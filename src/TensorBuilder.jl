# Helper for nearest index lookup
find_nearest_index(vals, target) = findmin(v -> abs(v - target), vals)[2]

# Dynamic D extraction so we don't need to parameterize the whole file!
_get_D(sim_data::ESimData) = ndims(sim_data.u) - 2
_get_D(sim_data::AbstractSimData) = length(sim_data.x[1][1])

safe_reshape(data::AbstractArray, dims...) = reshape(data, dims...)
safe_reshape(data::Real, dims...) = data

function _get_global_target_t(sim_config::SimulationConfig, fixed_params::Dict)
    for (m_name, params) in sim_config.methods_dict
        if contains(safe_string(m_name), "analytic") || contains(safe_string(m_name), "reference"); continue; end
        
        base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
        ik = IRunPDESims.get_ignore_keys(sim_config.methods_dict, m_name)
        tasks, _ = generate_method_tasks(base_params, collect(keys(sim_config.varied_params)), collect(values(sim_config.varied_params)), fixed_params; ignore_keys=ik)
        
        if !isempty(tasks)
            try
                sim_data = loadSimData(tasks[1])
                if !isnothing(sim_data); return sim_data.t; end
            catch
            end
        end
    end
    return Float64[]
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

    for key in sorted_keys
        push!(active_keys, key)
        push!(active_values, all_varied[key])
    end

    for (k, v) in fixed_params
        if !(k in BaseVariables) && !(k in sorted_keys)
            sim_fixes[k] = v
        end
    end

    return active_keys, active_values, sim_fixes
end

# ==============================================================================
# 2. DATA SLICING & DIMENSION HELPERS
# ==============================================================================

function resolve_dimensions(sim_data::AbstractSimData, base_types::Vector)
    D = _get_D(sim_data)
    
    # LSimData branches removed. Intercept converts everything to ESimData here!
    raw_c = size(sim_data.u, 1)
    raw_space_D = size(sim_data.u)[2:D+1]
    raw_t = size(sim_data.u, D+2)

    raw_space = ntuple(i -> i <= length(raw_space_D) ? raw_space_D[i] : 1, 3)
    eff_c = base_types[1] isa Number ? 1 : raw_c
    
    eff_space = ntuple(3) do i
        if i <= D
            return base_types[1+i] isa Number ? 1 : raw_space[i]
        else
            return 1
        end
    end

    eff_t = base_types[5] isa Number ? 1 : raw_t
    max_p = 0 

    return eff_c, eff_space, eff_t, max_p, raw_c, raw_space, raw_t
end

function get_source_slices(base_types::Vector, D::Int, raw_c::Int, raw_space::Tuple, raw_t::Int, sim_data::AbstractSimData)
    # 1. Component Axis
    c_idx = base_types[1] isa Number ? Int(base_types[1]) : (1:raw_c)
    if c_idx == 1:1; c_idx = 1; end
    
    # 2. Spatial Axes
    space_idx = ntuple(3) do i
        if i <= D
            val = base_types[1+i]
            if val isa Integer
                return clamp(Int(val), 1, raw_space[i])
            elseif val isa Real
                grid_axis = sim_data.x[i] 
                return find_nearest_index(grid_axis, val)
            else
                return 1:raw_space[i]
            end
        else
            return 1
        end
    end
    
    # 3. Time Axis
    t_idx = if base_types[5] isa Integer
        clamp(Int(base_types[5]), 1, raw_t)
    elseif base_types[5] isa Real
        find_nearest_index(sim_data.t, base_types[5])
    else
        1:raw_t
    end
    
    return c_idx, space_idx, t_idx
end

