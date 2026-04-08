"""
    assembleParams(shared_obs, method_obs_collection, method_name)

Constructs a flat parameter dictionary for a simulation run by combining
current shared parameter values and current method-specific parameter values.

Method-specific parameters override shared parameters if keys conflict.
"""
function assembleParams(
    shared_params_obs::Union{Dict{String, Observable},ParamDict},
    method_params_collection_obs::Union{Dict{String, Dict{String, Observable}},MethodDict},
    method_name::String
    )::ParamDict # Assuming ParamDict = Dict{String, Any}

    method_specific_obs_dict = haskey(method_params_collection_obs, method_name) ? method_params_collection_obs[method_name] : nothing
    # --- CORRECTED: Safely get the list of keys to ignore from the observable ---
    ignore_keys = String[] # Default to an empty list
    if haskey(method_specific_obs_dict, "ignore")
        # Get the value from the "ignore" observable
        val = to_value(method_specific_obs_dict["ignore"])
        if val isa AbstractVector{<:AbstractString}
            ignore_keys = val
        end
    end
    # Start with current values of shared parameters
    current_params = Dict{String,Any}()
    for (key, obs) in shared_params_obs
        if key in ignore_keys; continue end
        val = to_value(obs)
        if isa(val, Tuple) && length(val) == 2 && val[1] == :const
            current_params[key] = to_value(val[2])
        else
            current_params[key] = val
        end
    end

    # Get the specific observable dictionary for the requested method
    if !isnothing(method_specific_obs_dict)
        # Merge/override with current values of method-specific parameters
        for (key, obs) in method_specific_obs_dict
            val = to_value(obs)
            if isa(val, Tuple) && length(val) == 2 && val[1] == :const
                current_params[key] = to_value(val[2])
            else
                current_params[key] = val
            end
        end
    else
        # This might be expected if a method uses only shared params
        @warn "No specific parameters found for method '$method_name' in observable collection."
    end

    # Add method name itself (optional, but often useful for saving/loading)
    #current_params["method"] = method_name

    return current_params
end


function allMethodNames(config::SimulationConfig)
    return collect(keys(config.methods_dict))
end

function createObsDict(dict::Dict{String,Any})
    dict_obs = Dict{String,Observable}()
    for (key,val) = dict
        dict_obs[key] = Observable(val)
    end
    return dict_obs
end

function parseValue(s::String)
    try
        # Meta.parse turns a string into a Julia expression.
        # `eval` executes that expression.
        return eval(Meta.parse(s))
    catch e
        # If parsing fails, it's probably just a plain string.
        # We also strip quotes that CSV readers sometimes add.
        return s == "<empty>" ? "" : string(strip(s, '\"'))
    end
end

"""
    smart_parse_and_update!(obs::Observable, input_str::String)

Attempts to parse `input_str` into the same type as the current value of `obs`.
If parsing fails or types are incompatible, it prints a warning and leaves the 
observable unchanged.
"""
function smart_parse_and_update!(obs::Observable, input_str::String)
    # Ignore empty inputs (usually handled by the placeholder logic)
    (isempty(input_str) || input_str == "default") && return
    
    current_val = to_value(obs)
    T = typeof(current_val)

    try
        if T == String
            obs[] = input_str
        elseif T == Symbol
            obs[] = Symbol(input_str)
        elseif T == Bool
            # Handle true/false, 1/0, yes/no
            s = lowercase(strip(input_str))
            obs[] = (s == "true" || s == "1" || s == "yes")
        elseif T <: Int
            obs[] = parse(Int, input_str)
        elseif T <: AbstractFloat
            obs[] = parse(Float64, input_str)
        elseif T <: Tuple || T <: Vector
            # For complex types, we use the general parser but check the result type
            parsed = parseValue(input_str) 
            if typeof(parsed) == T
                obs[] = parsed
            else
                @warn "Type mismatch for complex input. Expected $T, but got $(typeof(parsed))."
            end
        else
            # Fallback for any other types
            obs[] = parse(T, input_str)
        end
    catch e
        @warn "Invalid input: Could not parse '$input_str' as $T. The value remains: $current_val"
    end
end
# ==============================================================================
# --- EULERIAN CONVERSIONS ---
# ==============================================================================

"""
    createSimData(x::Vector, u::Matrix, t::Vector, params)

1D Scalar Eulerian. Auto-expands the `[Space, Time]` matrix into 
the required `[Component, Space, Time]` tensor.
"""
function createSimData(x::AbstractVector{<:Real}, u::AbstractMatrix{<:Real}, t::AbstractVector{<:Real}, params::ParamDict)
    u_expanded = reshape(u, 1, size(u, 1), size(u, 2))
    return ESimData{1}(params, Float64.(x), Float64.(u_expanded), Float64.(t), Dict(), Dict(), Dict(), Dict())
end

"""
    createSimData(x::Vector, u::Array{T,3}, t::Vector, params)

1D System Eulerian. Directly maps the `[Comp, Space, Time]` array.
"""
function createSimData(x::AbstractVector{<:Real}, u::AbstractArray{<:Real, 3}, t::AbstractVector{<:Real}, params::ParamDict)
    return ESimData{1}(params, Float64.(x), Float64.(u), Float64.(t), Dict(), Dict(), Dict(), Dict())
