
function _get_lsim_bounds(x::Vector{Vector{SVector{DS, T}}}) where {DS, T}
    mins, maxs = fill(T(Inf), DS), fill(T(-Inf), DS)
    for step in x; for p in step; for d in 1:DS
        mins[d], maxs[d] = min(mins[d], p[d]), max(maxs[d], p[d])
    end; end; end
    return Tuple(mins), Tuple(maxs)
end

# ==============================================================================
# --- EULERIAN CONSTRUCTORS (Spacetime Tensors) ---
# ==============================================================================

# 1D Space + 1D Time = 2D Spacetime Tensor
function create_sim_data(
    x::AbstractVector{<:Real}, u::AbstractMatrix{SVector{M, T}}, t::AbstractVector{<:Real}, params::ParamDict; 
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing, time_dim::Union{Nothing,Symbol}=:t, x_dim::Symbol=:x
) where {M, T<:Real}
    DS, D = 1, 2
    
    _mins = SVector{D, T}(
        isnothing(xmins) ? T(minimum(x)) : T(xmins[1]), 
        isnothing(tmin) ? T(minimum(t)) : T(tmin)
    )
    _maxs = SVector{D, T}(
        isnothing(xmaxs) ? T(maximum(x)) : T(xmaxs[1]), 
        isnothing(tmax) ? T(maximum(t)) : T(tmax)
    )
    
    axes = (Vector{T}(x), Vector{T}(t))
    spacing = SVector{D, T}(
        length(x) > 1 ? (_maxs[1] - _mins[1]) / T(length(x) - 1) : one(T),
        length(t) > 1 ? (_maxs[2] - _mins[2]) / T(length(t) - 1) : one(T)
    )
    
    registry = deepcopy(STAT_REGISTRY)
    registry[:Solution] = :all
    
    dim_keys = (x_dim, time_dim)
    domain = DomainInfo{D, T}(dim_keys, _mins, _maxs, spacing, time_dim, registry)

    u_typed = u isa AbstractMatrix{SVector{M, T}} ? u : [SVector{M, T}(v) for v in u]
    stats_dict = StatDict{M, T}(:Solution => u_typed)

    return ESimData{D, DS, M, T}(params, domain, axes, u_typed, stats_dict)
end

# 2D Space + 1D Time = 3D Spacetime Tensor
function create_sim_data(
    x_grid::AbstractMatrix{<:Real}, y_grid::AbstractMatrix{<:Real}, u::AbstractArray{SVector{M, T}, 3}, t::AbstractVector{<:Real}, params::ParamDict; 
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing, time_dim::Union{Nothing,Symbol}=:t, x_dim::Symbol=:x,y_dim::Symbol=:y
) where {M, T<:Real}
    DS, D = 2, 3
    
    x_axis, y_axis = vec(x_grid[:, 1]), vec(y_grid[1, :])
    
    _mins = SVector{D, T}(
        isnothing(xmins) ? T(minimum(x_axis)) : T(xmins[1]), 
        isnothing(xmins) ? T(minimum(y_axis)) : T(xmins[2]), 
        isnothing(tmin) ? T(minimum(t)) : T(tmin)
    )
    _maxs = SVector{D, T}(
        isnothing(xmaxs) ? T(maximum(x_axis)) : T(xmaxs[1]), 
        isnothing(xmaxs) ? T(maximum(y_axis)) : T(xmaxs[2]), 
        isnothing(tmax) ? T(maximum(t)) : T(tmax)
    )
    
    axes = (Vector{T}(x_axis), Vector{T}(y_axis), Vector{T}(t))
    spacing = SVector{D, T}(
        length(x_axis) > 1 ? (_maxs[1] - _mins[1]) / T(length(x_axis) - 1) : one(T),
        length(y_axis) > 1 ? (_maxs[2] - _mins[2]) / T(length(y_axis) - 1) : one(T),
        length(t) > 1 ? (_maxs[3] - _mins[3]) / T(length(t) - 1) : one(T)
    )
    
    registry = deepcopy(STAT_REGISTRY)
    registry[:Solution] = :all
    
    dim_keys = (x_dim, y_dim, time_dim)
    domain = DomainInfo{D, T}(dim_keys, _mins, _maxs, spacing, time_dim, registry)

    u_typed = u isa AbstractArray{SVector{M, T}, 3} ? u : [SVector{M, T}(v) for v in u]
    stats_dict = StatDict{M, T}(:Solution => u_typed)

    return ESimData{D, DS, M, T}(params, domain, axes, u_typed, stats_dict)
end

# ==============================================================================
# --- LAGRANGIAN CONSTRUCTORS ---
# ==============================================================================

