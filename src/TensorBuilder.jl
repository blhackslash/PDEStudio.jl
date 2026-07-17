# Helper for nearest index lookup
find_nearest_index(vals, target) = findmin(v -> abs(v - target), vals)[2]

# --- THE FIX: SVector array is (X,Y,Z,T), so ndims-1 = D ---
_get_D(sim_data::ESimData) = ndims(sim_data.u) - 1  
_get_D(sim_data::AbstractSimData) = length(sim_data.x[1][1])

safe_reshape(data::AbstractArray, dims...) = reshape(data, dims...)
safe_reshape(data::Real, dims...) = data

function _get_template_simdata(sim_config::SimulationConfig, fixed_params::Dict)
    for (m_name, params) in sim_config.methods_dict
        if contains(safe_string(m_name), "analytic") || contains(safe_string(m_name), "reference"); continue; end
        
        base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
        ik = IRunPDESims.get_ignore_keys(sim_config.methods_dict, m_name)
        tasks, _ = generate_method_tasks(base_params, collect(keys(sim_config.varied_params)), collect(values(sim_config.varied_params)), fixed_params; ignore_keys=ik)
        
        if !isempty(tasks)
            try
                return loadSimData(tasks[1],Val(PLOT_MODE[]))
            catch
            end
        end
    end
    return nothing
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
    
    # --- THE FIX: Purged raw_c! Components are now internal to the SVector. ---
    raw_space_D = size(sim_data.u)[1:D]
    raw_t = size(sim_data.u, D+1)

    raw_space = ntuple(i -> i <= length(raw_space_D) ? raw_space_D[i] : 1, 3)
    
    # --- THE FIX: base_types is now [x, y, z, t]. 1=X, 2=Y, 3=Z, 4=T ---
    eff_space = ntuple(3) do i
        if i <= D
            return base_types[i] isa Number ? 1 : raw_space[i]
        else
            return 1
        end
    end

    eff_t = base_types[4] isa Number ? 1 : raw_t
    max_p = 0 

    return eff_space, eff_t, max_p, raw_space, raw_t
end

function get_source_slices(base_types::Vector, D::Int, raw_space::Tuple, raw_t::Int, sim_data::AbstractSimData)
    # 1. Spatial Axes 
    space_idx = ntuple(3) do i
        if i <= D
            val = base_types[i] # 1 is X, 2 is Y, 3 is Z
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
    
    # 2. Time Axis (base_types[4] is Time)
    val_t = base_types[4]
    t_idx = if val_t isa Integer
        clamp(Int(val_t), 1, raw_t)
    elseif val_t isa Real
        find_nearest_index(sim_data.t, val_t)
    else
        1:raw_t
    end
    
    return space_idx, t_idx
end

function slice_and_fill_eulerian!(target, source, dest_prefix, base_types, D, raw_space, raw_t, category, sim_data)
    space_src, t_src = get_source_slices(base_types, D, raw_space, raw_t, sim_data)
    valid_space_src = space_src[1:D]

    len_sx = space_src[1] isa Int ? 1 : length(space_src[1])
    len_sy = space_src[2] isa Int ? 1 : length(space_src[2])
    len_sz = space_src[3] isa Int ? 1 : length(space_src[3])
    len_t  = t_src isa Int ? 1 : length(t_src)

    # --- THE FIX: Array assignment cleanly maps SVectors without component dimensions ---
    if category == :field
        data = source[valid_space_src..., t_src]
        target[dest_prefix..., :, :, :, :] = safe_reshape(data, len_sx, len_sy, len_sz, len_t)
    elseif category == :scalar
        data = source
        target[dest_prefix..., 1, 1, 1, 1] = safe_reshape(data, 1, 1, 1, 1)
    elseif category == :series
        data = source[t_src]
        target[dest_prefix..., 1, 1, 1, :] = safe_reshape(data, 1, 1, 1, len_t)
    elseif category == :profile
        data = source[valid_space_src...]
        target[dest_prefix..., :, :, :, 1] = safe_reshape(data, len_sx, len_sy, len_sz, 1)
    end
end

