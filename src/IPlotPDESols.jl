module IPlotPDESols

# --- 1. Global Dependencies ---
using Makie, CairoMakie, Reexport
using Observables: ObserverFunction, onany
using Dates, CSV, DataFrames, Pkg, LibGit2, Printf, Statistics, StaticArrays

@reexport using IRunPDESims 

export launch_plotter, set_sim_config!, reset_plotter!, set_mode!, set_allowed_dims!, set_max_params!, set_plot_presets!, force_simulation

function dummy_simulation_function(args...); return nothing; end

const DUMMY_CONFIG = SimulationConfig(dummy_simulation_function, :none, nothing, :none, ParamDict(), MethodDict(), String[], VariedDict())

# ==============================================================================
# --- UI DIMENSION REFERENCES (Dynamic Setup) ---
# ==============================================================================
const ALLOWED_PLOT_DIMS = Ref{Tuple{Vararg{Symbol}}}((:x, :y, :z, :t))
const MAX_SUPPORTED_PARAMS = Ref{Int}(2)

set_max_params!(n::Int) = (MAX_SUPPORTED_PARAMS[] = n)

const DIM_LABELS = Ref{Dict{Symbol, String}}(Dict(
    :x => "Space (X)", :y => "Space (Y)", :z => "Space (Z)", :t => "Time (T)"
))

function set_allowed_dims!(dims::Tuple{Vararg{Symbol}}, labels::Dict{Symbol, String}; time_dim::Symbol=:t)
    ALLOWED_PLOT_DIMS[] = dims
    DIM_LABELS[] = labels
    @info "Plotter UI configured for dimensions: $dims"
end

get_base_variables() = collect(ALLOWED_PLOT_DIMS[])  

# ==============================================================================
# --- GLOBAL DASHBOARD STATE ---
# ==============================================================================
const LOCK_HIERARCHY = [:Simulation, :Layout, :Scene, :Primitive, :Slider, :Data, :UI]
const PLOT_MODE = Observable{Symbol}(:eulerian)
set_mode!(mode::Symbol) = (PLOT_MODE[] = mode)

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
    ui::Dict{Symbol, Dict{Symbol, Any}}     
    widgets::Dict{Symbol, Any}              
    triggers::Dict{Symbol, Observable{Int}} 
    staged::Dict{Symbol, Any}                
    locks::Dict{Symbol, Bool}               
    listeners::Dict{Symbol, Union{ObserverFunction, Vector{ObserverFunction}}} 
    
    methods::Observable{Vector{String}}
    plot_vars::Vector{Symbol}
    caches::Dict{Int, Dict{String, AbstractPlotCache}}
    
    active_config::SimulationConfig
    plot_data::Observable{Dict{String, AbstractPlotData}}
end

function PlotManager()
    return PlotManager(
        Dict{Symbol, Dict{Symbol, Any}}(),
        Dict{Symbol, Any}(), Dict{Symbol, Observable{Int}}(),
        Dict{Symbol, Any}(), Dict{Symbol, Bool}(), 
        Dict{Symbol, Union{ObserverFunction, Vector{ObserverFunction}}}(),
        Observable(String[]), Symbol[],
        Dict{Int, Dict{String, AbstractPlotCache}}(),
        DUMMY_CONFIG, Observable(Dict{String, AbstractPlotData}())
    )
end
const GLOBAL_PLOT_MANAGER = PlotManager()

force_simulation() = notify(GLOBAL_PLOT_MANAGER.triggers[:Simulation])

