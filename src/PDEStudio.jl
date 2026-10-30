module PDEStudio

# --- 1. Global Dependencies ---
using Makie, CairoMakie, Reexport
using Observables: ObserverFunction, onany
using Dates, CSV, DataFrames, Pkg, LibGit2, Printf, Statistics, StaticArrays

@reexport using PDEStudioCore

# PDEStudio needs the refactored backend (cleaned SimulationConfig fields, StatsView, safe str2val).
if !(isdefined(PDEStudioCore, :StatsView) && hasfield(SimulationConfig, :varied))
    error("PDEStudio requires the new PDEStudioCore (SimulationConfig with `varied`, `defaults`, …), but an older " *
          "version is loaded from $(pathof(PDEStudioCore)). Use the new version, e.g. `pkg> dev /path/to/PDEStudioCore.jl`.")
end

export launch_plotter, set_sim_config!, reset_plotter!, reset_manager!, set_mode!, set_allowed_dims!, set_max_params!, set_plot_preset!, force_simulation, set_resolution!
export set_sim_preset!, save_sim_preset, save_plot_preset, reset_sim_config!

# Placeholder text of the ":create_new" entry in the preset editors.
const DEFAULT_PRESET_DESC = "Type a description here, a name in the filename box, then click Save."

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

A wrapper mapping an N-dimensional parameter sweep to its corresponding `PDEStudioCore` simulation data.
Stores the actual Cartesian tensor of `AbstractSimData` objects alongside the exact keys and values of the active parameter grid.
"""
struct PlotSweepData{N} <: AbstractPlotData
    data::Array{Union{Nothing, AbstractSimData}, N} 
    active_param_keys::Vector{Symbol}
    active_param_values::Vector{Vector{Any}}
end

"""
    PlotManager

The central reactive state of the `PDEStudio` interface: the widgets of the open window, the bound
`SimulationConfig`, the loaded sweep data, the persistent option caches and the trigger / lock
hierarchy that keeps the headless backend and the Makie frontend from racing each other.