end

"""
    createSimData(x_grid::Matrix, y_grid::Matrix, u::Array{T,3}, t::Vector, params)

2D Scalar Eulerian. Accepts standard meshgrids and a `[X, Y, Time]` tensor.
"""
function createSimData(x_grid::AbstractMatrix{<:Real}, y_grid::AbstractMatrix{<:Real}, u::AbstractArray{<:Real, 3}, t::AbstractVector{<:Real}, params::ParamDict)
    # Stack x and y grids into a single coordinate tensor
    xy_coords = cat(x_grid, y_grid, dims=3)
    u_expanded = reshape(u, 1, size(u, 1), size(u, 2), size(u, 3))
    return ESimData{2}(params, Float64.(xy_coords), Float64.(u_expanded), Float64.(t), Dict(), Dict(), Dict(), Dict())
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
"""
    convert_to_eulerian(ldata::LSimData, N_grid::Int=50)

Interpolates unstructured Lagrangian particle data onto a structured Eulerian grid.
Automatically interpolates spatial 'fields' and 'profiles' alongside 'u'.
"""
function convert_to_eulerian(ldata::LSimData, N_grid::Int=50)
    D = length(ldata.x[1][1]) 
    T = length(ldata.t)
    C = length(ldata.u[1][1]) 

    # 1. Bounding Box & Grid axes
    mins = fill(Inf, D); maxs = fill(-Inf, D)
    for step in ldata.x
        for p in step
            for d in 1:D
                mins[d] = min(mins[d], p[d])
                maxs[d] = max(maxs[d], p[d])
            end
        end
    end

    for d in 1:D
        pad = max(1e-5, (maxs[d] - mins[d]) * 0.01)
        mins[d] -= pad; maxs[d] += pad
    end

    grid_axes = ntuple(d -> range(mins[d], maxs[d], length=N_grid), D)
    grid_shape = ntuple(d -> N_grid, D)

# 2. Allocate Eulerian Tensors
    if D == 1; x_euler = collect(grid_axes[1]); else
        x_euler = zeros(Float64, grid_shape..., D)
        for idx in CartesianIndices(grid_shape)
            for d in 1:D; x_euler[Tuple(idx)..., d] = grid_axes[d][idx[d]]; end
        end
    end

    u_euler = zeros(Float64, C, grid_shape..., T)
    
    # --- THE FIX: Explicitly typed dictionaries ---
    e_fields = Dict{String, Array{Float64}}()
    for (k, v) in ldata.fields
        e_fields[k] = zeros(Float64, size(v, 1), grid_shape..., T)
    end
    
    e_profiles = Dict{String, Array{Float64}}()
    for (k, v) in ldata.profiles
        e_profiles[k] = zeros(Float64, size(v, 1), grid_shape...)
    end

    # 3. Time-Dependent Interpolation (u & fields)
    Threads.@threads for t_idx in 1:T
        x_step = ldata.x[t_idx]
        N_p = length(x_step)
        N_p == 0 && continue

        for idx in CartesianIndices(grid_shape)
            pos = SVector{D, Float64}(ntuple(d -> grid_axes[d][idx[d]], D))
            
            w_sum = 0.0
            u_sum = zeros(C)
            f_sums = Dict(k => zeros(size(v, 1)) for (k, v) in ldata.fields)

            for p_idx in 1:N_p
                dist = norm(pos - x_step[p_idx])
                
                # Exact coordinate match bypass
                if dist < 1e-10 
                    for c in 1:C; u_sum[c] = ldata.u[t_idx][p_idx][c]; end
                    for (k, v) in ldata.fields; for c in 1:size(v, 1); f_sums[k][c] = v[c, p_idx, t_idx]; end; end
                    w_sum = 1.0
                    break
                end

                w = 1.0 / (dist^2)
                w_sum += w
                for c in 1:C; u_sum[c] += ldata.u[t_idx][p_idx][c] * w; end
                for (k, v) in ldata.fields; for c in 1:size(v, 1); f_sums[k][c] += v[c, p_idx, t_idx] * w; end; end
            end

            for c in 1:C; u_euler[c, Tuple(idx)..., t_idx] = u_sum[c] / w_sum; end
            for (k, v) in ldata.fields; for c in 1:size(v, 1); e_fields[k][c, Tuple(idx)..., t_idx] = f_sums[k][c] / w_sum; end; end
        end
    end

    # 4. Time-Independent Interpolation (Profiles)
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
                end
                w = 1.0 / (dist^2)
                w_sum += w
                for (k, v) in ldata.profiles; for c in 1:size(v, 1); p_sums[k][c] += v[c, p_idx] * w; end; end
            end
            for (k, v) in ldata.profiles; for c in 1:size(v, 1); e_profiles[k][c, Tuple(idx)...] = p_sums[k][c] / w_sum; end; end
        end
    end

    return ESimData(ldata.params, x_euler, u_euler, ldata.t, ldata.scalars, ldata.series, e_profiles, e_fields)
end