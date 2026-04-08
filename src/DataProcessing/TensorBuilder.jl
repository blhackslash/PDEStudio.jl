include("IOUtils.jl")         
include("ConversionUtils.jl") 
include("StatCalculation.jl")
include("Simulations.jl")

# Helper for nearest index lookup
find_nearest_index(vals, target) = findmin(v -> abs(v - target), vals)[2]

# Dynamic D extraction so we don't need to parameterize the whole file!
_get_D(::AbstractSimData{D}) where D = D
safe_reshape(data::AbstractArray, dims...) = reshape(data, dims...)
safe_reshape(data::Real, dims...) = fill(data, dims...)

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

# ==============================================================================
# 2. DATA SLICING & DIMENSION HELPERS
# ==============================================================================

function resolve_dimensions(sim_data::AbstractSimData, base_types::Vector)
    D = _get_D(sim_data)
    
    if sim_data isa ESimData
        raw_c = size(sim_data.u, 1)
        raw_space_D = size(sim_data.u)[2:D+1]
        raw_t = size(sim_data.u, D+2)
    elseif sim_data isa LSimData
        raw_t = length(sim_data.t)
        raw_c = size(sim_data.u[1][1], 1)
        max_particles = maximum(length(step) for step in sim_data.u)
        raw_space_D = (max_particles,)
    end

    # Pad raw space to exactly 3D
    raw_space = ntuple(i -> i <= length(raw_space_D) ? raw_space_D[i] : 1, 3)

    eff_c = base_types[1] isa Number ? 1 : raw_c
    
    # Pad effective space to exactly 3D
    eff_space = ntuple(3) do i
        if sim_data isa ESimData
            if i <= D
                return base_types[1+i] isa Number ? 1 : raw_space[i]
            else
                return 1
            end
        else # LSimData
            if i == 1
                return base_types[2] isa Number ? 1 : raw_space[1]
            else
                return 1
            end
        end
    end

    # base_types is now always length 5 (Comp, X, Y, Z, Time)
    eff_t = base_types[5] isa Number ? 1 : raw_t

    max_p = sim_data isa LSimData ? raw_space[1] : 0

    return eff_c, eff_space, eff_t, max_p, raw_c, raw_space, raw_t
end

"""
    get_source_slices(base_types, D, raw_dims..., sim_data)

Smartly generates slices based on input type:
- Integer: Direct Array Index (e.g., 10 -> 10th step)
- Real/Float: Physical Coordinate Search (e.g., 0.5 -> nearest grid point to 0.5)
"""
function get_source_slices(base_types::Vector, D::Int, raw_c::Int, raw_space::Tuple, raw_t::Int, sim_data::AbstractSimData)
    is_lagrangian = sim_data isa LSimData
    
    # 1. Component Axis (Always an integer index)
    c_idx = base_types[1] isa Number ? Int(base_types[1]) : (1:raw_c)
    
    # 2. Spatial Axes
    space_idx = if is_lagrangian
        # Particles are always indexed by ID
        p_idx = base_types[2] isa Number ? Int(base_types[2]) : (1:raw_space[1])
        (p_idx, 1:1, 1:1)
    else
        ntuple(3) do i
            if i <= D
                val = base_types[1+i]
                if val isa Integer
                    # SMART ADAPT: Direct Indexing (clamped for safety)
                    return clamp(Int(val), 1, raw_space[i])
                elseif val isa Real
                    # SMART ADAPT: Physical coordinate search
                    grid_axis = D == 1 ? sim_data.x : selectdim(sim_data.x, i, 1) 
                    return find_nearest_index(grid_axis, val)
                else
                    return 1:raw_space[i]
                end
            else
                return 1:1
            end
        end
    end
    
    # 3. Time Axis
    t_idx = if base_types[5] isa Integer
        # SMART ADAPT: Direct Indexing
        clamp(Int(base_types[5]), 1, raw_t)
    elseif base_types[5] isa Real
        # SMART ADAPT: Physical coordinate search
        find_nearest_index(sim_data.t, base_types[5])
    else
        1:raw_t
    end
    
    return c_idx, space_idx, t_idx
end