A single instance exists (`PDEStudio.manager`); [`reset_manager!`](@ref) returns it to its pristine
state and [`reset_plotter!`](@ref) closes the window. The `locks` are re-entrancy guards for the
synchronous observable cascades (see [`@with_lock`](@ref)), not thread locks.
"""
Base.@kwdef mutable struct PlotManager
    # --- UI dictionaries, widgets and the trigger hierarchy ---
    ui::Dict{Symbol, Dict{Symbol, Any}} = Dict{Symbol, Dict{Symbol, Any}}()     # active UI style scopes
    widgets::Dict{Symbol, Any} = Dict{Symbol, Any}()                            # Makie blocks of the open window
    panels::Dict{Symbol, GridLayout} = Dict{Symbol, GridLayout}()               # widget groups of the control tabs
    panel_park::Union{Nothing, GridLayout} = nothing                            # off-screen layout of hidden panels
    tab_area::Union{Nothing, GridLayout} = nothing                              # where the selected tab's panels go
    active_tab::Observable{Symbol} = Observable(:plot)                          # selected tab of the control panel
    park_slots::Dict{UInt, Int} = Dict{UInt, Int}()                             # objectid => column in `panel_park`
    editor_view::Dict{Symbol, Tuple{Union{Nothing, Symbol}, Int}} =             # category => (scope or `nothing`
        Dict{Symbol, Tuple{Union{Nothing, Symbol}, Int}}()                      #   for the overview, page)
    editor_row_keys::Vector{Any} = Any[]                                        # key bound to each shown editor row
    editor_page_scopes::Vector{Symbol} = Symbol[]                               # scope of each shown overview button
    triggers::Dict{Symbol, Observable{Int}} = Dict{Symbol, Observable{Int}}()   # one trigger per tier of LOCK_HIERARCHY
    flags::Dict{Symbol, Observable{Bool}} = Dict{Symbol, Observable{Bool}}()    # "pending" flags per tier (button colours)
    locks::Dict{Symbol, Bool} = Dict{Symbol, Bool}()                            # re-entrancy guards per tier / menu chain
    listeners::Dict{Symbol, Union{ObserverFunction, Vector{ObserverFunction}}} =
        Dict{Symbol, Union{ObserverFunction, Vector{ObserverFunction}}}()

    # --- display names, presets and the slider mapping ---
    labels::Dict{Symbol, String} = Dict{Symbol, String}()            # custom display names (`set_label!`)
    presets::Dict{Symbol, String} = Dict{Symbol, String}()           # visual presets: name => description
    sim_presets::Dict{Symbol, String} = Dict{Symbol, String}()       # simulation presets: name => description
    param_map::Dict{Symbol, Symbol} = Dict{Symbol, Symbol}()         # slider key (:param_i) => swept parameter
    reverse_map::Dict{Symbol, Symbol} = Dict{Symbol, Symbol}()       # swept parameter => slider key

    # --- the simulation and its data ---
    methods::Observable{Vector{Symbol}} = Observable(Symbol[])       # active methods (drawn)
    plot_vars::Vector{Symbol} = Symbol[]                             # [swept parameters; base dimensions]
    caches::Dict{Int, Dict{Symbol, AbstractPlotCache}} = Dict{Int, Dict{Symbol, AbstractPlotCache}}()
    active_config::Union{Nothing, SimulationConfig} = nothing        # `nothing` until a configuration is bound
    base_config::Union{Nothing, SimulationConfig} = nothing          # baseline that `reset_sim_config!` returns to
    plot_data::Observable{Dict{Symbol, AbstractPlotData}} = Observable(Dict{Symbol, AbstractPlotData}())
    mode::Observable{Symbol} = Observable{Symbol}(:eulerian)
    allowed_dims::Tuple{Vararg{Symbol}} = (:x, :y, :z, :t)
    max_params::Int = 2
    resolution_base::Dict{Symbol, Int} = Dict{Symbol, Int}()         # display resolution per dimension (numerical data)
    resolution_ref::Dict{Symbol, Int} = Dict{Symbol, Int}()          # display resolution per dimension (references)

    # --- the window ---
    is_open::Bool = false
    master_fig::Union{Nothing, Figure} = nothing
    plot_window_initialized::Observable{Bool} = Observable(false)
    main_render_observers::Vector{ObserverFunction} = ObserverFunction[]

    # --- reactive UI state ---
    active_axes::Observable{Vector{Int}} = Observable{Vector{Int}}(Int[])    # indices into plot_vars bound to plot axes
    is_activate_mode::Observable{Bool} = Observable(true)                     # method menu activates (or deactivates)
    is_animating::Observable{Bool} = Observable(false)
    animation_timer::Observable{Union{Nothing, Timer}} = Observable{Union{Nothing, Timer}}(nothing)
    layout_dict::Observable{Dict{Symbol, Any}} = Observable(Dict{Symbol, Any}())   # subplot grid of the current layout
    camera_locked::Observable{Bool} = Observable(false)

    # --- persistent caches (they outlive a closed window) ---
    camera_cache::Dict{Symbol, Any} = Dict{Symbol, Any}()
    slider_cache::Dict{Symbol, Float64} = Dict{Symbol, Float64}()
    layout_cache::Dict{Symbol, Any} = Dict{Symbol, Any}()
    plot_cache::Dict{Symbol, Any} = Dict{Symbol, Any}()
    exploration_cache::Dict{Symbol, Any} = Dict{Symbol, Any}()
    compare_state::Tuple{Symbol, Union{Nothing, Int}, Vector{String}, Vector} = (:none, nothing, String[], Any[])
    plot_titles::Vector{String} = String[]
    active_plot_type::Symbol = :none                                 # :none before the first layout
    csv_cache::Union{Nothing, NamedTuple} = nothing                  # structural CSV staged until "Run Simulation"
    is_exporting::Bool = false
    skip_next_camera_extract::Bool = false
    bypass_locks::Bool = false
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
    _sync_resolution_dims!()
    @info "Plotter UI configured for dimensions: $dims"
end

# Makes sure every allowed dimension has a display resolution (the time axis gets coarser defaults).
function _sync_resolution_dims!()
    for d in manager.allowed_dims
        get!(manager.resolution_base, d, d === :t ? 50 : 200)
        get!(manager.resolution_ref, d, d === :t ? 100 : 400)
    end
    return nothing
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
    target = is_ref ? manager.resolution_ref : manager.resolution_base
    target[dim] = val
end

"""
    get_resolution(dim::Symbol; is_ref::Bool=false)

Retrieves the active UI resolution for a given dimension, automatically falling back to sensible defaults (200 for numerical, 400 for analytical) if the dimension was dynamically generated during a sweep.
"""
function get_resolution(dim::Symbol; is_ref::Bool=false)
    target = is_ref ? manager.resolution_ref : manager.resolution_base
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
        
        if manager.bypass_locks
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
include("Presets.jl")

"""
    get_base_layout_options()

