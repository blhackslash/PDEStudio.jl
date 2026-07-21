
function _get_lsim_bounds(x::Vector{Vector{SVector{DS, Float64}}}) where DS
    mins, maxs = fill(Inf, DS), fill(-Inf, DS)
    for step in x; for p in step; for d in 1:DS
        mins[d], maxs[d] = min(mins[d], p[d]), max(maxs[d], p[d])
    end; end; end
    return Tuple(mins), Tuple(maxs)
end
# ==============================================================================
# --- EULERIAN CONSTRUCTORS (Spacetime Tensors) ---
# ==============================================================================

# 1D Space + 1D Time = 2D Spacetime Tensor
function createSimData(
    x::AbstractVector{<:Real}, u::AbstractMatrix{SVector{M, T}}, t::AbstractVector{<:Real}, params::ParamDict; 
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing, time_dim::Union{Nothing,Symbol}=:t
) where {M, T<:Real}
    DS, D = 1, 2
    
    _mins = (isnothing(xmins) ? Float64(minimum(x)) : Float64(xmins[1]), isnothing(tmin) ? Float64(minimum(t)) : Float64(tmin))
    _maxs = (isnothing(xmaxs) ? Float64(maximum(x)) : Float64(xmaxs[1]), isnothing(tmax) ? Float64(maximum(t)) : Float64(tmax))
    
    axes = (Float64.(x), Float64.(t))
    spacing = (
        length(x) > 1 ? (_maxs[1] - _mins[1]) / (length(x) - 1) : 1.0,
        length(t) > 1 ? (_maxs[2] - _mins[2]) / (length(t) - 1) : 1.0
    )
    
    registry = deepcopy(STAT_REGISTRY)
    registry[:Solution] = :all
    
    # Define keys and construct domain with time_dim
    dim_keys = (:x, time_dim)
    domain = DomainInfo{D}(dim_keys, _mins, _maxs, spacing, time_dim, registry)

    u_float = u isa AbstractMatrix{SVector{M, Float64}} ? u : [SVector{M, Float64}(v) for v in u]
    stats_dict = StatDict{M}(:Solution => u_float)

    return ESimData{D, DS, M}(params, domain, axes, u_float, stats_dict)
end

# 2D Space + 1D Time = 3D Spacetime Tensor
function createSimData(
    x_grid::AbstractMatrix{<:Real}, y_grid::AbstractMatrix{<:Real}, u::AbstractArray{SVector{M, T}, 3}, t::AbstractVector{<:Real}, params::ParamDict; 
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing, time_dim::Union{Nothing,Symbol}=:t
) where {M, T<:Real}
    DS, D = 2, 3
    
    x_axis, y_axis = vec(x_grid[:, 1]), vec(y_grid[1, :])
    
    _mins = (isnothing(xmins) ? Float64(minimum(x_axis)) : Float64(xmins[1]), isnothing(xmins) ? Float64(minimum(y_axis)) : Float64(xmins[2]), isnothing(tmin) ? Float64(minimum(t)) : Float64(tmin))
    _maxs = (isnothing(xmaxs) ? Float64(maximum(x_axis)) : Float64(xmaxs[1]), isnothing(xmaxs) ? Float64(maximum(y_axis)) : Float64(xmaxs[2]), isnothing(tmax) ? Float64(maximum(t)) : Float64(tmax))
    
    axes = (Float64.(x_axis), Float64.(y_axis), Float64.(t))
    spacing = (
        length(x_axis) > 1 ? (_maxs[1] - _mins[1]) / (length(x_axis) - 1) : 1.0,
        length(y_axis) > 1 ? (_maxs[2] - _mins[2]) / (length(y_axis) - 1) : 1.0,
        length(t) > 1 ? (_maxs[3] - _mins[3]) / (length(t) - 1) : 1.0
    )
    
    registry = deepcopy(STAT_REGISTRY)
    registry[:Solution] = :all
    
    dim_keys = (:x, :y, time_dim)
    domain = DomainInfo{D}(dim_keys, _mins, _maxs, spacing, time_dim, registry)

    u_float = u isa AbstractArray{SVector{M, Float64}, 3} ? u : [SVector{M, Float64}(v) for v in u]
    stats_dict = StatDict{M}(:Solution => u_float)

    return ESimData{D, DS, M}(params, domain, axes, u_float, stats_dict)
end

# ==============================================================================
# --- LAGRANGIAN CONSTRUCTORS ---
# ==============================================================================

