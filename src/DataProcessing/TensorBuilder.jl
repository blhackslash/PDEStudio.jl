include("IOUtils.jl")         
include("ConversionUtils.jl") 
include("StatCalculation.jl")
# Helper for nearest index lookup
find_nearest_index(vals, target) = findmin(v -> abs(v - target), vals)[2]

# ==============================================================================
# 1. TASK & CONFIGURATION ANALYSIS
# ==============================================================================

function analyze_configuration(sim_config::SimulationConfig, fixed_params::FixedDict)
    all_varied = sim_config.varied_params
    active_keys = String[]
    active_values = Vector{Vector{Any}}()
    sorted_keys = sort(collect(keys(all_varied)))
    sim_fixes = FixedDict()

    for (k, v) in fixed_params
        if !(k in BaseVariables); sim_fixes[k] = v; end
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
    tasks, grid_indices = Vector{ParamDict}(), Vector{Tuple}()

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


"""
    get_source_slices(base_types, D, raw_dims..., sim_data)

Generates integer indices/ranges for slicing. Performs a nearest neighbor 
search on physical coordinates (like time or grid points) if a number is provided.
"""
function get_source_slices(base_types::Vector, D::Int, raw_c::Int, raw_space::Tuple, raw_t::Int, sim_data::AbstractSimData)
    is_lagrangian = sim_data isa LSimData
    
    # 1. Component Axis (Always an integer index)
    c_idx = base_types[1] isa Number ? Int(base_types[1]) : (1:raw_c)
    
    # 2. Spatial Axes
    space_idx = if is_lagrangian
        # Lagrangian space maps strictly to a Particle Index
        base_types[2] isa Number ? Int(base_types[2]) : (1:raw_space[1])
    else
        # Eulerian space: Search the grid axes for the closest physical coordinate
        ntuple(D) do i
            val = base_types[1+i]
            if val isa Number
                # Select the 1D axis slice to search against
                grid_axis = D == 1 ? sim_data.x : selectdim(sim_data.x, i, 1) 
                return find_nearest_index(grid_axis, val)
            else
                return 1:raw_space[i]
            end
        end
    end
    
    # 3. Time Axis
    t_idx = base_types[D+2] isa Number ? find_nearest_index(sim_data.t, base_types[D+2]) : (1:raw_t)
    
    return c_idx, space_idx, t_idx
end

function slice_and_fill_eulerian!(target, source, dest_prefix, base_types, D, raw_c, raw_space, raw_t, category, sim_data)
    c_src, space_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, sim_data)
    
    # Passing an Int index automatically drops that dimension from the source slice.
    # Julia's assignment naturally broadcasts this into the size-1 slot in the target tensor.
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

function slice_and_fill_lagrangian!(target, x_data, u_data, dest_prefix, base_types, D, raw_c, raw_space, raw_t, sim_data)
    c_src, p_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, sim_data)
    max_p = raw_space[1]
    
    # t_src might be an Int (if locked) or a UnitRange (if varied). Wrap it to iterate safely.
    t_iter = t_src isa Int ? (t_src,) : t_src
    
    for (tgt_t, src_t) in enumerate(t_iter)
        u_step = u_data[src_t] # Vector of Matrices [Particles] -> [C, State]
        x_step = x_data[src_t] # Vector of SVectors [Particles] -> [SVector{D}]
        curr_p_len = length(x_step)
        
        if p_src isa Int
            # Plotting a single, specific particle
            if p_src <= curr_p_len
                target["u"][dest_prefix..., :, 1, tgt_t] = u_step[p_src][c_src, 1] 
                target["x"][dest_prefix..., :, 1, tgt_t] = x_step[p_src]
            else
                target["u"][dest_prefix..., :, 1, tgt_t] .= NaN
                target["x"][dest_prefix..., :, 1, tgt_t] .= NaN
            end
        else
            # Plotting all available particles
            for p in 1:curr_p_len
                target["u"][dest_prefix..., :, p, tgt_t] = u_step[p][c_src, 1]
                target["x"][dest_prefix..., :, p, tgt_t] = x_step[p]
            end
            
            # Pad empty/dead particle slots with NaN
            if curr_p_len < max_p
                target["u"][dest_prefix..., :, (curr_p_len+1):end, tgt_t] .= NaN
                target["x"][dest_prefix..., :, (curr_p_len+1):end, tgt_t] .= NaN
            end
        end
    end
end


# ==============================================================================
# MAIN TENSOR CREATION ROUTINE
# ==============================================================================

function create_method_plot_data(
    base_params::ParamDict,
    sim_config::SimulationConfig{D, F},
    fixed_params::FixedDict,
    base_types::Vector
) where {D, F}
    
    # 1. Configuration & Task Generation
    active_keys, active_values, sim_fixes = analyze_configuration(sim_config, fixed_params)
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    
    ensure_sim_data_exists!(tasks, sim_config)
    if isempty(tasks); return nothing; end

    # 2. Initialization & Dimension Resolution
    first_data = loadSimData(tasks[1]) 
    eff_c, eff_space, eff_t, max_p, raw_c, raw_space, raw_t = resolve_dimensions(first_data, base_types)
    grid_dims = length.(active_values)
    n_params = length(active_keys)
    
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
        elseif category == :grid   # [P..., D/1, Space..., T]
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
        sim_data = loadSimData(params)
        dest_prefix = grid_indices[k]
        
        # Resolve dynamic indices using nearest neighbor
        c_src, space_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, sim_data)
        
        # Fill Time Tensor
        if eff_t == 1
            data_store["t"][dest_prefix..., 1, (1 for _ in 1:length(eff_space))..., 1] = sim_data.t[t_src]
        else
            data_store["t"][dest_prefix..., 1, (1 for _ in 1:length(eff_space))..., :] = sim_data.t[t_src]
        end

        # Route to specific slicers
        if sim_data isa ESimData{D}
            slice_and_fill_eulerian!(data_store["u"], sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :field, sim_data)
            slice_and_fill_eulerian!(data_store["x"], sim_data.x, dest_prefix, base_types, D, 1, raw_space, 1, :grid, sim_data) 
            
            for (sk, sv) in sim_data.scalars; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :scalar, sim_data); end
            for (sk, sv) in sim_data.series; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :series, sim_data); end
            for (sk, sv) in sim_data.profiles; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :profile, sim_data); end
            for (sk, sv) in sim_data.fields; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :field, sim_data); end

        elseif sim_data isa LSimData{D}
            slice_and_fill_lagrangian!(data_store, sim_data.x, sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t, sim_data)
            
            # --- Fill Lagrangian Buckets ---
            # You can adapt the Eulerian logic or manually loop them here if you ever expand LSimData's usage!
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
            base_params = assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
            new_data = Base.invokelatest(create_method_plot_data, base_params, sim_config, fixed_params, base_types)
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    for k in keys(plot_data_dict); if !(k in active_methods); delete!(plot_data_dict, k); end; end
    return plot_data_dict
end