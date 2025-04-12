module MakiePlotting

using ..Structs
using ..Utils
using GLMakie
using CSV, DataFrames

export show1DSolutionFig, show2DSolutionFig, showDynamicDependence

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
function createTextBoxes(fig::Makie.Figure, keys::Vector{String}, obs_dict::Dict{String, Observable})
    tbLayout = fig[end+1,:] = GridLayout()
    sort!(keys)
    for (i,key) = enumerate(keys)
        row = mod1(i, 5)
        col = trunc(Int64, (i-1)/5) + 1
        Label(tbLayout[row,2*col-1], key * " = ")
        tb = Textbox(tbLayout[row,2*col], placeholder = string(to_value(obs_dict[key])), validator = typeof(to_value(obs_dict[key])))
        on(tb.stored_string) do s
            obs_dict[key][] = parse(typeof(obs_dict[key][]), s)
        end
    end
end

function createSaveFigBox(figControl::Makie.Figure, plot_fig::Makie.Figure, usedKeys::Vector{String}, namePrefix::String)
    saveBox = Textbox(figControl[1,2], placeholder = "Type name to save")
    on(saveBox.stored_string) do s
        name = namePrefix * s 
        CairoMakie.activate!(pt_per_unit = 1.5)
        CairoMakie.save(saveFigs*name* ".pdf", plot_fig)

        vals = map(key -> to_value(obs_dict[key]), usedKeys)
        dataf = DataFrame(processCSVNames(usedKeys) .=> vals)
        CSV.write(saveFigs*name* ".csv", dataf)
        
        println("Plot saved as $name")
        
    end
end

function createSliders(fig::Makie.Figure, slNames::Vector{String})
    slLayout = fig[3,1] = GridLayout()
    for (i,name) = enumerate(slNames)
        tmpSlider = Slider(slLayout[i,1], range = sliderRanges[name], startvalue = obs_dict[name][])
        tmpLabel = lift(x -> name * " = " * string(x), tmpSlider.value)
        Label(slLayout[i,1], tmpLabel)
        on(tmpSlider.value) do val
            obs_dict[name][] = to_value(val)
        end
    end
end

function createMethodToggles(fig::Makie.Figure, methods_obs::Observable{Vector{String}}, methods::Vector{String})
    
    # actives = Vector{Observable}(undef, length(methods)) 
    # for (i, method) = enumerate(methods)
    #     toLayout = fig[end+1,div(i,5)+1] = GridLayout() # 5 hard coded atm can be added to ui_dict
    #     Label(toLayout[mod1(i,5),1], method)
    #     actives[i] = Toggle(toLayout[mod1(i,5),2], active = false).active
    # end
    # activatedToggles = lift((actives...)) do _...
    #     findall(x -> to_value(x), actives)
    # end
    for (i,method) = enumerate(methods)
        toLayout = fig[end+1,div(i,5)+1] = GridLayout() # 5 hard coded atm can be added to ui_dict
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
Creates a Makie figure containing the simulation controls. They have to be given as vectors of Strings.
The methods have to be coupled with the equation type, see the global parameters for the implemented 
method combinations. 
"""
function createControls(params_obs::Dict{String,Observable}, methods_obs::Observable{Vector{String}}, methods::Vector{String})
    fig = Figure(size=(800,700))
    # Split parameters by type
    println(params_obs)
    vals = values(params_obs)
    ks = sort(collect(keys(params_obs)))
    mask_to = map(x -> x[] isa Bool, vals)
    mask_tb = map(x -> x[] isa Real, vals) .& .!mask_to

    # Create control elements
    createTextBoxes(fig, ks[mask_tb], params_obs)
    createParameterToggles(fig, ks[mask_to], params_obs)
    createMethodToggles(fig, methods_obs, methods)

    return fig
end

"""
    show1DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot showing the 1D solution `u(x)` at different times `t` 
for various simulation methods.

Uses two figures: one for the plot (`plot_fig`) and one for controls (`control_fig`).
Allows toggling methods, adjusting parameters, and scrubbing through time with a slider.

# Arguments
- `sim_config::SimulationConfig`: Configuration object containing the simulation 
  function (`sim_function`), method definitions (`methods_dict`), shared parameters 
  (`shared_params`), default method, and UI overrides (`ui_options`). 
  Assumes `sim_function` returns `SimData1D` with `x`, `u`, `t` fields.
