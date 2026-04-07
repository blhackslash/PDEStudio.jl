module IPlotPDESols

# --- 1. Global Dependencies ---
using GLMakie, CairoMakie, Printf, Statistics, LibGit2, CSV, DataFrames, Dates
using ProgressMeter, LinearAlgebra, StaticArrays, SHA, Pkg, JLD2, FileIO

# --- 2. Top-Level Exports ---
# Everything exported here is instantly available to the user when they do `using IPlotPDESols`
export loadSimData, getStats, doesSimDataExist, deleteSimData, 
       getAllSimData, changeStats, set_save_path!, get_save_path,
       ParamDict, MethodDict, VariedDict, SimulationConfig, createSimData,
       createParamDict, createMethodDict, createVariedDict,
       AbstractSimData, calculateConvergenceData, allMethodNames,
       calculateAllStats!, process_existing_data,
       registerSimFunction!, getSimFunction, registerAllFunctions, 
       show_unified_fig, launch_csv_interface

# --- 3. Core Types (Defined directly in the main module) ---
# Included FIRST so submodules can use them.
include("Structs.jl") 


# ==============================================================================
# 4. DATA PROCESSING MODULE (Backend)
# ==============================================================================
module DataProcessing
    # Look UP to the parent module (IPlotPDESols) to grab the core types
    using ..IPlotPDESols: ParamDict, MethodDict, FixedDict, VariedDict, _SAVE_ROOT_PATH,
                          AbstractSimData, ESimData, LSimData, SimulationConfig,
                          UnifiedPlotData, BaseVariables, PlotManager, NoSimData
    using GLMakie: Observable, to_value
    using LinearAlgebra, StaticArrays, ProgressMeter, JLD2, FileIO, SHA, CSV, DataFrames, LibGit2, Pkg
    
    # Export only the functions the UI needs to call
    export update_plot_data_collection!, createSimData, smart_parse_and_update!, get_save_path,
           set_save_path!, saveParametersToCSV, process_existing_data
    
    include("DataProcessing/TensorBuilder.jl")
end


# ==============================================================================
# 5. USER INTERFACE MODULE (Frontend)
# ==============================================================================
module UI
    # Look UP to the parent module to grab UI-specific structs and constants
    using ..IPlotPDESols: PlotManager, SimulationConfig, UnifiedPlotData, ParamDict,
                          MethodDict, NestedObsDict, resolve_simulation_function,
                          VariableControls, VariableNames, BaseVariables
        
    # Look across to the sibling module for the data pipeline
    using ..DataProcessing: update_plot_data_collection!, smart_parse_and_update!, get_save_path, 
                            saveParametersToCSV
    using Observables: ObserverFunction, onany
    using GLMakie, CairoMakie, Printf, Statistics, CSV, DataFrames, Dates
    
    # Submodule exports (These are re-exported globally at the bottom)
    export show_unified_fig, launch_csv_interface
    
    include("Plotting/MakiePlotting.jl") 
end


# ==============================================================================
# 6. RE-EXPORTS & REGISTRY
# ==============================================================================
using .DataProcessing
using .UI

const SIMULATION_FUNCTION_REGISTRY = Dict{Symbol, Function}()

function register_simulation_function!(name::Symbol, func::Function)
    if haskey(SIMULATION_FUNCTION_REGISTRY, name)
        @warn "Redefining simulation function: $name"
    end
    SIMULATION_FUNCTION_REGISTRY[name] = func
    @info "Registered simulation function: :$name"
end

function getSimFunction(name::Symbol)
    func = get(SIMULATION_FUNCTION_REGISTRY, name, nothing)
    if isnothing(func)
        @error "Simulation function :$name not found in registry."
    end
    return func
end

function registerAllFunctions()
    # Your existing directory scanning logic here...
    @info "Finished registering simulation functions."
end

end