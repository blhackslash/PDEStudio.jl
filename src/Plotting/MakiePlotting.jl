# Fallback error if a dimension isn't supported yet
function setup_render_lift!(plot_fig::Figure, plot_data_obs::Observable, manager::PlotManager, dim::Val)
    @warn "Render setup for dimension $(typeof(dim)) is not implemented yet!"
    return ObserverFunction[]
end


include("DataExtraction.jl")
include("UIStyles.jl")
include("PlottingUtils.jl")
include("ControlUtils.jl")
include("Controls.jl")
include("Render.jl")
# ==============================================================================
# In MakiePlotting.jl - Replace show_unified_fig and setup_render_lift!
# ==============================================================================

function create_plot_manager(sim_config::SimulationConfig{F}, master_ui::Dict) where {F}
    vars = collect(keys(sim_config.varied_params))
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

    manager = PlotManager(sim_obs, ui_obs, controls_obs, methods_obs, vars, copy(sim_config.shared_params))
    
    # 3. Populate the active UI immediately so `manager.ui["Axis-General"]` exists for Figure creation!
    switch_ui_plot_type!(manager, :lines)
    
    return manager
end

function show_unified_fig(
    sim_config::SimulationConfig;
    ui_options::UIType = :default,
    scene_options::Dict = Dict{String, Any}()
)
    # 1. Setup Manager & Figure
    manager = create_plot_manager(sim_config, create_master_ui_observables(ui_options))
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
            force_reload = (sim_update[] > 0), 
        )
        notify(plot_data_obs)
    end

    # --- 4. RENDER PIPELINE & DIMENSION SWITCHING ---
    # We store the active rendering listeners here so we can delete them later
    render_observers = ObserverFunction[]

    on(manager.controls["Plot_Type"]) do ptype_sym
        # A. Clean up old rendering listeners
        for obs in render_observers
            off(obs) 
        end
        empty!(render_observers)
        empty!(plot_fig)

        # B. RESTRUCTURE THE UI DICTIONARY
        switch_ui_plot_type!(manager, ptype_sym)

        # C. Dispatch directly to the specific plot type!
        # E.g., Val(:heatmap), Val(:scatter3d), Val(:lines)
        new_obs = setup_render_lift!(plot_fig, plot_data_obs, manager, Val(ptype_sym))
        
        if !isnothing(new_obs)
            append!(render_observers, new_obs)
        end
        
        notify(plot_data_obs)
    end

# --- 5. INITIALIZATION SEQUENCE ---
    final_scene = merge(get_base_scene_options(), scene_options)

    # a) PRE-LOAD OVERWRITES
    if haskey(final_scene, "base_types")
        bt_val = final_scene["base_types"]
        if bt_val isa String
            try
                manager.controls["base_types"][] = eval(Meta.parse(bt_val))
            catch
                @warn "Could not parse base_types string: $bt_val"
            end
        else
            manager.controls["base_types"][] = bt_val
        end
    end

    # b) Trigger the initial Plot Type (This fires the render pipeline builder!)
    init_type = get(final_scene, "Plot_Type", :lines)
    manager.controls["Plot_Type"][] = init_type

    # c) Trigger initial data load
    sim_update[] = 1 
    
    # d) Apply visual defaults
    set_defaults!(manager, final_scene)

    return plot_fig, ctrl_fig, manager
end


"""
    find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real)

Maps a physical value from a slider back to the correct tensor index.
"""
function find_closest_index_for_dim(pd::UnifiedPlotData{N}, dim_idx::Int, target_val::Real) where N
    n_params = length(pd.active_param_keys)
    
    if dim_idx <= n_params # Parameter
        p_vals = pd.active_param_values[dim_idx]
        return findmin(v -> abs(v - target_val), p_vals)[2]
        
    elseif dim_idx == n_params + 1 # Component
        return max(1, Int(target_val))
        
    elseif dim_idx > n_params + 1 && dim_idx <= n_params + 4 # Space (X, Y, Z...)
        if haskey(pd.data, "x")
            x_tensor = pd.data["x"]
            # Grab a 1D spatial vector by targeting index 1 for all non-spatial dimensions
            inds = ntuple(i -> i == dim_idx ? (:) : 1, ndims(x_tensor))
            x_vec = vec(x_tensor[inds...])
            
            # Filter out NaNs (Lagrangian padding) safely
            valid_idx = findall(!isnan, x_vec)
            if isempty(valid_idx)
                return 1
            end
            
            closest_valid = findmin(v -> abs(v - target_val), x_vec[valid_idx])[2]
            return valid_idx[closest_valid]
        end
        return 1 
        
    elseif dim_idx == n_params + 5 # Time
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