"""
function show1DSolutionFig(sim_config::SimulationConfig)
    # --- Basic Setup ---
    local_ui_dict = deepcopy(ui_dict) # Use a local copy for UI settings
    updateUI(local_ui_dict, sim_config.ui_options)

    # Create the main plotting figure and axis
    plot_fig = Figure(size = local_ui_dict["figsize"])
    ax = Axis(plot_fig[1,1], xlabel = "Position (x)", ylabel = "Solution Value (u)")

    # --- Parameter Handling ---
    # Merge shared and method-specific parameters into a single dictionary
    params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
    # Create observables for each parameter to allow dynamic updates from controls
    params_obs = Dict{String,Observable}()
    # Use comprehension for cleaner initialization
    for (key, val) in params_all; params_obs[key] = Observable(val); end

    # --- Method Selection Handling ---
    methods = collect(keys(sim_config.methods_dict)) # Get list of available methods
    # Observable vector storing the names of currently *active* methods (toggled on)
    methods_obs = Observable([sim_config.default_method]) 
    # Observable tracking the *number* of active methods
    method_number = lift(length, methods_obs) 

    # --- Create Control Figure ---
    # Contains parameter sliders/toggles and method selection toggles
    control_fig = createControls(params_obs, methods_obs, methods)

    # --- Time Slider Setup ---
    # Add slider to the control figure; range will be set dynamically later
    # Initialize with a dummy range and start value
    tSlider = Slider(control_fig[end+1,:], range = 0.0:1.0, startvalue = 0.0) 
    # Label showing the current time selected by the slider
    tLabel_text = Observable("t = 0.0") # Use observable for text update
    tLabel = Label(control_fig[end,:], text = tLabel_text) # Assign observable to text

    # --- Data Structures for Plotting ---
    # These observables hold the simulation data for *all* active methods.
    # xData[i], uData[i], tData[i] store the full time series for method i.
    xData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
    uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

    # These observables hold the data for the *currently selected time* (from tSlider)
    # for each active method. xs[i], us[i] store the u(x) profile at time t for method i.
    xs = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

    # --- Lift Block 1: Load/Compute Data & Update Time Slider Range ---
    # This code runs whenever the number of active methods changes or any parameter value changes.
    lift(method_number, values(params_obs)...) do active_num, _...
        println("Updating data based on methods/parameters...")

        # Resize data structure arrays based on the number of active methods
        xData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
        uData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
        tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        xs[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        us[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
        
        all_time_points = Set{Float64}() # Collect all unique time points from active methods

        # --- Loop through active methods to load/compute data ---
        for i = 1:active_num 
            method = methods_obs[][i] # Get the name of the i-th active method

            # Reconstruct parameters for the current method using current observable values
            current_method_params = Dict{String, Any}() 
            for (p_key, p_obs) in params_obs
                if haskey(sim_config.shared_params, p_key) || haskey(sim_config.methods_dict[method], p_key)
                     current_method_params[p_key] = p_obs[] # Get current value from observable
                end
            end
            params = merge(current_method_params, Dict("method" => method)) # Add method name if needed

            # --- Load or Compute Simulation Data ---
            # Replace with your actual data loading/computation logic (e.g., using Utils.loadSimData)
            # Example: Using sim_function directly
            if !doesSimDataExist(params)
                println("Data is being calculated for method: $method...")
                sim_data = sim_config.sim_function(params)
                saveSimData(sim_data) # Assumes saveSimData exists
            else
                println("Loading data for method: $method...")
                sim_data = loadSimData(params) # Assumes loadSimData exists
            end
            # println("Running/Loading simulation for method: $method")
            # sim_data = sim_config.sim_function(params) # Direct call for demo
            println("Simulation finished for method: $method")
            
            # --- Store full simulation data in observables ---
            xData[][i] = Observable(sim_data.x)
            uData[][i] = Observable(sim_data.u)
            tData[][i] = Observable(sim_data.t)
            
            # Collect time points for slider range
            union!(all_time_points, sim_data.t)

            # --- Initialize snapshot data (xs, us) for the current slider time ---
            # Find the index 'm' closest to the current slider time 't'
            current_t = tSlider.value[] # Get slider's current value
             # Use findmin to get index of closest time step; handle empty t case
            closest_t_index = isempty(sim_data.t) ? 0 : findmin(a -> abs(a - current_t), sim_data.t)[2]
            
            if closest_t_index > 0 && closest_t_index <= length(sim_data.x) && closest_t_index <= length(sim_data.u)
                xs[][i] = Observable(sim_data.x[closest_t_index])
                us[][i] = Observable(sim_data.u[closest_t_index])
            else
                # Handle cases where data might be empty or index invalid
                xs[][i] = Observable(Float64[])
                us[][i] = Observable(Float64[])
                 if !isempty(sim_data.t) # Only warn if time existed but index was bad
                     @warn "Could not get initial snapshot for method '$method' at t=$current_t. Index $closest_t_index invalid."
                 end
            end
        end # --- End loop over active methods ---

        # --- Update Time Slider Range ---
        if !isempty(all_time_points)
            sorted_times = sort(collect(all_time_points))
             # Set slider range; ensure start/end are distinct if only one time point
            tSlider.range = length(sorted_times) > 1 ? (sorted_times[1]:(sorted_times[end]-sorted_times[1])/(length(sorted_times)-1):sorted_times[end]) : (sorted_times[1]:sorted_times[1])
             # Clamp current value to the new range and update slider
            new_t = clamp(tSlider.value[], sorted_times[1], sorted_times[end])
            set_close_to!(tSlider, new_t) 
            tLabel_text[] = "t = $(round(new_t, digits=3))" # Update label observable
        else
            # Handle case where no methods are active or no time points were found
            tSlider.range = 0.0:1.0 # Set a default range
            set_close_to!(tSlider, 0.0)
            tLabel_text[] = "t = 0.0"
            println("Warning: No time points found. Setting default time range.")
        end

        # Trigger downstream lifts if needed (usually automatic)
        # notify(xs); notify(us) 
        
        println("Data update complete.")
    end # --- End Lift Block 1 ---


    # --- Lift Block 2: Update Plot Snapshot When Time Slider Changes ---
    # This runs whenever tSlider.value changes.
    lift(tSlider.value) do t
        # Update the label text directly
        tLabel_text[] = "t = $(round(t, digits=3))"

        # Check if data is available before proceeding
        if isempty(xs[]) || isempty(tData[]) || length(xs[]) != length(tData[])
             # This might happen briefly if Lift 1 hasn't finished after methods changed
             # Or if active_num was 0.
             # println("Skipping snapshot update: data not ready.")
             return
        end

        # Update the x and u vectors (xs, us) for the currently selected time t
        for i = eachindex(xs[]) # Loop through each active method's snapshot data
             # Ensure the data observable for this method exists and is valid
            if i > length(tData[]) || i > length(xData[]) || i > length(uData[])
                 continue # Skip if data is inconsistent
            end
             
            current_times = tData[][i][] # Get the full time vector for this method
            
            if isempty(current_times)
                 continue # Skip if this method has no time data
            end

             # Find the index 'm' in the *full* time series (tData) closest to the slider time 't'
            (_, m) = findmin(a -> abs(a - t), current_times)

             # Update the snapshot observables (xs[i], us[i]) with data from the full series (xData, uData) at index m
             # Ensure index 'm' is valid for xData and uData as well
            if m > 0 && m <= length(xData[][i][]) && m <= length(uData[][i][])
                xs[][i][] = xData[][i][][m] # Update the inner observable's value
                us[][i][] = uData[][i][][m] # Update the inner observable's value
            else
                # If index is invalid, clear the snapshot (or handle as error)
                xs[][i][] = Float64[]
                us[][i][] = Float64[]
                 # @warn "Time index $m invalid for method index $i when updating snapshot at t=$t"
            end
        end
        autolimits!(ax) # Optionally readjust limits whenever time changes
    end # --- End Lift Block 2 ---


    # --- Lift Block 3: Redraw Plot ---
    # This runs whenever the number of active methods changes or any parameter changes
    # (It implicitly depends on xs and us, which are updated by Lift 1 and Lift 2)
    lift(method_number, values(params_obs)...) do active_num, _...
        println("Updating plot...")
        
        # --- Clear previous plot elements ---
        empty!(ax) # Remove previous lines/scatter points
        # Remove the old legend object if it exists
        for c in contents(plot_fig[1,1]) # Iterate through elements in the grid layout cell
            if isa(c, Legend)
                delete!(c) # Delete the legend object
            end
        end

        # --- Handle case with no active methods ---
        if active_num == 0
            println("Plotting skipped: No methods selected.")
            # Optionally add a message to the plot
            text!(ax, "No methods selected", position = (0.5, 0.5), align = (:center, :center), 
                  textsize = local_ui_dict["font_size"], justification = :center)
            return # Stop here if nothing to plot
        end

        # --- Plot data for each active method ---
        for i = 1:active_num
             # Ensure snapshot data exists and is valid before plotting
             if i > length(xs[]) || i > length(us[])
                 @warn "Snapshot data missing for method index $i during plotting. Skipping."
                 continue
             end
             
            method = methods_obs[][i] # Get method name for label
            plotLabel = method

            # Get the snapshot data observables for this method
            x_snapshot = xs[][i]
            u_snapshot = us[][i]
            
            # Check if snapshot data is actually populated
            if isempty(x_snapshot[]) || isempty(u_snapshot[])
                 # @info "Snapshot data empty for method '$method' at current time. Skipping plot."
                 continue # Don't plot if no data for this snapshot
            end

            # --- Apply Plotting Styles ---
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            line_style = :solid
            if local_ui_dict["dashed_lines"]; line_style = local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))]; end
            marker_style = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            
            # --- Plot Lines and/or Scatter Points ---
            # Use the snapshot observables directly in plotting functions
            if local_ui_dict["show_lines"]
                lines!(ax, x_snapshot, u_snapshot, label = plotLabel, linestyle = line_style, color = color, linewidth=local_ui_dict["linewidth"])
            end
            if local_ui_dict["show_scatter"]
                scatter!(ax, x_snapshot, u_snapshot, label = plotLabel, marker = marker_style, color = color, markersize=local_ui_dict["markersize"])
            end
        end # --- End loop over active methods ---

        # --- Add Legend ---
        # Only add legend if at least one method was potentially plotted (active_num > 0 check already done)
        Legend(plot_fig[1,1], ax, local_ui_dict["legend"], merge = true, tellheight = false, tellwidth = false,
               titlesize = local_ui_dict["font_size"], labelsize = local_ui_dict["label_size"], 
               valign = local_ui_dict["vPos"], halign = local_ui_dict["hPos"])
        
        autolimits!(ax) # Adjust axis limits after plotting new data
        println("Plot update complete.")

    end # --- End Lift Block 3 ---

    # --- Display Figures ---
    GLMakie.activate!() # Ensure GLMakie backend is active
    display(GLMakie.Screen(), control_fig)
    display(GLMakie.Screen(), plot_fig)

    # Optionally return figures for further interaction
    # return control_fig, plot_fig
end

# function show1DSolutionFig(sim_config::SimulationConfig)
#     updateUI(ui_dict, sim_config.ui_options)
#     plot_fig = Figure(size = ui_dict["figsize"])
#     ax = Axis(plot_fig[1,1], xlabel = "Position", ylabel = "Function Value")
#     println(sim_config.shared_params, sim_config.methods_dict)
#     params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
#     #println(params_all)
#     params_obs = Dict{String,Observable}()
#     [params_obs[key] = Observable(val) for (key, val) = params_all]
#     #println(params_obs)

#     methods = collect(keys(sim_config.methods_dict))
#     methods_obs = Observable([sim_config.default_method])
#     method_number = lift(methods -> length(methods), methods_obs)
   
#     control_fig = createControls(params_obs, methods_obs, methods)

#     tSlider = Slider(control_fig[end+1,:], startvalue = 0)

#     # Datastructures for data saving 
#     xData = Observable(Vector(undef, 1))
#     uData = Observable(Vector(undef, 1))
#     tData = Observable(Vector(undef, 1))
#     xs = Observable(Vector(undef, 1))
#     us = Observable(Vector(undef, 1))

#     #Update Data
#     lift(method_number,values(params_obs)...) do active_num, _...
        
#         t = tSlider.value[]
#         xData[] = Vector(undef, active_num[])
#         uData[] = Vector(undef, active_num[])
#         tData[] = Vector(undef, active_num[])
#         xs[] = Vector(undef, active_num[])
#         us[] = Vector(undef, active_num[])

#         for i = 1:active_num[]
#             method = methods_obs[][i]
#             # Reconstruct parameters for the current method
#             current_method_params = Dict{String, Any}() 
#             for (p_key, p_obs) in params_obs
#                 if haskey(sim_config.methods_dict[method], p_key) || haskey(sim_config.shared_params, p_key)
#                      current_method_params[p_key] = p_obs[]
#                 end
#             end
#             # Ensure method name itself is included if needed by save/load logic
#             params = merge(current_method_params, Dict("method" => method)) 
#             if !doesSimDataExist(params)
#                 println("Data is being calculated...")
#                 sim_data = sim_config.sim_function(params)
#                 saveSimData(sim_data)
#             else
#                 sim_data = loadSimData(params)
#             end
#             xData[][i] = Observable(sim_data.x)
#             uData[][i] = Observable(sim_data.u)
#             tData[][i] = Observable(sim_data.t)
            
#             (_, m) = findmin(a -> abs(a-t), sim_data.t)
#             xs[][i] = Observable(sim_data.x[m])
#             us[][i] = Observable(sim_data.u[m])
#         end
#         ts = sort(union(vcat(map(a -> a[], (tData[]))...)))
#         tSlider.range[] = ts
#     end

#     tLabel = lift(tSlider.value) do t
#         "t = " * string(t)
#     end
#     Label(control_fig[end,:], tLabel)

#     lift(tSlider.value) do t
#         for i = eachindex(xs[])
#             (_, m) = findmin(a -> abs(a-t[]), tData[][i][])
#             xs[][i][] = to_value(xData[][i])[m]
#             us[][i][] = to_value(uData[][i])[m]
#         end
#         #GLMakie.ylims!(ax, ymin, ymax)
#     end

#     lift(method_number,values(params_obs)...) do active_num, _...

#         empty!(ax)
#         for c = contents(plot_fig[1,1])
#             if isa(c, Legend)
#                 empty!(c.blockscene)
#                 delete!(c)
#             end
#         end
#         for i = 1:active_num[]
#             println(params_obs,i)
#             method = methods_obs[][i]
#             plotLabel = method
#             if ui_dict["dashed_lines"][]
#                 line_style = ui_dict["line_style"][mod1(i, length(ui_dict["line_style"]))]
#             else
#                 line_style = :solid
#             end
#             color = ui_dict["colors"][mod1(i, length(ui_dict["colors"]))]
            
#             marker_style = ui_dict["markers"][mod1(i, length(ui_dict["markers"]))]
#             if ui_dict["show_scatter"][]
#                 GLMakie.scatter!(ax, xs[][i], us[][i], label = plotLabel, marker = marker_style, color = color)
#             end 
#             if ui_dict["show_lines"][]
#                 GLMakie.lines!(ax, xs[][i], us[][i], label = plotLabel, linestyle = line_style, color = color)
#             end
#         end

#         #apply_style!(plot_fig[1,1])
#         Legend(plot_fig[1,1], ax, ui_dict["legend"], merge = true, tellheight = false, tellwidth = false,
#             titlesize = ui_dict["font_size"], labelsize = ui_dict["label_size"], valign = ui_dict["vPos"], halign = ui_dict["hPos"])
#     end

#     GLMakie.activate!()
#     display(GLMakie.Screen(),control_fig)
#     display(GLMakie.Screen(),plot_fig)
# end

# Gemini code 


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

    control_fig = createControls(params_obs, methods_obs, methods)

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

Creates an interactive Makie plot showing the 2D solution `u(x, y)` at different 
times `t` for various simulation methods, using data from `SimData2D`.

Uses two figures: one for the plot (`plot_fig`) and one for controls (`control_fig`).
Allows toggling methods, adjusting parameters, scrubbing through time with a slider,
and switching between a 2D scatter plot (colored by `u`) and a 3D surface/mesh plot.

# Arguments
- `sim_config::SimulationConfig`: Configuration object containing the simulation 
  function (`sim_function`), method definitions (`methods_dict`), shared parameters 
  (`shared_params`), default method, and UI overrides (`ui_options`). 
  Assumes `sim_function` returns `SimData2D` with `x::Vector{Vector{NTuple{2,Float64}}}`, 
  `u::Vector{Vector{Float64}}`, and `t` fields.
"""
# function show2DSolutionFig(sim_config::SimulationConfig)
#     # --- Basic Setup ---
#     local_ui_dict = deepcopy(ui_dict2D) # Use a local copy for UI settings
#     updateUI(local_ui_dict, sim_config.ui_options)