function create_sim_data(
    x::Vector{Vector{SVector{DS, T}}}, u::Vector{Vector{SVector{M, T}}}, t::Vector{T}, params::ParamDict;
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing, time_dim::Union{Nothing,Symbol}=:t
) where {DS, M, T<:Real}
    D = DS + 1 
    
    auto_mins, auto_maxs = _get_lsim_bounds(x) # Ensure _get_lsim_bounds uses T
    _xmins = isnothing(xmins) ? auto_mins : Tuple(T.(xmins))
    _xmaxs = isnothing(xmaxs) ? auto_maxs : Tuple(T.(xmaxs))
    _tmin  = isnothing(tmin)  ? T(minimum(t)) : T(tmin)
    _tmax  = isnothing(tmax)  ? T(maximum(t)) : T(tmax)
    
    N_p = max(1, maximum(length.(x)))
    avg_dx = T((prod(_xmaxs .- _xmins) / N_p)^(1/DS))
    dt = length(t) > 1 ? (_tmax - _tmin) / T(length(t) - 1) : one(T)
    
    dim_keys = ((:x, :y, :z)[1:DS]..., time_dim)
    
    mins = SVector{D, T}(_xmins..., _tmin)
    maxs = SVector{D, T}(_xmaxs..., _tmax)
    spacing = SVector{D, T}(ntuple(d -> avg_dx, Val(DS))..., dt)
    
    registry = deepcopy(STAT_REGISTRY)
    registry[:Solution] = :all
    domain = DomainInfo{D, T}(dim_keys, mins, maxs, spacing, time_dim, registry)
    stats_dict = StatDict{M, T}(:Solution => u)

    return LSimData{D, DS, M, T}(params, domain, t, x, u, stats_dict)
end


get_time_dim(domain::DomainInfo) = findfirst(==(domain.time_dim), domain.dim_keys)

# ==============================================================================
# --- CONVERSIONS ---
# ==============================================================================
# --- ALGORITHM: DYNAMIC SCATTER ---
function interpolate_to_grid!(
    ::Val{:scatter},
    u_euler, w_euler, e_fields,
    ldata::LSimData{D, DS, M, T}, 
    field_keys, field_vals, field_nan_vals, nan_vec,
    s_mins, s_maxs, s_dx, s_inv_dx, grid_shape
) where {D, DS, M, T}
    T_len = length(ldata.t)
    
    # --- Pre-calculate smoothing metrics ---
    N_p_initial = max(1, length(ldata.x[1]))
    pts_per_dim = max(1.0, N_p_initial^(1 / DS) - 1.0)
    particle_spacings = SVector{DS, T}([(s_maxs[d] - s_mins[d]) / pts_per_dim for d in 1:DS])
    effective_spacing = max.(s_dx, particle_spacings)
    radius = (norm(effective_spacing) * 1.5)^2
    radius_1d = sqrt(radius) 

    # =========================================================================
    # TIME BATCH LOOP (Dynamic Scatter Algorithm)
    # =========================================================================
    @batch for t_idx in 1:T_len
        x_step = ldata.x[t_idx]
        u_step = ldata.u[t_idx]
        N_p = length(x_step)
        
        # Pass 1: Scatter particles and fields to local grid cells
        @inbounds for p_idx in 1:N_p
            pos = x_step[p_idx]
            
            idx_float = (pos .- s_mins) .* s_inv_dx .+ 1.0
            rad_idx = radius_1d .* s_inv_dx
            
            min_idx = @. max(1, floor(Int, idx_float - rad_idx))
            max_idx = @. min(grid_shape..., ceil(Int, idx_float + rad_idx))
            
            for cell_idx in CartesianIndices(ntuple(d -> min_idx[d]:max_idx[d], Val(DS)))
                s_idx = SVector{DS, T}(Tuple(cell_idx))
                cell_pos = s_mins + s_dx .* (s_idx .- 1.0)
                
                dist2 = sum(abs2, cell_pos - pos)
                if dist2 <= radius
                    w = 1.0 / max(dist2, 1e-12) 
                    
                    if D > DS
                        w_euler[cell_idx, t_idx] += w
                        u_euler[cell_idx, t_idx] += u_step[p_idx] * w
                        for i in 1:length(field_keys)
                            e_fields[field_keys[i]][cell_idx, t_idx] += field_vals[i][t_idx][p_idx] * w
                        end
                    else
                        w_euler[cell_idx] += w
                        u_euler[cell_idx] += u_step[p_idx] * w
                        for i in 1:length(field_keys)
                            e_fields[field_keys[i]][cell_idx] += field_vals[i][p_idx] * w
                        end
                    end
                end
            end
        end
        
        # Pass 2: Finalize averages for this time step
        @inbounds for cell_idx in CartesianIndices(grid_shape)
            if D > DS
                w_sum = w_euler[cell_idx, t_idx]
                if w_sum > 0.0
                    u_euler[cell_idx, t_idx] /= w_sum
                    for i in 1:length(field_keys)
                        e_fields[field_keys[i]][cell_idx, t_idx] /= w_sum
                    end
                else
                    u_euler[cell_idx, t_idx] = nan_vec
                    for i in 1:length(field_keys)
                        e_fields[field_keys[i]][cell_idx, t_idx] = field_nan_vals[i]
                    end
                end
            else
                w_sum = w_euler[cell_idx]
                if w_sum > 0.0
                    u_euler[cell_idx] /= w_sum
                    for i in 1:length(field_keys)
                        e_fields[field_keys[i]][cell_idx] /= w_sum
                    end
                else
                    u_euler[cell_idx] = nan_vec
                    for i in 1:length(field_keys)
                        e_fields[field_keys[i]][cell_idx] = field_nan_vals[i]
                    end
                end
            end
        end
    end
