const AtomicType = Union{Float64, Int64, Bool, Symbol, String}
const AtomicTuple = Tuple{Vararg{AtomicType}}

const BaseVariables = ["c","x","y","z","t"]
const VariableNames = ["Component","Space(X)","Space(Y)","Space(Z)","Time"]
const VariableControls = [:menu,:slider,:slider,:slider,:slider]

# --- 1. Define the Dictionary Structs ---

# --- 1. Type Aliases ---
const ParamDict = Dict{String, Any}
const MethodDict = Dict{String, ParamDict}
const VariedDict = Dict{String, <:Vector}
const FixedDict = ParamDict 
const NestedObsDict = Dict{String, Dict{String, Observable}}

# --- 2. Explicit Creator Functions ---

# ParamDict Creators
createParamDict(kv::Pair{String, <:Any}...) = ParamDict(kv...)
createParamDict(kv) = ParamDict(kv) # Catches generators like (k => v for ...)
createParamDict() = ParamDict()

# MethodDict Creators
createMethodDict(kv::Pair{String, ParamDict}...) = MethodDict(kv...)
createMethodDict(kv) = MethodDict(kv)
createMethodDict() = MethodDict()

# VariedDict Creators
createVariedDict(kv::Pair{String, <:Vector}...) = VariedDict(kv...)
createVariedDict(kv) = VariedDict(kv)
createVariedDict() = VariedDict()

# --- 1. Abstract Hierarchy ---
abstract type AbstractSimData{D} end

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
    params::ParamDict
    x::Array{Float64, D}          # 1D -> Vector, 2D -> Matrix
    u::Array{Float64}        # [Component, Space..., Time]
    t::Vector{Float64}

    scalars::Dict{String, Vector{Float64}} 
    series::Dict{String, Matrix{Float64}} 
    profiles::Dict{String, Array{Float64}} # [Component, Space...]
    fields::Dict{String, Array{Float64}}   # [Component, Space..., Time]
end

"""
    LSimData{D}
Lagrangian data where x is a vector of positions.
Each position is an SVector of size D.
"""
struct LSimData{D} <: AbstractSimData{D}
    params::ParamDict
    x::Vector{Vector{SVector{D, Float64}}} # Time -> Particles -> Position
    u::Vector{Vector{Matrix{Float64}}}     # Time -> Particles -> [Comp, State]
    t::Vector{Float64}

    scalars::Dict{String, Vector{Float64}} 
    series::Dict{String, Matrix{Float64}} 
    profiles::Dict{String, Vector{Vector{SVector{D, Float64}}}} 
    fields::Dict{String, Vector{Vector{Matrix{Float64}}}}
end

# --- 4. SimulationConfig with Dimension Dispatch ---

"""
    SimulationConfig
Holds the master configuration for a plot orchestrator run.
"""
mutable struct SimulationConfig{F <: Function} # <-- Removed D
    simulation_func::F
    shared_params::ParamDict
    methods_dict::MethodDict
    default_methods::Vector{String}
    varied_params::VariedDict
end

function SimulationConfig(
    sim_func::F, 
    shared::ParamDict, 
    methods::MethodDict, 
    defaults::Vector{String}; 
    varied_params::VariedDict = VariedDict()
) where {F <: Function}
    SimulationConfig{F}(sim_func, shared, methods, defaults, varied_params)
end

# --- 5. Dispatch for createSimData ---

# function createSimData(x, u, t, params, stats)
#     @warn "Types: x = " * string(typeof(x)) * " u = " * string(typeof(u)) * " t = " * string(typeof(t))
#     error("Wrong input types or requested dimension not implemented yet!")
# end

# Eulerian 1D
function createSimData(x::Vector{Float64}, u::Array{Float64, 3}, t::Vector{Float64}, params::Dict)
    return ESimData{1}(params, x, u, t, Dict(), Dict(), Dict(), Dict())
end
# Eulerian 1D
function createSimData(x::Matrix{Float64}, u::Array{Float64, 3}, t::Vector{Float64}, params::Dict)
    @warn "x-input in matrixform but u given eulerian"
    return ESimData{1}(params, x[:,1], u, t, Dict(), Dict(), Dict(), Dict())
end

