# ==============================================================================
# DATA EXTRACTION PIPELINE (Dispatched by Val{D})
# ==============================================================================

"""
    find_closest_index_for_dim(pd::EulerianPlotData, dim_idx::Int, target_val::Real)

Maps a physical value from a slider back to the correct tensor index.
"""
function find_closest_index_for_dim(pd::EulerianPlotData{N}, dim_idx::Int, target_val::Real) where N
    n_params = length(pd.active_param_keys)
    
    if dim_idx <= n_params 
        p_vals = pd.active_param_values[dim_idx]
        return findmin(v -> abs(v - target_val), p_vals)[2]
        
    elseif dim_idx >= n_params + 1 && dim_idx <= n_params + 3 
        # --- THE FIX: X, Y, Z are now exactly n_params + 1, 2, 3 ---
        tensor_key = dim_idx == n_params + 1 ? "x" : (dim_idx == n_params + 2 ? "y" : "z")
        
        if haskey(pd.data, tensor_key)
            slice_idx = ntuple(i -> i == dim_idx ? (:) : 1, ndims(pd.data[tensor_key]))
            coord_vec = pd.data[tensor_key][slice_idx...]
            
            valid_pairs = filter(p -> isfinite(p[2]), collect(enumerate(coord_vec)))
            if isempty(valid_pairs)
                return 1
            end
            
            best_idx = findmin(p -> abs(p[2] - target_val), valid_pairs)[2]
            return valid_pairs[best_idx][1]
        end
        
    elseif dim_idx == n_params + 4 
        # --- THE FIX: Time is now exactly n_params + 4 ---
        return findmin(v -> abs(v - target_val), pd.t_vals)[2]
    end
    
    return 1
end

function _get_desired_indices(pd::EulerianPlotData, target_dims::Tuple, sel_vals)
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

function get_base_dim_idx(pd::EulerianPlotData, key::Union{String, Nothing}, dim_names::Vector{String})
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

# ==============================================================================
# EULERIAN DATA EXTRACTION PIPELINE
# ==============================================================================

# --- 1D Data Extraction ---
function extract_eulerian_data(data::Dict, manager::PlotManager, sel_vals, target_c_str, x_key, y_key, z_key, u_key, ::Val{1})
    dim_names = manager.plot_vars
    pd_first = first(values(data))
    slice_dim_idx = get_base_dim_idx(pd_first, x_key, dim_names)
    xs, us, valid_labels = Vector{Float64}[], Vector{Float64}[], String[]
    
    target_c = target_c_str isa String ? parse(Int, target_c_str) : target_c_str
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (slice_dim_idx,), sel_vals)
        
        safe_x = map(i -> i == slice_dim_idx ? (:) : 1, 1:ndims(x_tensor))
        safe_u = map(i -> i == slice_dim_idx ? (:) : (des_idx[i] isa Colon ? 1 : min(des_idx[i], size(u_tensor, i))), 1:ndims(u_tensor))
        
        try
            x_vec = vec(x_tensor[safe_x...])
            u_raw = vec(u_tensor[safe_u...])
            
            # --- THE LATE SLICE ---
            u_flat = map(u_raw) do val
                if val isa Number
                    return Float64(val)
                elseif target_c <= length(val)
                    return Float64(val[target_c])
                else
                    return NaN
                end
            end
            
            valid_idx = .!(isnan.(x_vec)) .& .!(isnan.(u_flat))
            x_vec = x_vec[valid_idx]
            u_vec = u_flat[valid_idx]
            
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
function extract_eulerian_data(data::Dict, manager::PlotManager, sel_vals, target_c_str, x_key, y_key, z_key, u_key, ::Val{2})
    dim_names = manager.plot_vars
    pd_first = first(values(data))
    dim1 = get_base_dim_idx(pd_first, x_key, dim_names)
    dim2 = get_base_dim_idx(pd_first, y_key, dim_names)
    xs, ys, us, valid_labels = Vector{Float64}[], Vector{Float64}[], Matrix{Float64}[], String[]
    
    target_c = target_c_str isa String ? parse(Int, target_c_str) : target_c_str
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, y_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, y_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(y_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (dim1, dim2), sel_vals)
        
        safe_x = map(i -> i == dim1 ? (:) : 1, 1:ndims(x_tensor))
        safe_y = map(i -> i == dim2 ? (:) : 1, 1:ndims(y_tensor))
        
        safe_u = map(1:ndims(u_tensor)) do i
            if i == dim1 || i == dim2
                return (:)
            else
                idx = des_idx[i] isa Colon ? 1 : min(des_idx[i], size(u_tensor, i))
                return idx:idx 
            end
        end
        
        try
            x_vec = vec(x_tensor[safe_x...])
            y_vec = vec(y_tensor[safe_y...])
            Nx, Ny = length(x_vec), length(y_vec)
            
            u_raw = u_tensor[safe_u...] 
            
            # --- THE LATE SLICE ---
            u_flat = map(u_raw) do val
                if val isa Number
                    return Float64(val)
                elseif target_c <= length(val)
                    return Float64(val[target_c])
                else
                    return NaN
                end
            end
            
            if dim1 == dim2
                u_mat = repeat(vec(u_flat), 1, Ny)
            else
                other_dims = setdiff(1:ndims(u_tensor), [dim1, dim2])
                perm = [dim1, dim2, other_dims...]
                u_permuted = permutedims(u_flat, perm)
                u_mat = reshape(u_permuted, Nx, Ny)
            end
            
            push!(xs, x_vec); push!(ys, y_vec); push!(us, u_mat); push!(valid_labels, m_name)
        catch e; @warn "2D Slicing failed for $m_name" exception=e; end
    end
    title_str = generate_dynamic_title(dim1, dim_names, sel_vals)
    return (xs, ys, us), valid_labels, title_str
