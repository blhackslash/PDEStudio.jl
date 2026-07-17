# ==============================================================================
# --- EULERIAN CONSTRUCTORS ---
# ==============================================================================

# 1D Eulerian Constructor
function createSimData(
    x::AbstractVector{<:Real}, 
    u::AbstractMatrix{SVector{M, T}}, 
    t::AbstractVector{<:Real}, 
    params::ParamDict; 
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing
) where {M, T<:Real}
    
    _xmins = isnothing(xmins) ? (Float64(minimum(x)),) : Float64.(Tuple(xmins))
    _xmaxs = isnothing(xmaxs) ? (Float64(maximum(x)),) : Float64.(Tuple(xmaxs))
    _tmin  = isnothing(tmin)  ? Float64(minimum(t)) : Float64(tmin)
    _tmax  = isnothing(tmax)  ? Float64(maximum(t)) : Float64(tmax)
    
    # Cast inner values to Float64 if they aren't already
    u_float = u isa AbstractMatrix{SVector{M, Float64}} ? u : [SVector{M, Float64}(v) for v in u]
    
    return ESimData{1, M}(params, (Float64.(x),), u_float, Float64.(t), _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict(), Dict())
end

# 2D Eulerian Constructor
function createSimData(
    x_grid::AbstractMatrix{<:Real}, 
    y_grid::AbstractMatrix{<:Real}, 
    u::AbstractArray{SVector{M, T}, 3}, 
    t::AbstractVector{<:Real}, 
    params::ParamDict; 
    xmins=nothing, xmaxs=nothing, tmin=nothing, tmax=nothing
) where {M, T<:Real}
    
    x_axis = vec(x_grid[:, 1]) 
    y_axis = vec(y_grid[1, :]) 
    
    _xmins = isnothing(xmins) ? (Float64(minimum(x_axis)), Float64(minimum(y_axis))) : Float64.(Tuple(xmins))
    _xmaxs = isnothing(xmaxs) ? (Float64(maximum(x_axis)), Float64(maximum(y_axis))) : Float64.(Tuple(xmaxs))
    _tmin  = isnothing(tmin)  ? Float64(minimum(t)) : Float64(tmin)
    _tmax  = isnothing(tmax)  ? Float64(maximum(t)) : Float64(tmax)

    u_float = u isa AbstractArray{SVector{M, Float64}, 3} ? u : [SVector{M, Float64}(v) for v in u]

    return ESimData{2, M}(params, (Float64.(x_axis), Float64.(y_axis)), u_float, Float64.(t), _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict(), Dict())
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
    
    return LSimData{1, 1}(params, x_vec, u_vec, Float64.(t), _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict())
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

    return LSimData{D, M}(params, x, u, t, _xmins, _xmaxs, _tmin, _tmax, Dict(), Dict(), Dict())
end

function resample_time(data::ESimData{D, M}, T_grid::Int) where {D, M}
    target_t = collect(range(data.tmin, data.tmax, length=T_grid))
    
    # If the time vectors perfectly match the uniform grid, skip the overhead
    if length(data.t) == T_grid && all(isapprox.(data.t, target_t, atol=1e-8))
        return data
    end
    
    @info "Nearest-Neighbor resampling Eulerian data from $(length(data.t)) to $T_grid timesteps..."
    
    T_new = T_grid
    T_old = length(data.t)
    
    # 1. Allocate new SVector tensors dynamically
    new_u = similar(data.u, size(data.u)[1:end-1]..., T_new)
    
    # Use typeof() to perfectly match the dynamically dimensioned SVector tensor
    new_fields = Dict{String, typeof(data.u)}()
    for (k, v) in data.fields
        new_fields[k] = similar(v, size(v)[1:end-1]..., T_new)
    end
    
    # Update Series to expect SVectors!
    new_series = Dict{String, Vector{SVector{M, Float64}}}()
    for (k, v) in data.series
        new_series[k] = similar(v, T_new)
    end

    # 2. Helper to find the absolute closest native frame
    function get_nearest_idx(t)
        if t <= data.t[1]; return 1; end
        if t >= data.t[end]; return T_old; end
        
        idx = searchsortedlast(data.t, t)
        if idx == T_old; return T_old; end
        
        # Return whichever frame is closer in time
        return abs(t - data.t[idx]) < abs(t - data.t[idx+1]) ? idx : idx+1
    end

    # 3. Fast Broadcast Snapping Loop
    Threads.@threads for i in 1:T_new
        nearest = get_nearest_idx(target_t[i])
        
        selectdim(new_u, ndims(new_u), i) .= selectdim(data.u, ndims(data.u), nearest)
        
        for (k, v) in data.fields
            selectdim(new_fields[k], ndims(v), i) .= selectdim(v, ndims(v), nearest)
        end
        
        for (k, v) in data.series
            # Series are just 1D vectors now, so we can index them directly!
            new_series[k][i] = v[nearest]
        end
    end

    return ESimData{D, M}(
        data.params, data.x, new_u, target_t, 
        data.xmins, data.xmaxs, data.tmin, data.tmax,
        data.scalars, new_series, data.profiles, new_fields
    )
