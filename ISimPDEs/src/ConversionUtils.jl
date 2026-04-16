"""
    createSimData(x::Vector, u::Matrix, t::Vector, params)

1D Scalar Eulerian. Auto-expands the `[Space, Time]` matrix into 
the required `[Component, Space, Time]` tensor.
"""
function createSimData(x::AbstractVector{<:Real}, u::AbstractMatrix{<:Real}, t::AbstractVector{<:Real}, params::ParamDict)
    u_expanded = reshape(u, 1, size(u, 1), size(u, 2))
    return ESimData{1}(params, (Float64.(x),), Float64.(u_expanded), Float64.(t), Dict(), Dict(), Dict(), Dict())
end

function createSimData(x::AbstractVector{<:Real}, u::AbstractArray{<:Real, 3}, t::AbstractVector{<:Real}, params::ParamDict)
    return ESimData{1}(params, (Float64.(x),), Float64.(u), Float64.(t), Dict(), Dict(), Dict(), Dict())
end

"""
    createSimData(x_grid::Matrix, y_grid::Matrix, u::Array{T,3}, t::Vector, params)

2D Scalar Eulerian. Accepts standard meshgrids and a `[X, Y, Time]` tensor.
"""
function createSimData(x_grid::AbstractMatrix{<:Real}, y_grid::AbstractMatrix{<:Real}, u::AbstractArray{<:Real, 3}, t::AbstractVector{<:Real}, params::ParamDict)
    # Extract the 1D axes from the meshgrids (assuming standard ndgrid layout)
    x_axis = vec(x_grid[:, 1]) 
    y_axis = vec(y_grid[1, :]) 
    
    u_expanded = reshape(u, 1, size(u, 1), size(u, 2), size(u, 3))
    # Pass as a Tuple of Vectors
    return ESimData{2}(params, (Float64.(x_axis), Float64.(y_axis)), Float64.(u_expanded), Float64.(t), Dict(), Dict(), Dict(), Dict())
end

# ==============================================================================
# --- LAGRANGIAN CONVERSIONS ---
# ==============================================================================

"""
    createSimData(x::Matrix, u::Matrix, t::Vector, params)

1D Scalar Lagrangian. Converts flat `[Particle, Time]` matrices into 
nested `SVector` time-steps.
"""
function createSimData(x::AbstractMatrix{<:Real}, u::AbstractMatrix{<:Real}, t::AbstractVector{<:Real}, params::ParamDict)
    n_p, n_t = size(x)
    
    x_vec = [[SVector{1, Float64}(x[p, m]) for p in 1:n_p] for m in 1:n_t]
    u_vec = [[SVector{1, Float64}(u[p, m]) for p in 1:n_p] for m in 1:n_t]
    
    return LSimData{1, 1}(params, x_vec, u_vec, Float64.(t), Dict(), Dict(), Dict(), Dict())
end

"""
    createSimData(x::Vector{Vector{Space{D}}}, u::Vector{Vector{State{M}}}, t, params)

Native Multi-D / Multi-Component Lagrangian. 
Directly maps your simulation package's output!
"""
function createSimData(
    x::Vector{Vector{SVector{D, Float64}}}, 
    u::Vector{Vector{SVector{M, Float64}}}, 
    t::Vector{Float64}, 
    params::ParamDict
) where {D, M}
    return LSimData{D, M}(params, x, u, t, Dict(), Dict(), Dict(), Dict())
end