function slice_and_fill_eulerian!(target, source, dest_prefix, base_types, D, raw_c, raw_space, raw_t, category, sim_data)
    c_src, space_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, sim_data)
    
    valid_space_src = space_src[1:D]

    # Calculate exact lengths to guarantee shape matching for broadcasting
    len_c = c_src isa Int ? 1 : length(c_src)
    len_sx = space_src[1] isa Int ? 1 : length(space_src[1])
    len_sy = space_src[2] isa Int ? 1 : length(space_src[2])
    len_sz = space_src[3] isa Int ? 1 : length(space_src[3])
    len_t = t_src isa Int ? 1 : length(t_src)

    if category == :field
        data = source[c_src, valid_space_src..., t_src]
        target[dest_prefix..., :, :, :, :, :] = safe_reshape(data, len_c, len_sx, len_sy, len_sz, len_t)
    elseif category == :scalar
        data = source[c_src]
        target[dest_prefix..., 1, 1, 1, 1, 1] = safe_reshape(data, 1, 1, 1, 1, 1)
    elseif category == :series
        data = source[c_src, t_src]
        target[dest_prefix..., :, 1, 1, 1, :] = safe_reshape(data, len_c, 1, 1, 1, len_t)
    elseif category == :profile
        data = source[c_src, valid_space_src...]
        target[dest_prefix..., :, :, :, :, 1] = safe_reshape(data, len_c, len_sx, len_sy, len_sz, 1)
    elseif category == :grid
        data = source[valid_space_src...]
        target[dest_prefix..., 1, :, :, :, 1] = safe_reshape(data, 1, len_sx, len_sy, len_sz, 1)
    end
end

# ==============================================================================
# MAIN TENSOR CREATION ROUTINE
# ==============================================================================