function createSimData(
    x::Vector{Vector{SVector{DS, Float64}}}, u::Vector{Vector{SVector{M, Float64}}}, t::Vector{Float64}, params::ParamDict;
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing, time_dim::Union{Nothing,Symbol}=:t
) where {DS, M}
    D = DS + 1 
    
    auto_mins, auto_maxs = _get_lsim_bounds(x)
    _xmins = isnothing(xmins) ? auto_mins : Float64.(Tuple(xmins))
    _xmaxs = isnothing(xmaxs) ? auto_maxs : Float64.(Tuple(xmaxs))
    _tmin  = isnothing(tmin)  ? Float64(minimum(t)) : Float64(tmin)
    _tmax  = isnothing(tmax)  ? Float64(maximum(t)) : Float64(tmax)
    
    N_p = max(1, maximum(length.(x)))
    avg_dx = (prod(_xmaxs .- _xmins) / N_p)^(1/DS)
    dt = length(t) > 1 ? (_tmax - _tmin) / (length(t) - 1) : 1.0
    
    dim_keys = ((:x, :y, :z)[1:DS]..., time_dim)
    mins = (_xmins..., _tmin)
    maxs = (_xmaxs..., _tmax)
    spacing = (ntuple(d -> avg_dx, Val(DS))..., dt)
    
    registry = deepcopy(STAT_REGISTRY)
    registry[:Solution] = :all
    domain = DomainInfo{D}(dim_keys, mins, maxs, spacing, time_dim, registry)
    stats_dict = StatDict{M}(:Solution => u)

    return LSimData{D, DS, M}(params, domain, t, x, u, stats_dict)
end
get_time_dim(domain::DomainInfo) = findfirst(==(domain.time_dim), domain.dim_keys)

# ==============================================================================
# --- CONVERSIONS ---
# ==============================================================================
function resample_time(data::ESimData{D, DS, M}, T_grid::Int) where {D, DS, M}
    t_dim = get_time_dim(data.domain)
    
    # 1. Static PDE check
    if isnothing(t_dim)
        @info "Static PDE detected (no $(data.domain.time_dim) in dim_keys). Skipping time resampling."
        return data
    end

    old_t = data.axes[t_dim]
    T_old = length(old_t)
    target_t = collect(range(data.domain.mins[t_dim], data.domain.maxs[t_dim], length=T_grid))
    
    # If the time vectors perfectly match the uniform grid, skip the overhead
    if T_old == T_grid && all(isapprox.(old_t, target_t, atol=1e-8))
        return data
    end
    
    @info "Nearest-Neighbor resampling Eulerian data from $T_old to $T_grid timesteps..."
    
    # 2. Allocate new main SVector tensor dynamically
    new_sz = collect(size(data.u))
    new_sz[t_dim] = T_grid
    new_u = similar(data.u, Tuple(new_sz))
    
    # 3. Dynamically adapt the unified stats dictionary using the Registry
    new_stats = StatDict{M}()
    for (k, v) in data.stats
        if !(v isa AbstractArray)
            new_stats[k] = copy(v)
            continue
        end
        
        # Query the registry for the dimensions kept by this specific stat
        kept_dims = get_kept_dims(k, data.domain)
        t_idx_in_stat = findfirst(==(data.domain.time_dim), kept_dims)
        
        if !isnothing(t_idx_in_stat)
            # This stat has a time dimension! Resample exactly that axis.
            stat_sz = collect(size(v))
            stat_sz[t_idx_in_stat] = T_grid
            new_stats[k] = similar(v, Tuple(stat_sz))
        else
            # Purely spatial stat (e.g., [:x, :y] or [:x]), pass it through
            new_stats[k] = copy(v)
        end
    end

    # 4. Helper to find the absolute closest native frame
    function get_nearest_idx(t)
        if t <= old_t[1]; return 1; end
        if t >= old_t[end]; return T_old; end
        
        idx = searchsortedlast(old_t, t)
        if idx == T_old; return T_old; end
        
        return abs(t - old_t[idx]) < abs(t - old_t[idx+1]) ? idx : idx+1
    end

    # 5. Fast Broadcast Snapping Loop
    Threads.@threads for i in 1:T_grid
        nearest = get_nearest_idx(target_t[i])
        
        # Resample the main Spacetime tensor safely
        selectdim(new_u, t_dim, i) .= selectdim(data.u, t_dim, nearest)
        
        # Resample time-dependent statistics
        for (k, v) in data.stats
            if !(v isa AbstractArray); continue; end
            
            kept_dims = get_kept_dims(k, data.domain)
            t_idx_in_stat = findfirst(==(data.domain.time_dim), kept_dims)
            
            if !isnothing(t_idx_in_stat)
                # target ONLY the axis that represents time within this specific array
                selectdim(new_stats[k], t_idx_in_stat, i) .= selectdim(v, t_idx_in_stat, nearest)
            end
        end
    end

    # 6. Build the updated DomainInfo and Axes
    new_spacing = collect(data.domain.spacing)
    new_spacing[t_dim] = length(target_t) > 1 ? (target_t[end] - target_t[1]) / (T_grid - 1) : 1.0
    
    new_axes = collect(data.axes)
    new_axes[t_dim] = target_t

    return ESimData{D, DS, M}(
        data.params, DomainInfo{D}(data.domain.dim_keys, data.domain.mins, data.domain.maxs, Tuple(new_spacing), data.domain.time_dim, data.domain.stat_registry), 
        Tuple(new_axes), new_u, new_stats
    )