function convert_to_eulerian(ldata::LSimData, N_grid::Int=50)
    D = length(ldata.x[1][1]) 
    T = length(ldata.t)
    C = length(ldata.u[1][1]) 

    mins = fill(Inf, D); maxs = fill(-Inf, D)
    for step in ldata.x; for p in step; for d in 1:D
        mins[d] = min(mins[d], p[d]); maxs[d] = max(maxs[d], p[d])
    end; end; end

    for d in 1:D
        pad = max(1e-5, (maxs[d] - mins[d]) * 0.01)
        mins[d] -= pad; maxs[d] += pad
    end

    grid_axes = ntuple(d -> range(mins[d], maxs[d], length=N_grid), D)
    grid_shape = ntuple(d -> N_grid, D)

    # 1. NEW COMPACT X ALLOCATION (Strictly 1D Vectors)
    x_euler = ntuple(d -> collect(grid_axes[d]), D)

    u_euler = zeros(Float64, C, grid_shape..., T)
    e_fields = Dict{String, Array{Float64}}()
    for (k, v) in ldata.fields; e_fields[k] = zeros(Float64, size(v, 1), grid_shape..., T); end
    
    e_profiles = Dict{String, Array{Float64}}()
    for (k, v) in ldata.profiles; e_profiles[k] = zeros(Float64, size(v, 1), grid_shape...); end

    # --- THE FIX: Localized Search Radius ---
    # Calculates a typical grid-cell size and sets a compact support radius
    cell_sizes = [(maxs[d] - mins[d]) / max(1, N_grid - 1) for d in 1:D]
    radius = norm(cell_sizes) * 3.0

    Threads.@threads for t_idx in 1:T
        x_step = ldata.x[t_idx]; N_p = length(x_step)
        N_p == 0 && continue

        for idx in CartesianIndices(grid_shape)
            pos = SVector{D, Float64}(ntuple(d -> grid_axes[d][idx[d]], D))
            w_sum = 0.0; u_sum = zeros(C)
            f_sums = Dict(k => zeros(size(v, 1)) for (k, v) in ldata.fields)

            for p_idx in 1:N_p
                dist = norm(pos - x_step[p_idx])
                if dist < 1e-10 
                    for c in 1:C; u_sum[c] = ldata.u[t_idx][p_idx][c]; end
                    for (k, v) in ldata.fields; for c in 1:size(v, 1); f_sums[k][c] = v[c, p_idx, t_idx]; end; end
                    w_sum = 1.0; break
                    
                # ONLY apply particles within the physically relevant cutoff!
                elseif dist <= radius
                    w = 1.0 / (dist^4) # p=4 provides a sharper, more accurate local falloff
                    w_sum += w
                    for c in 1:C; u_sum[c] += ldata.u[t_idx][p_idx][c] * w; end
                    for (k, v) in ldata.fields; for c in 1:size(v, 1); f_sums[k][c] += v[c, p_idx, t_idx] * w; end; end
                end
            end

            # If particles were found, set the average. Otherwise, it's EMPTY space (NaN).
            if w_sum > 0.0
                for c in 1:C; u_euler[c, Tuple(idx)..., t_idx] = u_sum[c] / w_sum; end
                for (k, v) in ldata.fields; for c in 1:size(v, 1); e_fields[k][c, Tuple(idx)..., t_idx] = f_sums[k][c] / w_sum; end; end
            else
                for c in 1:C; u_euler[c, Tuple(idx)..., t_idx] = NaN; end
                for (k, v) in ldata.fields; for c in 1:size(v, 1); e_fields[k][c, Tuple(idx)..., t_idx] = NaN; end; end
            end
        end
    end

    if !isempty(ldata.profiles)
        x_step = ldata.x[1]
        for idx in CartesianIndices(grid_shape)
            pos = SVector{D, Float64}(ntuple(d -> grid_axes[d][idx[d]], D))
            w_sum = 0.0
            p_sums = Dict(k => zeros(size(v, 1)) for (k, v) in ldata.profiles)

            for p_idx in 1:length(x_step)
                dist = norm(pos - x_step[p_idx])
                if dist < 1e-10
                    for (k, v) in ldata.profiles; for c in 1:size(v, 1); p_sums[k][c] = v[c, p_idx]; end; end
                    w_sum = 1.0; break
                elseif dist <= radius
                    w = 1.0 / (dist^4); w_sum += w
                    for (k, v) in ldata.profiles; for c in 1:size(v, 1); p_sums[k][c] += v[c, p_idx] * w; end; end
                end
            end
            
            if w_sum > 0.0
                for (k, v) in ldata.profiles; for c in 1:size(v, 1); e_profiles[k][c, Tuple(idx)...] = p_sums[k][c] / w_sum; end; end
            else
                for (k, v) in ldata.profiles; for c in 1:size(v, 1); e_profiles[k][c, Tuple(idx)...] = NaN; end; end
            end
        end
    end

    return ESimData(ldata.params, x_euler, u_euler, ldata.t, ldata.scalars, ldata.series, e_profiles, e_fields)
end

function generate_reference_simdata(ref_func::Function, params::ParamDict)
    N = _REFERENCE_RESOLUTION[]
    
    # 1. Extract physical bounds directly from parameters (Strict requires)
    xmin = params["mins"]
    xmax = params["maxs"]
    tmax = params["tmax"]
    snapshots = params["snapshots"]
    
    # Optional parameters
    tmin = get(params, "tmin", 0.0)
    
    # Determine dimensionality based on the type of xmin
    D = length(xmin)
    
    # 2. Build the high-res spatial axes
    axes_list = ntuple(D) do d
        min_val = Float64(xmin[d])
        max_val = Float64(xmax[d])
        collect(range(min_val, max_val, length=N))
    end
    
    # 3. Build the time vector (snapshots + 1 ensures we include t=0)
    t_vec = tmax > tmin ? collect(range(tmin, tmax, length=snapshots+1)) : [Float64(tmin)]
    T = length(t_vec)
    
    # Evaluate one point to find the number of components (C)
    # --- THE FIX: Create an SVector cleanly using ntuple ---
    sample_pos = SVector{D, Float64}(ntuple(d -> axes_list[d][1], D))
    sample_val = ref_func(sample_pos, t_vec[1])
    C = length(sample_val)
    
    # 4. Allocate the dense tensor
    grid_shape = ntuple(d -> N, D)
    u_exact = zeros(Float64, C, grid_shape..., T)
    
    # 5. Evaluate the exact function on the fly
    Threads.@threads for t_idx in 1:T
        t = t_vec[t_idx]
        for idx in CartesianIndices(grid_shape)
            # --- THE FIX: Native, allocation-free SVector creation ---
            pos = SVector{D, Float64}(ntuple(d -> axes_list[d][idx[d]], D))
            exact_val = ref_func(pos, t)
            
            for c in 1:C
                u_exact[c, Tuple(idx)..., t_idx] = exact_val[c]
            end
        end
    end
    
    # Return a lightweight ESimData that exists ONLY in RAM
    return ESimData{D}(params, axes_list, u_exact, t_vec, Dict(), Dict(), Dict(), Dict())
end