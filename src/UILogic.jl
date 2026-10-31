const _RANK_0 = (:none, :shared, :sweep, :config)   # structural menu entries; also reserved Advanced scope names

"""
    menu_option_rank(opt::Tuple)

Custom sorting algorithm for Makie dropdown menus. 

# Hierarchy
1. **Rank 0:** Structural fallbacks (e.g., `:none`), reserved names (`:shared`, `:sweep`, `:config`), and any keys strictly belonging to the active simulation parameter array (`manager.plot_vars`).
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
            if widget isa NumberBox
                _set_number!(widget, val)
                continue
            elseif widget isa StyleChoice
                _set_style!(widget, val)
                continue
            end
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

    # The result of a load is reported in the status line (and by the colour of the load button).
    function _handle_load(path)
        local structural
        try
            structural = load_and_apply_csv!(path)
        catch e
            @error "Failed to load $path" exception = (e, catch_backtrace())
            _status!("Loading $(basename(path)) failed: $(_short(sprint(showerror, e), 80))", :error)
            load_btn.buttoncolor[] = :lightcoral
            return
        end
        if structural
            load_btn.buttoncolor[] = :orange
            run_btn.buttoncolor[] = :orange
            _status!("$(basename(path)) changes the dimensions or slider count: Run Simulation rebuilds the window " *
                     "(save a preset first to keep the current settings).", :warn)
        else
            _status!("Loaded $(basename(path)). Run Simulation to apply it.", :ok)
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
        path = _box_text(path_box)
        if isempty(path)
            _report(:warn, "Enter a path or file name in the Name / path box first.")
            return
        end
        found = find_config_csv(path)
        if isnothing(found)
            _report(:warn, "CSV file '$path' not found.")
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

# ------------------------------------------------------------------------------
# Status line
# ------------------------------------------------------------------------------

const STATUS_COLORS = Dict(:info => RGBf(0.25, 0.25, 0.25), :ok => RGBf(0.0, 0.45, 0.15),
                           :warn => RGBf(0.8, 0.4, 0.0), :error => RGBf(0.8, 0.1, 0.1))
const STATUS_LINE_CHARS = 76   # characters per line of the status line (two lines)

"""
    _status!(msg, level = :info)

Shows `msg` in the status line below the tabs (`level`: `:info`, `:ok`, `:warn` or `:error`, which sets the colour).
Long messages are wrapped at a space and shortened to two lines. A no-op without an open window.
"""
function _status!(msg::AbstractString, level::Symbol = :info)
    w = manager.widgets
    haskey(w, :status) || return nothing
    w[:status_color][] = get(STATUS_COLORS, level, STATUS_COLORS[:info])
    w[:status][] = _wrap_status(replace(String(msg), '\n' => ' '))
    return nothing
end

# Breaks a message into at most two lines of `STATUS_LINE_CHARS` (Makie's own word wrap centres the text).
function _wrap_status(text::String)
    n = STATUS_LINE_CHARS
    length(text) <= n && return text
    cut = something(findlast(' ', first(text, n + 1)), n + 1)
    line1, rest = rstrip(first(text, cut - 1)), lstrip(text[nextind(text, 0, cut):end])
    length(rest) > n && (rest = first(rest, n - 1) * "…")
    return line1 * "\n" * rest
end

# Logs a message and shows it in the status line.
function _report(level::Symbol, msg::AbstractString)
    if level === :error
        @error msg
    elseif level === :warn
        @warn msg
    else
        @info msg
    end
    _status!(msg, level)
    return nothing
end

# Shortens a value for a status message.
_short(s::AbstractString, n::Int = 40) = length(s) > n ? first(s, n - 1) * "…" : s

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

# Whether a block or layout sits exactly in `parent[row, cols]`.
function _is_at(item, parent::GridLayout, row::Int, cols)
    gc = Makie.GridLayoutBase.gridcontent(item)
    return !isnothing(gc) && gc.parent === parent && gc.span.rows == row:row && gc.span.cols == (cols isa Int ? (cols:cols) : cols)
end

# Places a block or layout in `parent[row, cols]` (moving it only if it isn't there yet) and draws it.
function _place!(item, parent::GridLayout, row::Int, cols)
    _is_at(item, parent, row, cols) || (parent[row, cols] = item)
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

Selects a tab of the control panel (`:plot`, `:methods`, `:shared`, `:ui`, `:files`, `:advanced`). The panels of
the tab (`TAB_PANELS`) are placed in the tab area and drawn; every other panel is hidden and parked in a layout
outside the figure, where it can't be clicked. Widgets are never deleted or recreated. The editor tabs show the
editor page last opened in their category (see `show_editor_page!`). A no-op
without an open window.
"""
function show_tab!(tab::Symbol)
    haskey(TAB_PANELS, tab) || throw(ArgumentError("unknown tab :$tab (tabs: $(join(CONTROL_TABS, ", ")))"))
    area = manager.tab_area
    (isnothing(area) || isnothing(manager.panel_park)) && return nothing

    shown = _tab_panels(tab)
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
    _render_editor!()
    return nothing
end

# The panels a tab shows: the Files and Plot tabs show the editor while one of their pages is open.
_tab_panels(tab) = haskey(TAB_EDITOR_PAGES, tab) && _editor_tab(tab) ? (:editor,) : TAB_PANELS[tab]

# Whether a tab shows the editor: the editor tabs, and the Files / Plot tab with a page open (`TAB_EDITOR_PAGES`).
_editor_tab(tab) = tab in EDITOR_TABS ||
                   (haskey(TAB_EDITOR_PAGES, tab) && first(get(manager.editor_view, tab, (nothing, 1))) in TAB_EDITOR_PAGES[tab])

# The mode of the editor page shown in the active tab (see `_editor_mode`), or `nothing`.
function _active_editor_mode()
    tab = manager.active_tab[]
    _editor_tab(tab) || return nothing
    return _editor_mode(tab, first(_view(tab)))
end

# The page (scope, page number) shown in a tab; the Shared tab has only one page.
_default_scope(tab) = tab === :shared ? :shared : nothing
_view(tab) = get(manager.editor_view, tab, (_default_scope(tab), 1))

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

# The dictionary (or dictionary-like view) the editor edits for a category and scope.
function _editor_target(cat, scope)
    if cat === :simulation   # the Shared tab and the method pages of the Methods tab
        config = manager.active_config
        isnothing(config) && return nothing
        scope === :shared && return config.shared
        return get(config.methods, scope, nothing)
    elseif cat === :ui
        return get(manager.ui, _ui_template_scope(scope), nothing)   # a plot type's page edits `plot_style`
    elseif cat === :labels
        return manager.labels
    end
    return nothing
end

_editor_display(v) = isnothing(v) ? "none" : val2str(v)

# The text the editor shows for `target[key]`.
_editor_text(target, key) = _editor_display(target[key])

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
        target = scope === :shared ? base.shared : get(base.methods, scope, nothing)
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

# Flags or triggers whatever an editor change requires.
function _after_editor_change!(cat, scope, key, target)
    if cat === :simulation
        manager.flags[:Simulation][] = true
    elseif cat === :ui
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
        end
        manager.triggers[:UI][] += 1
    end
    return nothing
end

# The editor category of a tab: the Methods and Shared tabs edit the simulation configuration, the Files tab the
# export settings.
_data_cat(tab) = tab in (:methods, :shared) ? :simulation : tab === :files ? :ui : tab   # (:plot: the plot styles)


# Display names of the fixed scopes; UI scopes and keys use their frontend names, simulation keys their exact names.
const _SCOPE_LABELS = Dict(:shared => "Shared", :sweep => "Sweep", :config => "Config",
                           :components => "Components", :variables => "Variables", :methods => "Methods",
                           :export => "Export settings",
                           :x_axis_1d => "X Axis (1D)", :y_axis_1d => "Y Axis (1D)", :x_axis_nd => "X Axis (2D/3D)",
                           :y_axis_nd => "Y Axis (2D/3D)", :z_axis_3d => "Z Axis (3D)",
                           :heatmap_flat => "Heatmap Flat", :heatmap_surface => "Heatmap Surface",
                           :scatter_surface => "Scatter Surface", :volume_3d => "Volume")