function reset_manager!()
    mgr = GLOBAL_PLOT_MANAGER
    empty!(mgr.ui); empty!(mgr.widgets); empty!(mgr.staged)
    empty!(mgr.locks); empty!(mgr.plot_vars); empty!(mgr.caches)
    
    for (k, listener_node) in mgr.listeners
        if listener_node isa Vector
            for l in listener_node; off(l); end
        else
            off(listener_node)
        end
    end
    empty!(mgr.listeners)
    
    mgr.methods.val = String[]
    mgr.active_config = DUMMY_CONFIG
    mgr.plot_data.val = Dict{String, AbstractPlotData}()
    
    core_keys = [:Simulation, :Layout, :Scene, :Primitive, :Slider, :Data, :UI]
    for k in core_keys
        mgr.triggers[k] = Observable(0)
        mgr.locks[k]    = false
        mgr.staged[k]   = Dict{Symbol, Any}() 
    end
    
    for k in [:Menu_Sync, :Menu_A, :Menu_B, :Menu_C]
        mgr.locks[k] = false
    end
    
    mgr.staged[:plot_window_initialized] = Observable(false)
    mgr.staged[:Active_Axes] = Observable{Vector{Int}}(Int[])
    mgr.staged[:Is_Activate_Mode] = Observable(true)
    mgr.staged[:Is_Animating] = Observable(false)
    mgr.staged[:Animation_Timer] = Observable{Any}(nothing)
    mgr.staged[:Active_Target_Obs] = Observable{Any}(nothing)
    mgr.staged[:Layout_Dict] = Observable(Dict{Symbol, Any}())
    mgr.staged[:Camera] = Dict{Symbol, Any}()
    
    # --- THE FIX: Add UI State Flags for the Hierarchy Controller ---
    mgr.staged[:Flag_Sim]    = Observable(false)
    mgr.staged[:Flag_Layout] = Observable(false)
    mgr.staged[:Flag_Plot]   = Observable(false)
end

struct PlotSweepData{N} <: AbstractPlotData
    data::Array{Union{Nothing, AbstractSimData}, N} 
    active_param_keys::Vector{String}
    active_param_values::Vector{Vector{Any}}
end

macro with_lock(lock_name, expr)
    return quote
        local lname = $(esc(lock_name))
        local locks = GLOBAL_PLOT_MANAGER.locks
        
        if !locks[lname]
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

function __init__()
    on(PLOT_MODE) do _
        reset_plotter!()
        reset_manager!()
    end
    reset_manager!()
    GLOBAL_PLOT_MANAGER.active_config = DUMMY_CONFIG
    
    on(GLOBAL_PLOT_MANAGER.triggers[:Simulation]) do _
        @with_lock :Simulation begin
            manager = GLOBAL_PLOT_MANAGER
            curr_config = manager.active_config
            (isnothing(curr_config) || curr_config.simulation_func === dummy_simulation_function) && return

            wanted_methods = haskey(manager.staged, :Staged_Methods) ? manager.staged[:Staged_Methods][] : manager.methods[]
            
            if isempty(wanted_methods)
                @warn "No methods staged! Please activate at least one method to run."
                return
            end

            @info "Running dynamic calculations directly from active config..."
            runAllSimulations(curr_config; active_methods = wanted_methods, calculate_stats = true, force_overwrite = false)
            
            if sort(manager.methods[]) != sort(wanted_methods)
                manager.methods[] = copy(wanted_methods)
            end
            
            @info "Running Simulation and Mapping UI..."

            real_params = Symbol.(sort(collect(keys(curr_config.varied_params))))
            param_map = Dict{Symbol, Symbol}()
            reverse_map = Dict{Symbol, Symbol}()
            
            i = 1
            while haskey(manager.widgets, Symbol("param_$(i)_Label"))
                p_key = Symbol("param_$i")
                lbl_obs = manager.widgets[Symbol("param_$(i)_Label")]
                
                if i <= length(real_params)
                    real_sym = real_params[i]
                    param_map[p_key] = real_sym
                    reverse_map[real_sym] = p_key
                    lbl_obs[] = string(real_sym) * ":"  
                else
                    lbl_obs[] = "Unused:"
                    if haskey(manager.widgets, p_key)
                        manager.widgets[p_key].range[] = [0.0] 
                    end
                end
                i += 1
            end
            
            manager.staged[:Param_Map] = param_map
            manager.staged[:Reverse_Map] = reverse_map
            manager.plot_vars = [real_params; get_base_variables()]
            
            try
                update_plot_data_collection!(manager.plot_data[], curr_config, manager.methods[]; force_reload = true)
            finally
                GLOBAL_PLOT_MANAGER.staged[:Flag_Sim][] = false
            end
        end
        GLOBAL_PLOT_MANAGER.triggers[:Layout][] += 1
    end
end

include("Utils.jl")         
include("DataHandler.jl")

include("MakiePlotting.jl")
include("UIStyles.jl")
include("PlottingUtils.jl")
include("Controls.jl")
include("InteractionController.jl")
include("Render.jl")

end