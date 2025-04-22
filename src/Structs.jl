module Structs

export ParamDict, MethodDict, SimulationConfig, SimData1D, SimData2D, createSimData, mergeParams
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
    shared_params::ParamDictType
    ui_options::ParamDictType

    function SimulationConfig(sim_function::Function, methods_dict::MethodDictType, shared_params::ParamDictType, default_method::String)
        @assert (default_method in keys(methods_dict)) "Default method is not contained in the given dictionary!"
        new(sim_function, methods_dict, default_method, shared_params::ParamDictType, ParamDict())
    end
end

mutable struct SimData1D <: AbstractSimData
    x::Vector{Vector{Float64}}
    u::Vector{Vector{Float64}}
    t::Vector{Float64}
    params::ParamDictType
    stats::ParamDictType
    
    function SimData1D(x::Vector{Vector{Float64}}, u::Vector{Vector{Float64}}, t::Vector{Float64}, params::ParamDictType)
        new(x, u, t, params, ParamDict())
    end
end

mutable struct SimData2D <: AbstractSimData
    x::Vector{Vector{NTuple{2,Float64}}}
    u::Vector{Vector{Float64}}
    t::Vector{Float64}
    params::ParamDictType
    stats::ParamDictType

    function SimData2D(x::Vector{Vector{NTuple{2,Float64}}}, u::Vector{Vector{Float64}}, t::Vector{Float64}, params::ParamDictType)
        new(x, u, t, params, ParamDict())
    end
end
function mergeParams(shared_params::ParamDictType, methods::MethodDictType)
    merged = copy(shared_params)
    for (_, val) = methods
        merged = merge(merged, val)
    end
    return merged
end

function createSimData(x, u, t, params)
    error("Wrong input types or requested dimension not implemented yet!")
end

function createSimData(x::Vector{Vector{Float64}}, u::Vector{Vector{Float64}}, t::Vector{Float64}, params::ParamDictType)
    SimData1D(x, u, t, params)
end

function createSimData(x::Vector{Vector{Tuple{Float64,Float64}}}, u::Vector{Vector{Tuple{Float64,Float64}}}, t::Vector{Float64}, params::ParamDictType)
    SimData2D(x, u, t, params)
end

end