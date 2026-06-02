# ==============================================================================
# DATA EXTRACTION PIPELINE (Dispatched by Val{D})
# ==============================================================================


"""
    find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real)

Maps a physical value from a slider back to the correct tensor index.
"""
function find_closest_index_for_dim(pd::UnifiedPlotData{N}, dim_idx::Int, target_val::Real) where N
    n_params = length(pd.active_param_keys)
    
    if dim_idx <= n_params 
        p_vals = pd.active_param_values[dim_idx]
        return findmin(v -> abs(v - target_val), p_vals)[2]
        
    elseif dim_idx == n_params + 1 
        return max(1, Int(target_val))
        
    elseif dim_idx > n_params + 1 && dim_idx <= n_params + 4 
        tensor_key = dim_idx == n_params + 2 ? "x" : (dim_idx == n_params + 3 ? "y" : "z")
        
        if haskey(pd.data, tensor_key)
            # --- THE FIX: Isolate the 1D axis natively to prevent vec() from flattening the grid! ---
            slice_idx = ntuple(i -> i == dim_idx ? (:) : 1, ndims(pd.data[tensor_key]))
            coord_vec = pd.data[tensor_key][slice_idx...]
            
            # Safely find the closest index while ignoring NaNs
            valid_pairs = filter(p -> isfinite(p[2]), collect(enumerate(coord_vec)))
            if isempty(valid_pairs)
                return 1
            end
            
            # Find the minimum difference, and extract the original index
            best_idx = findmin(p -> abs(p[2] - target_val), valid_pairs)[2]
            return valid_pairs[best_idx][1]
        end
        
    elseif dim_idx == n_params + 5 
        return findmin(v -> abs(v - target_val), pd.t_vals)[2]
    end
    
    return 1
end

function _get_desired_indices(pd::UnifiedPlotData, target_dims::Tuple, sel_vals)
    return map(1:length(sel_vals)) do i
        if i in target_dims; return (:); end
        raw_val = sel_vals[i]
        if isnothing(raw_val) || raw_val == "-" || raw_val == "disabled"
            return 1
        end
        val = raw_val isa String ? parse(Int, raw_val) : raw_val
        return find_closest_index_for_dim(pd, i, val)
    end
end