end

function convert_to_eulerian(ldata::LSimData{D, M}; N_grid=_N_GRID[], T_grid=_T_GRID[]) where {D, M}
    T_len = length(ldata.t)
    mins, maxs = collect(ldata.xmins), collect(ldata.xmaxs)
    
    grid_axes = ntuple(d -> collect(range(mins[d], maxs[d], length=N_grid)), Val(D))
    grid_shape = ntuple(d -> N_grid, Val(D))
    x_euler = ntuple(d -> grid_axes[d], Val(D))

    # --- Pre-calculate grid metrics ---
    N_p_initial = max(1, length(ldata.x[1]))
    pts_per_dim = max(1.0, N_p_initial^(1 / D) - 1.0)
    
    cell_sizes = [(maxs[d] - mins[d]) / max(1, N_grid - 1) for d in 1:D]
    particle_spacings = [(maxs[d] - mins[d]) / pts_per_dim for d in 1:D]
    
    effective_spacing = max.(cell_sizes, particle_spacings)
    radius = (norm(effective_spacing) * 1.5)^2
    radius_1d = sqrt(radius) # For the bounding box

    s_mins = SVector{D, Float64}(mins)
    s_maxs = SVector{D, Float64}(maxs)
    s_dx = (s_maxs - s_mins) / max(1, N_grid - 1)
    s_inv_dx = 1.0 ./ s_dx # Pre-compute inverse for fast division

    # --- Preallocate SVector Eulerian grids ---
    zero_vec = zero(SVector{M, Float64})
    nan_vec = zero_vec .* NaN
    
    u_euler = fill(zero_vec, grid_shape..., T_len)
    w_euler = zeros(Float64, grid_shape..., T_len)
    
    e_fields = Dict{String, Array{SVector{M, Float64}, D+1}}()
    for k in keys(ldata.fields)
        e_fields[k] = fill(zero_vec, grid_shape..., T_len)
    end
    
    # Pre-extract dictionaries for fast loop access
    field_keys = collect(keys(ldata.fields))
    field_vals = collect(values(ldata.fields))

    # =========================================================================
    # 1. TIME BATCH LOOP (Dynamic Scatter Algorithm)
    # =========================================================================
    @batch for t_idx in 1:T_len
        x_step = ldata.x[t_idx]
        u_step = ldata.u[t_idx]
        N_p = length(x_step)
        
        # Pass 1: Scatter particles to local grid cells
        @inbounds for p_idx in 1:N_p
            pos = x_step[p_idx]
            
            # 1. Calculate Grid Bounding Box for this particle
            idx_float = (pos .- s_mins) .* s_inv_dx .+ 1.0
            rad_idx = radius_1d .* s_inv_dx
            
            min_idx = @. max(1, floor(Int, idx_float - rad_idx))
            max_idx = @. min(N_grid, ceil(Int, idx_float + rad_idx))
            
            # 2. Scatter only to affected cells
            for cell_idx in CartesianIndices(ntuple(d -> min_idx[d]:max_idx[d], Val(D)))
                s_idx = SVector{D, Float64}(Tuple(cell_idx))
                cell_pos = s_mins + s_dx .* (s_idx .- 1.0)
                
                dist2 = sum(abs2, cell_pos - pos)
                if dist2 <= radius
                    # Smooth 1/r^2 weight, clamped to avoid Inf at perfect overlap
                    w = 1.0 / max(dist2, 1e-12) 
                    
                    w_euler[cell_idx, t_idx] += w
                    u_euler[cell_idx, t_idx] += u_step[p_idx] * w
                    
                    for i in 1:length(field_vals)
                        e_fields[field_keys[i]][cell_idx, t_idx] += field_vals[i][t_idx][p_idx] * w
                    end
                end
            end
        end
        
        # Pass 2: Finalize averages for this time step
        @inbounds for cell_idx in CartesianIndices(grid_shape)
            w_sum = w_euler[cell_idx, t_idx]
            if w_sum > 0.0
                u_euler[cell_idx, t_idx] /= w_sum
                for k in field_keys
                    e_fields[k][cell_idx, t_idx] /= w_sum
                end
            else
                u_euler[cell_idx, t_idx] = nan_vec
                for k in field_keys
                    e_fields[k][cell_idx, t_idx] = nan_vec
                end
            end
        end
    end
    println(ldata.series)
    edata = ESimData{D, M}(ldata.params, x_euler, u_euler, ldata.t, 
                           ldata.xmins, ldata.xmaxs, ldata.tmin, ldata.tmax, 
                           ldata.scalars, ldata.series, Dict{String, Array{SVector{M, Float64}, D}}(), e_fields)
    
    return resample_time(edata, T_grid)
