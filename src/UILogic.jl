const _RANK_0 = (:none, :shared, :presets, :sweep, :config, :create_new)

"""
    menu_option_rank(opt::Tuple)

Custom sorting algorithm for Makie dropdown menus. 

# Hierarchy
1. **Rank 0:** Structural fallbacks (e.g., `:none`, "Methods..."), reserved default keys (like `:shared` or `:presets`), and any keys strictly belonging to the active simulation parameter array (`manager.plot_vars`).
2. **Rank 1:** Mathematical baselines. Strings containing keywords like "analytic", "reference", or "exact" are floated to the top of standard data options.
3. **Rank 2:** Standard alphabetical sorting for everything else.
"""
function menu_option_rank(opt)
    label_str = string(opt[1])
    val = length(opt) > 1 ? opt[2] : nothing
    
    # Rank 0: Main prompts and ":none" fallbacks 
    if val in manager.plot_vars || val in _RANK_0
        return (0, label_str)
    end
    
    # Rank 1: Priority references (same rule as the backend, e.g. "Analytic", "Exact Solution")
    if is_reference_method(label_str)
        return (1, label_str)
    end
    
    # Rank 2: Everything else
    return (2, label_str)
end

"""
    update_menu_safe!(menu_widget, new_options; fallbacks=Any[], force_notify=false)

Safely updates the options of a Makie `Menu` widget. 

Because rapidly swapping underlying tuples in a GLMakie backend can trigger WebGL buffer crashes or infinite `onany` recursion loops, this function mathematically verifies if an update is strictly necessary. If options do change, it gracefully preserves the user's active selection. If that selection is no longer valid, it attempts to bind to the first available element in the `fallbacks` array before defaulting to index `1`.
"""
function update_menu_safe!(menu_widget, new_options; fallbacks=Any[], force_notify=false)
    curr = menu_widget.selection[]
    
    # Ensure options are properly sorted by priority BEFORE comparing state
    new_arr = isempty(new_options) ? Any[menu_opt(:none)] : sort(new_options, by=menu_option_rank)
    
    old_arr = menu_widget.options[]
    options_changed = false
    
    # 1. Compare underlying option labels AND values
    is_eq = length(old_arr) == length(new_arr)
    if is_eq
        for (o, n) in zip(old_arr, new_arr)
            if o[1] != n[1] || o[2] != n[2]
                is_eq = false
                break
            end
        end
    end
    
    # 2. Update options and force WebGL sync if changed
    if !is_eq
        menu_widget.options[] = new_arr
        menu_widget.is_open[] = true
        menu_widget.is_open[] = false
        options_changed = true
    end

    # 3. Extract purely the values (2nd element of every tuple)
    opt_values = [opt[2] for opt in new_arr]

    # 4. Resolve the target selection index
    target_idx = 1
    if curr === :none || isnothing(curr) || curr ∉ opt_values
        for f in fallbacks
            idx = findfirst(isequal(f), opt_values)
            if !isnothing(idx)
                target_idx = idx
                break
            end
        end
    else
        target_idx = findfirst(isequal(curr), opt_values)
    end
    
    # 5. Apply selection and notify
    selection_changed = menu_widget.i_selected[] != target_idx
    if selection_changed
        menu_widget.i_selected[] = target_idx
    end
    
    if (options_changed && !selection_changed) || force_notify
        notify(menu_widget.selection)
    end
end

# Selects the option with the given value (re-notifying if it is already selected). Returns `false` if there is none.
function _select_menu_value!(menu_widget, value)
    idx = findfirst(o -> o isa Tuple && length(o) > 1 && isequal(o[2], value), menu_widget.options[])
    isnothing(idx) && return false
    if menu_widget.i_selected[] == idx
        notify(menu_widget.selection)
    else
        menu_widget.i_selected[] = idx
    end
    return true
end

"""
    apply_options!(cache::AbstractDict, option_keys::Tuple, new_options::Dict)

Orchestrates the massive state synchronization that occurs when a CSV preset is loaded.

1. **Persistent Update:** Unconditionally overwrites the persistent `cache` (`manager.layout_cache`, `manager.plot_cache` or `manager.exploration_cache`) with the loaded values.
2. **Widget Synchronization:** If the corresponding Makie widget currently exists in the layout, it safely updates its observable. It uses a three-tier matching system to resolve loaded UI strings (e.g., `"Contour Filled"`) back to their functional backend `Symbol`s (e.g., `:contour_f`).
"""
function apply_options!(cache::AbstractDict, option_keys::Tuple, new_options::Dict)
    isempty(new_options) && return

    # 1. ALWAYS update the central source of truth
    for (k, v) in new_options
        cache[k] = v
    end

    # 2. Sync the widgets ONLY if they currently exist
    for k in option_keys
        val = get(new_options, k, get(new_options, string(k), nothing))
        if !isnothing(val) && haskey(manager.widgets, k)
            widget = manager.widgets[k]
            opts = widget.options[]
            isempty(opts) && continue
            
            valid_vals = (!isempty(opts) && opts[1] isa Tuple) ? [o[2] for o in opts] : opts
            
            idx = findfirst(v -> string(v) == string(val), valid_vals)
            
            # Setting `i_selected` notifies `selection` by itself (an extra notify ran every listener twice).
            if !isnothing(idx)
                widget.i_selected[] = idx
            else
                # Fallback for dynamic menus (like Axis targets) pushing new options
                new_opts = copy(opts)
                push!(new_opts, opts[1] isa Tuple ? (string(val), val) : val)
                widget.options[] = new_opts
                widget.i_selected[] = length(widget.options[])
            end
        end
    end
end

"""
    extract_options(option_keys::Tuple)

Scrapes the current `selection[]` observables from all widgets matching the provided `option_keys` tuple. Returns a strongly typed `Dict{Symbol, Any}`.
"""
function extract_options(option_keys::Tuple)
    opts = Dict{Symbol, Any}()
    for k in option_keys
        if haskey(manager.widgets, k)
            opts[k] = manager.widgets[k].selection[]
        end
    end
    return opts
end

"""
    apply_slider_options!(slider_options::Dict)

Specifically manages the application of loaded parameter constraints to Makie `Slider`s. 
Because sliders automatically trigger data-fetching loops, this function safely clamps the target values to the sliders' natively allowable ranges and bypasses updates if the slider is holding a dummy `[0.0]` state.
"""
function apply_slider_options!(slider_options::Dict)
    isempty(slider_options) && return
    
    rev_map = manager.reverse_map
    for (key, desired_val) in slider_options
        # Skip standard dropdown keys if a mixed dictionary is passed in
        if key in PLOT_AXIS_OPTIONS || key in LAYOUT_OPTIONS || key in EXPLORATION_OPTIONS || key === :reset
            continue
        end
        
        base_sym = key
        w_key = haskey(rev_map, base_sym) ? rev_map[base_sym] : base_sym
        
        if haskey(manager.widgets, w_key)
            widget = manager.widgets[w_key]
            if widget isa Makie.Slider && desired_val isa Real
                # Safely cache the desired CSV value
                manager.slider_cache[w_key] = Float64(desired_val)
                manager.plot_cache[key] = desired_val
                
                rng = widget.range[]
                
                # If the range is a dummy placeholder, do not touch the widget
                if isempty(rng) || rng == [0.0]
                    continue
                end
                
                val = clamp(Float64(desired_val), Float64(rng[1]), Float64(rng[end]))
                set_close_to!(widget, val) 
            end
        end
    end
end

"""
    extract_slider_options()

Extracts the exact numeric floating-point values from every dynamic parameter slider currently rendered in the UI. 
Maps the internal UI widget keys back to their core physics variable symbols via `manager.reverse_map`.
"""
function extract_slider_options()
    opts = Dict{Symbol, Any}()
    rev_map = manager.reverse_map
    for k in manager.plot_vars
        w_key = haskey(rev_map, k) ? rev_map[k] : k 
        if haskey(manager.widgets, w_key)
            widget = manager.widgets[w_key]
            if widget isa Makie.Slider
                opts[k] = widget.value[] 
            end
        end
    end
    return opts
end

# ==============================================================================
# --- ALIASES FOR COMPATIBILITY ---
# ==============================================================================
apply_layout_options!(opts::Dict)      = apply_options!(manager.layout_cache, LAYOUT_OPTIONS, opts)
apply_exploration_options!(opts::Dict) = apply_options!(manager.exploration_cache, EXPLORATION_OPTIONS, opts)

function apply_plot_options!(opts::Dict)
    apply_options!(manager.plot_cache, PLOT_AXIS_OPTIONS, opts)
    apply_slider_options!(opts)
end

extract_layout_options()      = extract_options(LAYOUT_OPTIONS)
extract_exploration_options() = extract_options(EXPLORATION_OPTIONS)

function extract_plot_options()
    opts = extract_options(PLOT_AXIS_OPTIONS)
    merge!(opts, extract_slider_options())
    return opts
end

# ==============================================================================
# --- INTERACTION CONTROLLER ---
# ==============================================================================

