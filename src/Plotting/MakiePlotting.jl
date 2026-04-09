include("DataExtraction.jl")
include("UIStyles.jl")
include("PlottingUtils.jl")
include("ControlUtils.jl")
include("Controls.jl")
include("Render.jl")
include("CSVLauncher.jl")
# ==============================================================================
# In MakiePlotting.jl - Replace show_unified_fig and setup_render_lift!
# ==============================================================================

function create_plot_manager(sim_config::SimulationConfig{F}, master_ui::Dict) where {F}
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

    # Add config_dict to the constructor
    manager = PlotManager(sim_obs, ui_obs, config_dict, controls_obs, methods_obs, vars, copy(sim_config.shared_params))
    
    # 3. Populate the active UI immediately so `manager.ui["Axis-General"]` exists for Figure creation!
    switch_ui_plot_type!(manager, :lines)
    
    return manager
end
function show_unified_fig(
    sim_config::SimulationConfig;
    ui_style::UIType = :default,
    ui_overwrite::Dict = Dict{String, Any}(), # Uses your MethodDict equivalent
    var_overwrite::Vector{Any} = Any[:menu, :slider, :slider, :slider, :slider],
    scene_options::Dict = Dict{String, Any}(),
    parallel = false,
)
    ui_obs = create_master_ui_observables(ui_style)
    
    # --- APPLY UI OVERWRITES BEFORE MANAGER CREATION ---
    for (scope, keys_dict) in ui_overwrite
        if haskey(ui_obs, scope)
            for (k, v) in keys_dict
                if haskey(ui_obs[scope], k)
                    ui_obs[scope][k][] = v
                end
            end
        end
    end

    # 1. Setup Manager & Figure
    manager = create_plot_manager(sim_config, ui_obs)
    plot_fig = Figure(size = manager.ui["Axis-General"]["figsize"][])
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())

    # 2. Build UI 
    ctrl_fig = create_controls(plot_fig, manager, plot_data_obs)
    
    # 3. Setup Data Generator Lift
    sim_update = manager.controls["Simulation_Update"]
    methods_obs = manager.methods
    
    lift(sim_update, methods_obs) do _, active_methods
        fixed_params = ParamDict(k => v[] for (k, v) in manager.simulation["shared"])
        
        Base.invokelatest(update_plot_data_collection!,
            plot_data_obs[], sim_config, active_methods, fixed_params, to_value(manager.controls["base_types"]);
            force_reload = (sim_update[] > 0), parallel = parallel, 
        )
        notify(plot_data_obs)
    end

    # --- 4. RENDER PIPELINE & DIMENSION SWITCHING ---
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
        
        notify(plot_data_obs)
    end

    # --- 5. INITIALIZATION SEQUENCE ---
    final_scene = merge(get_base_scene_options(), scene_options)

    # a) Apply Variable Overwrites directly to the controls
    manager.controls["base_types"][] = var_overwrite

    # b) Trigger the initial Plot Type 
    # Try reading from Scene first, fallback to :lines
    init_type = :lines
    if haskey(final_scene, "Menu") && haskey(final_scene["Menu"], "Plot-Type_Selection")
        raw_type = final_scene["Menu"]["Plot-Type_Selection"]
        init_type = raw_type isa String ? Symbol(raw_type) : raw_type
    end
    manager.controls["Plot-Type_Selection"][] = init_type

    # c) Trigger initial data load
    sim_update[] = 1 
    
    # d) Apply visual defaults (like limits/menus from Scene options)
    set_defaults!(manager, final_scene)

    return plot_fig, ctrl_fig, manager
end

"""
    find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real)

Maps a physical value from a slider back to the correct tensor index.
"""
function find_closest_index_for_dim(pd::UnifiedPlotData{N}, dim_idx::Int, target_val::Real) where N
    n_params = length(pd.active_param_keys)
    
    if dim_idx <= n_params 
        p_vals = pd.active_param_values[dim_idx]
        return findmin(v -> abs(v - target_val), p_vals)[2]
        
    elseif dim_idx == n_params + 1 
        return max(1, Int(target_val))
        
    elseif dim_idx > n_params + 1 && dim_idx <= n_params + 4 
        # --- THE FIX: Route to correct orthogonal axis natively ---
        tensor_key = dim_idx == n_params + 2 ? "x" : (dim_idx == n_params + 3 ? "y" : "z")
        
        if haskey(pd.data, tensor_key)
            # Filter out the NaN padding to reveal the pure 1D coordinate axis
            coord_vec = filter(isfinite, vec(pd.data[tensor_key]))
            if isempty(coord_vec)
                return 1
            end
            return findmin(v -> abs(v - target_val), coord_vec)[2]
        end
        
    elseif dim_idx == n_params + 5 
        return findmin(v -> abs(v - target_val), pd.t_vals)[2]
    end
    
    return 1
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