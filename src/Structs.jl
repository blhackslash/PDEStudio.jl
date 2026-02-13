module Structs

export ParamDict, MethodDict, SimulationConfig, ESimData1D, VariedDictType, LSimData1D, UnifiedPlotData, SimData2D, createSimData, mergeParams, FixedDictType
export AbstractSimData, ParamDictType, MethodDictType, parseValue, AtomicType, AtomicTuple, load_function_from_disk, _load_function_from_string

abstract type AbstractSimData end
abstract type SimData1D <: AbstractSimData end
abstract type SimData2D <: AbstractSimData end

const AtomicType = Union{Float64, Int64, Bool, Symbol, String}
const AtomicTuple = Tuple{Vararg{AtomicType}}

const BaseVariables = ["t", "x","x1","x2","y","c"]

# Types of dictionaries
const ParamDictType = Dict{String, Any}
const MethodDictType = Dict{String, ParamDictType}
const VariedDictType = Dict{String, <:Vector}
const FixedDictType = Dict{String, Any}


# Updated Dictionary creators enforcing the right datatype
ParamDict(args...) = Dict{String, Any}(args...)
MethodDict(args...) = Dict{String, ParamDictType}(args...)

struct SimulationConfig
    sim_function::Function
    methods_dict::MethodDictType
    default_methods::Vector{String}
    shared_params::ParamDictType
    varied_params::Dict{String,<:Vector}
    """
    SimulationConfig(sim_function, shared_params, methods_dict, default_methods)

    Primary constructor for a SimulationConfig.
    """
    function SimulationConfig(
        sim_function::Function,
        shared_params::ParamDictType,
        methods_dict::MethodDictType,
        default_methods::Union{Vector{String}, String};
        varied_params::VariedDictType = Dict{String,Vector}()
    )
        all_methods = collect(keys(methods_dict))
        methods = isa(default_methods, String) ? 
                  (default_methods == "all" ? all_methods : [default_methods]) : 
                  copy(default_methods)
        
        if !haskey(shared_params, "sim_function")
            @warn "No 'sim_function' key detected... Using function name."
            shared_params["sim_function"] = string(nameof(sim_function))
        end
        
        filter!(m -> haskey(methods_dict, m), methods)       
        
        return new(sim_function, methods_dict, methods, shared_params, varied_params)
    end
end

# --- Simulation Data Structures ---

struct ESimData1D <: SimData1D

    params::ParamDictType
    x::Vector{Float64}
    u::Array{Float64,3}
    t::Vector{Float64}

    # Buckets for stats
    # [Component]
    scalars::Dict{String, Vector{Float64}} 
    # [Component, Time]
    series::Dict{String, Matrix{Float64}} 
    # [Component, Space]
    profiles::Dict{String, Matrix{Float64}} 
    # [Component, Space, Time]
    fields::Dict{String, Array{Float64, 3}}

end

struct LSimData1D <: SimData1D

    params::ParamDictType
    x::Vector{Vector{Float64}}
    u::Vector{VecOrMat}
    t::Vector{Float64}

    # Buckets for stats
    # [Component]
    scalars::Dict{String, Vector{Float64}} 
    # [Component, Time]
    series::Dict{String, Matrix{Float64}} 
    # [Component, Space]
    profiles::Dict{String, Vector{Vector{Float64}}} 
    # [Component, Space, Time]
    fields::Dict{String, Vector{Matrix{Float64}}}

end

# --- Plotting Data Structure ---

"""
    UnifiedPlotData
The cached tensor ready for plotting.
It contains the subset of data where specific parameters are fixed.
Tensor Shape: [Component, ActiveParam1, ActiveParam2, ..., Space, Time]
"""
struct UnifiedPlotData{N}
    # The Tensor Dictionary
    # Keys: "u", "x", "mass", etc.
    data::Dict{String, Array{Float64, N}}
    
    # Metadata for Axes
    active_param_keys::Vector{String}       # Names of P1, P2...
    active_param_values::Vector{Vector{Any}} # Values of P1, P2...
    
    t_vals::Vector{Float64}
    
    # Snapshot of the configuration used to create this
    fixed_params::FixedDictType 
end

# --- Constructors / Dispatch ---

function createSimData(x, u, t, params, stats)
    @warn "Types: x = " * string(typeof(x)) * " u = " * string(typeof(u)) * " t = " * string(typeof(t))
    error("Wrong input types or requested dimension not implemented yet!")
end

# 1. Eulerian Dispatch (Dense Array input)
function createSimData(x::AbstractMatrix{Float64}, u::AbstractArray{Float64,3}, t::AbstractVector{Float64}, params::ParamDictType, stats::ParamDictType)
    
    # 1. Handle Grid conversion (Matrix [Space, Time] -> Vector [Space])
    # Assuming fixed grid for Eulerian, we take the first column.
    x_vec = vec(x[:, 1])

    # 2. Create Empty Buckets (Specific types for Eulerian)
    scalars  = Dict{String, Vector{Float64}}()
    series   = Dict{String, Matrix{Float64}}()
    profiles = Dict{String, Matrix{Float64}}()
    fields   = Dict{String, Array{Float64, 3}}()

    # 3. Construct ESimData1D
    # Order: params, x, u, t, buckets...
    return ESimData1D(params, x_vec, u, t, scalars, series, profiles, fields)
end

# 2. Lagrangian Dispatch (Vector of Vectors input)
function createSimData(x::AbstractVector{<:AbstractVector{Float64}}, u::AbstractVector{<:AbstractVecOrMat}, t::AbstractVector{Float64}, params::ParamDictType, stats::ParamDictType)
    
    # 1. Standardize u to Vector{Matrix}
    # This ensures that even if u is a Vector{Vector} (1 component), it becomes Vector{Matrix} [1, Space]
    u_standardized = map(u) do step_u
        if step_u isa AbstractVector
            return reshape(step_u, 1, :) # [1, Space]
        else
            return step_u # [Component, Space]
        end
    end

    # 2. Create Empty Buckets (Specific types for Lagrangian)
    scalars  = Dict{String, Vector{Float64}}()
    series   = Dict{String, Matrix{Float64}}()
    profiles = Dict{String, Vector{Vector{Float64}}}() # Note: Vector{Vector}
    fields   = Dict{String, Vector{Matrix{Float64}}}() # Note: Vector{Matrix}

    # 3. Construct LSimData1D
    return LSimData1D(params, x, u_standardized, t, scalars, series, profiles, fields)
end

function mergeParams(shared_params::ParamDictType, methods::MethodDictType)
    merged = copy(shared_params)
    for (_, val) = methods
        merged = merge(merged, val)
    end
    return merged
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
end