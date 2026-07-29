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
# --- GLOBAL LOCK HIERARCHY ---
# ==============================================================================
const LOCK_HIERARCHY = [:Simulation, :Data, :Layout, :Plot, :Slider, :PlotData, :UI]

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
    flags::Dict{Symbol, Observable{Bool}}
    state::Dict{Symbol, Any}               # Add this line
    maps::Dict{Symbol, Any}                # Add this line
    locks::Dict{Symbol, Bool}               
    listeners::Dict{Symbol, Union{ObserverFunction, Vector{ObserverFunction}}} 
    
    methods::Observable{Vector{String}}
    plot_vars::Vector{Symbol}
    caches::Dict{Int, Dict{String, AbstractPlotCache}}
    
    active_config::SimulationConfig
    plot_data::Observable{Dict{String, AbstractPlotData}}

    # Unified Encapsulated Globals
    mode::Observable{Symbol}
    ui_state::Dict{Symbol, Any}
end

function PlotManager()
    return PlotManager(
        Dict{Symbol, Dict{Symbol, Any}}(),
        Dict{Symbol, Any}(), Dict{Symbol, Observable{Int}}(),
        Dict{Symbol, Any}(), 
        Dict{Symbol, Observable{Bool}}(), 
        Dict{Symbol, Any}(),                   # Add this line (state)
        Dict{Symbol, Any}(),                   # Add this line (maps)
        Dict{Symbol, Bool}(), 
        Dict{Symbol, Union{ObserverFunction, Vector{ObserverFunction}}}(),
        Observable(String[]), Symbol[],
        Dict{Int, Dict{String, AbstractPlotCache}}(),
        DUMMY_CONFIG, Observable(Dict{String, AbstractPlotData}()),
        Observable{Symbol}(:eulerian),
        Dict{Symbol, Any}(:is_open => false, :master_fig => nothing),
    )
end

const manager = PlotManager()

set_mode!(mode::Symbol) = (manager.mode[] = mode)
force_simulation() = notify(manager.triggers[:Simulation])

macro with_lock(lock_name, expr)
    return quote
        local lname = $(esc(lock_name))
        local locks = manager.locks
        
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

function get_base_layout_options()
    return Dict{Symbol, Any}(
        :Base_Plot_Selection       => :lines,
        :Plot_Style_Selection      => :one_d,
        :Compare_Target_Selection  => :None, 
        :Compare_Columns_Selection => 2,     
        :Compare_Link_Selection    => :fully_coupled,
        :Legend_Base_Selection     => :right,
        :Legend_Add_Selection      => :detached,
        :Plot_Width_Selection      => 600,
        :Plot_Height_Selection     => 400,
        :Anim_Target_Selection     => :None
    )
end

function reset_manager!()
    
    empty!(manager.ui); empty!(manager.widgets); empty!(manager.staged)
    empty!(manager.flags) 
    empty!(manager.state); empty!(manager.maps) # Add this line
    empty!(manager.locks); empty!(manager.plot_vars); empty!(manager.caches)
    
    for (k, listener_node) in manager.listeners
        if listener_node isa Vector
            for l in listener_node; off(l); end
        else
            off(listener_node)
        end
    end
    empty!(manager.listeners)
    
    manager.methods.val = String[]
    manager.active_config = DUMMY_CONFIG
    manager.plot_data.val = Dict{String, AbstractPlotData}()
    
    core_keys = [:Simulation, :Data, :Layout, :Plot, :Slider, :PlotData, :UI]
    for k in core_keys
        manager.triggers[k] = Observable(0)
        manager.locks[k]    = false
        manager.staged[k]   = Dict{Symbol, Any}() 
        manager.flags[k]    = Observable(false) 
    end
    manager.staged[:Layout] = get_base_layout_options()
    
    for k in [:Menu_Sync, :Menu_A, :Menu_B, :Menu_C, :Menu_D]
        manager.locks[k] = false
    end
    
    # Move these variables into manager.state
    manager.state[:plot_window_initialized] = Observable(false)
    manager.state[:Active_Axes] = Observable{Vector{Int}}(Int[])
    manager.state[:Is_Activate_Mode] = Observable(true)
    manager.state[:Is_Animating] = Observable(false)
    manager.state[:Animation_Timer] = Observable{Any}(nothing)
    manager.state[:Active_Target_Obs] = Observable{Any}(nothing)
    manager.state[:Layout_Dict] = Observable(Dict{Symbol, Any}())
    manager.state[:Camera_Locked] = Observable(false)

    manager.staged[:Camera] = Dict{Symbol, Any}()
    manager.staged[:Methods] = Observable(String[])
end

struct PlotSweepData{N} <: AbstractPlotData
    data::Array{Union{Nothing, AbstractSimData}, N} 
    active_param_keys::Vector{String}
    active_param_values::Vector{Vector{Any}}
end

function __init__()
    on(manager.mode) do _
        reset_plotter!()
        reset_manager!()
    end
    reset_manager!()
    manager.active_config = DUMMY_CONFIG
    
    on(manager.triggers[:Simulation]) do _
        @with_lock :Simulation begin
            
            curr_config = manager.active_config
            (isnothing(curr_config) || curr_config.simulation_func === dummy_simulation_function) && return

            wanted_methods = manager.staged[:Methods][]
            
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
            
            manager.maps[:Param] = param_map
            manager.maps[:Reverse] = reverse_map
            manager.plot_vars = [real_params; get_base_variables()]
            
            manager.locks[:Layout] = true
            try
                update_plot_data_collection!(manager.plot_data[], curr_config, manager.methods[]; force_reload = true)
            finally
                manager.locks[:Layout] = false
                manager.flags[:Simulation][] = false
            end
        end
        manager.triggers[:Data][] += 1
    end
end
       
include("DataHandler.jl")
include("PlottingLogic.jl")
include("MakiePlotting.jl")
include("UIStyles.jl")
include("PlottingUtils.jl")
include("Controls.jl")
include("UILogic.jl")
include("Render.jl")
include("ConfigIO.jl")

end