end
# ==============================================================================
# Eulerian to Lagrangian Conversion (Grid Shattering)
# ==============================================================================
function convert_to_lagrangian(data::ESimData{D, M}) where {D, M}
    @info "Shattering Eulerian grid into unstructured Lagrangian particles..."
    T_len = length(data.t)
    
    # 1. Flatten the spatial meshgrid into 1D particle arrays
    if D == 1
        pts = [SVector{1, Float64}(x) for x in data.x[1]]
    elseif D == 2
        pts = vec([SVector{2, Float64}(x, y) for x in data.x[1], y in data.x[2]])
    elseif D == 3
        pts = vec([SVector{3, Float64}(x, y, z) for x in data.x[1], y in data.x[2], z in data.x[3]])
    end
    N_pts = length(pts)
    
    # Since Eulerian grids are static, duplicate the positions over time.
    new_x = [copy(pts) for _ in 1:T_len]
    
    # 2. Fast Reshape Helper for Tensors
    function flatten_field(field_tensor)
        new_field = Vector{Vector{SVector{M, Float64}}}(undef, T_len)
        for t in 1:T_len
            slice = selectdim(field_tensor, ndims(field_tensor), t)
            new_field[t] = vec(slice)
        end
        return new_field
    end
    
    # 3. Apply to all dynamic data
    new_u = flatten_field(data.u)
    
    new_fields = Dict{String, Vector{Vector{SVector{M, Float64}}}}()
    for (k, v) in data.fields
        new_fields[k] = flatten_field(v)
    end
    
    # Notice: new_profiles is completely removed here.
    
    return LSimData{D, M}(
        data.params, new_x, new_u, data.t, 
        data.xmins, data.xmaxs, data.tmin, data.tmax,
        data.scalars, data.series, new_fields # <-- No profiles passed!
    )
end
function generate_reference_simdata(ref_func::Function, params::ParamDict, template_data::LSimData{D, M}) where {D, M}
    N = _REF_GRID[]
    T_len = _T_GRID[]
    
    # 1. Use existing template bounds
    xmins, xmaxs = template_data.xmins, template_data.xmaxs
    tmin, tmax = template_data.tmin, template_data.tmax
    
    # 2. Build vectors
    t_vec = collect(range(tmin, tmax, length=T_len))
    axes_list = ntuple(d -> collect(range(xmins[d], xmaxs[d], length=N)), D)
    grid_shape = ntuple(d -> N, D)
    N_pts = prod(grid_shape)
    
    # 3. Generate static particle positions
    static_particles = [SVector{D, Float64}(ntuple(d -> axes_list[d][idx[d]], D)) 
                        for idx in CartesianIndices(grid_shape)]
    
    x_ref = [copy(static_particles) for _ in 1:T_len]
    u_ref = Vector{Vector{SVector{M, Float64}}}(undef, T_len)
    
    # 4. Evaluate using the analytical logic
    Threads.@threads for t_idx in 1:T_len
        t = t_vec[t_idx]
        u_ref[t_idx] = [SVector{M, Float64}(ref_func(pos, t)) for pos in static_particles]
    end
    
    return LSimData{D, M}(
        params, x_ref, u_ref, t_vec,
        xmins, xmaxs, tmin, tmax,
        Dict(), Dict(), Dict()
    )
end
function generate_reference_simdata(ref_func::Function, params::ParamDict, template_data::ESimData{D, M_orig}) where {D, M_orig}
    N = _REF_GRID[]
    T = _T_GRID[]
    
    xmins, xmaxs = template_data.xmins, template_data.xmaxs
    tmin, tmax = template_data.tmin, template_data.tmax
    
    axes_list = ntuple(d -> collect(range(xmins[d], xmaxs[d], length=N)), D)
    t_vec = collect(range(tmin, tmax, length=T))
    
    # 1. Determine M from the function output
    sample_val = ref_func(SVector{D, Float64}(ntuple(d -> axes_list[d][1], D)), t_vec[1])
    M = length(sample_val)
    
    # 2. Pre-allocate the SVector tensor layout
    grid_shape = ntuple(d -> N, D)
    u_exact = Array{SVector{M, Float64}, D+1}(undef, grid_shape..., T)
    
    # 3. Fill the tensor
    Threads.@threads for t_idx in 1:T
        t = t_vec[t_idx]
        for idx in CartesianIndices(grid_shape)
            pos = SVector{D, Float64}(ntuple(d -> axes_list[d][idx[d]], D))
            u_exact[idx, t_idx] = SVector{M, Float64}(ref_func(pos, t))
        end
    end
    
    # 4. Construct the RAM-only container
    ram_data = ESimData{D, M}(
        params, axes_list, u_exact, t_vec, 
        xmins, xmaxs, tmin, tmax, 
        Dict(), Dict(), Dict(), Dict()
    )
    
    # Calculate baseline stats immediately
    calculateAllStats!(ram_data, ref_func)
    
    return ram_data
end