"""
    _editor_sections(cat)

The overview of an editor category: titled groups of pages (scopes). UI: *General* (fonts, HUD, outliers), *Labels*
(the titles and axis labels of the plot, the display names of components, variables and methods), *Axes* (every axis variant: 1D, 2D/3D, Z) and *Plot styles* (one page per plot type
of the mode, each with the options that type uses). Advanced: the raw scopes of the `SimulationConfig` (`shared`,
`varied`, the fields) and the list of all methods.
"""
function _editor_sections(cat)
    if cat === :ui
        general = Symbol[s for s in UI_GENERAL_SCOPES if s !== :labels]
        return Pair{String, Vector{Symbol}}["General" => general,
                                            "Labels" => Symbol[:labels, _LABEL_SCOPES...],
                                            "Axes" => Symbol[UI_AXIS_SCOPES...],
                                            "Plot styles" => _plot_style_scopes()]
    elseif cat === :plot
        return _plot_style_sections()
    elseif cat === :advanced
        config = manager.active_config
        isnothing(config) && return Pair{String, Vector{Symbol}}[]
        return Pair{String, Vector{Symbol}}["" => Symbol[:shared, :sweep, :config, ADV_METHODS]]
    end
    return Pair{String, Vector{Symbol}}[]
end

# The plot styles of the mode, one titled group per base plot, without the ones the data doesn't allow.
function _plot_style_sections()
    opts = manager.mode[] == :eulerian ? EULERIAN_PLOT_STYLE_OPTIONS : LAGRANGIAN_PLOT_STYLE_OPTIONS
    bases = manager.mode[] == :eulerian ? (:lines, :scatter, :contour, :heatmap, :volume) : (:scatter,)
    allowed = manager.allowed_styles
    sections = Pair{String, Vector{Symbol}}[]
    for b in bases
        styles = Symbol[o[2] for o in opts[b] if isempty(allowed) || o[2] in allowed]
        isempty(styles) || push!(sections, frontend_key(b) => styles)
    end
    return sections
end

# The display name of a plot type (the menu names of some only make sense next to their base plot, e.g. "Flat").
_style_label(style::Symbol) = get(_SCOPE_LABELS, style, frontend_key(style))

"""
    _choose_plot_style!(style)

Selects a plot type from the page of all plot styles, returns to the Plot tab and flags *Apply Layout*.
"""
function _choose_plot_style!(style::Symbol)
    sc = manager.widgets[:plot_style]
    changed = sc.selection[] != style
    _set_style!(sc, style)
    show_editor_page!(:plot)
    changed && _status!("Plot style: $(_style_label(style)). Apply Layout to redraw.", :ok)
    return nothing
end

"""
    _set_allowed_styles!(styles)

Limits the plot styles offered by the Plot tab to `styles` (e.g. the scatter styles matching the dimension of
Lagrangian data); the plot style falls back to the first one if the current one isn't among them.
"""
function _set_allowed_styles!(styles::Vector{Symbol})
    manager.allowed_styles = styles
    sc = manager.widgets[:plot_style]
    sc.selection[] in styles || _set_style!(sc, first(styles))
    _render_editor!()
    return nothing
end

# Every page of the overview of an editor category.
_editor_scopes(cat) = reduce(vcat, last.(_editor_sections(cat)); init = Symbol[])

# The plot types of the mode, grouped by base plot.
function _plot_style_scopes()
    groups = manager.mode[] == :eulerian ?
             [EULERIAN_PLOT_STYLE_OPTIONS[b] for b in (:lines, :scatter, :contour, :heatmap, :volume)] :
             [LAGRANGIAN_PLOT_STYLE_OPTIONS[:scatter]]
    return Symbol[o[2] for opts in groups for o in opts]
end

# Whether the page of a UI scope belongs to the active plot (the active plot type and its axis variants).
function _ui_scope_active(scope)
    ptype = manager.active_plot_type
    scope === ptype && return true
    scope in UI_AXIS_SCOPES || return false
    scope === :z_axis_3d && return get(PLOT_DIM_MAP, ptype, 1) == 3 || is_surface(ptype)
    return scope in (_ui_template_scope(:x_axis), _ui_template_scope(:y_axis))
end

"""
    _editor_keys(cat, scope)

The keys of an editor page, in row order (sorted). The page of a plot type lists the options that type uses
(`STYLE_DEPENDENCIES`). Labels get their built-in display name if they have none yet.
"""
function _editor_keys(cat, scope)
    if cat === :labels
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
    cat === :ui && haskey(STYLE_DEPENDENCIES, scope) && filter!(in(STYLE_DEPENDENCIES[scope]), ks)
    return Any[ks...]
end

_scope_label(cat, scope) = cat === :ui && scope === :labels ? "Plot" :   # the titles and axis labels of the plot
                          get(_SCOPE_LABELS, scope, cat === :simulation ? string(scope) : menu_opt(scope)[1])

# The editor category of a page: the UI tab also shows the display names (Labels: components, variables, methods).
_scope_cat(tab, scope) = tab === :ui && scope in _LABEL_SCOPES ? :labels : _data_cat(tab)
const _LABEL_SCOPES = (:components, :variables, :methods)
_key_label(cat, scope, key) = cat === :ui && key isa Symbol ? menu_opt(key)[1] : string(key)

# The label of a page button: the scope and (except in the static UI overview) its number of entries.
function _scope_button_label(cat, scope)
    cat === :plot && return _style_label(scope)
    if cat === :advanced
        scope === ADV_METHODS && return "Methods ($(isnothing(manager.active_config) ? 0 : length(manager.active_config.methods))) ›"
        return "$(_scope_label(:simulation, scope)) ($(length(_raw_keys(scope))))"
    end
    cat === :ui && return _scope_label(cat, scope)
    return "$(_scope_label(cat, scope)) ($(length(_editor_keys(cat, scope))))"
end

# What the button of a row does: toggle a Bool, or restore the default.
function _row_action(cat, scope, target, key)
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

# What the editor shows for a tab and scope: the overview, the rows of a page, the method list / drawing order of the
# Methods tab, the preset list / a preset file of the Files tab, or the raw rows of the Advanced tab.
function _editor_mode(tab, scope)
    if tab === :files
        scope === PRESET_LIST && return :preset_list
        scope === PRESET_FILE && return :preset_file
        scope === RESOLUTION_SETTINGS && return :resolution
        return :rows                     # the export settings
    end
    tab === :plot && return :overview    # the plot styles
    tab === :shared && return :rows      # the one page of the Shared tab
    if tab === :advanced
        isnothing(scope) && return :overview
        scope === ADV_METHODS && return :adv_method_list
        return :raw_rows
    end
    if tab === :methods
        isnothing(scope) && return :method_list
        scope === ORDER_VIEW && return :method_order
        return :rows
    end
    return isnothing(scope) ? :overview : :rows
end

# Whether `scope` is (still) a page of the tab, e.g. not a method that was removed.
function _editor_scope_valid(tab, scope)
    tab === :files && scope === PRESET_FILE && return !isnothing(_preset_rows(manager.preset_kind, manager.preset_name))
    haskey(TAB_EDITOR_PAGES, tab) && return scope in TAB_EDITOR_PAGES[tab]
    tab === :shared && return scope === :shared && !isnothing(manager.active_config)
    if tab === :advanced && !isnothing(scope)
        config = manager.active_config
        return !isnothing(config) && (scope in (:shared, :sweep, :config, ADV_METHODS) || haskey(config.methods, scope))
    end
    isnothing(scope) && return true
    if tab === :methods
        config = manager.active_config
        isnothing(config) && return false
        return scope === ORDER_VIEW || haskey(config.methods, scope)
    end
    return scope in _editor_scopes(tab)
