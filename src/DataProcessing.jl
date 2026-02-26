module DataProcessing

using ..Structs
using ..Utils 
using ProgressMeter
using LinearAlgebra

export create_unified_plot_data, update_plot_data_collection!, analyze_configuration


"""
    update_plot_data_collection!(...)

Orchestrates the creation and cleanup of plot data tensors for all active methods.
Passes `var_types` down to handle dimension overwrites/skipping.
"""
function update_plot_data_collection!(
    plot_data_dict::Dict{String, UnifiedPlotData},
    sim_config::SimulationConfig{D, F},
    active_methods::Vector{String},
    fixed_params::FixedDictType,
    var_types::AbstractVector; # The key input for variable handling
    force_reload::Bool = false
) where {D, F}
    # 1. Clear everything if a full refresh is requested (e.g., clicked REFRESH)
    if force_reload
        empty!(plot_data_dict)
    end

    # 2. Update or Create data for each active method
    for method_name in active_methods
        if !haskey(plot_data_dict, method_name)
            # Assemble the base parameters (Shared + Method-Specific)
            base_params = Utils.assembleParams(sim_config.shared_params, sim_config.methods_dict, method_name)
            
            # Pass everything down to the creation chain
            # create_method_plot_data now handles the D-dimensional logic
            new_data = create_method_plot_data(base_params, sim_config, fixed_params, var_types)
            
            if !isnothing(new_data)
                plot_data_dict[method_name] = new_data
            end
        end
    end

    # 3. Cleanup: Remove methods that are no longer selected in the UI
    for k in keys(plot_data_dict)
        if !(k in active_methods)
            delete!(plot_data_dict, k)
        end
    end
    
    return plot_data_dict
end

"""
    create_method_plot_data(...)

Creates the multi-dimensional tensor for a single method.
Automatically detects spatial dimensionality D from the SimulationConfig.
"""
function create_method_plot_data(
    base_params::ParamDictType,
    sim_config::SimulationConfig{D, F},
    fixed_params::FixedDictType,
    var_types::AbstractVector
) where {D, F}
    # 1. Analyze the configuration to find which dimensions are active vs. fixed
    # Any variable in var_types that is a Number is added to base_fixes here.
    active_keys, active_values, sim_fixes, base_fixes = analyze_configuration(sim_config, fixed_params, var_types)
    
    # 2. Peek at the simulation structure
    # We generate tasks to find the first valid data point to determine tensor sizes.
    tasks, _ = generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    if isempty(tasks); return nothing; end
    
    first_data = ensure_sim_data_exists!([tasks[1]], sim_config)[1]
    
    # Determine effective sizes for [C, Space..., T]
    # Fixed/skipped dimensions return size 1.
    eff_c, eff_space, eff_t = resolve_dimensions(first_data, base_fixes)
    grid_dims = Tuple(length(v) for v in active_values)
    
    # Shape: [ParameterGrid..., Component, Space(D dims)..., Time]
    tensor_shape = (grid_dims..., eff_c, eff_space..., eff_t)
    
    # 3. Allocate Buckets
    data_store = Dict{String, Array{Float64}}()
    # Using fill(NaN) makes it easy to spot missing simulation points in the plot
    data_store["u"] = fill(NaN, tensor_shape...)
    data_store["x"] = fill(NaN, tensor_shape...)

    # 4. Fill the tensor recursively
    # This calls the generalized slice_eulerian! or slice_lagrangian!
    slice_and_fill!(data_store, sim_config.sim_function, sim_config, base_params, 
                    active_keys, active_values, sim_fixes, base_fixes)

    return UnifiedPlotData{length(tensor_shape)}(
        data_store,
        active_keys,
        active_values,
        first_data.t,
        fixed_params
    )
end

# ==============================================================================
# 1. CONFIGURATION ANALYSIS (Handling Overwrites)
# ==============================================================================