#     # Create the main plotting figure
#     # We will add the Axis dynamically in the plotting lift, as it might be Axis or Axis3
#     plot_fig = Figure(size = local_ui_dict["figsize"])

#     # --- Parameter Handling ---
#     params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
#     params_obs = Dict{String,Observable}()
#     for (key, val) in params_all; params_obs[key] = Observable(val); end

#     # --- Method Selection Handling ---
#     methods = collect(keys(sim_config.methods_dict))
#     methods_obs = Observable([sim_config.default_method])
#     method_number = lift(length, methods_obs)

#     # --- Create Control Figure ---
#     control_fig = createControls(params_obs, methods_obs, methods) # Use existing function

#     # --- Time Slider Setup ---
#     tSlider = Slider(control_fig[end+1, :], range = 0.0:1.0, startvalue = 0.0)
#     tLabel_text = Observable("t = 0.0")
#     tLabel = Label(control_fig[end, :], text = tLabel_text) # Note: using end, not end+1

#     # --- Plot Type Toggle ---
#     plot_toggle_layout = control_fig[end+1, :] = GridLayout() # Add new row for toggle
#     plot_as_surface_obs = Observable(local_ui_dict["plot_as_surface"]) # Observable for toggle state
#     Label(plot_toggle_layout[1, 1], "Plot as Surface (3D)")
#     toggle_plot_type = Toggle(plot_toggle_layout[1, 2], active = plot_as_surface_obs[])
#     # Link toggle interaction to the observable
#     on(toggle_plot_type.active) do active_state
#         plot_as_surface_obs[] = active_state
#         println("Plot type switched to: ", active_state ? "Surface (3D)" : "Scatter (2D)")
#     end


