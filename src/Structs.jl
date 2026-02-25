module Structs

import GLMakie: Observable

export PlotManager, NestedObsDict, create_plot_manager

using StaticArrays, LinearAlgebra, GLMakie

export SimulationConfig, ESimData, LSimData, AbstractSimData, AbstractSimulator
export createSimData, Simulator

const AtomicType = Union{Float64, Int64, Bool, Symbol, String}
const AtomicTuple = Tuple{Vararg{AtomicType}}

const BaseVariables = ["c","x","y","z","t"]
const VariableNames = ["Component","Space(X)","Space(Y)","Space(Z)","Time"]

# Types of dictionaries
const ParamDictType = Dict{String, Any}
const MethodDictType = Dict{String, ParamDictType}
const VariedDictType = Dict{String, <:Vector}
const FixedDictType = Dict{String, Any}
const NestedObsDict = Dict{String, Dict{String, Observable}}


# Updated Dictionary creators enforcing the right datatype
ParamDict(args...) = Dict{String, Any}(args...)
MethodDict(args...) = Dict{String, ParamDictType}(args...)

# --- 1. Abstract Hierarchy ---
abstract type AbstractSimData{D} end
abstract type AbstractSimulator{D} end

# Fix NoSimData recursion
struct NoSimData{D} <: AbstractSimData{D} end
function NoSimData(D::Int)
    @warn "No Simulation Data created for Dimension $D!"
    return NoSimData{D}()
end

# --- 2. D-Dimensional Data Structures ---

"""
    ESimData{D}
Eulerian data where spatial grids are typically dense arrays.
x: D-dimensional Array
profiles: D-dimensional Matrix/Array per component
"""
struct ESimData{D} <: AbstractSimData{D}
    params::Dict{String, Any}
    x::Array{Float64, D}          # 1D -> Vector, 2D -> Matrix
    u::Array{Float64, D+2}        # [Component, Space..., Time]
    t::Vector{Float64}
    stats::Dict{String, Any}

    scalars::Dict{String, Vector{Float64}} 
    series::Dict{String, Matrix{Float64}} 
    profiles::Dict{String, Array{Float64, D+1}} # [Component, Space...]
    fields::Dict{String, Array{Float64, D+2}}   # [Component, Space..., Time]
end

"""
    LSimData{D}
Lagrangian data where x is a vector of positions.
Each position is an SVector of size D.
"""
struct LSimData{D} <: AbstractSimData{D}
    params::Dict{String, Any}
    x::Vector{Vector{SVector{D, Float64}}} # Time -> Particles -> Position
    u::Vector{Vector{Matrix{Float64}}}     # Time -> Particles -> [Comp, State]
    t::Vector{Float64}
    stats::Dict{String, Any}

    scalars::Dict{String, Vector{Float64}} 
    series::Dict{String, Matrix{Float64}} 
    profiles::Dict{String, Vector{Vector{SVector{D, Float64}}}} 
    fields::Dict{String, Vector{Vector{Matrix{Float64}}}}
end

# --- 3. The Generalized Functor ---

struct Simulator{D} <: AbstractSimulator{D}
    f::Function
end

# Enforce that the output MUST be a subtype of AbstractSimData{D}
function (sim::Simulator{D})(params::Dict{String, Any})::AbstractSimData{D} where D
    result = sim.f(params)
    if isnothing(result)
        return NoSimData(D)
    end
    return result
end

# --- 4. SimulationConfig with Dimension Dispatch ---

struct SimulationConfig{D, F <: AbstractSimulator{D}}
    sim_function::F
    methods_dict::Dict{String, Dict{String, Any}}
    default_methods::Vector{String}
    shared_params::Dict{String, Any}
    varied_params::Dict{String, Vector}

    function SimulationConfig(
        sim_input::Union{Function, AbstractSimulator},
        shared_params::Dict{String, Any},
        methods_dict::Dict{String, Dict{String, Any}},
        default_methods::Union{Vector{String}, String};
        varied_params::Dict{String, Vector} = Dict{String, Vector}()
    )
        # Determine D from params or metadata
        # D = min(get(shared_params,"dimension",Inf))
        D = get(shared_params, "dimension", 1)
        
        # Wrap raw function if necessary
        sim_functor = sim_input isa Function ? Simulator{D}(sim_input) : sim_input
        
        # Method handling
        all_methods = collect(keys(methods_dict))
        methods = default_methods isa String ? 
                  (default_methods == "all" ? all_methods : [default_methods]) : 
                  copy(default_methods)
        
        new{D, typeof(sim_functor)}(sim_functor, methods_dict, methods, shared_params, varied_params)
    end
