module MakiePlotting

using ..Structs
using ..Utils
using GLMakie
using CSV, DataFrames

export show1DSolutionFig, show2DSolutionFig, showDynamicDependence, showConvergenceFig, showConvergenceFig2,showConvergenceFig3

ui_dict = Dict(
    "dashed_lines" => false,
    "show_scatter" => false,
    "show_lines" => true,
    "hPos" => :right,
    "vPos" => :top,
    "figsize" => (1280,800),
    "linewidth" => 6,
    "markersize" => 20,
    "label_size" => 24,
    "ticklabel_size" => 22,
    "font_size" => 24,
    "legend" => "Legend",
    "x_axis_limit_padding" => 0,
    "y_axis_limit_padding" => 0.1,
    "colors" => [:red, :blue, :green, :orange, :purple, :brown, :cyan, :yellow, :gray, :magenta, :navy],
    "markers" => [:rect, :circle, :utriangle, :dtriangle, :cross, :xcross],
    "lineStyles" => [:solid, (:dash, :dense), (:dash, :normal), (:dashdot, :dense), (:dashdot, :normal), (:dot, :dense), (:dot, :normal)]
)

# --- ui_dict definition ---
# Add the new option for 2D plotting type
ui_dict2D = Dict(
    # ... (previous keys) ...
    "hPos" => :right,
    "vPos" => :top,
    "figsize" => (1280, 800),
    "markersize_2d" => 15,    # Marker size for 2D scatter plot
    "markersize_3d" => Vec3f(0.2, 0.2, 0.2), # Marker size for 3D meshscatter (can be Vec3f or Float)
    "label_size" => 24,
    "ticklabel_size" => 22,
    "font_size" => 24,
    "legend" => "Legend",
    "colors" => [:red, :blue, :green, :orange, :purple, :brown, :cyan, :yellow, :gray, :magenta, :navy],
    "markers" => [:circle, :rect, :utriangle, :dtriangle, :cross, :xcross], # Markers for legend mostly
    "lineStyles" => [:solid, (:dash, :dense), (:dash, :normal), (:dashdot, :dense), (:dashdot, :normal), (:dot, :dense), (:dot, :normal)], # Less relevant
    "plot_as_surface" => false, # << NEW: false for scatter/heatmap, true for surface
    "colormap" => :viridis,     # Default colormap
    "colormaps" => [:viridis, :plasma, :inferno, :magma, :thermal, :coolwarm, :balance, :grays], # Available colormaps
    "axis_limit_padding" => 0.1
)

function updateUI(ui_dict::Dict, ui_input::Dict)
    @assert issubset(Set(keys(ui_input)), Set(keys(ui_dict))) "At least one of the given UI keys is not used! Check spelling!"
    for (key, val) in ui_input
        # Special handling if user provides scalar for 3d markersize
        if key == "markersize_3d" && isa(val, Real)
            ui_dict[key] = Vec3f(val)
        else
            ui_dict[key] = val
        end
    end
end

# Functions for Makie Controls
function createTextBoxes(fig::Makie.Figure, keys::Vector{String}, params_obs::Dict{String, Observable})
    tbLayout = fig[end+1,:] = GridLayout()
    sort!(keys)
    for (i,key) = enumerate(keys)
        row = mod1(i, 5)
        col = trunc(Int64, (i-1)/5) + 1
        Label(tbLayout[row,2*col-1], key * " = ")
        tb = Textbox(tbLayout[row,2*col], placeholder = string(to_value(params_obs[key])), validator = typeof(to_value(params_obs[key])))
        on(tb.stored_string) do s
            params_obs[key][] = parse(typeof(params_obs[key][]), s)
        end
    end
end

function createSaveFigBox(figControl::Makie.Figure, plot_fig::Makie.Figure, params_obs::Dict{String,Observable})
    saveBox = Textbox(figControl[end+1, 1], placeholder = "Type name to save")
    save_figures = get_save_path() * "/figures/"
    on(saveBox.stored_string) do s
        name = save_figures * s
        #CairoMakie.activate!(pt_per_unit = 1.5)
        #CairoMakie.save( name * ".pdf", plot_fig)
        save(name * ".png", plot_fig)

        ks = sort(collect(keys(params_obs)))
        vals = map(key -> to_value(params_obs[key]), ks)
        dataf = DataFrame(ks .=> vals)
        CSV.write(name * ".csv", dataf)
        
        println("Plot saved as $name" * ".png. To change the directory run set_save_path!")
        
    end
end

function createMethodToggles(fig::Makie.Figure, methods_obs::Observable{Vector{String}}, methods::Vector{String})
    toLayout = fig[end+1,:] = GridLayout() # 5 hard coded atm can be added to ui_dict
    for (i,method) = enumerate(methods)
        Label(toLayout[mod1(i,5),1], method)
        if method == methods_obs[][1]
            tmp = Toggle(toLayout[mod1(i,5),2], active = true)
        else
            tmp = Toggle(toLayout[mod1(i,5),2], active = false)
        end
        on(tmp.active) do active 
            if to_value(active) & !(methods[i] in methods_obs[])
                push!(methods_obs[], methods[i])
            elseif !to_value(active) & (methods[i] in methods_obs[])
                deleteat!(methods_obs[],findfirst(isequal(methods[i]),to_value(methods_obs)))
            end
            notify(methods_obs)
        end
    end
end

function createParameterToggles(fig::Makie.Figure, keys::Vector{String}, obs_dict::Dict{String, Observable})
    ptoLayout = fig[end+1,:] = GridLayout()
    for (i,key) = enumerate(keys)
        Label(ptoLayout[i,1], key)
        toggleTmp= Toggle(ptoLayout[i,2], active = to_value(obs_dict[key]))
        on(toggleTmp.active) do active
            obs_dict[key][] = active[]
        end
    end
end

"""
Creates a Makie figure containing the simulation controls.
"""
function createControls(plot_fig::Makie.Figure, params_obs::Dict{String,Observable}, methods_obs::Observable{Vector{String}}, methods::Vector{String})
    control_fig = Figure(size=(800,700))
    # Split parameters by type
    println(params_obs)
    vals = values(params_obs)
    ks = sort(collect(keys(params_obs)))
    mask_to = map(x -> x[] isa Bool, vals)
    mask_tb = map(x -> x[] isa Real, vals) .& .!mask_to

    # Create control elements
    createTextBoxes(control_fig, ks[mask_tb], params_obs)
    createParameterToggles(control_fig, ks[mask_to], params_obs)
    createMethodToggles(control_fig, methods_obs, methods)
    createSaveFigBox(control_fig, plot_fig, params_obs)

    return control_fig
end

"""
    show1DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot showing the 1D solution `u(x)` at different times `t` 
for various simulation methods.

Uses two figures: one for the plot (`plot_fig`) and one for controls (`control_fig`).
Allows toggling methods, adjusting parameters, and scrubbing through time with a slider.

# # Arguments
# - `sim_config::SimulationConfig`: Configuration object containing the simulation 
#   function (`sim_function`), method definitions (`methods_dict`), shared parameters 
#   (`shared_params`), default method, and UI overrides (`ui_options`). 
#   Assumes `sim_function` returns `SimData1D` with `x`, `u`, `t` fields.
# """
# function show1DSolutionFig(sim_config::SimulationConfig)
#     # --- Basic Setup ---
#     local_ui_dict = deepcopy(ui_dict) # Use a local copy for UI settings
#     updateUI(local_ui_dict, sim_config.ui_options)

#     # Create the main plotting figure and axis
#     plot_fig = Figure(size = local_ui_dict["figsize"])
#     ax = Axis(plot_fig[1,1], xlabel = "Position (x)", ylabel = "Solution Value (u)")

#     # --- Parameter Handling ---
#     # Merge shared and method-specific parameters into a single dictionary
#     params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
#     # Create observables for each parameter to allow dynamic updates from controls
#     params_obs = Dict{String,Observable}()
#     # Use comprehension for cleaner initialization
#     for (key, val) in params_all; params_obs[key] = Observable(val); end

#     # --- Method Selection Handling ---
#     methods = collect(keys(sim_config.methods_dict)) # Get list of available methods
#     # Observable vector storing the names of currently *active* methods (toggled on)
#     methods_obs = Observable([sim_config.default_method]) 
#     # Observable tracking the *number* of active methods
#     method_number = lift(length, methods_obs) 

#     # --- Create Control Figure ---
#     # Contains parameter sliders/toggles and method selection toggles
#     control_fig = createControls(plot_fig, params_obs, methods_obs, methods)

#     # --- Time Slider Setup ---
#     # Label showing the current time selected by the slider
#     tLabel_text = Observable("t = 0.0") # Use observable for text update
#     Label(control_fig[end+1,:], text = tLabel_text) # Assign observable to text
#     # Add slider to the control figure; range will be set dynamically later
#     # Initialize with a dummy range and start value
#     tSlider = Slider(control_fig[end+1,:], range = 0.0:1.0, startvalue = 0.0) 


#     # --- Data Structures for Plotting ---
#     # These observables hold the simulation data for *all* active methods.
#     # xData[i], uData[i], tData[i] store the full time series for method i.
#     xData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
#     uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
#     tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

#     # These observables hold the data for the *currently selected time* (from tSlider)
#     # for each active method. xs[i], us[i] store the u(x) profile at time t for method i.
#     xs = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
#     us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

#     # --- Lift Block 1: Load/Compute Data & Update Time Slider Range ---
#     # This code runs whenever the number of active methods changes or any parameter value changes.
#     lift(method_number, values(params_obs)...) do active_num, _...
#         println("Updating data based on methods/parameters...")

#         # Resize data structure arrays based on the number of active methods
#         xData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
#         uData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
#         tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
#         xs[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
#         us[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        
#         all_time_points = Set{Float64}() # Collect all unique time points from active methods

#         # --- Loop through active methods to load/compute data ---
#         for i = 1:active_num 
#             method = methods_obs[][i] # Get the name of the i-th active method

#             # Reconstruct parameters for the current method using current observable values
#             current_method_params = Dict{String, Any}() 
#             for (p_key, p_obs) in params_obs
#                 if haskey(sim_config.shared_params, p_key) || haskey(sim_config.methods_dict[method], p_key)
#                      current_method_params[p_key] = p_obs[] # Get current value from observable
#                 end
#             end
#             params = merge(current_method_params, Dict("method" => method)) # Add method name if needed

#             # --- Load or Compute Simulation Data ---
#             # Replace with your actual data loading/computation logic (e.g., using Utils.loadSimData)
#             # Example: Using sim_function directly
#             if !doesSimDataExist(params)
#                 println("Data is being calculated for method: $method...")
#                 sim_data = sim_config.sim_function(params)
#                 saveSimData(sim_data) # Assumes saveSimData exists
#             else
#                 println("Loading data for method: $method...")
#                 sim_data = loadSimData(params) # Assumes loadSimData exists
#             end
#             # println("Running/Loading simulation for method: $method")
#             # sim_data = sim_config.sim_function(params) # Direct call for demo
#             println("Simulation finished for method: $method")
            
#             # --- Store full simulation data in observables ---
#             xData[][i] = Observable(sim_data.x)
#             uData[][i] = Observable(sim_data.u)
#             tData[][i] = Observable(sim_data.t)
            
#             # Collect time points for slider range
#             union!(all_time_points, sim_data.t)

#             # --- Initialize snapshot data (xs, us) for the current slider time ---
#             # Find the index 'm' closest to the current slider time 't'
#             current_t = tSlider.value[] # Get slider's current value
#              # Use findmin to get index of closest time step; handle empty t case
#             closest_t_index = isempty(sim_data.t) ? 0 : findmin(a -> abs(a - current_t), sim_data.t)[2]
            
#             if closest_t_index > 0 && closest_t_index <= length(sim_data.x) && closest_t_index <= length(sim_data.u)
#                 xs[][i] = Observable(sim_data.x[closest_t_index])
#                 us[][i] = Observable(sim_data.u[closest_t_index])
#             else
#                 # Handle cases where data might be empty or index invalid
#                 xs[][i] = Observable(Float64[])
#                 us[][i] = Observable(Float64[])
#                  if !isempty(sim_data.t) # Only warn if time existed but index was bad
#                      @warn "Could not get initial snapshot for method '$method' at t=$current_t. Index $closest_t_index invalid."
#                  end
#             end
#         end # --- End loop over active methods ---

#         # --- Update Time Slider Range ---
#         if !isempty(all_time_points)
#             sorted_times = sort(collect(all_time_points))
#              # Set slider range; ensure start/end are distinct if only one time point
#             tSlider.range = length(sorted_times) > 1 ? (sorted_times[1]:(sorted_times[end]-sorted_times[1])/(length(sorted_times)-1):sorted_times[end]) : (sorted_times[1]:sorted_times[1])
#              # Clamp current value to the new range and update slider
#             new_t = clamp(tSlider.value[], sorted_times[1], sorted_times[end])
#             set_close_to!(tSlider, new_t) 
#             tLabel_text[] = "t = $(round(new_t, digits=3))" # Update label observable
#         else
#             # Handle case where no methods are active or no time points were found
#             tSlider.range = 0.0:1.0 # Set a default range
#             set_close_to!(tSlider, 0.0)
#             tLabel_text[] = "t = 0.0"
#             println("Warning: No time points found. Setting default time range.")
#         end