#     # --- Data Structures for 2D Data ---
#     # Observables holding the full time series for *all* active methods
#     xData = Observable(Vector{Observable{Vector{Vector{NTuple{2, Float64}}}}}(undef, 0))
#     uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
#     tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0)) # Same as 1D

#     # Observables holding the data snapshot for the *currently selected time*
#     xs = Observable(Vector{Observable{Vector{NTuple{2, Float64}}}}(undef, 0)) # Snapshot of coordinates
#     us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))       # Snapshot of solution values

#     # --- Lift Block 1: Load/Compute Data & Update Time Slider Range ---
#     # Runs when methods or parameters change. Logic very similar to 1D version.
#     lift(method_number, values(params_obs)...) do active_num, _...
#         println("Updating data based on methods/parameters...")

#         # Resize data structure arrays
#         xData[] = Vector{Observable{Vector{Vector{NTuple{2, Float64}}}}}(undef, active_num)
#         uData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
#         tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
#         xs[] = Vector{Observable{Vector{NTuple{2, Float64}}}}(undef, active_num)
#         us[] = Vector{Observable{Vector{Float64}}}(undef, active_num)

#         all_time_points = Set{Float64}()

#         for i = 1:active_num
#             method = methods_obs[][i]
#             current_method_params = Dict{String, Any}()
#             for (p_key, p_obs) in params_obs
#                 if haskey(sim_config.shared_params, p_key) || haskey(sim_config.methods_dict[method], p_key)
#                     current_method_params[p_key] = p_obs[]
#                 end
#             end
#             params = merge(current_method_params, Dict("method" => method))

#             # --- Load or Compute SimData2D ---
#             println("Running/Loading simulation for method: $method")
#             # sim_data = loadOrComputeData(sim_config.sim_function, params) # Replace with your logic
#             sim_data::SimData2D = sim_config.sim_function(params) # Ensure type for clarity
#             println("Simulation finished for method: $method")

#             # --- Store full simulation data ---
#             xData[][i] = Observable(sim_data.x)
#             uData[][i] = Observable(sim_data.u)
#             tData[][i] = Observable(sim_data.t)

#             union!(all_time_points, sim_data.t)

#             # --- Initialize snapshot data (xs, us) ---
#             current_t = tSlider.value[]
#             closest_t_index = isempty(sim_data.t) ? 0 : findmin(a -> abs(a - current_t), sim_data.t)[2]

#             if closest_t_index > 0 && closest_t_index <= length(sim_data.x) && closest_t_index <= length(sim_data.u)
#                 xs[][i] = Observable(sim_data.x[closest_t_index])
#                 us[][i] = Observable(sim_data.u[closest_t_index])
#             else
#                 xs[][i] = Observable(NTuple{2, Float64}[]) # Empty vector of correct type
#                 us[][i] = Observable(Float64[])
#                 if !isempty(sim_data.t)
#                     @warn "Could not get initial snapshot for method '$method' at t=$current_t. Index $closest_t_index invalid."
#                 end
#             end
#         end # End loop over methods

#         # --- Update Time Slider Range ---
#         if !isempty(all_time_points)
#             sorted_times = sort(collect(all_time_points))
#             # Use step for range if multiple points, otherwise single point range
#              time_step = length(sorted_times) > 1 ? (sorted_times[end] - sorted_times[1]) / (length(sorted_times) - 1) : 0.0
#              time_range = length(sorted_times) > 1 ? range(sorted_times[1], stop=sorted_times[end], step=time_step) : range(sorted_times[1], stop=sorted_times[1], length=1)
            