function create_method_plot_data(
    base_params::ParamDict,
    sim_config::SimulationConfig, 
    fixed_params::FixedDict,
    base_types::Vector;
    parallel=false
)
    # 1. Configuration & Task Generation
    active_keys, active_values, sim_fixes = analyze_configuration(sim_config, fixed_params)
    
    # Generate tasks exclusively for THIS method
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    if isempty(tasks); return nothing; end

    # 2. Smart Execution (Replaces ensure_sim_data_exists!)
    # Runs the solver only if the data doesn't already exist on disk
    if parallel
        Threads.@threads for params in tasks
            try
                run_simulation(sim_config.simulation_func, params; force_overwrite=false)
            catch e
                @error "Simulation Error" exception=(e, catch_backtrace())
            end
        end
    else
        for params in tasks
            run_simulation(sim_config.simulation_func, params; force_overwrite=false)
        end
    end

    first_data = loadSimData(tasks[1]) 
    if isnothing(first_data)
        @warn "Failed to load simulation data after execution."
        return nothing
    end
    
    # --- CACHED INTERCEPT ---
    if first_data isa LSimData
        try
            first_data = loadSimData(tasks[1]; suffix="conv")
            @info "Loaded cached Eulerian conversion."
        catch
            @info "Converting LSimData to ESimData for plotting (this only happens once)..."
            first_data = convert_to_eulerian(first_data, 50) # Use your preferred grid resolution!
            saveSimData(first_data; suffix="conv", overwrite=true)
        end
    end
    
    D = _get_D(first_data)
    
    eff_c, eff_space, eff_t, max_p, raw_c, raw_space, raw_t = resolve_dimensions(first_data, base_types)
    grid_dims = length.(active_values)
    n_params = length(active_keys)
    
    data_store = Dict{String, Array{Float64}}()
    
    function allocate_tensor(category)
        if category == :field      # [P..., C, X, Y, Z, T]
            return fill(NaN, grid_dims..., eff_c, eff_space..., eff_t)
        elseif category == :scalar # [P..., C, 1, 1, 1, 1]
            return fill(NaN, grid_dims..., 1, 1, 1, 1, 1)
        elseif category == :series # [P..., C, 1, 1, 1, T]
            return fill(NaN, grid_dims..., eff_c, 1, 1, 1, eff_t)
        elseif category == :profile# [P..., C, X, Y, Z, 1]
            return fill(NaN, grid_dims..., eff_c, eff_space..., 1)
        elseif category == :grid   # [P..., 1, X, Y, Z, grid_t]
            grid_t = (first_data isa ESimData && !(base_types[5] isa Number)) ? 1 : eff_t
            return fill(NaN, grid_dims..., 1, eff_space..., grid_t)
        elseif category == :time   # [P..., 1, 1, 1, 1, T]
            return fill(NaN, grid_dims..., 1, 1, 1, 1, eff_t)
        end
    end

    # --- 4. Inject Parameters as Tensors ---
    for (i, key) in enumerate(active_keys)
        param_tensor = fill(NaN, grid_dims..., 1, 1, 1, 1, 1)
        vals = Float64.(active_values[i])
        for (v_idx, val) in enumerate(vals)
            idx = ntuple(d -> d == i ? v_idx : (:), n_params)
            param_tensor[idx..., 1, 1, 1, 1, 1] = val
        end
        data_store[key] = param_tensor
    end

    # --- 5. Allocate Results & Time ---
    data_store["u"] = allocate_tensor(:field)
    
    data_store["x"] = allocate_tensor(:grid)
    if D >= 2; data_store["y"] = allocate_tensor(:grid); end
    if D == 3; data_store["z"] = allocate_tensor(:grid); end
    
    data_store["t"] = allocate_tensor(:time)

    for k in keys(first_data.scalars); data_store[k] = allocate_tensor(:scalar); end
    for k in keys(first_data.series); data_store[k] = allocate_tensor(:series); end
    for k in keys(first_data.profiles); data_store[k] = allocate_tensor(:profile); end
    for k in keys(first_data.fields); data_store[k] = allocate_tensor(:field); end

    # --- 6. Data Filling Loop ---
    # Loads SimData from disk one by one, keeping RAM usage low
    for (k, params) in enumerate(tasks)
        sim_data = loadSimData(params)
        # --- CACHED INTERCEPT ---
        if sim_data isa LSimData
            try
                sim_data = loadSimData(params; suffix="conv")
            catch
                sim_data = convert_to_eulerian(sim_data, 50)
                saveSimData(sim_data; suffix="conv", overwrite=true)
            end
        end
        
        dest_prefix = grid_indices[k]
        
        # NOTE: D is derived from the Eulerian data now, so it will slice perfectly!
        c_src, space_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, sim_data)
        
        # Fill Time Tensor
        if eff_t == 1
            data_store["t"][dest_prefix..., 1, 1, 1, 1, 1] = sim_data.t[t_src]
        else
            data_store["t"][dest_prefix..., 1, 1, 1, 1, :] .= sim_data.t[t_src]
        end


        slice_and_fill_eulerian!(data_store["u"], sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :field, sim_data)
        
        # Split Eulerian Coordinates
        if D == 1
            slice_and_fill_eulerian!(data_store["x"], sim_data.x, dest_prefix, base_types, D, 1, raw_space, 1, :grid, sim_data) 
        elseif D == 2
            slice_and_fill_eulerian!(data_store["x"], selectdim(sim_data.x, D+1, 1), dest_prefix, base_types, D, 1, raw_space, 1, :grid, sim_data) 
            slice_and_fill_eulerian!(data_store["y"], selectdim(sim_data.x, D+1, 2), dest_prefix, base_types, D, 1, raw_space, 1, :grid, sim_data) 
        elseif D == 3
            slice_and_fill_eulerian!(data_store["x"], selectdim(sim_data.x, D+1, 1), dest_prefix, base_types, D, 1, raw_space, 1, :grid, sim_data) 
            slice_and_fill_eulerian!(data_store["y"], selectdim(sim_data.x, D+1, 2), dest_prefix, base_types, D, 1, raw_space, 1, :grid, sim_data) 
            slice_and_fill_eulerian!(data_store["z"], selectdim(sim_data.x, D+1, 3), dest_prefix, base_types, D, 1, raw_space, 1, :grid, sim_data) 
        end
    end

    return UnifiedPlotData{ndims(data_store["u"])}(
        data_store, active_keys, active_values, first_data.t, fixed_params
    )
end

function update_plot_data_collection!(plot_data_dict, sim_config, active_methods, fixed_params, base_types; force_reload=false, parallel=false)
    if force_reload; empty!(plot_data_dict); end
    for m_name in active_methods
        if !haskey(plot_data_dict, m_name)
            base_params = assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
            new_data = Base.invokelatest(create_method_plot_data, base_params, sim_config, fixed_params, base_types; parallel=parallel)
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    for k in keys(plot_data_dict); if !(k in active_methods); delete!(plot_data_dict, k); end; end
    return plot_data_dict
end