end


"""
    resample_eulerian(data::ESimData, res::NTuple{D, Int})

Resamples the full Eulerian spacetime tensor and all dimensionally-dependent 
statistics to a new resolution using multi-dimensional linear interpolation.
"""
function resample_eulerian(data::ESimData{D, DS, M, T}, res::NTuple{D, Int}) where {D, DS, M, T}
    # 1. Fast exit if resolutions already match perfectly
    if size(data.u) == res
        return data
    end
    
    @info "Linearly interpolating Eulerian data from $(size(data.u)) to $res..."
    
    # 2. Build the new coordinate axes
    new_axes = ntuple(D) do d
        collect(range(data.domain.mins[d], data.domain.maxs[d], length=res[d]))
    end
    
    # 3. Create interpolation object for the main tensor
    # Flat extrapolation prevents bounds errors if float precision causes slight overshoots
    itp = linear_interpolation(data.axes, data.u, extrapolation_bc=Flat())
    
    # Evaluate the interpolation across the entire new grid
    # Iterators.product creates the multi-dimensional cartesian grid perfectly
    new_u = [itp(pt...) for pt in Iterators.product(new_axes...)]
    
    # 4. Dynamically resample statistics
    new_stats = StatDict{M, T}()
    for (k, v) in data.stats
        if !(v isa AbstractArray) || isempty(v)
            new_stats[k] = copy(v)
            continue
        end
        
        # Determine which dimensions this specific stat cares about
        kept_dims = get_kept_dims(k, data.domain)
        if isempty(kept_dims)
            new_stats[k] = copy(v)
            continue
        end
        
        kept_indices = get_kept_indices(k, data.domain)
        stat_res = ntuple(i -> res[kept_indices[i]], length(kept_indices))
        
        if size(v) == stat_res
            new_stats[k] = copy(v)
            continue
        end
        
        # Interpolate the stat across its specific sub-dimensions
        stat_axes = ntuple(i -> data.axes[kept_indices[i]], length(kept_indices))
        stat_new_axes = ntuple(i -> new_axes[kept_indices[i]], length(kept_indices))
        
        stat_itp = linear_interpolation(stat_axes, v, extrapolation_bc=Flat())
        new_stats[k] = [stat_itp(pt...) for pt in Iterators.product(stat_new_axes...)]
    end
    
    # 5. Build updated spacing and DomainInfo
    new_spacing = SVector{D, T}(
        ntuple(d -> res[d] > 1 ? (data.domain.maxs[d] - data.domain.mins[d]) / T(res[d] - 1) : one(T), D)
    )
    
    new_domain = DomainInfo{D, T}(
        data.domain.dim_keys, data.domain.mins, data.domain.maxs, new_spacing, 
        data.domain.time_dim, data.domain.stat_registry
    )
    
    return ESimData{D, DS, M, T}(data.params, new_domain, new_axes, new_u, new_stats)
end

# ==============================================================================
# --- CONVERSIONS ---
# ==============================================================================