#             # Fallback if step is zero but multiple points somehow exist
#              if time_step == 0 && length(sorted_times) > 1
#                  time_range = range(sorted_times[1], stop=sorted_times[end], length=length(sorted_times))
#                  @warn "Calculated zero time step for multiple time points, using length-based range."
#              end

#             tSlider.range = time_range
#             new_t = clamp(tSlider.value[], sorted_times[1], sorted_times[end])
#             set_close_to!(tSlider, new_t)
#             tLabel_text[] = "t = $(round(new_t, digits=3))"
#         else
#             tSlider.range = 0.0:1.0
#             set_close_to!(tSlider, 0.0)
#             tLabel_text[] = "t = 0.0"
#             println("Warning: No time points found. Setting default time range.")
#         end
#         println("Data update complete.")
#     end # --- End Lift Block 1 ---


#     # --- Lift Block 2: Update Plot Snapshot When Time Slider Changes ---
#     # Logic is identical to 1D, types handled by observables.
#     lift(tSlider.value) do t
#         tLabel_text[] = "t = $(round(t, digits=3))"
#         if isempty(xs[]) || isempty(tData[]) || length(xs[]) != length(tData[])
#             return
#         end

#         for i = eachindex(xs[])
#             if i > length(tData[]) || i > length(xData[]) || i > length(uData[])
#                  continue 
#             end
#             current_times = tData[][i][]
#             if isempty(current_times); continue; end

#             (_, m) = findmin(a -> abs(a - t), current_times)

#             if m > 0 && m <= length(xData[][i][]) && m <= length(uData[][i][])
#                 xs[][i][] = xData[][i][][m] # Update snapshot coordinates
#                 us[][i][] = uData[][i][][m] # Update snapshot solution values
#             else
#                 xs[][i][] = NTuple{2, Float64}[]
#                 us[][i][] = Float64[]
#             end
#         end
#     end # --- End Lift Block 2 ---


#     # --- Lift Block 3: Redraw Plot (Main Change for 2D) ---
#     # Runs when methods, parameters, or plot type toggle change.
#     lift(method_number, plot_as_surface_obs, values(params_obs)...) do active_num, plot_surface, _...
#         println("Updating plot...")

#         # --- Clear previous plot figure content ---
#         # Remove axis, legend, colorbar etc.
#         empty!(plot_fig) 

#         # --- Handle case with no active methods ---
#         if active_num == 0
#             println("Plotting skipped: No methods selected.")
#             # Add message directly to the figure grid
#             Label(plot_fig[1, 1], "No methods selected", tellwidth=false, tellheight=false,
#                   textsize = local_ui_dict["font_size"], justification=:center)
#             return
#         end

#         # --- Create Axis based on plot type ---
#         if plot_surface
#             ax = Axis3(plot_fig[1, 1], xlabel="x", ylabel="y", zlabel="Solution (u)", 
#                        title = "Surface Plot at t=$(round(tSlider.value[], digits=3))")
#              ax.aspect = (1, 1, 0.5) # Adjust aspect ratio for 3D view if needed
#         else
#             ax = Axis(plot_fig[1, 1], xlabel="x", ylabel="y", 
#                       title = "Scatter Plot at t=$(round(tSlider.value[], digits=3))",
#                       aspect=DataAspect()) # Ensure correct aspect ratio for 2D scatter
#         end
        
#         # --- Determine Color Range ---
#         # Find global min/max of u across all *visible* snapshots for consistent coloring
#         global_u_min = Inf
#         global_u_max = -Inf
#         valid_data_found = false
#         for i = 1:active_num
#              if i <= length(us[]) && !isempty(us[][i][])
#                  u_vals = us[][i][]
#                  global_u_min = min(global_u_min, minimum(u_vals))
#                  global_u_max = max(global_u_max, maximum(u_vals))
#                  valid_data_found = true
#              end
#         end
        
#         # Set default range if no valid data or min/max are equal
#         color_range = (valid_data_found && global_u_min < global_u_max) ? (global_u_min, global_u_max) : (0.0, 1.0)
#         println("Determined color range: $color_range")

#         # --- Plot data for each active method ---
#         plotted_objects = [] # Store plot objects for potential colorbar linking
#         for i = 1:active_num
#             if i > length(xs[]) || i > length(us[]) continue end # Safety check

#             method = methods_obs[][i]
#             plotLabel = method

#             x_snapshot_obs = xs[][i] # Observable{Vector{NTuple{2, Float64}}}
#             u_snapshot_obs = us[][i] # Observable{Vector{Float64}}

#             if isempty(x_snapshot_obs[]) || isempty(u_snapshot_obs[]) continue end # Skip if no data

#             # --- Prepare points for plotting (handle observables carefully) ---
#             # Use lift to create Point observables that update when snapshots change
#             points_xy = lift(x_snapshot_obs) do x_vec
#                  [Point2f(pt[1], pt[2]) for pt in x_vec] # Convert tuples to Point2f
#             end
#             points_xyz = lift(x_snapshot_obs, u_snapshot_obs) do x_vec, u_vec
#                  # Ensure lengths match before creating points
#                  len = min(length(x_vec), length(u_vec))
#                  [Point3f(x_vec[j][1], x_vec[j][2], u_vec[j]) for j in 1:len]
#             end
            
#             # Color should also be an observable if possible, linked to u_snapshot_obs
#             color_values = u_snapshot_obs # Use the observable directly for color

#             # --- Perform Plotting ---
#             plt_obj = nothing
#             if plot_surface
#                 # Use meshscatter for 3D surface-like plot from scattered points
#                  marker_size = local_ui_dict["markersize_3d"]
#                  # Check if marker size needs scaling (experimental)
#                  # avg_u = mean(u_snapshot_obs[])
#                  # scaled_marker_size = marker_size * (1.0 + 0.5 * abs(avg_u / (color_range[2] - color_range[1] + 1e-6)))
#                 plt_obj = meshscatter!(ax, points_xyz, 
#                                        # marker=Rect3D(Vec3f(1,1,1)), # Use simple marker shape
#                                        markersize = marker_size, # Use Vec3f size from ui_dict
#                                        color = color_values, 
#                                        colormap = local_ui_dict["colormap"], 
#                                        colorrange = color_range, # Apply consistent range
#                                        label = plotLabel)
#             else
#                 # Use scatter for 2D plot, colored by u
#                 plt_obj = scatter!(ax, points_xy, 
#                                    markersize = local_ui_dict["markersize_2d"], 
#                                    color = color_values, 
#                                    colormap = local_ui_dict["colormap"], 
#                                    colorrange = color_range, # Apply consistent range
#                                    label = plotLabel)
#             end
#             push!(plotted_objects, plt_obj) # Store plot object