#         # Trigger downstream lifts if needed (usually automatic)
#         # notify(xs); notify(us) 
        
#         println("Data update complete.")
#     end # --- End Lift Block 1 ---


#     # --- Lift Block 2: Update Plot Snapshot When Time Slider Changes ---
#     # This runs whenever tSlider.value changes.
#     lift(tSlider.value) do t
#         # Update the label text directly
#         tLabel_text[] = "t = $(round(t, digits=3))"

#         # Check if data is available before proceeding
#         if isempty(xs[]) || isempty(tData[]) || length(xs[]) != length(tData[])
#              # This might happen briefly if Lift 1 hasn't finished after methods changed
#              # Or if active_num was 0.
#              # println("Skipping snapshot update: data not ready.")
#              return
#         end

#         # Update the x and u vectors (xs, us) for the currently selected time t
#         for i = eachindex(xs[]) # Loop through each active method's snapshot data
#              # Ensure the data observable for this method exists and is valid
#             if i > length(tData[]) || i > length(xData[]) || i > length(uData[])
#                  continue # Skip if data is inconsistent
#             end
             
#             current_times = tData[][i][] # Get the full time vector for this method
            
#             if isempty(current_times)
#                  continue # Skip if this method has no time data
#             end

#              # Find the index 'm' in the *full* time series (tData) closest to the slider time 't'
#             (_, m) = findmin(a -> abs(a - t), current_times)

#              # Update the snapshot observables (xs[i], us[i]) with data from the full series (xData, uData) at index m
#              # Ensure index 'm' is valid for xData and uData as well
#             if m > 0 && m <= length(xData[][i][]) && m <= length(uData[][i][])
#                 xs[][i][] = xData[][i][][m] # Update the inner observable's value
#                 us[][i][] = uData[][i][][m] # Update the inner observable's value
#             else
#                 # If index is invalid, clear the snapshot (or handle as error)
#                 xs[][i][] = Float64[]
#                 us[][i][] = Float64[]
#                  # @warn "Time index $m invalid for method index $i when updating snapshot at t=$t"
#             end
#         end
#         autolimits!(ax) # Optionally readjust limits whenever time changes
#     end # --- End Lift Block 2 ---


#     # --- Lift Block 3: Redraw Plot ---
#     # This runs whenever the number of active methods changes or any parameter changes
#     # (It implicitly depends on xs and us, which are updated by Lift 1 and Lift 2)
#     lift(method_number, values(params_obs)...) do active_num, _...
#         println("Updating plot...")
        
#         # --- Clear previous plot elements ---
#         empty!(ax) # Remove previous lines/scatter points
#         # Remove the old legend object if it exists
#         for c in contents(plot_fig[1,1]) # Iterate through elements in the grid layout cell
#             if isa(c, Legend)
#                 delete!(c) # Delete the legend object
#             end
#         end

#         # --- Handle case with no active methods ---
#         if active_num == 0
#             println("Plotting skipped: No methods selected.")
#             # Optionally add a message to the plot
#             text!(ax, "No methods selected", position = (0.5, 0.5), align = (:center, :center), 
#                   textsize = local_ui_dict["font_size"], justification = :center)
#             return # Stop here if nothing to plot
#         end

#         # --- Plot data for each active method ---
#         for i = 1:active_num
#              # Ensure snapshot data exists and is valid before plotting
#              if i > length(xs[]) || i > length(us[])
#                  @warn "Snapshot data missing for method index $i during plotting. Skipping."
#                  continue
#              end
             
#             method = methods_obs[][i] # Get method name for label
#             plotLabel = method

#             # Get the snapshot data observables for this method
#             x_snapshot = xs[][i]
#             u_snapshot = us[][i]
            
#             # Check if snapshot data is actually populated
#             if isempty(x_snapshot[]) || isempty(u_snapshot[])
#                  # @info "Snapshot data empty for method '$method' at current time. Skipping plot."
#                  continue # Don't plot if no data for this snapshot
#             end

#             # --- Apply Plotting Styles ---
#             color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
#             line_style = :solid
#             if local_ui_dict["dashed_lines"]; line_style = local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))]; end
#             marker_style = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            
#             # --- Plot Lines and/or Scatter Points ---
#             # Use the snapshot observables directly in plotting functions
#             if local_ui_dict["show_lines"]
#                 lines!(ax, x_snapshot, u_snapshot, label = plotLabel, linestyle = line_style, color = color, linewidth=local_ui_dict["linewidth"])
#             end
#             if local_ui_dict["show_scatter"]
#                 scatter!(ax, x_snapshot, u_snapshot, label = plotLabel, marker = marker_style, color = color, markersize=local_ui_dict["markersize"])
#             end
#         end # --- End loop over active methods ---

#         # --- Add Legend ---
#         # Only add legend if at least one method was potentially plotted (active_num > 0 check already done)
#         Legend(plot_fig[1,1], ax, local_ui_dict["legend"], merge = true, tellheight = false, tellwidth = false,
#                titlesize = local_ui_dict["font_size"], labelsize = local_ui_dict["label_size"], 
#                valign = local_ui_dict["vPos"], halign = local_ui_dict["hPos"])
        
#         autolimits!(ax) # Adjust axis limits after plotting new data
#         println("Plot update complete.")

#     end # --- End Lift Block 3 ---

#     # --- Display Figures ---
#     GLMakie.activate!() # Ensure GLMakie backend is active
#     display(GLMakie.Screen(), control_fig)
#     display(GLMakie.Screen(), plot_fig)

#     # Optionally return figures for further interaction
#     # return control_fig, plot_fig
# end

"""
    show1DSolutionFig(sim_config::SimulationConfig) - REVISED for Fixed Global Limits

Creates an interactive Makie plot for `SimData1D` with globally fixed X and Y limits
determined by the range of data across all active methods and time steps.
"""
function show1DSolutionFig(sim_config::SimulationConfig)
    # --- Basic Setup ---
    local_ui_dict = deepcopy(ui_dict) # Use 1D UI dict
    updateUI(local_ui_dict, sim_config.ui_options)
    plot_fig = Figure(size = local_ui_dict["figsize"])
    ax = Axis(plot_fig[1,1], xlabel = "Position (x)", ylabel = "Solution Value (u)")

    # --- Parameter & Method Observables ---
    params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
    params_obs = Dict{String,Observable}()
    for (key, val) in params_all; params_obs[key] = Observable(val); end
    methods = collect(keys(sim_config.methods_dict))
    methods_obs = Observable([sim_config.default_method])
    method_number = lift(length, methods_obs)

    # --- Control Figure & Widgets ---
    # Assuming createControls takes plot_fig as first arg based on user code
    control_fig = createControls(plot_fig, params_obs, methods_obs, methods) 
    tLabel_text = Observable("t = 0.0")
    Label(control_fig[end+1,:], text = tLabel_text) # Label above slider
    tSlider = Slider(control_fig[end+1,:], range = 0.0:1.0, startvalue = 0.0)

    # --- Data Structures ---
    xData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
    uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    xs = Observable(Vector{Observable{Vector{Float64}}}(undef, 0)) # Snapshot x
    us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0)) # Snapshot u

    # --- Observables for Global Limits ---
    global_xlims = Observable((0.0, 1.0))
    global_ylims = Observable((0.0, 1.0))

    # --- Lift Block 1: Load Data, Calc Global XY Limits, Update Slider ---
    lift(method_number, values(params_obs)...) do active_num, _...
        println("Lift 1 (1D): Updating data & calculating global limits...")
        # Resize arrays
        xData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
        uData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
        tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        xs[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        us[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        
        all_time_points = Set{Float64}()
        # Global limits tracking
        g_xmin, g_xmax = Inf, -Inf
        g_umin, g_umax = Inf, -Inf
        found_any_data = false

        for i = 1:active_num
            method = methods_obs[][i]
            # Parameter setup
            current_method_params = Dict{String, Any}()
            for (p_key, p_obs) in params_obs; if haskey(sim_config.shared_params, p_key) || haskey(sim_config.methods_dict[method], p_key); current_method_params[p_key] = p_obs[]; end; end
            params = merge(current_method_params, Dict("method" => method))

            # Load or Compute Data (Using user's structure)
            local sim_data::Union{SimData1D, Nothing} = nothing # Ensure type/scope
            # if !doesSimDataExist(params) # Replace with actual checks
            #     println("Data calculated for method: $method")
            #     sim_data = sim_config.sim_function(params)
            #     # saveSimData(sim_data) 
            # else
            #     println("Loading data for method: $method")
            #     # sim_data = loadSimData(params) 
            # end
            # --- Direct call for testing ---
             println("Running simulation for method: $method")
             sim_data = sim_config.sim_function(params) # Direct call
             println("Simulation finished for method: $method")
            # --- End Data Loading ---

            if isnothing(sim_data) || !isa(sim_data, SimData1D)
                @warn "Failed to load/compute valid SimData1D for method '$method'. Skipping."
                # Assign empty observables to prevent errors later
                 xData[][i] = Observable(Vector{Vector{Float64}}(undef, 0))
                 uData[][i] = Observable(Vector{Vector{Float64}}(undef, 0))
                 tData[][i] = Observable(Float64[])
                 xs[][i] = Observable(Float64[])
                 us[][i] = Observable(Float64[])
                continue # Skip to next method
            end
            
            # Store data in observables
            xData[][i] = Observable(sim_data.x)
            uData[][i] = Observable(sim_data.u)
            tData[][i] = Observable(sim_data.t)
            union!(all_time_points, sim_data.t)

            # --- Update Global X and U Limits ---
            for k in eachindex(sim_data.t)
                x_k = sim_data.x[k]
                u_k = sim_data.u[k]
                if !isempty(x_k) && !isempty(u_k)
                    found_any_data = true
                    # Use extrema for min/max
                    xmin_k, xmax_k = extrema(x_k)
                    umin_k, umax_k = extrema(u_k)
                    # Update global limits
                    g_xmin = min(g_xmin, xmin_k); g_xmax = max(g_xmax, xmax_k)
                    g_umin = min(g_umin, umin_k); g_umax = max(g_umax, umax_k)
                end
            end

            # Initialize snapshot based on current slider time
            current_t = tSlider.value[]
            closest_t_index = isempty(sim_data.t) ? 0 : findmin(a->abs(a-current_t), sim_data.t)[2]
            if closest_t_index > 0 && closest_t_index <= length(sim_data.x) && closest_t_index <= length(sim_data.u)
                xs[][i] = Observable(sim_data.x[closest_t_index])
                us[][i] = Observable(sim_data.u[closest_t_index])
            else
                xs[][i] = Observable(Float64[]); us[][i] = Observable(Float64[])
            end
        end # End loop over methods

        # --- Finalize and Apply Global Limits ---
        if found_any_data
            padding_factor_x = local_ui_dict["x_axis_limit_padding"]
            padding_factor_y = local_ui_dict["y_axis_limit_padding"]
            x_range = g_xmax - g_xmin; x_pad = x_range * padding_factor_x / 2.0; x_pad = x_range <= 1e-14 ? 0.1 : x_pad
            y_range = g_umax - g_umin; y_pad = y_range * padding_factor_y / 2.0; y_pad = y_range <= 1e-14 ? 0.1 : y_pad

            final_xlims = (g_xmin - x_pad, g_xmax + x_pad)
            final_ylims = (g_umin - y_pad, g_umax + y_pad)

            global_xlims[] = final_xlims
            global_ylims[] = final_ylims

            try # Apply limits to the existing Axis
                xlims!(ax, final_xlims)
                ylims!(ax, final_ylims)
                # Or: limits!(ax, final_xlims..., final_ylims...)
                println("Lift 1 (1D): Applied global limits X=$final_xlims, Y=$final_ylims")
            catch e
                println("Warning: Failed to apply limits in Lift 1 (1D) - $e")
            end
        else # Default limits
            global_xlims[] = (0.0, 1.0); global_ylims[] = (0.0, 1.0)
            xlims!(ax, 0.0, 1.0); ylims!(ax, 0.0, 1.0)
        end

        # --- Update Time Slider Range ---
        if !isempty(all_time_points)
            # ... (slider range logic same as before) ...
            sorted_times = sort(collect(all_time_points)); time_step = length(sorted_times)>1 ? (sorted_times[end]-sorted_times[1]) / (length(sorted_times)-1) : 0.0; t_range = length(sorted_times)>1 ? range(sorted_times[1], stop=sorted_times[end], step=max(eps(Float64), time_step)) : range(sorted_times[1], stop=sorted_times[1], length=1); if time_step == 0 && length(sorted_times) > 1; t_range = range(sorted_times[1], stop=sorted_times[end], length=length(sorted_times)); end; tSlider.range = t_range; new_t = clamp(tSlider.value[], first(t_range), last(t_range)); set_close_to!(tSlider, new_t); tLabel_text[] = "t = $(round(new_t, digits=3))"; 
        else
            tSlider.range = 0.0:1.0; set_close_to!(tSlider, 0.0); tLabel_text[] = "t = 0.0"
        end
        println("Lift 1 (1D): Data update complete.")
    end # --- End Lift Block 1 ---


    # --- Lift Block 2: Update Snapshot & Title Only ---
    # Triggered by time slider changes. Updates snapshot data and title.
    # Limits are fixed by Lift 1, so NO autolimits! here.
    lift(tSlider.value) do t
        tLabel_text[] = "t = $(round(t, digits=3))"
        ax.title = "t=$(round(t, digits=3))" # Update title

        if isempty(xs[]) || isempty(tData[]) || length(xs[]) != length(tData[]); return; end

        # Update snapshot data (xs, us)
        for i = eachindex(xs[])
            if i > length(tData[]) || i > length(xData[]) || i > length(uData[]); continue; end
            current_times = tData[][i][]; if isempty(current_times); continue; end
            (_, m) = findmin(a -> abs(a - t), current_times)
            if m > 0 && m <= length(xData[][i][]) && m <= length(uData[][i][])
                xs[][i][] = xData[][i][][m]; us[][i][] = uData[][i][][m]
            else
                xs[][i][] = Float64[]; us[][i][] = Float64[]
            end
        end
        # REMOVED autolimits!(ax) 
    end # --- End Lift Block 2 ---


    # --- Lift Block 3: Redraw Plot ---
    # Triggered by method or parameter changes. Clears axis, redraws lines/scatter, adds legend.
    # Limits are fixed by Lift 1, so NO autolimits! here.
    lift(method_number, values(params_obs)...; ignore_equal_values=true) do active_num, _...
        # Optional: Could add global_xlims, global_ylims as dependencies if needed,
        # but Lift 1 already applies them directly. This lift just needs to redraw.
        
        println("Lift 3 (1D): Redrawing plot...")
        
        # Clear previous plot elements from the axis
        empty!(ax) 
        # Remove old legend from the figure layout
        for c in contents(plot_fig[1,1]) 
            if isa(c, Legend); delete!(c); end
        end

        # Handle case with no active methods
        if active_num == 0
            text!(ax, "No methods selected", position = (0.5, 0.5), align = (:center, :center), 
                  space=:relative, fontsize = local_ui_dict["font_size"])
            return 
        end

        # Plot data for each active method
        for i = 1:active_num
             if i > length(xs[]) || i > length(us[]) continue end # Safety check
             
            method = methods_obs[][i]; plotLabel = method
            x_snapshot = xs[][i]; u_snapshot = us[][i]
            
            if isempty(x_snapshot[]) || isempty(u_snapshot[]) continue end # Skip empty

            # Apply Plotting Styles
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            line_style = :solid
            if local_ui_dict["dashed_lines"]; line_style = local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))]; end
            marker_style = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            
            # Plot Lines and/or Scatter Points
            if local_ui_dict["show_lines"]
                lines!(ax, x_snapshot, u_snapshot; label=plotLabel, linestyle=line_style, color=color, linewidth=local_ui_dict["linewidth"])
            end
            if local_ui_dict["show_scatter"]
                scatter!(ax, x_snapshot, u_snapshot; label=plotLabel, marker=marker_style, color=color, markersize=local_ui_dict["markersize"])
            end
        end # End loop over active methods

        # Add Legend
        if active_num > 0 # Only add legend if something was plotted
             Legend(plot_fig[1,1], ax, local_ui_dict["legend"], merge=true, 
                    tellheight=false, tellwidth=false, # Place inside axis area
                    titlesize=local_ui_dict["font_size"], labelsize=local_ui_dict["label_size"], 
                    valign=local_ui_dict["vPos"], halign=local_ui_dict["hPos"])
        end
        
        # REMOVED autolimits!(ax)
        
    end # --- End Lift Block 3 ---

    # --- Display Figures ---
    GLMakie.activate!() 
    display(GLMakie.Screen(), control_fig)
    display(GLMakie.Screen(), plot_fig)

    return control_fig, plot_fig # Return figures 