"""
    setup_ui_interactions!(master_fig::Figure, plot_layout::GridLayout, mode::Val{T}) where T

The master conductor for the reactive UI. 
It establishes the state machine watching for structural or numeric changes, binds the physical button clicks, sets up the editor pages, and configures the dependent dropdown chains (Chains A, B, and C) that automatically prune invalid options when users change visualization paradigms.
"""
function setup_ui_interactions!(master_fig::Figure, plot_layout::GridLayout, mode::Val{T}) where T
    _setup_run_and_drop_interactions!(master_fig)
    _setup_method_interactions!()
    _setup_editor_interactions!()
    _setup_export_interactions!(master_fig, plot_layout)
    _setup_button_state_machine!()
    
    # Unified UI Data Sync Pipeline driven by Dispatch
    _setup_chain_A!(mode)
    _setup_chain_B!(mode)
    _setup_chain_C!(mode)
    
    notify(manager.methods)
    _setup_tab_interactions!()
end

"""
    _setup_button_state_machine!()

Wires up the global traffic lights of the UI. 
It constantly monitors the `:Layout` and `:Plot` caches. When it detects a discrepancy between the cache and the currently rendered scene, it flags the corresponding boolean observables and turns the "Update Plot" or "Apply Layout" buttons bright yellow, signaling to the user that a manual synchronization click is required.
"""
function _setup_button_state_machine!()
    w = manager.widgets
    
    f_sim = manager.flags[:Simulation]
    f_lay = manager.flags[:Layout]
    f_plot = manager.flags[:Plot]

    # --- DYNAMIC WATCHERS ---
    # 1. Layout Watcher
    layout_obs = [w[k].selection for k in LAYOUT_OPTIONS if haskey(w, k)]
    manager.listeners[:Watch_Layout] = onany(layout_obs...) do _...
        merge!(manager.layout_cache, extract_layout_options())
        if !manager.locks[:Layout] && !manager.locks[:Simulation]
            f_lay[] = true
        end
    end

    # 2. Plot Watcher
    plot_obs = [w[k].selection for k in PLOT_AXIS_OPTIONS if haskey(w, k)]
    manager.listeners[:Watch_Plot] = onany(plot_obs...) do _...
        merge!(manager.plot_cache, extract_plot_options())
        if !manager.locks[:Plot] && !manager.locks[:Layout] && !manager.locks[:Simulation]
            f_plot[] = true
        end
    end
    
    # 3. Exploration Watcher (Updates Cache, but doesn't flag a hard reset)
    exp_obs = [w[k].selection for k in EXPLORATION_OPTIONS if haskey(w, k)]
    manager.listeners[:Watch_Exploration] = onany(exp_obs...) do _...
        merge!(manager.exploration_cache, extract_exploration_options())
    end

    # --- MASTER HIERARCHY RESOLVER ---
    manager.listeners[:Button_Hierarchy] = onany(f_sim, f_lay, f_plot) do sim_needed, lay_needed, plot_needed
        c_sim = :lightgreen;  l_sim = "Run Simulation"
        c_lay = :lightgreen;  l_lay = "Apply Layout"
        c_plot = :lightgreen; l_plot = "Update Plot"

        if sim_needed
            c_sim = :lightyellow; l_sim = "Run Simulation *"
            c_lay = :lightcoral;  l_lay = "Locked (Sim)"
            c_plot = :lightcoral; l_plot = "Locked (Sim)"
        elseif lay_needed
            c_lay = :lightyellow; l_lay = "Apply Layout *"
            c_plot = :lightcoral; l_plot = "Locked (Layout)"
        elseif plot_needed
            c_plot = :lightyellow; l_plot = "Update Plot *"
        end

        if haskey(w, :run_button)
            w[:run_button].buttoncolor[] = c_sim
            w[:run_button].label[] = l_sim
        end
        if haskey(w, :layout_apply)
            w[:layout_apply].buttoncolor[] = c_lay
            w[:layout_apply].label[] = l_lay
        end
        if haskey(w, :plot_button)
            w[:plot_button].buttoncolor[] = c_plot
            w[:plot_button].label[] = l_plot
        end
    end
end

"""
    _setup_run_and_drop_interactions!(master_fig::Figure)

Connects the drag-and-drop file listener and the *Load CSV* button (a path, or a file name searched for in the usual
folders) to the CSV loader. 
Also handles the staging logic: if a loaded CSV contains structural changes (like an increase in allowed dimensions or
parameter sliders), it temporarily stores the configuration, turns the execution buttons orange, and completely
rebuilds the UI via `launch_plotter()` upon the next "Run" click.
"""
function _setup_run_and_drop_interactions!(master_fig::Figure)
    load_btn = manager.widgets[:load_config_button]
    run_btn  = manager.widgets[:run_button]
    path_box = manager.widgets[:export_text]

    function _handle_load(path)
        show_tab!(:files)  # the load button reports the result (a file may have been dropped on another tab)
        local structural
        try
            structural = load_and_apply_csv!(path)
        catch e
            @error "Failed to load $path" exception = (e, catch_backtrace())
            load_btn.label[] = "Loading failed (see log). Load CSV from Path Below / Drag & Drop Here"
            load_btn.buttoncolor[] = :lightcoral
            return
        end
        if structural
            load_btn.buttoncolor[] = :orange
            run_btn.buttoncolor[] = :orange
            load_btn.label[] = "Structural limits changed! \nClicking 'Run Simulation' will completely reset the backend. \nSave current settings as a preset if you want to keep them."
        else
            load_btn.label[] = "CSV successfully loaded! Press 'Run Simulation' to apply it."
            load_btn.buttoncolor[] = :lightgreen
            notify(manager.flags[:Simulation])  # recolours the Run button (it may still be orange from a staged file)
        end
    end

    manager.listeners[:Drag_Drop] = on(events(master_fig.scene).dropped_files) do files
        if !isempty(files) && endswith(lowercase(files[1]), ".csv")
            path = files[1]
            path_box.stored_string[] = path
            path_box.displayed_string[] = path
            _handle_load(path)
        end
    end

    manager.listeners[:Load_Click] = on(load_btn.clicks) do _
        path = strip(something(path_box.stored_string[], ""))
        if isempty(path)
            @warn "Please enter a path or filename in the textbox below first."
            return
        end
        found = find_config_csv(path)
        if isnothing(found)
            @warn "CSV file '$path' not found."
            return
        end
        _handle_load(found)
    end

    manager.listeners[:Run_Click] = on(run_btn.clicks) do _
        
        if !isnothing(manager.csv_cache)
            @info "Structural rebuild initiated. Relaunching UI..."
            
            # 1. Extract the staging area
            staged = manager.csv_cache
            manager.csv_cache = nothing
            
            # 2. Apply structural limits globally
            manager.allowed_dims = staged.dims
            manager.max_params = staged.max_params
            _sync_resolution_dims!()
            
            # 3. Physically relaunch UI (and display it safely if using GLMakie),
            #    then apply the cached configuration to the NEW widgets and run it.
            Base.invokelatest() do
                fig = launch_plotter()
                display(fig)
                load_and_apply_csv!(staged.parsed, staged.raw; config = staged.config, sources = staged.sources)
                force_simulation()
            end
            return
        end
        
        manager.flags[:Simulation][] = false
        manager.flags[:Layout][] = false
        manager.flags[:Plot][] = false
        manager.triggers[:Simulation][] += 1
        return
    end
end

"""
    _setup_method_interactions!()

Handles the "Activate/Deactivate" method toggles. It intercepts clicks, updates the active methods (`defaults`) of the `SimulationConfig`, and instantly flags the `:Simulation` lock to require a fresh backend numerical evaluation.
"""
function _setup_method_interactions!()
    mode_btn = manager.widgets[:mode_button]
    menu_mth = manager.widgets[:method_toggle]
    is_activate_mode = manager.is_activate_mode
    
    # A helper function to manually sync the menu directly from the config
    function sync_menu()
        config = manager.active_config
        isnothing(config) && return 
        
        staged = config.defaults
        raw_method_names = filter(k -> k != :shared, collect(keys(config.methods)))
        opts = is_activate_mode[] ? filter(m -> !(m in staged), raw_method_names) : copy(staged)

        opts_sorted = sort_methods_robust(opts)
        new_opts = isempty(opts) ? Any[menu_opt(:none)] : Any[("Methods...", :none); menu_opt.(opts_sorted)]
        update_menu_safe!(menu_mth, new_opts)
    end

    manager.listeners[:Menu_Sync] = on(is_activate_mode) do _
        @with_lock :Menu_Sync begin
            sync_menu()
        end
    end

    manager.listeners[:Mode_Click] = on(mode_btn.clicks) do _
        is_activate_mode[] = !is_activate_mode[]
        mode_btn.label[] = is_activate_mode[] ? "Mode: Activate" : "Mode: Deact."
        mode_btn.buttoncolor[] = is_activate_mode[] ? :lightgreen : :lightcoral
    end

    manager.listeners[:Method_Toggle] = on(menu_mth.selection) do sel
        (isnothing(sel) || sel === :none || sel == "-") && return
        
        config = manager.active_config
        isnothing(config) && return
        
        new_staged = copy(config.defaults)
        if is_activate_mode[]
            sel in new_staged || push!(new_staged, sel)   # appended: `defaults` keeps the display order
        else
            filter!(x -> x != sel, new_staged)
        end
        
        config.defaults = new_staged
        manager.flags[:Simulation][] = true
        menu_mth.i_selected[] = 1
        _render_editor!()  # the editor may be showing `defaults` or `permutation`, which just changed
        
        @with_lock :Menu_Sync begin
            sync_menu()
        end
    end
end

# ------------------------------------------------------------------------------
# Fixed widgets: placing, hiding and parking
# ------------------------------------------------------------------------------

