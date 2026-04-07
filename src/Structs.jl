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
struct NoSimData{D} <: AbstractSimData{D} 
    scalars::Dict
    series::Dict
    profiles::Dict 
    fields::Dict
end

function NoSimData(D::Int=0)
    return NoSimData{D}(Dict(), Dict(), Dict(), Dict())
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

    scalars::Dict{String, Float64} 
    series::Dict{String, Matrix{Float64}} 
    profiles::Dict{String, Array{Float64}} # [Component, Space...]
    fields::Dict{String, Array{Float64}}   # [Component, Space..., Time]
end

"""
    LSimData{D, M}
Lagrangian data where:
- D is the spatial dimension.
- M is the number of physical components.
"""
struct LSimData{D, M} <: AbstractSimData{D}
    params::ParamDict
    x::Vector{Vector{SVector{D, Float64}}} # Time -> Particles -> Space
    u::Vector{Vector{SVector{M, Float64}}} # Time -> Particles -> Components
    t::Vector{Float64}

    # The strongly typed stat dictionaries
    scalars::Dict{String, Float64} 
    series::Dict{String, Matrix{Float64}} 
    profiles::Dict{String, Vector{Vector{SVector{D, Float64}}}} 
    fields::Dict{String, Vector{Vector{SVector{M, Float64}}}}
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
"""
    resolve_simulation_function(func_name_str::String, sim_func::Union{Function, Nothing}; target_module::Module = Main)

Resolves the simulation function. Evaluates the script in the `target_module` namespace 
(defaulting to `Main`) to avoid dependency bleed into the plotting package.
"""
function resolve_simulation_function(func_name_str::String, sim_func::Union{Function, Nothing}; target_module::Module = Main)
    if !isnothing(sim_func)
        return sim_func
    end

    try
        func_file = joinpath(_SAVE_ROOT_PATH[], "SimulationFunctions", func_name_str * ".jl")
        
        if isfile(func_file)
            @info "Dynamically loading function file into $target_module: $func_file"
            # Evaluate the file in the requested module scope
            Base.include(target_module, func_file)
        else
            @warn "File $func_file not found. Assuming function '$func_name_str' is already in $target_module scope."
        end
        
        # Fetch the compiled function directly from the requested module
        return getfield(target_module, Symbol(func_name_str))
        
    catch e
        @error "Failed to dynamically resolve simulation function." exception=(e, catch_backtrace())
        return nothing
    end
end

function SimulationConfig(sim_func::String, args...; target_module::Module = Main, kwargs...)
    f = resolve_simulation_function(sim_func, nothing; target_module = target_module)
    
    if isnothing(f)
        error("Aborting: Could not resolve simulation function '$sim_func' in module $target_module.")
    end
    
    SimulationConfig(f, args...; kwargs...)
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