function convert_to_eulerian(
    ldata::LSimData{D, DS, M, T}, 
    res::NTuple{D, Int}; 
    spatial_interp::Symbol=:scatter
) where {D, DS, M, T}
    mins, maxs = ldata.domain.mins, ldata.domain.maxs
    time_dim = ldata.domain.time_dim
    t_dim_idx = get_time_dim(ldata.domain)
    T_len = length(ldata.t)
    
    # 1. Extract spatial resolutions from the unified spacetime res tuple
    spatial_res = isnothing(t_dim_idx) ? res : ntuple(d -> res[d < t_dim_idx ? d : d+1], Val(DS))
    
    grid_axes = ntuple(d -> collect(range(mins[d], maxs[d], length=spatial_res[d])), Val(DS))
    grid_shape = spatial_res
    
    s_mins = SVector{DS, T}(mins[1:DS])
    s_maxs = SVector{DS, T}(maxs[1:DS])
    s_dx = (s_maxs - s_mins) ./ max.(1, spatial_res .- 1)
    s_inv_dx = 1.0 ./ s_dx
    
    # 2. Target Eulerian Spacetime Shape (Uses native T_len for the initial scatter pass)
    e_shape = ntuple(d -> d <= DS ? spatial_res[d] : T_len, Val(D))
    e_axes = ntuple(d -> d <= DS ? grid_axes[d] : ldata.t, Val(D))
    e_dim_keys = D > DS ? (ldata.domain.dim_keys[1:DS]..., time_dim) : ldata.domain.dim_keys
    e_spacing = SVector{D, T}(ntuple(d -> d <= DS ? s_dx[d] : ldata.domain.spacing[d], Val(D)))
    e_domain = DomainInfo{D, T}(e_dim_keys, mins, maxs, e_spacing, time_dim, ldata.domain.stat_registry)

    # 3. Preallocate Main Tensors
    zero_vec = zero(SVector{M, T})
    nan_vec = zero_vec .* NaN
    
    u_euler = fill(zero_vec, e_shape...)
    w_euler = zeros(T, e_shape...)
    
    # =========================================================================
    # --- STATS ROUTING & PREALLOCATION ---
    # =========================================================================
    e_stats = StatDict{M, T}()
    field_keys = Symbol[]
    field_nan_vals = Any[]
    e_fields = Dict{Symbol, Array}()
    
    for (k, v) in ldata.stats
        kept_dims = get_kept_dims(k, ldata.domain)
        
        # If it's a Series (keeps only :t, or is static with no dims) -> Pass through!
        if kept_dims == [time_dim] || isempty(kept_dims)
            e_stats[k] = copy(v)
            
        # Otherwise, it must be a Field -> Prepare to scatter!
        else
            push!(field_keys, k)
            
            # Extract the correct element type
            T_val = D > DS ? eltype(eltype(v)) : eltype(v)
            f_zero = zero(T_val)
            f_nan = f_zero .* NaN
            
            push!(field_nan_vals, f_nan)
            e_fields[k] = fill(f_zero, e_shape...)
        end
    end
    
    field_vals = [ldata.stats[k] for k in field_keys]

    # 4. Delegate spatial mesh generation to the modular interpolator
    interpolate_to_grid!(
        Val(spatial_interp), u_euler, w_euler, e_fields, ldata, 
        field_keys, field_vals, field_nan_vals, nan_vec, 
        s_mins, s_maxs, s_dx, s_inv_dx, grid_shape
    )

    # 5. Merge scattered fields back into the main stats dictionary
    for k in field_keys
        e_stats[k] = e_fields[k]
    end

    edata = ESimData{D, DS, M, T}(ldata.params, e_domain, e_axes, u_euler, e_stats)
    
    # 6. Apply temporal resampling ONLY if the requested time resolution differs from the native frames
    needs_time_resampling = D > DS && T_len != res[t_dim_idx]
    return needs_time_resampling ? resample_eulerian(edata, res) : edata
end

function convert_to_lagrangian(data::ESimData{D, DS, M, T}) where {D, DS, M, T}
    t_dim = get_time_dim(data.domain)
    is_static = isnothing(t_dim)
    
    T_len = is_static ? 1 : length(data.axes[t_dim])
    t_vec = is_static ? T[0.0] : data.axes[t_dim]
    
    # Get all indices EXCEPT the time dimension to build the spatial grid
    grid_shape = filter(d -> d != t_dim, 1:D)
    
    # 1. Flatten the spatial meshgrid into 1D particle arrays
    pts = vec([SVector{DS, T}(ntuple(dim -> data.axes[dim][idx[dim]], Val(DS))) 
               for idx in CartesianIndices(grid_shape)])
    
    new_x = [copy(pts) for _ in 1:T_len]
    new_u = Vector{Vector{SVector{M, T}}}(undef, T_len)
    
    # 2. Reshape Tensor slices dynamically
    for t in 1:T_len
        # Slice exactly along the time axis, wherever it is!
        slice = is_static ? data.u : selectdim(data.u, t_dim, t)
        new_u[t] = vec(slice)
    end
    
    # Because DomainInfo inherently describes the total tensor D, we can reuse it!
    return LSimData{D, DS, M, T}(
        data.params, data.domain, t_vec, new_x, new_u, 
        StatDict{M, T}()
    )
end