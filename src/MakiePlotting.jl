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


function show_unified_fig(
    sim_config::SimulationConfig;
    ui_options::UIType = :default,
    scene_options::Dict = Dict{String, Any}()
)
    # --- 1. Initialization ---
    ui_nested = createUIDict(ui_options)
    scene_default = Dict{String, Any}("t" => 0.0, "component" => 1)
    scene_dict = merge(scene_default, scene_options)
    
    # Create the single source of truth
    manager = create_plot_manager(sim_config, ui_nested, scene_dict)
    
    plot_fig = Figure(size = manager.ui["Axis"]["figsize"][])
    ax = Axis(plot_fig[1, 1])
    
    # Storage for the current batch of 5D tensors
    plot_data_dict = Dict{String, UnifiedPlotData}()

    # --- 2. Create UI Controls ---
    # fig_ctrl is the sidebar, plot_slot is where sliders will go
    fig_ctrl, update_notifier, methods_obs, plot_slot = create_controls(plot_fig, manager)

    # --- 3. The "Data Loader" Lift (Case 1 & 2) ---
    # Triggered by the "Refresh" button or method toggles
    # We combine them so any change in method selection or a forced refresh reloads tensors
    lift(update_notifier, methods_obs) do _, active_methods
        
        # Determine fixed params for the "Refresh" (Case 1)
        # We extract values from manager.simulation["shared"] and method defaults
        fixed_params = Dict{String, Any}()
        for (k, obs) in manager.simulation["shared"]
            fixed_params[k] = obs[]
        end

        # Run orchestrator to ensure data exists and load into tensors
        # Note: We pass force_reload=true if triggered by update_notifier
        update_plot_data_collection!(
            plot_data_dict, 
            sim_config, 
            active_methods, 
            fixed_params; 
            force_reload = (update_notifier[] > 0)
        )

        # --- 4. Rebuild Plot Controls ---
        # Every time the data batch changes, we must rebuild the sliders
        # because the parameter ranges or time steps might have changed.
        
        # Clear the old slot and inject new menus/sliders
        x_obs, y_obs, dim_obs, selectors = Controls.attach_plot_controls!(plot_slot, plot_data_dict)

        # --- 5. Start/Restart the Rendering Lift ---
        # This connects the newly created sliders to the Axis
        setup_render_lift!(ax, plot_fig, plot_data_dict, manager, x_obs, y_obs, dim_obs, selectors)
    end

    # Initial trigger to start the first load
    update_notifier[] = 0 
    
    return plot_fig, fig_ctrl, manager
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