# ==============================================================================
# LAGRANGIAN TENSOR CREATION ROUTINE
# ==============================================================================
function create_lagrangian_plot_data(
    method_name::String, 
    base_params::ParamDict,
    sim_config::SimulationConfig, 
    fixed_params::FixedDict,
    base_types::Vector;
)
    active_keys, active_values, sim_fixes = analyze_configuration(sim_config, fixed_params)
    mode = Val(PLOT_MODE[])
    ignore_keys = IRunPDESims.get_ignore_keys(sim_config.methods_dict, method_name)
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes; ignore_keys=ignore_keys)
    isempty(tasks) && return nothing

    for task in tasks; _recombine_tuples!(task); end
    
    base_template = _get_template_simdata(sim_config, sim_fixes)
    if isnothing(base_template)
        @warn "Cannot generate Lagrangian data: No valid simulation data found."
        return nothing
    end

    grid_dims = isempty(active_values) ? (1,) : Tuple(length.(active_values))
    l_data_store = Array{Any}(undef, grid_dims...)
    
    for (k, params) in enumerate(tasks)
        is_ref = contains(safe_string(method_name), "analytic") || contains(safe_string(method_name), "reference")
        sim_data = is_ref ? IRunPDESims.generate_reference_simdata(sim_config.reference_func, params, base_template) : loadSimData(params,mode)
        
        dest_prefix = isempty(grid_indices[k]) ? (1,) : grid_indices[k]
        l_data_store[dest_prefix...] = sim_data
    end

    return LagrangianPlotData{ndims(l_data_store)}(
        l_data_store, active_keys, active_values, base_template.t, fixed_params
    )
end