end

"""
    _method_items(mode)

The methods listed by the Methods tab: every method of the configuration in the automatic order (references first,
then alphabetical, like the `permutation` key), filtered by `manager.method_filter` (`:active`, `:disabled` or
`:all`); in the drawing order view (`mode = :method_order`) the active methods (`defaults`) in their order.
"""
function _method_items(mode)
    config = manager.active_config
    isnothing(config) && return Symbol[]
    active = Symbol[Symbol(m) for m in unique(config.defaults)]
    mode === :method_order && return active
    ms = filter(m -> !(m in _RANK_0), sort_methods_robust(collect(keys(config.methods))))
    manager.method_filter === :active && return filter(in(active), ms)
    manager.method_filter === :disabled && return filter(!in(active), ms)
    return ms
end

const _ROW_GREEN = RGBf(0.56, 0.93, 0.56)
const _ROW_GREY = RGBf(0.83, 0.83, 0.83)
const _ROW_NEUTRAL = RGBf(0.92, 0.92, 0.92)
const _ROW_FAINT = RGBf(0.97, 0.97, 0.97)

# Binds method row `i`: name, active/off and Edit (list), or position and ▲ ▼ (drawing order of `n` methods).
function _bind_method_row!(i::Int, mode, m::Symbol, pos::Int, n::Int)
    w = manager.widgets
    a, b = w[Symbol("method_row_", i, "_a")], w[Symbol("method_row_", i, "_b")]
    if mode === :method_list
        active = m in manager.active_config.defaults
        w[Symbol("method_row_", i, "_label")][] = string(m)
        a.label[] = active ? "active" : "off"
        a.buttoncolor[] = active ? _ROW_GREEN : _ROW_GREY
        b.label[] = "Edit ›"
        b.buttoncolor[] = _ROW_NEUTRAL
    else
        w[Symbol("method_row_", i, "_label")][] = "$pos.  $m"
        a.label[] = "▲"
        b.label[] = "▼"
        a.buttoncolor[] = pos == 1 ? _ROW_FAINT : _ROW_NEUTRAL
        b.buttoncolor[] = pos == n ? _ROW_FAINT : _ROW_NEUTRAL
    end
    return nothing
end

# --- Files tab: presets -------------------------------------------------------------------------------------------

# The saved presets of a kind (`:simulation`, `:visual`), sorted.
_preset_items(kind::Symbol) = sort!(collect(keys(_preset_kind_registry(kind))))

# Binds item row `i` to a preset: name and description, Apply and Edit (built-in presets have no file to edit).
function _bind_preset_row!(i::Int, kind::Symbol, name::Symbol)
    w = manager.widgets
    desc = get(_preset_kind_registry(kind), name, "")
    w[Symbol("method_row_", i, "_label")][] = _short("$name  ·  $desc", 52)
    a, b = w[Symbol("method_row_", i, "_a")], w[Symbol("method_row_", i, "_b")]
    a.label[] = "Apply"
    a.buttoncolor[] = _ROW_GREEN
    b.label[] = "Edit ›"
    b.buttoncolor[] = isnothing(_preset_file(_preset_kind_dir(kind), name)) ? _ROW_FAINT : _ROW_NEUTRAL
    return nothing
end

# Binds editor row `i` to row `idx` of the open preset file: scope and key, the value as written, ✕ to delete.
function _bind_preset_file_row!(i::Int, idx::Int)
    w = manager.widgets
    r = manager.preset_file_rows[idx]
    w[Symbol("editor_row_", i, "_label")][] = r[1] == "Metadata" ? r[3] : "$(r[2]) · $(r[3])"
    _show_editor_text!(w[Symbol("editor_row_", i, "_text")], r[4])
    btn = w[Symbol("editor_row_", i, "_button")]
    btn.label[] = "✕"
    btn.buttoncolor[] = RGBf(1.0, 0.85, 0.85)
    return nothing
end

# Applies (`which = :a`) or opens the file (`:b`) of the preset bound to item row `i`.
function _preset_row_action!(i::Int, which::Symbol)
    i <= length(manager.editor_row_keys) || return nothing
    name, kind = manager.editor_row_keys[i], manager.preset_kind
    if which === :a
        ok = kind === :simulation ? !isnothing(set_sim_preset!(name)) : set_plot_preset!(name) !== false
        ok ? _status!("Applied $(kind === :simulation ? "simulation" : "look") preset '$name'." *
                      (kind === :simulation ? " Run Simulation to compute it." : ""), :ok) :
             _status!("Preset '$name' could not be applied (see the log).", :warn)
        _render_editor!()
    elseif isnothing(_preset_file(_preset_kind_dir(kind), name))
        _report(:warn, "'$name' is built in and has no file: apply it and save it under a new name to edit it.")
    else
        manager.preset_name = name
        show_editor_page!(:files, PRESET_FILE)
    end
    return nothing
end

# Writes the rows of the open preset file and reports `msg`.
function _store_preset_file!(msg::AbstractString)
    if _write_preset_rows!(manager.preset_kind, manager.preset_name, manager.preset_file_rows)
        _status!("Preset '$(manager.preset_name)': $msg", :ok)
    else
        _report(:warn, "Preset '$(manager.preset_name)' has no file any more.")
    end
    _render_editor!()
    return nothing
end

function _set_preset_value!(i::Int, s::AbstractString)
    i <= length(manager.editor_row_keys) || return nothing
    r = manager.preset_file_rows[manager.editor_row_keys[i]]
    r[4] = String(strip(s))
    _store_preset_file!("$(r[2]) · $(r[3]) = $(_short(r[4]))")
end

function _delete_preset_row!(i::Int)
    i <= length(manager.editor_row_keys) || return nothing
    r = manager.preset_file_rows[manager.editor_row_keys[i]]
    deleteat!(manager.preset_file_rows, manager.editor_row_keys[i])
    _store_preset_file!("removed $(r[2]) · $(r[3])")
end

"""
    _add_preset_row!()

Adds the row typed into the add-row of a preset file page: `Category, Scope` (a simulation preset may give only the
scope, e.g. `Shared`), key and value (as written in the file, e.g. `40`, `upwind`, `[0.1, 0.2]`). An existing
entry with the same category, scope and key gets the new value.
"""
function _add_preset_row!()
    w = manager.widgets
    parts = strip.(split(_box_text(w[:preset_add_scope]), ','))
    key, value = _box_text(w[:preset_add_key]), _box_text(w[:preset_add_value])
    if length(parts) == 1 && manager.preset_kind === :simulation
        parts = ["Simulation", parts[1]]
    end
    if length(parts) != 2 || any(isempty, parts) || isempty(key)
        _report(:warn, "Give the category and scope (e.g. `Simulation, Shared` or `UI, hud`) and a key.")
        return nothing
    end
    rows = manager.preset_file_rows
    existing = findfirst(r -> r[1] == parts[1] && r[2] == parts[2] && r[3] == key, rows)
    isnothing(existing) ? push!(rows, String[parts[1], parts[2], key, value]) : (rows[existing][4] = value)
    foreach(k -> Makie.reset!(w[k]), (:preset_add_key, :preset_add_value))
    _store_preset_file!("$(parts[2]) · $key = $(_short(value))")
end

# --- Advanced tab: the SimulationConfig itself ------------------------------------------------------------------

const _RAW_CONFIG_FIELDS = (:defaults, :reference, :postprocess, :sources)

# The dictionary of a raw scope (`:shared`, `:sweep` = `varied`, a method), or the config itself for `:config`.
function _raw_target(scope)
    config = manager.active_config
    isnothing(config) && return nothing
    scope === :shared && return config.shared
    scope === :sweep && return config.varied
    scope === :config && return config
    return get(config.methods, scope, nothing)