Returns the default structural layout dictionary. Dynamically switches between continuous Eulerian line plots and Lagrangian scatter plots depending on the active `manager.mode`.
"""
function get_base_layout_options()

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

Switches the fundamental operation mode of the UI (e.g., `:eulerian` or `:lagrangian`). This alters which primitive engines are loaded and resets the UI state. The bound `SimulationConfig` is kept (call `launch_plotter()` again and press *Run Simulation*).
"""
function set_mode!(mode::Symbol)
    mode in (:eulerian, :lagrangian) || throw(ArgumentError("mode must be :eulerian or :lagrangian, got :$mode"))
    manager.mode[] = mode
end

"""
    force_simulation()

Manually pushes an asynchronous trigger to the `:Simulation` observable, forcing the backend to re-evaluate the active `SimulationConfig`.
"""
force_simulation() = notify(manager.triggers[:Simulation])

"""
    simulation_trigger()

The primary asynchronous worker mapped to the `:Simulation` lock. 

It safely checks the validity of the current `SimulationConfig`, executes the headless numerical loops via `PDEStudioCore.run_all_simulations`, caches the updated multi-dimensional arrays, and hands the payload over to the `:Layout` lock to begin mapping the UI.
"""
function simulation_trigger()
    ran = false
    @with_lock :Simulation begin

        curr_config = manager.active_config
        isnothing(curr_config) && return

        active_methods = curr_config.defaults

        if isempty(active_methods)
            @warn "No methods selected. Please activate at least one method to run."
            return
        end

        @info "Running dynamic calculations directly from active config..."
        run_all_simulations(curr_config; calculate_stats = true, force_overwrite = false)

        if manager.methods[] != active_methods   # order matters: it is the legend / comparison order
            manager.methods[] = copy(active_methods)
        end

        @info "Running Simulation and Mapping UI..."

        manager.locks[:Layout] = true
        try
            update_plot_data_collection!(manager.plot_data[], curr_config, manager.methods[]; force_reload = true)
            notify(manager.plot_data)
        finally
            manager.locks[:Layout] = false
            manager.flags[:Simulation][] = false
        end
        ran = true
    end
    # Only continue the cascade if a simulation actually ran (not when blocked or without a config).
    ran && (manager.triggers[:Data][] += 1)
    return nothing
end

"""
    reset_manager!()

Returns the `PlotManager` to its pristine state: detaches every listener, drops the UI dictionaries,
widgets, caches, labels and the bound configuration, rebuilds the trigger tree and reloads the default
styles and the presets found on disk. The mode, the allowed dimensions, the number of parameter
sliders and the window handle are kept (see [`reset_plotter!`](@ref) for the window).
"""
function reset_manager!()
    for (_, listener_node) in manager.listeners
        if listener_node isa Vector
            for l in listener_node; off(l); end
        else
            off(listener_node)
        end
    end

    fresh = PlotManager()
    for field in fieldnames(PlotManager)
        field in (:mode, :allowed_dims, :max_params, :is_open, :master_fig, :methods, :plot_data) && continue
        setfield!(manager, field, getfield(fresh, field))
    end
    manager.methods.val = Symbol[]
    manager.plot_data.val = Dict{Symbol, AbstractPlotData}()

    for k in LOCK_HIERARCHY
        manager.triggers[k] = Observable(0)
        manager.locks[k]    = false
        manager.flags[k]    = Observable(false)
    end
    manager.listeners[:Simulation] = on(manager.triggers[:Simulation]) do _; simulation_trigger() end
    for k in (:Menu_Sync, :Menu_A, :Menu_B, :Menu_C, :Menu_D)
        manager.locks[k] = false
    end

    _sync_resolution_dims!()
    manager.layout_cache = get_base_layout_options()
    manager.presets = Dict{Symbol, String}(PRESET_DESCRIPTIONS)

    # Set plot defaults
    set_plot_preset!()

    # Initialize the default creation text and register the presets found on disk
    manager.presets[:create_new] = DEFAULT_PRESET_DESC
    manager.sim_presets[:create_new] = DEFAULT_PRESET_DESC
    refresh_preset_registries!()
    return nothing
end

function __init__()
    on(manager.mode) do _
        # Keep the bound simulation across a mode switch; everything else is rebuilt.
        config = manager.active_config
        base = manager.base_config
        reset_plotter!()
        reset_manager!()
        if !isnothing(config)
            set_sim_config!(config; snapshot = false)
            isnothing(base) || (manager.base_config = base)
        end
    end
    reset_manager!()
end

end