# Draws or hides a block, or every block of a layout. Hidden Makie blocks still react to the mouse where they were
# (buttons, sliders and toggles hit-test their bounding box), which is why `_park!` also moves them off-screen.
function _set_item_visible!(gl::GridLayout, visible::Bool)
    for c in Makie.GridLayoutBase.contents(gl)
        _set_item_visible!(c, visible)
    end
    return nothing
end
function _set_item_visible!(b::Makie.Block, visible::Bool)
    visible || _release_block!(b)
    b.blockscene.visible[] == visible || (b.blockscene.visible[] = visible)
    return nothing
end
_set_item_visible!(_, ::Bool) = nothing

# Closes an open dropdown and drops the keyboard focus, so nothing hidden keeps listening.
_release_block!(b) = nothing
_release_block!(m::Menu) = (m.is_open[] && (m.is_open[] = false); nothing)
_release_block!(t::Textbox) = (t.focused[] && Makie.defocus!(t); nothing)

# Whether a block or layout sits exactly in `parent[row, col]`.
function _is_at(item, parent::GridLayout, row::Int, col::Int)
    gc = Makie.GridLayoutBase.gridcontent(item)
    return !isnothing(gc) && gc.parent === parent && gc.span.rows == row:row && gc.span.cols == col:col
end

# Places a block or layout in `parent[row, col]` (moving it only if it isn't there yet) and draws it.
function _place!(item, parent::GridLayout, row::Int, col::Int)
    _is_at(item, parent, row, col) || (parent[row, col] = item)
    _set_item_visible!(item, true)
    return nothing
end

# Hides a block or layout and moves it to the layout outside the figure, where it can't be seen or clicked. Every
# item has its own slot there, so parking it again doesn't move anything.
function _park!(item)
    park = manager.panel_park
    isnothing(park) && return nothing
    _set_item_visible!(item, false)
    slot = get!(manager.park_slots, objectid(item), length(manager.park_slots) + 1)
    _is_at(item, park, 1, slot) || (park[1, slot] = item)
    return nothing
end

# Removes empty rows at the end of a layout. An empty row has no natural height, so the layout would give it a
# share of the space and squeeze the others.
function _trim_rows!(gl::GridLayout)
    GLB = Makie.GridLayoutBase
    while GLB.nrows(gl) > 1 && !any(c -> GLB.lastrow(gl) in c.span.rows, gl.content)
        GLB.deleterow!(gl, GLB.lastrow(gl))
    end
    return nothing
end

# Places the shown `items` in the cells 1, 2, … of `gl` (row by row, `ncols` per row), parks the others and drops
# the empty rows at the end.
function _pack!(gl::GridLayout, items, shown; ncols::Int = 1, gap = nothing)
    n = 0
    for (item, s) in zip(items, shown)
        if s
            n += 1
            _place!(item, gl, (n - 1) ÷ ncols + 1, (n - 1) % ncols + 1)
        else
            _park!(item)
        end
    end
    _trim_rows!(gl)
    !isnothing(gap) && size(gl)[1] > 1 && rowgap!(gl, gap)
    return nothing
end

"""
    _sync_slider_rows!()

Shows the slider rows that have a choice to make (more than one position) and parks the others: unused parameter
sliders, dimensions on a plot axis or not present in the data. The shown rows are packed to the top of the slider
area, which keeps its height.
"""
function _sync_slider_rows!()
    haskey(manager.panels, :sliders) || return nothing
    keys = filter(k -> haskey(manager.widgets, k), _slider_keys())
    rows = [manager.panels[Symbol("slider_row_", k)] for k in keys]
    _pack!(manager.panels[:sliders], rows, [length(manager.widgets[k].range[]) > 1 for k in keys]; gap = SLIDER_ROWGAP)
    return nothing
end

# ------------------------------------------------------------------------------
# Control tabs
# ------------------------------------------------------------------------------

"""
    show_tab!(tab::Symbol)

Selects a tab of the control panel (`:plot`, `:layout`, `:simulation`, `:ui`, `:labels`, `:files`). The panels of
the tab (`TAB_PANELS`) are placed in the tab area and drawn; every other panel is hidden and parked in a layout
outside the figure, where it can't be clicked. Widgets are never deleted or recreated. The editor tabs show the
editor page last opened in their category (see `show_editor_page!`). A no-op
without an open window.
"""
function show_tab!(tab::Symbol)
    haskey(TAB_PANELS, tab) || throw(ArgumentError("unknown tab :$tab (tabs: $(join(CONTROL_TABS, ", ")))"))
    area = manager.tab_area
    (isnothing(area) || isnothing(manager.panel_park)) && return nothing

    shown = TAB_PANELS[tab]
    names = [shown...; [n for n in TAB_PANEL_NAMES if !(n in shown)]]
    _pack!(area, [manager.panels[n] for n in names], [n in shown for n in names]; gap = TAB_ROWGAP)

    for t in CONTROL_TABS
        btn = get(manager.widgets, Symbol("tab_", t), nothing)
        isnothing(btn) && continue
        active = t === tab
        btn.buttoncolor[]        = active ? RGBf(0.25, 0.41, 0.88) : RGBf(0.92, 0.92, 0.92)
        btn.buttoncolor_hover[]  = active ? RGBf(0.39, 0.58, 0.93) : RGBf(0.85, 0.85, 0.85)
        btn.buttoncolor_active[] = active ? RGBf(0.25, 0.41, 0.88) : RGBf(0.75, 0.75, 0.75)
        btn.labelcolor[] = btn.labelcolor_hover[] = btn.labelcolor_active[] = active ? :white : :black
    end

    manager.active_tab[] === tab || (manager.active_tab[] = tab)
    if tab in EDITOR_TABS
        _update_preset_buttons!(tab)
        _render_editor!()
    end
    return nothing
end

"""
    _setup_tab_interactions!()

Connects the tab buttons to `show_tab!`.
"""
function _setup_tab_interactions!()
    for tab in CONTROL_TABS
        btn = manager.widgets[Symbol("tab_", tab)]
        manager.listeners[Symbol("Tab_", tab)] = on(_ -> show_tab!(tab), btn.clicks)
    end
    return nothing
end

# ------------------------------------------------------------------------------
# Editor pages
# ------------------------------------------------------------------------------

"""
    ConfigFields(config)

Editor view (`Simulation → Config`) of the method and function fields of a `SimulationConfig`: `defaults` (active
methods), `reference`, `postprocess` and `sources`. Assignments go through the backend's normalisation; `none`
clears a function.

`permutation` is not a field: it shows the order of `defaults` as indices into their automatic order (references
first, then alphabetical, as the method menus list them), and assigning a permutation reorders `defaults`.
"""
struct ConfigFields
    config::SimulationConfig
end
const CONFIG_EDITOR_FIELDS = (:defaults, :permutation, :reference, :postprocess, :sources)
Base.haskey(::ConfigFields, key) = key in CONFIG_EDITOR_FIELDS
Base.keys(::ConfigFields) = collect(CONFIG_EDITOR_FIELDS)
Base.getindex(p::ConfigFields, key::Symbol) =
    key === :permutation ? _method_permutation(p.config.defaults) : getproperty(p.config, key)
function Base.setindex!(p::ConfigFields, value, key::Symbol)
    if key === :permutation
        p.config.defaults = _permute_methods(p.config.defaults, value)
        return p
    end
    key in (:reference, :postprocess) && (value = _function_name(value))
    setproperty!(p.config, key, value)
    return p
end

# The dictionary (or dictionary-like view) the editor edits for a category and scope.
function _editor_target(cat, scope)
    if cat === :simulation
        scope === :presets && return manager.sim_presets
        config = manager.active_config
        isnothing(config) && return nothing
        scope === :shared && return config.shared
        scope === :sweep && return config.varied
        scope === :config && return ConfigFields(config)
        return get(config.methods, scope, nothing)
    elseif cat === :ui
        scope === :presets && return manager.presets
        return get(manager.ui, scope, nothing)
    elseif cat === :labels
        return manager.labels
    end
    return nothing
end

_editor_display(v) = isnothing(v) ? "none" : val2str(v)

# The text the editor shows for `target[key]`; a method permutation is shown as plain indices (`[3, 1, 2]`).
_editor_text(target, key) = target isa ConfigFields && key === :permutation ? "[" * join(target[key], ", ") * "]" :
                            _editor_display(target[key])

# Shows `s` in the editor's text box as its current (stored) value. Makie draws a displayed string that differs
# from the stored one in the placeholder colour, so values set only through `displayed_string` looked like
# placeholders. `stored_string.val` is set without notifying, so the text is not re-applied as an edit.
function _show_editor_text!(tb, s::AbstractString)
    tb.stored_string.val = String(s)
    tb.displayed_string[] = String(s)
    return nothing
end

# UI options holding colours are validated when edited: an invalid colour would only fail later, inside the
# render loop, where it cannot be caught and leaves the studio unable to draw.
const _COLOR_UI_KEYS = (:color, :colors)
_valid_ui_value(key::Symbol, val) = key in _COLOR_UI_KEYS ? _valid_color(val) :
                                    key === :color_map ? _valid_colormap(val) : true