end

function _raw_keys(scope)
    scope === :config && return Any[_RAW_CONFIG_FIELDS...]
    target = _raw_target(scope)
    return isnothing(target) ? Any[] : Any[sort!(collect(keys(target)), by = string)...]
end

_raw_value(scope, key) = scope === :config ? getproperty(manager.active_config, key) : _raw_target(scope)[key]

# A value exactly as stored: a Julia literal with its type (`20`, `0.5`, `"text"`, `:sym`, `Float64[0.1, 0.2]`).
_raw_text(v) = isnothing(v) ? "nothing" : val2str(v; top_level = false)

# Parses a raw literal; text must be quoted (anything that is no literal is refused).
function _parse_raw(s::AbstractString)
    txt = strip(s)
    v = str2val(txt)
    v isa AbstractString && !startswith(txt, '"') && return (false, nothing)
    return (true, v)
end

const _RAW_HINT = "Raw values are Julia literals: 20, 0.5, \"text\", :symbol, [1, 2], (1, 2), nothing."

function _after_raw_change!(scope, msg::AbstractString)
    manager.flags[:Simulation][] = true
    scope === :sweep && _map_parameters_to_sliders!(manager.active_config)
    _status!("$msg. Run Simulation to apply.", :ok)
    _render_editor!()
    return nothing
end

function _bind_raw_row!(i::Int, scope, key)
    w = manager.widgets
    w[Symbol("editor_row_", i, "_label")][] = string(key)
    _show_editor_text!(w[Symbol("editor_row_", i, "_text")], _raw_text(_raw_value(scope, key)))
    btn = w[Symbol("editor_row_", i, "_button")]
    deletable = scope !== :config
    btn.label[] = deletable ? "✕" : " "
    btn.buttoncolor[] = deletable ? RGBf(1.0, 0.85, 0.85) : _ROW_FAINT
    return nothing
end

"""
    _apply_raw_input!(scope, key, s)

Advanced tab: stores the literal `s` in the scope as it is: no text fallback, no sweep conversion, no views. The
value must be a Julia literal (text in quotes); a sweep must be a vector. Flags *Run Simulation*.
"""
function _apply_raw_input!(scope, key, s::AbstractString)
    ok, v = _parse_raw(s)
    if !ok
        _report(:warn, "'$key' was not changed: '$(_short(String(strip(s)), 30))' is no literal. $_RAW_HINT")
        return _render_editor!()
    end
    if scope === :sweep && !(v isa AbstractVector)
        _report(:warn, "'$key' was not changed: a sweep is a vector, e.g. [0.1, 0.2].")
        return _render_editor!()
    end
    try
        scope === :config ? setproperty!(manager.active_config, key, v) : (_raw_target(scope)[key] = v)
    catch e
        _report(:warn, "'$key' was not changed: $(_short(sprint(showerror, e), 80))")
        return _render_editor!()
    end
    _after_raw_change!(scope, "$(_scope_label(:simulation, scope)) → $key = $(_short(_raw_text(v)))")
end

function _delete_raw_key!(scope, key)
    scope === :config && return nothing   # the fields of the configuration can't be removed
    delete!(_raw_target(scope), key)
    _after_raw_change!(scope, "Removed $key from $(_scope_label(:simulation, scope))")
end

"""
    _typed_value(T, s)

The value of `s` as type `T` (`RAW_VALUE_TYPES`): `:auto` reads the literal (text in quotes), `:String` and
`:Symbol` take the text as it is, the number and Bool types parse it, vectors convert each entry (`[a, b]` works for
`Vector{Symbol}` and `Vector{String}`), `:Tuple` accepts a tuple or vector literal. Throws an `ArgumentError` with a
readable message otherwise.
"""
function _typed_value(T::Symbol, s::AbstractString)
    txt = String(strip(s))
    unquote(x) = (m = match(r"^\"(.*)\"$"s, x); isnothing(m) ? x : String(m.captures[1]))
    if T === :auto
        ok, v = _parse_raw(txt)
        ok || throw(ArgumentError("'$(_short(txt, 30))' is no literal: choose a type or quote text"))
        return v
    end
    T === :String && return unquote(txt)
    T === :Symbol && return Symbol(lstrip(unquote(txt), ':'))
    for (name, R) in ((:Int, Int), (:Float64, Float64), (:Bool, Bool))
        T === name || continue
        v = tryparse(R, txt)
        isnothing(v) && throw(ArgumentError("'$(_short(txt, 30))' is no $R"))
        return v
    end
    v = str2val(txt)
    if v isa AbstractString   # e.g. [a, b]: bare words
        m = match(r"^\[(.*)\]$"s, txt)
        isnothing(m) && throw(ArgumentError("'$(_short(txt, 30))' is no vector, e.g. [1, 2]"))
        v = Any[unquote(String(strip(x))) for x in split(m.captures[1], ',') if !isempty(strip(x))]
    end
    if T === :Tuple
        v isa Tuple && return v
        v isa AbstractVector && return Tuple(v)
        throw(ArgumentError("'$(_short(txt, 30))' is no tuple, e.g. (1, 2)"))
    end
    v isa AbstractVector || throw(ArgumentError("'$(_short(txt, 30))' is no vector, e.g. [1, 2]"))
    conv = Dict(Symbol("Vector{Float64}") => x -> Float64(x isa AbstractString ? parse(Float64, x) : x),
                Symbol("Vector{Int}") => x -> Int(x isa AbstractString ? parse(Int, x) : x),
                Symbol("Vector{Symbol}") => x -> Symbol(lstrip(string(x), ':')),
                Symbol("Vector{String}") => x -> string(x))
    haskey(conv, T) || throw(ArgumentError("unknown type $T"))
    try
        return [conv[T](x) for x in v]
    catch
        throw(ArgumentError("the entries of '$(_short(txt, 30))' can't be converted to $T"))
    end
end

"""
    _add_raw_key!()

Advanced tab: adds the key typed into the add-row to the open scope, with the value converted to the chosen type
(see `_typed_value`). Refuses keys that exist (edit their row) and sweeps that aren't vectors.
"""
function _add_raw_key!()
    w = manager.widgets
    scope = first(get(manager.editor_view, :advanced, (nothing, 1)))
    target = _raw_target(scope)
    (isnothing(target) || scope === :config) && return nothing
    name = lstrip(_box_text(w[:raw_add_key]), ':')
    if isempty(name)
        return _report(:warn, "Type the name of the new key.")
    end
    key = Symbol(name)
    haskey(target, key) && return _report(:warn, "'$key' exists already: edit its row.")
    T = something(w[:raw_add_type].selection[], :auto)
    v = try
        _typed_value(T, _box_text(w[:raw_add_value]))
    catch e
        return _report(:warn, "'$key' was not added: " * (e isa ArgumentError ? e.msg : sprint(showerror, e)))
    end
    scope === :sweep && !(v isa AbstractVector) && return _report(:warn, "'$key' was not added: a sweep is a vector.")
    target[key] = v
    foreach(k -> Makie.reset!(w[k]), (:raw_add_key, :raw_add_value))
    _after_raw_change!(scope, "Added $key = $(_short(_raw_text(v))) to $(_scope_label(:simulation, scope))")
end

# Advanced method list: adds an (inactive) method with no parameter overrides and opens it.
function _add_method!()
    config = manager.active_config
    isnothing(config) && return nothing
    w = manager.widgets
    name = lstrip(_box_text(w[:method_add_name]), ':')
    isempty(name) && return _report(:warn, "Type the name of the new method.")
    m = Symbol(name)
    (haskey(config.methods, m) || m in _RANK_0) && return _report(:warn, "'$m' exists already (or is a reserved name).")
    config.methods[m] = create_param_dict()
    Makie.reset!(w[:method_add_name])
    manager.flags[:Simulation][] = true
    _status!("Method $m added (inactive: activate it in the Methods tab).", :ok)
    show_editor_page!(:advanced, m)