#         end # --- End loop over active methods ---

#         # --- Add Legend and Colorbar ---
#         if !isempty(plotted_objects)
#             # Add Legend (may get crowded with many methods)
#             Legend(plot_fig[1, 2], ax, local_ui_dict["legend"], merge = true, 
#                    tellheight = false, # Allow colorbar to take space
#                    titlesize = local_ui_dict["font_size"], 
#                    labelsize = local_ui_dict["label_size"]) # valign/halign might need adjustment
                   
#             # Add Colorbar linked to the *first* plotted object (assuming same range applied to all)
#             Colorbar(plot_fig[1, 3], plotted_objects[1], label = "Solution (u)", 
#                      width = 25, ticklabelsize = local_ui_dict["ticklabel_size"])
            
#             # Adjust column widths
#             colsize!(plot_fig.layout, 1, Aspect(1, 1.0)) # Make plot area roughly square if possible
#             colsize!(plot_fig.layout, 2, Auto()) # Legend width auto
#             colsize!(plot_fig.layout, 3, Auto()) # Colorbar width auto
#         end
        
#         # autolimits!(ax) # May not be needed if Axis is recreated

#         println("Plot update complete.")

#     end # --- End Lift Block 3 ---

#     # --- Display Figures ---
#     GLMakie.activate!()
#     display(GLMakie.Screen(), control_fig)
#     display(GLMakie.Screen(), plot_fig)

#     # Optionally return figures
#     # return control_fig, plot_fig
# end

# """
#     show2DSolutionFig(sim_config::SimulationConfig) - REVISED FOR AXIS REUSE

# Creates an interactive Makie plot showing the 2D solution `u(x, y)` at different 
# times `t`, reusing the Axis3 object to maintain interactivity.
# ... (rest of docstring same) ...
# """
# function show2DSolutionFig(sim_config::SimulationConfig)
#     # --- Basic Setup ---
#     local_ui_dict = deepcopy(ui_dict2D) 
#     updateUI(local_ui_dict, sim_config.ui_options)

#     # Create the main plotting figure
#     plot_fig = Figure(size = local_ui_dict["figsize"])

#     # --- Create Axis3 ONCE ---
#     # We will always use Axis3 and configure it for 2D or 3D views.
#     ax = Axis3(plot_fig[1, 1], xlabel="x", ylabel="y", zlabel="Solution (u)")
#     println("Axis3 created initially.") # Debug message

#     # --- Parameter Handling ---
#     params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
#     params_obs = Dict{String,Observable}()
#     for (key, val) in params_all; params_obs[key] = Observable(val); end

#     # --- Method Selection Handling ---
#     methods = collect(keys(sim_config.methods_dict))
#     methods_obs = Observable([sim_config.default_method])
#     method_number = lift(length, methods_obs)

#     # --- Create Control Figure ---
#     control_fig = createControls(params_obs, methods_obs, methods) 

#     # --- Time Slider Setup ---
#     tSlider = Slider(control_fig[end+1, :], range = 0.0:1.0, startvalue = 0.0)
#     tLabel_text = Observable("t = 0.0")
#     tLabel = Label(control_fig[end, :], text = tLabel_text) 

#     # --- Plot Type Toggle ---
#     plot_toggle_layout = control_fig[end+1, :] = GridLayout() 
#     plot_as_surface_obs = Observable(local_ui_dict["plot_as_surface"]) 
#     Label(plot_toggle_layout[1, 1], "Plot as Surface (3D)")
#     toggle_plot_type = Toggle(plot_toggle_layout[1, 2], active = plot_as_surface_obs[])
#     on(toggle_plot_type.active) do active_state
#         plot_as_surface_obs[] = active_state
#         println("Plot type switched to: ", active_state ? "Surface (3D)" : "Scatter (2D)")
#     end


#     # --- Data Structures for 2D Data (Same as before) ---
#     xData = Observable(Vector{Observable{Vector{Vector{NTuple{2, Float64}}}}}(undef, 0))
#     uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
#     tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0)) 
#     xs = Observable(Vector{Observable{Vector{NTuple{2, Float64}}}}(undef, 0)) 
#     us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))       

#     # --- Observable for Global Z Limits & Color Range ---
#     global_zlims_and_colorrange = Observable((0.0, 1.0)) # Use same range for Z and color

#     # --- Lift Block 1: Load/Compute Data & Update Time Slider Range (Same as before) ---
#     lift(method_number, values(params_obs)...) do active_num, _...
#         # ... (Identical code as previous version for loading data into xData, uData, tData, xs, us) ...
#         println("Updating data based on methods/parameters...")

#         # Resize data structure arrays
#         xData[] = Vector{Observable{Vector{Vector{NTuple{2, Float64}}}}}(undef, active_num)
#         uData[] = Vector{Observable{Vector{Vector{Float64}}}}(undef, active_num)
#         tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)
#         xs[] = Vector{Observable{Vector{NTuple{2, Float64}}}}(undef, active_num)
#         us[] = Vector{Observable{Vector{Float64}}}(undef, active_num)

#         all_time_points = Set{Float64}()

#         # Variables to track global min/max of U
#         g_umin, g_umax = Inf, -Inf
#         found_any_u_data = false

#         for i = 1:active_num
#             method = methods_obs[][i]
#             current_method_params = Dict{String, Any}()
#             for (p_key, p_obs) in params_obs
#                 if haskey(sim_config.shared_params, p_key) || haskey(sim_config.methods_dict[method], p_key)
#                     current_method_params[p_key] = p_obs[]
#                 end
#             end
#             params = merge(current_method_params, Dict("method" => method))

#             println("Running/Loading simulation for method: $method")
#             sim_data::SimData2D = sim_config.sim_function(params) # Ensure type for clarity
#             println("Simulation finished for method: $method")

#             xData[][i] = Observable(sim_data.x)
#             uData[][i] = Observable(sim_data.u)
#             tData[][i] = Observable(sim_data.t)
#             union!(all_time_points, sim_data.t)

#             # --- Update Global U Limits ---
#             for k in eachindex(sim_data.t) # Iterate through time steps
#                 u_k = sim_data.u[k]
#                 if !isempty(u_k)
#                     found_any_u_data = true
#                     # Calculate min/max for this snapshot's solution values using extrema
#                     umin_k, umax_k = extrema(u_k) # <<< Use extrema
#                      # Update global solution limits
#                     g_umin = min(g_umin, umin_k)
#                     g_umax = max(g_umax, umax_k)
#                 end
#             end # End loop over time k

