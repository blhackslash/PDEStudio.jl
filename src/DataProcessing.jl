module DataProcessing

using ..Structs
using ..Utils 
using ProgressMeter

export create_method_plot_data, update_plot_data_collection!, generate_method_tasks, analyze_configuration

# ==============================================================================
# 1. TASK & CONFIGURATION ANALYSIS
# ==============================================================================

"""
    analyze_configuration(sim_config, fixed_params)

Separates parameters to find the `active_keys` (varied in the grid) and `sim_fixes` 
(parameters fixed for the simulation). Base variable fixes are now handled separately 
via the UI's `base_types`.
"""
function analyze_configuration(sim_config::SimulationConfig, fixed_params::FixedDictType)
    all_varied = sim_config.varied_params
    active_keys = String[]
    active_values = Vector{Vector{Any}}()
    
    # Sort for consistent tensor dimension ordering
    sorted_keys = sort(collect(keys(all_varied)))

    sim_fixes = FixedDictType()

    # Apply Simulation Parameter Fixes
    for (k, v) in fixed_params
        if !(k in Structs.BaseVariables)
            sim_fixes[k] = v
        end
    end

    # Build Active Grid
    for key in sorted_keys
        if haskey(sim_fixes, key)
            continue 
        else
            push!(active_keys, key)
            push!(active_values, all_varied[key])
        end
    end

    return active_keys, active_values, sim_fixes
end

function generate_method_tasks(
    base_params::ParamDictType,
    active_keys::Vector{String},
    active_values::Vector{Vector{Any}},
    sim_fixes::FixedDictType
)
    param_grid = collect(Iterators.product(active_values...))
    tasks = Vector{ParamDictType}()
    grid_indices = Vector{Tuple}()

    for (linear_idx, p_vals) in enumerate(param_grid)
        task_params = copy(base_params)
        
        for (k, v) in sim_fixes; task_params[k] = v; end
        
        indices = Tuple(CartesianIndices(param_grid)[linear_idx])
        for (i, val) in enumerate(p_vals)
            task_params[active_keys[i]] = val
        end
        
        push!(tasks, task_params)
        push!(grid_indices, indices)
    end

    return tasks, grid_indices
end

# ==============================================================================
# 2. DATA SLICING & DIMENSION HELPERS
# ==============================================================================

"""
    resolve_dimensions(sim_data, D, base_types)

Determines the effective sizes after applying `base_types` fixes.
Reduces the effective dimension to 1 if a number is provided in `base_types`.
"""
function resolve_dimensions(sim_data::AbstractSimData{D}, base_types::Vector) where D
    if sim_data isa ESimData{D}
        raw_c = size(sim_data.u, 1)
        raw_space = size(sim_data.u)[2:D+1]
        raw_t = size(sim_data.u, D+2)
        max_particles = 0 
    elseif sim_data isa LSimData{D}
        raw_t = length(sim_data.t)
        raw_c = size(sim_data.u[1][1], 1)
        max_particles = maximum(length(step) for step in sim_data.u)
        raw_space = (max_particles,) # Lagrangian maps space to a 1D particle index array
    end

    # Extract effective sizes using base_types: [C, Space(1..D)..., T]
    eff_c = base_types[1] isa Number ? 1 : raw_c
    
    # Lagrangian Space is 1D (Particles), Eulerian is D-dimensional
    eff_space = if sim_data isa ESimData{D}
        ntuple(i -> base_types[1+i] isa Number ? 1 : raw_space[i], D)
    else
        (base_types[2] isa Number ? 1 : max_particles,)
    end
    
    eff_t = base_types[D+2] isa Number ? 1 : raw_t

    return eff_c, eff_space, eff_t, max_particles, raw_c, raw_space, raw_t
end