"""
    analyze_configuration(sim_config, fixed_params, var_types)

Determines the tensor structure. Dimensions with numeric 'var_types' are 
pushed to 'base_fixes' to be collapsed during slicing.
"""
function analyze_configuration(
    sim_config::SimulationConfig{D, F}, 
    fixed_params::FixedDictType,
    var_types::AbstractVector
) where {D, F}
    all_varied = sim_config.varied_params
    active_keys = String[]
    active_values = Vector{Vector{Any}}()
    
    sorted_varied_keys = sort(collect(keys(all_varied)))
    n_varied = length(sorted_varied_keys)

    sim_fixes = FixedDictType()
    base_fixes = Dict{String, Any}() 

    # 1. Process Parameter Overwrites (1..N_varied)
    for (i, key) in enumerate(sorted_varied_keys)
        vt = var_types[i]
        if vt isa Number 
            sim_fixes[key] = vt
        else
            push!(active_keys, key)
            push!(active_values, all_varied[key])
        end
    end

    # 2. Process Base Variable Overwrites (C, Space..., T)
    # Component (C) at index N+1
    vt_c = var_types[n_varied + 1]
    if vt_c isa Number; base_fixes["c"] = vt_c; end

    # Spatial Dimensions (X, Y, Z) at indices N+2..N+D+1
    for d in 1:D
        vt_s = var_types[n_varied + 1 + d]
        if vt_s isa Number; base_fixes[BaseVariables[1+d]] = vt_s; end
    end

    # Time (T) at the final index
    vt_t = var_types[end]
    if vt_t isa Number; base_fixes["t"] = vt_t; end

    # 3. Merge explicit Fixed Params from Navigator
    for (k, v) in fixed_params
        if k in BaseVariables; base_fixes[k] = v; else; sim_fixes[k] = v; end
    end

    return active_keys, active_values, sim_fixes, base_fixes
end

# ==============================================================================
# 2. DIMENSION RESOLUTION & ALLOCATION
# ==============================================================================

"""
    resolve_dimensions(sim_data, base_fixes)

Calculates the effective tensor sizes. Fixed dimensions return size 1.
"""
function resolve_dimensions(sim_data::AbstractSimData{D}, base_fixes::Dict{String, Any}) where D
    if sim_data isa ESimData{D}
        raw_c, raw_space, raw_t = size(sim_data.u, 1), size(sim_data.x), length(sim_data.t)
    else # Lagrangian
        raw_t, raw_c = length(sim_data.t), size(sim_data.u[1], 1)
        max_p = maximum(size(step, 2) for step in sim_data.u)
        raw_space = ntuple(_ -> max_p, D) 
    end

    eff_c = haskey(base_fixes, "c") ? 1 : raw_c
    eff_space = Int[]
    for d in 1:D
        s_key = BaseVariables[1+d]
        push!(eff_space, haskey(base_fixes, s_key) ? 1 : raw_space[d])
    end
    eff_t = haskey(base_fixes, "t") ? 1 : raw_t

    return eff_c, Tuple(eff_space), eff_t
end

# ==============================================================================
# 3. RECURSIVE SLICING ENGINE
# ==============================================================================

function create_method_plot_data(base_params, sim_config, fixed_params, var_types)
    # 1. Analyze what needs to be active vs fixed 
    active_keys, active_values, sim_fixes, base_fixes = analyze_configuration(sim_config, fixed_params, var_types)
    
    # 2. Peek at first data to allocate tensors
    tasks, _ = generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    first_data = ensure_sim_data_exists!([tasks[1]], sim_config)[1]
    
    eff_c, eff_space, eff_t = resolve_dimensions(first_data, base_fixes)
    grid_dims = Tuple(length(v) for v in active_values)
    
    # Shape: [ActiveParams..., C, Space..., T]
    tensor_shape = (grid_dims..., eff_c, eff_space..., eff_t)
    
    data_store = Dict{String, Array{Float64}}()
    for key in ["u", "x"] # Extend to other buckets as needed
        data_store[key] = fill(NaN, tensor_shape...)
    end

    # 3. Recursively fill tensors
    slice_and_fill!(data_store, sim_config.sim_function, sim_config, base_params, 
                    active_keys, active_values, sim_fixes, base_fixes)

    return UnifiedPlotData{length(tensor_shape)}(data_store, active_keys, active_values, first_data.t, fixed_params)
end

