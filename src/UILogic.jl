const _RANK_0 = (:none,:shared,:presets,:create_new)
const _RANK_1 = ("analytic", "reference", "exact", "baseline", "true")

"""
    menu_option_rank(opt::Tuple)

Custom sorting ranker for Makie dropdown tuples.
Rank 0: Defaults / Disabled / Main Prompts
Rank 1: Analytical / Reference methods
Rank 2: Standard alphabetical sorting
"""
function menu_option_rank(opt)
    label_str = string(opt[1])
    val = length(opt) > 1 ? opt[2] : nothing
    
    # Rank 0: Main prompts and ":none" fallbacks 
    # (Catches "Methods...", "-", and the resolved UI label for :none)
    if val in manager.plot_vars || val in _RANK_0
        return (0, label_str)
    end
    
    # Rank 1: Priority references
    lm = lowercase(label_str)
    if any(k -> occursin(k, lm), _RANK_1)
        return (1, label_str)
    end
    
    # Rank 2: Everything else
    return (2, label_str)
end

"""
    update_menu_safe!(menu_widget, new_options; fallbacks=Any[], force_notify=false)

Safely updates a Makie Menu's options, forces a WebGL buffer sync to prevent crashes,
and preserves the current selection or falls back to a prioritized list.
Assumes all options are `(Label, Value)` tuples and automatically sorts them by priority.
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
            # THE FIX: Check if either the Label (o[1]) or the Value (o[2]) changed
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
function apply_options!(cache_key::Symbol, option_keys::Tuple, new_options::Dict)
    isempty(new_options) && return

    # 1. ALWAYS update the central source of truth
    for (k, v) in new_options
        manager.state[cache_key][k] = v
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
            
            if isnothing(idx) && val isa String
                idx = findfirst(v -> startswith(string(v), val), valid_vals)
            end
            
            if !isnothing(idx)
                widget.i_selected[] = idx
                notify(widget.selection)
            else
                # Fallback for dynamic menus (like Axis targets) pushing new options
                if opts isa Vector && !isempty(opts) && opts[1] isa Tuple
                    new_opts = copy(opts)
                    push!(new_opts, (string(val), val))
                    widget.options[] = new_opts
                else
                    new_opts = copy(opts)
                    push!(new_opts, val)
                    widget.options[] = new_opts
                end
                widget.i_selected[] = length(widget.options[])
                notify(widget.selection)
            end
        end
    end
end

function extract_options(option_keys::Tuple)
    opts = Dict{Symbol, Any}()
    for k in option_keys
        if haskey(manager.widgets, k)
            opts[k] = manager.widgets[k].selection[]
        end
    end
    return opts
end

function apply_slider_options!(slider_options::Dict)
    isempty(slider_options) && return
    
    rev_map = get(manager.maps, :Reverse, Dict{Symbol, Symbol}())
    for (key, desired_val) in slider_options
        # Skip standard dropdown keys if a mixed dictionary is passed in
        if key in PLOT_AXIS_OPTIONS || key in LAYOUT_OPTIONS || key in EXPLORATION_OPTIONS || key === :reset
            continue
        end
        
        base_sym = key
        w_key = haskey(rev_map, base_sym) ? rev_map[base_sym] : base_sym
        
        if haskey(manager.widgets, w_key)
            widget = manager.widgets[w_key]
            if widget isa Makie.Slider
                manager.state[:Slider_Cache][w_key] = Float64(desired_val)
                manager.state[:Plot_Cache][key] = desired_val
                
                rng = widget.range[]
                isempty(rng) && continue
                
                val = Float64(rng[1])
                if desired_val isa Real
                    val = clamp(Float64(desired_val), Float64(rng[1]), Float64(rng[end]))
                end
                set_close_to!(widget, val) 
            end
        end
    end
end

function extract_slider_options()
    opts = Dict{Symbol, Any}()
    rev_map = get(manager.maps, :Reverse, Dict{Symbol, Symbol}())
    for k in manager.plot_vars
        w_key = haskey(rev_map, k) ? rev_map[k] : k 
        if haskey(manager.widgets, w_key)
            widget = manager.widgets[w_key]
            if widget isa Makie.Slider
                opts[k] = widget.value[]  # Assign purely by the variable's symbol
            end
        end
    end
    return opts
end

# ==============================================================================
# --- ALIASES FOR COMPATIBILITY ---
# ==============================================================================
apply_layout_options!(opts::Dict)      = apply_options!(:Layout_Cache, LAYOUT_OPTIONS, opts)
apply_exploration_options!(opts::Dict) = apply_options!(:Exploration_Cache, EXPLORATION_OPTIONS, opts)

function apply_plot_options!(opts::Dict)
    apply_options!(:Plot_Cache, PLOT_AXIS_OPTIONS, opts)
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

function setup_ui_interactions!(master_fig::Figure, plot_layout::GridLayout, mode::Val{T}) where T
    _setup_run_and_drop_interactions!(master_fig)
    _setup_method_interactions!()
    _setup_hierarchy_interactions!()
    _setup_export_interactions!(master_fig, plot_layout)
    _setup_button_state_machine!()
    
    # Unified UI Data Sync Pipeline driven by Dispatch
    _setup_chain_A!(mode)
    _setup_chain_B!(mode)
    _setup_chain_C!(mode)
    
    manager.widgets[:editor_cat].i_selected[] = 1
    notify(manager.widgets[:editor_cat].selection)
    notify(manager.methods)
end

function _setup_button_state_machine!()
    w = manager.widgets
    
    f_sim = manager.flags[:Simulation]
    f_lay = manager.flags[:Layout]
    f_plot = manager.flags[:Plot]

    # --- DYNAMIC WATCHERS ---
    # 1. Layout Watcher
    layout_obs = [w[k].selection for k in LAYOUT_OPTIONS if haskey(w, k)]
    manager.listeners[:Watch_Layout] = onany(layout_obs...) do _...
        merge!(manager.state[:Layout_Cache], extract_layout_options())
        if !manager.locks[:Layout] && !manager.locks[:Simulation]
            f_lay[] = true
        end
    end

    # 2. Plot Watcher
    plot_obs = [w[k].selection for k in PLOT_AXIS_OPTIONS if haskey(w, k)]
    manager.listeners[:Watch_Plot] = onany(plot_obs...) do _...
        merge!(manager.state[:Plot_Cache], extract_plot_options())
        if !manager.locks[:Plot] && !manager.locks[:Layout] && !manager.locks[:Simulation]
            f_plot[] = true
        end
    end
    
    # 3. Exploration Watcher (Updates Cache, but doesn't flag a hard reset!)
    exp_obs = [w[k].selection for k in EXPLORATION_OPTIONS if haskey(w, k)]
    manager.listeners[:Watch_Exploration] = onany(exp_obs...) do _...
        merge!(manager.state[:Exploration_Cache], extract_exploration_options())
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

function _setup_run_and_drop_interactions!(master_fig::Figure)
    load_btn = manager.widgets[:load_config_button]
    run_btn  = manager.widgets[:run_button]
    path_box = manager.widgets[:export_text]

    function _handle_load(path)
        # Load the CSV (which theoretically modifies manager.allowed_dims / max_params)
        if load_and_apply_csv!(path)
            load_btn.buttoncolor[] = :orange
            run_btn.buttoncolor[] = :orange
            load_btn.label[] = "Structural limits changed! \nClicking 'Run Simulation' will completely reset the backend. \nSave current settings as a preset if you want to keep them."
        else
            load_btn.label[] = "CSV successfully loaded! Press 'Run Simulation' to apply it."
            load_btn.buttoncolor[] = :lightgreen
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
        path = strip(path_box.stored_string[])
        if isempty(path)
            @warn "Please enter a path or filename in the textbox below first."
            return
        end
        
        if !isfile(path)
            set_sim_config!(path)
            run_btn.buttoncolor[] = :lightgreen
            run_btn.label[] = "Run Simulation"
        else
            _handle_load(path)
        end
    end

    manager.listeners[:Run_Click] = on(run_btn.clicks) do _
        
        if haskey(manager.state, :CSV_Cache)
            @info "Structural rebuild initiated. Relaunching UI..."
            
            # 1. Extract the staging area
            new_dims, new_max, parsed = manager.state[:CSV_Cache]
            
            # 2. Apply structural limits globally
            manager.allowed_dims = new_dims
            manager.max_params = new_max
            
            # 3. Physically relaunch UI (and display it safely if using GLMakie)
            Base.invokelatest() do
                fig = launch_plotter()
                display(fig)
                
                # 4. Apply the fully cached configuration directly to the NEW widgets
                load_and_apply_csv!(parsed)
                force_simulation()
            end
            
            # 5. Clean up
            delete!(manager.state, :CSV_Cache)
        end
        
        manager.flags[:Simulation][] = false
        manager.flags[:Layout][] = false
        manager.flags[:Plot][] = false
        manager.triggers[:Simulation][] += 1
        return
    end
end

function _setup_method_interactions!()
    mode_btn = manager.widgets[:mode_button]
    menu_mth = manager.widgets[:method_toggle]
    is_activate_mode = manager.state[:Is_Activate_Mode]
    
    # THE FIX: A helper function to manually sync the menu directly from the config
    function sync_menu()
        config = manager.active_config
        isnothing(config) && return 
        
        staged = config.active_methods
        raw_method_names = filter(k -> k != :shared, collect(keys(config.methods_dict)))
        opts = is_activate_mode[] ? filter(m -> !(m in staged), raw_method_names) : copy(staged)

        opts_sorted = sort_methods_robust(opts)
        new_opts = isempty(opts) ? Any[menu_opt(:none)] : [("Methods...", :none); menu_opt.(opts_sorted)]
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
        (isnothing(sel) || sel == :none || sel == "-") && return
        
        config = manager.active_config
        isnothing(config) && return
        
        new_staged = copy(config.active_methods)
        if is_activate_mode[]
            if !(sel in new_staged)
                push!(new_staged, sel)
                new_staged = sort_methods_robust(new_staged) 
            end
        else
            filter!(x -> x != sel, new_staged)
        end
        
        # THE FIX: Directly mutate the config!
        config.active_methods = new_staged
        manager.flags[:Simulation][] = true
        menu_mth.i_selected[] = 1
        
        @with_lock :Menu_Sync begin
            sync_menu()
        end
    end
end

function _setup_hierarchy_interactions!()
    menu_cat   = manager.widgets[:editor_cat]
    menu_scope = manager.widgets[:editor_scope]
    menu_key   = manager.widgets[:editor_key]
    tb         = manager.widgets[:editor_text]
    
    active_target_ref = manager.state[:Active_Target_Obs]

    function sync_textbox_to_active_key()
        key = menu_key.selection[]
        if isnothing(key) || key === :none || key == "-"
            active_target_ref[] = nothing
            tb.stored_string.val = ""
            if tb.displayed_string[] != ""; Makie.reset!(tb); end
            
            manager.widgets[:editor_toggle].label[] = "Toggle"
            manager.widgets[:editor_toggle].buttoncolor[] = :lightgray
            return
        end
        
        cat = menu_cat.selection[]
        scope = menu_scope.selection[]
        (isnothing(cat) || isnothing(scope) || scope === :none || scope == "-") && return
        
        target_dict = nothing
        if cat === :simulation
            config = manager.active_config
            isnothing(config) && return 
            target_dict = scope === :shared ? config.shared_params : get(config.methods_dict, scope, nothing)
        elseif cat === :ui
            target_dict = scope === :presets ? manager.maps[:Presets] : get(manager.ui, scope, nothing)
        elseif cat === :labels
            target_dict = manager.maps[:Labels]
        end

        if !isnothing(target_dict) && haskey(target_dict, key)
            active_target_ref[] = (target_dict, key)
            val_str = _value_to_string_for_csv(target_dict[key])
            tb.displayed_string[] = isempty(val_str) ? "<empty>" : val_str
            
            # THE FIX: Dynamic Toggle/Apply Button!
            if cat === :ui && scope === :presets
                manager.widgets[:editor_toggle].label[] = "Apply"
                manager.widgets[:editor_toggle].buttoncolor[] = :lightgreen
            else
                manager.widgets[:editor_toggle].label[] = "Toggle"
                manager.widgets[:editor_toggle].buttoncolor[] = :lightgray
            end
        end
    end

    manager.listeners[:Hierarchy_Cat_Sync] = onany(menu_cat.selection, manager.methods) do cat, active_methods
        isnothing(cat) && return
        new_scopes = Any[]
        
        if cat === :simulation
            config = manager.active_config
            if !isnothing(config) 
                push!(new_scopes, ("Shared", :shared))
                for m in sort_methods_robust(active_methods)
                    m_sym = Symbol(m)
                    haskey(config.methods_dict, m_sym) && push!(new_scopes, (string(m_sym), m_sym))
                end
            end
        elseif cat === :ui
            # THE FIX: Inject Presets as the default UI scope
            push!(new_scopes, ("Presets", :presets))
            for k in sort(collect(keys(manager.ui)))
                push!(new_scopes, menu_opt(k))
            end
        elseif cat === :labels
            new_scopes = Any[("Components", :components), ("Variables", :variables), ("Methods", :methods)]
        end
        
        new_scopes = isempty(new_scopes) ? Any[menu_opt(:none)] : new_scopes
        update_menu_safe!(menu_scope, new_scopes; force_notify=true)
    end

    manager.listeners[:Hierarchy_Scope_Sync] = on(menu_scope.selection) do scope
        (isnothing(scope) || scope === :none || scope == "-") && return 
        cat = menu_cat.selection[]
        raw_keys = Symbol[]
        
        if cat === :simulation
            config = manager.active_config
            if !isnothing(config) 
                target_dict = scope === :shared ? config.shared_params : get(config.methods_dict, scope, Dict{Symbol, Any}())
                raw_keys = sort(collect(keys(target_dict)))
            end
        elseif cat === :ui
            if scope === :presets
                # THE FIX: Dynamically scan the disk for custom presets!
                preset_dir = joinpath(get_save_path(), "Presets")
                if isdir(preset_dir)
                    for file in readdir(preset_dir)
                        if endswith(lowercase(file), ".csv")
                            sym_name = Symbol(splitext(file)[1])
                            # Register it in the UI maps if it isn't there already
                            if !haskey(manager.maps[:Presets], sym_name)
                                manager.maps[:Presets][sym_name] = "Custom disk preset"
                            end
                        end
                    end
                end
                
                raw_keys = sort(collect(keys(manager.maps[:Presets])))
            else
                raw_keys = sort(collect(keys(get(manager.ui, scope, Dict{Symbol, Any}()))))
            end
        elseif cat === :labels
            if scope === :components
                c_max = 1
                if !isempty(manager.plot_data[])
                    pd_first = first(values(manager.plot_data[]))
                    sim_data = _get_first_valid(pd_first)
                    if !isnothing(sim_data)
                        u_val = manager.widgets[:u_axis].selection[]
                        target_field = (isnothing(u_val) || u_val === :none) ? :Solution : u_val
                        target_tensor = get(sim_data.stats, target_field, sim_data.stats[:Solution])
                        c_max = _get_component_num_plots(Val(manager.mode[]), target_tensor)
                    end
                end
                raw_keys = [Symbol("component_$i") for i in 1:c_max]
            elseif scope === :variables
                raw_keys = manager.plot_vars
            elseif scope === :methods
                raw_keys = manager.methods[]
            end
            
            for k in raw_keys
                if !haskey(manager.maps[:Labels], k)
                    manager.maps[:Labels][k] = string(k)
                end
            end
        end

        if scope === :plot_style
            ptype = manager.widgets[:plot_style].selection[]
            valid_keys = get(STYLE_DEPENDENCIES, ptype, Symbol[])
            filter!(k -> k in valid_keys, raw_keys)
        end

        # Preserve exact casing for Simulation, Labels, and Presets!
        if cat === :labels
            new_keys = isempty(raw_keys) ? Any[menu_opt(:none)] : Any[(string(k), k) for k in raw_keys]
        else
            new_keys = isempty(raw_keys) ? Any[menu_opt(:none)] : Any[menu_opt(k) for k in raw_keys]
        end
        
        update_menu_safe!(menu_key, new_keys; force_notify=true)
        sync_textbox_to_active_key()
    end

    manager.listeners[:Hierarchy_Key_Sync] = on(menu_key.selection) do _
        sync_textbox_to_active_key()
    end

    manager.listeners[:Hierarchy_Text_Sync] = on(tb.stored_string) do s
        target_info = active_target_ref[]
        isnothing(target_info) && return
        if manager.flags[:Layout][] || manager.flags[:Simulation][]; return end
        target_dict, key = target_info
        
        cat = menu_cat.selection[]
        scope = menu_scope.selection[]
        
        try
            if cat === :labels || (cat === :ui && scope === :presets)
                target_dict[key] = string(s)
            else
                target_dict[key] = smart_parse_csv_value(s)
            end
            
            if cat === :simulation
                manager.flags[:Simulation][] = true 
            elseif cat === :ui
                if scope !== :presets
                    if key in REPLOT_OPTIONS
                        manager.triggers[:Plot][] += 1
                    else
                        manager.triggers[:UI][] += 1
                    end
                end
            elseif cat === :labels
                
                if scope === :variables
                    lbl_key = Symbol("$(key)_label")
                    if haskey(manager.widgets, lbl_key)
                        manager.widgets[lbl_key][] = target_dict[key] * ":"
                    end
                elseif scope === :components
                    notify(manager.widgets[:u_axis].selection)
                elseif scope === :methods
                    notify(manager.state[:Is_Activate_Mode])
                end
                manager.triggers[:UI][] += 1
            end
        catch e
            @warn "Failed to apply parameter '$key': $(s)" exception=(e, catch_backtrace())
        end
    end
    
    manager.listeners[:Hierarchy_Toggle_Sync] = on(manager.widgets[:editor_toggle].clicks) do _
        target_info = active_target_ref[]
        isnothing(target_info) && return
        if manager.flags[:Layout][] || manager.flags[:Simulation][]; return end
        target_dict, key = target_info
        
        cat = menu_cat.selection[]
        scope = menu_scope.selection[]
        
        try
            if cat === :ui && scope === :presets
                if key === :create_new
                    @info "Fill in a filename below and click 'Save Defs' to write to disk."
                else
                    set_plot_presets!(key)
                end
                return
            end
            
            if target_dict[key] isa Bool
                target_dict[key] = !target_dict[key]
                tb.displayed_string[] = string(target_dict[key])
                
                if cat === :simulation
                    manager.flags[:Simulation][] = true 
                elseif cat === :ui
                    if key in REPLOT_OPTIONS
                        manager.triggers[:Plot][] += 1
                    else
                        manager.triggers[:UI][] += 1
                    end
                end
            end
        catch e
            @warn "Failed to toggle parameter '$key'." exception=(e, catch_backtrace())
        end
    end
end

function _setup_export_interactions!(master_fig::Figure, plot_layout::GridLayout)
    saveBox = manager.widgets[:export_text]
    btn_play = manager.widgets[:play_anim_button]
    btn_lock = manager.widgets[:lock_camera_button] 
    btn_export = manager.widgets[:export_button]

    manager.listeners[:Camera_Lock_Click] = on(btn_lock.clicks) do _
        is_locked = !manager.state[:Camera_Locked][]
        manager.state[:Camera_Locked][] = is_locked
        
        if is_locked
            extract_and_store_camera_state!(plot_layout)
            @info "Camera locked to current view."
        else
            manager.state[:Camera_Cache] = Dict{Symbol, Any}()
            @info "Camera unlocked. Will auto-scale on next data update."
        end
    end

    # THE FIX: Couple the button directly to the observable!
    manager.listeners[:Camera_State_Sync] = on(manager.state[:Camera_Locked]) do is_locked
        if is_locked
            btn_lock.label[] = "Camera: Locked"
            btn_lock.buttoncolor[] = :lightgreen
        else
            btn_lock.label[] = "Lock Camera"
            btn_lock.buttoncolor[] = :lightblue
        end
    end

    anim_target_obs = manager.widgets[:anim_target].selection
    is_animating = manager.state[:Is_Animating]
    animation_timer = manager.state[:Animation_Timer]

    function get_target_widget(target_name)
        target_name == :none && return nothing
        rev_map = haskey(manager.maps, :Reverse) ? manager.maps[:Reverse] : Dict{Symbol, Symbol}()
        w_key = haskey(rev_map, target_name) ? rev_map[target_name] : Symbol(target_name)
        return haskey(manager.widgets, w_key) ? manager.widgets[w_key] : nothing
    end

    function check_selection_validity(target_name)
        if isnothing(target_name) || target_name == :none
            @warn "Export Error: No target selected."
            return false 
        end
        
        idx = findfirst(isequal(target_name), manager.plot_vars)
        if !isnothing(idx) && idx in manager.state[:Active_Axes][]
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
        # THE FIX: Match the pristine figure exactly to the cropped plot dimensions
        bbox = plot_layout.layoutobservables.computedbbox[]
        w, h = bbox.widths[1], bbox.widths[2]
        w = max(w, 400); h = max(h, 300) # Fallback minimums
        
        export_fig = Figure(size = (w, h)) 
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
        raw_filename = string(strip(saveBox.stored_string[]))
        if isempty(raw_filename); raw_filename = "plot_export"; end
        
        base_name, ext = splitext(raw_filename)
        ext = lowercase(replace(ext, "." => ""))
        
        formats = String[]
        is_anim = false
        
        if isempty(ext)
            formats = lowercase.(manager.ui[:various][:save_formats])
            is_anim = "gif" in formats || "mp4" in formats
        else
            formats = [ext]
            is_anim = ext == "gif" || ext == "mp4"
        end

        target_name = anim_target_obs[] 
        if is_anim
            !check_selection_validity(target_name) && return
        end

        was_locked = manager.state[:Camera_Locked][]
        manager.state[:Camera_Locked][] = true 
        extract_and_store_camera_state!(plot_layout)
        
        target_widget = is_anim ? get_target_widget(target_name) : nothing
        
        # THE FIX: Tell the macro to let both windows render simultaneously
        manager.state[:Bypass_Locks] = true
        
        try
            export_fig, export_obs = build_pristine_export_figure()

            if is_anim
                save_path = joinpath(get_save_path(), "animations")
                mkpath(save_path)
                
                active_ext = isempty(ext) ? "gif" : ext
                fname = joinpath(save_path, base_name * "." * active_ext)
                
                duration = manager.ui[:various][:animation_time]
                fps = manager.ui[:various][:animation_FPS]
                rng = target_widget.range[]
                n_frames = Int(duration * fps)
                @info "Recording pristine '$target_name' animation to $fname..."
                # Because the locks are bypassed, moving the main window's slider
                # WILL successfully animate the pristine figure in the background!
                record(export_fig, fname, range(rng[1], rng[end], length=n_frames); framerate=fps) do val
                    set_close_to!(target_widget, val)
                    yield() 
                end
                display(master_fig)
                metadata = Dict("Save Type" => "Animation", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
                save_params_to_csv(base_name, save_path, metadata) 
                @info "Pristine Animation Saved Successfully."
                
                for obs in export_obs; off(obs); end
            else
                save_dir = joinpath(get_save_path(), "figures")
                if manager.ui[:various][:create_savefolder]; save_dir = joinpath(save_dir, base_name); end
                mkpath(save_dir)

                for fmt in formats
                    full_path = joinpath(save_dir, base_name * ".$fmt")
                    save(full_path, export_fig; backend=CairoMakie)
                    @info "Pristine Image ($fmt) saved safely via CairoMakie!"
                end

                for obs in export_obs; off(obs); end
                
                metadata = Dict("Save Type" => "Static Frame", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
                save_params_to_csv(base_name, save_dir, metadata)
            end
        catch e
            @error "Export Failed" exception=(e, catch_backtrace())
        finally
            # Restore the lock safety net!
            manager.state[:Bypass_Locks] = false
            
            if !was_locked
                manager.state[:Camera_Locked][] = false
                manager.state[:Camera_Cache] = Dict{Symbol, Any}()
            end
        end
    end

    manager.listeners[:Save_Defs] = on(manager.widgets[:save_presets_button].clicks) do _
        # --- DISK SAVE (Create New Preset) ---
        filename = manager.widgets[:export_text].stored_string[]
        if isempty(filename)
            @warn "Please enter a preset name in the Filename box."
            return
        end
        
        sym_name = Symbol(lowercase(replace(strip(filename), r"\s+" => "_")))
        save_dir = joinpath(get_save_path(), "Presets")
        mkpath(save_dir)
        
        desc = manager.maps[:Presets][:create_new]
        if desc == "Type a description here, type a filename above, \nand click Save Preset." || isempty(desc)
            desc = "User custom preset: $filename"
        end
        manager.maps[:Presets][sym_name] = desc
        
        success = save_preset_to_csv(sym_name, save_dir)
        if success
            Makie.reset!(manager.widgets[:export_text])
            manager.maps[:Presets][:create_new] = "Type a description here, type a filename above, \nand click Save Preset."
            notify(manager.widgets[:editor_scope].selection)
            
            idx = findfirst(x -> x[2] == sym_name, manager.widgets[:editor_key].options[])
            if !isnothing(idx); manager.widgets[:editor_key].selection[] = sym_name; end
        end
    end
    
    manager.listeners[:Clear_Defs_Click] = on(manager.widgets[:clear_presets_button].clicks) do _
        set_plot_presets!()
        manager.triggers[:UI][] += 1
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
            
            duration = manager.ui[:various][:animation_time]
            fps = manager.ui[:various][:animation_FPS]
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

function _get_active_sim_data(plot_data_dict)
    isempty(plot_data_dict) && return nothing, nothing
    pd_first = first(values(plot_data_dict))
    
    sim_data = _get_first_valid(pd_first)
    
    return pd_first, sim_data
end

# ==============================================================================
# --- CHAIN A: Base Setup & Anim/Compare Targeting ---
# ==============================================================================

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
        notify(manager.widgets[:editor_scope].selection)
    end
    
    manager.listeners[:Eulerian_Style_Change] = on(style_obs) do _
        notify(manager.widgets[:editor_scope].selection)
    end

    manager.listeners[:Eulerian_Chain_A] = onany(manager.plot_data, base_obs, style_obs, x_sel, y_sel) do plot_data_dict, base_sel, style_sel, _x, _y
        @with_lock :Menu_A begin
            isempty(plot_data_dict) && return
            (isnothing(style_sel) || style_sel == :none || isnothing(base_sel) || base_sel == :none) && return
            pd_first = first(values(plot_data_dict))
            n_params = length(pd_first.active_param_keys)
            if n_params > 0; manager.plot_vars[1:n_params] .= Symbol.(pd_first.active_param_keys); end
            dim_names = manager.plot_vars
            
            sim_data = _get_first_valid(pd_first)
            isnothing(sim_data) && return
            
            valid_indep_axes = Symbol[]
            for p in pd_first.active_param_keys; push!(valid_indep_axes, Symbol(p)); end
            for k in sim_data.domain.dim_keys; push!(valid_indep_axes, k); end
            
            for k in keys(sim_data.stats)
                k === :Solution && continue
                stat_dims = IRunPDESims.get_kept_dims(k, sim_data.domain)
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
            
            # THE FIX: Dynamically set the fallback to the time dimension!
            t_dim = sim_data.domain.time_dim
            anim_fallbacks = !isnothing(t_dim) ? [t_dim, :none] : [:none]
            
            update_menu_safe!(w[:anim_target], anim_options; fallbacks=anim_fallbacks)

            compare_opts = Any[menu_opt(:none), menu_opt(:methods), menu_opt(:component)]
            if !isnothing(sim_data.domain.time_dim)
                push!(compare_opts, menu_opt(:time))
            end
            for p_key in pd_first.active_param_keys
                # THE FIX: Use menu_opt instead of string()
                push!(compare_opts, menu_opt(Symbol(p_key)))
            end
            update_menu_safe!(w[:compare_target], compare_opts; fallbacks=[:none], force_notify=false)

            ptype = manager.widgets[:plot_style].selection[]
            p_dim = PLOT_DIM_MAP[ptype]
            
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
            x_val = w[:x_axis].selection[]
            
            update_menu_safe!(w[:x_axis], build_axis_opts([]); fallbacks=base_vars, force_notify=false)
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

function _setup_chain_A!(::Val{:lagrangian})
    w = manager.widgets
    
    # THE FIX: Ensure the base menu is locked to Scatter when in Lagrangian mode!
    base_opts = Any[menu_opt(:scatter)]
    update_menu_safe!(w[:base_plot], base_opts; fallbacks=[:scatter], force_notify=false)

    manager.listeners[:Lagrangian_Chain_A] = onany(manager.plot_data) do plot_data_dict
        @with_lock :Menu_A begin
            isempty(plot_data_dict) && return
            
            pd_first = first(values(plot_data_dict))
            l_data = _get_first_valid(pd_first)
            isnothing(l_data) && return
            
            n_params = length(pd_first.active_param_keys)
            dim_names = manager.plot_vars
            
            D = length(l_data.domain.mins) - (isnothing(l_data.domain.time_dim) ? 0 : 1)
            spatial_keys = filter(k -> k != l_data.domain.time_dim, l_data.domain.dim_keys)
            
            sx = D >= 1 ? spatial_keys[1] : :x
            sy = D >= 2 ? spatial_keys[2] : :y
            sz = D >= 3 ? spatial_keys[3] : :z
            
            # THE FIX: Use menu_opt instead of string()
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
            
            # THE FIX: Explicitly add time to Lagrangian anim options and set it as the default
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
                # THE FIX: Use menu_opt instead of string()
                push!(compare_opts, menu_opt(Symbol(p_key)))
            end
            update_menu_safe!(w[:compare_target], compare_opts; fallbacks=[:none], force_notify=false)
        end
    end
end

# ==============================================================================
# --- CHAIN B: Dependent Field & Active Axis Triggers ---
# ==============================================================================

function _setup_chain_B!(::Val{:eulerian})
    w = manager.widgets
    x_sel, y_sel, z_sel = w[:x_axis].selection, w[:y_axis].selection, w[:z_axis].selection
    active_axes_obs = manager.state[:Active_Axes]

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
                kept_syms = IRunPDESims.get_kept_dims(k, sim_data.domain)
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

function _setup_chain_B!(::Val{:lagrangian})
    w = manager.widgets
    active_axes_obs = manager.state[:Active_Axes]

    manager.listeners[:Lagrangian_Chain_B] = onany(w[:x_axis].selection, w[:y_axis].selection, w[:z_axis].selection, manager.plot_data) do x_val, y_val, z_val, plot_data_dict
        @with_lock :Menu_B begin
            isempty(plot_data_dict) && return
            
            pd_first = first(values(plot_data_dict))
            l_data = _get_first_valid(pd_first)
            isnothing(l_data) && return
            
            spatial_keys = filter(k -> k != l_data.domain.time_dim, l_data.domain.dim_keys)

            valid_fields = Any[]
            if issubset(spatial_keys, l_data.domain.dim_keys)
                push!(valid_fields, menu_opt(:Solution)) # THE FIX: Use menu_opt
            end
            
            for k in keys(l_data.stats)
                k === :Solution && continue
                kept_syms = IRunPDESims.get_kept_dims(k, l_data.domain)
                if issubset(spatial_keys, kept_syms)
                    push!(valid_fields, menu_opt(k))     # THE FIX: Use menu_opt
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
                # Auto-initialize the label if it doesn't exist yet
                if !haskey(manager.maps[:Labels], sym)
                    manager.maps[:Labels][sym] = "Component $i"
                end
                
                # THE FIX: Push the frontend_key mapped string to the UI menu
                push!(c_options, (frontend_key(sym), i))
            end
            update_menu_safe!(w[:component], c_options; fallbacks=[1])
        end
    end
end