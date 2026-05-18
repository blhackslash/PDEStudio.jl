include("UIStyles.jl")
include("PlottingUtils.jl")
include("ControlUtils.jl")
include("Controls.jl")
include("Render.jl")
include("CSVLauncher.jl")

# ==============================================================================
# --- GLOBAL UI STATE REFERENCES ---
# ==============================================================================
const GLOBAL_UI_OVERWRITE = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_VAR_OVERWRITE = Ref{Vector{Any}}(Any[:menu, :slider, :slider, :slider, :slider])
const GLOBAL_SCENE_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())

function create_plot_manager(sim_config::SimulationConfig{F}, master_ui::Dict, ui_overwrite::Dict, init_type::Symbol) where {F}
    varied_dict = sim_config.varied_params
    vars = isempty(varied_dict) ? [] : collect(keys(varied_dict))
    append!(vars, BaseVariables)

    base_types = Observable{Vector{Any}}([[:menu]; [:slider for _ in 2:5]])
    sim_obs = NestedObsDict()
    
    make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
    sim_obs["shared"] = Dict(k => make_obs(v) for (k, v) in sim_config.shared_params)
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => make_obs(v) for (k, v) in m_params)
    end

    # 1. Start with an empty active UI dictionary
    ui_obs = NestedObsDict()

    methods_obs = Observable(copy(sim_config.default_methods))

    # 2. Stash the Master Dictionary reference safely
    controls_obs = Dict{String, Observable}(
        "base_types" => base_types, 
        "Master_UI_Ref" => Observable(master_ui)
    )

    config_dict = ParamDict(
        "Parameters" => copy(sim_config.varied_params),
        "General"    => Dict{String, Any}(
            "simulation_func" => string(sim_config.simulation_func),
            "reference_func"  => isnothing(sim_config.reference_name) ? "none" : string(sim_config.reference_name)
        )
    )

    
    manager = PlotManager(sim_obs, ui_obs, config_dict, controls_obs, methods_obs, vars, copy(sim_config.shared_params))
    
    switch_ui_plot_type!(manager, init_type)
    
    # THE FIX: Apply UI Overwrites directly to the manager's active UI!
    for (scope, keys_dict) in ui_overwrite
        if haskey(manager.ui, scope)
            for (k, v) in keys_dict
                if haskey(manager.ui[scope], k)
                    manager.ui[scope][k][] = v
                end
            end
        end
    end
    
    return manager
end
function show_unified_fig(sim_config::SimulationConfig)
    # --- 1. Load from Global Refs ---
    ui_overwrite = deepcopy(GLOBAL_UI_OVERWRITE[])
    var_overwrite = deepcopy(GLOBAL_VAR_OVERWRITE[])
    scene_options = deepcopy(GLOBAL_SCENE_OPTIONS[])

    ui_obs = create_master_ui_observables()
    
    # --- 2. Flatten and Merge Scene Options ---
    final_scene = get_base_scene_options()
    
    if haskey(scene_options, "Menu")
        for (k, v) in scene_options["Menu"]; final_scene["$(k)_Selection"] = v; end
    end
    if haskey(scene_options, "Slider")
        for (k, v) in scene_options["Slider"]; final_scene["$(k)_Value"] = v; end
    end
    for (k, v) in scene_options
        if k != "Menu" && k != "Slider"; final_scene[k] = v; end
    end
    
    raw_type = get(final_scene, "Plot-Type_Selection", "Lines")
    init_type = raw_type isa String ? Symbol(lowercase(replace(raw_type, " " => ""))) : raw_type

    # --- 3. Setup Manager & Figure ---
    GLMakie.activate!()
    
    manager = create_plot_manager(sim_config, ui_obs, ui_overwrite, init_type)
    plot_fig = Figure(size = manager.ui["Axis-General"]["figsize"][])
    plot_screen_ref = Ref(GLMakie.Screen(title = "Makie Plot"))
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())
    
    # --- 4. INITIALIZATION SEQUENCE ---
    manager.controls["base_types"][] = var_overwrite
    ctrl_fig = create_controls(plot_fig, manager, plot_data_obs, final_scene)    
    
    sim_update = manager.controls["Simulation_Update"]
    methods_obs = manager.methods

    on(sim_update) do _
        if !GLMakie.isopen(plot_screen_ref[])
            plot_screen_ref[] = GLMakie.Screen(title = "Makie Plot")
            display(plot_screen_ref[], plot_fig)
        end
    end

    # --- 5. RENDER PIPELINE & DIMENSION SWITCHING ---
    render_observers = ObserverFunction[]

    # THE FIX: A unified rebuilder that safely orchestrates the teardown and setup!
    function rebuild_plot_layout!()
        ptype_sym = manager.controls["Plot-Type_Selection"][]
        
        # 1. KILL the old render loops FIRST so they don't accidentally fire
        for obs in render_observers; off(obs); end
        empty!(render_observers)
        empty!(plot_fig)
        
        # 2. NOW it is safe to swap the UI styles without the old plot crashing!
        switch_ui_plot_type!(manager, ptype_sym)
        
        # 3. Create the new render loop
        new_obs = setup_render_lift!(plot_fig, plot_data_obs, manager, Val(ptype_sym))
        
        if !isnothing(new_obs)
            append!(render_observers, new_obs)
        end
        
        # 4. Safe public API to preserve 3D interactivity
        scr = plot_screen_ref[]
        if GLMakie.isopen(scr)
            try
                GLMakie.close(scr) 
            catch e
                @debug "Screen close suppressed: $e"
            end
        end
        
        plot_screen_ref[] = GLMakie.Screen(title = "Makie Plot")
        display(plot_screen_ref[], plot_fig)
        notify(plot_data_obs)
    end

    onany(sim_update, methods_obs) do _, active_methods
        Base.invokelatest(update_plot_data_collection!,
            plot_data_obs[], sim_config, manager, active_methods, to_value(manager.controls["base_types"]);
            force_reload = (sim_update[] > 0), 
        )
        
        if manager.controls["Compare_Mode"][]
            rebuild_plot_layout!()
        else
            notify(plot_data_obs)
        end
    end

    on(manager.controls["Plot-Type_Selection"]) do ptype_sym
        rebuild_plot_layout!()
    end

    on(manager.controls["Compare_Mode"]) do _
        rebuild_plot_layout!()
    end

    notify(manager.controls["Plot-Type_Selection"])
    sim_update[] = 1 
    
    return plot_fig, ctrl_fig, manager
