include("IOUtils.jl")         
include("ConversionUtils.jl") 
include("StatCalculation.jl")
include("Simulations.jl")

# Helper for nearest index lookup
find_nearest_index(vals, target) = findmin(v -> abs(v - target), vals)[2]

# Dynamic D extraction so we don't need to parameterize the whole file!
_get_D(sim_data::ESimData) = ndims(sim_data.u) - 2
_get_D(sim_data::AbstractSimData) = length(sim_data.x[1][1])

safe_reshape(data::AbstractArray, dims...) = reshape(data, dims...)
safe_reshape(data::Real, dims...) = data

"""
Safely assigns a 1D vector (or flat scalar) into an N-Dimensional target tensor.
`target_dim` is relative to the core 5 dimensions (C, X, Y, Z, T):
X = 2, Y = 3, Z = 4, T = 5.
"""
function safe_fill_axis!(target_tensor, dest_prefix, src_data, eff_len, target_dim)
    if eff_len == 1
        # If flat, safely extract the scalar and place it in the exact corner
        target_tensor[dest_prefix..., 1, 1, 1, 1, 1] = first(src_data)
    else
        # Dynamically create the slice (e.g., target_dim 2 becomes (1, :, 1, 1, 1))
        idx = ntuple(i -> i == target_dim ? (:) : 1, 5)
        try
            target_tensor[dest_prefix..., idx...] .= src_data
        catch
            target_tensor[dest_prefix..., idx...] = src_data
        end
    end
end

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
    if c_idx == 1:1
        c_idx = 1
    end
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
                    grid_axis = sim_data.x[i] 
                    return find_nearest_index(grid_axis, val)
                else
                    return 1:raw_space[i]
                end
            else
                return 1
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
        data = source
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
    method_name::String, 
    base_params::ParamDict,
    sim_config::SimulationConfig, 
    fixed_params::FixedDict,
    base_types::Vector;
    parallel=false
)
    active_keys, active_values, sim_fixes = analyze_configuration(sim_config, fixed_params)
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    isempty(tasks) && return nothing

    local first_data

# --- THE VIRTUAL METHOD INTERCEPTOR ---
    safe_method = safe_string(method_name)
    safe_ref = isnothing(sim_config.reference_name) ? nothing : safe_string(sim_config.reference_name)
    
    is_reference = !isnothing(safe_ref) && safe_method == safe_ref

    if is_reference
        isnothing(sim_config.reference_func) && return nothing
        @info "Generating high-res Reference solution in-memory (N=$(_REFERENCE_RESOLUTION[]))..."
        first_data = generate_reference_simdata(sim_config.reference_func, tasks[1])
    else
        # --- Standard Numerical Run Logic ---
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
            N_grid = _LAGRANGE_N_GRID[]
            cache_name = "conv_$(N_grid)"
            
            try
                first_data = loadSimData(tasks[1]; suffix=cache_name)
                @info "Loaded cached Eulerian conversion ($cache_name)."
            catch
                @info "Converting LSimData to ESimData at N=$N_grid for plotting..."
                first_data = convert_to_eulerian(first_data, N_grid)
                saveSimData(first_data; suffix=cache_name, overwrite=true)
            end
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
        
        local sim_data
        
        # THE FIX: Intercept the loop loading for Reference methods!
        if is_reference
            # Reuse first_data for the first frame, generate the rest on the fly
            sim_data = k == 1 ? first_data : generate_reference_simdata(sim_config.reference_func, params)
        else
            sim_data = loadSimData(params)
            
            # --- CACHED INTERCEPT ---
            if sim_data isa LSimData
                N_grid = _LAGRANGE_N_GRID[]
                cache_name = "conv_$(N_grid)"
                try
                    sim_data = loadSimData(params; suffix=cache_name)
                catch
                    sim_data = convert_to_eulerian(sim_data, N_grid)
                    saveSimData(sim_data; suffix=cache_name, overwrite=true)
                end
            end
        end
        
        dest_prefix = grid_indices[k]
        
        # NOTE: D is derived from the Eulerian data now, so it will slice perfectly!
        c_src, space_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, sim_data)
        len_sx = space_src[1] isa Int ? 1 : length(space_src[1])
        len_sy = space_src[2] isa Int ? 1 : length(space_src[2])
        len_sz = space_src[3] isa Int ? 1 : length(space_src[3])

        
        # --- Safely Extract Time (T is dim 5) ---
        safe_fill_axis!(data_store["t"], dest_prefix, sim_data.t[t_src], eff_t, 5)
        
        if sim_data isa ESimData
            slice_and_fill_eulerian!(data_store["u"], sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :field, sim_data)
            
            # --- THE NEW CLEAN ORTHOGONAL AXIS EXTRACTION ---
            # X is dim 2
            safe_fill_axis!(data_store["x"], dest_prefix, sim_data.x[1][space_src[1]], len_sx, 2)
            
            if D >= 2
                # Y is dim 3
                safe_fill_axis!(data_store["y"], dest_prefix, sim_data.x[2][space_src[2]], len_sy, 3)
            end
            if D == 3
                # Z is dim 4
                safe_fill_axis!(data_store["z"], dest_prefix, sim_data.x[3][space_src[3]], len_sz, 4)
            end
            
            for (sk, sv) in sim_data.scalars; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :scalar, sim_data); end
            for (sk, sv) in sim_data.series; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :series, sim_data); end
            
            for (sk, sv) in sim_data.scalars; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :scalar, sim_data); end
            for (sk, sv) in sim_data.series; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :series, sim_data); end
            for (sk, sv) in sim_data.profiles; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :profile, sim_data); end
            for (sk, sv) in sim_data.fields; slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :field, sim_data); end
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
            new_data = Base.invokelatest(create_method_plot_data, m_name, base_params, sim_config, fixed_params, base_types; parallel=parallel)
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    for k in keys(plot_data_dict); if !(k in active_methods); delete!(plot_data_dict, k); end; end
    return plot_data_dict
end