end

function convert_to_eulerian(ldata::LSimData{D, DS, M}; N_grid=_N_GRID[], T_grid=_T_GRID[]) where {D, DS, M}
    mins, maxs = ldata.domain.mins, ldata.domain.maxs
    T_len = length(ldata.t)
    time_dim = ldata.domain.time_dim
    
    # 1. Build Spatial Grid config
    grid_axes = ntuple(d -> collect(range(mins[d], maxs[d], length=N_grid)), Val(DS))
    grid_shape = ntuple(d -> N_grid, Val(DS))
    
    s_mins = SVector{DS, Float64}(mins[1:DS])
    s_maxs = SVector{DS, Float64}(maxs[1:DS])
    s_dx = (s_maxs - s_mins) ./ max(1, N_grid - 1)
    s_inv_dx = 1.0 ./ s_dx
    
    # 2. Target Eulerian Spacetime Shape
    e_shape = ntuple(d -> d <= DS ? N_grid : T_len, Val(D))
    e_axes = ntuple(d -> d <= DS ? grid_axes[d] : ldata.t, Val(D))
    e_dim_keys = D > DS ? (ldata.domain.dim_keys[1:DS]..., time_dim) : ldata.domain.dim_keys
    e_spacing = ntuple(d -> d <= DS ? s_dx[d] : ldata.domain.spacing[d], Val(D))
    e_domain = DomainInfo{D}(e_dim_keys, mins, maxs, e_spacing, time_dim, ldata.domain.stat_registry)

    # 3. Preallocate Main Tensors
    zero_vec = zero(SVector{M, Float64})
    nan_vec = zero_vec .* NaN
    
    u_euler = fill(zero_vec, e_shape...)
    w_euler = zeros(Float64, e_shape...)
    
    # =========================================================================
    # --- STATS ROUTING & PREALLOCATION ---
    # =========================================================================
    e_stats = StatDict{M}()
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
            
            # Extract the correct element type (Transient is Vector{Vector{T}}, Static is Vector{T})
            T_val = D > DS ? eltype(eltype(v)) : eltype(v)
            f_zero = zero(T_val)
            f_nan = f_zero .* NaN
            
            push!(field_nan_vals, f_nan)
            e_fields[k] = fill(f_zero, e_shape...)
        end
    end
    
    # Fast-access arrays for the hot loop
    field_vals = [ldata.stats[k] for k in field_keys]

    # --- Pre-calculate smoothing metrics ---
    N_p_initial = max(1, length(ldata.x[1]))
    pts_per_dim = max(1.0, N_p_initial^(1 / DS) - 1.0)
    particle_spacings = [(maxs[d] - mins[d]) / pts_per_dim for d in 1:DS]
    effective_spacing = max.(collect(s_dx), particle_spacings)
    radius = (norm(effective_spacing) * 1.5)^2
    radius_1d = sqrt(radius) 

    # =========================================================================
    # 4. TIME BATCH LOOP (Dynamic Scatter Algorithm)
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
            max_idx = @. min(N_grid, ceil(Int, idx_float + rad_idx))
            
            for cell_idx in CartesianIndices(ntuple(d -> min_idx[d]:max_idx[d], Val(DS)))
                s_idx = SVector{DS, Float64}(Tuple(cell_idx))
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

    # Merge scattered fields back into the main stats dictionary
    for k in field_keys
        e_stats[k] = e_fields[k]
    end

    edata = ESimData{D, DS, M}(ldata.params, e_domain, e_axes, u_euler, e_stats)
    
    return D > DS ? resample_time(edata, T_grid) : edata
end

function convert_to_lagrangian(data::ESimData{D, DS, M}) where {D, DS, M}
    t_dim = get_time_dim(data.domain)
    is_static = isnothing(t_dim)
    
    T_len = is_static ? 1 : length(data.axes[t_dim])
    t_vec = is_static ? [0.0] : data.axes[t_dim]
    
    # Get all indices EXCEPT the time dimension to build the spatial grid
    grid_shape = filter(d -> d != t_dim, 1:D)
    
    # 1. Flatten the spatial meshgrid into 1D particle arrays
    pts = vec([SVector{DS, Float64}(ntuple(dim -> data.axes[dim][idx[dim]], Val(DS))) 
               for idx in CartesianIndices(grid_shape)])
    
    new_x = [copy(pts) for _ in 1:T_len]
    new_u = Vector{Vector{SVector{M, Float64}}}(undef, T_len)
    
    # 2. Reshape Tensor slices dynamically
    for t in 1:T_len
        # Slice exactly along the time axis, wherever it is!
        slice = is_static ? data.u : selectdim(data.u, t_dim, t)
        new_u[t] = vec(slice)
    end
    
    t_vec = D > DS ? data.axes[end] : [0.0]
    
    # Because DomainInfo inherently describes the total tensor D, we can reuse it!
    return LSimData{D, DS, M}(
        data.params, data.domain, t_vec, new_x, new_u, 
        StatDict{M}(),
    )
