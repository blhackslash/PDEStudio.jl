module IPlotPDESols

# --- 1. Global Dependencies ---

using Makie, CairoMakie, Reexport
using Observables: ObserverFunction, onany
using Dates, CSV, DataFrames, Pkg, LibGit2, Printf, Statistics, StaticArrays

@reexport using IRunPDESims # <-- Your new backend!
# Export UI specific
export launch_plotter, launch_csv_interface, set_plot_presets!, set_sim_config!, reset_plotter!

const NestedObsDict = Dict{String, Dict{String, Observable}}
const BaseVariables = ["c","x","y","z","t"]
const VariableNames = ["Component","Space(X)","Space(Y)","Space(Z)","Time"]
const VariableControls = [:menu,:slider,:slider,:slider,:slider]

# --- 3. Makie Rendering Cache ---
"""
    PlotCache
Holds the reactive observables and primitive objects for a single plot layer.
"""
mutable struct PlotCache
    obs_x::Observable{Any}
    obs_y::Observable{Any}
    obs_z::Observable{Any}
    obs_u::Observable{Any}
    primitives::Dict{String, Any}
end

# Helper to initialize empty caches
PlotCache() = PlotCache(
    Observable{Any}(Float64[]), 
    Observable{Any}(Float64[]), 
    Observable{Any}(Float64[]), 
    Observable{Any}(Float64[]), 
    Dict{String, Any}()
)

# In Controls.jl / Structs.jl
mutable struct PlotManager 
    simulation::NestedObsDict
    ui::NestedObsDict
    config::ParamDict
    controls::NestedObsDict # <-- Change this line
    methods::Observable{Vector{String}}
    plot_vars::Vector{String}
    last_run_params::ParamDict
    caches::Dict{Int, Dict{String, PlotCache}}
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
include("Utils.jl")         
include("DataExtraction.jl")
include("TensorBuilder.jl")

include("MakiePlotting.jl")
include("UIStyles.jl")
include("PlottingUtils.jl")
include("Controls.jl")
include("InteractionController.jl")
include("Render.jl")


end