end

"""
    showDynamicDependence(sim_config::SimulationConfig)

Creates an interactive Makie plot showing the time evolution of selected statistics 
from simulation data. Handles stats stored as Dict{String, Any}.

Plots `stats` values (selected via slider, must be Vector{<:Real}) against time (`t`) 
for different simulation methods defined in `sim_config`. Allows comparison of 
statistics across methods.

# Arguments
- `sim_config::SimulationConfig`: Configuration object containing simulation function,
  methods, parameters, and UI options. Assumes the simulation function returns an
  `AbstractSimData` object with non-empty `t::Vector{Float64}` and 
  `stats::Dict{String, Any}` fields.
"""
function showDynamicDependence(sim_config::SimulationConfig)
    # --- Standard Setup ---
    local_ui_dict = deepcopy(ui_dict)
    updateUI(local_ui_dict, sim_config.ui_options)
    plot_fig = Figure(size = local_ui_dict["figsize"])
    ax = Axis(plot_fig[1,1], xlabel = "Time (t)", ylabel = "Statistic Value")

    params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
    params_obs = Dict{String,Observable}()
    [params_obs[key] = Observable(val) for (key, val) = params_all]

    methods = collect(keys(sim_config.methods_dict))
    methods_obs = Observable([sim_config.default_method])
    method_number = lift(length, methods_obs)

    control_fig = createControls(plot_fig, params_obs, methods_obs, methods)

    # --- Data Structures for Statistics (using Dict{String, Any}) ---
    statsData = Observable(Vector{Observable{Dict{String, Any}}}(undef, 0)) # Stores the full stats dict
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))    # Stores the time vector
    stat_keys_obs = Observable(String[]) # Stores the available PLOTTABLE keys
    selected_stat_index_obs = Observable(1) # Index of the statistic currently selected

    # --- Statistic Selection Slider & Label (using Observable for text) ---
    stats_label_text = Observable("Selected Statistic: <calculating>") # Observable for the label text
    stats_label = Label(control_fig[end+1, :], text = stats_label_text) # Assign observable to text
    stats_slider = Slider(control_fig[end+1, :], range = 1:1, startvalue = 1)

    # --- Lift Block 1: Load Data, Filter Plottable Stat Keys, Update UI ---
    lift(method_number, values(params_obs)...) do active_num, _...
        println("Updating data based on methods/parameters...")

        statsData[] = Vector{Observable{Dict{String, Any}}}(undef, active_num)
        tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)

        first_data_loaded = false
        # Store potential keys temporarily before checking type and intersection
        potential_keys_per_method = Vector{Set{String}}(undef, active_num) 

        for i = 1:active_num
            method = methods_obs[][i]
            current_method_params = Dict{String, Any}()
            # Get current parameters from observables
            for (p_key, p_obs) in params_obs
                 # Check if param belongs to shared or the specific method's params
                 # This logic assumes methods_dict contains only method-specific overrides/additions
                if haskey(sim_config.shared_params, p_key) || haskey(sim_config.methods_dict[method], p_key)
                     current_method_params[p_key] = p_obs[]
                end
            end
            params = merge(current_method_params, Dict("method" => method)) # Add method name if needed

            # --- Load or Compute Simulation Data ---
            println("Running/Loading simulation for method: $method")
            # sim_data = loadOrComputeData(sim_config.sim_function, params) # Replace with your logic
            sim_data = sim_config.sim_function(params) # Direct call for demo
            println("Simulation finished for method: $method")

            # --- Store Raw Data ---
            statsData[][i] = Observable(sim_data.stats) # Store the Dict{String, Any}
            tData[][i] = Observable(sim_data.t)

            # --- Identify PLOTTABLE keys for *this* method ---
            plottable_keys_this_method = Set{String}()
            if !isempty(sim_data.stats) && isa(sim_data.stats, Dict)
                for (key, value) in sim_data.stats
                    # *** Check if the value is a Vector of Real numbers ***
                    if isa(value, Vector{<:Real}) && length(value) == length(sim_data.t)
                        push!(plottable_keys_this_method, key)
                    else
                         # Optionally warn if a key exists but is not plottable
                         # println("Info: Stat '$key' in method '$method' is not a Vector{<:Real} or has mismatched length, skipping.")
                    end
                end
            else
                 @warn "Method '$method' produced empty or invalid stats. Skipping stats processing."
            end
            potential_keys_per_method[i] = plottable_keys_this_method
        end # End loop over methods

        # --- Determine Common Plottable Keys ---
        common_plottable_keys = Set{String}()
        if active_num > 0
            common_plottable_keys = potential_keys_per_method[1] # Start with the first set
            for i = 2:active_num
                intersect!(common_plottable_keys, potential_keys_per_method[i]) # Intersect with subsequent sets
            end
        end

        # --- Update Stat Selection UI ---
        sorted_keys = sort(collect(common_plottable_keys))
        stat_keys_obs[] = sorted_keys # Update the observable list of keys

        if isempty(sorted_keys)
            stats_label_text[] = "No common plottable statistics found." # Update observable text
            stats_slider.range = 1:1
            # stats_slider.startvalue = 1 # Might not be needed if range is 1:1
            set_close_to!(stats_slider, 1) # Ensure slider is at 1
            selected_stat_index_obs[] = 1
            println("Warning: No common plottable statistics available to plot.")
        else
            num_keys = length(sorted_keys)
            current_index = selected_stat_index_obs[]
            valid_index = clamp(current_index, 1, num_keys)

            stats_slider.range = 1:num_keys
            set_close_to!(stats_slider, valid_index)
            selected_stat_index_obs[] = valid_index # Ensure observable matches

            # Update the label text observable
            stats_label_text[] = "Selected Statistic: $(sorted_keys[valid_index])" 
            println("Available plottable statistics updated: ", sorted_keys)
        end

        # Trigger downstream lifts manually if necessary (usually automatic)
        # notify(stat_keys_obs) 
        # notify(selected_stat_index_obs) 

        println("Data update complete.")
    end # End of lift block 1

    # --- Connect Statistic Slider to Observable ---
    on(stats_slider.value) do idx
        # Check bounds before accessing stat_keys_obs
        if !isempty(stat_keys_obs[]) && idx >= 1 && idx <= length(stat_keys_obs[])
            if idx != selected_stat_index_obs[]
                 selected_stat_index_obs[] = idx
                 # Update label text directly when slider changes index
                 stats_label_text[] = "Selected Statistic: $(stat_keys_obs[][idx])" 
                 println("Statistic selection changed to index: $idx ($(stat_keys_obs[][idx]))")
            end
        # Handle edge case where slider might briefly be out of sync
        elseif !isempty(stat_keys_obs[]) && selected_stat_index_obs[] != 1
             selected_stat_index_obs[] = 1 # Reset to 1 if slider is somehow invalid
             stats_label_text[] = "Selected Statistic: $(stat_keys_obs[][1])" 
        end
    end

    # --- Lift Block 2: Update Plot ---
    lift(method_number, selected_stat_index_obs, values(params_obs)...) do active_num, stat_idx, _...
        println("Updating plot...")
        empty!(ax)
        for c in contents(plot_fig[1,1])
            if isa(c, Legend); delete!(c); end
        end

        if isempty(stat_keys_obs[]) || active_num == 0 || stat_idx > length(stat_keys_obs[]) || stat_idx < 1
            println("Plotting skipped: No data or no valid statistic selected.")
            ax.ylabel = "Statistic Value" # Reset label
            return
        end

        selected_key = stat_keys_obs[][stat_idx]
        ax.ylabel = selected_key # Update y-axis label based on selection

        println("Plotting statistic: $selected_key")
        valid_plots = 0
        for i = 1:active_num
            method = methods_obs[][i]
            plotLabel = method

            # --- Check data validity for this method and selected key ---
            # Ensure indices are valid before accessing observables
            if i > length(tData[]) || i > length(statsData[])
                 @warn "Data arrays out of sync for method index $i. Skipping plot."
                 continue
            end
            
            local_t_obs = tData[][i]
            current_stats_dict = statsData[][i][] # Get the actual dictionary

            # Check if key exists and if the value is appropriate BEFORE plotting
            if !haskey(current_stats_dict, selected_key)
                # This shouldn't happen if common_plottable_keys logic is correct, but good safeguard
                @warn "Statistic '$selected_key' unexpectedly not found for method '$method'. Skipping."
                continue
            end

            stat_value = current_stats_dict[selected_key]

            # *** Final check: Is it a Vector of Real and lengths match? ***
            if !(isa(stat_value, Vector{<:Real}) && length(stat_value) == length(local_t_obs[]))
                @warn "Statistic '$selected_key' for method '$method' is not Vector{<:Real} or length mismatch. Skipping plot."
                continue
            end

            # If checks pass, create observables for plotting this specific data
            # No need to store these long term, just create for the plot call
            local_t_plot = local_t_obs # Can use the existing observable
            local_stat_y_plot = Observable(convert(Vector{Float64}, stat_value)) # Convert to Float64 for plotting consistency

            if isempty(local_t_plot[]) # Check after potential filtering/conversion
                @info "Time or statistic vector empty for method '$method', statistic '$selected_key'. Skipping."
                continue
            end

            # --- Apply Plotting Styles ---
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            line_style = :solid
            if local_ui_dict["dashed_lines"]; line_style = local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))]; end
            marker_style = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]

            # --- Plot Lines/Scatter ---
            if local_ui_dict["show_lines"]
                lines!(ax, local_t_plot, local_stat_y_plot, label = plotLabel, linestyle = line_style, color = color, linewidth=local_ui_dict["linewidth"])
            end
            if local_ui_dict["show_scatter"]
                scatter!(ax, local_t_plot, local_stat_y_plot, label = plotLabel, marker = marker_style, color = color, markersize=local_ui_dict["markersize"])
            end
            valid_plots += 1
        end # End loop over methods

        # --- Add Legend ---
        if valid_plots > 0
            Legend(plot_fig[1,1], ax, local_ui_dict["legend"], merge = true, tellheight = false, tellwidth = false,
                    titlesize = local_ui_dict["font_size"], labelsize = local_ui_dict["label_size"],
                    valign = local_ui_dict["vPos"], halign = local_ui_dict["hPos"])
        end

        autolimits!(ax)
        println("Plot update complete.")
    end # End of lift block 2

    # --- Display Figures ---
    GLMakie.activate!()
    display(GLMakie.Screen(), control_fig)
    display(GLMakie.Screen(), plot_fig)
    
    # Optionally return figures
    # return control_fig, plot_fig 