end

# --- 5. Dispatch for createSimData ---

# Eulerian 1D
function createSimData(x::Vector{Float64}, u::Array{Float64, 3}, t::Vector{Float64}, params::Dict, stats::Dict)
    return ESimData{1}(params, x, u, t, stats, Dict(), Dict(), Dict(), Dict())
end

# Eulerian 2D
function createSimData(x::Matrix{Float64}, u::Array{Float64, 4}, t::Vector{Float64}, params::Dict, stats::Dict)
    return ESimData{2}(params, x, u, t, stats, Dict(), Dict(), Dict(), Dict())
end

# Lagrangian D-Dimensional
function createSimData(x::Vector{Vector{SVector{D, Float64}}}, u, t, params, stats) where D
    return LSimData{D}(params, x, u, t, stats, Dict(), Dict(), Dict(), Dict())
end
# Type Alias for Scope -> Key -> Observable


# In Controls.jl
mutable struct PlotManager
    simulation::NestedObsDict
    ui::NestedObsDict
    controls::Dict{String, Observable} # NEW: Flat Dict for dynamic widget state
    methods::Observable{Vector{String}}
    last_run_params::Dict{String, Any}

    function PlotManager(sim, ui, ctrl, methods, last_run)
        new(sim, ui, ctrl, methods, last_run)
    end
end

function create_plot_manager(sim_config::SimulationConfig{D,F}, ui_raw::Dict) where {F,D}
    vars = [keys(sim_config.varied_params) ; [BaseVariables[1]] ; BaseVariables[2:D+1] ; [BaseVariables[end]]]
    sim_obs = NestedObsDict()
    sim_obs["shared"] = Dict(k => Observable(v) for (k, v) in sim_config.shared_params)
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => Observable(v) for (k, v) in m_params)
    end

    ui_obs = NestedObsDict()
    for (scope, keys_dict) in ui_raw
        ui_obs[scope] = Dict(k => Observable(v) for (k, v) in keys_dict)
    end

    methods_obs = Observable(copy(sim_config.default_methods))

    # Initialize empty; populated by create_plot_controls!
    controls_obs = Dict{String, Observable}()

    return PlotManager(sim_obs, ui_obs, controls_obs, methods_obs, copy(sim_config.shared_params))
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

# # 1. Eulerian Dispatch (Dense Array input)
# function createSimData(x::AbstractMatrix{Float64}, u::AbstractArray{Float64,3}, t::AbstractVector{Float64}, params::ParamDictType, stats::ParamDictType)
    
#     # 1. Handle Grid conversion (Matrix [Space, Time] -> Vector [Space])
#     # Assuming fixed grid for Eulerian, we take the first column.
#     x_vec = vec(x[:, 1])

#     # 2. Create Empty Buckets (Specific types for Eulerian)
#     scalars  = Dict{String, Vector{Float64}}()
#     series   = Dict{String, Matrix{Float64}}()
#     profiles = Dict{String, Matrix{Float64}}()
#     fields   = Dict{String, Array{Float64, 3}}()

#     # 3. Construct ESimData1D
#     # Order: params, x, u, t, buckets...
#     return ESimData1D(params, x_vec, u, t, scalars, series, profiles, fields)
# end

# # 2. Lagrangian Dispatch (Vector of Vectors input)
# function createSimData(x::AbstractVector{<:AbstractVector{Float64}}, u::AbstractVector{<:AbstractVecOrMat}, t::AbstractVector{Float64}, params::ParamDictType, stats::ParamDictType)
    
#     # 1. Standardize u to Vector{Matrix}
#     # This ensures that even if u is a Vector{Vector} (1 component), it becomes Vector{Matrix} [1, Space]
#     u_standardized = map(u) do step_u
#         if step_u isa AbstractVector
#             return reshape(step_u, 1, :) # [1, Space]
#         else
#             return step_u # [Component, Space]
#         end
#     end

#     # 2. Create Empty Buckets (Specific types for Lagrangian)
#     scalars  = Dict{String, Vector{Float64}}()
#     series   = Dict{String, Matrix{Float64}}()
#     profiles = Dict{String, Vector{Vector{Float64}}}() # Note: Vector{Vector}
#     fields   = Dict{String, Vector{Matrix{Float64}}}() # Note: Vector{Matrix}

#     # 3. Construct LSimData1D
#     return LSimData1D(params, x, u_standardized, t, scalars, series, profiles, fields)
# end

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