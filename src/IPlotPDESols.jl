module IPlotPDESols

# --- 1. Global Dependencies ---
using Makie, CairoMakie, Reexport
using Observables: ObserverFunction, onany
using Dates, CSV, DataFrames, Pkg, LibGit2, Printf, Statistics, StaticArrays

@reexport using IRunPDESims 

export launch_plotter, set_sim_config!, reset_plotter!, set_mode!, set_allowed_dims!, set_max_params!, set_plot_presets!, force_simulation

function dummy_simulation_function(args...); return nothing; end

const DUMMY_CONFIG = SimulationConfig(dummy_simulation_function, :none, nothing, :none, ParamDict(), MethodDict(), Symbol[], VariedDict())

# ==============================================================================
# --- UI DIMENSION REFERENCES (Dynamic Setup) ---
# ==============================================================================
const ALLOWED_PLOT_DIMS = Ref{Tuple{Vararg{Symbol}}}((:x, :y, :z, :t))
const MAX_SUPPORTED_PARAMS = Ref{Int}(2)

set_max_params!(n::Int) = (MAX_SUPPORTED_PARAMS[] = n)

function set_allowed_dims!(dims::Tuple{Vararg{Symbol}})
    ALLOWED_PLOT_DIMS[] = dims
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

struct PlotSweepData{N} <: AbstractPlotData
    data::Array{Union{Nothing, AbstractSimData}, N} 
    active_param_keys::Vector{Symbol}
    active_param_values::Vector{Vector{Any}}
end

mutable struct PlotManager 
    ui::Dict{Symbol, Dict{Symbol, Any}}     
    widgets::Dict{Symbol, Any}              
    triggers::Dict{Symbol, Observable{Int}} 
    staged::Dict{Symbol, Any}
    flags::Dict{Symbol, Observable{Bool}}
    state::Dict{Symbol, Any}               
    maps::Dict{Symbol, Any}                
    locks::Dict{Symbol, Bool}               
    listeners::Dict{Symbol, Union{ObserverFunction, Vector{ObserverFunction}}} 
    
    methods::Observable{Vector{Symbol}}
    plot_vars::Vector{Symbol}
    caches::Dict{Int, Dict{Symbol, AbstractPlotCache}}
    
    active_config::SimulationConfig
    plot_data::Observable{Dict{Symbol, AbstractPlotData}}

    # Unified Encapsulated Globals
    mode::Observable{Symbol}
    ui_state::Dict{Symbol, Any}
end

function PlotManager()
    return PlotManager(
        Dict{Symbol, Dict{Symbol, Any}}(),
        Dict{Symbol, Any}(), Dict{Symbol, Observable{Int}}(),
        Dict{Symbol, Any}(:Simulation => Observable(0)), 
        Dict{Symbol, Observable{Bool}}(), 
        Dict{Symbol, Any}(),                   
        Dict{Symbol, Any}(),                   
        Dict{Symbol, Bool}(), 
        Dict{Symbol, Union{ObserverFunction, Vector{ObserverFunction}}}(),
        Observable(Symbol[]), Symbol[],
        Dict{Int, Dict{Symbol, AbstractPlotCache}}(),
        DUMMY_CONFIG, Observable(Dict{Symbol, AbstractPlotData}()),
        Observable{Symbol}(:eulerian),
        Dict{Symbol, Any}(:is_open => false, :master_fig => nothing),
    )
end

const manager = PlotManager()

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
       
include("DataHandler.jl")
include("PlottingLogic.jl")
include("MakiePlotting.jl")
include("UIStyles.jl")
include("PlottingUtils.jl")
include("Controls.jl")
include("UILogic.jl")
include("Render.jl")
include("ConfigIO.jl")


# FIX: Return lowercased, suffix-free symbols for layout options
function get_base_layout_options()
    return Dict{Symbol, Any}(
        :base_plot       => :lines,
        :plot_style      => :lines_1d,
        :compare_target  => :none, 
        :compare_columns => 2,     
        :compare_link    => :fully_coupled,
        :legend_base     => :right,
        :legend_add      => :detached,
        :plot_width      => 500,
        :plot_height     => 400,
        :anim_target     => :none
    )