end

"""
    show2DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot for `SimData2D`.

Features:
- Reuses Axis3 object for stable interactivity.
- Auto-scaling XY limits based on current time step.
- Globally fixed Z limits and Color range based on full dataset.
- Toggle between 2D scatter plot and 3D surface (meshscatter) plot.
- Slider to select colormap dynamically.
- Standard controls for methods, parameters, and time.
"""
function show2DSolutionFig(sim_config::SimulationConfig)
    # --- Basic Setup & UI ---
    local_ui_dict = deepcopy(ui_dict2D)
    updateUI(local_ui_dict, sim_config.ui_options)
    plot_fig = Figure(size = local_ui_dict["figsize"])

    # --- Create Axis3 ONCE ---
    # Always use Axis3; configure appearance dynamically for 2D/3D views.
    ax = Axis3(plot_fig[1, 1], xlabel="x", ylabel="y", zlabel="Solution (u)")

    # --- Parameter & Method Observables ---
    params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
    params_obs = Dict{String,Observable}()
    for (key, val) in params_all; params_obs[key] = Observable(val); end
    methods = collect(keys(sim_config.methods_dict))
    methods_obs = Observable([sim_config.default_method])
    method_number = lift(length, methods_obs)

    # --- Control Figure & Widgets ---
    control_fig = createControls(plot_fig, params_obs, methods_obs, methods)

    # Time Slider
    tLabel_text = Observable("t = 0.0")
    # Place time label above its slider for better layout
    Label(control_fig[end+1, :], tLabel_text, tellwidth=false) 
    tSlider = Slider(control_fig[end+1, :], range = 0.0:1.0, startvalue = 0.0)


    # Plot Type Toggle
    plot_toggle_layout = control_fig[end+1, :] = GridLayout()
    plot_as_surface_obs = Observable(local_ui_dict["plot_as_surface"])
    Label(plot_toggle_layout[1, 1], "Plot as Surface (3D)")
    toggle_plot_type = Toggle(plot_toggle_layout[1, 2], active = plot_as_surface_obs[])
    on(toggle_plot_type.active, update=true) do active_state
        plot_as_surface_obs[] = active_state
    end

    # Colormap Slider
    cmap_layout = control_fig[end+1, :] = GridLayout()
    available_cmaps = local_ui_dict["colormaps"]
    default_cmap_idx = findfirst(isequal(local_ui_dict["colormap"]), available_cmaps)
    if isnothing(default_cmap_idx); default_cmap_idx = 1; end # Fallback
    selected_colormap_obs = Observable(available_cmaps[default_cmap_idx])

    cmap_slider = Slider(cmap_layout[1, 1],
                         range = 1:length(available_cmaps),
                         startvalue = default_cmap_idx)
    cmap_label = Label(cmap_layout[1, 2], # Place label next to slider
                       lift(idx -> "$(available_cmaps[idx])", cmap_slider.value),
                       width=Auto()) # Adjust width
    on(cmap_slider.value, update=true) do idx
        selected_colormap_obs[] = available_cmaps[idx] # Update observable on slider change
    end

    # --- Data Structures ---
    xData = Observable(Vector{Observable{Vector{Vector{NTuple{2, Float64}}}}}(undef, 0))
    uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    xs = Observable(Vector{Observable{Vector{NTuple{2, Float64}}}}(undef, 0)) # Snapshot coords
    us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))       # Snapshot values
    global_zlims_and_colorrange = Observable((0.0, 1.0)) # Global U range (min, max)

    # --- Lift Block 1: Data Loading & Global U Range Calculation ---
    # Triggered by method selection or parameter changes.
    # Calculates the global range of U across all time/methods.
    # Loads full data, initializes snapshots, updates time slider range.
    lift(method_number, values(params_obs)...) do active_num, _...
        println("Lift 1: Updating data & calculating global U range...")
        xData[] = Vector{Observable{Vector{Vector{NTuple{2, Float64}}}}}(undef, active_num)
        uData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
        tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        xs[] = Vector{Observable{Vector{NTuple{2, Float64}}}}(undef, active_num)
        us[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        all_time_points = Set{Float64}()
        g_umin, g_umax = Inf, -Inf
        found_any_u_data = false

        for i = 1:active_num
            method = methods_obs[][i]
            current_method_params = Dict{String, Any}()
            for (p_key, p_obs) in params_obs
                 if haskey(sim_config.shared_params, p_key) || haskey(sim_config.methods_dict[method], p_key)
                    current_method_params[p_key] = p_obs[]
                 end
            end
            params = merge(current_method_params, Dict("method" => method))

            sim_data::SimData2D = sim_config.sim_function(params)
            xData[][i] = Observable(sim_data.x); uData[][i] = Observable(sim_data.u)
            tData[][i] = Observable(sim_data.t); union!(all_time_points, sim_data.t)

            # Update Global U Limits from full sim_data
            for k in eachindex(sim_data.t)
                u_k = sim_data.u[k]
                if !isempty(u_k)
                    found_any_u_data = true
                    umin_k, umax_k = extrema(u_k)
                    g_umin = min(g_umin, umin_k); g_umax = max(g_umax, umax_k)
                end
            end
            # Initialize snapshot based on current slider time
            current_t = tSlider.value[]
            closest_t_index = isempty(sim_data.t) ? 0 : findmin(a -> abs(a-current_t), sim_data.t)[2]
            if closest_t_index > 0 && closest_t_index <= length(sim_data.x) # Check index validity
                 xs[][i] = Observable(sim_data.x[closest_t_index])
                 us[][i] = Observable(sim_data.u[closest_t_index])
            else
                 xs[][i] = Observable(NTuple{2, Float64}[]); us[][i] = Observable(Float64[])
            end
        end

        # Finalize and Store Global Z Limits / Color Range
        if found_any_u_data
            padding_factor = local_ui_dict["axis_limit_padding"]
            z_range = g_umax - g_umin
            z_pad = z_range * padding_factor / 2.0
            z_pad = (z_pad <= 1e-6 && z_range <= 1e-6) ? 0.1 : z_pad # Ensure some padding if range is zero or tiny
            final_zlims = (g_umin - z_pad, g_umax + z_pad)
            global_zlims_and_colorrange[] = final_zlims
        else
            global_zlims_and_colorrange[] = (0.0, 1.0) # Default range
        end
        println("Lift 1: Global Z/Color range set to $(global_zlims_and_colorrange[])")

        # Update Time Slider Range
        if !isempty(all_time_points)
            sorted_times = sort(collect(all_time_points))
            time_step = length(sorted_times)>1 ? (sorted_times[end]-sorted_times[1]) / (length(sorted_times)-1) : 0.0
            t_range = length(sorted_times)>1 ? range(sorted_times[1], stop=sorted_times[end], step=max(eps(Float64), time_step)) : range(sorted_times[1], stop=sorted_times[1], length=1)
            if time_step == 0 && length(sorted_times) > 1 # Fallback if step is zero
                 t_range = range(sorted_times[1], stop=sorted_times[end], length=length(sorted_times))
            end
            tSlider.range = t_range
            # Adjust slider position smoothly, update label
            set_close_to!(tSlider, clamp(tSlider.value[], first(t_range), last(t_range)))
            tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"
        else
            tSlider.range = 0.0:1.0; set_close_to!(tSlider, 0.0); tLabel_text[] = "t = 0.0"
        end
        # Note: No explicit redraw call here; Lift 3 will react to parameter/method changes.
    end # --- End Lift Block 1 ---


    # --- Lift Block 2: Time Slider Updates ---
    # Triggered only by time slider changes.
    # Updates snapshot data, title, and applies auto XY limits + fixed Z limits.
    lift(tSlider.value) do t
        tLabel_text[] = "t = $(round(t, digits=3))"; ax.title = "t=$(round(t, digits=3))"
        if isempty(xs[]) || isempty(tData[]) || length(xs[]) != length(tData[]); return; end

        # Update snapshot data for each active method
        for i = eachindex(xs[])
             if i > length(tData[]) || i > length(xData[]) || i > length(uData[]); continue; end
             current_times = tData[][i][]; if isempty(current_times); continue; end
             (_, m) = findmin(a -> abs(a - t), current_times)
             if m > 0 && m <= length(xData[][i][])
                  xs[][i][] = xData[][i][][m]; us[][i][] = uData[][i][][m]
             else; xs[][i][] = NTuple{2, Float64}[]; us[][i][] = Float64[]; end
        end

        # Adjust XY (& Z temporarily) limits, then fix Z limits
        try; autolimits!(ax); catch e; println("Warning: autolimits! failed - $e"); end
        try; zlims!(ax, global_zlims_and_colorrange[]...); catch e; println("Warning: Failed to apply fixed zlims in Lift 2! - $e"); end

    end # --- End Lift Block 2 ---


    # --- Lift Block 3: Plot Redraw & Configuration ---
    # Triggered by method, parameter, plot type, or colormap changes.
    # Clears axis, deletes old elements, configures axis view, fixes Z limits, plots data.
    lift(method_number, plot_as_surface_obs, selected_colormap_obs,
         global_zlims_and_colorrange, values(params_obs)...; # Add global limits as dependency
         ignore_equal_values=true) do active_num, plot_surface, current_cmap, current_zlims_val, _...

        println("Lift 3: Redrawing plot...")

        # Clear axis content & Delete old Legend/Colorbar
        empty!(ax)
        needs_colorbar_update = false
        for (row, col) in [(1, 2), (1, 3)]
            content_list = contents(plot_fig[row, col]) # Don't search recursively
            if !isempty(content_list)
                # Iterate deletion candidates. Only delete direct children.
                to_delete = filter(x -> isa(x, Union{Legend, Colorbar}), content_list)
                for elem in to_delete
                    try
                        delete!(elem); if isa(elem, Colorbar); needs_colorbar_update=true; end
                    catch e; println("Warning: Failed delete element $(typeof(elem)) - $e"); end
                end
            end
        end

        # Configure Axis Appearance (title is set by Lift 2)
        if plot_surface; ax.xlabel="x"; ax.ylabel="y"; ax.zlabel="Solution (u)"; ax.aspect=(1,1,0.5); ax.perspectiveness=0.5; ax.xgridvisible=true; ax.ygridvisible=true; ax.zgridvisible=true; ax.xticklabelsvisible=true; ax.yticklabelsvisible=true; ax.zticklabelsvisible=true; ax.zlabelvisible=true
        else; ax.xlabel="x"; ax.ylabel="y"; ax.zlabel=""; ax.aspect=(1,1,1); ax.xgridvisible=true; ax.ygridvisible=true; ax.zgridvisible=false; ax.xticklabelsvisible=true; ax.yticklabelsvisible=true; ax.zticklabelsvisible=false; ax.zlabelvisible=false; ax.elevation=pi/2; ax.azimuth=0; ax.perspectiveness=0.0; end

        # Fix Z Limits using the current global value
        try; zlims!(ax, current_zlims_val...); catch e; println("Warning: Failed apply fixed zlims in Lift 3! - $e"); end

        # Handle no active methods
        if active_num == 0; text!(ax, "No methods selected", position=Point3f(0.5,0.5,0), align=(:center,:center), space=:relative, fontsize=local_ui_dict["font_size"]); return; end

        # Use Global Color Range
        color_range = current_zlims_val

        # Plot data
        plotted_objects = []
        for i = 1:active_num
            if i > length(xs[]) || i > length(us[]) continue end
            method = methods_obs[][i]; plotLabel = method
            x_snapshot_obs = xs[][i]; u_snapshot_obs = us[][i]
            if isempty(x_snapshot_obs[]) || isempty(u_snapshot_obs[]) continue end

            # Use lift for points; avoids recalculating points unless snapshot changes
            points_xyz = lift((x, u) -> [Point3f(x[j][1],x[j][2],u[j]) for j in 1:min(length(x),length(u))], x_snapshot_obs, u_snapshot_obs)
            points_xy0 = lift(x -> [Point3f(pt[1], pt[2], 0.0f0) for pt in x], x_snapshot_obs)
            color_values = u_snapshot_obs # Color directly by solution value observable

            plt_obj = nothing
            marker_size_3d = local_ui_dict["markersize_3d"] # Use consistent var name
            markersize_2d = local_ui_dict["markersize_2d"]
            if plot_surface
                plt_obj = meshscatter!(ax, points_xyz; markersize=marker_size_3d,
                                       color=color_values, colormap=current_cmap,
                                       colorrange=color_range, label=plotLabel)
            else
                plt_obj = scatter!(ax, points_xy0; markersize=markersize_2d,
                                   color=color_values, colormap=current_cmap,
                                   colorrange=color_range, label=plotLabel)
            end
            push!(plotted_objects, plt_obj)
        end

        # Add Legend/Colorbar
        if !isempty(plotted_objects)
            try
                # Add legend if cell is empty
                if isempty(contents(plot_fig[1, 2]))
                    Legend(plot_fig[1, 2], ax, local_ui_dict["legend"], merge=true,
                           tellheight=false, titlesize=local_ui_dict["font_size"],
                           labelsize=local_ui_dict["label_size"])
                end
                # Add colorbar if cell is empty or needs update
                if isempty(contents(plot_fig[1, 3])) || needs_colorbar_update
                    Colorbar(plot_fig[1, 3], limits=color_range, colormap=current_cmap, # Use current_cmap
                             label="Solution (u)", width=25,
                             ticklabelsize=local_ui_dict["ticklabel_size"])
                end
                # Adjust layout (can be outside try block if needed)
                #colsize!(plot_fig.layout, 1, AxisAspect(1)) # Make plot area square
                colsize!(plot_fig.layout, 2, Auto())
                colsize!(plot_fig.layout, 3, Auto())
            catch e
                println("Error adding Legend/Colorbar: $e")
            end
        end

    end # --- End Lift Block 3 ---

    # --- Display Figures ---
    GLMakie.activate!()
    display(GLMakie.Screen(), control_fig)
    display(GLMakie.Screen(), plot_fig)
    #return plot_fig, control_fig # Return figs for potential further use
end

"""
    showConvergenceFig(sim_config::SimulationConfig,
                       key::String,
                       param_values::Union{AbstractVector, AbstractRange};
                       run_simulations::Bool = true,
                       force_int_param::Bool = false)

Plots simulation statistics against a varied parameter ('key') for multiple
selected methods at different times.

Runs the simulation defined in `sim_config` for each *active method* and for
each value in `param_values` assigned to the parameter `key`. It then plots
user-selected statistics or the varied parameter against each other, allowing
exploration via a time slider and method toggles.

# Arguments
- `sim_config`: Base SimulationConfig defining methods, base params, sim function.
- `key`: String name of the parameter in `params` to vary.
- `param_values`: Vector or Range of values to assign to `key`.
- `run_simulations`: If true (default), runs simulations. False requires load logic.
- `force_int_param`: If true, attempts `trunc(Int, value)` for the varied parameter.
"""
function showConvergenceFig(
    sim_config::SimulationConfig,
    key::String,
    param_values::Union{AbstractVector, AbstractRange};
    run_simulations::Bool = true,
    force_int_param::Bool = false
    )

    # --- Basic Setup & UI ---
    local_ui_dict = deepcopy(ui_dict)
    # updateUI(local_ui_dict, sim_config.ui_options) # Apply overrides if needed
    plot_fig = Figure(size = local_ui_dict["figsize"])
    ax = Axis(plot_fig[1,1], title="Convergence Plot") # Standard 2D Axis

    # --- Parameter & Method Observables/Controls ---
    params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
    # Exclude the key being varied from interactive controls
    controlled_param_keys = filter(k -> k != key && haskey(params_all, k), keys(params_all))
    params_obs = Dict{String,Observable}()
    for p_key in controlled_param_keys; params_obs[p_key] = Observable(params_all[p_key]); end

    methods = collect(keys(sim_config.methods_dict))
    default_method = sim_config.default_method in methods ? sim_config.default_method : methods[1]
    methods_obs = Observable([default_method]) # Observable list of active method names
    method_number = lift(length, methods_obs)  # Observable count of active methods

    # Create standard controls (method toggles, param sliders/boxes)
    control_fig = createControls(plot_fig, params_obs, methods_obs, methods)

    # --- Convergence Specific Controls ---
    # X-Axis Stat Menu
    Label(control_fig[end+1, 1], "X-Axis:").padding = (0, 5, 0, 0)
    x_stat_menu = Menu(control_fig[end, 2], options = ["Calculating..."], width=200)
    x_stat_obs = x_stat_menu.selection

    # Y-Axis Stat Menu
    Label(control_fig[end+1, 1], "Y-Axis:").padding = (0, 5, 0, 0)
    y_stat_menu = Menu(control_fig[end, 2], options = ["Calculating..."], width=200)
    y_stat_obs = y_stat_menu.selection

    # Time Slider
    tLabel_text = Observable("t = 0.0")
    Label(control_fig[end+1, 1:2], tLabel_text, tellwidth=false).padding = (0, 0, 5, 0)
    tSlider = Slider(control_fig[end+1, 1:2], range = 0.0:1.0, startvalue = 0.0)

    # --- Data Storage ---
    num_params = length(param_values)
    local_param_values = collect(param_values) # Ensure vector

    # Store results nested: [method_idx][param_idx] -> {stats_dict, time_vector}
    all_method_stats = Observable(Vector{Vector{ParamDictType}}(undef, 0))
    all_method_times = Observable(Vector{Vector{Vector{Float64}}}(undef, 0))
    actual_param_values_used = Observable(Vector{Vector{Any}}(undef, 0))

    # Store available stat keys (common across all runs)
    stat_keys = Observable(["Varied Parameter ($key)"])

    # Store plot data: [method_idx] -> Observable{Vector{Float64}}
    x_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    y_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))


    # --- Lift 1: Data Loading / Simulation Execution ---
    # Triggered when active methods list or base parameters change.
    lift(method_number, values(params_obs)...; ignore_equal_values=true) do active_num, _...
        if active_num == 0
            println("Lift 1: No methods selected. Clearing data.")
            all_method_stats[] = []; all_method_times[] = []; actual_param_values_used[] = []
            x_plot_data_methods[] = []; y_plot_data_methods[] = []
            stat_keys[] = ["Varied Parameter ($key)"]
            # Reset menus and slider? Or handled by Lift 3 clearing the plot?
            x_stat_menu.options = stat_keys[]; x_stat_menu.selection = stat_keys[][1]
            y_stat_menu.options = stat_keys[]; y_stat_menu.selection = stat_keys[][1]
            tSlider.range = 0.0:1.0; set_close_to!(tSlider, 0.0)
            return # Stop processing if no methods are active
        end

        println("Lift 1: Updating methods/params. Running/Loading simulations for $active_num method(s)...")

        temp_method_stats = Vector{Vector{ParamDictType}}(undef, active_num)
        temp_method_times = Vector{Vector{Vector{Float64}}}(undef, active_num)
        temp_actual_params = Vector{Vector{Any}}(undef, active_num)

        common_stat_keys = Set{String}()
        first_run_overall = true
        all_times_union = Set{Float64}()
        active_methods = methods_obs[]

        for i = 1:active_num # Loop through ACTIVE methods
            method_name = active_methods[i]
            println(" Processing Method: $method_name ($i/$active_num)")

            stats_for_method = Vector{ParamDictType}(undef, num_params)
            times_for_method = Vector{Vector{Float64}}(undef, num_params)
            params_for_method = Vector{Any}(undef, num_params)

            method_specific_params = sim_config.methods_dict[method_name]
            base_params = merge(sim_config.shared_params, method_specific_params)
            for (p_key, p_obs) in params_obs; base_params[p_key] = p_obs[]; end

            Threads.@threads for j = 1:num_params # OPTIONAL: Parallelize parameter loop if sims are independent
                 # Create thread-local copy? Or ensure sim_function is thread-safe?
                 # For now, assume serial or thread-safe sim_function
                local_j = j # Capture loop variable for closure if needed

                raw_value = local_param_values[local_j]
                current_value = if force_int_param; try trunc(Int, raw_value) catch; raw_value end else raw_value end
                params_for_method[local_j] = current_value

                current_params = copy(base_params)
                current_params[key] = current_value
                current_params["method"] = method_name # Ensure method name is available

                print("  Run $local_j/$num_params: $key = $current_value ... ")

                local sim_data::Union{AbstractSimData, Nothing} = nothing
                try
                    if run_simulations
                        sim_data = sim_config.sim_function(current_params)
                    else
                        error("Loading not implemented.")
                    end

                    if isnothing(sim_data) || !hasproperty(sim_data, :stats) || !hasproperty(sim_data, :t) || !isa(sim_data.stats, AbstractDict) || !isa(sim_data.t, AbstractVector)
                         println("Invalid SimData. Skipping.")
                         stats_for_method[local_j] = ParamDictType(); times_for_method[local_j] = Float64[]
                         # continue # Cannot continue in @threads, need other logic if parallel
                    else
                        println("Done.")
                        stats_for_method[local_j] = sim_data.stats
                        times_for_method[local_j] = sim_data.t
                        # Thread safety needed for union! and common_stat_keys update if parallel
                        # Using locks or atomics, or process results after parallel loop
                        # Serial version:
                        union!(all_times_union, sim_data.t)
                        current_keys = Set{String}()
                        for (stat_name, stat_val) in sim_data.stats
                             if isa(stat_val, Vector{<:Real}) && !isempty(stat_val) && length(stat_val) == length(sim_data.t)
                                push!(current_keys, stat_name)
                             end
                        end
                        # This part needs locking if parallel:
                        if first_run_overall && !isempty(current_keys)
                            common_stat_keys = current_keys; first_run_overall = false
                        elseif !first_run_overall
                            intersect!(common_stat_keys, current_keys)
                        end
                        # End lock section
                    end

                catch e
                    println("Failed! Error: $e")
                    stats_for_method[local_j] = ParamDictType(); times_for_method[local_j] = Float64[]
                end
            end # End loop over param_values (j)

            temp_method_stats[i] = stats_for_method
            temp_method_times[i] = times_for_method
            temp_actual_params[i] = params_for_method
        end # End loop over active methods (i)

        println("Finished runs. Updating observables...")

        all_method_stats[] = temp_method_stats
        all_method_times[] = temp_method_times
        actual_param_values_used[] = temp_actual_params

        # Update stat key options
        new_axis_keys = [ "Varied Parameter ($key)"; sort(collect(common_stat_keys)) ]
        println(new_axis_keys)
        if stat_keys[] != new_axis_keys
             stat_keys[] = new_axis_keys
             # Reset menus if current selection is no longer valid
             current_x = x_stat_obs[]; if !(current_x in new_axis_keys); x_stat_menu.selection = new_axis_keys[1]; end
             current_y = y_stat_obs[]; default_y = length(new_axis_keys)>1 ? new_axis_keys[2] : new_axis_keys[1]; if !(current_y in new_axis_keys); y_stat_menu.selection = default_y; end
        end

        # Update Time Slider Range
        time_vec = isempty(all_times_union) ? [0.0, 1.0] : sort(collect(all_times_union))
        t_range = isempty(time_vec) ? (0.0:1.0) : range(first(time_vec), last(time_vec), length=max(100, 2*length(time_vec)))
        tSlider.range = t_range
        set_close_to!(tSlider, clamp(tSlider.value[], first(t_range), last(t_range)))
        tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"

        # Resize & initialize plot data observables
        current_x_plot_data = [Observable(zeros(Float64, num_params)) for _ in 1:active_num]
        current_y_plot_data = [Observable(zeros(Float64, num_params)) for _ in 1:active_num]
        
        # Manually trigger update for initial snapshot
        current_t = tSlider.value[]; current_x_key = x_stat_obs[]; current_y_key = y_stat_obs[]
        actual_x_key = replace(current_x_key, "Varied Parameter ($key)" => key)
        actual_y_key = replace(current_y_key, "Varied Parameter ($key)" => key)
        
        for i = 1:active_num
            x_vals = zeros(Float64, num_params); y_vals = zeros(Float64, num_params)
            method_stats = all_method_stats[][i]; method_times = all_method_times[][i]
            method_params_used = actual_param_values_used[][i]

            for j = 1:num_params
                if isempty(method_times[j]) continue end
                (_, m_ij) = findmin(a -> abs(a - current_t), method_times[j])
                
                if actual_x_key == key; x_vals[j] = Float64(method_params_used[j]);
                elseif haskey(method_stats[j], actual_x_key) && m_ij <= length(method_stats[j][actual_x_key]); x_vals[j] = Float64(method_stats[j][actual_x_key][m_ij]);
                else x_vals[j] = NaN; end
                
                if actual_y_key == key; y_vals[j] = Float64(method_params_used[j]);
                elseif haskey(method_stats[j], actual_y_key) && m_ij <= length(method_stats[j][actual_y_key]); y_vals[j] = Float64(method_stats[j][actual_y_key][m_ij]);
                else y_vals[j] = NaN; end
            end
            current_x_plot_data[i][] = x_vals # Update inner observable
            current_y_plot_data[i][] = y_vals # Update inner observable
        end
        # Update the outer observables containing the plot data observables
        x_plot_data_methods[] = current_x_plot_data
        y_plot_data_methods[] = current_y_plot_data
        println("Lift 1: Update complete.")

    end # --- End Lift Block 1 ---


    # --- Lift Block 2: Snapshot Update ---
    # Triggered by time, x-stat, or y-stat selection.
    lift(tSlider.value, x_stat_obs, y_stat_obs; ignore_equal_values=true) do t, x_key, y_key
        # println("Lift 2: Updating plot data for t=$t, x=$x_key, y=$y_key")
        active_num = method_number[]
        tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"
        
        # Ensure consistency between active methods and data storage
        if length(x_plot_data_methods[]) != active_num || length(y_plot_data_methods[]) != active_num || length(all_method_stats[]) != active_num
             # This can happen briefly during transitions, wait for Lift 1 & 3 to sync
             println("Lift 2: Data structures size mismatch. Skipping update.")
             return 
        end

        actual_x_key = replace(x_key, "Varied Parameter ($key)" => key)
        actual_y_key = replace(y_key, "Varied Parameter ($key)" => key)

        for i = 1:active_num # Loop through currently active methods
            x_vals = zeros(Float64, num_params); y_vals = zeros(Float64, num_params)
            # Access data safely based on current active_num
            method_stats = all_method_stats[][i]; method_times = all_method_times[][i]
            method_params_used = actual_param_values_used[][i] 

            for j = 1:num_params # Loop through parameter values
                if isempty(method_times[j]) continue end # Skip if no time data for this run
                (_, m_ij) = findmin(a -> abs(a - t), method_times[j])

                # Get X value
                if actual_x_key == key; x_vals[j] = Float64(method_params_used[j]);
                elseif haskey(method_stats[j], actual_x_key) && m_ij <= length(method_stats[j][actual_x_key]); x_vals[j] = Float64(method_stats[j][actual_x_key][m_ij]);
                else x_vals[j] = NaN; end
                # Get Y value
                if actual_y_key == key; y_vals[j] = Float64(method_params_used[j]);
                elseif haskey(method_stats[j], actual_y_key) && m_ij <= length(method_stats[j][actual_y_key]); y_vals[j] = Float64(method_stats[j][actual_y_key][m_ij]);
                else y_vals[j] = NaN; end
            end
            # Update the specific inner observable for this method's plot data
            x_plot_data_methods[][i][] = x_vals 
            y_plot_data_methods[][i][] = y_vals 
        end

        ax.xlabel = x_key; ax.ylabel = y_key
        try; autolimits!(ax); catch e; println("Warning: autolimits! failed - $e"); end
        
    end # --- End Lift Block 2 ---


    # --- Lift Block 3: Plot Management ---
    # Triggered when the number of active methods changes.
    lift(method_number; ignore_equal_values=true) do active_num
        println("Lift 3: Active method count changed to $active_num. Redrawing plot structure...")
        
        empty!(ax) # Clear previous plot objects from axis
        # Delete old legend from figure
        for c in contents(plot_fig[1,2]) if isa(c, Legend); delete!(c); end; end
        
        active_methods = methods_obs[] 

        if active_num == 0; text!(ax, "No methods selected", position=(0.5, 0.5), align=(:center, :center), space=:relative); return; end

        # Ensure plot data observables match active method count
        if length(x_plot_data_methods[]) != active_num || length(y_plot_data_methods[]) != active_num
            @warn "Lift 3: Plot data observable length mismatch. Plot may be incomplete."
            # Attempt to use the minimum length to avoid index errors
            num_to_plot = min(active_num, length(x_plot_data_methods[]), length(y_plot_data_methods[]))
        else
            num_to_plot = active_num
        end

        plotted_objects = [] # Store one plot object per method for legend
        # Create plot objects for each active method
        for i = 1:num_to_plot 
            plotLabel = active_methods[i] 
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            
            # Plot using the specific inner observable for this method
            # Makie handles updates automatically when the inner observable changes
            l = lines!(ax, x_plot_data_methods[][i], y_plot_data_methods[][i]; 
                       color=color, linewidth=local_ui_dict["linewidth"], label=plotLabel)
            scatter!(ax, x_plot_data_methods[][i], y_plot_data_methods[][i]; 
                         color=color, markersize=local_ui_dict["markersize"], marker=marker, label=plotLabel)
            push!(plotted_objects, l) # Add line object to list for legend
        end

        # Add Legend (outside axis)
        if !isempty(plotted_objects)
             try
                 if isempty(contents(plot_fig[1, 2])) # Check target cell
                      # Provide plot objects and corresponding labels
                      Legend(plot_fig[1, 2], plotted_objects, active_methods[1:length(plotted_objects)], 
                             "Methods", tellheight=false, 
                             titlesize=local_ui_dict["font_size"]-2, labelsize=local_ui_dict["label_size"]-2)
                      colsize!(plot_fig.layout, 2, Auto()) # Let legend take its space
                 end
             catch e; println("Error adding Legend: $e"); end
        end
        
        # Ensure limits are recalculated after adding new plot objects
        try; autolimits!(ax); catch e; println("Warning: autolimits! failed after redraw - $e"); end

    end # --- End Lift Block 3 ---

    # --- Display ---
    display(GLMakie.Screen(), control_fig)
    display(GLMakie.Screen(), plot_fig)
    return plot_fig, control_fig

