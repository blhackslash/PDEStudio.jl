# ==============================================================================
# DATA EXTRACTION PIPELINE (Dispatched by Val{D})
# ==============================================================================

# Generic Slicing Helper
function _get_desired_indices(pd::UnifiedPlotData, target_dims::Tuple, sel_vals)
    return map(1:length(sel_vals)) do i
        if i in target_dims; return (:); end
        
        raw_val = sel_vals[i]
        if isnothing(raw_val) || raw_val == "-" || raw_val == "disabled"
            return 1 # Fallback during UI boot-up
        end
        
        val = raw_val isa String ? parse(Int, raw_val) : raw_val
        return find_closest_index_for_dim(pd, i, val)
    end
end

"""
    get_base_dim_idx(pd, key, dim_names)

Implements the Metric Rule: Finds the single Base Dimension a variable varies along, 
ignoring Varied Parameters. E.g., `l2error` returns the `Time` index.
"""
function get_base_dim_idx(pd::UnifiedPlotData, key::String, dim_names::Vector{String})
    idx = findfirst(isequal(key), dim_names)
    !isnothing(idx) && return idx
    
    tensor = get(pd.data, key, nothing)
    isnothing(tensor) && return 1 
    
    n_params = length(pd.active_param_keys)
    varying = findall(s -> s > 1, size(tensor))
    phys_varying = filter(d -> d > n_params, varying)
    
    if length(phys_varying) == 1
        return phys_varying[1]
    elseif isempty(phys_varying) && !isempty(varying)
        return varying[1]
    else
        return isempty(varying) ? 1 : varying[1]
    end
end

# --- 1D Data Extraction ---
function extract_data(data::Dict, manager::PlotManager, sel_vals, x_key, y_key, z_key, u_key, ::Val{1})
    dim_names = manager.plot_vars
    pd_first = first(values(data))
    
    # In 1D, X natively dictates the Plot-Along dimension!
    slice_dim_idx = get_base_dim_idx(pd_first, x_key, dim_names)
    
    xs, us, valid_labels = Vector{Float64}[], Vector{Float64}[], String[]
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (slice_dim_idx,), sel_vals)
        
        safe_x = map(i -> i == slice_dim_idx ? (:) : min(des_idx[i], size(x_tensor, i)), 1:ndims(x_tensor))
        safe_u = map(i -> i == slice_dim_idx ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            x_val = x_tensor[safe_x...]
            u_val = u_tensor[safe_u...]
            push!(xs, x_val isa AbstractVector ? vec(x_val) : [Float64(x_val)])
            push!(us, u_val isa AbstractVector ? vec(u_val) : [Float64(u_val)])
            push!(valid_labels, m_name)
        catch e; @warn "1D Slicing failed for $m_name" exception=e; end
    end
    
    title_str = generate_dynamic_title(slice_dim_idx, dim_names, sel_vals)
    return (xs, us), valid_labels, title_str
end

# --- 2D Data Extraction ---
function extract_data(data::Dict, manager::PlotManager, sel_vals, x_key, y_key, z_key, u_key, ::Val{2})
    dim_names = manager.plot_vars
    pd_first = first(values(data))
    
    dim1 = get_base_dim_idx(pd_first, x_key, dim_names)
    dim2 = get_base_dim_idx(pd_first, y_key, dim_names)
    
    xs, ys, us, valid_labels = Vector{Float64}[], Vector{Float64}[], Matrix{Float64}[], String[]
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, y_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, y_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(y_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (dim1, dim2), sel_vals)
        
        safe_x = map(i -> i == dim1 ? (:) : (i == dim2 ? 1 : min(des_idx[i], size(x_tensor, i))), 1:ndims(x_tensor))
        safe_y = map(i -> i == dim2 ? (:) : (i == dim1 ? 1 : min(des_idx[i], size(y_tensor, i))), 1:ndims(y_tensor))
        safe_u = map(i -> i in (dim1, dim2) ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            u_mat = u_tensor[safe_u...]
            if !(u_mat isa AbstractMatrix)
                sz_x = x_tensor[safe_x...] isa AbstractVector ? length(x_tensor[safe_x...]) : 1
                sz_y = y_tensor[safe_y...] isa AbstractVector ? length(y_tensor[safe_y...]) : 1
                u_mat = reshape([u_mat...], sz_x, sz_y)
            end
            if dim1 > dim2; u_mat = transpose(u_mat) |> collect; end 
            
            x_val = x_tensor[safe_x...]
            y_val = y_tensor[safe_y...]
            
            push!(xs, x_val isa AbstractVector ? vec(x_val) : [Float64(x_val)])
            push!(ys, y_val isa AbstractVector ? vec(y_val) : [Float64(y_val)])
            push!(us, u_mat)
            push!(valid_labels, m_name)
        catch e; @warn "2D Slicing failed for $m_name" exception=e; end
    end
    
    title_str = generate_dynamic_title(dim1, dim_names, sel_vals)
    return (xs, ys, us), valid_labels, title_str
end

# --- 3D Data Extraction ---
function extract_data(data::Dict, manager::PlotManager, sel_vals, x_key, y_key, z_key, u_key, ::Val{3})
    dim_names = manager.plot_vars
    pd_first = first(values(data))
    
    dim1 = get_base_dim_idx(pd_first, x_key, dim_names)
    dim2 = get_base_dim_idx(pd_first, y_key, dim_names)
    dim3 = get_base_dim_idx(pd_first, z_key, dim_names)
    
    xs, ys, zs, us, valid_labels = Vector{Float64}[], Vector{Float64}[], Vector{Float64}[], Array{Float64, 3}[], String[]
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, y_tensor, z_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, y_key, nothing), get(pd.data, z_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(y_tensor) || isnothing(z_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (dim1, dim2, dim3), sel_vals)
        
        safe_x = map(i -> i == dim1 ? (:) : (i in (dim2, dim3) ? 1 : min(des_idx[i], size(x_tensor, i))), 1:ndims(x_tensor))
        safe_y = map(i -> i == dim2 ? (:) : (i in (dim1, dim3) ? 1 : min(des_idx[i], size(y_tensor, i))), 1:ndims(y_tensor))
        safe_z = map(i -> i == dim3 ? (:) : (i in (dim1, dim2) ? 1 : min(des_idx[i], size(z_tensor, i))), 1:ndims(z_tensor))
        safe_u = map(i -> i in (dim1, dim2, dim3) ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            u_mat = u_tensor[safe_u...]
            s_dims = sort([dim1, dim2, dim3])
            t_order = [findfirst(==(dim1), s_dims), findfirst(==(dim2), s_dims), findfirst(==(dim3), s_dims)]
            if t_order != [1, 2, 3] && ndims(u_mat) == 3; u_mat = permutedims(u_mat, t_order); end
            
            x_val = x_tensor[safe_x...]; y_val = y_tensor[safe_y...]; z_val = z_tensor[safe_z...]
            
            push!(xs, x_val isa AbstractVector ? vec(x_val) : [Float64(x_val)])
            push!(ys, y_val isa AbstractVector ? vec(y_val) : [Float64(y_val)])
            push!(zs, z_val isa AbstractVector ? vec(z_val) : [Float64(z_val)])
            push!(us, u_mat); push!(valid_labels, m_name)
        catch e; @warn "3D Slicing failed for $m_name" exception=e; end
    end
    
    title_str = generate_dynamic_title(dim1, dim_names, sel_vals)
    return (xs, ys, zs, us), valid_labels, title_str
end