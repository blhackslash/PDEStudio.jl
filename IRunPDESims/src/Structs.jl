# --- 1. Type Aliases ---
const ParamDict = Dict{String, Any}
const MethodDict = Dict{String, ParamDict}
const VariedDict = Dict{String, Vector}
const FixedDict = ParamDict 

const _GRID_LOCK = Ref{Bool}(false)

const _SAVE_ROOT_PATH = Ref{String}(pwd())
const _N_GRID = Ref{Int}(100)
const _T_GRID = Ref{Int}(25)
const _REF_GRID = Ref{Int}(500)
const _TARGET_MODULE = Ref{Module}(Main)


set_space_resolution!(n::Int) = _GRID_LOCK[] ? (@warn "Grid is currently locked!") : (_N_GRID[] = n)
set_time_resolution!(n::Int) = _GRID_LOCK[] ? (@warn "Grid is currently locked!") : (_T_GRID[] = n)
set_ref_resolution!(n::Int) = _GRID_LOCK[] ? (@warn "Grid is currently locked!") : (_REF_GRID[] = n)
get_space_resolution() = _N_GRID[]
get_time_resolution() = _T_GRID[]
get_ref_resolution() = _REF_GRID[]
set_target_module!(target_module::Module) = (_TARGET_MODULE[] = target_module)

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

# A strict union covering all possible geometries of your statistics
const AbstractStatTensor{M, T} = Union{
    SVector{M, T},
    AbstractArray{SVector{M, T}},
    Vector{Vector{SVector{M, T}}}
}

# The strictly typed dictionary for SimData
const StatDict{M} = Dict{Symbol, AbstractStatTensor{M, Float64}}

# ==============================================================================
# --- 1. Abstract Hierarchy & Metadata ---
# ==============================================================================

# D = Total Spacetime Dimensions, DS = Spatial Dimensions, M = Vector Components
abstract type AbstractSimData{D, DS, M} end

struct NoSimData{D, DS, M} <: AbstractSimData{D, DS, M} 
    scalars::Dict{String, Any}
    stats::Dict{String, Any}
end

function NoSimData(D::Int=0, DS::Int=0, M::Int=0)
    return NoSimData{D, DS, M}(Dict{String, Any}(), Dict{String, Any}())
end

# DomainInfo strictly models the total D tensor shape.
struct DomainInfo{D}
    dim_keys::Tuple{Vararg{Symbol, D}}
    mins::Tuple{Vararg{Float64, D}}
    maxs::Tuple{Vararg{Float64, D}}
    spacing::Tuple{Vararg{Float64, D}}
    time_dim::Union{Nothing,Symbol}
    
    # --- NEW: Local Registry ---
    stat_registry::Dict{Symbol, Union{Symbol, Vector{Symbol}}} 
end

# ==============================================================================
# --- 2. D-Dimensional Data Structures ---
# ==============================================================================

mutable struct ESimData{D, DS, M} <: AbstractSimData{D, DS, M}
    params::ParamDict
    domain::DomainInfo{D}
    axes::NTuple{D, Vector{Float64}}
    u::Array{SVector{M, Float64}, D}
    stats::StatDict{M}  # <-- Strictly typed and Symbolic!
end

mutable struct LSimData{D, DS, M} <: AbstractSimData{D, DS, M}
    params::ParamDict
    domain::DomainInfo{D}
    t::Vector{Float64}
    x::Vector{Vector{SVector{DS, Float64}}}
    u::Vector{Vector{SVector{M, Float64}}}
    stats::StatDict{M}  # <-- Strictly typed and Symbolic!
end

nice_string(s::Symbol) = nice_string(String(s))

function safe_string(s::AbstractString)
    # Replace whitespace and hyphens with underscores, then lowercase
    s_clean = replace(strip(s), r"[\s-]+" => "_")
    return lowercase(s_clean)
end

function nice_string(s::AbstractString)
    words = split(s, "_")
    formatted_words = map(words) do word
        # If the word has more than one uppercase letter, assume it's an acronym/code and keep it as-is.
        if count(isuppercase, word) > 1
            return word
        else
            return titlecase(word)
        end
    end
    return join(formatted_words, " ")
end

mutable struct SimulationConfig{F <: Function, A <: Union{Function, Nothing}}
    simulation_func::F
    simulation_name::Symbol # <-- Store strictly as Symbol
    reference_func::A 
    reference_name::Union{Symbol, Nothing} # <-- Store strictly as Symbol
    shared_params::ParamDict
    methods_dict::MethodDict
    default_methods::Vector{String}
    varied_params::VariedDict
end

# Update the signature to accept 'nothing' for the reference function name
function SimulationConfig(
    sim_func_name::String, 
    ref_func_name::Union{String, Nothing}, 
    shared::ParamDict, 
    methods::MethodDict, 
    defaults::Vector{String};
    varied_params::VariedDict = createVariedDict(),
)
    target_module = _TARGET_MODULE[]
    
    # 1. Safe string conversion, then immediately to Symbol
    ref_name_sym = isnothing(ref_func_name) ? nothing : Symbol(safe_string(ref_func_name))
    sim_name_sym = Symbol(safe_string(sim_func_name))

    # 2. Resolve Simulation Function via Symbol
    sim_f = resolve_dynamic_function(sim_name_sym)
    if isnothing(sim_f)
        error("Aborting: Could not resolve simulation function '$sim_name_sym' in module $target_module.")
    end

    # 3. Resolve Reference Factory Function via Symbol (No more invokelatest!)
    ref_factory = resolve_dynamic_function(ref_name_sym)
    ref_f = isnothing(ref_factory) ? nothing : ref_factory(shared)
    
    # 4. AUTO-INJECT: Add the reference method to the methods dictionary if it exists
    if !isnothing(ref_func_name)
        # Use the string for the dictionary key, not the symbol
        ns = nice_string(safe_string(ref_func_name)) 
        if !haskey(methods, ns)
            methods[ns] = ParamDict()
        end
    end

    return SimulationConfig{typeof(sim_f), typeof(ref_f)}(
        sim_f, sim_name_sym, ref_f, ref_name_sym, shared, methods, defaults, varied_params
    )
end

# Fallback constructor for when no reference function is provided
function SimulationConfig(
    sim_func_name::String, 
    shared::ParamDict, 
    methods::MethodDict, 
    defaults::Vector{String}; 
    varied_params::VariedDict = createVariedDict(),
)
    return SimulationConfig(sim_func_name, nothing, shared, methods, defaults; varied_params = varied_params)
end

# Simplify wrappers to cast strings to symbols before lookup
resolve_simulation_function(func_name_str::Union{String, Symbol}, sim_func::Union{Function, Nothing}) = resolve_dynamic_function(Symbol(func_name_str), sim_func)
resolve_reference_function(func_name::Union{String, Nothing, Symbol}) = isnothing(func_name) ? nothing : resolve_dynamic_function(Symbol(func_name))

"""
    resolve_dynamic_function(func_name::Union{Symbol, Nothing}, provided_func::Union{Function, Nothing} = nothing)

Pure lookup mechanism: fetches a compiled function object directly from the target module namespace.
"""
function resolve_dynamic_function(
    func_name::Union{Symbol, Nothing}, 
    provided_func::Union{Function, Nothing} = nothing
)
    target_module = _TARGET_MODULE[]
    
    if !isnothing(provided_func)
        return provided_func
    end
    
    if isnothing(func_name) || func_name === :none
        return nothing 
    end
    
    try
        # Native symbol lookup directly from memory
        return getglobal(target_module, func_name)
    catch e
        @warn "Failed to resolve function '$func_name' from $target_module."
        return nothing
    end
end