function get_base_dim_idx(pd::UnifiedPlotData, key::Union{String, Nothing}, dim_names::Vector{String})
    (isnothing(key) || key == "-" || key == "disabled") && return 1
    
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
    slice_dim_idx = get_base_dim_idx(pd_first, x_key, dim_names)
    xs, us, valid_labels = Vector{Float64}[], Vector{Float64}[], String[]
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (slice_dim_idx,), sel_vals)
        n_params = length(pd.active_param_keys)
        # Force orthogonal dimensions (dims > n_params) to index 1 to avoid NaN padding
        safe_x = map(i -> i == slice_dim_idx ? (:) : (des_idx[i] isa Colon ? 1 : (i > n_params ? 1 : min(des_idx[i], size(x_tensor, i)))), 1:ndims(x_tensor))
        safe_u = map(i -> des_idx[i] isa Colon ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            x_val = x_tensor[safe_x...]
            u_val = u_tensor[safe_u...]
            x_vec = x_val isa AbstractVector ? vec(x_val) : [Float64(x_val)]
            u_vec = u_val isa AbstractVector ? vec(u_val) : [Float64(u_val)]
            
            # THE FIX: Broadcast flat scalars into vectors (e.g. for plotting y vs x)
            len = max(length(x_vec), length(u_vec))
            if length(x_vec) == 1 && len > 1; x_vec = fill(x_vec[1], len); end
            if length(u_vec) == 1 && len > 1; u_vec = fill(u_vec[1], len); end
            
            valid_idx = .!(isnan.(x_vec)) .& .!(isnan.(u_vec))
            x_vec = x_vec[valid_idx]
            u_vec = u_vec[valid_idx]
            
            perm = sortperm(x_vec)
            push!(xs, x_vec[perm])
            push!(us, u_vec[perm])
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
        n_params = length(pd.active_param_keys)
        safe_x = map(i -> i == dim1 ? (:) : (des_idx[i] isa Colon ? 1 : (i > n_params ? 1 : min(des_idx[i], size(x_tensor, i)))), 1:ndims(x_tensor))
        safe_y = map(i -> i == dim2 ? (:) : (des_idx[i] isa Colon ? 1 : (i > n_params ? 1 : min(des_idx[i], size(y_tensor, i)))), 1:ndims(y_tensor))
        safe_u = map(i -> des_idx[i] isa Colon ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            x_val = x_tensor[safe_x...]; y_val = y_tensor[safe_y...]
            x_vec = x_val isa AbstractVector ? vec(x_val) : [Float64(x_val)]
            y_vec = y_val isa AbstractVector ? vec(y_val) : [Float64(y_val)]
            
            Nx, Ny = length(x_vec), length(y_vec)
            u_raw = u_tensor[safe_u...]
            
            # THE FIX: Robust 2D Broadcasting Matrix
            if length(u_raw) == 1
                u_mat = fill(Float64(u_raw[1]), Nx, Ny)
            elseif length(u_raw) == Nx && length(u_raw) == Ny && dim1 == dim2
                u_mat = repeat(vec(u_raw), 1, Ny)
            elseif length(u_raw) == Nx * Ny
                u_mat = reshape([u_raw...], Nx, Ny)
                if dim1 > dim2; u_mat = transpose(u_mat) |> collect; end 
            elseif length(u_raw) == Nx
                u_mat = repeat(vec(u_raw), 1, Ny)
            elseif length(u_raw) == Ny
                u_mat = repeat(reshape(vec(u_raw), 1, Ny), Nx, 1)
            else
                u_mat = fill(NaN, Nx, Ny)
            end
            
            push!(xs, x_vec); push!(ys, y_vec); push!(us, u_mat); push!(valid_labels, m_name)
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
        n_params = length(pd.active_param_keys)
        safe_x = map(i -> i == dim1 ? (:) : (des_idx[i] isa Colon ? 1 : (i > n_params ? 1 : min(des_idx[i], size(x_tensor, i)))), 1:ndims(x_tensor))
        safe_y = map(i -> i == dim2 ? (:) : (des_idx[i] isa Colon ? 1 : (i > n_params ? 1 : min(des_idx[i], size(y_tensor, i)))), 1:ndims(y_tensor))
        safe_z = map(i -> i == dim3 ? (:) : (des_idx[i] isa Colon ? 1 : (i > n_params ? 1 : min(des_idx[i], size(z_tensor, i)))), 1:ndims(z_tensor))
        safe_u = map(i -> des_idx[i] isa Colon ? (:) : min(des_idx[i], size(u_tensor, i)), 1:ndims(u_tensor))
        
        try
            x_val = x_tensor[safe_x...]; y_val = y_tensor[safe_y...]; z_val = z_tensor[safe_z...]
            x_vec = x_val isa AbstractVector ? vec(x_val) : [Float64(x_val)]
            y_vec = y_val isa AbstractVector ? vec(y_val) : [Float64(y_val)]
            z_vec = z_val isa AbstractVector ? vec(z_val) : [Float64(z_val)]
            
            Nx, Ny, Nz = length(x_vec), length(y_vec), length(z_vec)
            u_raw = u_tensor[safe_u...]
            
            if length(u_raw) == 1
                u_mat = fill(Float64(u_raw[1]), Nx, Ny, Nz)
            elseif length(u_raw) == Nx * Ny * Nz
                u_mat = reshape([u_raw...], Nx, Ny, Nz)
                s_dims = sort([dim1, dim2, dim3])
                t_order = [findfirst(==(dim1), s_dims), findfirst(==(dim2), s_dims), findfirst(==(dim3), s_dims)]
                if t_order != [1, 2, 3] && ndims(u_mat) == 3; u_mat = permutedims(u_mat, t_order); end
            else
                u_mat = fill(NaN, Nx, Ny, Nz)
            end
            
            push!(xs, x_vec); push!(ys, y_vec); push!(zs, z_vec)
            push!(us, u_mat); push!(valid_labels, m_name)
        catch e; @warn "3D Slicing failed for $m_name" exception=e; end
    end
    title_str = generate_dynamic_title(dim1, dim_names, sel_vals)
    return (xs, ys, zs, us), valid_labels, title_str
end