end

# --- 3D Data Extraction ---
function extract_eulerian_data(data::Dict, manager::PlotManager, sel_vals, target_c_str, x_key, y_key, z_key, u_key, ::Val{3})
    dim_names = manager.plot_vars
    pd_first = first(values(data))
    dim1 = get_base_dim_idx(pd_first, x_key, dim_names)
    dim2 = get_base_dim_idx(pd_first, y_key, dim_names)
    dim3 = get_base_dim_idx(pd_first, z_key, dim_names)
    xs, ys, zs, us, valid_labels = Vector{Float64}[], Vector{Float64}[], Vector{Float64}[], Array{Float64, 3}[], String[]
    
    target_c = target_c_str isa String ? parse(Int, target_c_str) : target_c_str
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        x_tensor, y_tensor, z_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, y_key, nothing), get(pd.data, z_key, nothing), get(pd.data, u_key, nothing)
        (isnothing(x_tensor) || isnothing(y_tensor) || isnothing(z_tensor) || isnothing(u_tensor)) && continue
        
        des_idx = _get_desired_indices(pd, (dim1, dim2, dim3), sel_vals)
        
        safe_x = map(i -> i == dim1 ? (:) : 1, 1:ndims(x_tensor))
        safe_y = map(i -> i == dim2 ? (:) : 1, 1:ndims(y_tensor))
        safe_z = map(i -> i == dim3 ? (:) : 1, 1:ndims(z_tensor))
        
        safe_u = map(1:ndims(u_tensor)) do i
            if i == dim1 || i == dim2 || i == dim3
                return (:)
            else
                idx = des_idx[i] isa Colon ? 1 : min(des_idx[i], size(u_tensor, i))
                return idx:idx
            end
        end
        
        try
            x_vec = vec(x_tensor[safe_x...])
            y_vec = vec(y_tensor[safe_y...])
            z_vec = vec(z_tensor[safe_z...])
            Nx, Ny, Nz = length(x_vec), length(y_vec), length(z_vec)
            
            u_raw = u_tensor[safe_u...]
            
            # --- THE LATE SLICE ---
            u_flat = map(u_raw) do val
                if val isa Number
                    return Float64(val)
                elseif target_c <= length(val)
                    return Float64(val[target_c])
                else
                    return NaN
                end
            end
            
            unique_dims = unique([dim1, dim2, dim3])
            if length(unique_dims) < 3
                u_mat = fill(NaN, Nx, Ny, Nz)
            else
                other_dims = setdiff(1:ndims(u_tensor), [dim1, dim2, dim3])
                perm = [dim1, dim2, dim3, other_dims...]
                u_permuted = permutedims(u_flat, perm)
                u_mat = reshape(u_permuted, Nx, Ny, Nz)
            end
            
            push!(xs, x_vec); push!(ys, y_vec); push!(zs, z_vec)
            push!(us, u_mat); push!(valid_labels, m_name)
        catch e; @warn "3D Slicing failed for $m_name" exception=e; end
    end
    title_str = generate_dynamic_title(dim1, dim_names, sel_vals)
    return (xs, ys, zs, us), valid_labels, title_str
