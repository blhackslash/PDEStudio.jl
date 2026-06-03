# ==============================================================================
# --- GLOBAL UI STATE REFERENCES ---
# ==============================================================================
const GLOBAL_UI_OVERWRITE = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_VAR_OVERWRITE = Ref{Vector{Any}}(Any[:menu, :slider, :slider, :slider, :slider])
const GLOBAL_SCENE_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_LAYOUT_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())

# Singleton Global Observables & State
const ACTIVE_SIM_CONFIG = Observable{Any}(nothing) # THE FIX: Reactive Config Pipeline
const ACTIVE_PLOT_MANAGER = Ref{PlotManager}()
#const PLOTTER_UI_STATE = Ref{Dict{Symbol, Any}}(Dict(:is_open => false, :ctrl_fig => nothing, :plot_layout => nothing))
const PLOTTER_UI_STATE = Ref{Dict{Symbol, Any}}(Dict(:is_open => false, :master_fig => nothing))

function set_sim_config!(config::SimulationConfig)
    ACTIVE_SIM_CONFIG[] = config
    return
end

const LEGEND_REF = Ref{Symbol}(:none)
function dummy_simulation_function(args...); return nothing; end

"""
    set_sim_config!(csv_name::String, manager)

Searches for a CSV by name in the figures, animations, and Experiments folders.
If found, it parses it, reconstructs the `SimulationConfig`, runs the simulations,
and dynamically updates the active Plotter UI.
"""
function set_sim_config!(csv_name::String)
    manager = ACTIVE_PLOT_MANAGER[]
    filename = endswith(lowercase(csv_name), ".csv") ? csv_name : csv_name * ".csv"
    
    save_root = get_save_path()
    sim_root = _SIM_ROOT_PATH[]
    search_dirs = [
        joinpath(save_root, "figures"),
        joinpath(save_root, "animations"),
        joinpath(sim_root, "Experiments")
    ]
    
    filepath = ""
    for dir in search_dirs
        if isdir(dir)
            test_path = joinpath(dir, filename)
            if isfile(test_path); filepath = test_path; break; end
            
            for subdir in readdir(dir; join=true)
                if isdir(subdir)
                    test_path = joinpath(subdir, filename)
                    if isfile(test_path); filepath = test_path; break; end
                end
            end
        end
        if !isempty(filepath); break; end
    end
    
    if isempty(filepath)
        @warn "CSV file '$filename' not found."
        return
    end
    
    # Call the new helper!
    load_and_apply_csv!(manager, filepath)
end

"""
    reset_plotter!()

Completely wipes the UI state, purges observables, and destroys the active window. 
Guarantees a 100% clean slate for the next @plot call.
"""
function reset_plotter!()
    fig = PLOTTER_UI_STATE[][:master_fig]
    if !isnothing(fig)
        try
            screen = Makie.getscreen(fig.scene)
            if !isnothing(screen); close(screen); end
        catch
        end
        empty!(fig)
    end
    PLOTTER_UI_STATE[][:is_open] = false
    PLOTTER_UI_STATE[][:master_fig] = nothing
    empty!(ACTIVE_SIM_CONFIG.listeners)
    ACTIVE_SIM_CONFIG.val = nothing
    @info "Plotter state completely cleared. Ready for a fresh @plot."
end

