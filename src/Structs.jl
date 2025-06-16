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
    default_methods::Vector{String}
    shared_params::ParamDictType
    #ui_options::ParamDictType

    function SimulationConfig(sim_function::Function, shared_params::ParamDictType, methods_dict::MethodDictType, default_methods::Vector{String})
        @assert (issubset(Set(default_methods),Set(keys(methods_dict)))) "Default method is not contained in the given dictionary!"
        new(sim_function, methods_dict, default_methods, shared_params::ParamDictType)
    end
end


mutable struct SimData1D <: AbstractSimData
    x::Vector{Vector{Float64}}
    u::Vector{T} where T <:Union{Vector{Float64}, Matrix{Float64}}
    t::Vector{Float64}
    params::ParamDictType
    stats::ParamDictType
    
    function SimData1D(x::Vector{Vector{Float64}}, u::Vector{T}, t::Vector{Float64}, params::ParamDictType, stats::ParamDictType) where T <: Union{Vector{Float64}, Matrix{Float64}}
        new(x, u, t, params, stats)
    end
end

mutable struct SimData2D <: AbstractSimData
    x::Vector{Vector{NTuple{2,Float64}}}
    u::Vector{T} where T <:Union{Vector{Float64}, Matrix{Float64}}
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
    println("Types: x = " * string(typeof(x)) * " u = " * string(typeof(u)) * " t = " * string(typeof(t)))
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

end