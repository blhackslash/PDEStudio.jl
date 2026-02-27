module DataProcessing

using ..Structs
using ..Utils 
using ProgressMeter
using LinearAlgebra # For SVector handling if needed

export create_method_plot_data, update_plot_data_collection!, generate_method_tasks, analyze_configuration

# Helper: Simple nearest index lookup
find_nearest_index(vals, target) = findmin(v -> abs(v - target), vals)[2]

# ==============================================================================
# 1. TASK & CONFIGURATION ANALYSIS
# ==============================================================================

function analyze_configuration(sim_config::SimulationConfig, fixed_params::FixedDictType)
    all_varied = sim_config.varied_params
    active_keys = String[]
    active_values = Vector{Vector{Any}}()
    sorted_keys = sort(collect(keys(all_varied)))
    sim_fixes = FixedDictType()

    for (k, v) in fixed_params
        if !(k in Structs.BaseVariables); sim_fixes[k] = v; end
    end

    for key in sorted_keys
        if haskey(sim_fixes, key); continue 
        else
            push!(active_keys, key)
            push!(active_values, all_varied[key])
        end
    end
    return active_keys, active_values, sim_fixes
end

function generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    param_grid = collect(Iterators.product(active_values...))
    tasks, grid_indices = Vector{ParamDictType}(), Vector{Tuple}()

    for (linear_idx, p_vals) in enumerate(param_grid)
        task_params = copy(base_params)
        for (k, v) in sim_fixes; task_params[k] = v; end
        indices = Tuple(CartesianIndices(param_grid)[linear_idx])
        for (i, val) in enumerate(p_vals); task_params[active_keys[i]] = val; end
        push!(tasks, task_params)
        push!(grid_indices, indices)
    end
    return tasks, grid_indices
end

# ==============================================================================
# 2. DATA SLICING & DIMENSION HELPERS
# ==============================================================================

function resolve_dimensions(sim_data::AbstractSimData{D}, base_types::Vector) where D
    if sim_data isa ESimData{D}
        raw_c, raw_space, raw_t = size(sim_data.u, 1), size(sim_data.u)[2:D+1], size(sim_data.u, D+2)
    elseif sim_data isa LSimData{D}
        raw_t, raw_c = length(sim_data.t), size(sim_data.u[1][1], 1)
        max_particles = maximum(length(step) for step in sim_data.u)
        raw_space = (max_particles,)
    end

    eff_c = base_types[1] isa Number ? 1 : raw_c
    eff_space = sim_data isa ESimData{D} ? 
                ntuple(i -> base_types[1+i] isa Number ? 1 : raw_space[i], D) :
                (base_types[2] isa Number ? 1 : raw_space[1],)
    eff_t = base_types[D+2] isa Number ? 1 : raw_t

    return eff_c, eff_space, eff_t, (sim_data isa LSimData ? raw_space[1] : 0), raw_c, raw_space, raw_t
end

function get_source_slices(base_types::Vector, D::Int, raw_c::Int, raw_space::Tuple, raw_t::Int, is_lagrangian::Bool)
    c_idx = base_types[1] isa Number ? (base_types[1]:base_types[1]) : (1:raw_c)
    space_idx = is_lagrangian ? 
                (base_types[2] isa Number ? (base_types[2]:base_types[2]) : (1:raw_space[1])) :
                ntuple(i -> base_types[1+i] isa Number ? (base_types[1+i]:base_types[1+i]) : (1:raw_space[i]), D)
    t_idx = base_types[D+2] isa Number ? (base_types[D+2]:base_types[D+2]) : (1:raw_t)
    return c_idx, space_idx, t_idx
end

function slice_and_fill_eulerian!(target, source, dest_prefix, base_types, D, raw_c, raw_space, raw_t, category)
    c_src, space_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, false)
    if category == :field
        target[dest_prefix..., :, (Colon() for _ in 1:D)..., :] = source[c_src, space_src..., t_src]
    elseif category == :scalar
        target[dest_prefix..., :, (1 for _ in 1:D)..., 1] = source[c_src]
    elseif category == :series
        target[dest_prefix..., :, (1 for _ in 1:D)..., :] = source[c_src, t_src]
    elseif category == :profile
        target[dest_prefix..., :, (Colon() for _ in 1:D)..., 1] = source[c_src, space_src...]
    elseif category == :grid
        target[dest_prefix..., 1, (Colon() for _ in 1:D)..., 1] = source[space_src...]
    end
end

function slice_and_fill_lagrangian!(target, x_data, u_data, dest_prefix, base_types, D, raw_c, raw_space, raw_t)
    c_src, p_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, true)
    max_p = raw_space[1]
    
    for (tgt_t, src_t) in enumerate(t_src)
        u_step, x_step = u_data[src_t], x_data[src_t]
        curr_p_len = length(x_step)
        p_idx = base_types[2] isa Number ? Int(base_types[2]) : nothing
        
        if !isnothing(p_idx)
            if p_idx <= curr_p_len
                target["u"][dest_prefix..., :, 1, tgt_t] = u_step[p_idx][c_src, 1] 
                target["x"][dest_prefix..., :, 1, tgt_t] = x_step[p_idx]
            else
                target["u"][dest_prefix..., :, 1, tgt_t] .= NaN
                target["x"][dest_prefix..., :, 1, tgt_t] .= NaN
            end
        else
            for p in 1:curr_p_len
                target["u"][dest_prefix..., :, p, tgt_t] = u_step[p][c_src, 1]
                target["x"][dest_prefix..., :, p, tgt_t] = x_step[p]
            end
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