function slice_and_fill!(tensor_dict, sim_func, sim_config, current_params, 
                        rem_keys, rem_vals, sim_fixes, base_fixes)
    if isempty(rem_keys)
        # Leaf Node: Merge fixes and run/load simulation 
        final_params = merge(current_params, sim_fixes)
        sim_data = ensure_sim_data_exists!([final_params], sim_config)[1]
        
        if sim_data isa ESimData
            for (key, dest) in tensor_dict
                slice_eulerian!(dest, sim_data, key, current_params, sim_config, base_fixes)
            end
        else
            for (key, dest) in tensor_dict
                slice_lagrangian!(dest, sim_data, key, current_params, sim_config, base_fixes)
            end
        end
    else
        # Navigate Grid
        key, vals = rem_keys[1], rem_vals[1]
        for val in vals
            current_params[key] = val
            slice_and_fill!(tensor_dict, sim_func, sim_config, current_params, 
                           rem_keys[2:end], rem_vals[2:end], sim_fixes, base_fixes)
        end
    end
end

# ==============================================================================
# 4. DATA TYPE SPECIFIC SLICERS (D-DIMENSIONAL)
# ==============================================================================

function slice_eulerian!(dest, sim_data::ESimData{D}, key, current_params, sim_config, base_fixes) where D
    raw = key == "u" ? sim_data.u : sim_data.x
    p_inds = get_param_indices(current_params, sim_config) # Tuple
    
    # Map physical values to indices if fixed
    c_idx = haskey(base_fixes, "c") ? find_closest_idx(1:size(raw, 1), base_fixes["c"]) : (:)
    s_inds = ntuple(d -> haskey(base_fixes, BaseVariables[1+d]) ? 
                   find_closest_spatial_idx(sim_data, d, base_fixes[BaseVariables[1+d]]) : (:), D)
    t_idx = haskey(base_fixes, "t") ? find_closest_idx(sim_data.t, base_fixes["t"]) : (:)

    # Dynamic Slice Assignment
    dest[p_inds..., (1:length(c_idx))..., (1:length.(s_inds))..., (1:length(t_idx))...] .= raw[c_idx, s_inds..., t_idx]
end

function slice_lagrangian!(dest, sim_data::LSimData{D}, key, current_params, sim_config, base_fixes) where D
    raw_steps = key == "u" ? sim_data.u : sim_data.x # Vector of steps
    p_inds = get_param_indices(current_params, sim_config)
    
    t_range = haskey(base_fixes, "t") ? [find_closest_idx(sim_data.t, base_fixes["t"])] : 1:length(sim_data.t)

    for (t_out, t_raw) in enumerate(t_range)
        step = raw_steps[t_raw]
        c_idx = haskey(base_fixes, "c") ? [find_closest_idx(1:size(step, 1), base_fixes["c"])] : 1:size(step, 1)
        # Collapse particles to index 1 if spatial fixed 
        p_idx = haskey(base_fixes, "x") ? [find_closest_particle(sim_data, t_raw, base_fixes["x"])] : 1:size(step, 2)
        
        dest[p_inds..., 1:length(c_idx), 1:length(p_idx), t_out] .= step[c_idx, p_idx]
    end
end

# ==============================================================================
# 5. HELPERS
# ==============================================================================

function get_param_indices(curr, config)
    sorted_keys = sort(collect(keys(config.varied_params)))
    return Tuple(findfirst(==(curr[k]), config.varied_params[k]) for k in sorted_keys if haskey(curr, k))
end

find_closest_idx(coll, val) = findmin(x -> abs(x - val), coll)[2]

function find_closest_spatial_idx(sim_data::ESimData{D}, dim, val) where D
    # Extract 1D spatial coord vector along target dimension
    coords = selectdim(sim_data.x, dim, ntuple(_ -> 1, D-1)...)
    return find_closest_idx(coords, val)
end

function find_closest_particle(sim_data::LSimData{D}, t_idx, target_x) where D
    # Pick particle closest to physical 'target_x' (usually just looking at X1)
    pos_vectors = sim_data.x[t_idx]
    return findmin(p -> abs(p[1] - target_x), pos_vectors)[2]
end

end