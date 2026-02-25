module MakiePlotting

using ..Structs
using ..Utils
#using ..StatCalculation
using ..Controls
using ..DataProcessing
using IPlotPDESols: registerAllFunctions
using GLMakie
using CSV, DataFrames
using Dates # For timestamp in optional info
using ProgressMeter


export show1DSolutionFig, show2DCutFig, show2DSolutionFig, showDynamicDependence, showConvergencePlot, show2DConvergencePlot, GetUIStyle, plotFromCSV, interactiveCSVLauncher
export show_unified_fig
include("UIStyles.jl")
include("PlottingUtils.jl")
#include("Controls.jl")
# include("show1DSolutionFig.jl")
# include("show2DSolutionFig.jl")
# include("showDynamicDependence.jl")
# include("showConvergencePlot.jl")
# include("show2DConvergencePlot.jl")
# include("show2DCutFig.jl")


# ==============================================================================
# In MakiePlotting.jl - Replace show_unified_fig and setup_render_lift!
# ==============================================================================

function show_unified_fig(
    sim_config::SimulationConfig;
    ui_options::UIType = :default,
    scene_options::Dict = Dict{String, Any}()
)
    # 1. Setup Manager & Figure
    manager = create_plot_manager(sim_config, createUIDict(ui_options))
    plot_fig = Figure(size = manager.ui["Axis"]["figsize"][])
    ax = Axis(plot_fig[1, 1])
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())

    # 2. Build UI (This populates manager.controls)
    # We only return the Figure and the specific observables needed for the data-load trigger
    ctrl_fig = Controls.create_controls(plot_fig, manager, plot_data_obs)
    
    # 3. Pull needed observables from the manager for data loading
    sim_update = manager.controls["Simulation_Update"]
    methods_obs = manager.methods
    
    lift(sim_update, methods_obs) do _, active_methods
        fixed_params = Dict(k => v[] for (k, v) in manager.simulation["shared"])
        
        # Reload/Simulate data
        update_plot_data_collection!(
            plot_data_obs[], sim_config, active_methods, fixed_params;
            force_reload = (sim_update[] > 0)
        )
        notify(plot_data_obs)
    end

    # 4. Clean Render Setup
    setup_render_lift!(ax, plot_fig, plot_data_obs, manager)

    sim_update[] = 0 
    return plot_fig, ctrl_fig, manager
end


# ==============================================================================
# In MakiePlotting.jl - Replace setup_render_lift! and find_closest_index_for_dim
# ==============================================================================

# ==============================================================================
# In MakiePlotting.jl - Replace setup_render_lift!
# ==============================================================================

function setup_render_lift!(ax, plot_fig, plot_data_obs, manager)
    # UNPACK: Grab exactly what we need from the store
    c = manager.controls
    
    # Identify which sliders exist to pass them into the lift
    # We filter for anything that represents a "Value" or "Selection" 
    # except the ones we already explicitly named.
    selector_keys = filter(k -> endswith(k, "_Value") || endswith(k, "_Selection"), collect(keys(c)))
    # Remove axis selections so we don't double-count them in the lift
    filter!(k -> !occursin("Axis", k) && !occursin("Plot-Along", k), selector_keys)
    
    selectors = [c[k] for k in sort(selector_keys)]

    lift(plot_data_obs, c["X-Axis_Selection"], c["Y-Axis_Selection"], 
         c["Plot-Along_Selection"], c["UI_Update"], selectors...) do data, x_key, y_key, dim_idx, _ui, sel_vals...
        
        # 1. Validation
        (isnothing(x_key) || isnothing(y_key) || x_key == "-" || dim_idx == 0) && return
        isempty(data) && return
        
        # 2. Data Slicing
        active_methods = manager.methods[]
        xs_to_plot, us_to_plot, valid_labels = [], [], String[]

        for m_name in active_methods
            !haskey(data, m_name) && continue
            pd = data[m_name]
            
            # Map values back to tensor indices
            # Note: sel_vals is in the same order as selector_keys
            indices = map(1:ndims(pd.data[x_key])) do i
                if i == dim_idx
                    return (:)
                else
                    # Find which slider/menu corresponds to this dimension
                    # (Implementation logic depends on your dim_names mapping)
                    return find_closest_index_for_dim(pd, i, get_val_for_dim(i, selector_keys, sel_vals))
                end
            end
            
            try
                push!(xs_to_plot, vec(pd.data[x_key][indices...]))
                push!(us_to_plot, vec(pd.data[y_key][indices...]))
                push!(valid_labels, m_name)
            catch; end
        end

        # 3. Plotting
        title_str = generate_dynamic_title(x_key, y_key, dim_idx, manager, selector_keys, sel_vals)
        update_base_plot_1D!(plot_fig, ax, valid_labels, xs_to_plot, us_to_plot, manager;
                             xlabel=x_key, ylabel=y_key, title_str=title_str)
    end