end

# Advanced: removes a method from the configuration (and from the active methods).
function _delete_method!(m::Symbol)
    config = manager.active_config
    (isnothing(config) || !haskey(config.methods, m)) && return nothing
    delete!(config.methods, m)
    config.defaults = Symbol[x for x in config.defaults if x != m]
    manager.flags[:Simulation][] = true
    _status!("Method $m deleted. Run Simulation to apply.", :ok)
    _render_editor!()
end

# --- Files tab: the resolution of the data and the references -----------------------------------------------------

# Points per dimension the studio resamples to; the time dimension is coarser (see `_sync_resolution_dims!`).
_default_resolution(dim::Symbol, is_ref::Bool) = is_ref ? (dim === :t ? 100 : 400) : (dim === :t ? 50 : 200)

# The rows of the resolution page: every dimension for the data, then for the references.
_resolution_items() = Any[[(d, false) for d in manager.allowed_dims]; [(d, true) for d in manager.allowed_dims]]

function _bind_resolution_row!(i::Int, item)
    dim, is_ref = item
    w = manager.widgets
    w[Symbol("editor_row_", i, "_label")][] = "$(frontend_key(dim))  ·  $(is_ref ? "reference" : "data")"
    _show_editor_text!(w[Symbol("editor_row_", i, "_text")], string(get_resolution(dim; is_ref = is_ref)))
    btn = w[Symbol("editor_row_", i, "_button")]
    btn.label[] = "↺"
    btn.buttoncolor[] = _ROW_NEUTRAL
    return nothing
end

"""
    _set_resolution_from_ui!(item, s)

Sets the resolution (points per dimension) of the data or the references of a dimension (`set_resolution!`) from
the Resolution page of the Files tab (`"default"` restores the default) and flags *Run Simulation*, which reloads
the data at the new resolution (resampled representations are cached).
"""
function _set_resolution_from_ui!(item, s::AbstractString)
    dim, is_ref = item
    txt = strip(s)
    n = txt == "default" ? _default_resolution(dim, is_ref) : tryparse(Int, txt)
    if isnothing(n) || !(2 <= n <= 100_000)
        _report(:warn, "The resolution is a whole number of points (2 to 100000), not '$(_short(String(txt), 20))'.")
    else
        set_resolution!(dim, n; is_ref = is_ref)
        manager.flags[:Simulation][] = true
        _status!("Resolution of $(frontend_key(dim)) ($(is_ref ? "references" : "data")): $n. Run Simulation to reload.", :ok)
    end
    _render_editor!()
    return nothing
end

# --- Advanced tab: the list of all methods -----------------------------------------------------------------------

_adv_method_items() = isnothing(manager.active_config) ? Symbol[] :
                      filter(m -> !(m in _RANK_0), sort_methods_robust(collect(keys(manager.active_config.methods))))

function _bind_adv_method_row!(i::Int, m::Symbol)
    w = manager.widgets
    active = m in manager.active_config.defaults
    w[Symbol("method_row_", i, "_label")][] = active ? "$m  (active)" : string(m)
    a, b = w[Symbol("method_row_", i, "_a")], w[Symbol("method_row_", i, "_b")]
    a.label[] = "Edit ›"
    a.buttoncolor[] = _ROW_NEUTRAL
    b.label[] = "✕"
    b.buttoncolor[] = RGBf(1.0, 0.85, 0.85)
    return nothing
end

"""
    _render_editor!()

Binds the editor widgets to the page selected in the active editor tab (`manager.editor_view[tab]`): the overview
(one button per scope, see `_editor_scopes`), the rows of a scope (one per key, see `_editor_keys`) or, in the
Methods tab, the method list or the drawing order (see `_method_items`); `EDITOR_ROWS` rows (`OVERVIEW_BUTTONS`
buttons) per page. Unused buttons and rows are parked. A scope that no longer exists falls back to the overview.
A no-op outside the editor tabs, so it can be called after any change.
"""
function _render_editor!()
    tab = manager.active_tab[]
    (_editor_tab(tab) && haskey(manager.panels, :editor_rows)) || return nothing
    w, p = manager.widgets, manager.panels
    scope, page = _view(tab)
    _editor_scope_valid(tab, scope) || ((scope, page) = (_default_scope(tab), 1))
    mode = _editor_mode(tab, scope)
    cat = _scope_cat(tab, scope)
    if mode === :preset_file
        manager.preset_file_rows = something(_preset_rows(manager.preset_kind, manager.preset_name), Vector{String}[])
    end
    items = mode === :overview ? _editor_scopes(cat) :
            mode === :rows ? _editor_keys(cat, scope) :
            mode === :preset_list ? _preset_items(manager.preset_kind) :
            mode === :preset_file ? Any[eachindex(manager.preset_file_rows)...] :
            mode === :raw_rows ? _raw_keys(scope) :
            mode === :resolution ? _resolution_items() :
            mode === :adv_method_list ? _adv_method_items() : _method_items(mode)
    per_page = mode === :overview ? max(OVERVIEW_BUTTONS, length(items)) : EDITOR_ROWS   # overviews are one page
    npages = max(1, cld(length(items), per_page))
    page = clamp(page, 1, npages)
    manager.editor_view[tab] = (scope, page)
    offset = (page - 1) * per_page
    page_items = items[offset + 1:min(offset + per_page, length(items))]

    config = manager.active_config
    title = if tab === :plot
        "Plot style"
    elseif tab === :shared
        "Shared parameters"
    elseif mode === :resolution
        "Resolution (points per dimension)"
    elseif tab === :advanced
        isnothing(scope) ? "Advanced: the SimulationConfig" :
        scope === ADV_METHODS ? "Methods (raw)" : "$(_scope_label(:simulation, scope))  (raw)"
    elseif mode === :overview
        TAB_LABELS[tab]
    elseif mode === :preset_list
        manager.preset_kind === :simulation ? "Simulation presets" : "Look presets"
    elseif mode === :preset_file
        "Preset: $(manager.preset_name)"
    elseif tab === :files
        "Export settings"
    elseif mode === :rows
        _scope_label(cat, scope)
    elseif mode === :method_order
        "Drawing order (top first)"
    else
        isnothing(config) ? "Methods" : "Methods  ($(length(unique(config.defaults))) of $(length(config.methods)) active)"
    end
    w[:editor_title][] = npages > 1 ? "$title  ($page/$npages)" : title

    # Panel rows: header, the tools of the Methods tab, body, the add-rows of the preset file / raw / method list pages
    in_methods = mode in (:method_list, :method_order)
    raw_dict = mode === :raw_rows && scope !== :config
    _pack!(p[:editor], [p[:editor_header], p[:editor_tools], p[:editor_body], p[:preset_add], p[:raw_add], p[:method_add]],
           [true, in_methods, true, mode === :preset_file, raw_dict, mode === :adv_method_list]; gap = 8)
    has_back = (mode in (:rows, :raw_rows, :preset_list, :preset_file, :resolution, :adv_method_list) || tab === :plot) &&
               tab !== :shared
    has_back ? _place!(p[:editor_back], p[:editor_header], 1, 1) : _park!(p[:editor_back])
    npages > 1 ? _place!(p[:editor_pager], p[:editor_header], 1, 3) : _park!(p[:editor_pager])
    if in_methods
        w[:method_filter].label[] = "Show: $(manager.method_filter)"
        w[:method_order].label[] = mode === :method_order ? "◀ Method list" : "Order ▲▼"
    end

    body_view = mode === :overview ? :editor_overview :
                mode in (:rows, :preset_file, :raw_rows, :resolution) ? :editor_rows : :method_rows
    for name in (:editor_overview, :editor_rows, :method_rows)
        name === body_view || _park!(p[name])
    end
    _place!(p[body_view], p[:editor_body], 1, 1)

    if mode === :overview
        manager.editor_row_keys = Any[]
        _render_overview!(cat)
    elseif mode in (:rows, :preset_file, :raw_rows, :resolution)
        manager.editor_page_scopes = Symbol[]
        manager.editor_row_keys = Any[page_items...]
        target = mode === :rows ? _editor_target(cat, scope) : nothing
        for (i, key) in enumerate(page_items)
            mode === :rows ? _bind_editor_row!(i, cat, scope, target, key) :
            mode === :preset_file ? _bind_preset_file_row!(i, key) :
            mode === :resolution ? _bind_resolution_row!(i, key) : _bind_raw_row!(i, scope, key)
        end
        rows = [p[Symbol("editor_row_", i)] for i in 1:EDITOR_ROWS]
        _pack!(p[:editor_rows], rows, [i <= length(page_items) for i in 1:EDITOR_ROWS]; gap = EDITOR_ROWGAP)
    else
        manager.editor_page_scopes = Symbol[]
        manager.editor_row_keys = Any[page_items...]
        for (i, m) in enumerate(page_items)
            mode === :preset_list ? _bind_preset_row!(i, manager.preset_kind, m) :
            mode === :adv_method_list ? _bind_adv_method_row!(i, m) :
                                        _bind_method_row!(i, mode, m, offset + i, length(items))
        end
        rows = [p[Symbol("method_row_", i)] for i in 1:EDITOR_ROWS]
        _pack!(p[:method_rows], rows, [i <= length(page_items) for i in 1:EDITOR_ROWS]; gap = EDITOR_ROWGAP)
    end
    return nothing
