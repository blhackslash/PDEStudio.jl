module PDEStudio

# --- 1. Global Dependencies ---
using Makie, CairoMakie, Reexport
using Observables: ObserverFunction, onany
using Dates, CSV, DataFrames, Pkg, LibGit2, Printf, Statistics, StaticArrays

@reexport using PDECore

export launch_plotter, set_sim_config!, reset_plotter!, reset_manager!, set_mode!, set_allowed_dims!, set_max_params!, set_plot_preset!, force_simulation, set_resolution!

function dummy_simulation_function(args...); return nothing; end

const DUMMY_CONFIG = SimulationConfig(dummy_simulation_function, :none, nothing, :none, (_ -> false), :none, ParamDict(), MethodDict(), Symbol[], VariedDict(), String[])

# ==============================================================================
# --- GLOBAL LOCK HIERARCHY ---
# ==============================================================================
const LOCK_HIERARCHY = [:Simulation, :Data, :Layout, :Plot, :Slider, :PlotData, :UI]

# ==============================================================================
# --- MAKIE RENDERING CACHES ---
# ==============================================================================
"""
    AbstractPlotCache

The abstract base type for managing Makie rendering buffers.
"""
abstract type AbstractPlotCache end

"""
    EulerianPlotCache <: AbstractPlotCache

Stores the active `Observable` memory buffers and instantiated Makie primitives for a specific Eulerian rendering method. 
Holds strongly typed coordinate limits (`obs_x`, `obs_y`, `obs_z`) and the scalar field data (`obs_u`) alongside a dictionary tracking the drawn primitives (e.g., `:lines_2d`, `:contour_f`).
"""
mutable struct EulerianPlotCache <: AbstractPlotCache
    obs_x::Observable{Any}
    obs_y::Observable{Any}
    obs_z::Observable{Any}
    obs_u::Observable{Any}
    primitives::Dict{Symbol, Any}
end
EulerianPlotCache() = EulerianPlotCache(Observable{Any}(Float64[]), Observable{Any}(Float64[]), Observable{Any}(Float64[]), Observable{Any}(Float64[]), Dict{Symbol, Any}())

"""
    LagrangianPlotCache <: AbstractPlotCache

Stores the active `Observable` memory buffers for Lagrangian particle tracking. 
Bypasses rigid grid dimensions in favor of raw coordinate point clouds (`obs_pts`) and their associated scalar values (`obs_u`).
"""
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

"""
    PlotSweepData{N} <: AbstractPlotData

A wrapper mapping an N-dimensional parameter sweep to its corresponding `PDECore` simulation data.
Stores the actual Cartesian tensor of `AbstractSimData` objects alongside the exact keys and values of the active parameter grid.
"""
struct PlotSweepData{N} <: AbstractPlotData
    data::Array{Union{Nothing, AbstractSimData}, N} 
    active_param_keys::Vector{Symbol}
    active_param_values::Vector{Vector{Any}}
end

"""
    PlotManager

The central reactive state machine governing the `PDEStudio` interface. 

It encapsulates all UI widget references, active configuration payloads, UI state dictionaries, and the critical hierarchical trigger locks (`locks`, `flags`, `triggers`) that prevent asynchronous race conditions between the headless backend and the Makie frontend.
"""
mutable struct PlotManager 
    ui::Dict{Symbol, Dict{Symbol, Any}}     
    widgets::Dict{Symbol, Any}              
    triggers::Dict{Symbol, Observable{Int}} 
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

    allowed_dims::Tuple{Vararg{Symbol}}
    max_params::Int
end

function PlotManager()
    return PlotManager(
        Dict{Symbol, Dict{Symbol, Any}}(),
        Dict{Symbol, Any}(), 
        Dict{Symbol, Observable{Int}}(),
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
        (:x, :y, :z, :t), 2,
    )
end

const manager = PlotManager()

"""
    set_max_params!(n::Int)

Globally configures the maximum number of custom `VariedDict` sweep parameters the UI will allocate sliders for. Triggers a complete UI reset.
"""
function set_max_params!(n::Int)
    reset_plotter!()
    manager.max_params = n
end

"""
    set_allowed_dims!(dims::Tuple{Vararg{Symbol}})

Defines the foundational mathematical dimensions the studio expects to render (e.g., `(:x, :y, :t)`). Adapts the base UI slider banks accordingly and completely resets the plotter to apply the new physical boundaries.
"""
function set_allowed_dims!(dims::Tuple{Vararg{Symbol}})

    reset_plotter!()
    manager.allowed_dims = dims
    @info "Plotter UI configured for dimensions: $dims"
end

"""
    get_base_variables()

Returns a vector of the foundational mathematical dimensions currently allowed by the studio.
"""
get_base_variables() = collect(manager.allowed_dims)

# ==============================================================================
# --- DIMENSIONAL RESOLUTION MANAGEMENT ---
# ==============================================================================

"""
    set_resolution!(dim::Symbol, val::Int; is_ref::Bool=false)

Dynamically sets the internal interpolation and rendering resolution for a specific spatial or temporal dimension. Can target either the numerical baseline grid or the highly-resolved analytical reference grid.
"""
function set_resolution!(dim::Symbol, val::Int; is_ref::Bool=false)
    target = is_ref ? manager.state[:Resolution_Ref] : manager.state[:Resolution_Base]
    target[dim] = val
end

"""
    get_resolution(dim::Symbol; is_ref::Bool=false)

Retrieves the active UI resolution for a given dimension, automatically falling back to sensible defaults (200 for numerical, 400 for analytical) if the dimension was dynamically generated during a sweep.
"""
function get_resolution(dim::Symbol; is_ref::Bool=false)
    target = is_ref ? manager.state[:Resolution_Ref] : manager.state[:Resolution_Base]
    # Fallback default if a completely new dimension is requested dynamically
    return get(target, dim, is_ref ? 400 : 200)