# ==============================================================================
# MAIN TENSOR CREATION ROUTINE
# ==============================================================================
function create_eulerian_plot_data(
    method_name::String, 
    base_params::ParamDict,
    sim_config::SimulationConfig, 
    fixed_params::FixedDict,
    base_types::Vector;
)
    active_keys, active_values, sim_fixes = analyze_configuration(sim_config, fixed_params)
    mode = Val(PLOT_MODE[])
    
    ignore_keys = IRunPDESims.get_ignore_keys(sim_config.methods_dict, method_name)
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes; ignore_keys=ignore_keys)
    isempty(tasks) && return nothing

    for task in tasks; _recombine_tuples!(task); end

    safe_method = safe_string(method_name)
    safe_ref = isnothing(sim_config.reference_name) ? nothing : safe_string(sim_config.reference_name)
    is_reference = !isnothing(safe_ref) && safe_method == safe_ref
    
    base_template = _get_template_simdata(sim_config, sim_fixes)
    if isnothing(base_template)
        @warn "Cannot generate plot data: No valid simulation data found to use as a domain template."
        return nothing
    end

    local template_data
    if is_reference
        template_data = IRunPDESims.generate_reference_simdata(sim_config.reference_func, tasks[1], base_template)
    else
        template_data = base_template
    end

    D = _get_D(template_data)  
    eff_space, eff_t, max_p, raw_space, raw_t = resolve_dimensions(template_data, base_types)
    grid_dims = length.(active_values)
    n_params = length(active_keys)
    
    data_store = Dict{String, AbstractArray}()
    
    # --- THE FIX: Tensors no longer allocate a component dimension ---
    function allocate_tensor(category, T_type=Float64)
        if category == :field      
            return Array{T_type}(undef, grid_dims..., eff_space..., eff_t)
        elseif category == :scalar 
            return Array{T_type}(undef, grid_dims..., 1, 1, 1, 1)
        elseif category == :series 
            return Array{T_type}(undef, grid_dims..., 1, 1, 1, eff_t)
        elseif category == :profile
            return Array{T_type}(undef, grid_dims..., eff_space..., 1)
        end
    end

    space_src_first, t_src_first = get_source_slices(base_types, D, raw_space, raw_t, template_data)
    
    function make_independent_dims(target_dim_idx, eff_len)
        return ntuple(i -> i == target_dim_idx ? eff_len : 1, n_params + 4)
    end

    # --- THE FIX: Array wrapping `[data]` resolves the reshape MethodError! ---
    len_t = t_src_first isa Int ? 1 : length(t_src_first)
    t_data = t_src_first isa Int ? [template_data.t[t_src_first]] : template_data.t[t_src_first]
    data_store["t"] = reshape(t_data, make_independent_dims(n_params + 4, len_t))

    len_x = space_src_first[1] isa Int ? 1 : length(space_src_first[1])
    x_data = space_src_first[1] isa Int ? [template_data.x[1][space_src_first[1]]] : template_data.x[1][space_src_first[1]]
    data_store["x"] = reshape(x_data, make_independent_dims(n_params + 1, len_x))
    
    if D >= 2
        len_y = space_src_first[2] isa Int ? 1 : length(space_src_first[2])
        y_data = space_src_first[2] isa Int ? [template_data.x[2][space_src_first[2]]] : template_data.x[2][space_src_first[2]]
        data_store["y"] = reshape(y_data, make_independent_dims(n_params + 2, len_y))
    end
    if D == 3
        len_z = space_src_first[3] isa Int ? 1 : length(space_src_first[3])
        z_data = space_src_first[3] isa Int ? [template_data.x[3][space_src_first[3]]] : template_data.x[3][space_src_first[3]]
        data_store["z"] = reshape(z_data, make_independent_dims(n_params + 3, len_z))
    end

    for (i, key) in enumerate(active_keys)
        param_tensor = fill(NaN, grid_dims..., 1, 1, 1, 1)
        vals = Float64.(active_values[i])
        for (v_idx, val) in enumerate(vals)
            idx = ntuple(d -> d == i ? v_idx : (:), n_params)
            if Colon() in idx
                param_tensor[idx..., 1, 1, 1, 1] .= val
            else
                param_tensor[idx..., 1, 1, 1, 1] = val
            end
        end
        data_store[key] = param_tensor
    end

    # --- THE FIX: Dynamically allocate specific SVector types! ---
    data_store["u"] = allocate_tensor(:field, eltype(template_data.u))
    for (k, v) in template_data.scalars; data_store[k] = allocate_tensor(:scalar, eltype(v)); end
    for (k, v) in template_data.series;  data_store[k] = allocate_tensor(:series, eltype(v)); end
    for (k, v) in template_data.profiles; data_store[k] = allocate_tensor(:profile, eltype(v)); end
    for (k, v) in template_data.fields;  data_store[k] = allocate_tensor(:field, eltype(v)); end

    for (k, params) in enumerate(tasks)
        local sim_data
        
        if is_reference
            sim_data = (k == 1) ? template_data : IRunPDESims.generate_reference_simdata(sim_config.reference_func, params, base_template)
        else
            sim_data = loadSimData(params,mode)
        end
        
        dest_prefix = grid_indices[k]

        slice_and_fill_eulerian!(data_store["u"], sim_data.u, dest_prefix, base_types, D, raw_space, raw_t, :field, sim_data)
        
        for (sk, sv) in sim_data.scalars
            haskey(data_store, sk) && slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_space, raw_t, :scalar, sim_data)
        end
        for (sk, sv) in sim_data.series
            haskey(data_store, sk) && slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_space, raw_t, :series, sim_data)
        end
        for (sk, sv) in sim_data.profiles
            haskey(data_store, sk) && slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_space, raw_t, :profile, sim_data)
        end
        for (sk, sv) in sim_data.fields
            haskey(data_store, sk) && slice_and_fill_eulerian!(data_store[sk], sv, dest_prefix, base_types, D, raw_space, raw_t, :field, sim_data)
        end
    end

    return EulerianPlotData{ndims(data_store["u"])}(
        data_store, active_keys, active_values, template_data.t, fixed_params
    )
end

function update_plot_data_collection!(plot_data_dict, sim_config, manager::PlotManager, active_methods, base_types; force_reload=false)
    if force_reload; empty!(plot_data_dict); end
    for m_name in active_methods
        if !haskey(plot_data_dict, m_name)
            base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
            if isempty(base_params); continue end
            
            shared_ui = ParamDict(k => v[] for (k, v) in manager.simulation["shared"])
            method_ui = haskey(manager.simulation, m_name) ? ParamDict(k => v[] for (k, v) in manager.simulation[m_name]) : ParamDict()
            
            fixed_params = ParamDict()
            for (k, v) in shared_ui; k == "ignore" && continue; fixed_params[k] = v; end
            for (k, v) in method_ui; k == "ignore" && continue; fixed_params[k] = v; end
            
            builder_func = PLOT_MODE[] == :lagrangian ? create_lagrangian_plot_data : create_eulerian_plot_data
            new_data = Base.invokelatest(builder_func, m_name, base_params, sim_config, fixed_params, base_types;)
            
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    
    for k in keys(plot_data_dict); if !(k in active_methods); delete!(plot_data_dict, k); end; end
    return plot_data_dict
end