module IRunPDESims

# --- 1. Headless-Safe Dependencies ---
using LinearAlgebra, StaticArrays, ProgressMeter, Polyester
using JLD2, FileIO, SHA, Dates, DataFrames
import Base: show

# --- 2. Top-Level Exports ---
# Core Types
export AbstractSimData, ESimData, LSimData, NoSimData, SimulationConfig
export ParamDict, MethodDict, VariedDict, FixedDict
export createParamDict, createMethodDict, createVariedDict, createSimData

# Globals & Settings
export _SAVE_ROOT_PATH, _LAGRANGE_N_GRID, _REFERENCE_RESOLUTION, _SIM_ROOT_PATH, _TARGET_MODULE, SimFileNotFoundError
export set_save_path!, get_save_path, set_lagrange_resolution!, set_reference_resolution!, set_sim_path!, set_target_module!

# Simulation & Data Pipeline
export run_smart_simulation, runAllSimulations, loadSimData, saveSimData, generate_method_tasks
export doesSimDataExist, deleteSimData, getAllSimData, getStats, changeStats, loadBestConversion
export calculateAllStats!, process_existing_data, convert_to_eulerian, check_data

# Utilities
export safe_string, nice_string, smart_parse_and_update!, get_ignore_keys
export resolve_simulation_function, resolve_reference_function, resolve_dynamic_function

# --- 3. Core Logic Inclusions ---
# (Adjust file paths based on how you moved them into ISimPDEs/src/)
include("Structs.jl")             # Backend structs only (No Observables!)
include("IOUtils.jl")             # Saving, loading, hashing
include("ConversionUtils.jl")     # Lagrange -> Euler, parsing
include("StatCalculation.jl")     # Dierckx, QuadGK, Norms
include("Simulations.jl")         # run_smart_simulation, runAllSimulations



# Custom REPL print for Lagrangian Data
function Base.show(io::IO, ::MIME"text/plain", data::LSimData{D, M}) where {D, M}
    println(io, "🟢 LSimData{$D, $M} (Lagrangian Simulation Data)")
    println(io, "==================================================")
    
    # Time Summary
    t_len = length(data.t)
    t_str = t_len > 0 ? "steps [$(round(data.t[1], digits=3)) ➔ $(round(data.t[end], digits=3))]" : "empty"
    println(io, "  Time (T):    $t_len $t_str")
    
    # Particle Summary (handles jagged arrays if particles merge/split)
    if !isempty(data.x)
        min_p, max_p = extrema(length.(data.x))
        p_str = min_p == max_p ? "$min_p" : "$min_p to $max_p (variable)"
        println(io, "  Particles:   $p_str")
    else
        println(io, "  Particles:   0")
    end
    
    # Parameter Summary
    println(io, "  Parameters:  $(length(data.params)) keys")
    
    # Helper to print dictionary keys without dumping their contents
    function print_dict_summary(dict, label)
        if !isempty(dict)
            keys_str = join(sort(collect(keys(dict))), ", ")
            println(io, "  $label: $keys_str")
        else
            println(io, "  $label: (empty)")
        end
    end
    
    print_dict_summary(data.scalars,  "Scalars   ")
    print_dict_summary(data.series,   "Series    ")
    print_dict_summary(data.profiles, "Profiles  ")
    print_dict_summary(data.fields,   "Fields    ")
end

# You can do the exact same thing for ESimData!
function Base.show(io::IO, ::MIME"text/plain", data::ESimData{D}) where {D}
    println(io, "🟦 ESimData{$D} (Eulerian Grid Data)")
    println(io, "==================================================")
    println(io, "  Time (T):    $(length(data.t)) steps")
    grid_size = join(size(data.u)[2:end-1], " × ")
    println(io, "  Grid Size:   $grid_size")
    # Parameter Summary
    println(io, "  Parameters:  $(length(data.params)) keys")
    
    # Helper to print dictionary keys without dumping their contents
    function print_dict_summary(dict, label)
        if !isempty(dict)
            keys_str = join(sort(collect(keys(dict))), ", ")
            println(io, "  $label: $keys_str")
        else
            println(io, "  $label: (empty)")
        end
    end
    
    print_dict_summary(data.scalars,  "Scalars   ")
    print_dict_summary(data.series,   "Series    ")
    print_dict_summary(data.profiles, "Profiles  ")
    print_dict_summary(data.fields,   "Fields    ")
end

end