# ==============================================================================
# --- 1. MANAGER FACTORY (MVC Configured) ---
# ==============================================================================
function create_plot_manager(sim_config::SimulationConfig{F}, master_ui::Dict, ui_overwrite::Dict, init_type::Symbol) where {F}
    varied_dict = sim_config.varied_params
    vars = isempty(varied_dict) ? String[] : sort(collect(keys(varied_dict)))
    append!(vars, BaseVariables)

    sim_obs = NestedObsDict()
    make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
    sim_obs["shared"] = Dict(k => make_obs(v) for (k, v) in sim_config.shared_params)
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => make_obs(v) for (k, v) in m_params)
    end

    ui_obs = NestedObsDict()
    methods_obs = Observable(copy(sim_config.default_methods))

    # --- THE FIX: MVC Strict Nested Dictionaries ---
    controls_obs = Dict{String, Any}()
    for k in ["Widget", "Options", "Selection", "Value", "Range", "String", "Button", "State"]
        controls_obs[k] = Dict{String, Observable}()
    end
    controls_obs["Misc"] = Dict{String, Any}() # For non-observables
    
    controls_obs["State"]["base_types"] = Observable{Vector{Any}}([[:menu]; [:slider for _ in 2:5]])
    
    # --- TIERED ARCHITECTURE TRIGGERS ---
    controls_obs["State"]["Layout_Update"]    = Observable(0) # Tier 1 (Structure)
    controls_obs["State"]["Scene_Update"]     = Observable(0) # Tier 1.5 (Presets/Axes)
    controls_obs["State"]["Primitive_Rebuild"]= Observable(0) # Tier 2 (Blueprint)
    controls_obs["State"]["Data_Sync"]        = Observable(0) # Tier 3 (Render)
    controls_obs["State"]["UI_Update"]        = Observable(0) # Tier 4 (Style)
    controls_obs["State"]["Config_Just_Loaded"] = Observable(false)

    controls_obs["Misc"]["Master_UI_Ref"] = Observable(master_ui)
    
    # Initialize the master cache store: Dict{Plot_Idx, Dict{Method_Name, PlotCache}}
    controls_obs["Misc"]["Plot_Caches"] = Dict{Int, Dict{String, PlotCache}}()

    config_dict = ParamDict(
        "Parameters" => copy(sim_config.varied_params),
        "General"    => Dict{String, Any}(
            "simulation_func" => sim_config.simulation_name, # THE FIX
            "reference_func"  => isnothing(sim_config.reference_name) ? "none" : sim_config.reference_name
        )
    )
    
    manager = PlotManager(
        sim_obs, 
        ui_obs, 
        config_dict, 
        controls_obs, 
        methods_obs, 
        vars, 
        copy(sim_config.shared_params),
        Dict{Int, Dict{String, PlotCache}}() # <-- Initialize the empty caches natively
    )
    switch_ui_plot_type!(manager, init_type)
    
    for (scope, keys_dict) in ui_overwrite
        if haskey(manager.ui, scope)
            for (k, v) in keys_dict
                if haskey(manager.ui[scope], k); manager.ui[scope][k][] = v; end
            end
        end
    end
    return manager