# Value restored by typing `default` into the editor: the built-in default of a UI option, the baseline configuration
# (see `reset_sim_config!`) of a simulation entry. Returns `missing` if there is none.
function _editor_default(cat, scope, key)
    if cat === :ui
        template = _ui_template_scope(scope)
        haskey(MASTER_UI_DICT, template) && haskey(MASTER_UI_DICT[template], key) && return deepcopy(MASTER_UI_DICT[template][key])
    elseif cat === :simulation
        base = manager.base_config
        isnothing(base) && return missing
        if scope === :config && key === :permutation
            # The baseline order if it has the same methods, otherwise the automatic order
            config = manager.active_config
            isnothing(config) && return missing
            current = unique(config.defaults)
            same = Set(current) == Set(base.defaults)
            return same ? _method_permutation(base.defaults) : collect(1:length(current))
        end
        target = scope === :shared ? base.shared : scope === :sweep ? base.varied :
                 scope === :config ? ConfigFields(base) : get(base.methods, scope, nothing)
        (!isnothing(target) && haskey(target, key)) && return deepcopy(target[key])
    elseif cat === :labels
        # the built-in display name, i.e. the name without the custom label
        custom = pop!(manager.labels, key, nothing)
        default = frontend_key(key)
        isnothing(custom) || (manager.labels[key] = custom)
        return default
    end
    return missing
end

"""
    _parse_editor_input(s, old)

Parses text typed into the editor. Text values stay text (quotes are optional), everything else is parsed with the
safe literal parser `str2val` (numbers, symbols, vectors, tuples, …).
"""
function _parse_editor_input(s::AbstractString, old)
    txt = strip(s)
    txt == "<empty>" && return ""
    isnothing(old) && lowercase(txt) in ("none", "nothing") && return nothing  # `nothing` is displayed as "none"
    if old isa AbstractString
        m = match(r"^\"(.*)\"$"s, txt)
        return isnothing(m) ? String(txt) : String(m.captures[1])
    end
    return str2val(txt)
end

"""
    _parse_sweep_input(s, old)

Parses the swept values typed into `Simulation → Sweep` into a `Vector` (a single value sweeps one value). For a
sweep of text values, unquoted items stay text: `[upwind, lax_friedrichs]`, or a single `1e3`.
"""
function _parse_sweep_input(s::AbstractString, old)
    txt = strip(s)
    text_sweep = old isa AbstractVector && !isempty(old) && all(v -> v isa AbstractString, old)
    val = str2val(txt)
    val isa AbstractVector && return collect(val)
    if text_sweep
        m = match(r"^\[(.*)\]$"s, txt)
        isnothing(m) && return Any[_parse_editor_input(txt, "")]
        items = filter(!isempty, strip.(split(m.captures[1], ',')))
        return Any[_parse_editor_input(it, "") for it in items]
    end
    return Any[val]
end

# Flags or triggers whatever an editor change requires.
function _after_editor_change!(cat, scope, key, target)
    if cat === :simulation
        scope === :presets && return nothing
        manager.flags[:Simulation][] = true
        if scope === :config && key in (:defaults, :permutation)
            notify(manager.is_activate_mode)  # refresh the method menu
        elseif scope === :sweep && !isnothing(manager.active_config)
            _map_parameters_to_sliders!(manager.active_config)
        end
    elseif cat === :ui
        scope === :presets && return nothing
        if key in REPLOT_OPTIONS
            manager.triggers[:Plot][] += 1
        else
            manager.triggers[:UI][] += 1
        end
    elseif cat === :labels
        if scope === :variables
            w_key = get(manager.reverse_map, key, key)
            lbl_key = Symbol("$(w_key)_label")
            haskey(manager.widgets, lbl_key) && (manager.widgets[lbl_key][] = manager.labels[key] * ":")
        elseif scope === :components
            notify(manager.widgets[:u_axis].selection)
        elseif scope === :methods
            notify(manager.is_activate_mode)
        end
        manager.triggers[:UI][] += 1
    end
    return nothing
end

# The preset buttons act on simulation presets while the editor shows the Simulation category.
function _update_preset_buttons!(cat)
    w = manager.widgets
    is_sim = cat === :simulation
    haskey(w, :save_presets_button) && (w[:save_presets_button].label[] = is_sim ? "Save Sim Preset" : "Save Presets")
    haskey(w, :clear_presets_button) && (w[:clear_presets_button].label[] = is_sim ? "Reset Simulation" : "Clear Presets")
    return nothing
end

# The preset buttons act on simulation presets in the Simulation tab and on visual presets otherwise.
_preset_context() = manager.active_tab[] === :simulation ? :simulation : :visual

# The preset registry shown under `Presets` for an editor category.
_preset_registry(cat) = cat === :simulation ? manager.sim_presets : manager.presets

# Display names of the fixed scopes; UI scopes and keys use their frontend names, simulation keys their exact names.
const _SCOPE_LABELS = Dict(:presets => "Presets", :shared => "Shared", :sweep => "Sweep", :config => "Config",
                           :components => "Components", :variables => "Variables", :methods => "Methods")

"""
    _editor_scopes(cat)

The pages (scopes) of an editor category, in overview order. Simulation: `Presets`, and with a bound configuration
`Shared`, `Sweep`, `Config` and every active method (activate a method to edit it; inactive ones stay in
`config.methods`). UI: `Presets` and every UI style scope. Labels: components, variables and methods.
"""
function _editor_scopes(cat)
    if cat === :simulation
        scopes = Symbol[:presets]
        config = manager.active_config
        isnothing(config) && return scopes
        append!(scopes, (:shared, :sweep, :config))
        for m in sort_methods_robust(filter(m -> haskey(config.methods, m), manager.methods[]))
            m in _RANK_0 || push!(scopes, m)  # reserved scope names
        end
        return scopes
    elseif cat === :ui
        return Symbol[:presets; sort!(collect(keys(manager.ui)))]
    elseif cat === :labels
        return Symbol[:components, :variables, :methods]
    end
    return Symbol[]
end

"""
    _editor_keys(cat, scope)

The keys of an editor page, in row order. Presets: `create_new` first, then the presets found on disk (the preset
folders are rescanned, so files copied there show up). The plot style scope lists only the options of the selected
plot style. Labels get their built-in display name if they have none yet.
"""
function _editor_keys(cat, scope)
    if scope === :presets
        refresh_preset_registries!()  # picks up preset files added on disk
        names = sort!(collect(keys(_preset_registry(cat))))
        return Any[:create_new; filter(!=(:create_new), names)]
    elseif cat === :labels
        raw_keys = Symbol[]
        if scope === :components
            c_max = 1
            if !isempty(manager.plot_data[])
                sim_data = _get_first_valid(first(values(manager.plot_data[])))
                if !isnothing(sim_data) && haskey(manager.widgets, :u_axis)
                    u_val = manager.widgets[:u_axis].selection[]
                    target_field = (isnothing(u_val) || u_val === :none) ? :Solution : u_val
                    target_tensor = get(sim_data.stats, target_field, sim_data.stats[:Solution])
                    c_max = _get_component_num_plots(Val(manager.mode[]), target_tensor)
                end
            end
            raw_keys = [Symbol("component_$i") for i in 1:c_max]
        elseif scope === :variables
            raw_keys = copy(manager.plot_vars)
        elseif scope === :methods
            raw_keys = copy(manager.methods[])
        end
        for k in raw_keys
            haskey(manager.labels, k) || set_label!(k, frontend_key(k))
        end
        return Any[raw_keys...]
    end
    target = _editor_target(cat, scope)
    isnothing(target) && return Any[]
    ks = sort!(collect(keys(target)))
    if cat === :ui && scope === :plot_style && haskey(manager.widgets, :plot_style)
        valid_keys = get(STYLE_DEPENDENCIES, manager.widgets[:plot_style].selection[], Symbol[])
        filter!(k -> k in valid_keys, ks)
    end
    return Any[ks...]
end

_scope_label(cat, scope) = get(_SCOPE_LABELS, scope, cat === :simulation ? string(scope) : menu_opt(scope)[1])
_key_label(cat, scope, key) = (cat === :ui || scope === :presets) && key isa Symbol ? menu_opt(key)[1] : string(key)

function _scope_button_label(cat, scope)
    ks = _editor_keys(cat, scope)
    n = scope === :presets ? count(!=(:create_new), ks) : length(ks)
    return "$(_scope_label(cat, scope)) ($n)"
end

# What the button of a row does: apply a preset, toggle a Bool, restore the default, or nothing (`create_new`).
function _row_action(cat, scope, target, key)
    scope === :presets && return key === :create_new ? :none : :apply
    haskey(target, key) && target[key] isa Bool && return :toggle
    return :reset
end

function _style_row_button!(btn, action, target, key)
    if action === :toggle
        on_ = target[key]::Bool
        btn.label[] = on_ ? "on" : "off"
        btn.buttoncolor[] = on_ ? RGBf(0.56, 0.93, 0.56) : RGBf(0.83, 0.83, 0.83)
    elseif action === :apply
        btn.label[] = "Apply"
        btn.buttoncolor[] = RGBf(0.56, 0.93, 0.56)
    elseif action === :reset
        btn.label[] = "↺"
        btn.buttoncolor[] = RGBf(0.92, 0.92, 0.92)
    else
        btn.label[] = " "
        btn.buttoncolor[] = RGBf(0.96, 0.96, 0.96)
    end
    return nothing
end