end

function showConvergenceFig2(
    sim_config::SimulationConfig,
    key::String,
    param_values::Union{AbstractVector, AbstractRange};
    run_simulations::Bool = true,
    force_int_param::Bool = false
    )

    # --- Basic Setup & UI ---
    local_ui_dict = deepcopy(ui_dict)
    # updateUI(local_ui_dict, sim_config.ui_options) 
    plot_fig = Figure(size = local_ui_dict["figsize"])
    ax = Axis(plot_fig[1,1], title="Convergence Plot") # Axis labels set in Lift 3

    # --- Parameter & Method Observables/Controls ---
    params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
    controlled_param_keys = filter(k -> k != key && haskey(params_all, k), keys(params_all))
    params_obs = Dict{String,Observable}(); for p_key in controlled_param_keys; params_obs[p_key] = Observable(params_all[p_key]); end
    methods = collect(keys(sim_config.methods_dict)); default_method = sim_config.default_method in methods ? sim_config.default_method : methods[1]; methods_obs = Observable([default_method]); method_number = lift(length, methods_obs)

    # --- Control Figure & Widgets ---
    control_fig = Figure(size=(450, 400)) # Adjusted size 
    Label(control_fig[1, 1:2], "Convergence Plot Controls", fontsize=16, tellwidth=false, halign=:left)
    ctrl_row = 2 
    # Assume createControls adds its elements here...
    Label(control_fig[ctrl_row, 1:2], "(Standard Controls Placeholder)")
    ctrl_row += 1

    # Convergence Specific Controls
    Label(control_fig[ctrl_row, 1], "X-Axis:").padding = (0, 5, 3, 0)
    stat_keys_initial = ["Varied Parameter ($key)"] # Initial options before calculation
    stat_keys = Observable(stat_keys_initial) # Observable for available keys
    x_stat_menu = Menu(control_fig[ctrl_row, 2], options = stat_keys, width=200) # Link options reactively
    x_stat_obs = x_stat_menu.selection 
    ctrl_row += 1

    Label(control_fig[ctrl_row, 1], "Y-Axis:").padding = (0, 5, 3, 0)
    y_stat_menu = Menu(control_fig[ctrl_row, 2], options = stat_keys, width=200) # Link options reactively
    y_stat_obs = y_stat_menu.selection 
    ctrl_row += 1
    
    tLabel_text = Observable("t = 0.0")
    Label(control_fig[ctrl_row, 1:2], tLabel_text, tellwidth=false).padding = (0, 0, 5, 0)
    ctrl_row += 1
    
    tSlider = Slider(control_fig[ctrl_row, 1:2], range = 0.0:1.0, startvalue = 0.0)

    # --- Data Storage ---
    num_params = length(param_values); local_param_values = collect(param_values) 
    all_method_stats = Observable(Vector{Vector{ParamDictType}}(undef, 0))
    all_method_times = Observable(Vector{Vector{Vector{Float64}}}(undef, 0))
    actual_param_values_used = Observable(Vector{Vector{Any}}(undef, 0))
    x_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    y_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

    # --- Lift Block 1: Data Loading / Simulation Execution ---
    # Triggered by method selection or base parameter changes.
    lift(method_number, values(params_obs)...; ignore_equal_values=true) do active_num, _...
        if active_num == 0; println("Lift 1: No methods selected."); all_method_stats[] = []; all_method_times[] = []; actual_param_values_used[] = []; x_plot_data_methods[] = []; y_plot_data_methods[] = []; stat_keys[] = ["Varied Parameter ($key)"]; x_stat_menu.options = stat_keys[]; y_stat_menu.options = stat_keys[]; return; end

        println("Lift 1: Updating methods/params. Running simulations...")
        temp_method_stats = Vector{Vector{ParamDictType}}(undef, active_num); temp_method_times = Vector{Vector{Vector{Float64}}}(undef, active_num); temp_actual_params = Vector{Vector{Any}}(undef, active_num)
        common_stat_keys = Set{String}(); first_run_overall = true; all_times_union = Set{Float64}(); active_methods = methods_obs[]

        for i = 1:active_num # Loop ACTIVE methods
            method_name = active_methods[i]; println(" Processing Method: $method_name")
            stats_for_method = Vector{ParamDictType}(undef, num_params); times_for_method = Vector{Vector{Float64}}(undef, num_params); params_for_method = Vector{Any}(undef, num_params)
            method_specific_params = sim_config.methods_dict[method_name]; base_params = merge(sim_config.shared_params, method_specific_params); for (p_key, p_obs) in params_obs; base_params[p_key] = p_obs[]; end
            
            for j = 1:num_params # Loop param values
                raw_value = local_param_values[j]; current_value = if force_int_param; try trunc(Int, raw_value) catch; raw_value end else raw_value end; params_for_method[j] = current_value; current_params = copy(base_params); current_params[key] = current_value; current_params["method"] = method_name
                local sim_data::Union{AbstractSimData, Nothing} = nothing
                try; if run_simulations; sim_data = sim_config.sim_function(current_params); else error("Loading not implemented."); end
                    if isnothing(sim_data) || !hasproperty(sim_data, :stats) || !hasproperty(sim_data, :t) || !isa(sim_data.stats, AbstractDict) || !isa(sim_data.t, AbstractVector); stats_for_method[j] = ParamDictType(); times_for_method[j] = Float64[]; continue; end
                    stats_for_method[j] = sim_data.stats; times_for_method[j] = sim_data.t; union!(all_times_union, sim_data.t); current_keys = Set{String}(); for (sn, sv) in sim_data.stats; if isa(sv, Vector{<:Real}) && !isempty(sv) && length(sv) == length(sim_data.t); push!(current_keys, sn); end; end
                    if first_run_overall && !isempty(current_keys); common_stat_keys = current_keys; first_run_overall = false; elseif !first_run_overall; intersect!(common_stat_keys, current_keys); end
                catch e; println(" Run $j Failed! Error: $e"); stats_for_method[j] = ParamDictType(); times_for_method[j] = Float64[]; end
            end
            temp_method_stats[i] = stats_for_method; temp_method_times[i] = times_for_method; temp_actual_params[i] = params_for_method
        end # End loop methods

        println("Updating observables after runs..."); 
        all_method_stats[] = temp_method_stats; all_method_times[] = temp_method_times; actual_param_values_used[] = temp_actual_params

        # Update stat key options observable
        new_axis_keys = [ "Varied Parameter ($key)"; sort(collect(common_stat_keys)) ]
        if stat_keys[] != new_axis_keys; 
             stat_keys[] = new_axis_keys # Update the observable that menus listen to
             println("Lift 1: Updated stat_keys observable with: $(stat_keys[])") # DEBUG
             # Reset menu SELECTION only if previous selection is now invalid
             current_x = x_stat_menu.selection[]; if !(current_x in new_axis_keys); x_stat_menu.selection = new_axis_keys[1]; println(" Reset X menu selection"); end
             current_y = y_stat_menu.selection[]; default_y = length(new_axis_keys)>1 ? new_axis_keys[2] : new_axis_keys[1]; if !(current_y in new_axis_keys); y_stat_menu.selection = default_y; println(" Reset Y menu selection"); end
        # else
             # println("Lift 1: stat_keys unchanged.") # DEBUG
        end

        # Update Time Slider Range
        time_vec = isempty(all_times_union) ? [0.0, 1.0] : sort(collect(all_times_union)); t_range = isempty(time_vec) ? (0.0:1.0) : range(first(time_vec), last(time_vec), length=max(100, 2*length(time_vec))); tSlider.range = t_range; set_close_to!(tSlider, clamp(tSlider.value[], first(t_range), last(t_range))); tLabel_text[] = "t = $(round(tSlider.value[], digits=3))";

        # Resize plot data observables
        x_plot_data_methods[] = [Observable(zeros(Float64, num_params)) for _ in 1:active_num]
        y_plot_data_methods[] = [Observable(zeros(Float64, num_params)) for _ in 1:active_num]
        
        # Manually trigger initial snapshot calculation (via Lift 2)
        # Notify the observables that Lift 2 depends on to make it run once.
        notify(tSlider.value); notify(x_stat_obs); notify(y_stat_obs) 
        # Alternative: direct calculation here (as before) - might be safer
        # ... (direct calculation code omitted for brevity, same as before) ...

        println("Lift 1: Update complete.")
    end # --- End Lift Block 1 ---


    # --- Lift Block 2: Snapshot Update ---
    # Triggered by time, x-stat, or y-stat selection.
    # Updates the plot data observables for each active method.
    lift(tSlider.value, x_stat_obs, y_stat_obs; ignore_equal_values=true) do t, x_key, y_key
        # println("Lift 2: Updating plot data for t=$t, x=$x_key, y=$y_key") # DEBUG
        tLabel_text[] = "t = $(round(t, digits=3))" # Update time label text observable
        active_num = method_number[]
        
        if length(x_plot_data_methods[]) != active_num || length(y_plot_data_methods[]) != active_num || length(all_method_stats[]) != active_num; return; end # Exit if data not ready

        actual_x_key = replace(x_key, "Varied Parameter ($key)" => key)
        actual_y_key = replace(y_key, "Varied Parameter ($key)" => key)

        for i = 1:active_num # Loop through active methods
            x_vals = zeros(Float64, num_params); y_vals = zeros(Float64, num_params)
            method_stats = all_method_stats[][i]; method_times = all_method_times[][i]; method_params_used = actual_param_values_used[][i] 

            for j = 1:num_params # Loop through parameter values
                if isempty(method_times[j]) continue end 
                (_, m_ij) = findmin(a -> abs(a - t), method_times[j])

                # Get X value
                if actual_x_key == key; x_vals[j] = Float64(method_params_used[j]);
                elseif haskey(method_stats[j], actual_x_key) && m_ij <= length(method_stats[j][actual_x_key]); x_vals[j] = Float64(method_stats[j][actual_x_key][m_ij]);
                else x_vals[j] = NaN; end
                # Get Y value
                if actual_y_key == key; y_vals[j] = Float64(method_params_used[j]);
                elseif haskey(method_stats[j], actual_y_key) && m_ij <= length(method_stats[j][actual_y_key]); y_vals[j] = Float64(method_stats[j][actual_y_key][m_ij]);
                else y_vals[j] = NaN; end
            end
            x_plot_data_methods[][i][] = x_vals # Update inner observable for method i
            y_plot_data_methods[][i][] = y_vals # Update inner observable for method i
        end

        # Don't update axis labels here, Lift 3 handles plot configuration
        # try; autolimits!(ax); catch e; println("Warning: autolimits! failed - $e"); end # Autolimits done in Lift 3
        
    end # --- End Lift Block 2 ---


    # --- Lift Block 3: Plot Management & Axis Configuration ---
    # Triggered when methods change OR selected X/Y stats change.
    lift(method_number; ignore_equal_values=true) do active_num
        println("Lift 3: Redrawing plot structure / updating axis labels...")
        
        empty!(ax) # Clear previous plot objects from axis
        for c in contents(plot_fig[1,2]) if isa(c, Legend); delete!(c); end; end # Delete old legend
        
        # # Update Axis Labels based on selection
        # ax.xlabel = x_key
        # ax.ylabel = y_key
        
        active_methods = methods_obs[] 
        if active_num == 0; text!(ax, "No methods selected", position=(0.5, 0.5), align=(:center, :center), space=:relative); return; end

        num_to_plot = min(active_num, length(x_plot_data_methods[]), length(y_plot_data_methods[])); if num_to_plot < active_num; @warn "Lift 3: Plot data observable length mismatch."; end
            
        plotted_objects = [] 
        for i = 1:num_to_plot 
            plotLabel = active_methods[i] 
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            # Create plots linked to the data observables for method i
            l = lines!(ax, x_plot_data_methods[][i], y_plot_data_methods[][i]; color=color, linewidth=local_ui_dict["linewidth"], label=plotLabel)
            s = scatter!(ax, x_plot_data_methods[][i], y_plot_data_methods[][i]; color=color, markersize=local_ui_dict["markersize"], marker=marker, label=plotLabel)
            push!(plotted_objects, l) 
        end

        # Add Legend
        if !isempty(plotted_objects); try; if isempty(contents(plot_fig[1, 2])); Legend(plot_fig[1, 2], plotted_objects, active_methods[1:length(plotted_objects)], "Methods", tellheight=false, titlesize=local_ui_dict["font_size"]-2, labelsize=local_ui_dict["label_size"]-2); colsize!(plot_fig.layout, 2, Auto()); end; catch e; println("Error adding Legend: $e"); end; end
        
        # Autolimits after new plots are added and labels potentially change size
        try; autolimits!(ax); catch e; println("Warning: autolimits! failed after redraw - $e"); end

    end # --- End Lift Block 3 ---

    # --- Display ---
    display(GLMakie.Screen(), control_fig)
    display(GLMakie.Screen(), plot_fig)
    return plot_fig, control_fig