end
"""
    launch_plotter()

Backend-agnostic Single Dashboard entry point. 
Returns the Figure natively so the active backend (GLMakie, WGLMakie) can display it.
"""
function launch_plotter()
    if isnothing(ACTIVE_SIM_CONFIG[])
        ACTIVE_SIM_CONFIG.val = SimulationConfig(
            dummy_simulation_function,"none", nothing, "none", ParamDict(), MethodDict(), String[], VariedDict()
        )
    end

    if PLOTTER_UI_STATE[][:is_open]
        old_manager = ACTIVE_PLOT_MANAGER[]
        new_vars = [collect(keys(ACTIVE_SIM_CONFIG[].varied_params)); BaseVariables]
        
        if old_manager.plot_vars == new_vars
            old_manager.controls["State"]["Simulation_Update"][] += 1
            return PLOTTER_UI_STATE[][:master_fig], old_manager
        else
            @info "Dimensionality changed. Rebuilding UI..."
            PLOTTER_UI_STATE[][:is_open] = false
        end
    end

    ui_overwrite = deepcopy(GLOBAL_UI_OVERWRITE[])
    var_overwrite = deepcopy(GLOBAL_VAR_OVERWRITE[])
    ui_obs = create_master_ui_observables()
    
    manager = create_plot_manager(ACTIVE_SIM_CONFIG[], ui_obs, ui_overwrite, :lines)
    manager.controls["State"]["base_types"][] = var_overwrite
    manager.controls["State"]["Simulation_Update"] = Observable(0)
    manager.controls["State"]["plot_window_initialized"] = Observable(false)
    ACTIVE_PLOT_MANAGER[] = manager

    # ==========================================================================
    # THE FIX: Single Dashboard Architecture
    # ==========================================================================
    master_fig = Figure(size = (1600, 1000))
    
    # Left Panel: Fixed Width Controls
    ctrl_layout = master_fig[1, 1] = GridLayout(width = 550)
    
    # Right Panel: Plotting Area
    plot_layout = master_fig[1, 2] = GridLayout()
    
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())
    
    # Pass layouts instead of figures
    create_controls(ctrl_layout, manager)

    # NOW wire up the logic safely
    setup_ui_interactions!(master_fig, plot_layout, manager, plot_data_obs)

    PLOTTER_UI_STATE[][:is_open] = true
    PLOTTER_UI_STATE[][:master_fig] = master_fig

    # ==========================================================================
    # THE FIX: Purge old listeners from the Global Observable!
    # This prevents closed windows from reacting to new data and crashing the GL buffer.
    # ==========================================================================
    empty!(ACTIVE_SIM_CONFIG.listeners)

    on(ACTIVE_SIM_CONFIG) do new_config
        (isnothing(new_config) || new_config.simulation_func === dummy_simulation_function) && return
        
        # --- THE FIX: Map real physics names to the static abstract UI sliders ---
        real_params = sort(collect(keys(new_config.varied_params)))
        param_map = Dict{String, String}()
        reverse_map = Dict{String, String}()
        
        for i in 1:3
            p_key = "param_$i"
            lbl_obs = manager.controls["String"]["$(p_key)_Label"][]
            
            if i <= length(real_params)
                real_name = real_params[i]
                param_map[p_key] = real_name
                reverse_map[real_name] = p_key
                lbl_obs[] = real_name * ":"  # Rename the UI Label!
            else
                param_map[p_key] = "-"
                lbl_obs[] = "Unused:"
                manager.controls["Widget"][p_key][].range[] = [0.0] # Safely disable slider
            end
        end
        
        manager.controls["State"]["Param_Map"] = Observable(param_map)
        manager.controls["State"]["Reverse_Map"] = Observable(reverse_map)
        manager.plot_vars = [real_params; ["c", "x", "y", "z", "t"]]
        
        manager.config["Parameters"] = copy(new_config.varied_params)
        # THE FIX: Sync the General config so the CSV saves the active functions!
        if !haskey(manager.config, "General"); manager.config["General"] = Dict{String, Any}(); end
        manager.config["General"]["simulation_func"] = new_config.simulation_name
        manager.config["General"]["reference_func"]  = isnothing(new_config.reference_name) ? "none" : new_config.reference_name
        
        # --- The rest proceeds normally without rebooting! ---
        make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
        empty!(manager.simulation)
        manager.simulation["shared"] = Dict(k => make_obs(v) for (k, v) in new_config.shared_params)
        for (m, p) in new_config.methods_dict
            manager.simulation[m] = Dict(k => make_obs(v) for (k, v) in p)
        end

        if isempty(new_config.default_methods)
            manager.methods[] = filter(k -> k != "shared", collect(keys(new_config.methods_dict)))
        else
            manager.methods[] = filter(k -> k != "shared", copy(new_config.default_methods))
        end
        
        # 1. LOCK THE PIPELINE
        manager.controls["State"]["Config_Just_Loaded"][] = true
        
        layout_opts = isempty(GLOBAL_LAYOUT_OPTIONS[]) ? get_base_layout_options() : GLOBAL_LAYOUT_OPTIONS[]
        
        apply_layout_options!(manager, layout_opts)
        
        if !isempty(GLOBAL_UI_OVERWRITE[])
            for (scope, keys_dict) in GLOBAL_UI_OVERWRITE[]
                if haskey(manager.ui, scope)
                    for (k, v) in keys_dict
                        if haskey(manager.ui[scope], k)
                            manager.ui[scope][k].val = v 
                        end
                    end
                end
            end
            GLOBAL_UI_OVERWRITE[] = Dict{String, Any}()
            manager.controls["State"]["UI_Update"][] += 1
        end

        # 2. UNLOCK THE PIPELINE AND FIRE ONCE
        manager.controls["State"]["Config_Just_Loaded"][] = false
        manager.controls["State"]["Layout_Update"][] += 1
    end

    on(manager.controls["State"]["Simulation_Update"]) do _
        curr_config = ACTIVE_SIM_CONFIG[]
        if curr_config.simulation_func === dummy_simulation_function; return; end
        Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[], to_value(manager.controls["State"]["base_types"]); force_reload = true)
        
        notify(plot_data_obs)
        manager.controls["State"]["Primitive_Rebuild"][] += 1
    end

    setup_plot_window!(master_fig, plot_layout, manager, plot_data_obs)

    if ACTIVE_SIM_CONFIG[].simulation_func !== dummy_simulation_function
        manager.controls["State"]["Simulation_Update"][] += 1
    end

    return master_fig, manager # Native return for WGLMakie/GLMakie to display