function slice_and_fill_eulerian!(target, source, dest_prefix, base_types, D, raw_c, raw_space, raw_t, category, sim_data)
    c_src, space_src, t_src = get_source_slices(base_types, D, raw_c, raw_space, raw_t, sim_data)
    
    valid_space_src = space_src[1:D]

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
    
    ignore_keys = IRunPDESims.get_ignore_keys(sim_config.methods_dict, method_name)
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes; ignore_keys=ignore_keys)
    isempty(tasks) && return nothing

    for task in tasks
        _recombine_tuples!(task)
    end

    local first_data
    local target_t

    safe_method = safe_string(method_name)
    safe_ref = isnothing(sim_config.reference_name) ? nothing : safe_string(sim_config.reference_name)
    is_reference = !isnothing(safe_ref) && safe_method == safe_ref

    if is_reference
        isnothing(sim_config.reference_func) && return nothing
        target_t = _get_global_target_t(sim_config, sim_fixes)
        @info "Generating high-res Reference solution in-memory (N=$(_REFERENCE_RESOLUTION[]))..."
        first_data = generate_reference_simdata(sim_config.reference_func, tasks[1], target_t)
    else
        target_t = runAllSimulations(
            sim_config; 
            active_methods=[method_name], 
            varied_params=sim_config.varied_params, 
            fixed_params=sim_fixes, 
            convert_eulerian=true, 
            parallel=parallel
        )
        
        first_data = loadSimData(tasks[1]) 
        if isnothing(first_data)
            @warn "Failed to load simulation data after execution."
            return nothing
        end
        
        if first_data isa LSimData
            N_grid = _LAGRANGE_N_GRID[]
            try
                first_data = loadBestConversion(tasks[1], N_grid)
            catch e
                if !(e isa SimFileNotFoundError); @warn e end
                @info "Converting LSimData to ESimData at N=$N_grid for plotting..."
                first_data = convert_to_eulerian(first_data, N_grid; target_t=target_t)
                saveSimData(first_data; data_key="sim_data_plot_$(N_grid)", overwrite=true)
            end
        end
    end
    
    D = _get_D(first_data)  
    eff_c, eff_space, eff_t, max_p, raw_c, raw_space, raw_t = resolve_dimensions(first_data, base_types)
    grid_dims = length.(active_values)
    n_params = length(active_keys)
    
    data_store = Dict{String, Array{Float64}}()
    
    function allocate_tensor(category)
        if category == :field      
            return fill(NaN, grid_dims..., eff_c, eff_space..., eff_t)
        elseif category == :scalar 
            return fill(NaN, grid_dims..., 1, 1, 1, 1, 1)
        elseif category == :series 
            return fill(NaN, grid_dims..., eff_c, 1, 1, 1, eff_t)
        elseif category == :profile
            return fill(NaN, grid_dims..., eff_c, eff_space..., 1)
        end
    end

    # --- 1. Construct Perfectly Independent Grids! ---
    c_src_first, space_src_first, t_src_first = get_source_slices(base_types, D, raw_c, raw_space, raw_t, first_data)
    
    function make_independent_dims(target_dim_idx, eff_len)
        return ntuple(i -> i == target_dim_idx ? eff_len : 1, n_params + 5)
    end

    len_t = t_src_first isa Int ? 1 : length(t_src_first)
    data_store["t"] = reshape(first_data.t[t_src_first], make_independent_dims(n_params + 5, len_t))

    len_x = space_src_first[1] isa Int ? 1 : length(space_src_first[1])
    data_store["x"] = reshape(first_data.x[1][space_src_first[1]], make_independent_dims(n_params + 2, len_x))
    
    if D >= 2
        len_y = space_src_first[2] isa Int ? 1 : length(space_src_first[2])
        data_store["y"] = reshape(first_data.x[2][space_src_first[2]], make_independent_dims(n_params + 3, len_y))
    end
    if D == 3
        len_z = space_src_first[3] isa Int ? 1 : length(space_src_first[3])
        data_store["z"] = reshape(first_data.x[3][space_src_first[3]], make_independent_dims(n_params + 4, len_z))
    end

    # --- 2. Inject Parameters as Tensors ---
    for (i, key) in enumerate(active_keys)
        param_tensor = fill(NaN, grid_dims..., 1, 1, 1, 1, 1)
        vals = Float64.(active_values[i])
        for (v_idx, val) in enumerate(vals)
            idx = ntuple(d -> d == i ? v_idx : (:), n_params)
            if Colon() in idx
                param_tensor[idx..., 1, 1, 1, 1, 1] .= val
            else
                param_tensor[idx..., 1, 1, 1, 1, 1] = val
            end
        end
        data_store[key] = param_tensor
    end

    # --- 3. Allocate Results ---
    data_store["u"] = allocate_tensor(:field)
    
    for k in keys(first_data.scalars); data_store[k] = allocate_tensor(:scalar); end
    for k in keys(first_data.series); data_store[k] = allocate_tensor(:series); end
    for k in keys(first_data.profiles); data_store[k] = allocate_tensor(:profile); end
    for k in keys(first_data.fields); data_store[k] = allocate_tensor(:field); end

    # --- 4. Data Filling Loop ---
    for (k, params) in enumerate(tasks)
        
        local sim_data
        
        if is_reference
            sim_data = k == 1 ? first_data : generate_reference_simdata(sim_config.reference_func, params, target_t)
        else
            sim_data = loadSimData(params)
            
            if sim_data isa LSimData
                N_grid = _LAGRANGE_N_GRID[]
                try
                    sim_data = loadBestConversion(params, N_grid)
                catch e
                    if !(e isa SimFileNotFoundError); @warn e end
                    sim_data = convert_to_eulerian(sim_data, N_grid; target_t=target_t)
                    saveSimData(sim_data; data_key="sim_data_plot_$(N_grid)", overwrite=true)
                end
            end
        end
        # --- THE FIX: Grid Consistency Check ---
        if !isapprox(sim_data.t, first_data.t, rtol=1e-5)
            @warn "Time vectors do not match perfectly for task $(k)! Ensure simulations output matching temporal sequences."
        end
        for d in 1:D
            if !isapprox(sim_data.x[d], first_data.x[d], rtol=1e-5)
                @warn "Spatial grid axis $d does not perfectly match for task $(k)! The parameter $k might have physically shifted the domain."
            end
        end
        
        dest_prefix = grid_indices[k]
        
        if sim_data isa ESimData
            slice_and_fill_eulerian!(data_store["u"], sim_data.u, dest_prefix, base_types, D, raw_c, raw_space, raw_t, :field, sim_data)
            
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

