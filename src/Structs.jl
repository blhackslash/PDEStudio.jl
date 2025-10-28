module Structs

export ParamDict, MethodDict, SimulationConfig, SimData1D, SimData2D, createSimData, mergeParams
export AbstractSimData, ParamDictType, MethodDictType, parseValue, AtomicType, AtomicTuple, load_function_from_disk, _load_function_from_string

abstract type AbstractSimData end

# Types of dictionaries
const ParamDictType = Dict{String, Any}
const MethodDictType = Dict{String, ParamDictType}
const AtomicType = Union{Float64, Int64, Bool, Symbol, String}
const AtomicTuple = Tuple{Vararg{AtomicType}}

# Updated Dictionary creators enforcing the right datatype
ParamDict(args...) = Dict{String, Any}(args...)
MethodDict(args...) = Dict{String, ParamDictType}(args...)

struct SimulationConfig
    sim_function::Function
    methods_dict::MethodDictType
    default_methods::Vector{String}
    shared_params::ParamDictType

    """
    SimulationConfig(sim_function, shared_params, methods_dict, default_methods)

    Primary constructor for a SimulationConfig.
    """
    function SimulationConfig(
        sim_function::Function,
        shared_params::ParamDictType,
        methods_dict::MethodDictType,
        default_methods::Union{Vector{String}, String}
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
        
        return new(sim_function, methods_dict, methods, shared_params)
    end
end


mutable struct SimData1D <: AbstractSimData
    x::Vector{Vector{Float64}}
    u::Vector{VecOrMat}
    t::Vector{Float64}
    params::ParamDictType
    stats::ParamDictType
    
    function SimData1D(x::Vector{Vector{Float64}}, u::Vector{T}, t::Vector{Float64}, params::ParamDictType, stats::ParamDictType) where T <: Union{Vector{Float64}, Matrix{Float64}}
        new(x, u, t, params, stats)
    end
end

mutable struct SimData2D <: AbstractSimData
    x::Vector{Vector{NTuple{2,Float64}}}
    u::Vector{VecOrMat}
    t::Vector{Float64}
    params::ParamDictType
    stats::ParamDictType

    function SimData2D(x::Vector{Vector{NTuple{2,Float64}}}, u::Vector{T}, t::Vector{Float64}, params::ParamDictType, stats::ParamDictType) where T <: Union{Vector{Float64}, Matrix{Float64}}
        new(x, u, t, params, stats)
    end
end
function mergeParams(shared_params::ParamDictType, methods::MethodDictType)
    merged = copy(shared_params)
    for (_, val) = methods
        merged = merge(merged, val)
    end
    return merged
end

function createSimData(x, u, t, params, stats)
    @warn "Types: x = " * string(typeof(x)) * " u = " * string(typeof(u)) * " t = " * string(typeof(t))
    error("Wrong input types or requested dimension not implemented yet!")
end

function createSimData(x::Vector{Vector{Float64}}, u::Vector{T}, t::Vector{Float64}, params::ParamDictType, stats::ParamDictType) where T <: Union{Vector{Float64}, Matrix{Float64}}
    SimData1D(x, u, t, params, stats)
end

function createSimData(x::Vector{Vector{Tuple{Float64,Float64}}}, u::Vector{T}, t::Vector{Float64}, params::ParamDictType, stats::ParamDictType) where T <: Union{Vector{Float64}, Matrix{Float64}}
    SimData2D(x, u, t, params, stats)
end

function createSimData(x, u, t::Vector{Float64}, params::ParamDictType)
    createSimData(x, u, t, params, ParamDict())
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