end
# ==============================================================================
# --- 3. LAYOUT & RENDER HANDLERS ---
# ==============================================================================
function setup_plot_window!(master_fig::Figure, plot_layout::GridLayout, manager::PlotManager, plot_data_obs::Observable)
    if manager.controls["State"]["plot_window_initialized"][]; return; end
    manager.controls["State"]["plot_window_initialized"][] = true

    render_observers = ObserverFunction[]

    function rebuild_plot_layout!()
        ptype_sym = manager.controls["Selection"]["Plot_Type"][]
        for obs in render_observers; off(obs); end
        empty!(render_observers)
        
        empty!(manager.caches)
        
        # Safely Purge ONLY the Plot Layout
        for c in copy(plot_layout.content)
            if c.content isa Makie.Block
                delete!(c.content)
            end
        end
        trim!(plot_layout)
        
        switch_ui_plot_type!(manager, ptype_sym)
        
        new_obs = setup_render_lift!(master_fig, plot_layout, plot_data_obs, manager, Val(ptype_sym))
        if !isnothing(new_obs); append!(render_observers, new_obs); end
        
        # The dropdowns populate, sync safely aborts, then rebuild runs!
        notify(plot_data_obs)
        manager.controls["State"]["Primitive_Rebuild"][] += 1
    end

    # --- TIER 1: Layout Rebuild ---
    on(manager.controls["State"]["Layout_Update"]) do _
        curr_config = ACTIVE_SIM_CONFIG[]
        if curr_config.simulation_func != "none" && !isnothing(curr_config.simulation_func)
            Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[], to_value(manager.controls["State"]["base_types"]); force_reload = false)
        end
        rebuild_plot_layout!()
    end

    # --- TIER 1.5: Scene Options Update ---
    on(manager.controls["State"]["Scene_Update"]) do _
        curr_config = ACTIVE_SIM_CONFIG[]
        if curr_config.simulation_func != "none" && !isnothing(curr_config.simulation_func)
            Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[], to_value(manager.controls["State"]["base_types"]); force_reload = false)
        end
        # Changing X/Y axes requires us to rebind the observables, so trigger a rebuild
        manager.controls["State"]["Primitive_Rebuild"][] += 1
    end

    onany(
        manager.controls["Selection"]["X-Axis"],
        manager.controls["Selection"]["Y-Axis"],
        manager.controls["Selection"]["Z-Axis"],
        manager.controls["Selection"]["U-Axis"],
        manager.controls["Selection"]["c"]
    ) do _...
        if manager.controls["State"]["Config_Just_Loaded"][]; return; end
        manager.controls["State"]["Primitive_Rebuild"][] += 1
    end
    # 2. Wire the Structural Menus to ping the Layout trigger
    onany(
        manager.controls["Selection"]["Plot_Type"], manager.controls["Selection"]["Compare_Target"], 
        manager.controls["Selection"]["Compare_Columns"], manager.controls["Selection"]["Compare_Link"],
        manager.controls["Selection"]["Plot_Width"], manager.controls["Selection"]["Plot_Height"]
    ) do _...
        if manager.controls["State"]["Config_Just_Loaded"][]; return; end
        manager.controls["State"]["Layout_Update"][] += 1
    end

    # 3. Smart Legend Routing
    prev_leg_struct = Ref((false, :none, :none))
    onany(manager.controls["Selection"]["Legend_Base"], manager.controls["Selection"]["Legend_Add"]) do _...
        if manager.controls["State"]["Config_Just_Loaded"][]; return; end
        is_comp = manager.controls["Selection"]["Compare_Target"][] != "None"
        curr = _parse_legend_position(manager, is_comp)
        p = prev_leg_struct[]
        
        if (!curr[1] && !p[1])
            # If it's just moving around inside the axis, we only need to update the UI/Render
            manager.controls["State"]["UI_Update"][] += 1
        else
            # If it changes from attached to detached, we need a structural layout rebuild
            prev_leg_struct[] = curr
            manager.controls["State"]["Layout_Update"][] += 1
        end
    end

    rebuild_plot_layout!()
end

