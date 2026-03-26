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