#             # --- Initialize snapshot data (xs, us) using the loaded data ---
#             current_t = tSlider.value[]
#             closest_t_index = isempty(sim_data.t) ? 0 : findmin(a -> abs(a - current_t), sim_data.t)[2]

#             if closest_t_index > 0 && closest_t_index <= length(sim_data.x) && closest_t_index <= length(sim_data.u)
#                 xs[][i] = Observable(sim_data.x[closest_t_index])
#                 us[][i] = Observable(sim_data.u[closest_t_index])
#             else
#                 xs[][i] = Observable(NTuple{2, Float64}[]) 
#                 us[][i] = Observable(Float64[])
#                 if !isempty(sim_data.t)
#                     @warn "Could not get initial snapshot for method '$method' at t=$current_t. Index $closest_t_index invalid."
#                 end
#             end
#         end 

#         # --- Finalize and Store Global Z Limits / Color Range ---
#         if found_any_u_data
#             padding_factor = local_ui_dict["axis_limit_padding"]
#             z_range = g_umax - g_umin; z_pad = z_range * padding_factor / 2; z_pad = (z_pad <= 0 && z_range == 0) ? 0.1 : z_pad 
#             final_zlims = (g_umin - z_pad, g_umax + z_pad)
#             global_zlims_and_colorrange[] = final_zlims # Update observable
#             println("Updated global Z limits / color range: $final_zlims")
#         else
#             println("No U data found, using default Z limits / color range.")
#             global_zlims_and_colorrange[] = (0.0, 1.0)
#         end

#         # --- Update Time Slider Range ---
#         if !isempty(all_time_points)
#             sorted_times = sort(collect(all_time_points))
#              time_step = length(sorted_times) > 1 ? (sorted_times[end] - sorted_times[1]) / (length(sorted_times) - 1) : 0.0
#              time_range = length(sorted_times) > 1 ? range(sorted_times[1], stop=sorted_times[end], step=max(eps(Float64), time_step)) : range(sorted_times[1], stop=sorted_times[1], length=1) # Ensure step > 0 if range exists
#              if time_step == 0 && length(sorted_times) > 1
#                  time_range = range(sorted_times[1], stop=sorted_times[end], length=length(sorted_times))
#                  @warn "Calculated zero time step for multiple time points, using length-based range."
#              end

#             tSlider.range = time_range
#             new_t = clamp(tSlider.value[], sorted_times[1], sorted_times[end])
#             set_close_to!(tSlider, new_t) 
#             tLabel_text[] = "t = $(round(new_t, digits=3))" 
#         else
#             tSlider.range = 0.0:1.0 
#             set_close_to!(tSlider, 0.0)
#             tLabel_text[] = "t = 0.0"
#             println("Warning: No time points found. Setting default time range.")
#         end
#         println("Data update complete.")
#     end # --- End Lift Block 1 ---


#     # --- Lift Block 2: Update Plot Snapshot AND Title/Limits When Time Slider Changes ---
#     lift(tSlider.value) do t
#         # Update the label text and axis title
#         tLabel_text[] = "t = $(round(t, digits=3))"
#         ax.title = "t=$(round(t, digits=3))" # <<< UPDATE TITLE HERE

#         # Check data consistency
#         if isempty(xs[]) || isempty(tData[]) || length(xs[]) != length(tData[])
#             # This might happen briefly during transitions, just skip update
#             return 
#         end

#         # Update snapshot data (xs, us)
#         for i = eachindex(xs[])
#             # Check consistency for this specific index
#             if i > length(tData[]) || i > length(xData[]) || i > length(uData[])
#                  # This method's data might not be ready yet
#                  continue 
#             end

#             current_times = tData[][i][] 
#             if isempty(current_times); continue; end # Skip if no time data for this method

#             # Find closest time index 'm'
#             (_, m) = findmin(a -> abs(a - t), current_times)

#             # Update the snapshot observables if index is valid
#             if m > 0 && m <= length(xData[][i][]) && m <= length(uData[][i][])
#                 xs[][i][] = xData[][i][][m] # Update the inner observable's value
#                 us[][i][] = uData[][i][][m] # Update the inner observable's value
#             else
#                 # If index is invalid for data, clear the snapshot for safety
#                 xs[][i][] = NTuple{2, Float64}[]
#                 us[][i][] = Float64[]
#                  # Optional warning if needed
#                  # @warn "Time index $m invalid for method index $i when updating snapshot at t=$t"
#             end
#         end

#         # Adjust axis limits to fit the data at the current time step
#         # This ensures the view adapts if the data moves or changes scale
#         try # Wrap in try-catch as autolimits! might fail if limits are degenerate
#             autolimits!(ax) 
#             current_zlims = global_zlims_and_colorrange[] 
#             zlims!(ax, current_zlims...) # Set low and high Z limits using splatting
#         catch e
#             println("Warning: autolimits! failed - $e")
#         end

#     end # --- End Lift Block 2 ---

#     # --- Lift Block 3: Redraw Plot (REVISED AGAIN for Deletion) ---
#     lift(method_number, plot_as_surface_obs, values(params_obs)...) do active_num, plot_surface, _...
#         println("Updating plot (reusing Axis3)...")

#         # --- Clear existing content WITHOUT destroying axis ---
#         empty!(ax) # Clear plots from the axis object itself

#         # --- Delete old Legend and Colorbar from Figure grid ---
#         # Iterate through the expected grid positions for Legend and Colorbar
#         needs_colorbar_update = false # Flag if colorbar was deleted
#         for (row, col) in [(1, 2), (1, 3)] # Expected positions
#             # Use contents() to get list of elements at the specified grid position
#             content_list = contents(plot_fig[row, col]) 
#             if !isempty(content_list)
#                 # Iterate backwards to avoid index issues if multiple deletable items exist (unlikely here)
#                 for i in length(content_list):-1:1 
#                     elem = content_list[i]
#                     if isa(elem, Union{Legend, Colorbar})
#                         try
#                             delete!(elem)
#                             println("Deleted existing $(typeof(elem)) at ($row, $col)")
#                             if isa(elem, Colorbar); needs_colorbar_update = true; end
#                         catch e 
#                             println("Warning: Failed to delete element $(typeof(elem)) at ($row, $col) - $e") 
#                         end
#                     end
#                 end
#             end
#         end
        
