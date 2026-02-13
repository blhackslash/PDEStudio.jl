module DataProcessing

using ..Structs
using ..Utils 
using ProgressMeter

export create_unified_plot_data, update_plot_data_collection!, generate_method_tasks, analyze_configuration

const BaseVariables = ["t", "x", "x1", "x2", "y", "c"]

# ==============================================================================
# 1. TASK & CONFIGURATION ANALYSIS
# ==============================================================================

"""
    analyze_configuration(sim_config, fixed_params)

Separates fixed parameters into:
1. `sim_fixes`: Regular parameters fixed for the simulation (reduces grid size).
2. `base_fixes`: Base variables (t, x, c) fixed for the view (slices the tensors).
3. `active_keys`: The parameters that are actually varied (the grid dimensions).
"""
function analyze_configuration(sim_config::SimulationConfig, fixed_params::FixedDictType)
    # 1. Identify Active Varied Params
    all_varied = sim_config.varied_params
    active_keys = String[]
    active_values = Vector{Vector{Any}}()
    
    # Sort for consistent tensor dimension ordering (Left-most indices)
    sorted_keys = sort(collect(keys(all_varied)))

    sim_fixes = FixedDictType()
    base_fixes = Dict{String, Int}() # Index to fix at

    # Separate Fixes
    for (k, v) in fixed_params
        if k in BaseVariables
            # It's a base variable (t, x, c), store the index
            # User said: "just use indices for now"
            base_fixes[k] = v isa Int ? v : parse(Int, string(v))
        else
            # It's a simulation parameter
            sim_fixes[k] = v
        end
    end

    # Build Active Grid
    for key in sorted_keys
        if haskey(sim_fixes, key)
            continue # It is fixed
        else
            push!(active_keys, key)
            push!(active_values, all_varied[key])
        end
    end

    return active_keys, active_values, sim_fixes, base_fixes
end

"""
    generate_method_tasks(...)
    
Creates the list of parameter dictionaries to simulate/load.
"""
function generate_method_tasks(
    base_params::ParamDictType,
    active_keys::Vector{String},
    active_values::Vector{Vector{Any}},
    sim_fixes::FixedDictType
)
    # Cartesian Product of Active Params
    param_grid = collect(Iterators.product(active_values...))
    
    tasks = Vector{ParamDictType}()
    grid_indices = Vector{Tuple}()

    for (linear_idx, p_vals) in enumerate(param_grid)
        task_params = copy(base_params)
        
        # Apply Simulation Fixes
        for (k, v) in sim_fixes; task_params[k] = v; end
        
        # Apply Active Variations
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
    resolve_dimensions(sim_data, base_fixes)

Determines the effective [C, X, T] sizes after applying base fixes.
Returns (n_c, n_x, n_t) and the max spatial size for allocation.
"""
function resolve_dimensions(sim_data::AbstractSimData, base_fixes::Dict{String, Int})
    # Raw dimensions
    if sim_data isa ESimData1D
        # u is [C, X, T]
        raw_c, raw_x, raw_t = size(sim_data.u)
        max_x = raw_x
    elseif sim_data isa LSimData1D
        # u is Vector{Matrix} (T -> [C, X])
        raw_t = length(sim_data.t)
        raw_c = size(sim_data.u[1], 1)
        # Find max X
        max_x = maximum(size(step, 2) for step in sim_data.u)
        raw_x = max_x # For allocation purposes
    end

    # Apply Fixes (If fixed, dimension becomes 1)
    eff_c = haskey(base_fixes, "c") ? 1 : raw_c
    eff_x = haskey(base_fixes, "x") ? 1 : raw_x
    eff_t = haskey(base_fixes, "t") ? 1 : raw_t

    return eff_c, eff_x, eff_t, max_x
end

"""
    slice_and_fill!(target_tensor, source_data, dest_indices, base_fixes, raw_dims)

