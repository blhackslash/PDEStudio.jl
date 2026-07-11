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
# Define the strict hierarchy of your dashboard (Highest priority first)
const LOCK_HIERARCHY = ["Layout", "Scene", "Primitive", "Data", "UI"]

"""
    @with_lock manager "LockName" begin ... end

Safely executes a block of code ONLY if the requested lock is open AND 
no higher-tier structural locks are currently running.
"""
macro with_lock(manager, lock_name, expr)
    return quote
        local mgr = $(esc(manager))
        local lname = $(esc(lock_name))
        local locks = mgr.locks
        
        # 1. Self-Lock Check (Prevents infinite loops)
        if !locks[lname]
            # 2. Hierarchy Check (Prevents race conditions)
            local lock_idx = findfirst(isequal(lname), LOCK_HIERARCHY)
            local blocked = false
            if !isnothing(lock_idx)
                for higher_tier in LOCK_HIERARCHY[1:(lock_idx - 1)]
                    if locks[higher_tier]
                        blocked = true
                        break
                    end
                end
            end
            
            # 3. Execution
            if !blocked
                locks[lname] = true
                try
                    $(esc(expr))
                finally
                    # ALWAYS release the lock, even if the code crashes
                    locks[lname] = false
                end
            end
        end
    end
end
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
    primitives::Dict{Symbol, Any} # THE FIX: Native Symbol Dict
end

PlotCache() = PlotCache(
    Observable{Any}(Float64[]), 
    Observable{Any}(Float64[]), 
    Observable{Any}(Float64[]), 
    Observable{Any}(Float64[]), 
    Dict{Symbol, Any}()           # THE FIX: Native Symbol Dict
)

mutable struct PlotManager 
    simulation::NestedObsDict
    ui::NestedObsDict
    config::ParamDict
    
    # --- The Clean Flat Architecture ---
    widgets::Dict{String, Any}              
    triggers::Dict{String, Observable{Int}} 
    state::Dict{String, Any}                
    locks::Dict{String, Bool}               # THE NEW FLAT FIELD
    
    methods::Observable{Vector{String}}
    plot_vars::Vector{String}
    last_run_params::ParamDict
    caches::Dict{Int, Dict{String, PlotCache}}
end

# --- Plotting Data Structure ---

# ==============================================================================
# --- PLOT DATA STRUCTURES ---
# ==============================================================================
abstract type AbstractPlotData end

"""
    EulerianPlotData{N}
Stores dense, N-dimensional matrices representing perfectly orthogonal grids 
for heatmap, surface, and contour rendering.
"""
struct EulerianPlotData{N} <: AbstractPlotData
    data::Dict{String, Array{Float64, N}}
    active_param_keys::Vector{String}
    active_param_values::Vector{Vector{Any}}
    t_vals::Vector{Float64}
    fixed_params::FixedDict
end

"""
    LagrangianPlotData{N}
Stores raw, unstructured particle data mapped to the parameter grid. 
N is the number of varied parameters.
"""
struct LagrangianPlotData{N} <: AbstractPlotData
    data::Array{Any, N} # Holds the raw LSimData objects!
    active_param_keys::Vector{String}
    active_param_values::Vector{Vector{Any}}
    t_vals::Vector{Float64}
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