# Eulerian 2D
function createSimData(x::Matrix{Float64}, u::Array{Float64, 4}, t::Vector{Float64}, params::Dict)
    return ESimData{2}(params, x, u, t, Dict(), Dict(), Dict(), Dict())
end

# Lagrangian D-Dimensional
function createSimData(x::Vector{Vector{SVector{D, Float64}}}, u, t, params) where D
    return LSimData{D}(params, x, u, t, Dict(), Dict(), Dict(), Dict())
end

# --- Structs.jl / DataProcessing.jl additions ---

"""
    createSimData(x::Matrix{Float64}, u::Matrix{Float64}, t, params, stats)

Specialized 1D Lagrangian constructor. 
Handles raw Matrices for both position (x) and displacement (u).
"""
function createSimData(
    x::Matrix{Float64}, 
    u::Matrix{Float64}, 
    t::AbstractVector{Float64}, 
    params::ParamDict, 
)
    n_particles, n_time = size(x)
    
    # 1. Standardize x: Matrix [P, T] -> Vector{Vector{SVector{1}}}
    # Inner vector represents all particles at one time step 
    x_standardized = [ [SVector{1, Float64}(x[p, t_idx]) for p in 1:n_particles] for t_idx in 1:n_time ]

    # 2. Standardize u: Matrix [P, T] -> Vector{Vector{Matrix}}
    # LSimData expects Vector{Vector{Matrix}} 
    # We treat the Matrix input as a single component (1, Particles) per time step [cite: 18]
    u_standardized = [ [reshape(u[:, t_idx], 1, :)] for t_idx in 1:n_time ]

    return LSimData{1}(
        params, 
        x_standardized, 
        u_standardized, 
        t, 
        Dict(), Dict(), Dict(), Dict()
    )
end

"""
    createSimData(x::Matrix{SVector{D, Float64}}, u::AbstractArray{T, 3}, ...)

Generalized Multi-D Lagrangian constructor for constant particle counts.
"""
function createSimData(
    x::Matrix{SVector{D, Float64}}, 
    u::AbstractArray{T, 3}, 
    t::AbstractVector{Float64}, 
    params::ParamDict, 
) where {D, T}
    
    n_particles, n_time = size(x)
    
    # Standardize x into Vector of time-step Vectors 
    x_standardized = [ x[:, i] for i in 1:n_time ]

    # Standardize u: [Comp, Part, Time] -> Vector of [Comp, Part] Matrices [cite: 4, 18]
    # We wrap each Matrix in a Vector to match the Time -> Particles -> [Comp, State] nesting 
    u_standardized = [ [u[:, :, i]] for i in 1:n_time ]

    return LSimData{D}(
        params, 
        x_standardized, 
        u_standardized, 
        t, 
        Dict(), Dict(), Dict(), Dict()
    )
end

"""
    createSimData(x::Vector{Vector{Float64}}, u::Vector{Matrix{Float64}}, t::Vector{Float64}, params::Dict)

Specialized 1D Lagrangian constructor for Vector of Vectors / Vector of Matrices input.
Translates flat 1D particle tracks into the generalized Multi-D SVector structure.
"""
function createSimData(
    x::Vector{Vector{Float64}}, 
    u::Vector{Matrix{Float64}}, 
    t::Vector{Float64}, 
    params::ParamDict
)
    # 1. Map positions to 1D SVectors (Time -> Particles -> Position)
    x_standardized = [ [SVector{1, Float64}(pos) for pos in step_x] for step_x in x ]
    
    # 2. Map u states (Time -> Particles -> [Comp, State])
    # step_u is [n_comp, n_particles]. Target is a Vector of [n_comp, 1] per particle.
    u_standardized = map(u) do step_u
        n_comp, n_particles = size(step_u)
        [reshape(step_u[:, p], n_comp, 1) for p in 1:n_particles]
    end

    return LSimData{1}(
        params, 
        x_standardized, 
        u_standardized, 
        t, 
        Dict(), Dict(), Dict(), Dict()
    )
end

# In Controls.jl / Structs.jl
mutable struct PlotManager 
    simulation::NestedObsDict
    ui::NestedObsDict
    config::ParamDict
    controls::Dict{String, Observable} 
    methods::Observable{Vector{String}}
    plot_vars::Vector{String}
    last_run_params::ParamDict
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
    fixed_params::FixedDict 
end