end

"""
    showConvergenceFig(sim_config::SimulationConfig, 
                       convergence_key::String, 
                       convergence_values::AbstractVector;
                       default_x_key::Union{String, Nothing} = nothing,
                       default_y_key::Union{String, Nothing} = nothing,
                       xscale=identity, # z.B. log10
                       yscale=identity) # z.B. log10

Erstellt einen interaktiven Makie-Plot zur Visualisierung von Konvergenzdaten.

Führt Simulationen für verschiedene Werte eines Parameters (`convergence_key`) aus 
und plottet ausgewählte Statistiken (`SimData.stats`) gegeneinander. 
Benutzer können die Statistiken für die X/Y-Achsen und den Zeitpunkt auswählen.
"""
function showConvergenceFig3(sim_config::SimulationConfig, 
    convergence_key::String, 
    convergence_values::AbstractVector;
    default_x_key::Union{String, Nothing} = nothing,
    default_y_key::Union{String, Nothing} = nothing,
    xscale=identity, 
    yscale=identity)

# --- Grundlegendes Setup ---
local_ui_dict = deepcopy(ui_dict) # Lade Standard UI-Einstellungen
updateUI(local_ui_dict, sim_config.ui_options) # Überschreibe mit sim_config spezifischen Optionen

plot_fig = Figure(size = local_ui_dict["figsize"])
ax = Axis(plot_fig[1,1], 
xlabel = "X Axis", # Wird dynamisch gesetzt
ylabel = "Y Axis", # Wird dynamisch gesetzt
xscale = xscale, 
yscale = yscale)