function setup_render_lift!(master_fig::Figure, plot_layout::GridLayout, plot_data_obs::Observable, manager::PlotManager, ::Val{T}) where T
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || T == :surface
    c = manager.controls 
    
    rev_map = haskey(c["State"], "Reverse_Map") ? c["State"]["Reverse_Map"][] : Dict{String, String}()
    
    selector_obs = map(manager.plot_vars) do n
        w_key = haskey(rev_map, n) ? rev_map[n] : n
        haskey(c["Value"], w_key) ? c["Value"][w_key] : c["Selection"][w_key]
    end

    x_sel, y_sel = c["Selection"]["X-Axis"], c["Selection"]["Y-Axis"]
    z_sel, u_sel = c["Selection"]["Z-Axis"], c["Selection"]["U-Axis"]
    
    target = c["Selection"]["Compare_Target"][]
    cols = parse(Int, c["Selection"]["Compare_Columns"][])
    link_mode = c["Selection"]["Compare_Link"][]
    
    num_plots, compare_labels, compare_vals = 1, String[], Any[]
    
    plot_data_dict = plot_data_obs[]
    if !isempty(plot_data_dict)
        pd_first = first(values(plot_data_dict))
        if target == "Methods"
            compare_labels = manager.methods[]
            num_plots = length(compare_labels)
        elseif target == "Component"
            n_params = length(manager.plot_vars) - 5
            target_tensor = haskey(pd_first.data, u_sel[]) ? pd_first.data[u_sel[]] : pd_first.data["u"]
            num_plots = size(target_tensor, n_params + 1) # THE FIX: Component is n_params + 1
            
            comp_names_tuple = manager.ui["Labels"]["comp_names"][]
            compare_labels = String[]
            for i in 1:num_plots
                if comp_names_tuple isa Tuple && length(comp_names_tuple) >= i && comp_names_tuple[i] != "default" && !isempty(string(comp_names_tuple[i]))
                    push!(compare_labels, string(comp_names_tuple[i]))
                else
                    push!(compare_labels, "Component $i")
                end
            end
            compare_vals = collect(1:num_plots)
        elseif target == "Time"
            num_plots = length(pd_first.t_vals)
            compare_labels = ["t = $(round(t, sigdigits=4))" for t in pd_first.t_vals]
            compare_vals = pd_first.t_vals
        elseif target in manager.plot_vars
            idx = findfirst(isequal(target), manager.plot_vars)
            vals = pd_first.active_param_values[idx]
            num_plots = length(vals)
            compare_labels = ["$target = $(round(v, sigdigits=4))" for v in vals]
            compare_vals = vals
        end
    end
    
    if target == "None" || num_plots == 0
        num_plots = 1; target = "None"
    end
    
    is_compare = target != "None"
    is_det, halign, valign = _parse_legend_position(manager, is_compare)
    has_legend = T in (:lines, :contourf, :contour, :contour3d)
    has_colorbar = T in (:heatmap, :scatter2d, :contourf, :scatter3d, :surface, :volume)
    has_legend &= target != "Methods"

    layout_dict = calculate_layout_dictionary(num_plots, cols, link_mode, has_legend, is_det, halign, valign, has_colorbar)
    manager.controls["Misc"]["Layout_Dict"] = Observable(layout_dict)
    
    axes = []
    for i in 1:num_plots
        r, c_idx = layout_dict["Plots"][i]
        ax = is_3d_axis ? Axis3(plot_layout[r, c_idx], perspectiveness=0.5) : Axis(plot_layout[r, c_idx])
        push!(axes, ax)
    end
    
    # Resize the sub-layout
    p_w = parse(Int, manager.controls["Selection"]["Plot_Width"][])
    p_h = parse(Int, manager.controls["Selection"]["Plot_Height"][])
    for i in 1:plot_layout.size[1]; rowsize!(plot_layout, i, Auto()); end
    for i in 1:plot_layout.size[2]; colsize!(plot_layout, i, Auto()); end
    
    for i in 1:num_plots
        r, c_idx = layout_dict["Plots"][i]
        rowsize!(plot_layout, r, Fixed(p_h))
        colsize!(plot_layout, c_idx, Fixed(p_w))
    end
    
    if !is_3d_axis && link_mode in ("Fully Coupled", "Axes Only")
        linkaxes!(axes...)
    end
    
    # --- MODULAR RENDER HELPERS ---
    function _render_no_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        data_tuples, valid_labels, title_str = extract_data(data, manager, sel_vals, x_key, y_key, z_key, u_key, Val(PLOT_DIM_MAP[T]))
        
        has_cr = haskey(ui_app, "colorrange")
        orig_cr = has_cr ? ui_app["colorrange"].val : "default"
        if has_cr && orig_cr == "default"
            u_all = Float64[]
            for us in data_tuples[end]; append!(u_all, filter(isfinite, us)); end
            l_u, h_u = isempty(u_all) ? (0.0, 1.0) : (minimum(u_all), maximum(u_all))
            if l_u == h_u; h_u += 1e-6; end
            ui_app["colorrange"].val = (l_u, h_u) 
        end

        update_base_plot!(plot_layout, axes[1], valid_labels, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, Val(T), 1)
        if !is_3d_axis; plot_HUD!(axes[1], manager); end
        if has_cr; ui_app["colorrange"].val = orig_cr; end
    end

    function _render_method_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        data_tuples, valid_labels, title_str = extract_data(data, manager, sel_vals, x_key, y_key, z_key, u_key, Val(PLOT_DIM_MAP[T]))
        
        has_cr = haskey(ui_app, "colorrange")
        orig_cr = has_cr ? ui_app["colorrange"].val : "default"
        
        if has_cr && orig_cr == "default" && link_mode != "Decoupled"
            u_all = Float64[]
            for us in data_tuples[end]; append!(u_all, filter(isfinite, us)); end
            l_u, h_u = isempty(u_all) ? (0.0, 1.0) : (minimum(u_all), maximum(u_all))
            if l_u == h_u; h_u += 1e-6; end
            ui_app["colorrange"].val = (l_u, h_u) 
        end
        
        orig_title = manager.ui["Labels"]["title"].val
        orig_title_size = manager.ui["Axis-General"]["title_size"].val
        manager.ui["Axis-General"]["title_size"].val = manager.ui["Axis-General"]["label_size"].val 
        
        for (i, label) in enumerate(valid_labels)
            if i > length(axes); break; end
            single_tuples = Tuple([dt[i]] for dt in data_tuples)
            manager.ui["Labels"]["title"].val = label
            update_base_plot!(plot_layout, axes[i], [label], single_tuples, manager, x_key, y_key, z_key, u_key, label, Val(T), i)
            if !is_3d_axis; plot_HUD!(axes[i], manager); end
        end
        
        manager.ui["Labels"]["title"].val = orig_title
        manager.ui["Axis-General"]["title_size"].val = orig_title_size
        if has_cr; ui_app["colorrange"].val = orig_cr; end
    end

    function _render_variable_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        target_idx = target == "Component" ? findfirst(isequal("c"), manager.plot_vars) :
                     target == "Time" ? findfirst(isequal("t"), manager.plot_vars) :
                     findfirst(isequal(target), manager.plot_vars)

        u_all = Float64[]
        all_subplots_data = []
        
        for i in 1:num_plots
            mutated_sel_vals = collect(sel_vals)
            mutated_sel_vals[target_idx] = compare_vals[i]
            dt, vl, ts = extract_data(data, manager, mutated_sel_vals, x_key, y_key, z_key, u_key, Val(PLOT_DIM_MAP[T]))
            push!(all_subplots_data, (dt, vl, ts))
            for us in dt[end]; append!(u_all, filter(isfinite, us)); end
        end
        
        has_cr = haskey(ui_app, "colorrange")
        orig_cr = has_cr ? ui_app["colorrange"].val : "default"
        
        if has_cr && orig_cr == "default" && link_mode != "Decoupled"
            l_u, h_u = isempty(u_all) ? (0.0, 1.0) : (minimum(u_all), maximum(u_all))
            if l_u == h_u; h_u += 1e-6; end
            ui_app["colorrange"].val = (l_u, h_u) 
        end
        
        orig_title = manager.ui["Labels"]["title"].val
        orig_title_size = manager.ui["Axis-General"]["title_size"].val
        manager.ui["Axis-General"]["title_size"].val = manager.ui["Axis-General"]["label_size"].val 
        
        for i in 1:num_plots
            if i > length(axes); break; end
            dt, vl, ts = all_subplots_data[i]
            label = compare_labels[i]
            manager.ui["Labels"]["title"].val = label
            update_base_plot!(plot_layout, axes[i], vl, dt, manager, x_key, y_key, z_key, u_key, label, Val(T), i)
            if !is_3d_axis; plot_HUD!(axes[i], manager); end
        end
        
        manager.ui["Labels"]["title"].val = orig_title
        manager.ui["Axis-General"]["title_size"].val = orig_title_size
        if has_cr; ui_app["colorrange"].val = orig_cr; end
    end
    # --- THE FIX: The missing comparison mutator ---
    target_idx = target == "Component" ? findfirst(isequal("c"), manager.plot_vars) :
                 target == "Time"      ? findfirst(isequal("t"), manager.plot_vars) :
                 findfirst(isequal(target), manager.plot_vars)

    function _mutate_compare_vals(current_sels, idx)
        mutated = collect(current_sels)
        if !isnothing(target_idx) && !isempty(compare_vals) && idx <= length(compare_vals)
            mutated[target_idx] = compare_vals[idx]
        end
        return mutated
    end
    # --- THE RENDER LOOP ---
    # =========================================================================
    # TIER 2: PRIMITIVE REBUILD
    # =========================================================================
    prim_obs = on(manager.controls["State"]["Primitive_Rebuild"]) do _
        # 1. Base Pre-Flight Check
        (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == "-" || u_sel[] == "-") && return
        
        # 2. Dimensional Pre-Flight Check (THE FIX)
        if PLOT_DIM_MAP[T] >= 2
            (isnothing(y_sel[]) || y_sel[] == "-" || y_sel[] == "disabled") && return
        end
        if PLOT_DIM_MAP[T] >= 3
            (isnothing(z_sel[]) || z_sel[] == "-" || z_sel[] == "disabled") && return
        end
        
        data = plot_data_obs[]
        isempty(data) && return
        
        # 1. Clear old caches natively
        empty!(manager.caches)
        
        for ax in axes
            empty!(ax)
            if !is_3d_axis; ax.xscale[] = identity; ax.yscale[] = identity; end
        end
        
        ui_app = manager.ui["Plot-Style"]
        sel_vals = [to_value(obs) for obs in selector_obs]

        for i in 1:num_plots
            manager.caches[i] = Dict{String, PlotCache}()
            
            mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
            dt, vl, ts = extract_data(data, manager, mutated_sel_vals, x_sel[], y_sel[], z_sel[], u_sel[], Val(PLOT_DIM_MAP[T]))
            
            local_methods = manager.methods[]
            if target == "Methods" && i <= length(vl)
                vl = [vl[i]]
                dt = Tuple([slice[i]] for slice in dt)
                local_methods = [manager.methods[][i]]
            end
            
            initialize_base_plot!(plot_layout, axes[i], vl, dt, manager, x_sel[], y_sel[], z_sel[], u_sel[], ts, Val(T), i)
            
            if !is_3d_axis; 
                plot_HUD!(axes[i], manager)
                set_axis_limits_manager!(axes[i], dt[1], dt[2], manager)
            end
        end
        
        manager.controls["State"]["UI_Update"][] += 1
    end

    # =========================================================================
    # TIER 3: DATA SYNC
    # =========================================================================
    # =========================================================================
    # TIER 3: DATA SYNC
    # =========================================================================
    data_sync_obs = onany(plot_data_obs, selector_obs...) do data, sel_vals...
        # 1. Base Pre-Flight Check
        (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == "-" || u_sel[] == "-") && return
        
        # 2. Dimensional Pre-Flight Check (THE FIX)
        if PLOT_DIM_MAP[T] >= 2
            (isnothing(y_sel[]) || y_sel[] == "-" || y_sel[] == "disabled") && return
        end
        if PLOT_DIM_MAP[T] >= 3
            (isnothing(z_sel[]) || z_sel[] == "-" || z_sel[] == "disabled") && return
        end
        # 1. Native access!
        caches = manager.caches
        (isempty(data) || isempty(caches)) && return
        
        for i in 1:num_plots
            mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
            dt, vl, ts = extract_data(data, manager, mutated_sel_vals, x_sel[], y_sel[], z_sel[], u_sel[], Val(PLOT_DIM_MAP[T]))
            
            local_methods = manager.methods[]
            if target == "Methods" && i <= length(vl)
                vl = [vl[i]]
                dt = Tuple([slice[i]] for slice in dt)
                local_methods = [manager.methods[][i]]
            end
            
            sync_data_to_cache!(caches[i], vl, dt, Val(PLOT_DIM_MAP[T]))
            
            # THE FIX: Force overwrite the title for comparisons
            default_title = is_compare ? compare_labels[i] : ts
            axes[i].title[] = manager.ui["Labels"]["title"][] == "default" ? default_title : manager.ui["Labels"]["title"][]
            
            if !is_3d_axis
                set_axis_limits_manager!(axes[i], dt[1], dt[2], manager)
            end
        end
        
        for ax in axes; apply_axis_limits_overrides!(ax, manager); end
    end
    # =========================================================================
    # TIER 4: UI & STYLE MUTATION 
    # =========================================================================
    ui_obs = on(manager.controls["State"]["UI_Update"]) do _
        ui_gen = manager.ui["Axis-General"]
        ui_app = manager.ui["Plot-Style"]
        
        x_str = manager.controls["Selection"]["X-Axis"][]
        y_str = manager.controls["Selection"]["Y-Axis"][]
        z_str = manager.controls["Selection"]["Z-Axis"][]
        u_str = manager.controls["Selection"]["U-Axis"][]
        
        for (i, ax) in enumerate(axes)
            # 1. Update Labels natively
            if is_3d_axis
                set_axis_styles!(ax, manager, string(x_str), string(y_str), string(z_str), ax.title[])
            elseif PLOT_DIM_MAP[T] == 1
                set_axis_styles!(ax, manager, string(x_str), string(u_str), ax.title[])
            else
                set_axis_styles!(ax, manager, string(x_str), string(y_str), ax.title[])
            end
            apply_axis_limits_overrides!(ax, manager)
            
            # 2. Mutate Primitive Styles natively
            if haskey(manager.caches, i)
                for (m_idx, method_name) in enumerate(manager.methods[])
                    if haskey(manager.caches[i], method_name)
                        prims = manager.caches[i][method_name].primitives
                        color = ui_app["colors"][][mod1(m_idx, end)]
                        
                        if haskey(prims, "line")
                            prims["line"].color[] = color
                            prims["line"].linewidth[] = ui_app["linewidth"][]
                            prims["line"].linestyle[] = ui_app["dashed_lines"][] ? ui_app["lineStyles"][][mod1(m_idx, end)] : :solid
                            prims["line"].visible[] = ui_app["show_lines"][]
                        end
                        if haskey(prims, "scatter")
                            prims["scatter"].color[] = color
                            prims["scatter"].markersize[] = ui_app["markersize"][]
                            prims["scatter"].marker[] = ui_app["markers"][][mod1(m_idx, end)]
                            prims["scatter"].visible[] = ui_app["show_scatter"][]
                        end
                        if haskey(prims, "contour")
                            prims["contour"].color[] = color
                            prims["contour"].linewidth[] = ui_app["linewidth"][]
                        end
                        if haskey(prims, "volume");    prims["volume"].colormap[]    = ui_app["colormap"][]; end
                        if haskey(prims, "heatmap");   prims["heatmap"].colormap[]   = ui_app["colormap"][]; end
                        if haskey(prims, "surface");   prims["surface"].colormap[]   = ui_app["colormap"][]; end
                        if haskey(prims, "contourf");  prims["contourf"].colormap[]  = ui_app["colormap"][]; end
                        
                        if haskey(prims, "scatter2d")
                            prims["scatter2d"].colormap[] = ui_app["colormap"][]
                            prims["scatter2d"].markersize[] = ui_app["markersize"][]
                        end
                        if haskey(prims, "scatter3d")
                            prims["scatter3d"].colormap[] = ui_app["colormap"][]
                            prims["scatter3d"].markersize[] = ui_app["markersize"][]
                        end
                    end
                end
            end
        end
        
        # 3. Dynamic Legend Builder!
        # Physically removes elements from the legend if they are toggled off in the UI
        if !is_3d_axis && T in (:lines, :contour, :contourf) && haskey(manager.caches, 1)
            plotted_objects = []
            labels_for_legend = String[]
            
            for (m_idx, method_name) in enumerate(manager.methods[])
                if haskey(manager.caches[1], method_name)
                    prims = manager.caches[1][method_name].primitives
                    color = ui_app["colors"][][mod1(m_idx, end)]
                    
                    if haskey(prims, "contourf")
                        push!(plotted_objects, [Makie.PolyElement(color=Makie.to_colormap(ui_app["colormap"][])[end])])
                        push!(labels_for_legend, "$(method_name) (Base)")
                    end
                    
                    group = []
                    if haskey(prims, "line") && ui_app["show_lines"][]
                        ls = ui_app["dashed_lines"][] ? ui_app["lineStyles"][][mod1(m_idx, end)] : :solid
                        push!(group, Makie.LineElement(color=color, linewidth=ui_app["linewidth"][], linestyle=ls))
                    end
                    if haskey(prims, "scatter") && ui_app["show_scatter"][]
                        mrk = ui_app["markers"][][mod1(m_idx, end)]
                        push!(group, Makie.MarkerElement(color=color, marker=mrk, markersize=ui_app["markersize"][]))
                    end
                    if haskey(prims, "contour")
                        push!(group, Makie.LineElement(color=color, linewidth=ui_app["linewidth"][]))
                    end
                    
                    if !isempty(group)
                        push!(plotted_objects, group)
                        if !haskey(prims, "contourf"); push!(labels_for_legend, method_name); end
                    end
                end
            end
            create_or_update_legend!(plot_layout, plotted_objects, labels_for_legend, manager)
        end
    end
    return ObserverFunction[prim_obs; data_sync_obs; ui_obs]
end