end

"""
    find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real)

Maps a physical value from a slider back to the correct tensor index.
1 = Component, 2..N+1 = Params, N+2 = Space, N+3 = Time.
"""
function find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real)
    n_params = length(pd.active_param_keys)
    
    if dim_idx <= n_params # Parameter
        p_vals = pd.active_param_values[dim_idx]
        return findmin(v -> abs(v - target_val), p_vals)[2]
        
    elseif dim_idx == n_params + 1 # Component
        return Int(target_val)
        
    elseif dim_idx == n_params + 2 # Space
        # 3. FIX: If the user slides the Space slider to grab a specific X coordinate, 
        # find the index of the closest spatial point dynamically.
        if haskey(pd.data, "x")
            x_tensor = pd.data["x"]
            # Grab a 1D spatial vector by targeting index 1 for all non-spatial dimensions
            inds = ntuple(i -> i == dim_idx ? (:) : 1, ndims(x_tensor))
            x_vec = vec(x_tensor[inds...])
            return findmin(v -> abs(v - target_val), x_vec)[2]
        end
        return 1 
        
    elseif dim_idx == n_params + 3 # Time
        return findmin(v -> abs(v - target_val), pd.t_vals)[2]
    end
    
    return 1
end

function plotFromCSV(csv_filepath::String; kwargs...)
    ui_options = load_additional_options_from_csv(csv_filepath, "UI")
    scene_options = load_additional_options_from_csv(csv_filepath, "Scene")
    sim_config = create_sim_config_from_csv(csv_filepath)
    if haskey(scene_options,"variation_range") && haskey(scene_options,"varied_key")
        return showConvergencePlot(sim_config, scene_options["varied_key"], 
                                   scene_options["variation_range"]; ui_options = ui_options,
                                   scene_options = scene_options, kwargs...)
    elseif haskey(ui_options, "plot_as_surface")
        return show2DSolutionFig(sim_config; scene_options = scene_options, ui_options = ui_options, kwargs...)
    elseif haskey(scene_options, "line_point") && haskey(scene_options,"line_vector")
        return show2DCutFig(sim_config; scene_options = scene_options, ui_options = ui_options, kwargs...)
    elseif haskey(scene_options, "y_key") && !haskey(scene_options, "t")
        return showDynamicDependence(sim_config; scene_options = scene_options, ui_options = ui_options, kwargs...)
    elseif !haskey(scene_options, "y_key") && !haskey(scene_options, "x_key")
        return show1DSolutionFig(sim_config; scene_options = scene_options, ui_options = ui_options, kwargs...)
    else
        error("A required key is missing, use a supported CSV file!")
    end
end

"""
    interactiveCSVLauncher()

Launches a small, simple Makie window that serves as a drag-and-drop target.
Dropping a valid CSV file onto this window will call `plotFromCSV` to spawn a
separate, new window containing the plot.
"""
function interactiveCSVLauncher(;kwargs...)

    registerAllFunctions()
    # --- 1. Setup the simple UI Figure for Drag-and-Drop ---
    launcher_fig = Figure(size = (600, 200))
    
    # An axis to serve as the drag-and-drop target area
    ax_drop = Axis(launcher_fig[1, 1],
                   title = "Drag & Drop a '_params.csv' file here",
                   titlealign = :center)
    
    hidespines!(ax_drop)
    hidedecorations!(ax_drop) # Hides ticks, labels, etc.

    # --- 2. Setup the Reactive Logic ---
    
    # Listen for files being dropped onto the window
    on(events(launcher_fig).dropped_files) do files
        if isempty(files); return; end
        
        first_file = files[1]
        
        if endswith(lowercase(first_file), ".csv")
            @info "CSV file dropped: $first_file"
            ax_drop.title = "Processing: $(basename(first_file))"
            
            # Use a `try...catch` block to prevent the launcher from crashing
            # if the plotting function fails.
            try
                # Call the dispatcher. This will create and display a NEW window.
                plotFromCSV(first_file; kwargs...)
                ax_drop.title = "Success! Drop another file."
            catch e
                error_message = "Error plotting file: $e"
                @error error_message exception=(e, catch_backtrace())
                ax_drop.title = "Error! See REPL. Drop another file."
            end
        else
            ax_drop.title = "Error: Dropped file is not a .csv file. Try again."
            @warn "Warning: Ignored non-CSV file drop: $first_file"
        end
        display(launcher_fig)
    end

    # --- 3. Display the Launcher Figure ---
    @info "CSV Plot Launcher is active."
    GLMakie.activate!()
    display(GLMakie.Screen(),launcher_fig)
    return launcher_fig
end

end