end

# ==============================================================================
# LAGRANGIAN DATA EXTRACTION PIPELINE
# ==============================================================================

function extract_lagrangian_data(data::Dict, manager::PlotManager, sel_vals, target_c_str, u_key)
    dim_names = manager.plot_vars
    n_params = length(dim_names) - 4 # THE FIX: Explicitly updated to - 4
    time_idx = n_params + 4
    
    target_t = sel_vals[time_idx]
    target_c = target_c_str isa String ? parse(Int, target_c_str) : target_c_str
    
    pd_first = first(values(data))
    l_data_first = pd_first.data[1]
    D = length(l_data_first.xmins)
    
    pts_all = (D == 1) ? Vector{Float64}[] : Vector{Point{D, Float64}}[]
    us_all  = Vector{Float64}[]
    valid_labels = String[]
    
    for m_name in manager.methods[]
        !haskey(data, m_name) && continue
        pd = data[m_name]
        
        p_idx = map(1:n_params) do i
            p_vals = pd.active_param_values[i]
            isempty(p_vals) ? 1 : findmin(v -> abs(v - sel_vals[i]), p_vals)[2]
        end
        
        l_data = isempty(p_idx) ? pd.data[1] : pd.data[p_idx...]
        isnothing(l_data) && continue
        
        t_idx = findmin(v -> abs(v - target_t), l_data.t)[2]
        x_step = l_data.x[t_idx]
        
        u_step = nothing
        if u_key == "u" || u_key == "v" || u_key == "rho" || u_key == "p"
            u_step = l_data.u[t_idx]
        elseif haskey(l_data.fields, u_key)
            u_step = l_data.fields[u_key][t_idx]
        elseif haskey(l_data.profiles, u_key)
            u_step = l_data.profiles[u_key][1]
        elseif haskey(l_data.series, u_key) 
            u_step = [l_data.series[u_key][t_idx]] # Natively handle 1D time-series extracts too!
        end
        isnothing(u_step) && continue
        
        N_p = length(x_step)
        us = zeros(Float64, N_p)
        
        if D == 1
            pts = zeros(Float64, N_p)
            @inbounds for p in 1:N_p
                pts[p] = x_step[p][1]
                
                # --- THE LATE SLICE ---
                val = u_step[p]
                if val isa Number
                    us[p] = Float64(val)
                elseif target_c <= length(val)
                    us[p] = Float64(val[target_c])
                else
                    us[p] = NaN
                end
            end
            push!(pts_all, pts)
        else
            pts = Vector{Point{D, Float64}}(undef, N_p)
            @inbounds for p in 1:N_p
                pts[p] = Point{D, Float64}(x_step[p]...)
                
                # --- THE LATE SLICE ---
                val = u_step[p]
                if val isa Number
                    us[p] = Float64(val)
                elseif target_c <= length(val)
                    us[p] = Float64(val[target_c])
                else
                    us[p] = NaN
                end
            end
            push!(pts_all, pts)
        end
        
        push!(us_all, us)
        push!(valid_labels, m_name)
    end
    
    title_parts = String[]
    for i in 1:n_params
        val_str = sel_vals[i] isa AbstractFloat ? @sprintf("%.3f", sel_vals[i]) : string(sel_vals[i])
        push!(title_parts, "$(dim_names[i]) = $val_str")
    end
    push!(title_parts, "t = $(@sprintf("%.3f", target_t))")
    title_str = join(title_parts, " | ")
    
    return (pts_all, us_all), valid_labels, title_str
end