"""
    get_source_slices(base_types, D, raw_c, raw_space, raw_t, is_lagrangian=false)

Generates the dynamic slicing indices based on `base_types`.
"""
function get_source_slices(base_types::Vector, D::Int, raw_c::Int, raw_space::Tuple, raw_t::Int, is_lagrangian::Bool)
    c_idx = base_types[1] isa Number ? (base_types[1]:base_types[1]) : (1:raw_c)
    
    space_idx = if is_lagrangian
        base_types[2] isa Number ? (base_types[2]:base_types[2]) : (1:raw_space[1])
    else
        ntuple(i -> base_types[1+i] isa Number ? (base_types[1+i]:base_types[1+i]) : (1:raw_space[i]), D)
    end
    
    t_idx = base_types[D+2] isa Number ? (base_types[D+2]:base_types[D+2]) : (1:raw_t)
    
    return c_idx, space_idx, t_idx
end

function slice_and_fill_eulerian!(target, source::AbstractArray, dest_prefix, base_types, D, raw_c, raw_space, raw_t)
    c_src, space_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, false)
    
    # Determine Source Type based on dimensions
    nd = ndims(source)
    if nd == 1 # Scalar [C]
        target[dest_prefix..., :, (1 for _ in 1:D)..., 1] = source[c_src]
    elseif nd == 2 # TimeSeries [C, T]
        target[dest_prefix..., :, (1 for _ in 1:D)..., :] = source[c_src, t_src]
    elseif nd == D + 1 # Profile [C, Space...]
        target[dest_prefix..., :, (Colon() for _ in 1:D)..., 1] = source[c_src, space_src...]
    elseif nd == D + 2 # Field [C, Space..., T]
        target[dest_prefix..., :, (Colon() for _ in 1:D)..., :] = source[c_src, space_src..., t_src]
    elseif nd == D && source == raw_space # Grid [Space...]
        target[dest_prefix..., 1, (Colon() for _ in 1:D)..., 1] = source[space_src...]
    end
end

function slice_and_fill_lagrangian!(target, x_data, u_data, dest_prefix, base_types, D, raw_c, raw_space, raw_t)
    c_src, p_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, true)
    max_p = raw_space[1]
    
    for (tgt_t, src_t) in enumerate(t_src)
        u_step = u_data[src_t] # Vector of Matrices [Particles] -> [C, State]
        x_step = x_data[src_t] # Vector of SVectors [Particles] -> [SVector{D}]
        curr_p_len = length(x_step)
        
        # Check Particle Index Bounds
        p_idx = base_types[2] isa Number ? base_types[2] : nothing
        
        if !isnothing(p_idx)
            if p_idx <= curr_p_len
                # Assuming state matrix is [C, 1] for scalar plots
                target["u"][dest_prefix..., :, 1, tgt_t] = u_step[p_idx][c_src, 1] 
                # FIX: Use ':' to assign the D-dimensional SVector along the coordinate axis
                target["x"][dest_prefix..., :, 1, tgt_t] = x_step[p_idx]
            else
                target["u"][dest_prefix..., :, 1, tgt_t] .= NaN
                target["x"][dest_prefix..., :, 1, tgt_t] .= NaN
            end
        else
            # Fill all available particles
            for p in 1:curr_p_len
                target["u"][dest_prefix..., :, p, tgt_t] = u_step[p][c_src, 1]
                # FIX: Use ':' here as well
                target["x"][dest_prefix..., :, p, tgt_t] = x_step[p]
            end
            
            # Pad dead/unborn particles with NaN
            if curr_p_len < max_p
                target["u"][dest_prefix..., :, (curr_p_len+1):end, tgt_t] .= NaN
                target["x"][dest_prefix..., :, (curr_p_len+1):end, tgt_t] .= NaN
            end
        end
    end
end

# ==============================================================================
# 3. UNIFIED TENSOR CREATION
# ==============================================================================

