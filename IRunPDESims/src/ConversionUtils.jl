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

function convert_to_eulerian(ldata::LSimData{D, M}, N_grid::Int) where {D, M}
    T_len = length(ldata.t)

    mins = fill(Inf, D); maxs = fill(-Inf, D)
    for step in ldata.x; for p in step; for d in 1:D
        mins[d] = min(mins[d], p[d]); maxs[d] = max(maxs[d], p[d])
    end; end; end

    for d in 1:D
        pad = 0. # max(1e-5, (maxs[d] - mins[d]) * 0.01)
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

    return ESimData(ldata.params, x_euler, u_euler, ldata.t, ldata.scalars, ldata.series, e_profiles, e_fields)
end
