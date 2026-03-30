# Fallback error if a dimension isn't supported yet
function setup_render_lift!(plot_fig::Figure, plot_data_obs::Observable, manager::PlotManager, dim::Val)
    @warn "Render setup for dimension $(typeof(dim)) is not implemented yet!"
    return ObserverFunction[]
end



include("UIStyles.jl")
include("PlottingUtils.jl")
include("ControlUtils.jl")
include("Controls.jl")
include("Heatmap.jl")
include("Scatter2D.jl")
include("Lines.jl")
# ==============================================================================
# In MakiePlotting.jl - Replace show_unified_fig and setup_render_lift!
# ==============================================================================

function create_plot_manager(sim_config::SimulationConfig{F}, ui_raw::Dict) where {F}
    vars = collect(keys(sim_config.varied_params))
    append!(vars,BaseVariables)

    base_types = Observable{Vector{Any}}([[:menu]; [:slider for _ in 2:5]])
    sim_obs = NestedObsDict()
    sim_obs["shared"] = Dict(k => Observable(v) for (k, v) in sim_config.shared_params)
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => Observable(v) for (k, v) in m_params)
    end

    ui_obs = NestedObsDict()
    for (scope, keys_dict) in ui_raw
        ui_obs[scope] = Dict(k => Observable(v) for (k, v) in keys_dict)
    end

    methods_obs = Observable(copy(sim_config.default_methods))

    # Initialize empty; populated by create_plot_controls!
    controls_obs = Dict{String, Observable}("base_types" => base_types, "Master_UI_Ref" => ui_obs)

    return PlotManager(sim_obs, ui_obs, controls_obs, methods_obs, vars, copy(sim_config.shared_params))
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

    # b) Trigger the initial Plot Dimension (This fires the render pipeline builder!)
    init_dim = get(final_scene, "Plot_Dimension", 1)
    manager.controls["Plot_Dimension"][] = init_dim

    # c) Trigger initial data load
    sim_update[] = 1 
    
    # d) Apply visual defaults
    set_defaults!(manager, final_scene)

    return plot_fig, ctrl_fig, manager
end


# ==============================================================================
# In MakiePlotting.jl - Replace setup_render_lift! and find_closest_index_for_dim
# ==============================================================================
# ==============================================================================
# RENDER DISPATCH SYSTEM
# ==============================================================================


"""
    find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real)

Maps a physical value from a slider back to the correct tensor index.
"""
function find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real)
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