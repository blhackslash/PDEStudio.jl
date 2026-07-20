module IPlotPDESols

# --- 1. Global Dependencies ---
using Makie, CairoMakie, Reexport
using Observables: ObserverFunction, onany
using Dates, CSV, DataFrames, Pkg, LibGit2, Printf, Statistics, StaticArrays

@reexport using IRunPDESims 

# Export UI specific methods
export launch_plotter, set_sim_config!, reset_plotter!, set_mode!, set_allowed_dims!

const NestedObsDict = Dict{String, Dict{String, Observable}}

# ==============================================================================
# --- UI DIMENSION REFERENCES (Dynamic Setup) ---
# ==============================================================================

# The predefined dimensions the Makie UI will allocate sliders for.
const ALLOWED_PLOT_DIMS = Ref{Tuple{Vararg{Symbol}}}((:x, :y, :z, :t))

# The designated time identifier (used strictly by the Lagrangian plotter to isolate time)
const LAGRANGIAN_TIME_DIM = Ref{Symbol}(:t)

# Display labels for the generated UI sliders
const DIM_LABELS = Ref{Dict{Symbol, String}}(Dict(
    :x => "Space(X)",
    :y => "Space(Y)",
    :z => "Space(Z)",
    :t => "Time"
))

"""
    set_allowed_dims!(dims::Tuple{Vararg{Symbol}}, labels::Dict{Symbol, String}; time_dim::Symbol=:t)

Configures the UI dimensions before launching the plotter.
Example: set_allowed_dims!((:r, :theta, :phi, :t), Dict(:r => "Radius", ...))
"""
function set_allowed_dims!(dims::Tuple{Vararg{Symbol}}, labels::Dict{Symbol, String}; time_dim::Symbol=:t)
    ALLOWED_PLOT_DIMS[] = dims
    DIM_LABELS[] = labels
    LAGRANGIAN_TIME_DIM[] = time_dim
    @info "Plotter UI configured for dimensions: $dims"
end

# Dynamic helpers to replace the deprecated hardcoded arrays
get_base_variables() = [string(d) for d in ALLOWED_PLOT_DIMS[]]
get_base_controls() = Any[:slider for _ in ALLOWED_PLOT_DIMS[]]

# ==============================================================================
# --- GLOBAL DASHBOARD STATE ---
# ==============================================================================

# Define the strict hierarchy of your dashboard (Highest priority first)
const LOCK_HIERARCHY = ["Layout", "Scene", "Primitive", "Data", "UI"]
const PLOT_MODE = Observable{Symbol}(:eulerian)
set_mode!(mode::Symbol) = (PLOT_MODE[] = mode)

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
        
        # 1. Self-Lock Check
        if !locks[lname]
            # 2. Hierarchy Check
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
                    locks[lname] = false
                end
            end
        end
    end
end

# ==============================================================================
# --- MAKIE RENDERING CACHES ---
# ==============================================================================
abstract type AbstractPlotCache end

mutable struct EulerianPlotCache <: AbstractPlotCache
    obs_x::Observable{Any}
    obs_y::Observable{Any}
    obs_z::Observable{Any}
    obs_u::Observable{Any}
    primitives::Dict{Symbol, Any}
end
EulerianPlotCache() = EulerianPlotCache(Observable{Any}(Float64[]), Observable{Any}(Float64[]), Observable{Any}(Float64[]), Observable{Any}(Float64[]), Dict{Symbol, Any}())

mutable struct LagrangianPlotCache <: AbstractPlotCache
    obs_pts::Observable{Any} 
    obs_u::Observable{Any}
    primitives::Dict{Symbol, Any}
end
LagrangianPlotCache() = LagrangianPlotCache(Observable{Any}([]), Observable{Any}(Float64[]), Dict{Symbol, Any}())

mutable struct PlotManager 
    simulation::NestedObsDict
    ui::NestedObsDict
    config::ParamDict
    
    widgets::Dict{String, Any}              
    triggers::Dict{String, Observable{Int}} 
    state::Dict{String, Any}                
    locks::Dict{String, Bool}               
    
    methods::Observable{Vector{String}}
    plot_vars::Vector{String}
    last_run_params::ParamDict
    caches::Dict{Int, Dict{String, AbstractPlotCache}}
end

# ==============================================================================
# --- UNIFIED PLOT DATA STRUCTURE ---
# ==============================================================================
abstract type AbstractPlotData end

"""
    PlotSweepData{N}
Stores an N-dimensional grid of `AbstractSimData` objects, where `N` is the 
number of varied parameters. The inner SimData handles all spatial/temporal logic natively.
"""
struct PlotSweepData{N} <: AbstractPlotData
    data::Array{Union{Nothing, AbstractSimData}, N} 
    active_param_keys::Vector{String}
    active_param_values::Vector{Vector{Any}}
    fixed_params::FixedDict
end

# ==============================================================================
# --- MODULE INCLUDES ---
# ==============================================================================
include("Utils.jl")         
include("DataHandler.jl")

include("MakiePlotting.jl")
include("UIStyles.jl")
include("PlottingUtils.jl")
include("Controls.jl")
include("InteractionController.jl")
include("Render.jl")

function __init__()
    on(PLOT_MODE) do _
        reset_plotter!()
        ACTIVE_PLOT_MANAGER[] = nothing
    end
end

end