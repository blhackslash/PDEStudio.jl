# ==============================================================================
# DATA EXTRACTION PIPELINE (Dispatched by Val{D})
# ==============================================================================

# Generic Slicing Helper
function _get_desired_indices(pd::UnifiedPlotData, target_dims::Tuple, sel_vals)
    return map(1:length(sel_vals)) do i
        if i in target_dims; return (:); end
        val = sel_vals[i] isa String ? parse(Int, sel_vals[i]) : sel_vals[i]
        return find_closest_index_for_dim(pd, i, val)
    end
end

# --- 1D Data Extraction ---
function extract_data(data::Dict, manager::PlotManager, sel_vals, x_key, y_key, z_key, u_key, ::Val{1})
    dim_names = manager.plot_vars
    x_dim_idx = findfirst(isequal(x_key), dim_names)
    
    xs, us, valid_labels = Vector{Float64}[], Vector{Float64}[], String[]
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (x_dim_idx,), sel_vals)
        
        safe_x = map(i -> des_idx[i] isa Colon ? (:) : min(des_idx[i], size(x_tensor, i)), 1:ndims(x_tensor))
        safe_u = map(i -> des_idx[i] isa Colon ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            push!(xs, vec(x_tensor[safe_x...]))
            push!(us, vec(u_tensor[safe_u...]))
            push!(valid_labels, m_name)
        catch e; @warn "1D Slicing failed for $m_name" exception=e; end
    end
    
    title_str = generate_dynamic_title(x_dim_idx, dim_names, sel_vals)
    return (xs, us), valid_labels, title_str
end

# --- 2D Data Extraction ---
function extract_data(data::Dict, manager::PlotManager, sel_vals, x_key, y_key, z_key, u_key, ::Val{2})
    dim_names = manager.plot_vars
    x_dim_idx, y_dim_idx = findfirst(==(x_key), dim_names), findfirst(==(y_key), dim_names)
    
    xs, ys, us, valid_labels = Vector{Float64}[], Vector{Float64}[], Matrix{Float64}[], String[]
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, y_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, y_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(y_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (x_dim_idx, y_dim_idx), sel_vals)
        
        safe_x = map(i -> (i == x_dim_idx) ? (:) : ((i == y_dim_idx) ? 1 : min(des_idx[i], size(x_tensor, i))), 1:ndims(x_tensor))
        safe_y = map(i -> (i == y_dim_idx) ? (:) : ((i == x_dim_idx) ? 1 : min(des_idx[i], size(y_tensor, i))), 1:ndims(y_tensor))
        safe_u = map(i -> des_idx[i] isa Colon ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            u_mat = u_tensor[safe_u...]
            if x_dim_idx > y_dim_idx; u_mat = transpose(u_mat) |> collect; end 
            
            push!(xs, vec(x_tensor[safe_x...]))
            push!(ys, vec(y_tensor[safe_y...]))
            push!(us, u_mat)
            push!(valid_labels, m_name)
        catch e; @warn "2D Slicing failed for $m_name" exception=e; end
    end
    
    title_str = generate_dynamic_title(x_dim_idx, dim_names, sel_vals)
    return (xs, ys, us), valid_labels, title_str
end

# --- 3D Data Extraction ---
function extract_data(data::Dict, manager::PlotManager, sel_vals, x_key, y_key, z_key, u_key, ::Val{3})
    dim_names = manager.plot_vars
    x_dim_idx, y_dim_idx, z_dim_idx = findfirst(==(x_key), dim_names), findfirst(==(y_key), dim_names), findfirst(==(z_key), dim_names)
    
    xs, ys, zs, us, valid_labels = Vector{Float64}[], Vector{Float64}[], Vector{Float64}[], Array{Float64, 3}[], String[]
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, y_tensor, z_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, y_key, nothing), get(pd.data, z_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(y_tensor) || isnothing(z_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (x_dim_idx, y_dim_idx, z_dim_idx), sel_vals)
        
        safe_x = map(i -> (i == x_dim_idx) ? (:) : ((i == y_dim_idx || i == z_dim_idx) ? 1 : min(des_idx[i], size(x_tensor, i))), 1:ndims(x_tensor))
        safe_y = map(i -> (i == y_dim_idx) ? (:) : ((i == x_dim_idx || i == z_dim_idx) ? 1 : min(des_idx[i], size(y_tensor, i))), 1:ndims(y_tensor))
        safe_z = map(i -> (i == z_dim_idx) ? (:) : ((i == x_dim_idx || i == y_dim_idx) ? 1 : min(des_idx[i], size(z_tensor, i))), 1:ndims(z_tensor))
        safe_u = map(i -> des_idx[i] isa Colon ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            u_mat = u_tensor[safe_u...]
            s_dims = sort([x_dim_idx, y_dim_idx, z_dim_idx])
            t_order = [findfirst(==(x_dim_idx), s_dims), findfirst(==(y_dim_idx), s_dims), findfirst(==(z_dim_idx), s_dims)]
            if t_order != [1, 2, 3]; u_mat = permutedims(u_mat, t_order); end
            
            push!(xs, vec(x_tensor[safe_x...])); push!(ys, vec(y_tensor[safe_y...])); push!(zs, vec(z_tensor[safe_z...]))
            push!(us, u_mat); push!(valid_labels, m_name)
        catch e; @warn "3D Slicing failed for $m_name" exception=e; end
    end
    
    title_str = generate_dynamic_title(x_dim_idx, dim_names, sel_vals)
    return (xs, ys, zs, us), valid_labels, title_str
end