end

set_mode!(mode::Symbol) = (manager.mode[] = mode)
force_simulation() = notify(manager.triggers[:Simulation])

function simulation_trigger() 
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
        while haskey(manager.widgets, Symbol("param_$(i)_label"))
            p_key = Symbol("param_$i")
            lbl_obs = manager.widgets[Symbol("param_$(i)_label")]
            
            if i <= length(real_params)
                real_sym = real_params[i]
                param_map[p_key] = real_sym
                reverse_map[real_sym] = p_key
                
                # THE FIX: Use frontend_key for the Slider UI Label!
                lbl_obs[] = frontend_key(real_sym) * ":"  
            else
                lbl_obs[] = "Unused:"
                if haskey(manager.widgets, p_key)
                    manager.widgets[p_key].range[] = [0.0] 
                end
            end
            i += 1
        end
        
        # (Optional: If your x, y, z, t sliders also have Label observables, 
        #  you can dynamically update them here too!)
        for base_sym in get_base_variables()
            base_lbl_key = Symbol("$(base_sym)_label")
            if haskey(manager.widgets, base_lbl_key)
                manager.widgets[base_lbl_key][] = frontend_key(base_sym) * ":"
            end
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

function reset_manager!()
    
    empty!(manager.ui); empty!(manager.widgets); empty!(manager.staged)
    empty!(manager.flags) 
    empty!(manager.state); empty!(manager.maps) 
    empty!(manager.locks); empty!(manager.plot_vars); empty!(manager.caches)
    
    for (k, listener_node) in manager.listeners
        if listener_node isa Vector
            for l in listener_node; off(l); end
        else
            off(listener_node)
        end
    end
    empty!(manager.listeners)
    
    # FIX: Correctly initialize empty states as Symbol vectors/dicts
    manager.methods.val = Symbol[]
    manager.active_config = DUMMY_CONFIG
    manager.plot_data.val = Dict{Symbol, AbstractPlotData}()
    
    core_keys = [:Simulation, :Data, :Layout, :Plot, :Slider, :PlotData, :UI]
    for k in core_keys
        manager.triggers[k] = Observable(0)
        manager.locks[k]    = false
        manager.staged[k]   = Dict{Symbol, Any}() 
        manager.flags[k]    = Observable(false) 
    end
    manager.staged[:Layout] = get_base_layout_options()
    manager.listeners[:Simulation] = on(manager.triggers[:Simulation]) do _; simulation_trigger() end
    
    for k in [:Menu_Sync, :Menu_A, :Menu_B, :Menu_C, :Menu_D]
        manager.locks[k] = false
    end
    
    manager.state[:plot_window_initialized] = Observable(false)
    manager.state[:Active_Axes] = Observable{Vector{Int}}(Int[])
    manager.state[:Is_Activate_Mode] = Observable(true)
    manager.state[:Is_Animating] = Observable(false)
    manager.state[:Animation_Timer] = Observable{Any}(nothing)
    manager.state[:Active_Target_Obs] = Observable{Any}(nothing)
    manager.state[:Layout_Dict] = Observable(Dict{Symbol, Any}())
    manager.state[:Camera_Locked] = Observable(false)

    manager.staged[:Camera] = Dict{Symbol, Any}()
    manager.staged[:Methods] = Observable(Symbol[])

    manager.maps[:Labels] = Dict{Symbol, String}()
    manager.maps[:Presets] = deepcopy(PRESET_DESCRIPTIONS)

    # Initialize the default creation text
    manager.maps[:Presets][:create_new] = "Type a description here, type a filename below, and click Save Defs."
    
    preset_dir = joinpath(get_save_path(), "Presets")
    if isdir(preset_dir)
        for file in readdir(preset_dir)
            if endswith(file, ".csv")
                sym = Symbol(replace(file, ".csv" => ""))
                if !haskey(manager.maps[:Presets], sym)
                    manager.maps[:Presets][sym] = "Custom disk preset" 
                end
            end
        end
    end
end


function __init__()
    on(manager.mode) do _
        reset_plotter!()
        reset_manager!()
    end
    reset_manager!()
    manager.active_config = DUMMY_CONFIG
    
end

end