end

"""
    _render_overview!(cat)

Binds the page buttons of the overview to the sections of `cat` (see `_editor_sections`): a section title (if any)
spanning the row, then its buttons, `OVERVIEW_COLS` per row. The pages of the active plot (plot type and axis
variants) are highlighted. Unused buttons and titles are parked.
"""
function _render_overview!(cat)
    w, ov = manager.widgets, manager.panels[:editor_overview]
    buttons = [w[Symbol("editor_page_", j)] for j in 1:OVERVIEW_BUTTONS]
    titles = [w[Symbol("editor_section_", k)] for k in 1:OVERVIEW_SECTIONS]
    scopes = Symbol[]
    row, nb, nt = 0, 0, 0
    for (title, section) in _editor_sections(cat)
        if !isempty(title) && nt < OVERVIEW_SECTIONS
            nt += 1
            titles[nt].text[] = title
            _place!(titles[nt], ov, row += 1, 1:OVERVIEW_COLS)
        end
        for (i, s) in enumerate(section)
            nb < OVERVIEW_BUTTONS || break
            nb += 1
            push!(scopes, s)
            btn = buttons[nb]
            btn.label[] = _scope_button_label(cat, s)
            active = cat === :ui ? _ui_scope_active(s) : cat === :plot && s === manager.widgets[:plot_style].selection[]
            btn.buttoncolor[] = active ? RGBf(0.65, 0.78, 1.0) : RGBf(0.88, 0.92, 1.0)
            (i - 1) % OVERVIEW_COLS == 0 && (row += 1)
            _place!(btn, ov, row, (i - 1) % OVERVIEW_COLS + 1)
        end
    end
    foreach(_park!, buttons[nb + 1:end])
    foreach(_park!, titles[nt + 1:end])
    _trim_rows!(ov)
    size(ov)[1] > 1 && rowgap!(ov, EDITOR_ROWGAP)
    manager.editor_page_scopes = scopes
    return nothing
end

"""
    show_editor_page!(tab::Symbol, scope = nothing; page = 1)

Opens a page of the editor in the tab `tab`: in the UI tab the rows of `scope` (e.g. `:hud`, `:x_axis_nd`,
`:lines_1d`, `:methods` for the display names of the methods) or the overview (`scope = nothing`); the Shared tab has
one page; in the Methods tab a method, the drawing order (`ORDER_VIEW`) or the method list (`nothing`); in the
Advanced tab `:shared`, `:sweep`, `:config`, a method, the method list (`ADV_METHODS`) or the overview. In the Files
tab `EXPORT_SETTINGS`, `RESOLUTION_SETTINGS`, `PRESET_LIST` or `PRESET_FILE` (with `manager.preset_kind` /
`preset_name`), and `nothing` for the Files panel; in the Plot tab `STYLE_CHOOSER`, the page of all plot styles.
`page` selects the page of a long list. A no-op without an open window.
"""
function show_editor_page!(tab::Symbol, scope = nothing; page::Int = 1)
    (tab in EDITOR_TABS || haskey(TAB_EDITOR_PAGES, tab)) ||
        throw(ArgumentError("unknown editor tab :$tab (editor tabs: $(join((EDITOR_TABS..., keys(TAB_EDITOR_PAGES)...), ", ")))"))
    manager.editor_view[tab] = (scope, page)
    # the Files and Plot tabs switch between their panels and the editor
    manager.active_tab[] === tab && !haskey(TAB_EDITOR_PAGES, tab) ? _render_editor!() : show_tab!(tab)
    return nothing
end

# The page entry bound to row `i`: (category, scope, key, target), or `nothing`.
function _editor_row_binding(i::Int)
    tab = manager.active_tab[]
    _editor_tab(tab) || return nothing
    scope, _ = _view(tab)
    _editor_mode(tab, scope) === :rows || return nothing
    i > length(manager.editor_row_keys) && return nothing
    cat = _scope_cat(tab, scope)
    target = _editor_target(cat, scope)
    isnothing(target) && return nothing
    return (cat, scope, manager.editor_row_keys[i], target)
end

"""
    _set_method_active!(m, active) -> Bool

Activates (appends to `defaults`, the drawing order) or deactivates a method of the bound configuration and flags
*Run Simulation*. Returns whether something changed.
"""
function _set_method_active!(m::Symbol, active::Bool)
    config = manager.active_config
    isnothing(config) && return false
    defaults = Symbol[Symbol(x) for x in unique(config.defaults)]
    if active
        m in defaults && return false
        push!(defaults, m)
    else
        m in defaults || return false
        filter!(!=(m), defaults)
    end
    config.defaults = defaults
    manager.flags[:Simulation][] = true
    _status!("$m $(active ? "activated" : "deactivated"). Run Simulation to apply.", :ok)
    return true
end

"""
    _move_method!(m, step) -> Bool

Moves an active method `step` places in the drawing order (`defaults`; -1 is up) and flags *Run Simulation*.
Returns whether it moved.
"""
function _move_method!(m::Symbol, step::Int)
    config = manager.active_config
    isnothing(config) && return false
    defaults = Symbol[Symbol(x) for x in unique(config.defaults)]
    i = findfirst(isequal(m), defaults)
    j = isnothing(i) ? 0 : i + step
    1 <= j <= length(defaults) || return false
    defaults[i], defaults[j] = defaults[j], defaults[i]
    config.defaults = defaults
    manager.flags[:Simulation][] = true
    _status!("$m moved to position $j. Run Simulation to apply the order.", :ok)
    return true
end

# The buttons of method row `i`: active/off or Edit in the list, ▲ or ▼ in the drawing order.
function _method_row_action!(i::Int, which::Symbol)
    manager.active_tab[] === :methods || return nothing
    manager.locks[:Simulation] && return nothing
    scope, _ = get(manager.editor_view, :methods, (nothing, 1))
    mode = _editor_mode(:methods, scope)
    (mode in (:method_list, :method_order) && i <= length(manager.editor_row_keys)) || return nothing
    m = manager.editor_row_keys[i]
    if mode === :method_list
        which === :b && return show_editor_page!(:methods, m)
        _set_method_active!(m, !(m in manager.active_config.defaults))
    else
        _move_method!(m, which === :a ? -1 : 1)
    end
    _render_editor!()
    return nothing
