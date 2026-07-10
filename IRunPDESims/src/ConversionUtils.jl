# ==============================================================================
# --- EULERIAN CONSTRUCTORS ---
# ==============================================================================

function createSimData(x::AbstractVector{<:Real}, u::AbstractMatrix{<:Real}, t::AbstractVector{<:Real}, params::ParamDict; xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing)
    u_expanded = reshape(u, 1, size(u, 1), size(u, 2))
    
    _xmins = isnothing(xmins) ? (Float64(minimum(x)),) : Float64.(Tuple(xmins))
    _xmaxs = isnothing(xmaxs) ? (Float64(maximum(x)),) : Float64.(Tuple(xmaxs))
    _tmin  = isnothing(tmin)  ? Float64(minimum(t)) : Float64(tmin)
    _tmax  = isnothing(tmax)  ? Float64(maximum(t)) : Float64(tmax)
    
    return ESimData{1}(params, (Float64.(x),), Float64.(u_expanded), Float64.(t), _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict(), Dict())
end

function createSimData(x::AbstractVector{<:Real}, u::AbstractArray{<:Real, 3}, t::AbstractVector{<:Real}, params::ParamDict; xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing)
    _xmins = isnothing(xmins) ? (Float64(minimum(x)),) : Float64.(Tuple(xmins))
    _xmaxs = isnothing(xmaxs) ? (Float64(maximum(x)),) : Float64.(Tuple(xmaxs))
    _tmin  = isnothing(tmin)  ? Float64(minimum(t)) : Float64(tmin)
    _tmax  = isnothing(tmax)  ? Float64(maximum(t)) : Float64(tmax)

    return ESimData{1}(params, (Float64.(x),), Float64.(u), Float64.(t), _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict(), Dict())
end

function createSimData(x_grid::AbstractMatrix{<:Real}, y_grid::AbstractMatrix{<:Real}, u::AbstractArray{<:Real, 3}, t::AbstractVector{<:Real}, params::ParamDict; xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing)
    x_axis = vec(x_grid[:, 1]) 
    y_axis = vec(y_grid[1, :]) 
    u_expanded = reshape(u, 1, size(u, 1), size(u, 2), size(u, 3))
    
    _xmins = isnothing(xmins) ? (Float64(minimum(x_axis)), Float64(minimum(y_axis))) : Float64.(Tuple(xmins))
    _xmaxs = isnothing(xmaxs) ? (Float64(maximum(x_axis)), Float64(maximum(y_axis))) : Float64.(Tuple(xmaxs))
    _tmin  = isnothing(tmin)  ? Float64(minimum(t)) : Float64(tmin)
    _tmax  = isnothing(tmax)  ? Float64(maximum(t)) : Float64(tmax)

    return ESimData{2}(params, (Float64.(x_axis), Float64.(y_axis)), Float64.(u_expanded), Float64.(t), _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict(), Dict())
end

# ==============================================================================
# --- LAGRANGIAN CONSTRUCTORS ---
# ==============================================================================

# Internal helper to calculate bounds of scattered SVector data
function _get_lsim_bounds(x::Vector{Vector{SVector{D, Float64}}}) where D
    mins = fill(Inf, D)
    maxs = fill(-Inf, D)
    for step in x; for p in step; for d in 1:D
        mins[d] = min(mins[d], p[d])
        maxs[d] = max(maxs[d], p[d])
    end; end; end
    return Tuple(mins), Tuple(maxs)
end

function createSimData(x::AbstractMatrix{<:Real}, u::AbstractMatrix{<:Real}, t::AbstractVector{<:Real}, params::ParamDict; xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing)
    n_p, n_t = size(x)
    x_vec = [[SVector{1, Float64}(x[p, m]) for p in 1:n_p] for m in 1:n_t]
    u_vec = [[SVector{1, Float64}(u[p, m]) for p in 1:n_p] for m in 1:n_t]
    
    auto_mins, auto_maxs = _get_lsim_bounds(x_vec)
    _xmins = isnothing(xmins) ? auto_mins : Float64.(Tuple(xmins))
    _xmaxs = isnothing(xmaxs) ? auto_maxs : Float64.(Tuple(xmaxs))
    _tmin  = isnothing(tmin)  ? Float64(minimum(t)) : Float64(tmin)
    _tmax  = isnothing(tmax)  ? Float64(maximum(t)) : Float64(tmax)
    
    return LSimData{1, 1}(params, x_vec, u_vec, Float64.(t), _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict(), Dict())
end

function createSimData(
    x::Vector{Vector{SVector{D, Float64}}}, 
    u::Vector{Vector{SVector{M, Float64}}}, 
    t::Vector{Float64}, 
    params::ParamDict;
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing
) where {D, M}
    auto_mins, auto_maxs = _get_lsim_bounds(x)
    _xmins = isnothing(xmins) ? auto_mins : Float64.(Tuple(xmins))
    _xmaxs = isnothing(xmaxs) ? auto_maxs : Float64.(Tuple(xmaxs))
    _tmin  = isnothing(tmin)  ? Float64(minimum(t)) : Float64(tmin)
    _tmax  = isnothing(tmax)  ? Float64(maximum(t)) : Float64(tmax)

    return LSimData{D, M}(params, x, u, t, _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict(), Dict())