Extracts data from `source_data` (which might be 3D array, Matrix, Vector, etc.),
slices it according to `base_fixes`, and writes it into `target_tensor` at `dest_indices`.
"""
function slice_and_fill!(target, source::AbstractArray, dest_prefix, base_fixes, raw_c, raw_x, raw_t)
    # Source Shape Analysis
    # We need to map Source dimensions to [C, X, T]
    # Cases:
    # 1. Scalar [C] -> Tensor [..., C, 1, 1]
    # 2. TimeSeries [C, T] -> Tensor [..., C, 1, T]
    # 3. Profile [C, X] -> Tensor [..., C, X, 1]
    # 4. Field [C, X, T] -> Tensor [..., C, X, T]
    # 5. Grid [X] -> Tensor [..., 1, X, 1]
    # 6. Grid [X, T] -> Tensor [..., 1, X, T]

    # Indices for the source array
    # We start with Colon (:) for everything
    src_c = 1:raw_c
    src_x = 1:raw_x
    src_t = 1:raw_t

    # Apply Fixes
    if haskey(base_fixes, "c"); src_c = base_fixes["c"]; end
    if haskey(base_fixes, "x"); src_x = base_fixes["x"]; end
    if haskey(base_fixes, "t"); src_t = base_fixes["t"]; end

    # Determine Source Type and slice accordingly
    if ndims(source) == 1 # Scalar [C] or Grid [X]
        if length(source) == raw_c # Scalar
            target[dest_prefix..., :, 1, 1] = source[src_c]
        else # Grid [X] (Eulerian X)
            target[dest_prefix..., 1, :, 1] = source[src_x]
        end
    elseif ndims(source) == 2 # TimeSeries [C, T] or Profile [C, X]
        if size(source, 2) == raw_t # TimeSeries [C, T]
            target[dest_prefix..., :, 1, :] = source[src_c, src_t]
        else # Profile [C, X]
            # Handle NaN padding for Lagrangian Profiles if needed
            data_slice = source[src_c, src_x]
            # If target has fixed X=1, data_slice is vector. If target X=Full, data_slice is matrix.
            # Just broadcast assign
            target[dest_prefix..., :, :, 1] = data_slice
        end
    elseif ndims(source) == 3 # Field [C, X, T]
        target[dest_prefix..., :, :, :] = source[src_c, src_x, src_t]
    end
end

# Specific Helper for Lagrangian Vector-of-Vectors/Matrices
function slice_and_fill_lagrangian!(target, x_data, u_data, dest_prefix, base_fixes, max_x)
    # u_data is Vector{Matrix} [T] -> [C, X]
    # x_data is Vector{Vector} [T] -> [X]
    
    t_range = haskey(base_fixes, "t") ? (base_fixes["t"]:base_fixes["t"]) : (1:length(u_data))
    c_range = haskey(base_fixes, "c") ? (base_fixes["c"]:base_fixes["c"]) : (1:size(u_data[1], 1))
    # For X, we can't simple slice a range because length varies. 
    # If X is fixed to index `ix`, we take ix-th element if it exists, else NaN.
    
    # Iterate Target Time Indices (tt) and Source Time Indices (st)
    for (tt, st) in enumerate(t_range)
        u_step = u_data[st] # [C, X_actual]
        x_step = x_data[st] # [X_actual]
        curr_x_len = length(x_step)
        
        # --- Handle X Dimension ---
        if haskey(base_fixes, "x")
            ix = base_fixes["x"]
            # Check bounds
            if ix <= curr_x_len
                # Target is [..., C, 1, 1(Time slice)]
                target["u"][dest_prefix..., :, 1, tt] = u_step[c_range, ix]
                target["x"][dest_prefix..., 1, 1, tt] = x_step[ix]
            else
                # Out of bounds (particle doesn't exist yet/anymore) -> NaN
                target["u"][dest_prefix..., :, 1, tt] .= NaN
                target["x"][dest_prefix..., 1, 1, tt] .= NaN
            end
        else
            # Full X Range
            # Copy available data
            # Target is [..., C, Max_X, 1(Time slice)]
            target["u"][dest_prefix..., :, 1:curr_x_len, tt] = u_step[c_range, :]
            target["x"][dest_prefix..., 1, 1:curr_x_len, tt] = reshape(x_step, 1, :) # Broadcast C=1
            
            # Pad remaining X with NaN
            if curr_x_len < max_x
                target["u"][dest_prefix..., :, (curr_x_len+1):end, tt] .= NaN
                target["x"][dest_prefix..., 1, (curr_x_len+1):end, tt] .= NaN
            end
        end
    end
end

# ==============================================================================
# 3. UNIFIED TENSOR CREATION
# ==============================================================================

function create_method_plot_data(
    base_params::ParamDictType,
    sim_config::SimulationConfig,
    fixed_params::FixedDictType
)
    # 1. Configuration Analysis
    active_keys, active_values, sim_fixes, base_fixes = analyze_configuration(sim_config, fixed_params)
    
    # 2. Generate Tasks
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    ensure_sim_data_exists!(tasks,sim_config)
    if isempty(tasks); return nothing; end

    # 3. Initialization (Probe dimensions)
    # We load the first task to discover available buckets (scalars, fields, etc.) and dimensions.
    first_data = Utils.loadSimData(tasks[1]) 
    
    # Resolve effective dimensions (after applying base fixes)
    eff_c, eff_x, eff_t, max_x = resolve_dimensions(first_data, base_fixes)
    
    # Grid dimensions (P1, P2...)
    grid_dims = length.(active_values)
    
    # Prepare Tensor Dictionary
    data_store = Dict{String, Array{Float64}}()
    
    # Helper to allocate tensor based on category
    function allocate_tensor(category)
        if category == :field # [P..., C, X, T]
            return fill(NaN, grid_dims..., eff_c, eff_x, eff_t)
        elseif category == :scalar # [P..., C, 1, 1]
            return fill(NaN, grid_dims..., eff_c, 1, 1)
        elseif category == :series # [P..., C, 1, T]
            return fill(NaN, grid_dims..., eff_c, 1, eff_t)
        elseif category == :profile # [P..., C, X, 1]
            return fill(NaN, grid_dims..., eff_c, eff_x, 1)
        elseif category == :grid # [P..., 1, X, T/1] (C=1)
            # Grid T-dim depends on Euler (1) vs Lagrange (T)
            # But if T is fixed in UI, eff_t becomes 1 anyway.
            # If Lagrange & T not fixed -> T. If Euler & T not fixed -> 1.
            grid_t = (first_data isa ESimData1D && !haskey(base_fixes, "t")) ? 1 : eff_t
            return fill(NaN, grid_dims..., 1, eff_x, grid_t)
        end
    end

    # Allocate Core Data
    data_store["u"] = allocate_tensor(:field)
    data_store["x"] = allocate_tensor(:grid)

    # Allocate Buckets (Scalars, TimeSeries, etc.)
    # We scan the first_data to find keys. Assumes all runs have same keys.
    for k in keys(first_data.scalars); data_store[k] = allocate_tensor(:scalar); end
    for k in keys(first_data.series); data_store[k] = allocate_tensor(:series); end
    for k in keys(first_data.profiles); data_store[k] = allocate_tensor(:profile); end
    for k in keys(first_data.fields); data_store[k] = allocate_tensor(:field); end

    # 4. Data Filling Loop
    # @showprogress "Loading Data..." 
    for (k, params) in enumerate(tasks)
        sim_data = Utils.loadSimData(params)
        
        # Grid index prefix: [p1_idx, p2_idx, ...]
        dest_prefix = grid_indices[k]

        # --- Eulerian Fill ---
        if sim_data isa ESimData1D
            raw_c, raw_x, raw_t = size(sim_data.u)
            
            # Fill U
            slice_and_fill!(data_store["u"], sim_data.u, dest_prefix, base_fixes, raw_c, raw_x, raw_t)
            # Fill X (Grid)
            slice_and_fill!(data_store["x"], sim_data.x, dest_prefix, base_fixes, 1, raw_x, 1) # X is [X] or [X, 1]
            
            # Fill Buckets
            for (sk, sv) in sim_data.scalars; slice_and_fill!(data_store[sk], sv, dest_prefix, base_fixes, raw_c, 1, 1); end
            for (sk, sv) in sim_data.series; slice_and_fill!(data_store[sk], sv, dest_prefix, base_fixes, raw_c, 1, raw_t); end
            for (sk, sv) in sim_data.profiles; slice_and_fill!(data_store[sk], sv, dest_prefix, base_fixes, raw_c, raw_x, 1); end
            for (sk, sv) in sim_data.fields; slice_and_fill!(data_store[sk], sv, dest_prefix, base_fixes, raw_c, raw_x, raw_t); end

        # --- Lagrangian Fill ---
        elseif sim_data isa LSimData1D
            # LSimData needs special handling for the Vector-of-Matrices structure
            # and the variable length X.
            
            # Use the dedicated helper for Core Data
            slice_and_fill_lagrangian!(data_store, sim_data.x, sim_data.u, dest_prefix, base_fixes, max_x)
            
            # Buckets handling for Lagrangian
            # Scalars [C] (Same as Euler)
            raw_c = size(sim_data.u[1], 1)
            raw_t = length(sim_data.t)
            
            for (sk, sv) in sim_data.scalars
                # Scalars are just Vector [C].
                slice_and_fill!(data_store[sk], sv, dest_prefix, base_fixes, raw_c, 1, 1)
            end
            
            for (sk, sv) in sim_data.series
                # TimeSeries is Matrix [C, T].
                slice_and_fill!(data_store[sk], sv, dest_prefix, base_fixes, raw_c, 1, raw_t)
            end
            
            # For Fields/Profiles in Lagrange, we might need a `slice_and_fill_lagrangian_bucket` 
            # if they are stored as Vector{Matrix}. 
            # Assuming `fields` in LSimData are Vector{Matrix} like `u`.
             for (sk, sv) in sim_data.fields
                # Temporarily create a dummy x dict to reuse the helper, or write a generic one.
                # For brevity, assuming 'fields' behave exactly like 'u'
                # slice_and_fill_lagrangian_bucket!(data_store[sk], sv, dest_prefix, base_fixes, max_x)
             end
        end
    end

    return UnifiedPlotData{ndims(data_store["u"])}(
        data_store,
        active_keys,
        active_values,
        first_data.t,
        fixed_params
    )
end

# ==============================================================================
# 4. ORCHESTRATOR
# ==============================================================================

function update_plot_data_collection!(
    plot_data_dict::Dict{String, UnifiedPlotData},
    sim_config::SimulationConfig,
    active_methods::Vector{String},
    fixed_params::FixedDictType;
    force_reload::Bool = false
)
    if force_reload; empty!(plot_data_dict); end

    for method_name in active_methods
        if !haskey(plot_data_dict, method_name)
            base_params = Utils.assembleParams(sim_config.shared_params, sim_config.methods_dict, method_name)
            new_data = create_method_plot_data(base_params, sim_config, fixed_params)
            if !isnothing(new_data)
                plot_data_dict[method_name] = new_data
            end
        end
    end

    # Cleanup inactive
    for k in keys(plot_data_dict)
        if !(k in active_methods); delete!(plot_data_dict, k); end
    end
    return plot_data_dict
end

end