end
function setup_render_lift!(plot_fig::Figure, plot_data_obs::Observable, manager::PlotManager, ::Val{T}) where T
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || T == :surface
    c = manager.controls; selector_obs = [haskey(c, "$(n)_Value") ? c["$(n)_Value"] : c["$(n)_Selection"] for n in manager.plot_vars]
    x_sel = c["X-Axis_Selection"]
    y_sel = c["Y-Axis_Selection"]
    z_sel = c["Z-Axis_Selection"]
    u_sel = c["U-Axis_Selection"]
    
    # --- THE FIX: Create Axes OUTSIDE the render loop, perfectly mimicking your original code! ---
    compare_mode = get(c, "Compare_Mode", Observable(false))[]
    active_methods = manager.methods[]
    num_methods = length(active_methods)
    
    axes = []
    if compare_mode && num_methods > 1
        grid_layout = plot_fig[1, 1] = GridLayout()
        for i in 1:num_methods
            row = (i - 1) ÷ 2 + 1
            col = (i - 1) % 2 + 1
            ax = is_3d_axis ? Axis3(grid_layout[row, col], perspectiveness=0.5) : Axis(grid_layout[row, col])
            push!(axes, ax)
        end
        if !is_3d_axis; linkaxes!(axes...); end
    else
        ax = is_3d_axis ? Axis3(plot_fig[1, 1], perspectiveness=0.5) : Axis(plot_fig[1, 1])
        push!(axes, ax)
    end
    # -----------------------------------------------------------------------------------------
    
    render_obs = onany(plot_data_obs, x_sel, y_sel, z_sel, u_sel, c["UI_Update"], selector_obs...) do data, x_key, y_key, z_key, u_key, _ui, sel_vals...
        (isnothing(x_key) || isnothing(u_key) || x_key == "-" || u_key == "-") && return
        isempty(data) && return
        
        # 1. Dispatch Data Extraction
        data_tuples, valid_labels, title_str = extract_data(data, manager, sel_vals, x_key, y_key, z_key, u_key, Val(PLOT_DIM_MAP[T]))
        
        ui_app = manager.ui["Plot-Style"]
        
        # --- THE MAKIE LIFESAVER: TEMPORARY IDENTITY SCALES ---
        for ax in axes
            if !is_3d_axis
                ax.xscale[] = identity
                ax.yscale[] = identity
            end
        end
        
        # Global Colorrange
        has_cr = haskey(ui_app, "colorrange")
        orig_cr = has_cr ? ui_app["colorrange"].val : "default"
        
        if has_cr && orig_cr == "default"
            u_all = Float64[]
            for us in data_tuples[end]
                append!(u_all, filter(isfinite, us))
            end
            l_u, h_u = isempty(u_all) ? (0.0, 1.0) : (minimum(u_all), maximum(u_all))
            if l_u == h_u; h_u += 1e-6; end
            ui_app["colorrange"].val = (l_u, h_u) 
        end

        # 2. Dispatch Plotting safely! 
        if compare_mode && length(valid_labels) > 1
            orig_leg_pos = manager.ui["Axis-General"]["legend_pos"].val
            orig_title = manager.ui["Labels"]["title"].val
            orig_title_size = manager.ui["Axis-General"]["title_size"].val
            
            manager.ui["Axis-General"]["legend_pos"].val = "none"
            manager.ui["Axis-General"]["title_size"].val = manager.ui["Axis-General"]["label_size"].val 
            
            for (i, label) in enumerate(valid_labels)
                if i > length(axes); break; end # Safety check
                ax = axes[i]
                single_tuples = Tuple([dt[i]] for dt in data_tuples)
                manager.ui["Labels"]["title"].val = label
                
                update_base_plot!(plot_fig, ax, [label], single_tuples, manager, x_key, y_key, z_key, u_key, label, Val(T))
                
                if !is_3d_axis
                    plot_HUD!(ax, manager)
                end
            end
            
            manager.ui["Labels"]["title"].val = orig_title
            manager.ui["Axis-General"]["legend_pos"].val = orig_leg_pos
            manager.ui["Axis-General"]["title_size"].val = orig_title_size
        else
            ax = axes[1]
            update_base_plot!(plot_fig, ax, valid_labels, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, Val(T))
            
            if !is_3d_axis
                plot_HUD!(ax, manager)
            end
        end
        
        if has_cr; ui_app["colorrange"].val = orig_cr; end
    end
    return render_obs
end