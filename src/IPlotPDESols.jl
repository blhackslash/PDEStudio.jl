module IPlotPDESols

# --- 1. Global Dependencies ---

using GLMakie, CairoMakie, Observables, Reexport

@reexport using ISimPDEs # <-- Your new backend!
# Export UI specific
export show_unified_fig, launch_csv_interface

const NestedObsDict = Dict{String, Dict{String, Observable}}
const BaseVariables = ["c","x","y","z","t"]
const VariableNames = ["Component","Space(X)","Space(Y)","Space(Z)","Time"]
const VariableControls = [:menu,:slider,:slider,:slider,:slider]

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

# ==============================================================================
# 4. DATA PROCESSING MODULE (Frontend Ingestion)
# ==============================================================================
module DataProcessing
    # Grab UI structs
    using ..IPlotPDESols: UnifiedPlotData, PlotManager, BaseVariables, VariableNames, VariableControls
    # Grab Backend structs/functions directly
    using ISimPDEs, CSV, DataFrames, Dates, Pkg, DataFrames, LibGit2, Printf
    
    using GLMakie: Observable, to_value
    
    export update_plot_data_collection!, get_source_slices, find_closest_index_for_dim, extract_data, get_base_dim_idx, saveParametersToCSV
    
    include("DataProcessing/TensorBuilder.jl")
end

# ==============================================================================
# 5. USER INTERFACE MODULE (Frontend)
# ==============================================================================
module UI
    # Grab UI structs
    using ..IPlotPDESols: PlotManager, UnifiedPlotData, NestedObsDict, BaseVariables, VariableNames, VariableControls
    # Grab Backend structs
    using ISimPDEs, Dates
    # Grab the DataBuilder
    using ..DataProcessing: update_plot_data_collection!, find_closest_index_for_dim, extract_data, get_base_dim_idx, saveParametersToCSV
    
    using Observables: ObserverFunction, onany
    using GLMakie, CairoMakie, Printf, Statistics
    
    export show_unified_fig, launch_csv_interface
    
    include("Plotting/MakiePlotting.jl") 
end

# ==============================================================================
# 6. RE-EXPORTS & REGISTRY
# ==============================================================================
using .DataProcessing
using .UI

end