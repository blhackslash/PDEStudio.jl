module IRunPDESims

# --- 1. Headless-Safe Dependencies ---
using LinearAlgebra, StaticArrays, ProgressMeter, Polyester, Interpolations
using JLD2, FileIO, SHA, Dates, DataFrames
import Base: show

# --- 2. Top-Level Exports ---
# Core Types
export AbstractSimData, ESimData, LSimData, NoSimData, SimulationConfig
export ParamDict, MethodDict, VariedDict, FixedDict
export create_param_dict, create_method_dict, create_varied_dict, create_sim_data

# Globals & Settings
export set_save_path!, set_target_module!, get_save_path, get_target_module
export register_stat!, delete_stat!, add_stat!, get_kept_dims, get_kept_indices
# Simulation & Data Pipeline
export run_all_simulations, load_sim_data, save_sim_data, generate_method_tasks
export does_sim_data_exist, delete_sim_data
export calculate_all_stats!, check_data, generate_reference_simdata

# Utilities
export get_ignore_keys, is_reference_method
export resolve_simulation_function, resolve_reference_function, resolve_dynamic_function

# --- 3. Core Logic Inclusions ---
# (Adjust file paths based on how you moved them into ISimPDEs/src/)
include("Structs.jl")             # Backend structs only (No Observables!)
include("IOUtils.jl")             # Saving, loading, hashing
include("ConversionUtils.jl")     # Lagrange -> Euler, parsing
include("StatCalculation.jl")     # Dierckx, QuadGK, Norms
include("Simulations.jl")         # run_smart_simulation, runAllSimulations



# Custom REPL print for Lagrangian Data
function Base.show(io::IO, ::MIME"text/plain", data::LSimData{D, DS, M, T}) where {D, DS, M, T}
    println(io, "🟢 LSimData{$D, $DS, $M, $T} (Lagrangian Simulation Data)")
    println(io, "==================================================")
    
    # Time Summary (Supports Static vs Transient)
    if D > DS && !isempty(data.t)
        t_str = "steps [$(round(data.t[1], digits=3)) ➔ $(round(data.t[end], digits=3))]"
        println(io, "  Time (T)   : $(length(data.t)) $t_str")
    else
        println(io, "  Time (T)   : Static (1 step)")
    end
    
    # Domain Summary (Using DomainInfo and dimension keys)
    domain_strs = ["$(data.domain.dim_keys[d]): $(round(data.domain.mins[d], digits=3)) ➔ $(round(data.domain.maxs[d], digits=3))" for d in 1:DS]
    println(io, "  Space      : [$(join(domain_strs, "] × ["))]")
    
    # Particle Summary (handles jagged arrays if particles merge/split)
    if !isempty(data.x)
        min_p, max_p = extrema(length.(data.x))
        p_str = min_p == max_p ? "$min_p" : "$min_p to $max_p (variable)"
        println(io, "  Particles  : $p_str")
    else
        println(io, "  Particles  : 0")
    end
    
    # Parameter Summary
    println(io, "  Parameters : $(length(data.params)) keys")
    
    # Helper to print dictionary keys
    function print_dict_summary(dict, label)
        if !isempty(dict)
            keys_str = join(sort(string.(collect(keys(dict)))), ", ")
            println(io, "  $label: $keys_str")
        else
            println(io, "  $label: (empty)")
        end
    end
    
    print_dict_summary(data.stats,   "Statistics ")
end


# Custom REPL print for Eulerian Data
function Base.show(io::IO, ::MIME"text/plain", data::ESimData{D, DS, M, T}) where {D, DS, M, T}
    println(io, "🟦 ESimData{$D, $DS, $M, $T} (Eulerian Grid Data)")
    println(io, "==================================================")
    
    # Time Summary
    if D > DS
        t_vec = data.axes[end]
        t_str = "steps [$(round(t_vec[1], digits=3)) ➔ $(round(t_vec[end], digits=3))]"
        println(io, "  Time (T)   : $(length(t_vec)) $t_str")
    else
        println(io, "  Time (T)   : Static (1 step)")
    end
    
    # Spatial Domain Summary
    domain_strs = ["$(data.domain.dim_keys[d]): $(round(data.domain.mins[d], digits=3)) ➔ $(round(data.domain.maxs[d], digits=3))" for d in 1:DS]
    println(io, "  Space      : [$(join(domain_strs, "] × ["))]")
    
    # Grid Summary (Spatial points only for clarity)
    grid_dims = join(length.(data.axes[1:DS]), " × ")
    total_pts = prod(length.(data.axes[1:DS]))
    println(io, "  Grid Size  : $grid_dims ($total_pts spatial points)")
    
    # Parameter Summary
    println(io, "  Parameters : $(length(data.params)) keys")
    
    # Helper to print dictionary keys
    function print_dict_summary(dict, label)
        if !isempty(dict)
            keys_str = join(sort(string.(collect(keys(dict)))), ", ")
            println(io, "  $label: $keys_str")
        else
            println(io, "  $label: (empty)")
        end
    end
    
    print_dict_summary(data.stats,   "Statistics ")
end

end