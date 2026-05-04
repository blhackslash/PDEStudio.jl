include("UIStyles.jl")
include("PlottingUtils.jl")
include("ControlUtils.jl")
include("Controls.jl")
include("Render.jl")
include("CSVLauncher.jl")
# ==============================================================================
# In MakiePlotting.jl - Replace show_unified_fig and setup_render_lift!
# ==============================================================================

function create_plot_manager(sim_config::SimulationConfig{F}, master_ui::Dict, ui_overwrite::Dict, init_type::Symbol) where {F}
    varied_dict = sim_config.varied_params
    vars = isempty(varied_dict) ? [] : collect(keys(varied_dict))
    append!(vars, BaseVariables)

    base_types = Observable{Vector{Any}}([[:menu]; [:slider for _ in 2:5]])
    sim_obs = NestedObsDict()
    sim_obs["shared"] = Dict(k => Observable(v) for (k, v) in sim_config.shared_params)
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => Observable(v) for (k, v) in m_params)
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
        "General"    => Dict{String, Any}("simulation_func" => string(sim_config.simulation_func))
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
function show_unified_fig(
    sim_config::SimulationConfig;
    ui_style::UIType = :default,
    ui_overwrite::Dict = Dict{String, Any}(),
    var_overwrite::Vector{Any} = Any[:menu, :slider, :slider, :slider, :slider],
    scene_options::Dict = Dict{String, Any}(),
    parallel = false,
)
    ui_obs = create_master_ui_observables(ui_style)
    
    # --- 1. Flatten and Merge Scene Options ---
    final_scene = get_base_scene_options()
    
    # Map nested CSV Menu overrides to flat Selection keys
    if haskey(scene_options, "Menu")
        for (k, v) in scene_options["Menu"]
            final_scene["$(k)_Selection"] = v
        end
    end
    
    # Map nested CSV Slider overrides to flat Value keys
    if haskey(scene_options, "Slider")
        for (k, v) in scene_options["Slider"]
            final_scene["$(k)_Value"] = v
        end
    end
    
    # Merge any direct programmatic flat keys
    for (k, v) in scene_options
        if k != "Menu" && k != "Slider"
            final_scene[k] = v
        end
    end
    
    raw_type = get(final_scene, "Plot-Type_Selection", "Lines")
    init_type = raw_type isa String ? Symbol(lowercase(replace(raw_type, " " => ""))) : raw_type

    # --- 2. Setup Manager & Figure ---
    GLMakie.activate!()
    
    # Pass the init_type down so the UI initializes with the correct properties
    manager = create_plot_manager(sim_config, ui_obs, ui_overwrite, init_type)
    
    plot_fig = Figure(size = manager.ui["Axis-General"]["figsize"][])
    plot_screen_ref = Ref(GLMakie.Screen(title = "Makie Plot"))
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())
    
    # --- 3. INITIALIZATION SEQUENCE ---
    manager.controls["base_types"][] = var_overwrite
    
    # Pass the FLATTENED scene down to the control builder!
    ctrl_fig = create_controls(plot_fig, manager, plot_data_obs, final_scene)    
    
    # --- 4. Setup Data Generator Lift ---
    sim_update = manager.controls["Simulation_Update"]
    methods_obs = manager.methods

    on(sim_update) do _
        if !GLMakie.isopen(plot_screen_ref[])
            plot_screen_ref[] = GLMakie.Screen(title = "Makie Plot")
            display(plot_screen_ref[], plot_fig)
        end
    end

    onany(sim_update, methods_obs) do _, active_methods
        Base.invokelatest(update_plot_data_collection!,
            plot_data_obs[], sim_config, manager, active_methods, to_value(manager.controls["base_types"]);
            force_reload = (sim_update[] > 0), parallel = parallel, 
        )
        notify(plot_data_obs)
    end

    # --- 5. RENDER PIPELINE & DIMENSION SWITCHING ---
    render_observers = ObserverFunction[]

    # Note: Ensure this matches the key exposed in `build_static_plot_controls!`
    on(manager.controls["Plot-Type_Selection"]) do ptype_sym
        for obs in render_observers; off(obs); end
        empty!(render_observers)
        empty!(plot_fig)

        switch_ui_plot_type!(manager, ptype_sym)

        new_obs = setup_render_lift!(plot_fig, plot_data_obs, manager, Val(ptype_sym))
        
        if !isnothing(new_obs)
            append!(render_observers, new_obs)
        end
        
        if GLMakie.isopen(plot_screen_ref[])
            GLMakie.destroy!(plot_screen_ref[])
        end
        plot_screen_ref[] = GLMakie.Screen(title = "Makie Plot")
        display(plot_screen_ref[], plot_fig)
        
        notify(plot_data_obs)
    end

    # --- 6. TRIGGER FIRST FRAME ---
    notify(manager.controls["Plot-Type_Selection"])
    
    sim_update[] = 1 
    
    display(plot_screen_ref[], plot_fig)
    return plot_fig, ctrl_fig, manager
end

function setup_render_lift!(plot_fig::Figure, plot_data_obs::Observable, manager::PlotManager, ::Val{T}) where T
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || T == :surface
    ax = is_3d_axis ? Axis3(plot_fig[1, 1], perspectiveness=0.5) : Axis(plot_fig[1, 1])
    c = manager.controls; selector_obs = [haskey(c, "$(n)_Value") ? c["$(n)_Value"] : c["$(n)_Selection"] for n in manager.plot_vars]
    x_sel = c["X-Axis_Selection"]
    y_sel = c["Y-Axis_Selection"]
    z_sel = c["Z-Axis_Selection"]
    u_sel = c["U-Axis_Selection"]
    render_obs = onany(plot_data_obs, x_sel, y_sel, z_sel, u_sel, c["UI_Update"], selector_obs...) do data, x_key, y_key, z_key, u_key, _ui, sel_vals...
        (isnothing(x_key) || isnothing(u_key) || x_key == "-" || u_key == "-") && return
        isempty(data) && return
        
        # 1. Dispatch Data Extraction (PLOT_DIM_MAP[:lines] == 1)
        data_tuples, valid_labels, title_str = extract_data(data, manager, sel_vals, x_key, y_key, z_key, u_key, Val(PLOT_DIM_MAP[T]))
        
        # 2. Dispatch Plotting
        update_base_plot!(plot_fig, ax, valid_labels, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, Val(T))
    end
    return render_obs
end