end

"""
    _apply_editor_input!(cat, scope, key, target, s, tb) -> Bool

Applies text typed into the value box `tb` of a row to `target[key]`: `default` restores the default (see
`_editor_default`), labels are set as text, everything else is parsed with the safe literal parser
(`_parse_editor_input`, see `_valid_editor_value`). Colours are validated. Returns whether something changed; problems are reported as warnings.
"""
function _apply_editor_input!(cat, scope, key, target, s::AbstractString, tb)
    try
        if strip(s) == "default"
            val = _editor_default(cat, scope, key)
            if ismissing(val)
                _report(:warn, "No default value is known for '$key'.")
                return false
            end
            cat === :labels ? set_label!(key, string(val)) : (target[key] = val)
        elseif cat === :labels
            set_label!(key, String(s))
        else
            val = _parse_editor_input(s, target[key])
            if !_valid_editor_value(s, target, key, val)
                _report(:warn, "'$key' was not changed: '$(_short(String(strip(s)), 30))' is not a valid value. " *
                               "Use numbers, :symbols, [vectors], (tuples) or \"text\" in quotes.")
                return false
            end
            if cat === :ui && !_valid_ui_value(key, val)
                _report(:warn, "'$key' was not changed: $(repr(val)) is not a valid " *
                               (key === :color_map ? "colormap (e.g. :viridis)." : "colour (e.g. :red, \"#1f77b4\" or (:blue, 0.5))."))
                return false
            end
            target[key] = val
        end
        _after_editor_change!(cat, scope, key, target)
        _status!(_change_message(cat, scope, key, target), :ok)
        return true
    catch e
        @warn "Failed to apply parameter '$key': $(s)" exception=(e, catch_backtrace())
        _status!("'$key' was not changed: $(_short(sprint(showerror, e), 90))", :warn)
        return false
    end
end

"""
    _valid_editor_value(s, target, key, val) -> Bool

Whether parsed editor input may be stored. Input that is no literal at all (e.g. `[1, 2`) comes back from the parser
as text; that is only accepted where the value is text already (or quoted, `"…"`), not for numbers, symbols, vectors
and other values, so a typo can't silently change a parameter's type. Colours and colormaps may be typed as plain
text.
"""
function _valid_editor_value(s::AbstractString, target, key, val)
    txt = strip(s)
    (startswith(txt, '"') || !(val isa AbstractString || (val isa AbstractVector && any(v -> v isa AbstractString, val)))) && return true
    old = haskey(target, key) ? target[key] : nothing
    old isa AbstractString && return true
    key in (_COLOR_UI_KEYS..., :color_map) && return true   # checked by `_valid_ui_value` (`#1f77b4`, `red`, `viridis`)
    (isnothing(old) || old === missing) && return true
    return false
end

# Status message after an edit.
function _change_message(cat, scope, key, target)
    cat === :labels && return "Label of $key: $(_short(get(manager.labels, key, "")))"
    val = haskey(target, key) ? _short(_editor_text(target, key)) : ""
    where = "$(_scope_label(cat, scope)) → $key = $val"
    return cat === :simulation ? "$where. Run Simulation to apply." : where
end

# The button of a row: apply a preset, toggle a Bool, or restore the default.
function _editor_row_action!(cat, scope, key, target, tb)
    action = _row_action(cat, scope, target, key)
    try
        if action === :apply
            ok = cat === :simulation ? !isnothing(set_sim_preset!(key)) : set_plot_preset!(key) !== false
            ok ? _status!("Applied preset '$key'." * (cat === :simulation ? " Run Simulation to compute it." : ""), :ok) :
                 _status!("Preset '$key' could not be applied (see the log).", :warn)
        elseif action === :toggle
            target[key] = !target[key]
            _after_editor_change!(cat, scope, key, target)
            _status!(_change_message(cat, scope, key, target), :ok)
        elseif action === :reset
            _apply_editor_input!(cat, scope, key, target, "default", tb) || return nothing
        end
    catch e
        @warn "Failed to apply '$key'." exception=(e, catch_backtrace())
        _status!("Failed to apply '$key': $(_short(sprint(showerror, e), 90))", :error)
    end
    _render_editor!()
    return nothing
end

"""
    _setup_editor_interactions!()

Connects the fixed editor widgets: the page buttons of the overview open a scope, ◀ Back returns to the overview,
◀ ▶ turn pages, and each row writes its value box into the dictionary of the page (`_apply_editor_input!`) or runs
its button (`_editor_row_action!`). In the Methods tab the method rows activate, edit or move a method
(`_method_row_action!`), and the tools switch the listed methods and the drawing order view. Rows and buttons look up what they are bound to when used, so rebinding a page
needs no new listeners. The editor is redrawn when the active methods change.
"""
function _setup_editor_interactions!()
    w = manager.widgets
    for i in 1:EDITOR_ROWS
        tb = w[Symbol("editor_row_", i, "_text")]
        manager.listeners[Symbol("Editor_Row_Text_", i)] = on(tb.stored_string) do s
            s isa AbstractString || return
            manager.locks[:Simulation] && return  # a simulation is running
            mode = _active_editor_mode()
            if mode === :preset_file
                return _set_preset_value!(i, s)
            elseif mode === :resolution
                i <= length(manager.editor_row_keys) || return
                return _set_resolution_from_ui!(manager.editor_row_keys[i], s)
            elseif mode === :raw_rows
                i <= length(manager.editor_row_keys) || return
                return _apply_raw_input!(first(manager.editor_view[:advanced]), manager.editor_row_keys[i], s)
            end
            b = _editor_row_binding(i)
            isnothing(b) && return
            _apply_editor_input!(b..., s, tb) && _render_editor!()
        end
        manager.listeners[Symbol("Editor_Row_Button_", i)] = on(w[Symbol("editor_row_", i, "_button")].clicks) do _
            manager.locks[:Simulation] && return
            mode = _active_editor_mode()
            if mode === :preset_file
                return _delete_preset_row!(i)
            elseif mode === :resolution
                i <= length(manager.editor_row_keys) || return
                return _set_resolution_from_ui!(manager.editor_row_keys[i], "default")
            elseif mode === :raw_rows
                i <= length(manager.editor_row_keys) || return
                return _delete_raw_key!(first(manager.editor_view[:advanced]), manager.editor_row_keys[i])
            end
            b = _editor_row_binding(i)
            isnothing(b) && return
            _editor_row_action!(b..., tb)
        end
    end
    for j in 1:OVERVIEW_BUTTONS
        manager.listeners[Symbol("Editor_Page_", j)] = on(w[Symbol("editor_page_", j)].clicks) do _
            tab = manager.active_tab[]
            (_editor_tab(tab) && j <= length(manager.editor_page_scopes)) || return
            scope = manager.editor_page_scopes[j]
            tab === :plot ? _choose_plot_style!(scope) : show_editor_page!(tab, scope)
        end
    end
    manager.listeners[:Editor_Back] = on(w[:editor_back].clicks) do _
        tab = manager.active_tab[]
        _editor_tab(tab) || return
        mode = _active_editor_mode()
        mode === :preset_file ? show_editor_page!(:files, PRESET_LIST) :
        tab === :advanced && mode === :raw_rows && !(first(_view(tab)) in (:shared, :sweep, :config)) ?
            show_editor_page!(:advanced, ADV_METHODS) : show_editor_page!(tab)
    end
    manager.listeners[:Resolution_Page] = on(_ -> show_editor_page!(:files, RESOLUTION_SETTINGS), w[:resolution_button].clicks)
    for (name, kind) in ((:sim_presets_button, :simulation), (:look_presets_button, :visual))
        manager.listeners[Symbol("Preset_List_", kind)] = on(w[name].clicks) do _
            manager.preset_kind = kind
            refresh_preset_registries!()
            show_editor_page!(:files, PRESET_LIST)
        end
    end
    manager.listeners[:Preset_Add] = on(_ -> _add_preset_row!(), w[:preset_add_button].clicks)
    manager.listeners[:Raw_Add] = on(_ -> _add_raw_key!(), w[:raw_add_button].clicks)
    manager.listeners[:Method_Add] = on(_ -> _add_method!(), w[:method_add_button].clicks)
    manager.listeners[:Export_Settings] = on(_ -> show_editor_page!(:files, EXPORT_SETTINGS), w[:export_settings_button].clicks)
    for i in 1:EDITOR_ROWS, which in (:a, :b)
        manager.listeners[Symbol("Method_Row_", i, "_", which)] = on(w[Symbol("method_row_", i, "_", which)].clicks) do _
            mode = _active_editor_mode()
            if mode === :preset_list
                _preset_row_action!(i, which)
            elseif mode === :adv_method_list
                i <= length(manager.editor_row_keys) || return
                m = manager.editor_row_keys[i]
                which === :a ? show_editor_page!(:advanced, m) : _delete_method!(m)
            else
                _method_row_action!(i, which)
            end
        end
    end
    manager.listeners[:Method_Filter] = on(w[:method_filter].clicks) do _
        k = findfirst(isequal(manager.method_filter), METHOD_FILTERS)
        manager.method_filter = METHOD_FILTERS[mod1(something(k, 0) + 1, length(METHOD_FILTERS))]
        show_editor_page!(:methods)
    end
    manager.listeners[:Method_Order] = on(w[:method_order].clicks) do _
        scope, _ = get(manager.editor_view, :methods, (nothing, 1))
        show_editor_page!(:methods, scope === ORDER_VIEW ? nothing : ORDER_VIEW)
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