# --- Parameter & Methoden Observables ---
# Schließe den Konvergenz-Parameter von den interaktiven Params aus
params_all_interactive = filter(p -> p.first != convergence_key, 
            mergeParams(sim_config.shared_params, sim_config.methods_dict))
params_obs = Dict{String,Observable}()
for (key, val) in params_all_interactive; params_obs[key] = Observable(val); end

methods = collect(keys(sim_config.methods_dict))
methods_obs = Observable([sim_config.default_method])
method_number = lift(length, methods_obs)

# --- Kontroll-Fenster & Widgets ---
# Annahme: createControls kann einen Schlüssel zum Ignorieren erhalten
control_fig = createControls(plot_fig, params_obs, methods_obs, methods) 

# Zeit-Slider
tLabel_text = Observable("t = 0.0")
Label(control_fig[end+1,:], text = tLabel_text) 
tSlider = Slider(control_fig[end+1,:], range = 0.0:0.01:1.0, startvalue = 0.0) # Range wird später aktualisiert

# --- Achsen-Auswahl mit SLIDERS ---
stat_keys_available = Observable([""]) # Observable für Keys bleibt wichtig für Logik
initial_x_key = string(convergence_key)
x_axis_key = Observable(isnothing(default_x_key) ? initial_x_key : default_x_key) 
y_axis_key = Observable(isnothing(default_y_key) ? "" : default_y_key) 

# Labels zur Anzeige der ausgewählten Keys
Label(control_fig[end+1, 1], text="X-Achse:")
x_key_label = Label(control_fig[end, 2], text = x_axis_key) # Label zeigt direkt das Observable an
Label(control_fig[end+1, 1], text="Y-Achse:")
y_key_label = Label(control_fig[end, 2], text = y_axis_key) # Label zeigt direkt das Observable an

# Slider zur Auswahl des Index
# Initialisiere mit minimalem Range 1:1
x_axis_slider = Slider(control_fig[end+1, :], range = 1:1, startvalue = 1) 
y_axis_slider = Slider(control_fig[end+1, :], range = 1:1, startvalue = 1)

# --- Verknüpfung Slider-Wert -> Achsen-Key Observable ---
on(x_axis_slider.value) do idx
keys = stat_keys_available[]
# Wichtig: Prüfe, ob der Index gültig ist *bevor* zugegriffen wird
if 1 <= idx <= length(keys) 
new_key = keys[idx]
if new_key != x_axis_key[] # Optional: Nur bei Änderung aktualisieren
x_axis_key[] = new_key
end
else
println("Warnung: Ungültiger Index $idx von x_axis_slider (Keys-Länge: $(length(keys))).")
end
end

on(y_axis_slider.value) do idx
keys = stat_keys_available[]
# Wichtig: Prüfe, ob der Index gültig ist *bevor* zugegriffen wird
if 1 <= idx <= length(keys)
new_key = keys[idx]
if new_key != y_axis_key[] # Optional: Nur bei Änderung aktualisieren
y_axis_key[] = new_key
end
else
println("Warnung: Ungültiger Index $idx von y_axis_slider (Keys-Länge: $(length(keys))).")
end
end

# --- Datenstruktur für Ergebnisse ---
# Speichert für jede Methode die Ergebnisse (stats, t) für jeden Konvergenzwert
# Dict{MethodenName, Vector{Tuple{StatsDict, ZeitVector}}}
method_results_obs = Observable(Dict{String, Vector{Tuple{ParamDictType, Vector{Float64}}}}())

# --- Datenstruktur für Plot-Daten (Snapshots zur Zeit t) ---
# Vektor (für jede Methode) von Observables (enthält Vektor der X-Werte für Konvergenzpunkte)
plot_x_data = Observable(Vector{Observable{Vector{Float64}}}(undef, 0)) 
# Vektor (für jede Methode) von Observables (enthält Vektor der Y-Werte für Konvergenzpunkte)
plot_y_data = Observable(Vector{Observable{Vector{Float64}}}(undef, 0)) 

# --- LIFT BLOCK 1: Simulationen ausführen, Stats sammeln, UI aktualisieren ---
lift(method_number, values(params_obs)...) do active_num, _...
println("Lift 1 (Konvergenz): Führe Simulationen aus und sammle Stats...")

# --- WICHTIG: Initialisierung hier hinzufügen (Fix für UndefVarError) ---
local_results = Dict{String, Vector{Tuple{ParamDictType, Vector{Float64}}}}() 
# -----------------------------------------------------------------------

