include("UIStyles.jl")
include("PlottingUtils.jl")
include("ControlUtils.jl")
include("Controls.jl")
include("InteractionController.jl") # <-- The new Logic Controller
include("Render.jl")

# ==============================================================================
# --- GLOBAL UI STATE REFERENCES ---
# ==============================================================================
const GLOBAL_UI_OVERWRITE = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_VAR_OVERWRITE = Ref{Vector{Any}}(Any[:menu, :slider, :slider, :slider, :slider])
const GLOBAL_SCENE_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())

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
    vars = isempty(varied_dict) ? [] : collect(keys(varied_dict))
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
    
    # THE FIX: Initialize it directly into the state store!
    controls_obs["State"]["UI_Update"] = Observable(0) 
    controls_obs["State"]["Config_Just_Loaded"] = Observable(false)

    controls_obs["Misc"]["Master_UI_Ref"] = Observable(master_ui)

    config_dict = ParamDict(
        "Parameters" => copy(sim_config.varied_params),
        "General"    => Dict{String, Any}(
            "simulation_func" => sim_config.simulation_name, # THE FIX
            "reference_func"  => isnothing(sim_config.reference_name) ? "none" : sim_config.reference_name
        )
    )
    
    manager = PlotManager(sim_obs, ui_obs, config_dict, controls_obs, methods_obs, vars, copy(sim_config.shared_params))
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
        real_params = collect(keys(new_config.varied_params))
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
        
        manager.controls["State"]["Config_Just_Loaded"][] = true
        manager.controls["State"]["Simulation_Update"][] += 1
    end

    on(manager.controls["State"]["Simulation_Update"]) do _
        curr_config = ACTIVE_SIM_CONFIG[]
        if curr_config.simulation_func === dummy_simulation_function; return; end
        Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[], to_value(manager.controls["State"]["base_types"]); force_reload = true)
        notify(plot_data_obs)
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
        
        # ==========================================================================
        # THE FIX: Safely Purge ONLY the Plot Layout (Leaves controls untouched!)
        # ==========================================================================
        for c in copy(plot_layout.content)
            if c.content isa Makie.Block
                delete!(c.content)
            end
        end
        trim!(plot_layout)
        
        switch_ui_plot_type!(manager, ptype_sym)
        
        new_obs = setup_render_lift!(master_fig, plot_layout, plot_data_obs, manager, Val(ptype_sym))
        if !isnothing(new_obs); append!(render_observers, new_obs); end
        
        notify(plot_data_obs)
    end

    onany(
        manager.controls["Selection"]["Plot_Type"], manager.controls["Selection"]["Compare_Target"], 
        manager.controls["Selection"]["Compare_Columns"], manager.controls["Selection"]["Compare_Link"],
        manager.controls["Selection"]["Plot_Width"], manager.controls["Selection"]["Plot_Height"]
    ) do _...
        curr_config = ACTIVE_SIM_CONFIG[]
        if curr_config.simulation_func != "none" && !isnothing(curr_config.simulation_func)
            Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[], to_value(manager.controls["State"]["base_types"]); force_reload = false)
        end
        rebuild_plot_layout!()
    end

    prev_leg_struct = Ref((false, :none, :none))
    onany(manager.controls["Selection"]["Legend_Base"], manager.controls["Selection"]["Legend_Add"]) do _...
        is_comp = manager.controls["Selection"]["Compare_Target"][] != "None"
        curr = _parse_legend_position(manager, is_comp)
        p = prev_leg_struct[]
        if (!curr[1] && !p[1]); notify(plot_data_obs) 
        else; prev_leg_struct[] = curr; rebuild_plot_layout!(); end
    end

    rebuild_plot_layout!()
end

function setup_render_lift!(master_fig::Figure, plot_layout::GridLayout, plot_data_obs::Observable, manager::PlotManager, ::Val{T}) where T
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || T == :surface
    c = manager.controls 
    
    # MVC Map the selectors safely
    selector_obs = [haskey(c["Value"], n) ? c["Value"][n] : c["Selection"][n] for n in manager.plot_vars]
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
            comp_idx = findfirst(isequal("c"), manager.plot_vars)
            num_plots = size(pd_first.data["u"], comp_idx - (length(manager.plot_vars) - 5))
            compare_labels = ["Component $i" for i in 1:num_plots]
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

    # --- THE RENDER LOOP ---
    render_obs = onany(plot_data_obs, x_sel, y_sel, z_sel, u_sel, c["State"]["UI_Update"], selector_obs...) do data, x_key, y_key, z_key, u_key, _ui, sel_vals...
        (isnothing(x_key) || isnothing(u_key) || x_key == "-" || u_key == "-") && return
        isempty(data) && return

        for ax in axes
            if !is_3d_axis; ax.xscale[] = identity; ax.yscale[] = identity; end
        end
        
        ui_app = manager.ui["Plot-Style"]
        
        if target == "None" || num_plots <= 1
            _render_no_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        elseif target == "Methods"
            _render_method_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        else
            _render_variable_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        end
        resize_to_layout!()
    end
    return render_obs
end