# The text of a box: what it shows, so typed text counts even if Enter was not pressed (the stored string lags behind
# until then); the stored string if nothing is shown (it was set from code, which doesn't update the display).
function _box_text(tb)
    shown = String(strip(something(tb.displayed_string[], "")))
    return isempty(shown) ? String(strip(something(tb.stored_string[], ""))) : shown
end

"""
    _save_preset_from_ui!(kind) -> Bool

Saves the simulation (`kind = :simulation`) or look (`:visual`) preset named in the Name / path box of the Files
tab, with the text of the Description box. Reports the result in the status line and clears both boxes on success.
"""
function _save_preset_from_ui!(kind::Symbol)
    w = manager.widgets
    name, desc = _box_text(w[:export_text]), _box_text(w[:preset_desc_text])
    if isempty(name)
        _report(:warn, "Enter a preset name in the Name / path box.")
        return false
    end
    is_sim = kind === :simulation
    success = is_sim ? save_sim_preset(name; description = desc) : save_plot_preset(name; description = desc)
    if !success
        _status!("The preset '$name' was not saved (see the log).", :warn)
        return false
    end
    where = is_sim ? "Simulation → Presets" : "UI → Presets"
    _status!("Saved $(is_sim ? "simulation" : "look") preset '$(_preset_symbol(name))' (apply it under $where).", :ok)
    Makie.reset!(w[:export_text])
    Makie.reset!(w[:preset_desc_text])
    return true
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
            _report(:info, "Camera locked to the current view.")
        else
            manager.camera_cache = Dict{Symbol, Any}()
            _report(:info, "Camera unlocked: the view scales with the next data update.")
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
            _report(:warn, "Export Error: No target selected.")
            return false 
        end
        
        idx = findfirst(isequal(target_name), manager.plot_vars)
        if !isnothing(idx) && idx in manager.active_axes[]
            _report(:warn, "Cannot animate an active plot axis.")
            return false 
        end
        
        widget = get_target_widget(target_name)
        if isnothing(widget)
            return false
        end
        if !(widget isa Makie.Slider)
            _report(:warn, "Only Sliders can be animated.")
            return false 
        end
        if length(widget.range[]) < 2
            _report(:warn, "Slider has no range to animate.")
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
        raw_filename = _box_text(saveBox)
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
                @info "Animation saved: $fname"
                _status!("Animation saved: $fname", :ok)
                
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
                _status!("Exported $base_name ($(join(formats, ", "))) to $save_dir", :ok)
                
            else
                _report(:warn, "No valid static formats selected and no animation extension provided. Export bypassed.")
            end
            
            # 3. SHUT DOWN EXPORT LISTENERS
            for obs in export_obs; off(obs); end
            
        catch e
            @error "Export Failed" exception=(e, catch_backtrace())
            _status!("Export failed: $(_short(sprint(showerror, e), 90))", :error)
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

    # Files tab: save / reset simulation presets (the physics) and look presets (the visual settings)
    manager.listeners[:Save_Sim_Preset] = on(_ -> _save_preset_from_ui!(:simulation), manager.widgets[:save_sim_preset_button].clicks)
    manager.listeners[:Save_Defs] = on(_ -> _save_preset_from_ui!(:visual), manager.widgets[:save_presets_button].clicks)
    manager.listeners[:Reset_Sim] = on(manager.widgets[:reset_sim_button].clicks) do _
        manager.locks[:Simulation] && return
        reset_sim_config!()
        _status!("Simulation reset to the bound configuration. Run Simulation to apply.", :ok)
    end
    manager.listeners[:Clear_Defs_Click] = on(manager.widgets[:clear_presets_button].clicks) do _
        set_plot_preset!()
        manager.triggers[:UI][] += 1
        _status!("Look reset to the defaults.", :ok)
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

When the plot style changes (or new data arrives), it queries the underlying tensor's dimensions and filters the available Animation, Compare, and X/Y/Z Axis dropdown targets to ensure users cannot attempt to animate non-existent physical domains.
"""
function _setup_chain_A!(::Val{:eulerian})
    w = manager.widgets
    x_sel = w[:x_axis].selection
    y_sel = w[:y_axis].selection
    style_obs = w[:plot_style].selection

    manager.listeners[:Eulerian_Style_Change] = on(style_obs) do _
        _render_editor!()  # the UI overview highlights the pages of the active plot type
    end

    manager.listeners[:Eulerian_Chain_A] = onany(manager.plot_data, style_obs, x_sel, y_sel) do plot_data_dict, style_sel, _x, _y
        @with_lock :Menu_A begin
            isempty(plot_data_dict) && return
            (isnothing(style_sel) || style_sel == :none) && return
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

Recognizes that point clouds do not have fixed Eulerian bounding boxes. It offers only the scatter styles matching the dimension of the particles (`_set_allowed_styles!`), automatically locks the available X/Y/Z axes based strictly on the dimensionality of the scattered vectors (e.g., forcing X and Y for a 2D particle track), and explicitly injects the scalar `:time` dimension as the default animation target.
"""
function _setup_chain_A!(::Val{:lagrangian})
    w = manager.widgets
    
    manager.listeners[:Lagrangian_Style_Change] = on(_ -> _render_editor!(), w[:plot_style].selection)

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
                _set_allowed_styles!(Symbol[:scatter_1d, :scatter_lines, :scatter_colors])
                update_menu_safe!(w[:y_axis], Any[menu_opt(:none)]; fallbacks=[:none])
                update_menu_safe!(w[:z_axis], Any[menu_opt(:none)]; fallbacks=[:none])
            elseif D == 2
                _set_allowed_styles!(Symbol[:scatter_2d, :scatter_surface])
                update_menu_safe!(w[:y_axis], Any[menu_opt(sy)]; fallbacks=[sy])
                update_menu_safe!(w[:z_axis], Any[menu_opt(:none)]; fallbacks=[:none])
            else
                _set_allowed_styles!(Symbol[:scatter_3d])
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