#         # --- Configure the *existing* Axis3 ---
#         #ax.title = "t=$(round(tSlider.value[], digits=3))"
#         # ... (Axis configuration logic remains the same as previous version) ...
#         if plot_surface
#             ax.xlabel = "x"; ax.ylabel = "y"; ax.zlabel = "Solution (u)"
#             ax.aspect = (1, 1, 0.5); ax.perspectiveness = 0.5 
#             ax.xgridvisible=true; ax.ygridvisible=true; ax.zgridvisible=true
#             ax.xticklabelsvisible=true; ax.yticklabelsvisible=true; ax.zticklabelsvisible=true
#             ax.zlabelvisible=true
#         else
#             ax.xlabel = "x"; ax.ylabel = "y"; ax.zlabel = "" 
#             ax.aspect = (1, 1, 1) # Use a valid Axis3 aspect ratio
#             ax.xgridvisible=true; ax.ygridvisible=true; ax.zgridvisible=false 
#             ax.xticklabelsvisible=true; ax.yticklabelsvisible=true; ax.zticklabelsvisible=false 
#             ax.zlabelvisible=false
#             ax.elevation = pi / 2; ax.azimuth = 0; ax.perspectiveness = 0.0 
#             #ax.protrusions = (nothing, nothing, nothing, nothing) 
#         end

#         # --- Fix Z Limits using the global range ---
#         # This overrides any Z limits set by autolimits! in Lift 2
#         try
#             # Use the value from the observable
#             current_zlims = global_zlims_and_colorrange[] 
#             zlims!(ax, current_zlims...) # Set low and high Z limits using splatting
#             println("Applied fixed Z limits: $current_zlims")
#         catch e
#              println("Warning: Failed to apply fixed zlims! - $e")
#         end

#         # --- Handle case with no active methods ---
#         if active_num == 0
#             println("Plotting skipped: No methods selected.")
#             # Use ax.limits to attempt positioning, might need adjustment
#             lims = ax.limits[] # Get current limits (Observable)
#             pos_x = ismissing(lims) ? 0.5 : mean(lims.origin[1] .+ lims.widths[1])
#             pos_y = ismissing(lims) ? 0.5 : mean(lims.origin[2] .+ lims.widths[2])
#             pos_z = ismissing(lims) ? 0.0 : lims.origin[3] # Place at z=0
#             text!(ax, "No methods selected", position = Point3f(pos_x, pos_y, pos_z),
#                   align = (:center, :center), space=:data, fontsize = local_ui_dict["font_size"])
#             return
#         end

#         # --- Use Global Color Range ---
#         color_range = global_zlims_and_colorrange # Use the observable 
#         # # --- Determine Color Range ---
#         # global_u_min = Inf
#         # global_u_max = -Inf
#         # valid_data_found = false
#         # for i = 1:active_num
#         #      # ... (calculation same as before) ...
#         #      if i <= length(us[]) && !isempty(us[][i][])
#         #          u_vals = us[][i][]
#         #          global_u_min = min(global_u_min, minimum(u_vals))
#         #          global_u_max = max(global_u_max, maximum(u_vals))
#         #          valid_data_found = true
#         #      end
#         # end
#         # color_range = (valid_data_found && global_u_min < global_u_max) ? (global_u_min, global_u_max) : (0.0, 1.0)
        
#         # --- Plot data onto the *existing* axis ---
#         plotted_objects = []
#         # ... (plotting loop and point preparation same as before) ...
#         for i = 1:active_num
#             if i > length(xs[]) || i > length(us[]) continue end 
#             method = methods_obs[][i]
#             plotLabel = method
#             x_snapshot_obs = xs[][i] 
#             u_snapshot_obs = us[][i] 
#             if isempty(x_snapshot_obs[]) || isempty(u_snapshot_obs[]) continue end 
#             points_xyz = lift(x_snapshot_obs, u_snapshot_obs) do x_vec, u_vec
#                  len = min(length(x_vec), length(u_vec))
#                  [Point3f(x_vec[j][1], x_vec[j][2], u_vec[j]) for j in 1:len]
#             end
#             points_xy0 = lift(x_snapshot_obs) do x_vec
#                  [Point3f(pt[1], pt[2], 0.0f0) for pt in x_vec] 
#             end
#             color_values = u_snapshot_obs 
#             plt_obj = nothing
#             if plot_surface
#                  marker_size = local_ui_dict["markersize_3d"]
#                  plt_obj = meshscatter!(ax, points_xyz, 
#                                        markersize = marker_size, 
#                                        color = color_values, 
#                                        colormap = local_ui_dict["colormap"], 
#                                        colorrange = color_range, 
#                                        label = plotLabel)
#             else
#                  plt_obj = scatter!(ax, points_xy0, 
#                                    markersize = local_ui_dict["markersize_2d"], 
#                                    color = color_values, 
#                                    colormap = local_ui_dict["colormap"], 
#                                    colorrange = color_range,
#                                    label = plotLabel)
#             end
#             push!(plotted_objects, plt_obj) 
#         end 

#         # --- Add Legend and Colorbar (Recreate them in the figure grid) ---
#         if !isempty(plotted_objects)
#             try
#                 # Check grid cell emptiness before adding
#                 if isempty(contents(plot_fig[1, 2]))
#                     Legend(plot_fig[1, 2], ax, local_ui_dict["legend"], merge = true, 
#                            tellheight = false, 
#                            titlesize = local_ui_dict["font_size"], 
#                            labelsize = local_ui_dict["label_size"]) 
#                 else
#                     println("Warning: Grid cell (1, 2) occupied, skipping Legend.")
#                 end

#                 if isempty(contents(plot_fig[1, 3])) || needs_colorbar_update # Recreate if deleted
#                     # Use the first plotted object for colorbar reference
#                     Colorbar(plot_fig[1, 3], plotted_objects[1], label = "Solution (u)", 
#                              width = 25, ticklabelsize = local_ui_dict["ticklabel_size"])
#                      println("Added Colorbar to (1, 3)")
#                 else
#                      println("Warning: Grid cell (1, 3) occupied, skipping Colorbar.")
#                 end
                
#                 # Adjust column widths 
#                 colsize!(plot_fig.layout, 1, Aspect(1, 1.0)) 
#                 colsize!(plot_fig.layout, 2, Auto()) 
#                 colsize!(plot_fig.layout, 3, Auto()) 
#             catch e
#                 println("Error adding Legend/Colorbar: $e")
#             end
#         end
        
#         println("Plot update complete.")

#     end # --- End Lift Block 3 ---

#     # --- Display Figures ---
#     GLMakie.activate!()
#     display(GLMakie.Screen(), control_fig)
#     display(GLMakie.Screen(), plot_fig)
# end


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
    control_fig = createControls(params_obs, methods_obs, methods)

    # Time Slider
    tSlider = Slider(control_fig[end+1, :], range = 0.0:1.0, startvalue = 0.0)
    tLabel_text = Observable("t = 0.0")
    # Place time label above its slider for better layout
    Label(control_fig[end-1, :], tLabel_text, tellwidth=false) 

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
    return plot_fig, control_fig # Return figs for potential further use
end

end