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
        fixed_params = ParamDict(k => v[] for (k, v) in manager.simulation["shared"])
        # Reload/Simulate data
        update_plot_data_collection!(
            plot_data_obs[], sim_config, active_methods, fixed_params, to_value(manager.controls["base_types"]);
            force_reload = (sim_update[] > 0), 
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

function setup_render_lift!(ax, plot_fig, plot_data_obs, manager::PlotManager{D}) where {D}
    c = manager.controls
    dim_names = manager.plot_vars # This is natively strictly ordered!
    
    # 1. Gather the ordered selector observables based on plot_vars
    selector_obs = Observable[]
    for name in dim_names
        # Safely fetch either the Slider Value or the Menu Selection
        if haskey(c, "$(name)_Value")
            push!(selector_obs, c["$(name)_Value"])
        elseif haskey(c, "$(name)_Selection")
            push!(selector_obs, c["$(name)_Selection"])
        else
            @warn "No selector widget found for dimension: $name"
        end
    end

    # Pass the ordered selector_obs into the lift
    lift(plot_data_obs, c["X-Axis_Selection"], c["Y-Axis_Selection"], 
         c["Plot-Along_Selection"], c["UI_Update"], selector_obs...) do data, x_key, y_key, dim_idx, _ui, sel_vals...
        
        # 1. Validation
        if isnothing(x_key) || isnothing(y_key) || isnothing(dim_idx)
            return
        end
        (isnothing(x_key) || isnothing(y_key) || x_key == "-" || dim_idx == 0) && return
        isempty(data) && return
        
# 2. Data Slicing
        active_methods = manager.methods[]
        xs_to_plot, us_to_plot, valid_labels = Vector{Float64}[], Vector{Float64}[], String[]

        for m_name in active_methods
            !haskey(data, m_name) && continue
            pd = data[m_name]
            
            x_tensor = pd.data[x_key]
            y_tensor = pd.data[y_key]
            
            # Map values back to tensor indices (clamp to actual size to safely ignore size-1 axes!)
            x_indices = map(1:ndims(x_tensor)) do i
                if i == dim_idx; return (:); end
                val = sel_vals[i] isa String ? parse(Int, sel_vals[i]) : sel_vals[i]
                return min(find_closest_index_for_dim(pd, i, val, D), size(x_tensor, i))
            end
            
            y_indices = map(1:ndims(y_tensor)) do i
                if i == dim_idx; return (:); end
                val = sel_vals[i] isa String ? parse(Int, sel_vals[i]) : sel_vals[i]
                return min(find_closest_index_for_dim(pd, i, val, D), size(y_tensor, i))
            end
            
            try
                push!(xs_to_plot, vec(x_tensor[x_indices...]))
                push!(us_to_plot, vec(y_tensor[y_indices...]))
                push!(valid_labels, m_name)
            catch e
                @warn "Slicing failed for method $m_name" exception=e
            end
        end

        # 3. Plotting
        # Make sure your generate_dynamic_title function is also updated to accept the new ordered sel_vals
        title_str = generate_dynamic_title(dim_idx, dim_names, sel_vals)
        update_base_plot_1D!(plot_fig, ax, valid_labels, xs_to_plot, us_to_plot, manager;
                             xlabel=x_key, ylabel=y_key, title_str=title_str)
    end
end

"""
    find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real, D::Int)

Maps a physical value from a slider back to the correct tensor index.
1..N = Params, N+1 = Component, N+2..N+1+D = Space, N+2+D = Time.
"""
function find_closest_index_for_dim(pd::UnifiedPlotData, dim_idx::Int, target_val::Real, D::Int)
    n_params = length(pd.active_param_keys)
    
    if dim_idx <= n_params # Parameter
        p_vals = pd.active_param_values[dim_idx]
        return findmin(v -> abs(v - target_val), p_vals)[2]
        
    elseif dim_idx == n_params + 1 # Component
        return max(1, Int(target_val))
        
    elseif dim_idx > n_params + 1 && dim_idx <= n_params + 1 + D # Space (X, Y, Z...)
        if haskey(pd.data, "x")
            x_tensor = pd.data["x"]
            # Grab a 1D spatial vector by targeting index 1 for all non-spatial dimensions
            inds = ntuple(i -> i == dim_idx ? (:) : 1, ndims(x_tensor))
            x_vec = vec(x_tensor[inds...])
            
            # Filter out NaNs (Lagrangian padding) safely
            valid_idx = findall(!isnan, x_vec)
            if isempty(valid_idx)
                return 1
            end
            
            closest_valid = findmin(v -> abs(v - target_val), x_vec[valid_idx])[2]
            return valid_idx[closest_valid]
        end
        return 1 
        
    elseif dim_idx == n_params + 2 + D # Time
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