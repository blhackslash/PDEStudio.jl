module Structs

export ParamDict, MethodDict, SimulationConfig, SimData1D, SimData2D, createSimData, mergeMethodDicts
export AbstractSimData, ParamDictType, MethodDictType

abstract type AbstractSimData end

# Types of dictionaries
const ParamDictType = Dict{String, Any}
const MethodDictType = Dict{String, ParamDictType}

# Updated Dictionary creators enforcing the right datatype
ParamDict(args...) = Dict{String, Any}(args...)
MethodDict(args...) = Dict{String, ParamDictType}(args...)

struct SimulationConfig
    sim_function::Function
    methods_dict::MethodDictType
    default_method::String

    function SimulationConfig(sim_function::Function, methods_dict::MethodDictType, default_method::String)
        @assert (default_method in keys(methods_dict)) "Default method is not contained in the given dictionary!"
        new(sim_function, methods_dict, default_method)
    end
end

struct SimData1D <: AbstractSimData
    x::Vector{Vector{Float64}}
    u::Vector{Vector{Float64}}
    t::Vector{Float64}
    param::ParamDictType
    stats::ParamDictType
    
    function SimData1D(x::Vector{Vector{Float64}}, u::Vector{Vector{Float64}}, t::Vector{Float64}, param::ParamDictType)
        new(x, u, t, param, ParamDict())
    end
end

struct SimData2D <: AbstractSimData
    x::Vector{Matrix{Float64}}
    u::Vector{Matrix{Float64}}
    t::Vector{Float64}
    param::ParamDictType
    stats::ParamDictType

    function SimData2D(x::Vector{Matrix{Float64}}, u::Vector{Matrix{Float64}}, t::Vector{Float64}, param::ParamDictType)
        new(x, u, t, param, ParamDict())
    end
end

function mergeMethodDicts(shared_param::ParamDictType, methods::MethodDictType)
    merged = MethodDict()
    for (method, param) = methods
        merged[method] = merge(shared_param, param)
    end
    return merged
end

function SimulationConfig(sim_function::Function, shared_param::ParamDictType, methods_dict::MethodDictType, default_method::String)
    merged = mergeMethodDicts(shared_param, methods_dict)
    return SimulationConfig(sim_function, merged, default_method)
end

function createSimData(x, u, t, param)
    error("Wrong input types or requested dimension not implemented yet!")
end

function createSimData(x::Vector{Vector{Float64}}, u::Vector{Vector{Float64}}, t::Vector{Float64}, param::ParamDictType)
    SimData1D(x, u, t, param)
end

function createSimData(x::Vector{Matrix{Float64}}, u::Vector{Matrix{Float64}}, t::Vector{Float64}, param::ParamDictType)
    SimData2D(x, u, t, param)
end

end