function create_method_plot_data(
    base_params::ParamDictType,
    sim_config::SimulationConfig{D, F},
    fixed_params::FixedDictType,
    base_types::Vector
) where {D, F}
    
    active_keys, active_values, sim_fixes = analyze_configuration(sim_config, fixed_params)
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    
    ensure_sim_data_exists!(tasks, sim_config)
    if isempty(tasks); return nothing; end

    first_data = Utils.loadSimData(tasks[1]) 
    eff_c, eff_space, eff_t, max_p, raw_c, raw_space, raw_t = resolve_dimensions(first_data, base_types)
    grid_dims = length.(active_values)
    
    data_store = Dict{String, Array{Float64}}()
    
    function allocate_tensor(category)
        if category == :field      # [P..., C, Space..., T]
            return fill(NaN, grid_dims..., eff_c, eff_space..., eff_t)
        elseif category == :scalar # [P..., C, 1..., 1]
            return fill(NaN, grid_dims..., eff_c, (1 for _ in 1:length(eff_space))..., 1)
        elseif category == :series # [P..., C, 1..., T]
            return fill(NaN, grid_dims..., eff_c, (1 for _ in 1:length(eff_space))..., eff_t)
        elseif category == :profile# [P..., C, Space..., 1]
            return fill(NaN, grid_dims..., eff_c, eff_space..., 1)
        elseif category == :grid   # Eulerian: [P..., 1, Space..., T/1], Lagrangian [P..., D, Space..., T]
            grid_c = first_data isa LSimData{D} ? D : 1
            grid_t = (first_data isa ESimData{D} && !(base_types[D+2] isa Number)) ? 1 : eff_t
            return fill(NaN, grid_dims..., grid_c, eff_space..., grid_t)
        end
    end

    data_store["u"] = allocate_tensor(:field)
    data_store["x"] = allocate_tensor(:grid)

    for k in keys(first_data.scalars); data_store[k] = allocate_tensor(:scalar); end
    for k in keys(first_data.series); data_store[k] = allocate_tensor(:series); end
    for k in keys(first_data.profiles); data_store[k] = allocate_tensor(:profile); end
    for k in keys(first_data.fields); data_store[k] = allocate_tensor(:field); end

    for (k, params) in enumerate(tasks)
        sim_data = Utils.loadSimData(params)
        dest_prefix = grid_indices[k]

        if sim_data isa ESimData{D}
            slice_and_fill_eulerian!(data_store["u"], sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t)
            slice_and_fill_eulerian!(data_store["x"], sim_data.x, dest_prefix, base_types, D, 1, raw_space, 1) 
            
            for (sk, sv) in sim_data.scalars; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t); end
            for (sk, sv) in sim_data.series; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t); end
            for (sk, sv) in sim_data.profiles; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t); end
            for (sk, sv) in sim_data.fields; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t); end

        elseif sim_data isa LSimData{D}
            slice_and_fill_lagrangian!(data_store, sim_data.x, sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t)
            # Add Lagrangian bucket fillers here similarly using `c_src`, `p_src`, `t_src`
        end
    end

    return UnifiedPlotData{ndims(data_store["u"])}(
        data_store, active_keys, active_values, first_data.t, fixed_params
    )
end

# ==============================================================================
# 4. ORCHESTRATOR
# ==============================================================================

function update_plot_data_collection!(
    plot_data_dict::Dict{String, UnifiedPlotData},
    sim_config::SimulationConfig,
    active_methods::Vector{String},
    fixed_params::FixedDictType,
    base_types::Vector;
    force_reload::Bool = false
)
    if force_reload; empty!(plot_data_dict); end

    for method_name in active_methods
        if !haskey(plot_data_dict, method_name)
            base_params = Utils.assembleParams(sim_config.shared_params, sim_config.methods_dict, method_name)
            new_data = create_method_plot_data(base_params, sim_config, fixed_params, base_types)
            if !isnothing(new_data)
                plot_data_dict[method_name] = new_data
            end
        end
    end

    for k in keys(plot_data_dict)
        if !(k in active_methods); delete!(plot_data_dict, k); end
    end
    return plot_data_dict
end

end