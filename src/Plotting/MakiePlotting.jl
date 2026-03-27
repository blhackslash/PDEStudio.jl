include("UIStyles.jl")
include("PlottingUtils.jl")
include("ControlUtils.jl")
include("Controls.jl")
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
    controls_obs = Dict{String, Observable}("base_types" => base_types)

    return PlotManager(sim_obs, ui_obs, controls_obs, methods_obs, vars, copy(sim_config.shared_params))
end

function show_unified_fig(
    sim_config::SimulationConfig;
    ui_options::UIType = :default,
    scene_options::Dict = Dict{String, Any}(),
)
    # 1. Setup Manager & Figure
    manager = create_plot_manager(sim_config, createUIDict(ui_options))
    plot_fig = Figure(size = manager.ui["Axis"]["figsize"][])
    ax = Axis(plot_fig[1, 1])
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())

    # 2. Build UI (This populates manager.controls)
    # We only return the Figure and the specific observables needed for the data-load trigger
    ctrl_fig = create_controls(plot_fig, manager, plot_data_obs)
    
    # 3. Pull needed observables from the manager for data loading
    sim_update = manager.controls["Simulation_Update"]
    methods_obs = manager.methods

    final_scene = merge(get_base_scene_options(), scene_options)

    if haskey(final_scene, "base_types")
        bt_val = final_scene["base_types"]
        
        if bt_val isa String
            try
                # If loaded from CSV, it's a string like "Any[:menu, 0.5, :slider]"
                # We use Meta.parse to convert it back to a Julia Vector
                manager.controls["base_types"][] = eval(Meta.parse(bt_val))
            catch
                @warn "Could not parse base_types string: $bt_val"
            end
        else
            manager.controls["base_types"][] = bt_val
        end
    end

    lift(sim_update, methods_obs) do _, active_methods
        fixed_params = ParamDict(k => v[] for (k, v) in manager.simulation["shared"])
        # Reload/Simulate data
        Base.invokelatest(update_plot_data_collection!,
            plot_data_obs[], sim_config, active_methods, fixed_params, to_value(manager.controls["base_types"]);
            force_reload = (sim_update[] > 0), 
        )
        notify(plot_data_obs)
    end


    # a) Trigger initial data load. This synchronously populates the UI menus.
    sim_update[] = 1 
    
    # b) Apply Scene defaults safely AFTER data is populated and limits are known.
    set_defaults!(manager, final_scene)
    # 4. Clean Render Setup
    setup_render_lift!(ax, plot_fig, plot_data_obs, manager)
    
    sim_update[] = 0 
    return plot_fig, ctrl_fig, manager
end


# ==============================================================================
# In MakiePlotting.jl - Replace setup_render_lift! and find_closest_index_for_dim
# ==============================================================================

# ==============================================================================
# In MakiePlotting.jl - Replace setup_render_lift!
# ==============================================================================

function setup_render_lift!(ax, plot_fig, plot_data_obs, manager::PlotManager)
    c = manager.controls
    dim_names = manager.plot_vars # This is natively strictly ordered!
    
    # 1. Gather the ordered selector observables based on plot_vars
    selector_obs = Observable[]
    for name in dim_names
        # Safely fetch either the Slider Value or the Menu Selection
        if haskey(c, "$(name)_Value")
            push!(selector_obs, c["$(name)_Value"])
        elseif haskey(c, "$(name)_Selection")
            push!(selector_obs, c["$(name)_Selection"])
        else
            @warn "No selector widget found for dimension: $name"
        end
    end

    # Pass the ordered selector_obs into the lift
    lift(plot_data_obs, c["X-Axis_Selection"], c["Y-Axis_Selection"], 
         c["Plot-Along_Index"], c["UI_Update"], selector_obs...) do data, x_key, y_key, dim_idx, _ui, sel_vals...
        
        # 1. Validation
        if isnothing(x_key) || isnothing(y_key) || isnothing(dim_idx)
            return
        end
        (isnothing(x_key) || isnothing(y_key) || x_key == "-" || dim_idx == 0) && return
        isempty(data) && return
        
# 2. Data Slicing
        active_methods = manager.methods[]
        xs_to_plot, us_to_plot, valid_labels = Vector{Float64}[], Vector{Float64}[], String[]

        for m_name in active_methods
            !haskey(data, m_name) && continue
            pd = data[m_name]
            
            x_tensor = pd.data[x_key]
            y_tensor = pd.data[y_key]
            
            # Map values back to tensor indices (clamp to actual size to safely ignore size-1 axes!)
            x_indices = map(1:ndims(x_tensor)) do i
                if i == dim_idx; return (:); end
                val = sel_vals[i] isa String ? parse(Int, sel_vals[i]) : sel_vals[i]
                return min(find_closest_index_for_dim(pd, i, val), size(x_tensor, i))
            end
            
            y_indices = map(1:ndims(y_tensor)) do i
                if i == dim_idx; return (:); end
                val = sel_vals[i] isa String ? parse(Int, sel_vals[i]) : sel_vals[i]
                return min(find_closest_index_for_dim(pd, i, val), size(y_tensor, i))
            end
            
            try
                push!(xs_to_plot, vec(x_tensor[x_indices...]))
                push!(us_to_plot, vec(y_tensor[y_indices...]))
                push!(valid_labels, m_name)
            catch e
                @warn "Slicing failed for method $m_name" exception=e
            end
        end

        # 3. Plotting
        # Make sure your generate_dynamic_title function is also updated to accept the new ordered sel_vals
        title_str = generate_dynamic_title(dim_idx, dim_names, sel_vals)
        update_base_plot_1D!(plot_fig, ax, valid_labels, xs_to_plot, us_to_plot, manager;
                             xlabel=x_key, ylabel=y_key, title_str=title_str)
    end
end

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