end

function resample_time(data::ESimData{D}, T_grid::Int) where {D}
    target_t = collect(range(data.tmin, data.tmax, length=T_grid))
    
    # If the time vectors perfectly match the uniform grid, skip the overhead
    if length(data.t) == T_grid && all(isapprox.(data.t, target_t, atol=1e-8))
        return data
    end
    
    @info "Nearest-Neighbor resampling Eulerian data from $(length(data.t)) to $T_grid timesteps..."
    
    T_new = T_grid
    T_old = length(data.t)
    
    # 1. Allocate new tensors
    new_u = similar(data.u, size(data.u)[1:end-1]..., T_new)
    
    new_fields = Dict{String, Array{Float64}}()
    for (k, v) in data.fields; new_fields[k] = similar(v, size(v)[1:end-1]..., T_new); end
    
    new_series = Dict{String, Matrix{Float64}}()
    for (k, v) in data.series; new_series[k] = similar(v, size(v)[1:end-1]..., T_new); end

    # 2. Helper to find the absolute closest native frame
    function get_nearest_idx(t)
        if t <= data.t[1]; return 1; end
        if t >= data.t[end]; return T_old; end
        
        idx = searchsortedlast(data.t, t)
        if idx == T_old; return T_old; end
        
        # Return whichever frame is closer in time
        return abs(t - data.t[idx]) < abs(t - data.t[idx+1]) ? idx : idx+1
    end

    # 3. Fast Broadcast Snapping Loop (No w1/w2 blending!)
    Threads.@threads for i in 1:T_new
        nearest = get_nearest_idx(target_t[i])
        
        selectdim(new_u, ndims(new_u), i) .= selectdim(data.u, ndims(data.u), nearest)
        for (k, v) in data.fields; selectdim(new_fields[k], ndims(v), i) .= selectdim(v, ndims(v), nearest); end
        for (k, v) in data.series; selectdim(new_series[k], ndims(v), i) .= selectdim(v, ndims(v), nearest); end
    end

    return ESimData(
        data.params, data.x, new_u, target_t, 
        data.xmins, data.xmaxs, data.tmin, data.tmax,
        data.scalars, new_series, data.profiles, new_fields
    )
end