function update_plot_data_collection!(plot_data_dict, sim_config, manager::PlotManager, active_methods, base_types; force_reload=false, parallel=false)
    if force_reload; empty!(plot_data_dict); end
    for m_name in active_methods
        if !haskey(plot_data_dict, m_name)
            # 1. Base math params from config
            base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
            if isempty(base_params); continue end
            
            # 2. Extract UI observables for THIS specific method
            shared_ui = ParamDict(k => v[] for (k, v) in manager.simulation["shared"])
            method_ui = haskey(manager.simulation, m_name) ? ParamDict(k => v[] for (k, v) in manager.simulation[m_name]) : ParamDict()
            
            # 3. Merge them correctly (method overrides shared!)
            fixed_params = ParamDict()
            for (k, v) in shared_ui
                k == "ignore" && continue # Safety catch
                fixed_params[k] = v
            end
            for (k, v) in method_ui
                k == "ignore" && continue # THE FIX: Strip the meta-parameter!
                fixed_params[k] = v
            end
            
            # 4. Generate the plot data with the correctly merged UI params
            new_data = Base.invokelatest(create_method_plot_data, m_name, base_params, sim_config, fixed_params, base_types; parallel=parallel)
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    
    for k in keys(plot_data_dict); if !(k in active_methods); delete!(plot_data_dict, k); end; end
    return plot_data_dict
end