end

# ==============================================================================
# --- REFERENCE GENERATORS ---
# ==============================================================================

function generate_reference_simdata(ref_func::Function, params::ParamDict, template::ESimData{D, DS}) where {D, DS}
    # Dynamically apply _T_GRID to time axes, and _REF_GRID to spatial axes
    grid_shape = ntuple(d -> template.domain.dim_keys[d] == template.domain.time_dim ? _T_GRID[] : _REF_GRID[], Val(D))
    
    axes_list = ntuple(Val(D)) do d
        collect(range(template.domain.mins[d], template.domain.maxs[d], length=grid_shape[d]))
    end
    
    # 1. Evaluate one spacetime point to find the number of components (M)
    sample_st = SVector{D, Float64}(ntuple(d -> axes_list[d][1], Val(D)))
    M = length(ref_func(sample_st))
    
    # 2. Allocate the generalized Spacetime tensor
    u_exact = Array{SVector{M, Float64}, D}(undef, grid_shape...)
    
    # 3. Evaluate the exact function on the fly using multithreading
    Threads.@threads for idx in CartesianIndices(grid_shape)
        st = SVector{D, Float64}(ntuple(d -> axes_list[d][idx[d]], Val(D)))
        u_exact[idx] = SVector{M, Float64}(ref_func(st))
    end
    
    spacing = ntuple(d -> (template.domain.maxs[d] - template.domain.mins[d]) / max(1, grid_shape[d] - 1), Val(D))
    ref_domain = DomainInfo{D}(template.domain.dim_keys, template.domain.mins, template.domain.maxs, spacing, template.domain.time_dim, template.domain.stat_registry)
    
    ram_data = ESimData{D, DS, M}(params, ref_domain, axes_list, u_exact, StatDict{M}())
    
    return ram_data
end

function generate_reference_simdata(ref_func::Function, params::ParamDict, template::LSimData{D, DS}) where {D, DS}
    # Spatial axes
    s_shape = ntuple(d -> _REF_GRID[], Val(DS))
    s_axes = ntuple(d -> collect(range(template.domain.mins[d], template.domain.maxs[d], length=s_shape[d])), Val(DS))
    
    static_particles = vec([SVector{DS, Float64}(ntuple(d -> s_axes[d][idx[d]], Val(DS))) 
                            for idx in CartesianIndices(s_shape)])
    
    # Temporal constraints
    T_len = D > DS ? _T_GRID[] : 1
    t_vec = D > DS ? collect(range(template.domain.mins[end], template.domain.maxs[end], length=T_len)) : [0.0]
    
    x_ref = [copy(static_particles) for _ in 1:T_len]
    
    # 1. Pack a sample point to infer M
    sample_st = D > DS ? SVector{D, Float64}(static_particles[1]..., t_vec[1]) : SVector{D, Float64}(static_particles[1])
    M = length(ref_func(sample_st))
    
    u_ref = Vector{Vector{SVector{M, Float64}}}(undef, T_len)
    
    # 2. Evaluate using multithreading
    Threads.@threads for t_idx in 1:T_len
        t_val = t_vec[t_idx]
        if D > DS
            # Pack the DS-dimensional position and 1D time into a D Spacetime vector
            u_ref[t_idx] = [SVector{M, Float64}(ref_func(SVector{D, Float64}(pos..., t_val))) for pos in static_particles]
        else
            u_ref[t_idx] = [SVector{M, Float64}(ref_func(SVector{D, Float64}(pos))) for pos in static_particles]
        end
    end
    
    # Construct exact spacing metadata
    s_spacing = ntuple(d -> (template.domain.maxs[d] - template.domain.mins[d]) / max(1, s_shape[d] - 1), Val(DS))
    t_spacing = D > DS ? ((template.domain.maxs[end] - template.domain.mins[end]) / max(1, T_len - 1),) : ()
    spacing = (s_spacing..., t_spacing...)
    
    ref_domain = DomainInfo{D}(template.domain.dim_keys, template.domain.mins, template.domain.maxs, spacing, template.domain.time_dim, template.domain.stat_registry)
    
    return LSimData{D, DS, M}(params, ref_domain, t_vec, x_ref, u_ref, StatDict{M}())
end