# Binds row `i` of the editor page to `target[key]`: name, value and action button.
function _bind_editor_row!(i::Int, cat, scope, target, key)
    w = manager.widgets
    w[Symbol("editor_row_", i, "_label")][] = _key_label(cat, scope, key)
    val_str = haskey(target, key) ? _editor_text(target, key) : ""
    _show_editor_text!(w[Symbol("editor_row_", i, "_text")], isempty(val_str) ? "<empty>" : val_str)
    _style_row_button!(w[Symbol("editor_row_", i, "_button")], _row_action(cat, scope, target, key), target, key)
    return nothing
end

"""
    _render_editor!()

Binds the editor widgets to the page selected in the active editor tab (`manager.editor_view[category]`): the
overview (one button per scope, see `_editor_scopes`) or the rows of a scope (one per key, see `_editor_keys`),
`EDITOR_ROWS` per page. Unused buttons and rows are parked. A scope that no longer exists (e.g. a deactivated method)
falls back to the overview. A no-op outside the editor tabs, so it can be called after any change.
"""
function _render_editor!()
    cat = manager.active_tab[]
    (cat in EDITOR_TABS && haskey(manager.panels, :editor_rows)) || return nothing
    w, p = manager.widgets, manager.panels

    scopes = _editor_scopes(cat)
    scope, page = get(manager.editor_view, cat, (nothing, 1))
    (isnothing(scope) || scope in scopes) || ((scope, page) = (nothing, 1))
    items = isnothing(scope) ? scopes : _editor_keys(cat, scope)
    per_page = isnothing(scope) ? OVERVIEW_BUTTONS : EDITOR_ROWS
    npages = max(1, cld(length(items), per_page))
    page = clamp(page, 1, npages)
    manager.editor_view[cat] = (scope, page)
    page_items = items[(page - 1) * per_page + 1:min(page * per_page, length(items))]

    title = isnothing(scope) ? TAB_LABELS[cat] : _scope_label(cat, scope)
    w[:editor_title][] = npages > 1 ? "$title  ($page/$npages)" : title
    isnothing(scope) ? _park!(p[:editor_back]) : _place!(p[:editor_back], p[:editor_header], 1, 1)
    npages > 1 ? _place!(p[:editor_pager], p[:editor_header], 1, 3) : _park!(p[:editor_pager])

    if isnothing(scope)
        _park!(p[:editor_rows])
        _place!(p[:editor_overview], p[:editor_body], 1, 1)
        manager.editor_page_scopes = Symbol[page_items...]
        manager.editor_row_keys = Any[]
        buttons = [w[Symbol("editor_page_", j)] for j in 1:OVERVIEW_BUTTONS]
        for (j, s) in enumerate(page_items)
            buttons[j].label[] = _scope_button_label(cat, s)
        end
        _pack!(p[:editor_overview], buttons, [j <= length(page_items) for j in 1:OVERVIEW_BUTTONS];
               ncols = OVERVIEW_COLS, gap = EDITOR_ROWGAP + 2)
    else
        _park!(p[:editor_overview])
        _place!(p[:editor_rows], p[:editor_body], 1, 1)
        manager.editor_page_scopes = Symbol[]
        manager.editor_row_keys = Any[page_items...]
        target = _editor_target(cat, scope)
        for (i, key) in enumerate(page_items)
            _bind_editor_row!(i, cat, scope, target, key)
        end
        rows = [p[Symbol("editor_row_", i)] for i in 1:EDITOR_ROWS]
        _pack!(p[:editor_rows], rows, [i <= length(page_items) for i in 1:EDITOR_ROWS]; gap = EDITOR_ROWGAP)
    end
    return nothing
end

"""
    show_editor_page!(cat::Symbol, scope = nothing; page = 1)

Opens a page of the editor: the tab of the category (`:simulation`, `:ui` or `:labels`) with the rows of `scope`
(e.g. `:shared`, `:config`, a method, `:x_axis`, `:presets`), or the overview of the category for `scope = nothing`.
`page` selects the page of a scope with more keys than rows. A no-op without an open window.
"""
function show_editor_page!(cat::Symbol, scope = nothing; page::Int = 1)
    cat in EDITOR_TABS || throw(ArgumentError("unknown editor category :$cat (categories: $(join(EDITOR_TABS, ", ")))"))
    manager.editor_view[cat] = (scope, page)
    manager.active_tab[] === cat ? _render_editor!() : show_tab!(cat)
    return nothing
end

# The page entry bound to row `i`: (category, scope, key, target), or `nothing`.
function _editor_row_binding(i::Int)
    cat = manager.active_tab[]
    cat in EDITOR_TABS || return nothing
    scope, _ = get(manager.editor_view, cat, (nothing, 1))
    (isnothing(scope) || i > length(manager.editor_row_keys)) && return nothing
    target = _editor_target(cat, scope)
    isnothing(target) && return nothing
    return (cat, scope, manager.editor_row_keys[i], target)
end

"""
    _apply_editor_input!(cat, scope, key, target, s, tb) -> Bool

Applies text typed into the value box `tb` of a row to `target[key]`: preset descriptions are stored (and written
to the preset file), `default` restores the default (see `_editor_default`), labels are set as text, sweeps are
parsed with `_parse_sweep_input`, everything else with the safe literal parser (`_parse_editor_input`). Colours are
validated. Returns whether something changed; problems are reported as warnings.
"""
function _apply_editor_input!(cat, scope, key, target, s::AbstractString, tb)
    try
        if scope === :presets
            target[key] = String(s)  # the description (for :create_new: of the next preset saved)
            key === :create_new || _store_preset_description!(cat, key, String(s))
        elseif strip(s) == "default"
            val = _editor_default(cat, scope, key)
            if ismissing(val)
                @warn "No default value is known for '$key'."
                return false
            end
            cat === :labels ? set_label!(key, string(val)) : (target[key] = val)
        elseif cat === :labels
            set_label!(key, String(s))
        else
            if cat === :simulation && scope === :sweep
                val = _parse_sweep_input(s, target[key])
                if isempty(val)
                    @warn "A sweep needs at least one value; '$key' was not changed."
                    return false
                end
            else
                val = _parse_editor_input(s, target[key])
            end
            if cat === :ui && !_valid_ui_value(key, val)
                @warn "'$key' was not changed: $(repr(val)) is not a valid " *
                      (key === :color_map ? "colormap (e.g. :viridis)." : "colour (e.g. :red, \"#1f77b4\" or (:blue, 0.5)).")
                return false
            end
            target[key] = val
        end
        _after_editor_change!(cat, scope, key, target)
        return true
    catch e
        @warn "Failed to apply parameter '$key': $(s)" exception=(e, catch_backtrace())
        return false
    end
end

# The button of a row: apply a preset, toggle a Bool, or restore the default.
function _editor_row_action!(cat, scope, key, target, tb)
    action = _row_action(cat, scope, target, key)
    try
        if action === :apply
            cat === :simulation ? set_sim_preset!(key) : set_plot_preset!(key)
        elseif action === :toggle
            target[key] = !target[key]
            _after_editor_change!(cat, scope, key, target)
        elseif action === :reset
            _apply_editor_input!(cat, scope, key, target, "default", tb) || return nothing
        else
            save_label = cat === :simulation ? "Save Sim Preset" : "Save Presets"
            @info "Type a description here, enter a name in the filename box and click '$save_label'."
            return nothing
        end
    catch e
        @warn "Failed to apply '$key'." exception=(e, catch_backtrace())
    end
    _render_editor!()
    return nothing
end

"""
    _setup_editor_interactions!()

Connects the fixed editor widgets: the page buttons of the overview open a scope, ◀ Back returns to the overview,
◀ ▶ turn pages, and each row writes its value box into the dictionary of the page (`_apply_editor_input!`) or runs
its button (`_editor_row_action!`). Rows and buttons look up what they are bound to when used, so rebinding a page
needs no new listeners. The editor is redrawn when the active methods change.
"""
function _setup_editor_interactions!()
    w = manager.widgets
    for i in 1:EDITOR_ROWS
        tb = w[Symbol("editor_row_", i, "_text")]
        manager.listeners[Symbol("Editor_Row_Text_", i)] = on(tb.stored_string) do s
            s isa AbstractString || return
            manager.locks[:Simulation] && return  # a simulation is running
            b = _editor_row_binding(i)
            isnothing(b) && return
            _apply_editor_input!(b..., s, tb) && _render_editor!()
        end
        manager.listeners[Symbol("Editor_Row_Button_", i)] = on(w[Symbol("editor_row_", i, "_button")].clicks) do _
            manager.locks[:Simulation] && return
            b = _editor_row_binding(i)
            isnothing(b) && return
            _editor_row_action!(b..., tb)
        end
    end
    for j in 1:OVERVIEW_BUTTONS
        manager.listeners[Symbol("Editor_Page_", j)] = on(w[Symbol("editor_page_", j)].clicks) do _
            cat = manager.active_tab[]
            (cat in EDITOR_TABS && j <= length(manager.editor_page_scopes)) || return
            show_editor_page!(cat, manager.editor_page_scopes[j])
        end
    end
    manager.listeners[:Editor_Back] = on(w[:editor_back].clicks) do _
        cat = manager.active_tab[]
        cat in EDITOR_TABS && show_editor_page!(cat)
    end
    for (name, step) in ((:editor_prev, -1), (:editor_next, 1))
        manager.listeners[Symbol("Editor_Page_Turn_", step)] = on(w[name].clicks) do _
            cat = manager.active_tab[]
            cat in EDITOR_TABS || return
            scope, page = get(manager.editor_view, cat, (nothing, 1))
            manager.editor_view[cat] = (scope, page + step)
            _render_editor!()
        end
    end
    manager.listeners[:Editor_Methods] = on(_ -> _render_editor!(), manager.methods)
    return nothing