# Helper for nearest index lookup (ensure this is defined in the module)
find_nearest_index(vals, target) = findmin(v -> abs(v - target), vals)[2]

function create_method_plot_data(
    base_params::ParamDictType,
    sim_config::SimulationConfig{D, F},
    fixed_params::FixedDictType,
    base_types::Vector
) where {D, F}
    
    # 1. Configuration & Task Generation
    active_keys, active_values, sim_fixes = analyze_configuration(sim_config, fixed_params)
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    
    ensure_sim_data_exists!(tasks, sim_config)
    if isempty(tasks); return nothing; end

    # 2. Initialization & Dimension Resolution
    first_data = Utils.loadSimData(tasks[1]) 
    eff_c, eff_space, eff_t, max_p, raw_c, raw_space, raw_t = resolve_dimensions(first_data, base_types)
    grid_dims = length.(active_values)
    n_params = length(active_keys)
    
    data_store = Dict{String, Array{Float64}}()
    
    # Allocation Helper
    function allocate_tensor(category)
        if category == :field      # [P..., C, Space..., T]
            return fill(NaN, grid_dims..., eff_c, eff_space..., eff_t)
        elseif category == :scalar # [P..., C, 1..., 1]
            return fill(NaN, grid_dims..., eff_c, (1 for _ in 1:length(eff_space))..., 1)
        elseif category == :series # [P..., C, 1..., T]
            return fill(NaN, grid_dims..., eff_c, (1 for _ in 1:length(eff_space))..., eff_t)
        elseif category == :profile# [P..., C, Space..., 1]
            return fill(NaN, grid_dims..., eff_c, eff_space..., 1)
        elseif category == :grid   # [P..., D, Space..., T]
            grid_c = first_data isa LSimData{D} ? D : 1
            grid_t = (first_data isa ESimData{D} && !(base_types[D+2] isa Number)) ? 1 : eff_t
            return fill(NaN, grid_dims..., grid_c, eff_space..., grid_t)
        elseif category == :time   # [P..., 1, 1..., T]
            return fill(NaN, grid_dims..., 1, (1 for _ in 1:length(eff_space))..., eff_t)
        end
    end

    # --- 3. Inject Parameters as Tensors ---
    for (i, key) in enumerate(active_keys)
        param_tensor = fill(NaN, grid_dims..., 1, (1 for _ in 1:length(eff_space))..., 1)
        vals = Float64.(active_values[i])
        for (v_idx, val) in enumerate(vals)
            idx = ntuple(d -> d == i ? v_idx : (:), n_params)
            # FIX: Use '=' instead of '.=' to handle both single-point and slice assignments
            param_tensor[idx..., 1, (1 for _ in 1:length(eff_space))..., 1] = val
        end
        data_store[key] = param_tensor
    end

    # --- 4. Allocate Results & Time ---
    data_store["u"] = allocate_tensor(:field)
    data_store["x"] = allocate_tensor(:grid)
    data_store["t"] = allocate_tensor(:time)

    for k in keys(first_data.scalars); data_store[k] = allocate_tensor(:scalar); end
    for k in keys(first_data.series); data_store[k] = allocate_tensor(:series); end
    for k in keys(first_data.profiles); data_store[k] = allocate_tensor(:profile); end
    for k in keys(first_data.fields); data_store[k] = allocate_tensor(:field); end

    # --- 5. Data Filling Loop ---
    for (k, params) in enumerate(tasks)
        sim_data = Utils.loadSimData(params)
        dest_prefix = grid_indices[k]
        
        # FIX: Corrected Time assignment (used dest_prefix, == comparison, and arguments for helper)
        if eff_t == 1
            t_val = sim_data.t[find_nearest_index(sim_data.t, base_types[D+2])]
            data_store["t"][dest_prefix..., 1, (1 for _ in 1:length(eff_space))..., 1] = t_val
        else
            data_store["t"][dest_prefix..., 1, (1 for _ in 1:length(eff_space))..., :] = sim_data.t
        end

        if sim_data isa ESimData{D}
            slice_and_fill_eulerian!(data_store["u"], sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :field)
            slice_and_fill_eulerian!(data_store["x"], sim_data.x, dest_prefix, base_types, D, 1, raw_space, 1, :grid) 
            
            for (sk, sv) in sim_data.scalars; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :scalar); end
            for (sk, sv) in sim_data.series; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :series); end
            # FIX: Category name changed from :profiles to :profile
            for (sk, sv) in sim_data.profiles; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :profile); end
            for (sk, sv) in sim_data.fields; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :field); end

        elseif sim_data isa LSimData{D}
            slice_and_fill_lagrangian!(data_store, sim_data.x, sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t)
        end
    end

    return UnifiedPlotData{ndims(data_store["u"])}(
        data_store, active_keys, active_values, first_data.t, fixed_params
    )
end

function update_plot_data_collection!(plot_data_dict, sim_config, active_methods, fixed_params, base_types; force_reload=false)
    if force_reload; empty!(plot_data_dict); end
    for m_name in active_methods
        if !haskey(plot_data_dict, m_name)
            base_params = Utils.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
            new_data = create_method_plot_data(base_params, sim_config, fixed_params, base_types)
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    for k in keys(plot_data_dict); if !(k in active_methods); delete!(plot_data_dict, k); end; end
    return plot_data_dict
end

end