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
    ui_nested = createUIDict(ui_options)
    scene_default = Dict{String, Any}("t" => 0.0, "component" => 1)
    scene_dict = merge(scene_default, scene_options)
    
    manager = create_plot_manager(sim_config, ui_nested, scene_dict)
    plot_fig = Figure(size = (400,400))
    ax = Axis(plot_fig[1, 1])
    Axis
    # 1. Store plot data in a reactive Observable dict
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())

    # Determine fixed grid dimensions (P1, P2...) early to build static UI
    active_params = sort(collect(keys(sim_config.varied_params)))

    # 2. Create Static Controls Once
    fig_ctrl, update_notifier, ui_update, methods_obs, x_obs, y_obs, dim_obs, selectors = 
        Controls.create_controls(plot_fig, manager, plot_data_obs, active_params)

    # 3. Data Loader Lift
    lift(update_notifier, methods_obs) do _, active_methods
        fixed_params = Dict{String, Any}()
        for (k, obs) in manager.simulation["shared"]
            fixed_params[k] = obs[]
        end

        # Work on a copy to batch changes, then push to the observable once
        new_plot_data = copy(plot_data_obs[])
        
        update_plot_data_collection!(
            new_plot_data, 
            sim_config, 
            active_methods, 
            fixed_params;
            force_reload = (update_notifier[] > 0)
        )
        
        # This push triggers build_static_plot_controls! to update all slider ranges natively
        plot_data_obs[] = new_plot_data
    end

    # 4. Start Rendering Lift
    setup_render_lift!(ax, plot_fig, plot_data_obs, manager, x_obs, y_obs, dim_obs, ui_update, selectors)

    update_notifier[] = 0 
    return plot_fig, fig_ctrl, manager
end


# ==============================================================================
# In MakiePlotting.jl - Replace setup_render_lift! and find_closest_index_for_dim
# ==============================================================================

# ==============================================================================
# In MakiePlotting.jl - Replace setup_render_lift!
# ==============================================================================

function setup_render_lift!(ax, plot_fig, plot_data_obs, manager, x_key_obs, y_key_obs, plot_dim_obs, ui_update, selectors)

    lift(plot_data_obs, ui_update, x_key_obs, y_key_obs, plot_dim_obs, selectors...) do plot_data_dict, _, x_key, y_key, dim_idx, sel_vals...
        
        # 1. Basic Validation
        (isnothing(x_key) || isnothing(y_key) || x_key == "-" || y_key == "-" || dim_idx == 0) && return
        isempty(plot_data_dict) && return
        
        # 2. Derive Dimension Names (Map indices to descriptive strings)
        # Based on Controls.jl: 1=Comp, 2..N+1=Params, N+2=Space, N+3=Time 
        pd_sample = first(values(plot_data_dict))
        active_params = pd_sample.active_param_keys
        n_p = length(active_params)
        
        dim_names = Dict{Int, String}()
        for (i, p) in enumerate(active_params); dim_names[i] = p; end
        dim_names[n_p + 1] = "Component"
        dim_names[n_p + 2] = "Space"
        dim_names[n_p + 3] = "Time"

        # 3. Construct the Dynamic Title
        title_parts = String[]
        for i in eachindex(sel_vals)
            name = get(dim_names, i, "Dim$i")
            if i == dim_idx
                push!(title_parts, "[Along $name]") # Marker for Plotting Axis
            else
                val = sel_vals[i]
                # Round floats for cleanliness in the title
                val_str = val isa AbstractFloat ? string(round(val, digits=3)) : string(val)
                push!(title_parts, "$name: $val_str")
            end
        end
        # Format: "y_key vs x_key | [Along Time], Component: 1, Space: 2.5"
        generated_title = "$y_key vs $x_key | " * join(title_parts, ", ")

        # 4. Extract Data Slices
        active_methods = manager.methods[]
        xs_to_plot = Vector{Vector{Float64}}()
        us_to_plot = Vector{Vector{Float64}}()
        valid_labels = String[]

        for m_name in active_methods
            !haskey(plot_data_dict, m_name) && continue
            pd = plot_data_dict[m_name]
            
            indices = map(1:length(sel_vals)) do i
                i == dim_idx ? (:) : find_closest_index_for_dim(pd, i, sel_vals[i])
            end
            
            try
                push!(xs_to_plot, vec(pd.data[x_key][indices...]))
                push!(us_to_plot, vec(pd.data[y_key][indices...]))
                push!(valid_labels, m_name)
            catch; end
        end

        # 5. Call Plotter with dynamic labels and title
        update_base_plot_1D!(
            plot_fig, ax, valid_labels, xs_to_plot, us_to_plot, manager;
            xlabel = x_key, 
            ylabel = y_key, 
            title_str = generated_title
        )
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