end

"""
    _setup_export_interactions!(master_fig::Figure, plot_layout::GridLayout)

The standalone sub-routine managing figure and animation serialization. 

It handles the generation of a pristine, headless `Figure` copy of the active axes to ensure that UI artifacts (like slider handles or un-applied states) are never rendered into the final exported `.png` or `.mp4`.
"""
function _setup_export_interactions!(master_fig::Figure, plot_layout::GridLayout)
    saveBox = manager.widgets[:export_text]
    btn_play = manager.widgets[:play_anim_button]
    btn_lock = manager.widgets[:lock_camera_button] 
    btn_export = manager.widgets[:export_button]

    manager.listeners[:Camera_Lock_Click] = on(btn_lock.clicks) do _
        is_locked = !manager.camera_locked[]
        manager.camera_locked[] = is_locked
        
        if is_locked
            extract_and_store_camera_state!(plot_layout)
            @info "Camera locked to current view."
        else
            manager.camera_cache = Dict{Symbol, Any}()
            @info "Camera unlocked. Will auto-scale on next data update."
        end
    end

    # Couple the button directly to the observable
    manager.listeners[:Camera_State_Sync] = on(manager.camera_locked) do is_locked
        if is_locked
            btn_lock.label[] = "Camera: Locked"
            btn_lock.buttoncolor[] = :lightgreen
        else
            btn_lock.label[] = "Lock Camera"
            btn_lock.buttoncolor[] = :lightblue
        end
    end

    anim_target_obs = manager.widgets[:anim_target].selection
    is_animating = manager.is_animating
    animation_timer = manager.animation_timer

    function get_target_widget(target_name)
        target_name == :none && return nothing
        rev_map = manager.reverse_map
        w_key = haskey(rev_map, target_name) ? rev_map[target_name] : Symbol(target_name)
        return haskey(manager.widgets, w_key) ? manager.widgets[w_key] : nothing
    end

    function check_selection_validity(target_name)
        if isnothing(target_name) || target_name == :none
            @warn "Export Error: No target selected."
            return false 
        end
        
        idx = findfirst(isequal(target_name), manager.plot_vars)
        if !isnothing(idx) && idx in manager.active_axes[]
            @warn "Cannot animate an active plot axis."
            return false 
        end
        
        widget = get_target_widget(target_name)
        if isnothing(widget)
            return false
        end
        if !(widget isa Makie.Slider)
            @warn "Only Sliders can be animated."
            return false 
        end
        if length(widget.range[]) < 2
            @warn "Slider has no range to animate."
            return false 
        end
        return true
    end
    function build_pristine_export_figure()
        
        export_fig = Figure() 
        export_layout = export_fig[1, 1] = GridLayout()
        
        ptype_sym = manager.widgets[:plot_style].selection[]
        export_obs = setup_render_lift!(export_fig, export_layout, Val(ptype_sym))
        
        current_axes = [c.content for c in plot_layout.content if c.content isa Axis || c.content isa Axis3]
        export_axes = [c.content for c in export_layout.content if c.content isa Axis || c.content isa Axis3]
        
        manager.triggers[:Plot][] += 1
        
        for (c_ax, e_ax) in zip(current_axes, export_axes)
            if c_ax isa Axis3
                e_ax.azimuth[] = c_ax.azimuth[]
                e_ax.elevation[] = c_ax.elevation[]
                e_ax.perspectiveness[] = c_ax.perspectiveness[]
                
                lims = c_ax.finallimits[]
                limits!(e_ax, lims.origin[1], lims.origin[1] + lims.widths[1],
                              lims.origin[2], lims.origin[2] + lims.widths[2],
                              lims.origin[3], lims.origin[3] + lims.widths[3])
            elseif c_ax isa Axis
                lims = c_ax.finallimits[]
                limits!(e_ax, lims.origin[1], lims.origin[1] + lims.widths[1], 
                              lims.origin[2], lims.origin[2] + lims.widths[2])
            end
        end
        
        resize_to_layout!(export_fig)
        return export_fig, export_obs
    end
    manager.listeners[:Export_Click] = on(btn_export.clicks) do _
        raw_filename = String(strip(something(saveBox.stored_string[], "")))
        isempty(raw_filename) && (raw_filename = "plot_export")
        
        name_part, ext = splitext(raw_filename)
        ext = lowercase(lstrip(ext, '.'))
        
        is_anim = ext in ANIMATION_EXPORT_FORMATS
        if is_anim
            base_name = name_part
            formats = String[]
        elseif ext in STATIC_EXPORT_FORMATS
            # "figure.pdf" exports exactly that format, ignoring the format list of the export settings
            base_name = name_part
            formats = [ext]
        else
            # no (or an unknown) extension, e.g. "run_dt0.5": the whole text is the name
            base_name = raw_filename
            formats = _export_formats(get(manager.ui[:export], :save_formats, String[]))
        end

        target_name = anim_target_obs[] 
        if is_anim
            !check_selection_validity(target_name) && return
        end

        was_locked = manager.camera_locked[]
        manager.camera_locked[] = true 
        extract_and_store_camera_state!(plot_layout)
        
        target_widget = is_anim ? get_target_widget(target_name) : nothing

        try
            # 1. SHUT DOWN MAIN WINDOW (Prevents cache corruption and duplicate colorbars)
            for obs in manager.main_render_observers; off(obs); end
            empty!(manager.main_render_observers)
            
            # 2. BUILD PRISTINE EXPORT FIGURE (Takes exclusive control of manager.caches)
            export_fig, export_obs = build_pristine_export_figure()
            dpi_val = get(manager.ui[:export], :dpi, 300)

            manager.is_exporting = true

            # --- ANIMATION EXPORT ---
            if is_anim
                save_path = joinpath(get_save_path(), "animations")
                fname = joinpath(save_path, base_name * "." * ext)
                mkpath(dirname(fname))
                
                duration = Float64(manager.ui[:export][:animation_time])
                fps = max(1, round(Int, manager.ui[:export][:animation_FPS]))
                comp = get(manager.ui[:export], :mp4_compression, 15)
                
                rng = target_widget.range[]
                n_frames = max(2, round(Int, duration * fps))
                @info "Recording pristine '$target_name' animation to $fname..."
                
                record(export_fig, fname, range(rng[1], rng[end], length=n_frames); framerate=fps, compression=comp, px_per_unit=dpi_val/96.0) do val
                    set_close_to!(target_widget, val)
                    yield() 
                end
                
                metadata = Dict("Save Type" => "Animation", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
                save_params_to_csv(base_name, save_path, metadata) 
                @info "Pristine Animation Saved Successfully."
                
            # --- STATIC FRAME EXPORT ---
            elseif !isempty(formats)
                save_dir = joinpath(get_save_path(), "figures")
                if get(manager.ui[:export], :create_savefolder, false) === true
                    save_dir = joinpath(save_dir, base_name)
                end

                for fmt in formats
                    full_path = joinpath(save_dir, base_name * ".$fmt")
                    mkpath(dirname(full_path))
                    if fmt in ("png", "jpg", "jpeg")
                        save(full_path, export_fig; backend=CairoMakie, px_per_unit=dpi_val/96.0)
                    else
                        save(full_path, export_fig; backend=CairoMakie)
                    end
                    @info "Pristine Image ($fmt) saved to $full_path"
                end
                
                metadata = Dict("Save Type" => "Static Frame", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
                save_params_to_csv(base_name, save_dir, metadata)
                
            else
                @warn "No valid static formats selected and no animation extension provided. Export bypassed."
            end
            
            # 3. SHUT DOWN EXPORT LISTENERS
            for obs in export_obs; off(obs); end
            
        catch e
            @error "Export Failed" exception=(e, catch_backtrace())
        finally
            manager.is_exporting = false
            
            manager.camera_locked[] = was_locked
            if !was_locked
                manager.camera_cache = Dict{Symbol, Any}()
            end
            
            @info "Restoring main UI..."
            manager.skip_next_camera_extract = true 
            manager.triggers[:Layout][] += 1
            
            # Force the OpenGL context to bring the main window back to life
            display(master_fig)
        end
    end

    # Context-sensitive: saves a simulation preset in the Simulation tab, otherwise a visual preset.
    manager.listeners[:Save_Defs] = on(manager.widgets[:save_presets_button].clicks) do _
        filename = String(strip(something(saveBox.stored_string[], "")))
        if isempty(filename)
            @warn "Please enter a preset name in the Filename box."
            return
        end
        
        is_sim = _preset_context() === :simulation
        registry = is_sim ? manager.sim_presets : manager.presets
        desc = get(registry, :create_new, "")
        # Text typed into the create_new row of a Presets page counts even if Enter was not pressed yet (then the
        # displayed string differs from the stored one, which is always kept in sync otherwise).
        cat = manager.active_tab[]
        on_presets = cat in EDITOR_TABS && first(get(manager.editor_view, cat, (nothing, 1))) === :presets
        row = on_presets ? findfirst(isequal(:create_new), manager.editor_row_keys) : nothing
        if !isnothing(row)
            tb = manager.widgets[Symbol("editor_row_", row, "_text")]
            shown = strip(tb.displayed_string[])
            if shown != strip(something(tb.stored_string[], "")) && !isempty(shown) && shown != "<empty>"
                desc = String(shown)
            end
        end

        success = is_sim ? save_sim_preset(filename; description = desc) :
                           save_plot_preset(filename; description = desc)
        success || return

        registry[:create_new] = DEFAULT_PRESET_DESC
        Makie.reset!(saveBox)

        # Show the new preset in the editor (the Labels tab saves visual presets but has no Presets page)
        if cat in (:simulation, :ui)
            idx = findfirst(isequal(_preset_symbol(filename)), _editor_keys(cat, :presets))
            show_editor_page!(cat, :presets; page = isnothing(idx) ? 1 : cld(idx, EDITOR_ROWS))
        end
    end
    
    # Context-sensitive: restores the bound simulation configuration, or the default look.
    manager.listeners[:Clear_Defs_Click] = on(manager.widgets[:clear_presets_button].clicks) do _
        if _preset_context() === :simulation
            manager.locks[:Simulation] && return
            reset_sim_config!()
        else
            set_plot_preset!()
            manager.triggers[:UI][] += 1
        end
    end

    manager.listeners[:Anim_State_Change] = on(is_animating) do animating
        btn_play.label[] = animating ? "Stop Anim" : "Play Anim"
    end

    manager.listeners[:Play_Anim_Click] = on(btn_play.clicks) do _
        if is_animating[]
            is_animating[] = false
            !isnothing(animation_timer[]) && close(animation_timer[])
            animation_timer[] = nothing
        else
            target_name = anim_target_obs[]
            !check_selection_validity(target_name) && return
            
            target_widget = get_target_widget(target_name)
            is_animating[] = true
            
            duration = manager.ui[:export][:animation_time]
            fps = manager.ui[:export][:animation_FPS]
            rng = target_widget.range[]
            start_time = time()
            
            animation_timer[] = Timer(0.0, interval = 1/fps) do t
                if !is_animating[]; close(t); return; end
                elapsed = mod(time() - start_time, duration)
                progress = elapsed / duration
                val = rng[1] + progress * (rng[end] - rng[1])
                set_close_to!(target_widget, val)
            end
        end
    end
end

"""
    _get_active_sim_data(plot_data_dict)

Helper function that grabs the first structurally valid (non-null) `AbstractSimData` object from the current sweep cache.
"""
function _get_active_sim_data(plot_data_dict)
    isempty(plot_data_dict) && return nothing, nothing
    pd_first = first(values(plot_data_dict))
    
    sim_data = _get_first_valid(pd_first)
    
    return pd_first, sim_data
end

# ==============================================================================
# --- CHAIN A: Base Setup & Anim/Compare Targeting ---
# ==============================================================================

"""
    _setup_chain_A!(::Val{:eulerian})

The primary dropdown cascade for Eulerian data. 

When a base plot style (e.g., `:heatmap`) is selected, it immediately populates the style modifier menu (e.g., `:heatmap_surface`, `:heatmap_flat`). It then queries the underlying tensor's dimensions and filters the available Animation, Compare, and X/Y/Z Axis dropdown targets to ensure users cannot attempt to animate non-existent physical domains.
"""
function _setup_chain_A!(::Val{:eulerian})
    w = manager.widgets
    x_sel = w[:x_axis].selection
    y_sel = w[:y_axis].selection
    base_obs = w[:base_plot].selection
    style_obs = w[:plot_style].selection
    
    base_opts = Any[menu_opt(:lines), menu_opt(:scatter), menu_opt(:contour), menu_opt(:heatmap), menu_opt(:volume)]
    update_menu_safe!(w[:base_plot], base_opts; fallbacks=[:lines_1d], force_notify=false)

    manager.listeners[:Eulerian_Base_Change] = on(base_obs) do base_type
        (isnothing(base_type) || base_type == :none) && return
        valid_styles = get(EULERIAN_PLOT_STYLE_OPTIONS, base_type, Any[menu_opt(:lines_1d)])
        update_menu_safe!(w[:plot_style], valid_styles; fallbacks=[:lines_1d], force_notify=false)
        _render_editor!()  # the plot style page lists the options of the style
    end
    
    manager.listeners[:Eulerian_Style_Change] = on(style_obs) do _
        _render_editor!()
    end

    manager.listeners[:Eulerian_Chain_A] = onany(manager.plot_data, base_obs, style_obs, x_sel, y_sel) do plot_data_dict, base_sel, style_sel, _x, _y
        @with_lock :Menu_A begin
            isempty(plot_data_dict) && return
            (isnothing(style_sel) || style_sel == :none || isnothing(base_sel) || base_sel == :none) && return
            pd_first = first(values(plot_data_dict))
            n_params = length(pd_first.active_param_keys)
            # The swept parameters of the computed data (the bound config may already sweep others: re-run pending)
            dim_names = Symbol[Symbol.(pd_first.active_param_keys); get_base_variables()]
            
            sim_data = _get_first_valid(pd_first)
            isnothing(sim_data) && return
            
            valid_indep_axes = Symbol[]
            for p in pd_first.active_param_keys; push!(valid_indep_axes, Symbol(p)); end
            for k in sim_data.domain.dim_keys; push!(valid_indep_axes, k); end
            
            for k in keys(sim_data.stats)
                k === :Solution && continue
                stat_dims = PDEStudioCore.get_kept_dims(k, sim_data.domain)
                if isempty(stat_dims)
                    for p in pd_first.active_param_keys
                        push!(valid_indep_axes, Symbol("$(String(k))|$p"))
                    end
                elseif length(stat_dims) == 1
                    push!(valid_indep_axes, Symbol("$(String(k))|$(stat_dims[1])"))
                end
            end
            
            anim_options = Any[menu_opt(:none)]
            for i in 1:length(dim_names)
                ax_sym = dim_names[i]
                if i <= n_params && length(pd_first.active_param_values[i]) > 1
                    push!(anim_options, menu_opt(ax_sym))
                elseif i > n_params && ax_sym in valid_indep_axes
                    push!(anim_options, menu_opt(ax_sym))
                end
            end
            
            # Dynamically set the fallback to the time dimension
            t_dim = sim_data.domain.time_dim
            anim_fallbacks = !isnothing(t_dim) ? [t_dim, :none] : [:none]
            
            update_menu_safe!(w[:anim_target], anim_options; fallbacks=anim_fallbacks)

            compare_opts = Any[menu_opt(:none), menu_opt(:methods), menu_opt(:component)]
            if !isnothing(sim_data.domain.time_dim)
                push!(compare_opts, menu_opt(:time))
            end
            for p_key in pd_first.active_param_keys
                # Use menu_opt instead of string()
                push!(compare_opts, menu_opt(Symbol(p_key)))
            end
            update_menu_safe!(w[:compare_target], compare_opts; fallbacks=[:none], force_notify=false)

            ptype = manager.widgets[:plot_style].selection[]
            p_dim = get(PLOT_DIM_MAP, ptype, 1)
            
            build_axis_opts = function(excluded_syms)
                excluded_loops = [occursin("|", string(ex)) ? Symbol(split(string(ex), "|")[2]) : ex for ex in excluded_syms]
                opts = Any[]
                for ax_sym in valid_indep_axes
                    ax_str = string(ax_sym)
                    loop_dim = occursin("|", ax_str) ? Symbol(split(ax_str, "|")[2]) : ax_sym
                    loop_dim in excluded_loops && continue
                    
                    if occursin("|", ax_str)
                        stat_sym = Symbol(split(ax_str, "|")[1])
                        # Use frontend_key directly for the complex string construction
                        add_name = loop_dim in get_base_variables() ? titlecase(string(loop_dim)) : frontend_key(loop_dim)
                        nice_name = "$(frontend_key(stat_sym)) ($(add_name))"
                        push!(opts, (nice_name, ax_sym))
                    else
                        # Use menu_opt for all standard parameters and dimensions!
                        push!(opts, menu_opt(ax_sym))
                    end
                end
                return isempty(opts) ? Any[menu_opt(:none)] : opts
            end
            
            base_vars = get_base_variables()
            
            update_menu_safe!(w[:x_axis], build_axis_opts([]); fallbacks=base_vars, force_notify=false)
            x_val = w[:x_axis].selection[]  # read after the update: the old choice may no longer exist
            if p_dim >= 2
                update_menu_safe!(w[:y_axis], build_axis_opts([x_val]); fallbacks=base_vars, force_notify=false)
            else
                update_menu_safe!(w[:y_axis], Any[menu_opt(:none)]; fallbacks=[:none], force_notify=false)
            end
            
            curr_y = w[:y_axis].selection[]
            if p_dim >= 3
                update_menu_safe!(w[:z_axis], build_axis_opts([x_val, curr_y]); fallbacks=base_vars, force_notify=false)
            else
                update_menu_safe!(w[:z_axis], Any[menu_opt(:none)]; fallbacks=[:none], force_notify=false)
            end
        end
    end
end

"""
    _setup_chain_A!(::Val{:lagrangian})

The primary dropdown cascade for Lagrangian data. 

Recognizes that point clouds do not have fixed Eulerian bounding boxes. It forces the base plot to `:scatter`, automatically locks the available X/Y/Z axes based strictly on the dimensionality of the scattered vectors (e.g., forcing X and Y for a 2D particle track), and explicitly injects the scalar `:time` dimension as the default animation target.
"""
function _setup_chain_A!(::Val{:lagrangian})
    w = manager.widgets
    
    # Ensure the base menu is locked to Scatter when in Lagrangian mode
    base_opts = Any[menu_opt(:scatter)]
    update_menu_safe!(w[:base_plot], base_opts; fallbacks=[:scatter], force_notify=false)

    manager.listeners[:Lagrangian_Chain_A] = onany(manager.plot_data) do plot_data_dict
        @with_lock :Menu_A begin
            isempty(plot_data_dict) && return
            
            pd_first = first(values(plot_data_dict))
            l_data = _get_first_valid(pd_first)
            isnothing(l_data) && return
            
            n_params = length(pd_first.active_param_keys)
            dim_names = Symbol.(pd_first.active_param_keys)
            
            D = length(l_data.domain.mins) - (isnothing(l_data.domain.time_dim) ? 0 : 1)
            spatial_keys = filter(k -> k != l_data.domain.time_dim, l_data.domain.dim_keys)
            
            sx = D >= 1 ? spatial_keys[1] : :x
            sy = D >= 2 ? spatial_keys[2] : :y
            sz = D >= 3 ? spatial_keys[3] : :z
            
            update_menu_safe!(w[:x_axis], Any[menu_opt(sx)]; fallbacks=[sx], force_notify=true)
            if D == 1
                update_menu_safe!(w[:plot_style], Any[menu_opt(:scatter_1d), menu_opt(:scatter_lines), menu_opt(:scatter_colors)]; fallbacks=[:scatter_1d], force_notify=false)
                update_menu_safe!(w[:y_axis], Any[menu_opt(:none)]; fallbacks=[:none])
                update_menu_safe!(w[:z_axis], Any[menu_opt(:none)]; fallbacks=[:none])
            elseif D == 2
                update_menu_safe!(w[:plot_style], Any[menu_opt(:scatter_2d), menu_opt(:scatter_surface)]; fallbacks=[:scatter_2d], force_notify=false)
                update_menu_safe!(w[:y_axis], Any[menu_opt(sy)]; fallbacks=[sy])
                update_menu_safe!(w[:z_axis], Any[menu_opt(:none)]; fallbacks=[:none])
            else
                update_menu_safe!(w[:plot_style], Any[menu_opt(:scatter_3d)]; fallbacks=[:scatter_3d], force_notify=false)
                update_menu_safe!(w[:y_axis], Any[menu_opt(sy)]; fallbacks=[sy])
                update_menu_safe!(w[:z_axis], Any[menu_opt(sz)]; fallbacks=[sz])
            end
            
            anim_options = Any[menu_opt(:none)]
            for i in 1:n_params
                ax_sym = dim_names[i]
                if length(pd_first.active_param_values[i]) > 1
                    push!(anim_options, menu_opt(ax_sym))
                end
            end
            
            # Explicitly add time to Lagrangian anim options and set it as the default
            t_dim = l_data.domain.time_dim
            if !isnothing(t_dim)
                push!(anim_options, menu_opt(t_dim))
            end
            
            anim_fallbacks = !isnothing(t_dim) ? [t_dim, :none] : [:none]
            
            update_menu_safe!(w[:anim_target], anim_options; fallbacks=anim_fallbacks)
            
            compare_opts = Any[menu_opt(:none), menu_opt(:methods), menu_opt(:component)]
            if !isnothing(l_data.domain.time_dim)
                push!(compare_opts, menu_opt(:time))
            end
            for p_key in pd_first.active_param_keys
                push!(compare_opts, menu_opt(Symbol(p_key)))
            end
            update_menu_safe!(w[:compare_target], compare_opts; fallbacks=[:none], force_notify=false)
        end
    end
end

# ==============================================================================
# --- CHAIN B: Dependent Field & Active Axis Triggers ---
# ==============================================================================
"""
    _setup_chain_B!(::Val{:eulerian})

The secondary UI cascade. 

It listens to the exact spatial axes the user has currently selected (e.g., X and Y). It then iterates through all mathematically generated error metrics and custom statistics in the backend registry. If a statistic does not possess the physical dimensions required to be plotted across X and Y (e.g., a purely scalar mass conservation stat), it is automatically pruned from the `U-Axis (Dep)` field selector.
"""
function _setup_chain_B!(::Val{:eulerian})
    w = manager.widgets
    x_sel, y_sel, z_sel = w[:x_axis].selection, w[:y_axis].selection, w[:z_axis].selection
    active_axes_obs = manager.active_axes

    manager.listeners[:Eulerian_Chain_B] = onany(x_sel, y_sel, z_sel, manager.plot_data) do x_val, y_val, z_val, plot_data_dict
        @with_lock :Menu_B begin
            isempty(plot_data_dict) && return

            pd_first = first(values(plot_data_dict))
            sim_data = _get_first_valid(pd_first)
            isnothing(sim_data) && return
            
            axes_set = Set{Int}()
            active_axes_syms = filter(s -> !isnothing(s) && s != :none, [x_val, y_val, z_val])
            active_loop_dims = Symbol[]
            
            for val in active_axes_syms
                loop_dim = occursin("|", string(val)) ? Symbol(split(string(val), "|")[2]) : val
                push!(active_loop_dims, loop_dim)
                idx = findfirst(isequal(loop_dim), manager.plot_vars)
                !isnothing(idx) && push!(axes_set, idx)
            end
            
            active_physical_axes = filter(a -> a in sim_data.domain.dim_keys, active_loop_dims)
            valid_fields = Any[]
            
            if issubset(active_physical_axes, sim_data.domain.dim_keys)
                push!(valid_fields, ("Solution", :Solution))
            end
            
            for k in keys(sim_data.stats)
                k === :Solution && continue
                kept_syms = PDEStudioCore.get_kept_dims(k, sim_data.domain)
                if issubset(active_physical_axes, kept_syms)
                    push!(valid_fields, menu_opt(k))
                end
            end
            
            sort!(valid_fields, by = x -> x[1])
            update_menu_safe!(w[:u_axis], valid_fields; fallbacks=[:Solution], force_notify=false)
            
            active_axes_obs.val = collect(axes_set)
            notify(active_axes_obs)
        end
    end
end

"""
    _setup_chain_B!(::Val{:lagrangian})

The Lagrangian variant of Chain B. Because particles lack rigid meshes, it filters the available dependent fields strictly based on matching the spatial keys of the underlying domain.
"""
function _setup_chain_B!(::Val{:lagrangian})
    w = manager.widgets
    active_axes_obs = manager.active_axes

    manager.listeners[:Lagrangian_Chain_B] = onany(w[:x_axis].selection, w[:y_axis].selection, w[:z_axis].selection, manager.plot_data) do x_val, y_val, z_val, plot_data_dict
        @with_lock :Menu_B begin
            isempty(plot_data_dict) && return
            
            pd_first = first(values(plot_data_dict))
            l_data = _get_first_valid(pd_first)
            isnothing(l_data) && return
            
            spatial_keys = filter(k -> k != l_data.domain.time_dim, l_data.domain.dim_keys)

            valid_fields = Any[]
            if issubset(spatial_keys, l_data.domain.dim_keys)
                push!(valid_fields, menu_opt(:Solution))
            end
            
            for k in keys(l_data.stats)
                k === :Solution && continue
                kept_syms = PDEStudioCore.get_kept_dims(k, l_data.domain)
                if issubset(spatial_keys, kept_syms)
                    push!(valid_fields, menu_opt(k))
                end
            end
            sort!(valid_fields, by = x -> x[1])
            update_menu_safe!(w[:u_axis], valid_fields; fallbacks=[:Solution], force_notify=false)
            
            axes_set = Set{Int}()
            idx_x = findfirst(isequal(x_val), manager.plot_vars); !isnothing(idx_x) && push!(axes_set, idx_x)
            if y_val != :none
                idx_y = findfirst(isequal(y_val), manager.plot_vars); !isnothing(idx_y) && push!(axes_set, idx_y)
            end
            if z_val != :none
                idx_z = findfirst(isequal(z_val), manager.plot_vars); !isnothing(idx_z) && push!(axes_set, idx_z)
            end
            
            active_axes_obs.val = collect(axes_set)
            notify(active_axes_obs)
        end
    end
end

# ==============================================================================
# --- CHAIN C: Unified Component Extraction ---
# ==============================================================================

"""
    _setup_chain_C!(mode::Val{T}) where T

The tertiary UI cascade. 

Monitors the selected `U-Axis (Dep)` field. If the user selects a multidimensional state vector (e.g., a fluid momentum vector with 3 components), it calculates the exact tensor depth and generates an appropriate number of "Component X" targets in the UI, allowing the user to scrub through the layers of the state vector.
"""
function _setup_chain_C!(mode::Val{T}) where T
    w = manager.widgets
    manager.listeners[:Chain_C] = onany(w[:u_axis].selection, manager.plot_data) do u_val, plot_data_dict
        @with_lock :Menu_C begin
            pd_first, sim_data = _get_active_sim_data(plot_data_dict)
            isnothing(sim_data) && return
            
            target_field = (isnothing(u_val) || u_val === :none) ? :Solution : u_val
            target_tensor = get(sim_data.stats, target_field, sim_data.stats[:Solution])
            
            comp_max = _get_component_num_plots(mode, target_tensor)
            
            c_options = Any[]
            for i in 1:comp_max
                sym = Symbol("component_$i")
                haskey(manager.labels, sym) || set_label!(sym, "Component $i")
                
                push!(c_options, (frontend_key(sym), i))
            end
            update_menu_safe!(w[:component], c_options; fallbacks=[1])
        end
    end
end