all_stat_keys = Set{String}([string(convergence_key)]) # Konvergenzparameter ist immer verfügbar
all_time_points = Set{Float64}()

for i = 1:active_num
method = methods_obs[][i]
println("  Methode: $method")
# Erstellt eine Liste für die Ergebnisse dieser Methode über alle Konvergenzwerte
method_results_list = Vector{Tuple{ParamDictType, Vector{Float64}}}(undef, length(convergence_values))

# Basis-Parameter für diese Methode (ohne Konvergenz-Key)
base_method_params = Dict{String, Any}()
# Gemeinsame Parameter
for (p_key, p_obs) in params_obs; if haskey(sim_config.shared_params, p_key); base_method_params[p_key] = p_obs[]; end; end
# Methodenspezifische Parameter (überschreiben ggf. gemeinsame)
if haskey(sim_config.methods_dict, method)
# Nimm die Parameter aus dem Dictionary für diese Methode
# (Annahme: sim_config.methods_dict[method] ist ein ParamDictType)
specific_params = sim_config.methods_dict[method]
# Füge/Überschreibe nur die Parameter, für die es ein Observable gibt (interaktiv)
for (p_key, p_obs) in params_obs 
if haskey(specific_params, p_key)
 base_method_params[p_key] = p_obs[] 
end
end
# Füge auch nicht-interaktive Parameter dieser Methode hinzu
for (p_key, p_val) in specific_params
if !haskey(params_obs, p_key) # Nur wenn nicht schon durch Observable abgedeckt
  base_method_params[p_key] = p_val
end
end
end

for j = eachindex(convergence_values)
conv_val = convergence_values[j]
print("    Konvergenzwert: $convergence_key = $conv_val")

# Parameter für diesen spezifischen Lauf erstellen
current_run_params = copy(base_method_params)
current_run_params[convergence_key] = conv_val 
# Füge den Methodennamen hinzu, falls die sim_function ihn braucht
params = merge(current_run_params, Dict("method" => method)) 

# --- Simulation ausführen (oder laden) ---
local sim_data::Union{AbstractSimData, Nothing} = nothing
try
sim_data = sim_config.sim_function(params) 
print(" -> Fertig.\n")
catch e
@warn "Fehler bei Simulation für Methode '$method' mit $convergence_key=$conv_val: $e"
method_results_list[j] = (ParamDict(), Float64[]) 
print(" -> FEHLER.\n")
continue 
end
# --- Ende Simulation ---

if isnothing(sim_data) || !hasproperty(sim_data, :stats) || !hasproperty(sim_data, :t)
@warn "Ungültige oder fehlende SimData/Stats/T für Methode '$method' mit $convergence_key=$conv_val."
method_results_list[j] = (ParamDict(), Float64[])
else
method_results_list[j] = (sim_data.stats, sim_data.t)
for (stat_key, stat_val) in sim_data.stats
if isa(stat_val, AbstractVector) || isa(stat_val, Number)
     union!(all_stat_keys, Set([stat_key]))
end
end
union!(all_time_points, sim_data.t)
end
end # Ende Schleife über Konvergenzwerte

# Ergebnisse dieser Methode im lokalen Dictionary speichern
local_results[method] = method_results_list 

end # Ende Schleife über Methoden

# --- Ergebnisse und UI aktualisieren ---
method_results_obs[] = local_results 

# Verfügbare Stat-Keys vorbereiten
sorted_keys = sort(collect(all_stat_keys))
filter!(k -> !isempty(k), sorted_keys) 

# Aktualisiere das Observable für die Keys (wird von Slider-Callbacks gelesen)
stat_keys_available[] = sorted_keys 

# --- Standard-Achsen-Keys prüfen und ggf. anpassen (WICHTIG: VOR Slider-Update) ---
current_x = x_axis_key[] 
current_y = y_axis_key[]

# Prüfe Y-Achse 
if isempty(current_y) || !(current_y in sorted_keys)
available_y_keys = filter(k -> k != current_x, sorted_keys) 
if !isempty(available_y_keys); y_axis_key[] = first(available_y_keys)
elseif !isempty(sorted_keys); y_axis_key[] = first(sorted_keys)
else; y_axis_key[] = "" end
end
# Prüfe X-Achse 
if isempty(current_x) || !(current_x in sorted_keys)
x_axis_key[] = initial_x_key 
end

# --- Slider Ranges aktualisieren ---
num_keys = length(sorted_keys)
new_range = 1:max(1, num_keys) 

if x_axis_slider.range[] != new_range
println("Aktualisiere Slider-Range auf: ", new_range)
x_axis_slider.range = new_range 
y_axis_slider.range = new_range 
end

# --- Slider Werte (Indizes) aktualisieren ---
# (Nutze die potenziell gerade aktualisierten x_axis_key[] und y_axis_key[])
x_idx = findfirst(==(x_axis_key[]), sorted_keys)
y_idx = findfirst(==(y_axis_key[]), sorted_keys)
x_idx = isnothing(x_idx) ? 1 : x_idx
y_idx = isnothing(y_idx) ? 1 : y_idx

# Setze die Slider-Werte (Indizes) OHNE Trigger der `on` Blöcke
println("Setze Slider-Indizes: X=$x_idx, Y=$y_idx")
setindex!(x_axis_slider.value, x_idx) 
setindex!(y_axis_slider.value, y_idx) 

# Zeit-Slider Bereich aktualisieren 
if !isempty(all_time_points)
sorted_times = sort(collect(all_time_points))
t_min, t_max = extrema(sorted_times)
t_range = range(t_min, stop=t_max, length=max(2, length(sorted_times)*2)) 
if length(sorted_times) == 1; t_range = range(t_min, stop=t_max, length=2); end
tSlider.range = t_range
current_t = tSlider.value[]
new_t = clamp(current_t, first(t_range), last(t_range))
setindex!(tSlider.value, new_t) # Wert setzen ohne Trigger? Sicherer Weg? Testen.
# tSlider.value[] = new_t # Alternative, löst aber direkt Lift 2 aus
tLabel_text[] = "t = $(round(new_t, digits=3))" 
else
tSlider.range = 0.0:0.01:1.0; setindex!(tSlider.value, 0.0); tLabel_text[] = "t = 0.0"
end

println("Lift 1 (Konvergenz): Beendet (mit Slider-Aktualisierung).")
end # --- Ende Lift Block 1 ---


# --- LIFT BLOCK 2: Plot-Daten extrahieren (basierend auf Zeit und Achsen-Auswahl) ---
lift(tSlider.value, x_axis_key, y_axis_key, method_results_obs) do t, x_key, y_key, method_results
println("Lift 2 (Konvergenz): Extrahiere Plot-Daten für t=$t, x=$x_key, y=$y_key")

# --- Achsenbeschriftungen sicher setzen ---
safe_x_key = isempty(x_key) ? "X" : x_key 
safe_y_key = isempty(y_key) ? "Y" : y_key
if ax.xlabel[] != safe_x_key; ax.xlabel = safe_x_key; end
if ax.ylabel[] != safe_y_key; ax.ylabel = safe_y_key; end

# Zeitlabel aktualisieren
tLabel_text[] = "t = $(round(t, digits=3))" 

active_methods = methods_obs[]
num_active = length(active_methods)
current_x_data = Vector{Observable{Vector{Float64}}}(undef, num_active)
current_y_data = Vector{Observable{Vector{Float64}}}(undef, num_active)

for i = 1:num_active
method = active_methods[i]
x_vals_obs = Observable(Float64[]) 
y_vals_obs = Observable(Float64[])

if haskey(method_results, method) && !isempty(method_results[method])
results_for_method = method_results[method]
num_conv_points = length(results_for_method)
temp_x_vals = Vector{Float64}(undef, num_conv_points)
temp_y_vals = Vector{Float64}(undef, num_conv_points)

for j = 1:num_conv_points
conv_val = convergence_values[j]
stats_dict, time_vector = results_for_method[j]

if isempty(time_vector) || isempty(stats_dict)
  temp_x_vals[j] = NaN; temp_y_vals[j] = NaN; continue
end

m = findmin(abs.(time_vector .- t))[2] 
x_val = NaN
if x_key == convergence_key; x_val = Float64(conv_val)
elseif haskey(stats_dict, x_key)
  stat_x = stats_dict[x_key]
  if isa(stat_x, AbstractVector) && m <= length(stat_x); x_val = Float64(stat_x[m])
  elseif isa(stat_x, Number); x_val = Float64(stat_x) end
end
y_val = NaN
if y_key == convergence_key; y_val = Float64(conv_val)
elseif haskey(stats_dict, y_key)
  stat_y = stats_dict[y_key]
  if isa(stat_y, AbstractVector) && m <= length(stat_y); y_val = Float64(stat_y[m])
  elseif isa(stat_y, Number); y_val = Float64(stat_y) end
end
temp_x_vals[j] = x_val; temp_y_vals[j] = y_val
end 
x_vals_obs[] = temp_x_vals; y_vals_obs[] = temp_y_vals
end 
current_x_data[i] = x_vals_obs; current_y_data[i] = y_vals_obs
end 
plot_x_data[] = current_x_data; plot_y_data[] = current_y_data

println("Lift 2 (Konvergenz): Beendet.")
end # --- Ende Lift Block 2 ---


# --- LIFT BLOCK 3: Plot neu zeichnen (aktuellste Version mit Filtern) ---
# (Kann zum Testen auskommentiert bleiben, bis die Buffer-Fehler weg sind)
lift(plot_x_data, plot_y_data) do current_xs, current_ys
println("Lift 3 (Konvergenz): Zeichne Plot neu...")

empty!(ax) 
for c in contents(plot_fig[1,1]) 
if isa(c, Legend); delete!(c); end
end

active_methods = methods_obs[]
num_active = length(active_methods)

if num_active == 0 
if isempty(current_xs) || isempty(current_ys)
# text!(ax, "Keine Methoden ausgewählt", ...) # TEXT VORERST VERMEIDEN
println("Lift 3: Keine Methoden ausgewählt.")
autolimits!(ax); return 
end
end

if isempty(current_xs) || isempty(current_ys) || length(current_xs) != num_active || length(current_ys) != num_active
# text!(ax, "Warte auf Daten...", ...) # TEXT VORERST VERMEIDEN
println("Lift 3: Daten inkonsistent oder leer.")
autolimits!(ax); return
end

plotted_something = false
for i = 1:num_active
method = active_methods[i]
if i > length(current_xs) || i > length(current_ys); continue; end
x_obs = current_xs[i]; y_obs = current_ys[i]
x_vec = x_obs[]; y_vec = y_obs[]
if isempty(x_vec) || isempty(y_vec) continue end 

pairs = collect(zip(x_vec, y_vec))
valid_pairs = filter(p -> isfinite(p[1]) && isfinite(p[2]), pairs)
if isempty(valid_pairs) continue end 

plot_x_filt = first.(valid_pairs)
plot_y_filt = last.(valid_pairs)

color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
line_style = :solid
if local_ui_dict["dashed_lines"]; line_style = local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))]; end
marker_style = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
plotLabel = method 

if local_ui_dict["show_lines"] && !isempty(plot_x_filt)
lines!(ax, plot_x_filt, plot_y_filt; label=plotLabel, linestyle=line_style, color=color, linewidth=local_ui_dict["linewidth"])
plotted_something = true
end
if local_ui_dict["show_scatter"] && !isempty(plot_x_filt)
scatter!(ax, plot_x_filt, plot_y_filt; label=plotLabel, marker=marker_style, color=color, markersize=local_ui_dict["markersize"])
plotted_something = true
end
end # Ende Schleife über Methoden

if plotted_something
Legend(plot_fig[1,1], ax, "Methoden", merge=true, 
tellheight=false, tellwidth=false, 
titlesize=local_ui_dict["font_size"], labelsize=local_ui_dict["label_size"], 
valign=local_ui_dict["vPos"], halign=local_ui_dict["hPos"])
else
# text!(ax, "Keine gültigen Datenpunkte für Auswahl", ...) # TEXT VORERST VERMEIDEN
println("Lift 3: Keine gültigen Datenpunkte zum Plotten.")
end

autolimits!(ax) 
println("Lift 3 (Konvergenz): Beendet.")
end # --- Ende Lift Block 3 ---


# --- Fenster anzeigen ---
GLMakie.activate!() 
# Wichtig: Fange mögliche Fehler beim ersten Anzeigen ab
try
display(GLMakie.Screen(), control_fig)
catch e
@error "Fehler beim Anzeigen von control_fig: $e"
Base.show_backtrace(stderr, catch_backtrace())
end
try
display(GLMakie.Screen(), plot_fig)
catch e
@error "Fehler beim Anzeigen von plot_fig: $e"
Base.show_backtrace(stderr, catch_backtrace()) # Zeige Backtrace für diesen Fehler
end

return control_fig, plot_fig 
end

end