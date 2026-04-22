module IRunPDESims

# --- 1. Headless-Safe Dependencies ---
using LinearAlgebra, StaticArrays, ProgressMeter, Polyester
using JLD2, FileIO, SHA, Dates

# --- 2. Top-Level Exports ---
# Core Types
export AbstractSimData, ESimData, LSimData, NoSimData, SimulationConfig
export ParamDict, MethodDict, VariedDict, FixedDict
export createParamDict, createMethodDict, createVariedDict, createSimData

# Globals & Settings
export _SAVE_ROOT_PATH, _LAGRANGE_N_GRID, _REFERENCE_RESOLUTION, _SIM_ROOT_PATH
export set_save_path!, get_save_path, set_lagrange_resolution!, set_reference_resolution!, set_sim_path!

# Simulation & Data Pipeline
export run_smart_simulation, runAllSimulations, loadSimData, saveSimData, generate_method_tasks
export doesSimDataExist, deleteSimData, getAllSimData, getStats, changeStats
export calculateAllStats!, process_existing_data, convert_to_eulerian

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

end