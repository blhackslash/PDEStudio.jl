module Structs

export ParamDict, MethodDict, SimulationConfig, SimData1D, SimData2D, createSimData, mergeParams
export AbstractSimData, ParamDictType, MethodDictType, parseValue, AtomicType, AtomicTuple, load_function_from_disk, _load_function_from_string

abstract type AbstractSimData end

# Types of dictionaries
const ParamDictType = Dict{String, Any}
const MethodDictType = Dict{String, ParamDictType}
const AtomicType = Union{Float64, Int64, Bool, Symbol, String}
const AtomicTuple = Tuple{Vararg{AtomicType}}

# Updated Dictionary creators enforcing the right datatype
ParamDict(args...) = Dict{String, Any}(args...)
MethodDict(args...) = Dict{String, ParamDictType}(args...)

struct SimulationConfig
    sim_function::Function
    methods_dict::MethodDictType
    default_methods::Vector{String}
    shared_params::ParamDictType
    #ui_options::ParamDictType

    # --- CONSTRUCTOR 1: The original constructor, now simplified ---
    # This is the "inner" constructor that the new one will call.
    function SimulationConfig(
        sim_function::Function,
        shared_params::ParamDictType,
        methods_dict::MethodDictType,
        default_methods::Union{Vector{String}, String}
    )
        all_methods = collect(keys(methods_dict))
        methods = isa(default_methods, String) ? (default_methods == "all" ? all_methods : [default_methods]) : copy(default_methods)
        
        if !haskey(shared_params, "sim_function")
            @warn "No 'sim_function' key detected in the shared parameters. Name of the Julia function is used. Note that this can lead to errors when loading the CSV file!"
            shared_params["sim_function"] = string(nameof(sim_function))
        end
        # Validate that default methods exist in the methods_dict
        filter!(m -> haskey(methods_dict, m), methods)       
        
        # Use `new` to create an instance of the struct.
        return new(sim_function, methods_dict, methods, shared_params)
    end


    # --- CONSTRUCTOR 2: The new, robust constructor for reproducibility ---
    """
        SimulationConfig(shared_params, methods_dict, default_methods)

    A constructor that dynamically loads the simulation function from a file based on its name.
    The name is loaded from the shared parameter under the key "sim_function". This is the preferred 
    method for creating a `SimulationConfig` when loading from a file to ensure full reproducibility.
    """
    function SimulationConfig(
        shared_params::ParamDictType,
        methods_dict::MethodDictType,
        default_methods::Union{Vector{String}, String};
        repo_path::String = "." # Assumes the script is run from the repo root
    )
        sim_function_name = shared_params["sim_function"]
        sim_function_name = (sim_function_name isa Tuple) && sim_function_name[1] == :const ? sim_function_name[2] : sim_function_name
        # Load the function from the `SimulationFunctions/` directory.
        # This assumes your `load_function_from_disk` helper exists.
        sim_function_handle = load_function_from_disk(repo_path, Symbol(sim_function_name))
        
        if isnothing(sim_function_handle)
            error("Failed to load simulation function '$sim_function_name'. Cannot create SimulationConfig.")
        end
        
        # Call the primary constructor with the now-loaded function handle.
        return SimulationConfig(sim_function_handle, shared_params, methods_dict, default_methods)
    end
end


mutable struct SimData1D <: AbstractSimData
    x::Vector{Vector{Float64}}
    u::Vector{VecOrMat}
    t::Vector{Float64}
    params::ParamDictType
    stats::ParamDictType
    
    function SimData1D(x::Vector{Vector{Float64}}, u::Vector{T}, t::Vector{Float64}, params::ParamDictType, stats::ParamDictType) where T <: Union{Vector{Float64}, Matrix{Float64}}
        new(x, u, t, params, stats)
    end
end

mutable struct SimData2D <: AbstractSimData
    x::Vector{Vector{NTuple{2,Float64}}}
    u::Vector{VecOrMat}
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

function parseValue(s::String)
    try
        # Meta.parse turns a string into a Julia expression.
        # `eval` executes that expression.
        val = eval(Meta.parse(s))
        return isnothing(val) ? "" : val
    catch e
        # If parsing fails, it's probably just a plain string.
        # We also strip quotes that CSV readers sometimes add.
        return strip(s, '\"')
    end
end

"""
    load_function_from_disk(repo_path, function_name_sym) -> Function

Loads the current version of a simulation function from the disk.
"""
function load_function_from_disk(repo_path::String, function_name_sym::Symbol)
    filepath = joinpath(repo_path, "SimulationFunctions", "$(function_name_sym).jl")
    if !isfile(filepath)
        @error "Simulation function file not found at: $filepath"
        return nothing
    end
    file_content = read(filepath, String)
    
    func = _load_function_from_string(file_content, function_name_sym)
    if !isnothing(func)
        println("Successfully loaded current version of function '$function_name_sym' from disk.")
    end
    return func
end
"""
    _load_function_from_string(content::String, function_name_sym::Symbol) -> Function

Safely loads Julia code from a string into an isolated, anonymous module
and returns a handle to the specified function.
"""
function _load_function_from_string(content::String, function_name_sym::Symbol)
    # Create a sandboxed module to load the code into, preventing conflicts.
    sandbox_module = Module()
    # Evaluate the file's content within the new module's scope.
    Base.include_string(sandbox_module, content)
    
    if isdefined(sandbox_module, function_name_sym)
        return getfield(sandbox_module, function_name_sym)
    else
        @error "Function '$function_name_sym' was not found in the provided code."
        return nothing
    end
end
end