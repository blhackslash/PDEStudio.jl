module MakiePlotting

using ..Structs
using ..Utils
using ..StatCalculation
using IPlotPDESols: registerAllFunctions
using GLMakie
using CSV, DataFrames
using Dates # For timestamp in optional info
using ProgressMeter


export show1DSolutionFig, show2DCutFig, show2DSolutionFig, showDynamicDependence, showConvergencePlot, GetUIStyle, plotFromCSV, interactiveCSVLauncher

include("UIStyles.jl")
include("PlottingUtils.jl")
include("show1DSolutionFig.jl")
include("show2DSolutionFig.jl")
include("showDynamicDependence.jl")
include("showConvergencePlot.jl")
include("show2DCutFig.jl")

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