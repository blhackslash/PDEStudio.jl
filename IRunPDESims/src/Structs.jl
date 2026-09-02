# --- 1. Type Aliases ---
const ParamDict = Dict{Symbol, Any}
const MethodDict = Dict{Symbol, ParamDict}
const VariedDict = Dict{Symbol, Vector}
const FixedDict = ParamDict 

const _SAVE_ROOT_PATH = Ref{String}(pwd())
const _TARGET_MODULE = Ref{Module}(Main)

set_target_module!(target_module::Module) = (_TARGET_MODULE[] = target_module)
get_target_module() = _TARGET_MODULE[]

# --- 2. Explicit Creator Functions ---
# Converts any generic iterator or mixed string/symbol inputs into strictly typed Symbol-keyed dictionaries

# ParamDict Creators
create_param_dict(kv::Pair...) = ParamDict(Symbol(k) => v for (k, v) in kv)
create_param_dict(kv) = ParamDict(Symbol(k) => v for (k, v) in kv) 
create_param_dict() = ParamDict()

# MethodDict Creators
create_method_dict(kv::Pair...) = MethodDict(Symbol(k) => ParamDict(Symbol(ki) => vi for (ki, vi) in v) for (k, v) in kv)
create_method_dict(kv) = MethodDict(Symbol(k) => ParamDict(Symbol(ki) => vi for (ki, vi) in v) for (k, v) in kv)
create_method_dict() = MethodDict()

# VariedDict Creators
create_varied_dict(kv::Pair...) = VariedDict(Symbol(k) => v for (k, v) in kv)
create_varied_dict(kv) = VariedDict(Symbol(k) => v for (k, v) in kv)
create_varied_dict() = VariedDict()


# ==============================================================================
# --- 1. Abstract Hierarchy & Metadata ---
# ==============================================================================

# 1. Abstract Hierarchy (Now with T)
abstract type AbstractSimData{D, DS, M, T <: Real} end 

struct NoSimData <: AbstractSimData{0, 0, 0, Real} end

const AbstractStatTensor{M, T} = Union{
    SVector{M, T},
    AbstractArray{SVector{M, T}},
    Vector{Vector{SVector{M, T}}} 
}
const StatDict{M, T} = Dict{Symbol, AbstractStatTensor{M, T}} 

# 2. Modernized DomainInfo (Using SVector and T)
struct DomainInfo{D, T <: Real}
    dim_keys::Tuple{Vararg{Symbol, D}}
    mins::SVector{D, T}
    maxs::SVector{D, T}
    spacing::SVector{D, T}
    time_dim::Union{Nothing,Symbol}
    stat_registry::Dict{Symbol, Union{Symbol, Vector{Symbol}}} 
end

# ==============================================================================
# --- 2. D-Dimensional Data Structures ---
# ==============================================================================

mutable struct ESimData{D, DS, M, T} <: AbstractSimData{D, DS, M, T}
    params::ParamDict
    domain::DomainInfo{D, T} # You can optionally parameterize DomainInfo with T as well
    axes::NTuple{D, Vector{T}}
    u::Array{SVector{M, T}, D}
    stats::StatDict{M, T}
end

mutable struct LSimData{D, DS, M, T} <: AbstractSimData{D, DS, M, T}
    params::ParamDict
    domain::DomainInfo{D, T}
    t::Vector{T}
    x::Vector{Vector{SVector{DS, T}}}
    u::Vector{Vector{SVector{M, T}}}
    stats::StatDict{M, T} 
end

mutable struct SimulationConfig{F <: Function, A <: Union{Function, Nothing}, P <: Function}
    simulation_func::F
    simulation_name::Symbol
    reference_func::A 
    reference_name::Union{Symbol, Nothing}
    post_process_func::P
    post_process_name::Union{Symbol, Nothing}
    shared_params::ParamDict
    methods_dict::MethodDict
    active_methods::Vector{Symbol}
    varied_params::VariedDict
    source_files::Vector{String}
end

function SimulationConfig(
    sim_func_name::Union{String, Symbol},  
    shared::Dict, 
    methods::Dict, 
    defaults::Vector;
    varied_params::Dict = create_varied_dict(),
    ref_func_name::Union{String, Symbol, Nothing} = nothing,
    post_process_name::Union{String, Symbol, Nothing} = nothing,
    source_files::Union{<:AbstractString, Vector{String}} = String[] # THE FIX: Optional input
)
    target_module = _TARGET_MODULE[]
    
    # 1. Safe string conversion to Symbol
    ref_name_sym = isnothing(ref_func_name) ? nothing : Symbol(ref_func_name)
    sim_name_sym = Symbol(sim_func_name)
    post_name_sym = isnothing(post_process_name) ? nothing : Symbol(post_process_name)

    # Convert generic dictionaries to enforced Symbol-keyed dictionaries
    shared_sym   = ParamDict(Symbol(k) => v for (k, v) in shared)
    methods_sym  = MethodDict(Symbol(k) => ParamDict(Symbol(ki) => vi for (ki, vi) in v) for (k, v) in methods)
    varied_sym   = VariedDict(Symbol(k) => v for (k, v) in varied_params)
    defaults_sym = Symbol.(defaults)
    for (_, m_dict) = methods_sym
        if haskey(m_dict,:ignore)
            Symbol.(m_dict[:ignore])
        end
    end

    # 2. Resolve Dynamic Functions
    sim_f = resolve_dynamic_function(sim_name_sym)
    if isnothing(sim_f)
        error("Aborting: Could not resolve simulation function '$sim_name_sym' in module $target_module.")
    end

    ref_factory = resolve_dynamic_function(ref_name_sym)
    ref_f = isnothing(ref_factory) ? nothing : ref_factory(shared_sym)
    
    post_f = resolve_dynamic_function(post_name_sym)
    post_func = isnothing(post_f) ? (data) -> false : post_f

    src_files = source_files isa AbstractString ? [String(source_files)] : String.(source_files)

    return SimulationConfig{typeof(sim_f), typeof(ref_f), typeof(post_func)}(
        sim_f, sim_name_sym, ref_f, ref_name_sym, post_func, post_name_sym, 
        shared_sym, methods_sym, defaults_sym, varied_sym, src_files
    )
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