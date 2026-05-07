# --- 1. Type Aliases ---
const ParamDict = Dict{String, Any}
const MethodDict = Dict{String, ParamDict}
const VariedDict = Dict{String, Vector}
const FixedDict = ParamDict 


const _SAVE_ROOT_PATH = Ref{String}(pwd())
const _SIM_ROOT_PATH = Ref{String}(pwd())
const _LAGRANGE_N_GRID = Ref{Int}(100)
const _REFERENCE_RESOLUTION = Ref{Int}(500)

set_lagrange_resolution!(n::Int) = (_LAGRANGE_N_GRID[] = n)
set_reference_resolution!(n::Int) = (_REFERENCE_RESOLUTION[] = n)
set_sim_path!(path::String) = (_SIM_ROOT_PATH[] = path)

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
    x::NTuple{D, Vector{Float64}}  # ONLY stores the 1D coordinate axes!
    u::Array{Float64}              # [Component, Space..., Time]
    t::Vector{Float64}

    scalars::Dict{String, Float64} 
    series::Dict{String, Matrix{Float64}} 
    profiles::Dict{String, Array{Float64}} 
    fields::Dict{String, Array{Float64}}   
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

mutable struct SimulationConfig{F <: Function, A <: Union{Function, Nothing}}
    simulation_func::F
    reference_func::A 
    reference_name::Union{String, Nothing} # NEW: Store the name for dynamic matching
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
    # Replace underscores with spaces and titlecase the result
    return titlecase(replace(s, "_" => " "))
end

# Update the signature to accept 'nothing' for the reference function name
function SimulationConfig(
    sim_func_name::String, 
    ref_func_name::Union{String, Nothing}, # THE FIX: allow nothing here!
    shared::ParamDict, 
    methods::MethodDict, 
    defaults::Vector{String}; 
    varied_params::VariedDict = createVariedDict(),
    target_module::Module = Main
)
    # Safe string conversion (only if not nothing)
    ref_name_safe = isnothing(ref_func_name) ? nothing : safe_string(ref_func_name)
    sim_func_name = safe_string(sim_func_name)

    # 1. Resolve Simulation Function
    sim_f = resolve_simulation_function(sim_func_name, nothing; target_module = target_module)
    if isnothing(sim_f)
        error("Aborting: Could not resolve simulation function '$sim_func_name' in module $target_module.")
    end

    # 2. Resolve Reference Factory Function
    ref_factory = resolve_reference_function(ref_name_safe; target_module = target_module)
    ref_f = isnothing(ref_factory) ? nothing : Base.invokelatest(ref_factory, shared)

    # 3. AUTO-INJECT: Add the reference method to the methods dictionary if it exists
    if !isnothing(ref_name_safe) && !haskey(methods, ref_name_safe)
        methods[nice_string(ref_name_safe)] = ParamDict()
    end

    # 4. Pass the resolved string and functions to the base constructor
    return SimulationConfig{typeof(sim_f), typeof(ref_f)}(
        sim_f, ref_f, ref_name_safe, shared, methods, defaults, varied_params
    )
end

# Fallback constructor for when no reference function is provided
function SimulationConfig(
    sim_func_name::String, 
    shared::ParamDict, 
    methods::MethodDict, 
    defaults::Vector{String}; 
    varied_params::VariedDict = createVariedDict(),
    target_module::Module = Main
)
    # Reroute to the main constructor, explicitly passing 'nothing' for the reference name
    return SimulationConfig(
        sim_func_name, 
        nothing, 
        shared, 
        methods, 
        defaults; 
        varied_params = varied_params, 
        target_module = target_module
    )
end

function resolve_simulation_function(func_name_str::String, sim_func::Union{Function, Nothing}; target_module::Module = Main)
    return resolve_dynamic_function(func_name_str, "SimulationFunctions", sim_func; target_module=target_module)
end

# Update the wrapper name to match the new folder and terminology:
function resolve_reference_function(func_name::Union{String, Nothing}; target_module::Module = Main)
    return resolve_dynamic_function(func_name, "ReferenceFunctions", nothing; target_module=target_module)
end

"""
    resolve_dynamic_function(func_name::Union{String, Nothing}, dir_name::String, provided_func::Union{Function, Nothing} = nothing; target_module::Module = Main)

Dynamically resolves and loads a function from a specified directory. Evaluates the script in the `target_module` namespace 
(defaulting to `Main`) to avoid dependency bleed into the plotting package.
"""
function resolve_dynamic_function(
    func_name::Union{String, Nothing}, 
    dir_name::String, 
    provided_func::Union{Function, Nothing} = nothing; 
    target_module::Module = Main
)
    println(func_name,dir_name)
    # 1. If the function is already explicitly provided (e.g., from a direct struct call), return it
    if !isnothing(provided_func)
        return provided_func
    end
    
    # 2. If no name string is provided (e.g., no analytical function assigned), return nothing
    isnothing(func_name) && return nothing
    
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


