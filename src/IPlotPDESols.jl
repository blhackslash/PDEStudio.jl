module IPlotPDESols

# --- 1. Global Dependencies ---
using Makie, CairoMakie, Reexport
using Observables: ObserverFunction, onany
using Dates, CSV, DataFrames, Pkg, LibGit2, Printf, Statistics, StaticArrays

@reexport using IRunPDESims 

# Export the new configuration setter
export launch_plotter, set_sim_config!, reset_plotter!, set_mode!, set_allowed_dims!, set_max_params!, set_plot_presets!


function dummy_simulation_function(args...); return nothing; end

const DUMMY_CONFIG = SimulationConfig(dummy_simulation_function, :none, nothing, :none, ParamDict(), MethodDict(), String[], VariedDict())
# ==============================================================================
# --- UI DIMENSION REFERENCES (Dynamic Setup) ---
# ==============================================================================

# The predefined dimensions the Makie UI will allocate sliders for.
const ALLOWED_PLOT_DIMS = Ref{Tuple{Vararg{Symbol}}}((:x, :y, :z, :t))

# NEW: The maximum number of varied parameter sliders to generate
const MAX_SUPPORTED_PARAMS = Ref{Int}(2)


"""
    set_max_params!(n::Int)

Configures the maximum number of varied parameter sliders generated in the UI.
"""
set_max_params!(n::Int) = (MAX_SUPPORTED_PARAMS[] = n)

# Display labels for the generated UI sliders
const DIM_LABELS = Ref{Dict{Symbol, String}}(Dict(
    :x => "Space (X)",
    :y => "Space (Y)",
    :z => "Space (Z)",
    :t => "Time (T)"
))

"""
    set_allowed_dims!(dims::Tuple{Vararg{Symbol}}, labels::Dict{Symbol, String}; time_dim::Symbol=:t)

Configures the UI dimensions before launching the plotter.
Example: set_allowed_dims!((:r, :theta, :phi, :t), Dict(:r => "Radius", ...))
"""
function set_allowed_dims!(dims::Tuple{Vararg{Symbol}}, labels::Dict{Symbol, String}; time_dim::Symbol=:t)
    ALLOWED_PLOT_DIMS[] = dims
    DIM_LABELS[] = labels
    @info "Plotter UI configured for dimensions: $dims"
end

get_base_variables() = collect(ALLOWED_PLOT_DIMS[])  # Returns Vector{Symbol}

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

# ==============================================================================
# --- UNIFIED PLOT DATA STRUCTURE ---
# ==============================================================================
abstract type AbstractPlotData end
mutable struct PlotManager 
    ui::Dict{String, Dict{String, Any}}     # Pure Julia Dict, no Observables!
    
    widgets::Dict{String, Any}              
    triggers::Dict{String, Observable{Int}} 
    state::Dict{String, Any}                
    locks::Dict{String, Bool}               
    
    methods::Observable{Vector{String}}
    plot_vars::Vector{Symbol}
    caches::Dict{Int, Dict{String, AbstractPlotCache}}
    
    active_config::SimulationConfig
    plot_data::Observable{Dict{String, AbstractPlotData}}
end

function PlotManager()
    
    return PlotManager(
        Dict{String, Dict{String, Any}}(),
        Dict{String, Any}(), Dict{String, Observable{Int}}(),
        Dict{String, Any}(), Dict{String, Bool}(),
        Observable(String[]), Symbol[],
        Dict{Int, Dict{String, AbstractPlotCache}}(),
        DUMMY_CONFIG, Observable(Dict{String, AbstractPlotData}())
    )
end

const GLOBAL_PLOT_MANAGER = PlotManager()

function reset_manager!()
    mgr = GLOBAL_PLOT_MANAGER
    empty!(mgr.ui); empty!(mgr.widgets); empty!(mgr.state)
    empty!(mgr.locks); empty!(mgr.plot_vars); empty!(mgr.caches)
    
    mgr.methods.val = String[]
    mgr.active_config = DUMMY_CONFIG
    mgr.plot_data.val = Dict{String, AbstractPlotData}()
    
    for k in ["Layout_Update", "Scene_Update", "Primitive_Rebuild", "Data_Sync", "UI_Update", "Simulation_Update"]
        mgr.triggers[k] = Observable(0)
    end
    for k in ["Menu_Sync", "Layout", "Scene", "Primitive", "Data", "Sliders", "UI", "Menu_A", "Menu_B", "Menu_C", "Menu_D"]
        mgr.locks[k] = false
    end
    
    mgr.state["Config_Just_Loaded"] = Observable(false)
    mgr.state["plot_window_initialized"] = Observable(false)
    mgr.state["Active_Axes"] = Observable{Vector{Int}}(Int[])
    mgr.state["Is_Activate_Mode"] = Observable(true)
    mgr.state["Is_Animating"] = Observable(false)
    mgr.state["Animation_Timer"] = Observable{Any}(nothing)
    mgr.state["Active_Target_Obs"] = Observable{Any}(nothing)
    mgr.state["Layout_Dict"] = Observable(Dict{String, Any}())
end

# Drop fixed_params from the data struct[cite: 20]
struct PlotSweepData{N} <: AbstractPlotData
    data::Array{Union{Nothing, AbstractSimData}, N} 
    active_param_keys::Vector{String}
    active_param_values::Vector{Vector{Any}}
end

function __init__()
    on(PLOT_MODE) do _
        reset_plotter!()
        reset_manager!()
    end
    # Initialize the singleton with the dummy config immediately
    reset_manager!()
    GLOBAL_PLOT_MANAGER.active_config = DUMMY_CONFIG
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

end