function convert_to_eulerian(ldata::LSimData{D, M}) where {D, M}
    # THE FIX: Pull directly from the global state
    N_grid = _N_GRID[]
    T_grid = _T_GRID[]
    T_len = length(ldata.t)

    mins = collect(ldata.xmins)
    maxs = collect(ldata.xmaxs)
    
    for d in 1:D
        pad = 0. 
        mins[d] -= pad; maxs[d] += pad
    end

    grid_axes = ntuple(d -> collect(range(mins[d], maxs[d], length=N_grid)), Val(D))
    grid_shape = ntuple(d -> N_grid, Val(D))
    x_euler = ntuple(d -> grid_axes[d], Val(D))

    # Preallocate Eulerian grids
    u_euler = zeros(Float64, M, grid_shape..., T_len)
    
    e_fields = Dict{String, Array{Float64}}()
    for (k, v) in ldata.fields
        e_fields[k] = zeros(Float64, M, grid_shape..., T_len) 
    end
    
    e_profiles = Dict{String, Array{Float64}}()
    for (k, v) in ldata.profiles
        e_profiles[k] = zeros(Float64, D, grid_shape...) 
    end

    cell_sizes = [(maxs[d] - mins[d]) / max(1, N_grid - 1) for d in 1:D]
    
    # --- THE FIX: Dynamic Particle-Aware Smoothing ---
    # 1. Estimate average particle spacing based on the initial state
    N_p_initial = max(1, length(ldata.x[1]))
    
    # N_p^(1/D) correctly estimates the 1D count along a single axis for 1D, 2D, and 3D!
    pts_per_dim = max(1.0, N_p_initial^(1 / D) - 1.0)
    particle_spacings = [(maxs[d] - mins[d]) / pts_per_dim for d in 1:D]
    
    # 2. Use the larger of the two spacings to ensure we bridge particle gaps
    effective_spacing = max.(cell_sizes, particle_spacings)
    
    # 3. Calculate squared radius for fast distance checking
    # 1.5x to 2.0x is usually the sweet spot to overlap the kernels
    radius = (norm(effective_spacing) * 1.5)^2

    # --- Precompute SVector bounds for algebraic pos calculation ---
    s_mins = SVector{D, Float64}(mins)
    s_maxs = SVector{D, Float64}(maxs)
    s_dx = (s_maxs - s_mins) / max(1, N_grid - 1)

    field_keys = collect(keys(ldata.fields))
    field_vals = collect(values(ldata.fields))

    profile_keys = collect(keys(ldata.profiles))
    profile_vals = collect(values(ldata.profiles))

    # =========================================================================
    # 1. SPATIAL BATCH LOOP (Dynamic, Time-Series Data)
    # =========================================================================
    @batch for idx in CartesianIndices(grid_shape)
        
        # Pure SVector algebraic position calculation (Zero allocations, No branching)
        s_idx = SVector{D, Float64}(Tuple(idx))
        pos = s_mins + s_dx .* (s_idx .- 1.0)
        
        @inbounds for t_idx in 1:T_len
            # Explicit type assertions
            x_step = ldata.x[t_idx]
            u_step = ldata.u[t_idx]
            
            N_p = length(x_step)
            
            if N_p == 0
                for c in 1:M; u_euler[c, idx, t_idx] = NaN; end
                for i in 1:length(field_keys)
                    for c in 1:M; e_fields[field_keys[i]][c, idx, t_idx] = NaN; end
                end
                continue
            end

            w_sum = 0.0
            # Instance-based zero allocation (No GC dispatch)
            u_sum = zero(u_step[1])
            
            # Zero out the target array positions for direct accumulation
            for i in 1:length(field_keys)
                for c in 1:M; e_fields[field_keys[i]][c, idx, t_idx] = 0.0; end
            end

            @inbounds for p_idx in 1:N_p
                # Squared distance calculation (No sqrt() overhead)
                dist = sum(abs2, pos - x_step[p_idx])
                
                if dist < 1e-10 
                    u_sum = u_step[p_idx]
                    for i in 1:length(field_vals)
                        for c in 1:M; e_fields[field_keys[i]][c, idx, t_idx] = field_vals[i][t_idx][p_idx][c]; end
                    end
                    w_sum = 1.0; break
                    
                elseif dist <= radius
                    # 1/r^4 falloff achieved by squaring the squared distance
                    w = 1.0 / (dist^2)
                    w_sum += w
                    u_sum += u_step[p_idx] * w
                    
                    # Accumulate DIRECTLY into the output array
                    for i in 1:length(field_vals)
                        for c in 1:M; e_fields[field_keys[i]][c, idx, t_idx] += field_vals[i][t_idx][p_idx][c] * w; end
                    end
                end
            end

            # Finalize averages
            if w_sum > 0.0
                u_avg = u_sum / w_sum
                for c in 1:M; u_euler[c, idx, t_idx] = u_avg[c]; end
                
                for i in 1:length(field_keys)
                    for c in 1:M; e_fields[field_keys[i]][c, idx, t_idx] /= w_sum; end
                end
            else
                for c in 1:M; u_euler[c, idx, t_idx] = NaN; end
                for i in 1:length(field_keys)
                    for c in 1:M; e_fields[field_keys[i]][c, idx, t_idx] = NaN; end
                end
            end
        end
    end

    # =========================================================================
    # 2. SPATIAL BATCH LOOP (Static Profile Data)
    # =========================================================================
    if !isempty(profile_keys)
        # Explicit type assertion for the static positions
        x_step = ldata.x[1]::Vector{SVector{D, Float64}}
        N_p = length(x_step)
        
        @batch for idx in CartesianIndices(grid_shape)
            
            # Pure SVector algebraic position calculation
            s_idx = SVector{D, Float64}(Tuple(idx))
            pos = s_mins + s_dx .* (s_idx .- 1.0)
            
            w_sum = 0.0
            
            # Zero out the target array positions
            for i in 1:length(profile_keys)
                for c in 1:D; e_profiles[profile_keys[i]][c, idx] = 0.0; end
            end

            @inbounds for p_idx in 1:N_p
                # Squared distance calculation applied here too
                dist = sum(abs2, pos - x_step[p_idx])
                
                if dist < 1e-10
                    for i in 1:length(profile_vals)
                        for c in 1:D; e_profiles[profile_keys[i]][c, idx] = profile_vals[i][1][p_idx][c]; end
                    end
                    w_sum = 1.0; break
                    
                elseif dist <= radius
                    # 1/r^4 falloff from squared distance
                    w = 1.0 / (dist^2)
                    w_sum += w
                    for i in 1:length(profile_vals)
                        for c in 1:D; e_profiles[profile_keys[i]][c, idx] += profile_vals[i][1][p_idx][c] * w; end
                    end
                end
            end
            
            if w_sum > 0.0
                for i in 1:length(profile_keys)
                    for c in 1:D; e_profiles[profile_keys[i]][c, idx] /= w_sum; end
                end
            else
                for i in 1:length(profile_keys)
                    for c in 1:D; e_profiles[profile_keys[i]][c, idx] = NaN; end
                end
            end
        end
    end

    edata = ESimData(ldata.params, x_euler, u_euler, ldata.t, 
                     ldata.xmins, ldata.xmaxs, ldata.tmin, ldata.tmax, 
                     ldata.scalars, ldata.series, e_profiles, e_fields)
    
    # Unconditionally push it through the uniform time resampler!
    return resample_time(edata, T_grid)
end