end

"""
    build_res_tuple(dim_keys::AbstractVector{Symbol}; is_ref::Bool=false)

Dynamically generates the `NTuple{D, Int}` required by the backend, ensuring the spatial and temporal resolutions are ordered exactly according to the backend's expected `dim_keys` tuple.
"""
function build_res_tuple(dim_keys::Union{AbstractVector{Symbol},Tuple{Vararg{Symbol}}}; is_ref::Bool=false)
    return Tuple(get_resolution(d; is_ref=is_ref) for d in dim_keys)
end

"""
    @with_lock(lock_name, expr)

A critical concurrency macro that safely evaluates an expression while respecting the global `LOCK_HIERARCHY` (`:Simulation -> :Data -> :Layout -> :Plot -> :Slider -> :PlotData -> :UI`). 

It prevents reactive race conditions by blocking lower-tier UI triggers from firing while heavy upstream numeric fetches or layout rebuilds are actively executing. Contains a bypass explicitly designed for pristine headless figure exports.
"""
macro with_lock(lock_name, expr)
    return quote
        local lname = $(esc(lock_name))
        local locks = manager.locks
        
        # THE FIX: Allow pristine figures to bypass locks during headless exports!
        if get(manager.state, :Bypass_Locks, false)
            $(esc(expr))
        elseif !locks[lname]
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

"""
    get_base_layout_options()

Returns the default structural layout dictionary. Dynamically switches between continuous Eulerian line plots and Lagrangian scatter plots depending on the active `manager.mode`.
"""
function get_base_layout_options()
    # THE FIX: Check the mode dynamically!
    is_lag = manager.mode[] == :lagrangian
    
    return Dict{Symbol, Any}(
        :base_plot       => is_lag ? :scatter : :lines,
        :plot_style      => is_lag ? :scatter_1d : :lines_1d,
        :compare_target  => :none, 
        :compare_columns => 2,     
        :compare_link    => :fully_coupled,
        :legend_base     => :right,
        :legend_add      => :detached,
        :plot_width      => 500,
        :plot_height     => 400,
    )
end

"""
    set_mode!(mode::Symbol)

Switches the fundamental operation mode of the UI (e.g., `:eulerian` or `:lagrangian`). This alters which primitive engines are loaded and triggers a complete state purge.
"""
set_mode!(mode::Symbol) = (manager.mode[] = mode)

"""
    force_simulation()

Manually pushes an asynchronous trigger to the `:Simulation` observable, forcing the backend to re-evaluate the active `SimulationConfig`.
"""
force_simulation() = notify(manager.triggers[:Simulation])

"""
    simulation_trigger()

The primary asynchronous worker mapped to the `:Simulation` lock. 

It safely checks the validity of the current `SimulationConfig`, executes the headless numerical loops via `PDECore.run_all_simulations`, caches the updated multi-dimensional arrays, and hands the payload over to the `:Layout` lock to begin mapping the UI.
"""
function simulation_trigger() 
    @with_lock :Simulation begin
        
        curr_config = manager.active_config
        (isnothing(curr_config) || curr_config.simulation_func === dummy_simulation_function) && return

        active_methods = curr_config.active_methods
        
        if isempty(active_methods)
            @warn "No methods selected. Please activate at least one method to run."
            return
        end

        @info "Running dynamic calculations directly from active config..."
        run_all_simulations(curr_config; calculate_stats = true, force_overwrite = false)
        
        if sort(manager.methods[]) != sort(active_methods)
            manager.methods[] = copy(active_methods)
        end
        
        @info "Running Simulation and Mapping UI..."

        # THE FIX: Mapping is already handled by set_sim_config! 
        # We just need to update the plot data.
        manager.locks[:Layout] = true
        try
            update_plot_data_collection!(manager.plot_data[], curr_config, manager.methods[]; force_reload = true)
            notify(manager.plot_data)
        finally
            manager.locks[:Layout] = false
            manager.flags[:Simulation][] = false
        end
    end
    manager.triggers[:Data][] += 1
end

"""
    reset_manager!()

Performs a deep purge of the entire `PlotManager` architecture. 

It empties all UI dictionaries, safely clears reactive `on` and `onany` listeners to prevent dangling references, reconstructs the base observable trigger tree, and repopulates the hierarchical default styles from the master templates.
"""
function reset_manager!()
    
    empty!(manager.ui); empty!(manager.widgets)
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
        manager.flags[k]    = Observable(false) 
    end
    
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

    manager.state[:Camera_Cache] = Dict{Symbol, Any}()
    manager.state[:Slider_Cache] = Dict{Symbol, Float64}()
    manager.state[:Layout_Cache] = get_base_layout_options()
    manager.state[:Plot_Cache]   = Dict{Symbol, Any}()
    manager.state[:Exploration_Cache] = Dict{Symbol, Any}()

    manager.state[:Compare_State] = (:none, nothing, String[], Any[])

    # NEW: Generic Dimensional Resolution Tracking
    manager.state[:Resolution_Base] = Dict{Symbol, Int}()
    manager.state[:Resolution_Ref]  = Dict{Symbol, Int}()
    
    # Auto-populate defaults based on the active allowed dimensions
    for d in manager.allowed_dims
        # Optional: Provide a slightly lower default for time if desired
        manager.state[:Resolution_Base][d] = d === :t ? 50 : 200
        manager.state[:Resolution_Ref][d]  = d === :t ? 100 : 400
    end
    # ---------------------------------------------

    manager.maps[:Labels] = Dict{Symbol, String}()
    manager.maps[:Presets] = deepcopy(PRESET_DESCRIPTIONS)

    # Set plot defaults
    set_plot_preset!()

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
