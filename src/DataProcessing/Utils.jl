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
            parsed = parseValue(input_str) 
            
            # THE FIX: Only check if the base structure (Tuple or Vector) matches!
            if (T <: Tuple && parsed isa Tuple) || (T <: Vector && parsed isa Vector)
                try
                    obs[] = parsed
                catch e
                    @warn "Failed to apply value. The parameter strictly expects $T, but you provided $(typeof(parsed)). If you want to change the length of this tuple dynamically, initialize it as Observable{Any}."
                end
            else
                @warn "Type mismatch for complex input. Expected a $(T <: Tuple ? "Tuple" : "Vector"), but got $(typeof(parsed))."
            end
        else
            # Fallback for any other types
            obs[] = parse(T, input_str)
        end
    catch e
        @warn "Invalid input: Could not parse '$input_str' as $T. The value remains: $current_val"
    end
end




"""
    generate_dynamic_title(x_key, y_key, dim_idx, manager, dim_names, sel_vals)

Constructs the plot title dynamically. It lists all fixed parameters and base variables,
marks the actively plotted dimension, and allows for a user-defined override via `manager.ui`.
"""
function generate_dynamic_title(
    dim_idx::Int, 
    dim_names::Vector{String}, 
    sel_vals
)
    # 2. Build the Default Dynamic Title
    title_parts = String[]
    
    for i in 1:length(dim_names)
        name = dim_names[i]
        
        if i == dim_idx
            # This is the axis we are currently plotting along (the colon ':' in the tensor slice)
            push!(title_parts, "$name = [Axis]")
        else
            val = sel_vals[i]
            # Format floats neatly to 3 decimal places to prevent title bloat
            val_str = val isa AbstractFloat ? @sprintf("%.3f", val) : string(val)
            push!(title_parts, "$name = $val_str")
        end
    end
    
    # Join all the parts together with a separator
    return join(title_parts, " | ")
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
    
# Create the lightweight ESimData that exists ONLY in RAM
    ram_data = ESimData{D}(params, axes_list, u_exact, t_vec, Dict(), Dict(), Dict(), Dict())
    
    # THE FIX: Calculate baseline stats instantly without touching the hard drive!
    IRunPDESims._calculate_stats!(Val(:series), ram_data, ram_data.x, ram_data.u, ref_func)
    
    return ram_data
end

# ==============================================================================
# 1. TASK & CONFIGURATION ANALYSIS
# ==============================================================================

function _recombine_tuples!(params::Dict)
    tuple_groups = Dict{String, Vector{Pair{Int, Any}}}()
    keys_to_remove = String[]
    
    for (k, v) in params
        if occursin("__", k)
            parts = split(k, "__")
            if length(parts) == 2
                base_name, idx_str = parts[1], parts[2]
                idx = tryparse(Int, idx_str)
                if !isnothing(idx)
                    if !haskey(tuple_groups, base_name)
                        tuple_groups[base_name] = Pair{Int, Any}[]
                    end
                    push!(tuple_groups[base_name], idx => v)
                    push!(keys_to_remove, k)
                end
            end
        end
    end
    
    for k in keys_to_remove
        delete!(params, k)
    end
    
    for (base_name, pairs) in tuple_groups
        sort!(pairs, by = x -> x[1])
        params[base_name] = Tuple(x[2] for x in pairs)
    end
    return params
end