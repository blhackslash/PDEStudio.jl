# --- 1. Type Aliases ---
const ParamDict = Dict{String, Any}
const MethodDict = Dict{String, ParamDict}
const VariedDict = Dict{String, Vector}
const FixedDict = ParamDict 

const _GRID_LOCK = Ref{Bool}(false)

const _SAVE_ROOT_PATH = Ref{String}(pwd())
const _SIM_ROOT_PATH = Ref{String}(pwd())
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
set_sim_path!(path::String) = (_SIM_ROOT_PATH[] = path)
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
    
    # --- NEW: Local Registry ---
    stat_registry::Dict{Symbol, Union{Symbol, Vector{Symbol}}} 
end

# ==============================================================================
# --- 2. D-Dimensional Data Structures ---
# ==============================================================================

mutable struct ESimData{D, DS, M} <: AbstractSimData{D, DS, M}
    params::ParamDict
    domain::DomainInfo{D}
    axes::NTuple{D, Vector{Float64}}  # Unified axes for all dimensions
    u::Array{SVector{M, Float64}, D}  # The generalized spacetime tensor
    stats::Dict{String, Any}          # Unified storage for ALL reduced statistics
end

mutable struct LSimData{D, DS, M} <: AbstractSimData{D, DS, M}
    params::ParamDict
    domain::DomainInfo{D}
    t::Vector{Float64}                # Time remains explicitly separated
    x::Vector{Vector{SVector{DS, Float64}}} # Particles ONLY use the DS dimensions!
    u::Vector{Vector{SVector{M, Float64}}}
    stats::Dict{String, Any}          # Unified storage for ALL reduced statistics
end

mutable struct SimulationConfig{F <: Function, A <: Union{Function, Nothing}}
    simulation_func::F
    simulation_name::String # <-- ADDED THIS FIELD
    reference_func::A 
    reference_name::Union{String, Nothing} 
    shared_params::ParamDict
    methods_dict::MethodDict
    default_methods::Vector{String}
    varied_params::VariedDict
end

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
    # Safe string conversion (only if not nothing)
    ref_name_safe = isnothing(ref_func_name) ? nothing : safe_string(ref_func_name)
    sim_func_name = safe_string(sim_func_name)

    # 1. Resolve Simulation Function
    sim_f = resolve_simulation_function(sim_func_name, nothing)
    if isnothing(sim_f)
        error("Aborting: Could not resolve simulation function '$sim_func_name' in module $target_module.")
    end

    # 2. Resolve Reference Factory Function
    ref_factory = resolve_reference_function(ref_name_safe)
    ref_f = isnothing(ref_factory) ? nothing : Base.invokelatest(ref_factory, shared)
    
    # 3. AUTO-INJECT: Add the reference method to the methods dictionary if it exists
    if !isnothing(ref_name_safe) && !haskey(methods, ref_name_safe)
        ns = nice_string(ref_name_safe)
        methods[ns] = ParamDict()
    end

    # 4. Pass the resolved string and functions to the base constructor
    return SimulationConfig{typeof(sim_f), typeof(ref_f)}(
        sim_f, sim_func_name, ref_f, ref_name_safe, shared, methods, defaults, varied_params
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
    # Reroute to the main constructor, explicitly passing 'nothing' for the reference name
    return SimulationConfig(
        sim_func_name, 
        nothing, 
        shared, 
        methods, 
        defaults; 
        varied_params = varied_params,
    )
end

function resolve_simulation_function(func_name_str::String, sim_func::Union{Function, Nothing})
    return resolve_dynamic_function(func_name_str, "SimulationFunctions", sim_func)
end

# Update the wrapper name to match the new folder and terminology:
function resolve_reference_function(func_name::Union{String, Nothing})
    return resolve_dynamic_function(func_name, "ReferenceFunctions", nothing)
end

"""
    resolve_dynamic_function(func_name::Union{String, Nothing}, dir_name::String, provided_func::Union{Function, Nothing} = nothing)

Dynamically resolves and loads a function from a specified directory. Evaluates the script in the `target_module` namespace 
(defaulting to `Main`) to avoid dependency bleed into the plotting package.
"""
function resolve_dynamic_function(
    func_name::Union{String, Nothing}, 
    dir_name::String, 
    provided_func::Union{Function, Nothing} = nothing
)
    target_module = _TARGET_MODULE[]
    # 1. If the function is already explicitly provided (e.g., from a direct struct call), return it
    if !isnothing(provided_func)
        return provided_func
    end
    
    # 2. If no name string is provided (e.g., no analytical function assigned), return nothing
    if isnothing(func_name) || func_name == "none"; return nothing end
    
    try
        # Build the path using the injected directory string
        func_file = joinpath(_SIM_ROOT_PATH[], dir_name, func_name * ".jl")
        
        if isfile(func_file)
            @info "Dynamically loading function file into $target_module: $func_file"
            Base.include(target_module, func_file)
        else
            @warn "File $func_file not found. Assuming function '$func_name' is already in $target_module scope."
        end
        
        # THE FIX: Wrap the global binding lookup in invokelatest for Julia 1.12+
        return Base.invokelatest(getglobal, target_module, Symbol(func_name))
        
    catch e
        @warn "Failed to dynamically resolve function '$func_name' from '$dir_name'." exception=(e, catch_backtrace())
        return nothing
    end
end
