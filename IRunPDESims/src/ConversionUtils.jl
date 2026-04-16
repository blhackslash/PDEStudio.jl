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

function convert_to_eulerian(ldata::LSimData{D, M}, N_grid::Int=50) where {D, M}
    T_len = length(ldata.t)

    mins = fill(Inf, D); maxs = fill(-Inf, D)
    for step in ldata.x; for p in step; for d in 1:D
        mins[d] = min(mins[d], p[d]); maxs[d] = max(maxs[d], p[d])
    end; end; end

    for d in 1:D
        pad = max(1e-5, (maxs[d] - mins[d]) * 0.01)
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
    radius = (norm(cell_sizes) * 3.0)^2

    field_keys = collect(keys(ldata.fields))
    field_vals = collect(values(ldata.fields))

    profile_keys = collect(keys(ldata.profiles))
    profile_vals = collect(values(ldata.profiles))

    # =========================================================================
    # 1. SPATIAL BATCH LOOP (Dynamic, Time-Series Data)
    # =========================================================================
    @batch for idx in CartesianIndices(grid_shape)
        pos = if D == 1
            SVector{1, Float64}(grid_axes[1][idx[1]])
        elseif D == 2
            SVector{2, Float64}(grid_axes[1][idx[1]], grid_axes[2][idx[2]])
        elseif D == 3
            SVector{3, Float64}(grid_axes[1][idx[1]], grid_axes[2][idx[2]], grid_axes[3][idx[3]])
        else
            # Fallback for 4D+, Polyester might still warn but typically physical sims are <= 3D
            SVector{D, Float64}(ntuple(d -> grid_axes[d][idx[d]], Val(D))) 
        end
        
        for t_idx in 1:T_len
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
            u_sum = zero(SVector{M, Float64})
            
            # Zero out the target array positions for direct accumulation
            for i in 1:length(field_keys)
                for c in 1:M; e_fields[field_keys[i]][c, idx, t_idx] = 0.0; end
            end

            for p_idx in 1:N_p
                dist = sum(abs2,pos - x_step[p_idx])
                
                if dist < 1e-10 
                    u_sum = u_step[p_idx]
                    for i in 1:length(field_vals)
                        for c in 1:M; e_fields[field_keys[i]][c, idx, t_idx] = field_vals[i][t_idx][p_idx][c]; end
                    end
                    w_sum = 1.0; break
                    
                elseif dist <= radius
                    w = 1.0 / (dist^2)
                    w_sum += w
                    u_sum += u_step[p_idx] * w
                    
                    # Accumulate DIRECTLY into the output array (Zero allocations!)
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
        x_step = ldata.x[1]
        
        @batch for idx in CartesianIndices(grid_shape)
        pos = if D == 1
            SVector{1, Float64}(grid_axes[1][idx[1]])
        elseif D == 2
            SVector{2, Float64}(grid_axes[1][idx[1]], grid_axes[2][idx[2]])
        elseif D == 3
            SVector{3, Float64}(grid_axes[1][idx[1]], grid_axes[2][idx[2]], grid_axes[3][idx[3]])
        else
            # Fallback for 4D+, Polyester might still warn but typically physical sims are <= 3D
            SVector{D, Float64}(ntuple(d -> grid_axes[d][idx[d]], Val(D))) 
        end
            w_sum = 0.0
            
            # Zero out the target array positions
            for i in 1:length(profile_keys)
                for c in 1:D; e_profiles[profile_keys[i]][c, idx] = 0.0; end
            end

            for p_idx in 1:length(x_step)
                dist = norm(pos - x_step[p_idx])
                
                if dist < 1e-10
                    for i in 1:length(profile_vals)
                        for c in 1:D; e_profiles[profile_keys[i]][c, idx] = profile_vals[i][1][p_idx][c]; end
                    end
                    w_sum = 1.0; break
                    
                elseif dist <= radius
                    w = 1.0 / (dist^2); w_sum += w
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