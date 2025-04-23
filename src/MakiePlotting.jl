module MakiePlotting

using ..Structs
using ..Utils
using GLMakie
using CSV, DataFrames
using Dates # For timestamp in optional info


export show1DSolutionFig, show2DSolutionFig, showDynamicDependence, showConvergencePlot


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
    "animation_fps" => 30,
    "animation_duration_s" => 10.,
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
"""
    assemble_params_for_run(shared_obs, method_obs_collection, method_name)

Constructs a flat parameter dictionary for a simulation run by combining
current shared parameter values and current method-specific parameter values.

Method-specific parameters override shared parameters if keys conflict.
"""
function assemble_params_for_run(
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}},
    method_name::String
    )::ParamDictType # Assuming ParamDictType = Dict{String, Any}

    # Start with current values of shared parameters
    current_params = ParamDict()
    for (key, obs) in shared_params_obs
        current_params[key] = obs[] # Dereference observable
    end

    # Get the specific observable dictionary for the requested method
    if haskey(method_params_collection_obs, method_name)
        method_specific_obs_dict = method_params_collection_obs[method_name]
        # Merge/override with current values of method-specific parameters
        for (key, obs) in method_specific_obs_dict
             current_params[key] = obs[] # Dereference; overrides shared if key exists
        end
    else
        # This might be expected if a method uses only shared params
        @warn "No specific parameters found for method '$method_name' in observable collection."
    end

    # Add method name itself (optional, but often useful for saving/loading)
    current_params["method"] = method_name

    return current_params
end

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

# Add this helper function inside MakiePlotting module or where createControls lives
function is_const_param(obs::Observable)
    val = obs[] # Get the value inside the observable
    return 
end

# Functions for Makie Controls

"""
Creates Textboxes for non-boolean parameters, arranged in rows.
Disables Makie's internal validator for non-numeric types (like String)
to avoid errors, relying on parsing within the callback instead.
"""
# Functions for Makie Controls
function createTextBoxes(
    fig::Makie.Figure,
    keys::Vector{String},
    params_obs::Dict{String, Observable},
    notifier::Observable
    )

    # Create a new grid layout in the next row of the parent figure
    tbLayout = fig[end+1,:] = GridLayout()
    sort!(keys) # Sort keys for consistent order

    if isempty(keys); return; end

    num_items_per_row = 3
    num_rows_needed = ceil(Int, length(keys) / num_items_per_row)
    # Pre-allocate grid layout rows/cols if needed, or let it grow dynamically
    # tbLayout[1:num_rows_needed, 1:(2*num_items_per_row)] = GridLayout() # Example pre-allocation

    for (i, key) in enumerate(keys)
        # Calculate row and column within tbLayout
        layout_row = trunc(Int64, (i-1) / num_items_per_row) + 1
        item_in_row = mod1(i, num_items_per_row)
        label_col = 2 * item_in_row - 1
        textbox_col = 2 * item_in_row

        current_val = params_obs[key][] # Get initial value (might be tuple)
        local validator::Union{Type, Function} # Can be Type or Function
        label_prefix = ""
        value_to_display = current_val # Value for placeholder

        # --- Detect :const, Update Observable, Set Validator ---
        if isa(current_val, Tuple) && length(current_val) == 2 && current_val[1] == :const
            actual_value = current_val[2]
            params_obs[key] = Observable(actual_value) # <<< UPDATE OBSERVABLE TO PLAIN VALUE
            validator = str -> false         # <<< Make textbox non-validating
            label_prefix = "(fixed) "
            value_to_display = actual_value  # Display the unwrapped value
        elseif isa(current_val, AbstractFloat)
            validator = Float64
        elseif isa(current_val, Integer)
            validator = Int
        elseif isa(current_val, String)
             validator = str -> true # Allow any string input
        elseif isa(current_val, Number) # Catch other numbers like Complex
             @error "Unsupported Number type for parameter '$key'. Treating as read-only."
             validator = str -> false # Make read-only
             label_prefix = "(unsupported) "
        else # Treat anything else as String-like, allow any input
             @warn "Parameter '$key' type not recognized for specific validation. Allowing any string input."
             validator = str -> true
        end
        # -------------------------------------------------------

        # Create Label
        Label(tbLayout[layout_row, label_col], label_prefix *key * " = ", halign=:right).padding = (0,5,0,0)            

        # Create Textbox, passing Float64, Int, or Any as the validator
        tb = Textbox(tbLayout[layout_row, textbox_col],
                     placeholder = string(value_to_display),
                     validator = validator, # Pass the determined Type
                     reset_on_defocus = true
                     #width = 100
                     )

        # --- Callback for Textbox Submission ---
        on(tb.stored_string) do s
            try
                target_type = typeof(params_obs[key][])
                local parsed_val

                if target_type == String
                    parsed_val = s # Assign string directly
                else
                    # Attempt to parse to the target numeric type
                    parsed_val = parse(target_type, s)
                end

                if params_obs[key][] != parsed_val
                    params_obs[key][] = parsed_val
                    notifier[] = notifier[] + 1 # Increment notifier
                end
            catch e
                println("Invalid input '$s' for parameter '$key' (expected type $target_type): $e")
                # Reset textbox on error
                tb.stored_string = string(params_obs[key][])
            end
        end # End on
        # -------------------------------------
    end # End for loop

    # Optional: Adjust column sizes within tbLayout
    num_cols_used = 2 * num_items_per_row
    for c = 1:num_cols_used
        # Basic auto sizing
        try; colsize!(tbLayout, c, Auto()); catch; end
    end
    # Adjust overall row height in parent figure
    #rowsize!(fig.layout, Makie.current_row(fig.layout), Auto())

end # End function createTextBoxes


"""
    saveParametersToCSV(base_filename, save_dir, shared_params_obs, method_params_collection_obs, methods_obs, optional_info::Dict)

Gathers current parameter values (shared and active method-specific) and saves
them to a CSV file named based on `base_filename` inside `save_dir`.
Includes optional context information. Returns true on success, false on failure.
"""
function saveParametersToCSV(
    base_filename::String,
    save_dir::String,
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}},
    methods_obs::Observable{Vector{String}},
    optional_info::Dict = Dict{String, Any}() # For context like time, animation settings etc.
    )::Bool # Indicate success/failure

    if isempty(base_filename)
        @warn "CSV save skipped: Base filename is empty."
        return false
    end

    # Construct filename, using a suffix for clarity
    csv_filename = joinpath(save_dir, base_filename * "_params.csv")
    println("Saving parameters to $csv_filename...")

    try
        params_to_save = Pair{String, String}[] # Use String pairs for DataFrame

        # --- Add Optional Context Info First ---
        if !isempty(optional_info)
            push!(params_to_save, "# Context Info" => "====================")
            # Sort optional keys for consistent output
            for key in sort(collect(keys(optional_info)))
                 push!(params_to_save, string(key) => string(optional_info[key]))
             end
        end

        # --- Add Shared Parameters ---
        push!(params_to_save, "# Shared Parameters" => "====================")
        shared_keys = sort(collect(keys(shared_params_obs)))
        if isempty(shared_keys)
             push!(params_to_save, "(None)" => "")
        else
             for p_key in shared_keys
                if haskey(shared_params_obs, p_key) # Safety check
                    p_obs = shared_params_obs[p_key]
                    push!(params_to_save, string(p_key) => string(p_obs[])) # Store value as string
                end
            end
        end

        # --- Add Active Method-Specific Parameters ---
        push!(params_to_save, "# Method-Specific Parameters" => "==========================")
        active_methods = sort(methods_obs[]) # Get current active methods
        if isempty(active_methods)
             push!(params_to_save, "(No methods active)" => "")
        else
            for method_name in active_methods
                push!(params_to_save, "# Method: $method_name" => "--------------------") # Sub-header
                if haskey(method_params_collection_obs, method_name)
                    method_params_obs = method_params_collection_obs[method_name]
                    if !isempty(method_params_obs)
                        method_keys = sort(collect(keys(method_params_obs)))
                        for p_key in method_keys
                             if haskey(method_params_obs, p_key) # Safety check
                                p_obs = method_params_obs[p_key]
                                push!(params_to_save, string(p_key) => string(p_obs[])) # Store value as string
                            end
                        end
                    else
                         push!(params_to_save, "(No specific parameters defined)" => "")
                    end
                else
                     push!(params_to_save, "(Parameter definition collection not found)" => "")
                end
            end # End loop through active methods
        end
        # --------------------------------------

        # Convert to DataFrame and write CSV
        df_to_save = DataFrame(Parameter = first.(params_to_save), Value = last.(params_to_save))
        CSV.write(csv_filename, df_to_save)
        println("Parameters successfully saved.")
        return true # Indicate success

    catch e
        @error "Failed to save parameters to CSV ($csv_filename)!" exception=(e, catch_backtrace())
        return false # Indicate failure
    end
end

"""
    createSaveFigBox(target_layout, plot_fig, shared_params_obs, method_params_collection_obs, methods_obs)

Creates UI elements to save the current plot_fig as PNG and calls
saveParametersToCSV to save parameters.
"""
function createSaveFigBox(
    target_layout,
    plot_fig::Makie.Figure,
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}}, # <<< Pass through
    methods_obs::Observable{Vector{String}} # <<< Pass through
    )

    gb = target_layout[1, 1:2] = GridLayout() # Example layout
    Label(gb[1, 1], "Save PNG+CSV:", halign=:right).padding=(0,5,0,0)
    saveBox = Textbox(gb[1, 2], placeholder = "Type name (no ext)", width=200)
    try; colsize!(gb, 1, Auto()); colsize!(gb, 2, Auto()); catch; end

    get_save_dir() = joinpath(Utils.get_save_path(), "figures")

    on(saveBox.stored_string) do s
         base_name = string(strip(s))
         
         if isempty(base_name); println("Save cancelled (empty name)."); return; end

         save_figures_path = get_save_dir()
         try; mkpath(save_figures_path); catch e; @warn "Could not create dir $save_figures_path: $e"; end

         png_name = joinpath(save_figures_path, base_name * ".png")

         # --- Save PNG ---
         try
             Makie.save(png_name, plot_fig)
             println("Plot saved as $png_name")
         catch e; @error "Failed to save PNG!" exception=(e, catch_backtrace()); end

         # --- Call reusable function to save Parameters ---
         optional_info = Dict(
             "Save Type" => "Static Frame",
             "Timestamp" => string(Dates.now()) # Use Dates.now()
             # Add tSlider value if tSlider variable is accessible here?
             # "Trigger Time (t)" => string(round(tSlider.value[], digits=4))
         )
         saveParametersToCSV( # Call the new function
             base_name,
             save_figures_path,
             shared_params_obs,
             method_params_collection_obs, # Pass it along
             methods_obs,                  # Pass it along
             optional_info
         )
         # --------------------------------------------------

         #saveBox.stored_string = "" # Clear textbox
     end # End on event handler
end

function createMethodCheckboxes(fig::Makie.Figure, methods_obs::Observable{Vector{String}}, methods::Vector{String})
    toLayout = fig[end+1,1:div(length(methods),5)+2] = GridLayout() # 5 hard coded atm can be added to ui_dict
    for (i,method) = enumerate(methods)
        Label(toLayout[mod1(i,5),1], method)
        if method == methods_obs[][1]
            tmp = Checkbox(toLayout[mod1(i,5),2], checked = true)
        else
            tmp = Checkbox(toLayout[mod1(i,5),2], checked = false)
        end
        on(tmp.checked) do checked 
            if to_value(checked) & !(methods[i] in methods_obs[])
                push!(methods_obs[], methods[i])
            elseif !to_value(checked) & (methods[i] in methods_obs[])
                deleteat!(methods_obs[],findfirst(isequal(methods[i]),to_value(methods_obs)))
            end
            notify(methods_obs)
        end
    end
end

function createParameterToggles(fig::Makie.Figure, keys::Vector{String}, params_obs::Dict{String, Observable}, notifier::Observable)
    ptoLayout = fig[end+1,:] = GridLayout()
    for (i,key) = enumerate(keys)
        Label(ptoLayout[i,1], key)
        toggleTmp= Toggle(ptoLayout[i,2], active = to_value(params_obs[key]))
        on(toggleTmp.active) do active
            if params_obs[key][] != active_val
                params_obs[key][] = active_val # Update observable
                notifier[] = notifier[] + 1 # <<< INCREMENT NOTIFIER
            end
        end
    end
end


"""
    createControls_Separated(plot_fig, shared_params_obs, method_params_collection_obs, methods_obs, all_method_names)

Creates a Makie control figure using the user's helper functions, separating shared
and method-specific parameters into sections. Assumes helper functions add their
own rows to the passed figure using `fig[end+1, ...]`.
"""
function createControls(
    plot_fig::Makie.Figure,                             # Figure for save box action reference
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}},
    methods_obs::Observable{Vector{String}},          # Observable list of ACTIVE methods
    all_method_names::Vector{String},   # FULL list of possible methods
    parameter_update_notifier::Observable # Accept notifier                  
    )

    control_fig = Figure(size=(800, 1000)) # Adjust size as needed, likely taller
    Label(control_fig[1, :], "Control Panel", fontsize = 24, font=:bold, tellwidth=false) # Main title

    current_row_tracker = Ref(1) # Use Ref to track rows across helper calls if needed, although helpers use end+1

    # --- Shared Parameters Section ---
    if !isempty(shared_params_obs)
        # Add section title row
        Label(control_fig[end+1, :], "Shared Parameters", fontsize=18, font=:bold, halign=:center, tellwidth=false).padding = (0,0,10,5)
        # Separate keys
        # --- Filter out keys marked as :const ---
        # -------------------------------------
        shared_keys = sort(collect(keys(shared_params_obs)))
        shared_bool_keys = filter(k -> shared_params_obs[k][] isa Bool, shared_keys)
        shared_other_keys = filter(k -> !(shared_params_obs[k][] isa Bool), shared_keys)

        # Call user's helpers (they will add rows using end+1)
        if !isempty(shared_other_keys)
            createTextBoxes(control_fig, shared_other_keys, shared_params_obs, parameter_update_notifier)
        end
        if !isempty(shared_bool_keys)
            createParameterToggles(control_fig, shared_bool_keys, shared_params_obs, parameter_update_notifier)
        end
    end

    # --- Method-Specific Parameters Section ---
    Label(control_fig[end+1, :], "Method-Specific Parameters", fontsize=18, font=:bold, halign=:center, tellwidth=false).padding = (0,0,10,5)
    any_method_specific_params = false
    # Iterate through ALL possible methods to create sections consistently
    for method_name in sort(all_method_names)
        # Check if this method has specific parameter observables defined
        if haskey(method_params_collection_obs, method_name)
            method_params_obs = method_params_collection_obs[method_name]
            if !isempty(method_params_obs)
                any_method_specific_params = true
                # Add a sub-header for the method
                Label(control_fig[end+1, :], method_name, font=:bold, halign=:center, tellwidth=false).padding = (0,0,5,15) # Indent slightly

                # Separate keys for this method
                method_keys = sort(collect(keys(method_params_obs)))
                method_bool_keys = filter(k -> method_params_obs[k][] isa Bool, method_keys)
                method_other_keys = filter(k -> !(method_params_obs[k][] isa Bool), method_keys)

                # Call user's helpers for this method's params
                if !isempty(method_other_keys)
                    createTextBoxes(control_fig, method_other_keys, method_params_obs, parameter_update_notifier)
                end
                if !isempty(method_bool_keys)
                    createParameterToggles(control_fig, method_bool_keys, method_params_obs, parameter_update_notifier)
                end
            end # end if !isempty(method_params_obs)
        end # end if haskey
    end # end for method_name
    if !any_method_specific_params
         Label(control_fig[end+1, :], "(None)", halign=:center, tellwidth=false).padding = (0,0,5,15)
    end
    # --- Method Selection Section ---
    Label(control_fig[end+1, :], "Active Methods", fontsize=18, font=:bold, halign=:center, tellwidth=false).padding = (0,0,10,5)

    # Call user's Checkbox helper function
    createMethodCheckboxes(control_fig, methods_obs, all_method_names)

    # --- Save Box Section ---
    # Note: This currently only passes shared_params_obs to be saved in the CSV.
    # Modifying createSaveFigBox would be needed to save method-specific params too.
    #Label(control_fig[end+1, :], "Save Current View", fontsize=18, font=:bold, halign=:center, tellwidth=false).padding = (0,0,10,5)
    createSaveFigBox(control_fig[end+1,:], plot_fig, shared_params_obs, method_params_collection_obs, methods_obs)

    return control_fig
end


"""
    show1DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot for `SimData1D` with animation playback
and an option to save the animation as a GIF (which may close the window).
Saves corresponding parameters to a CSV file.
Uses closest data point logic for animation frames.
"""
function show1DSolutionFig(sim_config::SimulationConfig)

    # --- Basic Setup & UI ---
    local_ui_dict = deepcopy(ui_dict) # Use the base ui_dict
    if hasproperty(sim_config, :ui_options) && !isnothing(sim_config.ui_options)
         updateUI(local_ui_dict, sim_config.ui_options) # Apply specific overrides
    end
    plot_fig = Figure(size = get(local_ui_dict, "figsize", (900, 600)))
    ax = Axis(plot_fig[1,1], xlabel = "Position (x)", ylabel = "Solution Value (u)") # Title set dynamically

    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    # --- NEW: Notification Observable ---
    parameter_update_notifier = Observable(0)

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    default_method = sim_config.default_method in all_method_names ? sim_config.default_method : (isempty(all_method_names) ? "" : all_method_names[1])
    methods_obs = Observable(isempty(all_method_names) ? String[] : [default_method])
    method_number = lift(length, methods_obs)

    # --- Call the NEW createControls function ---
    control_fig = createControls(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        parameter_update_notifier
    )
    # -----------------------------------------

    # --- NEW Max Tracking Control ---
    # Add Checkbox below the animation/save controls
    track_max_obs = Observable(false) # Get default from dict
    cb_track_max = Toggle(control_fig[end+1, :][1,1], active = false)
    Label(control_fig[end, :][1,2], "Track Maximum") # Span columns

    # Link checkbox state back to observable (no explicit notify needed if lift depends on it)
    on(cb_track_max.active) do track_state
        track_max_obs[] = track_state
    end
    # --- End Max Tracking Control ---

    # --- Time Slider & Label ---
    tLabel_text = Observable("t = 0.0")
    # Add a new row for the time label
    Label(control_fig[end+1, 1:4], text = tLabel_text, tellwidth=false).padding = (0, 0, 5, 0) # Span controls area
    # Add a new row for the time slider
    tSlider = Slider(control_fig[end+1, 1:4], range = 0.0:1.0, startvalue = 0.0) # Span controls area

    # --- Animation and GIF Saving Controls ---
    # Add a new row, using a grid layout within it for alignment
    anim_save_controls_row = control_fig[end+1, 1:4] = GridLayout() # Span controls area

    # Animation State/Controls
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    time_range_data = Ref((0.0, 1.0)) # Stores (t_min, t_max) from actual data
    play_button = Button(anim_save_controls_row[1, 1], label = @lift($is_animating ? "Stop Anim" : "Play Anim")) # Col 1

    # GIF Saving Textbox (Col 2) - with default value
    gif_save_textbox = Textbox(anim_save_controls_row[1, 2], placeholder = "GIF Name (no ext)", width=150)
    gif_save_textbox.stored_string = "untitled_anim" # Set default filename

    # GIF Saving Button (Col 3)
    gif_save_button = Button(anim_save_controls_row[1, 3], label = "Save GIF")

    # Warning Label (Col 4)
    Label(anim_save_controls_row[1, 4], text="(Window may close!)", fontsize=10, color=:darkgray, halign=:left).padding = (10,0,0,0)

    # Adjust column sizes in the controls row for better spacing
    colsize!(anim_save_controls_row, 1, Auto()); colsize!(anim_save_controls_row, 3, Auto()); colsize!(anim_save_controls_row, 4, Auto())



    # --- Data Structures ---
    # Outer Observable holds Vector of Inner Observables (one per method)
    xData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0)) # Full x data series
    uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0)) # Full u data series
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))       # Full t data series
    xs = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))           # Snapshot x data for plotting
    us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))           # Snapshot u data for plotting
    global_xlims = Observable((0.0, 1.0)) # For fixed plot limits
    global_ylims = Observable((0.0, 1.0)) # For fixed plot limits
    # --- NEW: Observables for max tracking ---
    x_at_max_obs = Observable(Vector{Observable{Float64}}(undef, 0)) # Stores X position of max U per method
    u_at_max_obs = Observable(Vector{Observable{Float64}}(undef, 0)) # Stores max U value per method
    # ------------------------------------

        # Flatten the list of ALL observables (shared + all method-specific)
        all_method_param_observables = collect(Iterators.flatten(values(values(method_params_collection_obs))))
    # --- Lift Block 1: Data Loading / Simulation Execution ---
    lift(method_number, parameter_update_notifier; ignore_equal_values=true) do active_num, _...
        println("Lift 1: Running sims / loading data...") # Concise print
        # Resize outer vectors
        resize!(xData[], active_num); resize!(uData[], active_num); resize!(tData[], active_num)
        resize!(xs[], active_num); resize!(us[], active_num)
        resize!(x_at_max_obs[], active_num); resize!(u_at_max_obs[], active_num) # Resize new
        # Ensure inner observables exist
        for k in 1:active_num
             if !isassigned(xData[], k) || !isa(xData[][k], Observable); xData[][k] = Observable(Vector{Vector{Float64}}()); end
             if !isassigned(uData[], k) || !isa(uData[][k], Observable); uData[][k] = Observable(Vector{Vector{Float64}}()); end
             if !isassigned(tData[], k) || !isa(tData[][k], Observable); tData[][k] = Observable(Float64[]); end
             if !isassigned(xs[], k) || !isa(xs[][k], Observable); xs[][k] = Observable(Float64[]); end
             if !isassigned(us[], k) || !isa(us[][k], Observable); us[][k] = Observable(Float64[]); end
             if !isassigned(x_at_max_obs[], k) || !isa(x_at_max_obs[][k], Observable); x_at_max_obs[][k] = Observable(NaN); end
             if !isassigned(u_at_max_obs[], k) || !isa(u_at_max_obs[][k], Observable); u_at_max_obs[][k] = Observable(NaN); end
        end

        all_time_points = Set{Float64}()
        g_xmin, g_xmax = Inf, -Inf; g_umin, g_umax = Inf, -Inf
        found_any_data = false
        active_methods_now = methods_obs[]

        for i = 1:active_num
            method = active_methods_now[i]
            # Assemble params for this method run
            # --- Assemble Parameters using Helper ---
            params = assemble_params_for_run(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )
            # ------------------------------------

            # --- Load or Compute Data ---
            local sim_data::Union{AbstractSimData, Nothing} = nothing
            try
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                if !Utils.doesSimDataExist(params)
                     println(" Running simulation for method: $method")
                     sim_data = sim_config.sim_function(params)
                     Utils.saveSimData(sim_data) # Assumes saveSimData exists
                else
                     println(" Loading data for method: $method")
                     sim_data = Utils.loadSimData(params)
                end
            catch e
                 @warn "Simulation/Load failed for method '$method'" exception=(e, catch_backtrace())
                 sim_data = nothing
            end
            # --------------------------

            # --- Store Data & Update Limits ---
            if isnothing(sim_data) || !isa(sim_data, SimData1D)
                 @warn "Invalid SimData1D for '$method'. Assigning empty."
                 xData[][i][] = Vector{Vector{Float64}}(); uData[][i][] = Vector{Vector{Float64}}(); tData[][i][] = Float64[]
                 xs[][i][] = Float64[]; us[][i][] = Float64[]
                 continue # Skip to next method
            end

            xData[][i][] = sim_data.x
            uData[][i][] = sim_data.u
            tData[][i][] = sim_data.t
            union!(all_time_points, sim_data.t)

            # Update Global Limits Calculation
            for k in eachindex(sim_data.t)
                 if k <= length(sim_data.x) && k <= length(sim_data.u)
                     x_k = sim_data.x[k]; u_k = sim_data.u[k]
                     if !isempty(x_k) && !isempty(u_k)
                         found_any_data = true
                         xmin_k, xmax_k = extrema(x_k); umin_k, umax_k = extrema(u_k)
                         g_xmin = min(g_xmin, xmin_k); g_xmax = max(g_xmax, xmax_k)
                         g_umin = min(g_umin, umin_k); g_umax = max(g_umax, umax_k)
                     end
                 end
            end
            # -----------------------------
        end # End loop over methods

        # --- Finalize and Apply Global Limits ---
        if found_any_data; pad_x=get(local_ui_dict,"x_axis_limit_padding",0.05); pad_y=get(local_ui_dict,"y_axis_limit_padding",0.1); xr=g_xmax-g_xmin; xp=xr≈0 ? 0.1 : (xr*pad_x/2.0); yr=g_umax-g_umin; yp=yr≈0 ? 0.1 : (yr*pad_y/2.0); final_xlims=(g_xmin-xp,g_xmax+xp); final_ylims=(g_umin-yp,g_umax+yp); global_xlims[]=final_xlims; global_ylims[]=final_ylims; try; xlims!(ax,final_xlims); ylims!(ax,final_ylims); catch e; @warn "Failed applying limits" e; end; else; global_xlims[]=(0.0,1.0); global_ylims[]=(0.0,1.0); try; xlims!(ax,0.0,1.0); ylims!(ax,0.0,1.0); catch e; @warn "Failed applying default limits" e; end; end

        # --- Update Time Slider Range / Store Data Range ---
        if !isempty(all_time_points); t_min_data,t_max_data=extrema(all_time_points); time_range_data[]=(t_min_data,t_max_data); sorted_times=sort(collect(all_time_points)); t_len=length(sorted_times); t_range_slider=range(t_min_data,stop=t_max_data,length=max(2,t_len*2+100)); if t_len==1; t_range_slider=range(t_min_data,stop=t_max_data,length=2); end; if tSlider.range[]!=t_range_slider; tSlider.range=t_range_slider; end; current_t_val=clamp(tSlider.value[],t_min_data,t_max_data); set_close_to!(tSlider, current_t_val); else; time_range_data[]=(0.0,1.0); if tSlider.range[]!=(0.0:1.0); tSlider.range=0.0:1.0; end; set_close_to!(tSlider, 0.0); end
        # Set label AFTER slider value might have been clamped/set
        tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"

        # --- Calculate Initial Snapshot and Max Values ---
        # Need to do this AFTER slider value is set for this block
        current_t = tSlider.value[]
        for i = 1:active_num
             if i > length(tData[]) || isempty(tData[][i][]) # Check if data was loaded for this method
                 xs[][i][] = Float64[]; us[][i][] = Float64[]
                 x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN
                 continue
             end
             t_vec = tData[][i][]; x_vecs = xData[][i][]; u_vecs = uData[][i][]
             m = findmin(a->abs(a-current_t), t_vec)[2] # Find closest index
             if 1 <= m <= length(x_vecs) && 1 <= m <= length(u_vecs)
                 x_init_snap = x_vecs[m]; u_init_snap = u_vecs[m]
                 xs[][i][] = x_init_snap; us[][i][] = u_init_snap
                 if !isempty(u_init_snap) # Calc max only if snapshot is valid
                     try; u_max_val, max_idx = findmax(u_init_snap); if isfinite(u_max_val) && 1 <= max_idx <= length(x_init_snap); x_at_max_obs[][i][] = x_init_snap[max_idx]; u_at_max_obs[][i][] = u_max_val; else; x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end; catch; x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end
                 else; x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end
             else # Index m invalid
                 xs[][i][] = Float64[]; us[][i][] = Float64[]
                 x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN
             end
        end
        # --- End Initial Snapshot/Max Calculation ---
        println("Lift 1: Update complete.")
    end # --- End Lift Block 1 ---


    # --- Lift Block 2 (MODIFIED: Calculate and update max observables) ---
    lift(tSlider.value, xData, uData, tData; ignore_equal_values=false) do t, xd_obs, ud_obs, td_obs
        # Get inner vectors
        xd = to_value(xd_obs); ud = to_value(ud_obs); td = to_value(td_obs)
        active_num = method_number[]
        # Consistency check (include new observables)
        if length(xs[])!=active_num || length(us[])!=active_num || length(xd)!=active_num || length(ud)!=active_num || length(td)!=active_num || length(x_at_max_obs[])!=active_num || length(u_at_max_obs[])!=active_num; return; end

        tLabel_text[] = "t = $(round(t, digits=3))"; ax.title = "t=$(round(t, digits=3))"

        for i = 1:active_num # Iterate through active methods
             if i > length(xd) || i > length(ud) || i > length(td); continue; end # Index check
             x_vecs = xd[i][]; u_vecs = ud[i][]; t_vec = td[i][]

             local x_snapshot::Vector{Float64} = Float64[]; local u_snapshot::Vector{Float64} = Float64[]

             # Get snapshot using closest time step logic
             if !isempty(t_vec) && length(t_vec)==length(x_vecs) && length(t_vec)==length(u_vecs)
                 (_, m) = findmin(a -> abs(a - t), t_vec)
                 if 1 <= m <= length(x_vecs); x_snapshot = x_vecs[m]; u_snapshot = u_vecs[m]; end
             end

             # Update snapshot observables
             if i <= length(xs[]) && i <= length(us[]); xs[][i][] = x_snapshot; us[][i][] = u_snapshot; end

             # --- Calculate and Update Max Observables ---
             if !isempty(u_snapshot) && i <= length(x_at_max_obs[]) && i <= length(u_at_max_obs[])
                 try
                     u_max_val, max_idx = findmax(u_snapshot)
                     if isfinite(u_max_val) && 1 <= max_idx <= length(x_snapshot)
                         x_at_max_obs[][i][] = x_snapshot[max_idx]
                         u_at_max_obs[][i][] = u_max_val
                     else; x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end
                 catch e; @warn "findmax failed: $e"; x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end
             else # Empty snapshot or invalid index for max obs
                 if i <= length(x_at_max_obs[]) && i <= length(u_at_max_obs[]); x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end
             end
             # ---------------------------------------------
        end # End loop over methods
    end # --- End Lift Block 2 ---


    # --- Lift Block 3 (Plot Management - ADDED Max Tracking) ---
    # Trigger depends on method changes, snapshot data, AND track_max toggle
    lift(method_number, xs, us, track_max_obs, x_at_max_obs, u_at_max_obs; ignore_equal_values=true) do active_num, current_xs_obsvec, current_us_obsvec, track_max_enabled, current_x_max_obsvec, current_u_max_obsvec

        empty!(ax) # Clear previous plots
        # Clear legend explicitly targeting cell [1, 2]
        try; existing_legend=filter(c->isa(c, Legend), contents(plot_fig[1, 2])); foreach(delete!, existing_legend); catch e; @warn "Could not clear legend cell: $e"; end

        active_methods = methods_obs[]
        if active_num == 0; return; end # Nothing to plot

        # Consistency check
        num_to_plot = min(active_num, length(current_xs_obsvec), length(current_us_obsvec))
        if num_to_plot != active_num; @warn "Lift 3: Data series mismatch. Plotting $num_to_plot series."; end
        if num_to_plot <= 0; return; end

        plotted_objects = [] # For legend
        for i = 1:num_to_plot
            plotLabel = active_methods[i]
            # Get styles for this method
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            linestyle = get(local_ui_dict, "dashed_lines", false) ? local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))] : :solid

            # Access the snapshot observables for plotting
            x_snap_obs = current_xs_obsvec[i]
            u_snap_obs = current_us_obsvec[i]

            # --- Plot main data (Lines/Scatter) ---
            obj_for_legend = nothing
            # Use get for ui_dict keys for safety
            if get(local_ui_dict, "show_lines", true)
                 l = lines!(ax, x_snap_obs, u_snap_obs; color=color, linewidth=get(local_ui_dict,"linewidth", 1.5), label=plotLabel, linestyle=linestyle)
                 obj_for_legend = l
            end
            if get(local_ui_dict, "show_scatter", true)
                 s = scatter!(ax, x_snap_obs, u_snap_obs; color=color, markersize=get(local_ui_dict,"markersize", 8), marker=marker, label=plotLabel)
                 # Only add scatter to legend items if lines weren't plotted or legend is empty
                 if obj_for_legend === nothing; obj_for_legend = s; end
            end
            if obj_for_legend !== nothing; push!(plotted_objects, obj_for_legend); end
            # ------------------------------------

            # --- Plot Max Tracking Line (using observables from arguments) ---
            if track_max_enabled # Check toggle state passed into lift block
                # Ensure index i is valid for the max observable vectors passed in
                if i <= length(current_x_max_obsvec) && i <= length(current_u_max_obsvec)
                   # Access the observables holding max info for method i from the arguments
                   x_max_pos_obs = current_x_max_obsvec[i] # This is Observable{Float64}
                   u_max_val_obs = current_u_max_obsvec[i] # This is Observable{Float64}

                   # Define reactive points for the line segment using lift
                   start_point = lift(x_max_pos_obs; ignore_equal_values=true) do x_max
                        Point2f(isfinite(x_max) ? x_max : NaN, 0)
                   end
                   end_point = lift(x_max_pos_obs, u_max_val_obs; ignore_equal_values=true) do x_max, u_max
                        Point2f(isfinite(x_max) && isfinite(u_max) ? x_max : NaN, isfinite(u_max) ? u_max : NaN)
                   end

                   # Plot the line segment reactively if points are finite
                   linesegments!(ax, lift((s, e) -> isfinite(s[1]) && isfinite(e[1]) && isfinite(e[2]) ? [s, e] : Point2f[], start_point, end_point);
                                  color = (color, 0.75), # Use method color, slightly transparent
                                  linestyle = :dash,
                                  linewidth = ui_dict["linewidth"]/2)
               end # End index check
           end # End if track_max_enabled
           # --- End Max Tracking Line ---

        end # End loop over methods

        # Add Legend (as before)
        if !isempty(plotted_objects)
             try
                 # Clear just in case before adding new one
                 for c in contents(plot_fig.layout); if isa(c, Legend) && c.layout_position == (1, 2); delete!(c); end; end
                 Legend(plot_fig[1, 2], plotted_objects, active_methods[1:num_to_plot], "Methods", tellheight=false)
                 colsize!(plot_fig.layout, 2, Auto()) # Adjust column width
             catch e; @error "Error adding Legend" exception=(e, catch_backtrace()); end
        end
        # Use fixed global limits set in Lift 1 - DO NOT call autolimits!
    end # --- End Lift Block 3 ---


    # --- Animation Button Logic (Using real-time mapping) ---
    on(play_button.clicks) do _
        new_state = !is_animating[]
        if new_state # --- Request Start Animation ---
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
            t_min, t_max = time_range_data[]; if !(t_max > t_min); println("Cannot animate: Invalid time range."); return; end
            is_animating[] = true

            anim_duration_s = get(local_ui_dict, "animation_duration_s", 5.0) # Use value from dict
            anim_fps = get(local_ui_dict, "animation_fps", 30)
            timer_interval = 1.0 / max(1, anim_fps)
            start_real_time = time()
            #anim_time_ref = Ref(t_min) # Start animation from the beginning

            function update_frame(timer_handle)
                # Check if stopped externally
                if !is_animating[]; try close(timer_handle) catch; end; animation_timer[] = nothing; return; end
                # Calculate simulation time based on real time elapsed
                elapsed_real_time = time() - start_real_time
                cycled_elapsed_time = mod(elapsed_real_time, anim_duration_s)
                time_fraction = cycled_elapsed_time / anim_duration_s
                current_sim_time = t_min + time_fraction * (t_max - t_min)
                # Update slider value (triggers Lift 2)
                set_close_to!(tSlider, clamp(current_sim_time, t_min, t_max))
            end

            println("Starting animation (Duration: $(anim_duration_s)s, Target FPS: $anim_fps)...")
            # Start timer immediately, repeat at interval
            animation_timer[] = Timer(update_frame, 0.0, interval=max(0.01, timer_interval))

        else # --- Request Stop Animation ---
            println("Stopping animation...")
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
            is_animating[] = false
            # Nudge Lift 2 to ensure final state matches slider using non-animating logic
            set_close_to!(tSlider, tSlider.value[])
        end
    end
    # --- End Animation Button Logic ---

    # --- GIF Saving Button Logic (using saveParametersToCSV) ---
    on(gif_save_button.clicks) do _
        base_filename = string(strip(gif_save_textbox.stored_string[]))
        if isempty(base_filename); @warn "Enter GIF filename."; return; end

        save_dir = joinpath(Utils.get_save_path(), "figures")
        try mkpath(save_dir) catch e; @warn "Could not create dir: $e"; end
        gif_filename = joinpath(save_dir, base_filename * ".gif")

        println("Preparing GIF: $gif_filename and Parameters...")

        # === Call reusable function to save Parameters ===
        anim_info = Dict(
            "Save Type" => "Animation GIF",
            "Timestamp" => string(Dates.now()),
            "Animation Time Range" => string(time_range_data[]),
            "Animation Duration (s)" => string(get(local_ui_dict, "animation_duration_s", 5.0)),
            "Animation FPS" => string(get(local_ui_dict, "animation_fps", 30)),
            "Save Trigger Time (t)" => string(round(tSlider.value[], digits=4))
            # Add other relevant info?
        )
        save_success = saveParametersToCSV( # Call the new function
                            base_filename,
                            save_dir,
                            shared_params_obs,
                            method_params_collection_obs,
                            methods_obs,
                            anim_info
                    )
        if !save_success; @warn "Parameter CSV saving failed for $base_filename. Continuing with GIF..."; end
        # =================================================

        # Stop interactive animation if running
        was_animating = is_animating[]
        if was_animating; if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end; is_animating[] = false; sleep(0.1); end

        # Get parameters for saving GIF
        t_min, t_max = time_range_data[]; if !(t_max > t_min); println("Cannot save GIF: Invalid time range."); if was_animating; is_animating[]=true; end; return; end
        duration_s = get(local_ui_dict, "animation_duration_s", 5.0); fps = get(local_ui_dict, "animation_fps", 30); n_frames = round(Int, duration_s * fps); if n_frames <= 0; n_frames = 100; end
        times_for_gif = range(t_min, t_max, length=n_frames)

        # --- Record the animation ---
        try
            println("Recording $n_frames frames at $fps FPS... (Window may close)")
            xlims!(ax, global_xlims[]); ylims!(ax, global_ylims[]) # Use fixed limits

            record(plot_fig, gif_filename, times_for_gif; framerate = fps) do t_now
                set_close_to!(tSlider, t_now) # Update plot state via Lift 2
                yield() # Allow Makie to process events and redraw
            end
            println("Animation saved successfully to $gif_filename")
        catch e; @error "Failed to save GIF animation!" exception=(e, catch_backtrace());
        finally; println("GIF saving process finished."); end
        # --------------------------
    end
    # --- End GIF Saving Logic ---


    # --- Timer Cleanup on Figure Close ---
    on(plot_fig.scene.events.window_open) do is_open
        # Stop timer if figure closes
        if !is_open && !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; is_animating[] = false; end
    end

    # --- Display Figures ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return control_fig, plot_fig
end

"""
    show1DSolutionFig_with_animation(sim_config::SimulationConfig)

Creates an interactive Makie plot for `SimData1D` with animation playback
and an option to save the animation as a GIF.
Uses closest data point logic for animation frames.
"""
function show1DSolutionFig_with_animation2(sim_config::SimulationConfig)
    # --- Basic Setup & UI ---
    local_ui_dict = deepcopy(ui_dict)
    # updateUI(...)
    plot_fig = Figure(size = get(local_ui_dict, "figsize", (900, 600)))
    ax = Axis(plot_fig[1,1], xlabel = "Position (x)", ylabel = "Solution Value (u)") # Title set dynamically

    # --- Parameter & Method Observables/Controls ---
    # (Same as before)
    params_all = mergeParams(sim_config.shared_params, sim_config.methods_dict)
    params_obs = Dict{String,Observable}()
    for (key, val) in params_all; params_obs[key] = Observable(val); end
    methods = collect(keys(sim_config.methods_dict))
    default_method = sim_config.default_method in methods ? sim_config.default_method : (isempty(methods) ? "" : methods[1])
    methods_obs = Observable(isempty(methods) ? String[] : [default_method])
    method_number = lift(length, methods_obs)
    control_fig = createControls(plot_fig, params_obs, methods_obs, methods)

    # --- Time Slider & Label ---
    tLabel_text = Observable("t = 0.0")
    Label(control_fig[end+1, 1:3], text = tLabel_text, tellwidth=false).padding = (0, 0, 5, 0) # Span 3 columns
    tSlider = Slider(control_fig[end+1, 1:3], range = 0.0:1.0, startvalue = 0.0) # Span 3 columns

    # --- Animation and GIF Saving Controls ---
    # Place these controls together in the next row
    anim_save_controls_row = control_fig[end+1, :] = GridLayout()

    # Animation State/Controls
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    time_range_data = Ref((0.0, 1.0)) # Stores (t_min, t_max)
    play_button = Button(anim_save_controls_row[1, 1], label = @lift($is_animating ? "Stop Anim" : "Play Anim")) # Col 1

    # GIF Saving Textbox
    gif_save_textbox = Textbox(anim_save_controls_row[1, 2], placeholder = "GIF Name (no ext)", width=150) # Col 2

    # GIF Saving Button
    gif_save_button = Button(anim_save_controls_row[1, 3], label = "Save GIF") # Col 3

    # Adjust column sizes maybe
    # colsize!(control_fig.layout, 1, Auto()); colsize!(control_fig.layout, 3, Auto())

    # --- Data Structures ---
    # (Same as before: xData, uData, tData, xs, us, global_xlims, global_ylims)
    xData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
    uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    xs = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    global_xlims = Observable((0.0, 1.0)); global_ylims = Observable((0.0, 1.0))

    # --- Lift Block 1 (Data Loading, Limit Calc, Time Range Update) ---
    # (Same as previous working version)
    lift(method_number, values(params_obs)...; ignore_equal_values=true) do active_num, _...
        println("Lift 1: Updating data, calculating global limits...")
        # (Resize arrays: xData[], uData[], tData[], xs[], us[])
        resize!(xData[], active_num); resize!(uData[], active_num); resize!(tData[], active_num)
        resize!(xs[], active_num); resize!(us[], active_num)
        # (Ensure inner observables exist)
        for k in 1:active_num; if !isassigned(xData[], k) || !isa(xData[][k], Observable); xData[][k] = Observable(Vector{Vector{Float64}}()); end; if !isassigned(uData[], k) || !isa(uData[][k], Observable); uData[][k] = Observable(Vector{Vector{Float64}}()); end; if !isassigned(tData[], k) || !isa(tData[][k], Observable); tData[][k] = Observable(Float64[]); end; if !isassigned(xs[], k) || !isa(xs[][k], Observable); xs[][k] = Observable(Float64[]); end; if !isassigned(us[], k) || !isa(us[][k], Observable); us[][k] = Observable(Float64[]); end; end

        all_time_points = Set{Float64}(); g_xmin, g_xmax = Inf, -Inf; g_umin, g_umax = Inf, -Inf; found_any_data = false
        active_methods_now = methods_obs[]

        for i = 1:active_num # Loop Methods
            method = active_methods_now[i]
            # (Assemble params)
            current_method_params=Dict{String,Any}(); shared_keys=keys(sim_config.shared_params); method_keys=haskey(sim_config.methods_dict,method) ? keys(sim_config.methods_dict[method]) : []; for (pk,po) in params_obs; if pk in shared_keys || pk in method_keys; current_method_params[pk]=po[]; end; end; params=merge(current_method_params,Dict("method"=>method))
            local sim_data::Union{AbstractSimData, Nothing} = nothing
            try; sim_data = sim_config.sim_function(params); catch e; @warn "Sim failed: $method" exception=(e,catch_backtrace()); sim_data=nothing; end

            if isnothing(sim_data) || !isa(sim_data, SimData1D); @warn "Invalid SimData1D for '$method'."; xData[][i][]=[]; uData[][i][]=[]; tData[][i][]=[]; xs[][i][]=[]; us[][i][]=[]; continue; end
            xData[][i][] = sim_data.x; uData[][i][] = sim_data.u; tData[][i][] = sim_data.t; union!(all_time_points, sim_data.t)

            # (Update Global Limits g_xmin, etc.)
            for k in eachindex(sim_data.t); if k <= length(sim_data.x) && k <= length(sim_data.u); x_k=sim_data.x[k]; u_k=sim_data.u[k]; if !isempty(x_k) && !isempty(u_k); found_any_data=true; xmin_k, xmax_k = extrema(x_k); umin_k, umax_k = extrema(u_k); g_xmin=min(g_xmin, xmin_k); g_xmax=max(g_xmax, xmax_k); g_umin=min(g_umin, umin_k); g_umax=max(g_umax, umax_k); end; end; end
        end # End method loop

        # (Finalize and Apply Global Limits)
        if found_any_data; pad_x = get(local_ui_dict, "x_axis_limit_padding", 0.1); pad_y = get(local_ui_dict, "y_axis_limit_padding", 0.1); xr = g_xmax - g_xmin; xp = xr ≈ 0 ? 0.1 : (xr*pad_x/2.0); yr = g_umax - g_umin; yp = yr ≈ 0 ? 0.1 : (yr*pad_y/2.0); final_xlims = (g_xmin-xp, g_xmax+xp); final_ylims = (g_umin-yp, g_umax+yp); global_xlims[] = final_xlims; global_ylims[] = final_ylims; try; xlims!(ax, final_xlims); ylims!(ax, final_ylims); catch e; @warn "Failed applying limits" e; end; else; global_xlims[] = (0.0, 1.0); global_ylims[] = (0.0, 1.0); try; xlims!(ax, 0.0, 1.0); ylims!(ax, 0.0, 1.0); catch e; @warn "Failed applying default limits" e; end; end

        # (Store Time Range and Update Time Slider)
        if !isempty(all_time_points); t_min_data, t_max_data = extrema(all_time_points); time_range_data[] = (t_min_data, t_max_data); sorted_times = sort(collect(all_time_points)); t_len = length(sorted_times); t_range_slider = range(t_min_data, stop=t_max_data, length=max(2, t_len*2+100)); if t_len == 1; t_range_slider = range(t_min_data, stop=t_max_data, length=2); end; if tSlider.range[] != t_range_slider; tSlider.range = t_range_slider; end; current_t_val = clamp(tSlider.value[], t_min_data, t_max_data); set_close_to!(tSlider, current_t_val); tLabel_text[] = "t = $(round(current_t_val, digits=3))"; else; time_range_data[] = (0.0, 1.0); if tSlider.range[] != (0.0:1.0); tSlider.range = 0.0:1.0; end; set_close_to!(tSlider, 0.0); tLabel_text[] = "t = 0.0"; end

        println("Lift 1: Update complete.")
        notify(tSlider.value) # Ensure Lift 2 runs to calculate initial snapshot based on possibly new data
    end # --- End Lift Block 1 ---


    # --- Lift Block 2 (SIMPLIFIED: Always uses closest time step) ---
    lift(tSlider.value, xData, uData, tData; ignore_equal_values=false) do t, xd_obs, ud_obs, td_obs
        xd = to_value(xd_obs); ud = to_value(ud_obs); td = to_value(td_obs)
        num_active = method_number[]
        if length(xs[])!=num_active || length(us[])!=num_active || length(xd)!=num_active || length(ud)!=num_active || length(td)!=num_active; return; end

        tLabel_text[] = "t = $(round(t, digits=3))"; ax.title = "t=$(round(t, digits=3))"

        for i = 1:num_active
             if i > length(xd) || i > length(ud) || i > length(td) continue end
             x_vecs = xd[i][]; u_vecs = ud[i][]; t_vec = td[i][]
             if isempty(t_vec) || isempty(x_vecs) || isempty(u_vecs) || length(t_vec)!=length(x_vecs) || length(t_vec)!=length(u_vecs)
                 if i <= length(xs[]) && i <= length(us[]); xs[][i][] = Float64[]; us[][i][] = Float64[]; end; continue
             end
             # --- Find index 'm' of the original time step closest to 't' ---
             (_, m) = findmin(a -> abs(a - t), t_vec)
             local x_snapshot::Vector{Float64}; local u_snapshot::Vector{Float64}
             if 1 <= m <= length(x_vecs) && 1 <= m <= length(u_vecs); x_snapshot = x_vecs[m]; u_snapshot = u_vecs[m]; else; x_snapshot = Float64[]; u_snapshot = Float64[]; end
             # --- Update snapshot observables ---
             if i <= length(xs[]) && i <= length(us[]); xs[][i][] = x_snapshot; us[][i][] = u_snapshot; end
        end # End loop over methods
    end # --- End Lift Block 2 ---


    # --- Lift Block 3 (Plot Management) ---
    # Trigger depends on method changes AND snapshot data changes
    lift(method_number, xs, us; ignore_equal_values=true) do active_num, current_xs_obsvec, current_us_obsvec
        empty!(ax)
        # (Clear legend as before)
        for c in contents(plot_fig.layout); if isa(c, Legend); try delete!(c) catch; end; end; end
        active_methods = methods_obs[]; if active_num == 0; return; end
        num_to_plot = min(active_num, length(current_xs_obsvec), length(current_us_obsvec)); if num_to_plot <= 0; return; end

        plotted_objects = []
        for i = 1:num_to_plot
            plotLabel = active_methods[i]
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            linestyle = get(local_ui_dict, "dashed_lines", false) ? local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))] : :solid
            x_snap_obs = current_xs_obsvec[i]; u_snap_obs = current_us_obsvec[i]
            obj_for_legend = nothing
            if get(local_ui_dict, "show_lines", true); l = lines!(ax, x_snap_obs, u_snap_obs; color=color, linewidth=get(local_ui_dict,"linewidth", 1.5), label=plotLabel, linestyle=linestyle); obj_for_legend = l; end
            if get(local_ui_dict, "show_scatter", true); s = scatter!(ax, x_snap_obs, u_snap_obs; color=color, markersize=get(local_ui_dict,"markersize", 8), marker=marker, label=plotLabel); if obj_for_legend === nothing; obj_for_legend = s; end; end
            if obj_for_legend !== nothing; push!(plotted_objects, obj_for_legend); end
        end
        # (Add Legend as before, using try/catch and plot_fig[1, 2])
         if !isempty(plotted_objects); try; for c in contents(plot_fig.layout); if isa(c, Legend); delete!(c); end; end; Legend(plot_fig[1, 2], plotted_objects, active_methods[1:num_to_plot], "Methods", tellheight=false); colsize!(plot_fig.layout, 2, Auto()); catch e; @error "Error adding Legend" exception=(e, catch_backtrace()); end; end
        # Use fixed global limits set in Lift 1
    end # --- End Lift Block 3 ---


    # --- Animation Button Logic (Using real-time mapping) ---
    on(play_button.clicks) do _
        new_state = !is_animating[]
        if new_state # --- Request Start Animation ---
             if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
             t_min, t_max = time_range_data[]; if !(t_max > t_min); println("Cannot animate: Invalid time range."); return; end
             is_animating[] = true

             anim_duration_s = get(local_ui_dict, "animation_duration_s", 10.0)
             anim_fps = get(local_ui_dict, "animation_fps", 30)
             timer_interval = 1.0 / max(1, anim_fps)
             start_real_time = time()

             function update_frame(timer_handle)
                 if !is_animating[]; try close(timer_handle) catch; end; animation_timer[] = nothing; return; end
                 elapsed_real_time = time() - start_real_time
                 cycled_elapsed_time = mod(elapsed_real_time, anim_duration_s)
                 time_fraction = cycled_elapsed_time / anim_duration_s
                 current_sim_time = t_min + time_fraction * (t_max - t_min)
                 set_close_to!(tSlider, clamp(current_sim_time, t_min, t_max)) # Update slider -> triggers Lift 2
             end
             println("Starting animation...")
             animation_timer[] = Timer(update_frame, 0.0, interval=max(0.01, timer_interval))
        else # --- Request Stop Animation ---
            println("Stopping animation...")
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
            is_animating[] = false
            set_close_to!(tSlider, tSlider.value[]) # Nudge Lift 2
        end
    end
    # --- End Animation Button Logic ---

    # --- NEW GIF Saving Button Logic ---
    on(gif_save_button.clicks) do _
        base_filename = strip(gif_save_textbox.stored_string[])
        if isempty(base_filename)
            @warn "Please enter a filename for the GIF."
            return
        end

        save_dir = joinpath(get_save_path(), "figures")
        try mkpath(save_dir) catch e; @warn "Could not create save directory $save_dir: $e"; end
        filename = joinpath(save_dir, base_filename * ".gif")

        println("Preparing to save animation to $filename...")

        # Temporarily stop interactive animation if running
        was_animating = is_animating[]
        if was_animating
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
            is_animating[] = false # Set state to stop potential interference
            sleep(0.1) # Brief pause
        end

        # Get parameters for saving GIF
        t_min, t_max = time_range_data[]
        if !(t_max > t_min); println("Cannot save GIF: Invalid time range."); if was_animating; is_animating[] = true; end; return; end

        # Use animation parameters from ui_dict for consistency, or define separate ones for GIF
        duration_s = get(local_ui_dict, "animation_duration_s", 10.0)
        fps = get(local_ui_dict, "animation_fps", 30)
        n_frames = round(Int, duration_s * fps); if n_frames <= 0; n_frames = 100; end

        times_for_gif = range(t_min, t_max, length=n_frames)

        # --- Record the animation ---
        try
            println("Recording $n_frames frames at $fps FPS...")
            # Ensure the plot uses the fixed limits during recording
            xlims!(ax, global_xlims[])
            ylims!(ax, global_ylims[])

            record(plot_fig, filename, times_for_gif; framerate = fps) do t_now
                # For each frame: set slider, which triggers Lift 2, which triggers Lift 3 update
                set_close_to!(tSlider, t_now)
                # Wait briefly allows redraw? Needed sometimes for complex plots.
                sleep(0.005)
            end
            println("Animation saved successfully to $filename")

        catch e
            @error "Failed to save GIF animation!" exception=(e, catch_backtrace())
        finally
             # Optional: Restore slider to original position? Or leave at end? Leave at end for now.
             # Optional: Restart animation if it was running? Simpler to leave stopped.
             # if was_animating; is_animating[] = true; /* restart timer */ end
             println("GIF saving finished.")
        end
    end
    # --- End GIF Saving Logic ---

    # --- Timer Cleanup on Figure Close ---
    on(plot_fig.scene.events.window_open) do is_open
        if !is_open && !isnothing(animation_timer[])
            println("Figure closed, stopping animation timer.")
            try close(animation_timer[]) catch; end; animation_timer[] = nothing
            is_animating[] = false
        end
    end
    # --- End Cleanup ---

    # --- Display Figures ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return control_fig, plot_fig

end # --- End Function Definition ---

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

    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    # --- NEW: Notification Observable ---
    parameter_update_notifier = Observable(0)

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    default_method = sim_config.default_method in all_method_names ? sim_config.default_method : (isempty(all_method_names) ? "" : all_method_names[1])
    methods_obs = Observable(isempty(all_method_names) ? String[] : [default_method])
    method_number = lift(length, methods_obs)

    # --- Call the NEW createControls function ---
    control_fig = createControls(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        parameter_update_notifier
    )
    # -----------------------------------------

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
    lift(method_number, parameter_update_notifier; ignore_equal_values = true) do active_num, _...
        println("Updating data based on methods/parameters...")

        statsData[] = Vector{Observable{Dict{String, Any}}}(undef, active_num)
        tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)

        first_data_loaded = false
        # Store potential keys temporarily before checking type and intersection
        potential_keys_per_method = Vector{Set{String}}(undef, active_num) 
        active_methods_now = methods_obs[]

        for i = 1:active_num
            method = active_methods_now[i]
            # Assemble params for this method run
            # --- Assemble Parameters using Helper ---
            params = assemble_params_for_run(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )
            # ------------------------------------

            # --- Load or Compute Data ---
            local sim_data::Union{AbstractSimData, Nothing} = nothing
            try
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                if !Utils.doesSimDataExist(params)
                     println(" Running simulation for method: $method")
                     sim_data = sim_config.sim_function(params)
                     Utils.saveSimData(sim_data) # Assumes saveSimData exists
                else
                     println(" Loading data for method: $method")
                     sim_data = Utils.loadSimData(params)
                end
            catch e
                 @warn "Simulation/Load failed for method '$method'" exception=(e, catch_backtrace())
                 sim_data = nothing
            end
            # --------------------------

            # --- Store Data & Update Limits ---
            if isnothing(sim_data) || !isa(sim_data, SimData1D)
                 @warn "Invalid SimData1D for '$method'. Assigning empty."
                 xData[][i][] = Vector{Vector{Float64}}(); uData[][i][] = Vector{Vector{Float64}}(); tData[][i][] = Float64[]
                 xs[][i][] = Float64[]; us[][i][] = Float64[]
                 continue # Skip to next method
            end

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
    lift(method_number, selected_stat_index_obs, parameter_update_notifier) do active_num, stat_idx, _...
        println("Updating plot...")
        empty!(ax)
        try
            target_pos = (1, 2)
            existing_content = contents(plot_fig[target_pos...]) # Get content at specific position
            for item in existing_content
                if isa(item, Legend)
                    println("Deleting existing Legend at ", target_pos) # Debug print
                    delete!(item)
                end
            end
        catch e
            # Ignore errors if position doesn't exist or content access fails initially
            # @warn "Could not check/clear legend position [1, 2]: $e" # Optional warning
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
function show2DSolutionFig_old(sim_config::SimulationConfig)
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
                        target_pos = (1, 2)
                        existing_content = contents(plot_fig[target_pos...]) # Get content at specific position
                        for item in existing_content
                            if isa(item, Legend)
                                println("Deleting existing Legend at ", target_pos) # Debug print
                                delete!(item)
                            end
                        end
                    catch e
                        println("Warning: Failed delete element $(typeof(elem)) - $e")
                    end
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
                    Legend(plot_fig[1, 1], ax, local_ui_dict["legend"], merge=true,
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
    show2DSolutionFig(sim_config::SimulationConfig) # Renamed internally for clarity if needed

Creates an interactive Makie plot for `SimData2D` with animation playback
and an option to save the animation as a GIF (which may close the window).
Saves corresponding parameters to a CSV file.
Uses closest data point logic for animation frames.

Features:
- Reuses Axis3 object for stable interactivity.
- Auto-scaling XY limits based on current time step (driven by slider/animation).
- Globally fixed Z limits and Color range based on full dataset.
- Toggle between 2D scatter plot and 3D surface (meshscatter) plot.
- Slider to select colormap dynamically.
- Standard controls for methods, parameters.
- Animation Play/Stop button and GIF saving.
"""
function show2DSolutionFig(sim_config::SimulationConfig) # Keep original name

    # --- Basic Setup & UI ---
    local_ui_dict = deepcopy(ui_dict2D) # Use 2D settings
    if hasproperty(sim_config, :ui_options) && !isnothing(sim_config.ui_options)
        updateUI(local_ui_dict, sim_config.ui_options)
    end
    plot_fig = Figure(size = get(local_ui_dict, "figsize", (900, 700)))
    ax = Axis3(plot_fig[1, 2], xlabel="x", ylabel="y", zlabel="Solution (u)") # Title set dynamically


    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    # --- NEW: Notification Observable ---
    parameter_update_notifier = Observable(0)

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    default_method = sim_config.default_method in all_method_names ? sim_config.default_method : (isempty(all_method_names) ? "" : all_method_names[1])
    methods_obs = Observable(isempty(all_method_names) ? String[] : [default_method])
    method_number = lift(length, methods_obs)

    # --- Call the NEW createControls function ---
    control_fig = createControls(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        parameter_update_notifier
    )
    # -----------------------------------------
    controls_layout = control_fig.layout # Get layout grid

    # Time Slider & Label
    tLabel_text = Observable("t = 0.0")
    Label(controls_layout[end+1, 1:4], text = tLabel_text, tellwidth=false).padding = (0, 0, 5, 0) # Span controls area
    tSlider = Slider(controls_layout[end+1, 1:4], range = 0.0:1.0, startvalue = 0.0) # Span controls area

    # Plot Type Toggle
    plot_toggle_layout = controls_layout[end+1, :] = GridLayout() # Span controls area
    plot_as_surface_obs = Observable(get(local_ui_dict, "plot_as_surface", false))
    Label(plot_toggle_layout[1, 1], "Plot as Surface (3D)") # Span 2 cols for label
    toggle_plot_type = Toggle(plot_toggle_layout[1, 2], active = plot_as_surface_obs[]) # Place toggle in col 3
    on(toggle_plot_type.active) do active_state; plot_as_surface_obs[] = active_state; end

    # Colormap Slider
    cmap_layout = controls_layout[end+1, :] = GridLayout() # Span controls area
    available_cmaps = get(local_ui_dict, "colormaps", [:viridis])
    default_cmap = get(local_ui_dict, "colormap", :viridis)
    default_cmap_idx = findfirst(isequal(default_cmap), available_cmaps); if isnothing(default_cmap_idx); default_cmap_idx = 1; end
    selected_colormap_obs = Observable(available_cmaps[default_cmap_idx])
    cmap_slider = Slider(cmap_layout[1, 1], range = 1:length(available_cmaps), startvalue = default_cmap_idx) # Slider spans 2 cols
    cmap_label = Label(cmap_layout[1, 2], lift(idx -> "$(available_cmaps[idx])", cmap_slider.value), width=Auto(), halign=:left) # Label spans 2 cols
    on(cmap_slider.value) do idx; selected_colormap_obs[] = available_cmaps[idx]; end

    # --- Animation and GIF Saving Controls (Copied from 1D version) ---
    anim_save_controls_row = controls_layout[end+1, 1:4] = GridLayout() # Span controls area
    # Animation State/Controls
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    time_range_data = Ref((0.0, 1.0)) # Stores (t_min, t_max) from actual data
    play_button = Button(anim_save_controls_row[1, 1], label = @lift($is_animating ? "Stop Anim" : "Play Anim")) # Col 1
    # GIF Saving Textbox
    gif_save_textbox = Textbox(anim_save_controls_row[1, 2], placeholder = "GIF Name (no ext)", width=150) # Col 2
    gif_save_textbox.stored_string = "untitled_anim_2D" # Set default filename
    # GIF Saving Button
    gif_save_button = Button(anim_save_controls_row[1, 3], label = "Save GIF") # Col 3
    # Warning Label
    Label(anim_save_controls_row[1, 4], text="(Window may close!)", fontsize=10, color=:darkgray, halign=:left).padding = (10,0,0,0) # Col 4
    # Adjust column sizes
    colsize!(anim_save_controls_row, 1, Auto()); colsize!(anim_save_controls_row, 3, Auto()); colsize!(anim_save_controls_row, 4, Auto())
    # ---------------------------------------------

    # --- Data Structures ---
    xData = Observable(Vector{Observable{Vector{Vector{NTuple{2, Float64}}}}}(undef, 0))
    uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    xs = Observable(Vector{Observable{Vector{NTuple{2, Float64}}}}(undef, 0)) # Snapshot coords
    us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))       # Snapshot values
    global_zlims_and_colorrange = Observable((0.0, 1.0)) # Global U range (min, max)

    # --- Lift Block 1 (MODIFIED: Store time range) ---
    lift(method_number, parameter_update_notifier; ignore_equal_values=true) do active_num, _...
        println("Lift 1 (2D): Updating data & global U range...")
        # Resize outer vectors
        resize!(xData[], active_num); resize!(uData[], active_num); resize!(tData[], active_num)
        resize!(xs[], active_num); resize!(us[], active_num)
        # Ensure inner observables exist
        for k in 1:active_num
            if !isassigned(xData[], k) || !isa(xData[][k], Observable); xData[][k] = Observable(Vector{Vector{NTuple{2,Float64}}}()); end
            if !isassigned(uData[], k) || !isa(uData[][k], Observable); uData[][k] = Observable(Vector{Vector{Float64}}()); end
            if !isassigned(tData[], k) || !isa(tData[][k], Observable); tData[][k] = Observable(Float64[]); end
            if !isassigned(xs[], k) || !isa(xs[][k], Observable); xs[][k] = Observable(NTuple{2, Float64}[]); end
            if !isassigned(us[], k) || !isa(us[][k], Observable); us[][k] = Observable(Float64[]); end
        end

        all_time_points = Set{Float64}()
        g_umin, g_umax = Inf, -Inf; found_any_u_data = false
        active_methods_now = methods_obs[]

        for i = 1:active_num # Loop Methods
            method = active_methods_now[i]
            # --- Assemble Parameters using Helper ---
            params = assemble_params_for_run(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )
            # ------------------------------------

            # --- Load or Compute Data ---
            local sim_data::Union{AbstractSimData, Nothing} = nothing
            try
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                if !Utils.doesSimDataExist(params)
                     println(" Running simulation for method: $method")
                     sim_data = sim_config.sim_function(params)
                     Utils.saveSimData(sim_data) # Assumes saveSimData exists
                else
                     println(" Loading data for method: $method")
                     sim_data = Utils.loadSimData(params)
                end
            catch e
                 @warn "Simulation/Load failed for method '$method'" exception=(e, catch_backtrace())
                 sim_data = nothing
            end
            # --------------------------

            if isnothing(sim_data) || !isa(sim_data, SimData2D); @warn "Invalid SimData2D '$method'."; xData[][i][]=[]; uData[][i][]=[]; tData[][i][]=[]; xs[][i][]=[]; us[][i][]=[]; continue; end
            # Store Data
            xData[][i][] = sim_data.x; uData[][i][] = sim_data.u; tData[][i][] = sim_data.t; union!(all_time_points, sim_data.t)
            # Update Global U limits
            for k in eachindex(sim_data.t); if k <= length(sim_data.u); u_k=sim_data.u[k]; if !isempty(u_k); found_any_u_data=true; umnk,umxk=extrema(u_k); g_umin=min(g_umin,umnk); g_umax=max(g_umax,umxk); end; end; end
        end # End method loop

        # Finalize and Store Global Z Limits / Color Range
        if found_any_u_data; pad_fac=get(local_ui_dict,"axis_limit_padding",0.1); zr=g_umax-g_umin; zp=zr*pad_fac/2.0; zp=(zp<=1e-6 && zr<=1e-6) ? 0.1 : zp; final_zlims=(g_umin-zp, g_umax+zp); global_zlims_and_colorrange[]=final_zlims; else; global_zlims_and_colorrange[]=(0.0, 1.0); end
        println("Lift 1 (2D): Global Z/Color range: $(global_zlims_and_colorrange[])")

        # --- Store Time Range and Update Time Slider ---
        local t_min_data, t_max_data
        if !isempty(all_time_points)
            t_min_data, t_max_data = extrema(all_time_points)
            time_range_data[] = (t_min_data, t_max_data) # Store for animation
            sorted_times = sort(collect(all_time_points)); t_len = length(sorted_times)
            t_range_slider = range(t_min_data, stop=t_max_data, length=max(2, t_len*2+100))
            if t_len == 1; t_range_slider = range(t_min_data, stop=t_max_data, length=2); end
            if tSlider.range[] != t_range_slider; tSlider.range = t_range_slider; end
            current_t_val = clamp(tSlider.value[], t_min_data, t_max_data)
        else
            t_min_data, t_max_data = 0.0, 1.0
            time_range_data[] = (t_min_data, t_max_data)
            if tSlider.range[] != (0.0:1.0); tSlider.range = 0.0:1.0; end
            current_t_val = 0.0
        end
        # Set slider value using set_close_to! AFTER calculating initial snapshot below
        initial_t = current_t_val
        # ---------------------------------------------

        # --- Calculate Initial Snapshot ---
        for i = 1:active_num
             if i > length(tData[]) || isempty(tData[][i][]); xs[][i][]=[]; us[][i][]=[]; continue; end
             t_vec = tData[][i][]; x_vecs = xData[][i][]; u_vecs = uData[][i][]
             m = findmin(a->abs(a-initial_t), t_vec)[2]
             if 1 <= m <= length(x_vecs) && 1 <= m <= length(u_vecs); xs[][i][] = x_vecs[m]; us[][i][] = u_vecs[m]; else; xs[][i][]=[]; us[][i][]=[]; end
        end
        # --- End Initial Snapshot ---

        # Set slider value now, which might trigger Lift 2 if value changed
        set_close_to!(tSlider, initial_t)
        tLabel_text[] = "t = $(round(initial_t, digits=3))"

        println("Lift 1 (2D): Update complete.")
    end # --- End Lift Block 1 ---


    # --- Lift Block 2 (Time Slider Updates - Uses Closest Point) ---
    # UNCHANGED from user's original version - it already does what's needed
    lift(tSlider.value) do t
        tLabel_text[] = "t = $(round(t, digits=3))"; ax.title = "t=$(round(t, digits=3))"
        # Consistency check
        active_num = method_number[]
        if isempty(xs[]) || isempty(tData[]) || length(xs[]) != active_num; return; end

        for i = 1:active_num # Use active_num for loop bound
            # Ensure index validity before access
            if i > length(tData[]) || i > length(xData[]) || i > length(uData[]) || i > length(xs[]) || i > length(us[]); continue; end
            current_times = tData[][i][]; if isempty(current_times); xs[][i][] = []; us[][i][] = []; continue; end

            (_, m) = findmin(a -> abs(a - t), current_times)
            # Ensure m is valid for *all* data vectors for safety
            if m > 0 && m <= length(xData[][i][]) && m <= length(uData[][i][])
                 xs[][i][] = xData[][i][][m]; us[][i][] = uData[][i][][m]
            else; xs[][i][] = NTuple{2, Float64}[]; us[][i][] = Float64[]; end
        end

        # Adjust XY limits automatically for current frame, fix Z limit
        try; autolimits!(ax); catch e; @warn "autolimits! failed in Lift 2" exc=e; end
        try; zlims!(ax, global_zlims_and_colorrange[]...); catch e; @warn "Failed applying zlims in Lift 2" exc=e; end
    end # --- End Lift Block 2 ---


    # --- Lift Block 3 (Plot Redraw & Configuration) ---
    lift(method_number, plot_as_surface_obs, selected_colormap_obs,
        global_zlims_and_colorrange, parameter_update_notifier;
        ignore_equal_values=true) do active_num, plot_surface, current_cmap, current_zlims_val, _...

        println("Lift 3 (2D): Redrawing plot...")
        active_methods = methods_obs[] # Define active_methods here

        empty!(ax); needs_colorbar_update = false
        # Clear legend/colorbar robustly
        try; delete!.(filter(c->isa(c,Legend), contents(plot_fig[1,2]))); catch e; @warn "Could not clear legend: $e"; end
        try; existing_cb=filter(c->isa(c,Colorbar), contents(plot_fig[1,3])); if !isempty(existing_cb); needs_colorbar_update=true; delete!.(existing_cb); end; catch e; @warn "Could not clear colorbar: $e"; end

        # --- Configure Axis Appearance ---
        if plot_surface # Configure for 3D Surface View
            ax.xlabel = "x"
            ax.ylabel = "y"
            ax.zlabel = "Solution (u)"
            ax.aspect = (1, 1, 0.5) # Adjust Z aspect for better 3D view if needed
            ax.perspectiveness = 0.5 # Enable perspective
            # Ensure all elements are potentially visible for 3D
            ax.xgridvisible = true; ax.ygridvisible = true; ax.zgridvisible = true
            ax.xticklabelsvisible = true; ax.yticklabelsvisible = true; ax.zticklabelsvisible = true
            ax.xspinesvisible = true; ax.yspinesvisible = true; ax.zspinesvisible = true
            ax.zlabelvisible = true
            # Reset elevation/azimuth to a sensible default 3D view, or let user control
            # ax.elevation = pi/6
            # ax.azimuth = pi/4
        else # Configure for 2D Scatter View (Top-Down)
            ax.xlabel = "x"
            ax.ylabel = "y"
            ax.zlabel = "" # Hide Z label text
            ax.aspect = :data # Use DataAspect for correct XY scaling
            ax.perspectiveness = 0.0 # Orthographic projection
            # Ensure only XY grid/ticks/spines are visible
            ax.xgridvisible = true; ax.ygridvisible = true; ax.zgridvisible = false # <<< Hide Z grid
            ax.xticklabelsvisible = true; ax.yticklabelsvisible = true; ax.zticklabelsvisible = false # <<< Hide Z ticks
            ax.xspinesvisible = true; ax.yspinesvisible = true; ax.zspinesvisible = false # <<< Hide Z spine
            ax.zlabelvisible = false # Redundant given empty label, but safe
            # --- Explicitly set Top-Down View ---
            ax.elevation = pi/2
            ax.azimuth = 0
            # ------------------------------------
        end

    # (Fix Z Limits as before)
    try; zlims!(ax, current_zlims_val...); catch e; @warn "Failed applying zlims in Lift 3" exc=e; end
    if active_num == 0; return; end # Handle no methods

    color_range = current_zlims_val

    # --- Plot data loop ---
    plotted_objects = []
    plotted_labels = String[] # <<< Initialize list for labels of plotted items

    num_to_plot = min(active_num, length(xs[]), length(us[])); if num_to_plot != active_num; @warn "Lift 3 Plot data mismatch"; end; if num_to_plot <= 0; return; end

    for i = 1:num_to_plot
    if i > length(active_methods); continue; end # Safety check
    current_plot_label = active_methods[i] # Get potential label

    x_snapshot_obs = xs[][i]; u_snapshot_obs = us[][i]
    # Skip if snapshot data is empty for this method
    if isempty(x_snapshot_obs[]) || isempty(u_snapshot_obs[]) continue end

    # (lift points_xyz, points_xy0, color_values - as before)
    points_xyz=lift((x,u)->[Point3f(x[j][1],x[j][2],u[j]) for j in 1:min(length(x),length(u))],x_snapshot_obs,u_snapshot_obs); points_xy0=lift(x->[Point3f(pt[1],pt[2],0.0f0) for pt in x],x_snapshot_obs); color_values=u_snapshot_obs

    plt_obj=nothing; marker_size_3d=local_ui_dict["markersize_3d"]; markersize_2d=local_ui_dict["markersize_2d"]
    # Plot meshscatter! or scatter!
    if plot_surface
        plt_obj = meshscatter!(ax, points_xyz; markersize=marker_size_3d, color=color_values, colormap=current_cmap, colorrange=color_range, label=current_plot_label) # Pass label here
    else
        plt_obj = scatter!(ax, points_xy0; markersize=markersize_2d, color=color_values, colormap=current_cmap, colorrange=color_range, label=current_plot_label) # Pass label here
    end

    # --- Store object AND label if plot was successful ---
    if plt_obj !== nothing
        push!(plotted_objects, plt_obj)
        push!(plotted_labels, current_plot_label) # <<< Store the corresponding label
    end
    # ---------------------------------------------------
    end
    # --- End plot data loop ---

    # --- Add Legend/Colorbar (using the filtered lists) ---
    if !isempty(plotted_objects) # Check if anything was actually plotted
        try
            delete!.(filter(c->isa(c, Legend), contents(plot_fig[1, 1]))) # Clear first
            # Use plotted_labels (guaranteed same length as plotted_objects)
            Legend(plot_fig[1, 1], plotted_objects, plotted_labels, "Methods", tellheight=false) # <<< Use plotted_labels
            # Set fixed or relative size for legend column instead of Auto for width control
            # Or: colsize!(plot_fig.layout, 2, Relative(0.15)) # Use 15% of available width
        catch e; @error "Error adding Legend" exc=e; end
    end
    # (Add/update colorbar logic remains the same)
    if active_num > 0 || needs_colorbar_update; try; delete!.(filter(c->isa(c,Colorbar), contents(plot_fig[1,3]))); Colorbar(plot_fig[1, 3], limits=color_range, colormap=current_cmap, label="Solution (u)", width=25, ticklabelsize=local_ui_dict["ticklabel_size"]); colsize!(plot_fig.layout, 3, Auto()); catch e; @error "Error adding Colorbar" exc=e; end; end
    # ---------------------------------------------
            # --- SET COLUMN SIZES ---
    colsize!(plot_fig.layout, 1, Auto())        # Column 1 (Legend): Size based on content
    colsize!(plot_fig.layout, 2, Auto())        # Column 3 (Colorbar): Size based on content
    colsize!(plot_fig.layout, 3, Auto()) # Column 2 (Plot): Takes remaining space
end # --- End Lift Block 3 ---


    # --- Animation Button Logic (Copied from 1D version) ---
    on(play_button.clicks) do _
        new_state = !is_animating[]
        if new_state # Start Anim
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[]=nothing; end
            t_min, t_max = time_range_data[]; if !(t_max > t_min); println("Cannot animate: Invalid time range."); return; end
            is_animating[] = true
            anim_duration_s = get(local_ui_dict, "animation_duration_s", 10.0) # Use 2D dict value
            anim_fps = get(local_ui_dict, "animation_fps", 30)
            timer_interval = 1.0 / max(1, anim_fps)
            start_real_time = time()
            function update_frame(th); if !is_animating[]; try close(th) catch; end; animation_timer[]=nothing; return; end; ert=time()-start_real_time; cet=mod(ert,anim_duration_s); tf=cet/anim_duration_s; cst=t_min+tf*(t_max-t_min); set_close_to!(tSlider, clamp(cst,t_min,t_max)); end
            println("Starting animation...")
            animation_timer[] = Timer(update_frame, 0.0, interval=max(0.01, timer_interval))
        else # Stop Anim
            println("Stopping animation..."); if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[]=nothing; end
            is_animating[] = false; set_close_to!(tSlider, tSlider.value[]) # Nudge Lift 2
        end
    end # --- End Animation Button Logic ---


    # --- GIF Saving Button Logic (Using saveParametersToCSV) ---
    on(gif_save_button.clicks) do _
        base_filename = string(strip(gif_save_textbox.stored_string[]))
        if isempty(base_filename)
            @warn "Enter GIF filename."
            return
        end

        # Construct paths
        save_dir = joinpath(Utils.get_save_path(), "figures") # Use Utils module path
        try mkpath(save_dir) catch e; @warn "Could not create directory $save_dir: $e"; end
        gif_filename = joinpath(save_dir, base_filename * ".gif")
        # CSV filename is handled inside the helper function now

        println("Preparing 2D GIF: $gif_filename and Parameters...")

        # === Call reusable function to save Parameters ===
        # Create context dictionary with 2D-specific info
        optional_save_info = Dict{String, Any}(
            "Save Type"                => "Animation GIF (2D)",
            "Timestamp"                => string(Dates.now()),
            "Plot Type Request"        => plot_as_surface_obs[] ? "Surface (3D)" : "Scatter (2D)", # State of the toggle
            "Colormap Selection"       => string(selected_colormap_obs[]), # State of colormap
            # Methods list will be saved by the helper function based on methods_obs
            "Animation Time Range"     => string(time_range_data[]),
            "Animation Duration (s)" => string(get(local_ui_dict, "animation_duration_s", 10.0)), # Use 2D default if different
            "Animation FPS"            => string(get(local_ui_dict, "animation_fps", 30)),
            "Save Trigger Time (t)"    => string(round(tSlider.value[], digits=4))
            # Add any other relevant context here
        )

        # Call the reusable function
        # !!! Assumes shared_params_obs and method_params_collection_obs are defined
        # in the scope of show2DSolutionFig according to the new structure !!!
        save_success = saveParametersToCSV(
                        base_filename,
                        save_dir,
                        shared_params_obs,            # Pass shared observables
                        method_params_collection_obs, # Pass method-specific observables collection
                        methods_obs,                  # Pass active methods observable
                        optional_save_info
                    )

        if !save_success
            @warn "Parameter CSV saving failed for $base_filename. Stopping GIF save."
            # Decide if you want to stop GIF recording if CSV fails
            return # Stop GIF recording if CSV fails
        end
        # ==============================================

        # --- Proceed with GIF Recording ---
        # Stop interactive animation if running
        was_animating = is_animating[]
        if was_animating
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
            is_animating[] = false
            sleep(0.1) # Brief pause
        end

        # Get parameters for saving GIF
        t_min, t_max = time_range_data[]
        if !(t_max > t_min)
            println("Cannot save GIF: Invalid time range ($t_min, $t_max).")
            if was_animating; is_animating[]=true; end # Optionally restart animation?
            return
        end
        duration_s = get(local_ui_dict, "animation_duration_s", 10.0) # Use 2D dict default
        fps = get(local_ui_dict, "animation_fps", 30)
        n_frames = round(Int, duration_s * fps); if n_frames <= 0; n_frames = 100; end
        times_for_gif = range(t_min, t_max, length=n_frames)

        # --- Record the animation ---
        try
            println("Recording $n_frames frames at $fps FPS... (Window may close)")
            # Note: Lift 2 controls XY autolimits and fixed Z limits per frame
            record(plot_fig, gif_filename, times_for_gif; framerate = fps) do t_now
                set_close_to!(tSlider, t_now) # Trigger Lift 2 update
                yield() # Allow Makie to process events and redraw
            end
            println("Animation saved successfully to $gif_filename")
        catch e
            @error "Failed to save GIF animation!" exception=(e, catch_backtrace())
        finally
            println("GIF saving process finished.")
            # Leave animation stopped for simplicity
        end
        # -----------------------------
    end
    # --- End GIF Saving Logic ---


    # --- Timer Cleanup on Figure Close ---
    on(plot_fig.scene.events.window_open) do is_open
        if !is_open && !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; is_animating[] = false; end
    end


    # --- Display Figures ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return control_fig, plot_fig
end # --- End show2DSolutionFig Function ---


# --- Ensure other functions like show1DSolutionFig, showConvergencePlot etc. are defined ---

# end # --- End Module MakiePlotting --- # Assuming this is within a module

"""
WARNING! This version is deprecated. It is less stable and has less control 
         options than the functions with the axis predefined. 
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
function showConvergencePlot(
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

# --- Log Scale Toggles ---

    # Add Checkboxes to control figure (adjust row/column layout as needed)
    # Example: Placing them side-by-side in a new row, spanning 2 columns each
    log_scale_layout = control_fig[end+1, :] = GridLayout() # Span 4 columns for example
    cb_log_x = Toggle(log_scale_layout[1, 1], active = false) # Span cols 1-2
    Label(log_scale_layout[1,2], "Log-scale x-axis")
    cb_log_y = Toggle(log_scale_layout[1, 3], active = false) # Span cols 3-4
    Label(log_scale_layout[1,4], "Log-scale y-axis")

    # --- Link Log Scale Toggles to Axis Scale ---
    on(cb_log_x.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        # --- CORRECT WAY: Update value inside the observable ---
        local_ui_dict["x_axis_limit_padding"] = 0
        ax.xscale[] = new_scale_func
        # ------------------------------------------------------
        println("X-Axis scale set to: ", ax.xscale[]) # Debug print shows the function name
    end

    on(cb_log_y.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        # --- CORRECT WAY: Update value inside the observable ---
        local_ui_dict["y_axis_limit_padding"] = 0
        ax.yscale[] = new_scale_func
        # ------------------------------------------------------
        println("Y-Axis scale set to: ", ax.yscale[])
    end
    # ------------------------------------------

    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    # --- NEW: Notification Observable ---
    parameter_update_notifier = Observable(0)

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    default_method = sim_config.default_method in all_method_names ? sim_config.default_method : (isempty(all_method_names) ? "" : all_method_names[1])
    methods_obs = Observable(isempty(all_method_names) ? String[] : [default_method])
    method_number = lift(length, methods_obs)

    # --- Call the NEW createControls function ---
    control_fig = createControls(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        parameter_update_notifier
    )
    # -----------------------------------------
    # --- Convergence Specific Controls ---
    # Store available stat keys (common across all runs)
    stat_keys = Observable([key])
    x_stat_obs = Observable(key)
    y_stat_obs = Observable(key)

    # X-Axis Slider Setup
    Label(control_fig[end+1,:][1,1], "X-Axis:").padding = (0, 10, 0, 0) # Label for the row
    x_stat_slider = Slider(control_fig[end,:][1,2], startvalue = key, range = stat_keys) # Slider uses string keys directly
    x_key_display_label = Label(control_fig[end,:][1,3], text = x_stat_obs, halign = :left) # Label shows selected key


    # Y-Axis Slider Setup
    Label(control_fig[end+1,:][1,1], "Y-Axis:").padding = (0, 10, 0, 0) # Label for the row
    y_stat_slider = Slider(control_fig[end,:][1,2], startvalue = key, range = stat_keys) # Slider uses string keys directly
    y_key_display_label = Label(control_fig[end,:][1,3], text = y_stat_obs, halign = :left) # Label shows selected key
    on(x_stat_slider.value) do s
        if x_stat_obs[] != s # Optional: Nur bei Änderung zuweisen
            x_stat_obs[] = s
        end
    end
    on(y_stat_slider.value) do s
        if y_stat_obs[] != s # Optional: Nur bei Änderung zuweisen
            y_stat_obs[] = s
        end
    end

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



    # Store plot data: [method_idx] -> Observable{Vector{Float64}}
    x_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    y_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))


    # --- Lift 1: Data Loading / Simulation Execution ---
    # Triggered when active methods list or base parameters change.
    lift(method_number, parameter_update_notifier; ignore_equal_values=true) do active_num, _...
        if active_num == 0
            println("Lift 1: No methods selected. Clearing data.")
            all_method_stats[] = []; all_method_times[] = []; actual_param_values_used[] = []
            x_plot_data_methods[] = []; y_plot_data_methods[] = []
            stat_keys[] = [key]#["Varied Parameter ($key)"]
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
                        loadSimData(current_params)
                    end

                    if isnothing(sim_data) || !hasproperty(sim_data, :stats) || !hasproperty(sim_data, :t) || !isa(sim_data.stats, AbstractDict) || !isa(sim_data.t, AbstractVector)
                         println("Invalid sim_data. Skipping.")
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
        println(size(all_method_stats[]), size(all_method_stats[][end]))
        all_method_times[] = temp_method_times
        actual_param_values_used[] = temp_actual_params

        # Update stat key options
        new_axis_keys = [ key; sort(collect(common_stat_keys)) ]
        println(new_axis_keys)

        if stat_keys[] != new_axis_keys
             stat_keys[] = new_axis_keys
             if !(x_stat_obs[] in new_axis_keys) set_close_to!(x_stat_slider, key) end
             if !(y_stat_obs[] in new_axis_keys) set_close_to!(y_stat_slider, key) end
             x_stat_slider.range = new_axis_keys
             y_stat_slider.range = new_axis_keys
             
             # Reset menus if current selection is no longer valid
             # current_x = x_stat_obs[]; #if !(current_x in new_axis_keys); x_stat_menu.selection = new_axis_keys[1]; end
             # current_y = y_stat_obs[]; default_y = length(new_axis_keys)>1 ? new_axis_keys[2] : new_axis_keys[1]; #if !(current_y in new_axis_keys); y_stat_menu.selection = default_y; end
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
        actual_x_key = current_x_key#replace(current_x_key, "Varied Parameter ($key)" => key)
        actual_y_key = current_y_key#replace(current_y_key, "Varied Parameter ($key)" => key)
        
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

    end 
    # --- End Lift Block 1 ---
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

        actual_x_key = x_key #replace(x_key, "Varied Parameter ($key)" => key)
        actual_y_key = y_key #replace(y_key, "Varied Parameter ($key)" => key)
        println(x_key,y_key)
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

"""
    showConvergencePlot(sim_config::SimulationConfig,
                        key::String,
                        param_values::Union{AbstractVector, AbstractRange},
                        y_stat_key::String;
                        run_simulations::Bool = true,
                        force_int_param::Bool = false)

Plots a specific simulation statistic against a varied parameter.

Runs simulations varying `key` over `param_values` for active methods.
Plots `param_values` (X-axis) vs. the statistic `y_stat_key` (Y-axis).
A time slider is shown only if `y_stat_key` is found to be time-dependent.

# Arguments
- `sim_config`: Base SimulationConfig defining methods, base params, sim function.
- `key`: String name of the parameter to vary (plots on X-axis).
- `param_values`: Vector or Range of values for `key`.
- `y_stat_key`: String name of the statistic to plot on the Y-axis.
- `run_simulations`: If true (default), runs simulations. Assumes `loadSimData` otherwise.
- `force_int_param`: If true, attempts `trunc(Int, value)` for the varied parameter `key`.
"""
function showConvergencePlot(
    sim_config::SimulationConfig,
    key::String,
    param_values::Union{AbstractVector, AbstractRange},
    y_stat_key::String;
    force_int_param::Bool = false
    )

    # --- Basic Setup & UI ---
    local_ui_dict = deepcopy(ui_dict)
    plot_fig = Figure(size = local_ui_dict["figsize"])
    ax = Axis(plot_fig[1,1], title="Convergence: $y_stat_key vs $key", xlabel=key, ylabel=y_stat_key)
    
    # --- CONSTANT X-Axis Data ---
    actual_param_values_used = try
        vals = force_int_param ? map(v -> trunc(Int, v), param_values) : collect(param_values)
        Float64.(vals) # Ensure Float64 for plotting
    catch e
        @error "Could not process param_values for $key." exception=(e, catch_backtrace())
        return plot_fig, Figure() # Return empty figures on error
    end
    if isempty(actual_param_values_used); @warn "Empty parameter values provided."; return plot_fig, Figure(); end
    num_params = length(actual_param_values_used)

    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    # --- NEW: Notification Observable ---
    parameter_update_notifier = Observable(0)

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    default_method = sim_config.default_method in all_method_names ? sim_config.default_method : (isempty(all_method_names) ? "" : all_method_names[1])
    methods_obs = Observable(isempty(all_method_names) ? String[] : [default_method])
    method_number = lift(length, methods_obs)

    # --- Call the NEW createControls function ---
    control_fig = createControls(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        parameter_update_notifier
    )
    # -----------------------------------------

# --- Log Scale Toggles ---

    # Add Checkboxes to control figure (adjust row/column layout as needed)
    # Example: Placing them side-by-side in a new row, spanning 2 columns each
    log_scale_layout = control_fig[end+1, :] = GridLayout() # Span 4 columns for example
    cb_log_x = Toggle(log_scale_layout[1, 1], active = false) # Span cols 1-2
    Label(log_scale_layout[1,2], "Log-scale x-axis")
    cb_log_y = Toggle(log_scale_layout[1, 3], active = false) # Span cols 3-4
    Label(log_scale_layout[1,4], "Log-scale y-axis")

    # --- Link Log Scale Toggles to Axis Scale ---
    on(cb_log_x.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        # --- CORRECT WAY: Update value inside the observable ---
        xlims!(ax, (.1,1))
        ax.xscale[] = new_scale_func
        # ------------------------------------------------------
        println("X-Axis scale set to: ", ax.xscale[]) # Debug print shows the function name
    end

    on(cb_log_y.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        # --- CORRECT WAY: Update value inside the observable ---
        ylims!(ax, (.1,1))
        ax.yscale[] = new_scale_func
        # ------------------------------------------------------
        println("Y-Axis scale set to: ", ax.yscale[])
    end
    # ------------------------------------------
    lift(cb_log_x.active) do is_active
            # --- Calculate and Set X-Limits ONCE ---
        min_x_data, max_x_data = extrema(actual_param_values_used)
        # Get padding factor from ui_dict, default to 0.1 (10%) if not found
        pad_x_factor = to_value(is_active) ? 0 : get(local_ui_dict, "x_axis_limit_padding", 0.1)
        x_range = max_x_data - min_x_data
        x_pad = x_range ≈ 0 ? 0.1 : (x_range * pad_x_factor / 2.0) # Handle zero range
        final_xlims = (min_x_data - x_pad, max_x_data + x_pad)
        try; xlims!(ax, final_xlims); catch e; @warn "Failed to set initial xlims" exception=(e, catch_backtrace()); end
    end
    # --- Time Slider (Always Visible, label changes) ---
    is_y_stat_time_dependent = Observable(true) # Updated in Lift 1
    tLabel_text = Observable("t = ...")
    Label(control_fig[end+1, 1:2], tLabel_text, tellwidth=false).padding = (0, 0, 5, 0)
    tSlider = Slider(control_fig[end+1, 1:2], range = 0.0:1.0, startvalue = 0.0)

    # --- SIMPLIFIED Data Storage ---
    # Structure: [method_idx][param_idx] -> Tuple( raw_Y_stat :: Any, times :: Vector{Float64} )
    raw_data_store = Observable(Vector{Vector{Tuple{Any, Vector{Float64}}}}(undef, 0))
    # Structure: [method_idx] -> Observable{Vector{Float64}} (holds current Y snapshot)
    y_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

    # --- Lift 1: Data Loading / Simulation & Initial Snapshot ---
    lift(method_number, parameter_update_notifier; ignore_equal_values=true) do active_num, _...
        if active_num == 0
            raw_data_store[] = []; y_plot_data_methods[] = []
            is_y_stat_time_dependent[] = true; tSlider.range = 0.0:1.0; set_close_to!(tSlider, 0.0); tLabel_text[] = "t = N/A"
            return
        end
        println("Lift 1: Running/Loading simulations...")

        temp_raw_data = Vector{Vector{Tuple{Any, Vector{Float64}}}}(undef, active_num)
        all_times_union = Set{Float64}()

        # --- Simulation Loop ---
        for i = 1:active_num
            method = methods_obs[][i]
            raw_data_for_method = Vector{Tuple{Any, Vector{Float64}}}(undef, num_params)
            base_params = assemble_params_for_run(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )

            # === Optional: Threads.@threads for j = 1:num_params ===
            for j = 1:num_params
                current_value = actual_param_values_used[j]
                current_params = copy(base_params); 
                current_params[key] = current_value;

                stat_val_for_run = missing; time_vec_for_run = Float64[]
                try
                    # --- Run or Load ---
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                    if !Utils.doesSimDataExist(current_params)
                        println(" Running simulation for method: $method")
                        sim_data = sim_config.sim_function(current_params)
                        Utils.saveSimData(sim_data) # Assumes saveSimData exists
                    else
                        println(" Loading data for method: $method")
                        sim_data = Utils.loadSimData(current_params)
                    end
                    # --- Extract ONLY Needed Data ---
                    if !isnothing(sim_data) && hasproperty(sim_data, :stats) && hasproperty(sim_data, :t) && isa(sim_data.stats, AbstractDict)
                        stat_val_for_run = get(sim_data.stats, y_stat_key, missing)# Use get for safety
                        if isa(sim_data.t, AbstractVector); time_vec_for_run = sim_data.t; union!(all_times_union, time_vec_for_run); end
                    end
                catch e; @error "Sim/Load Error" exception=(e, catch_backtrace()); end
                raw_data_for_method[j] = (stat_val_for_run, time_vec_for_run)
            end # End j loop
            temp_raw_data[i] = raw_data_for_method
        end # End i loop
        # --- End Simulation Loop ---

        println("Finished runs. Updating observables...")
        raw_data_store[] = temp_raw_data # Store the collected raw data

         # --- Check Time Dependence of y_stat_key (REVISED LOGIC + DEBUG PRINTS) ---
         println("--- Checking time dependence for key: '$y_stat_key' ---")
         found_vector = false        # Ever found a valid Vector?
         found_scalar = false        # Ever found a valid Number?
         found_any_valid = false     # Found the key with a valid type at least once?
         processed_runs_with_key = 0 # Count runs where key was present
 
         # Iterate through the collected raw data (List per method -> List per param -> Tuple(raw_val, times))
         for (i_meth, method_data_list) in enumerate(temp_raw_data) # Use temp_raw_data from this lift block
             for (j_param, (raw_val, _)) in enumerate(method_data_list) # Unpack the tuple
 
                  # Check if the key was actually present and extracted (value is not missing)
                  if !ismissing(raw_val)
                     processed_runs_with_key += 1
                     found_any_valid = true # Mark that we found the key at least once
                     val_type = typeof(raw_val)
                     #print("  Run (Meth $i_meth, Param $j_param): Found '$y_stat_key', Type: $val_type")
 
                     # Check for recognized types and update flags
                     # Ensure vectors are non-empty and contain numbers
                     if isa(raw_val, AbstractVector) && !isempty(raw_val) && all(isa.(raw_val, Number))
                         found_vector = true; #print(" -> Vector\n")
                     elseif isa(raw_val, Number)
                         found_scalar = true; #print(" -> Scalar\n")
                     else
                         # Key exists but value is not a Number or a valid Vector (e.g., empty Vector, Nothing, String)
                         #print(" -> Other/Empty/Invalid Type\n")
                     end
 
                     # Optimization: If we've already found both types, we know it's inconsistent
                     if found_vector && found_scalar
                         println("      Inconsistency (Vector & Scalar) detected.")
                         # Optional: break loops early if needed, but completing allows full type survey
                         # break # breaks inner loop
                     end
                  # else: raw_val is missing (key wasn't in original stats dict)
                  #   println(" Key '$y_stat_key' was missing in this run.") # Optional debug
                  end
             end # End inner loop (param values)
             # if found_vector && found_scalar; break; end # Optional: break outer loop
         end # End outer loop (methods)
         println("--- Finished check. Processed $processed_runs_with_key runs containing the key '$y_stat_key' ---")
         println("    Final flags: found_any_valid=$found_any_valid, found_vector=$found_vector, found_scalar=$found_scalar")
 
         # Determine final is_td based *only* on whether both types were found, or only one.
         local is_td
         if !found_any_valid
              @error "Stat key '$y_stat_key' not found or has no valid data (Number/Vector)! Assuming non-time-dependent."
              is_td = false # Or handle as error? Defaulting to false.
         elseif found_vector && found_scalar # Inconsistent types found across runs
              @warn "Stat key '$y_stat_key' has inconsistent types (scalar/vector)! Treating as time-dependent."
              is_td = true
         elseif found_vector # Only vectors found
              is_td = true
         elseif found_scalar # Only scalars found
              is_td = false
         else
              # This case should ideally not be reached if found_any_valid is true.
              # It might mean the value was present but wasn't Number or valid Vector.
              @warn "Stat key '$y_stat_key' found, but not as Number or valid Vector. Assuming non-time-dependent."
              is_td = false
         end
         is_y_stat_time_dependent[] = is_td # Update the observable
         println("Statistic is time dependent: $is_td")
         # --- End Time Dependence Check ---
 
         # --- Update Time Slider Range AND Label Text ---
         # (This part uses the is_td determined above - remains the same)
         time_vec = isempty(all_times_union) ? [0.0] : sort(collect(all_times_union))
         t_range = range(extrema(time_vec)..., length=max(2, length(time_vec)*2+80))
         if tSlider.range[] != t_range; tSlider.range = t_range; end
         set_close_to!(tSlider, clamp(tSlider.value[], extrema(t_range)...))
         if is_td; tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"; else; tLabel_text[] = "t = N/A (Scalar Stat)"; end

        # --- Calculate Initial Y Plot Data Snapshot ---
        current_y_plot_data = [Observable(fill(NaN, num_params)) for _ in 1:active_num] # Initialize with NaN
        current_t = tSlider.value[]

        for i = 1:active_num
            y_vals = fill(NaN, num_params) # Use NaN as default
            raw_method_data = raw_data_store[][i] # Access stored raw data

            for j = 1:num_params
                 raw_stat_val, times = raw_method_data[j]
                 if !ismissing(raw_stat_val)
                     if is_td
                         if isa(raw_stat_val, AbstractVector) && !isempty(times) && !isempty(raw_stat_val)
                             (_, m_ij) = findmin(a -> abs(a - current_t), times)
                             if m_ij <= length(raw_stat_val); y_vals[j] = Float64(raw_stat_val[m_ij]); end
                         elseif isa(raw_stat_val, Number); y_vals[j] = Float64(raw_stat_val); end # Inconsistent case
                     elseif isa(raw_stat_val, Number); y_vals[j] = Float64(raw_stat_val); end
                 end
            end
            current_y_plot_data[i][] = y_vals
        end
        y_plot_data_methods[] = current_y_plot_data # Update the observable for plotting
        # --- End Snapshot Calculation ---
    end # --- End Lift 1 ---


    # --- Lift 2: Snapshot Update (Simpler) ---
    lift(tSlider.value; ignore_equal_values=true) do t
        if !is_y_stat_time_dependent[]; return; end # Only run if time-dependent

        tLabel_text[] = "t = $(round(t, digits=3))"
        active_num = method_number[]
        # Consistency check for safety
        if length(y_plot_data_methods[]) != active_num || length(raw_data_store[]) != active_num || active_num == 0; return; end

        # Recalculate Y snapshot data based on new time t
        for i = 1:active_num
            y_vals = fill(NaN, num_params)
            raw_method_data = raw_data_store[][i] # Get stored raw data

            for j = 1:num_params
                 raw_stat_val, times = raw_method_data[j]
                 if !ismissing(raw_stat_val)
                     # is_td must be true here
                     if isa(raw_stat_val, AbstractVector) && !isempty(times) && !isempty(raw_stat_val)
                         (_, m_ij) = findmin(a -> abs(a - t), times)
                         if m_ij <= length(raw_stat_val); y_vals[j] = Float64(raw_stat_val[m_ij]); end
                     elseif isa(raw_stat_val, Number); y_vals[j] = Float64(raw_stat_val); end # Inconsistent case
                 end
            end
             # Update the inner observable for this method's Y plot data
             if i <= length(y_plot_data_methods[]); y_plot_data_methods[][i][] = y_vals; end
        end
    end # --- End Lift 2 ---


    # --- Lift 3: Plot Management (Uses constant X-data) ---
    lift(method_number; ignore_equal_values=true) do active_num
        # Handles adding/removing plot objects when active methods change
        empty!(ax)
        for c in contents(plot_fig.layout); if isa(c, Legend); delete!(c); end; end # Clear potential legend
        if active_num == 0; return; end
        active_methods = methods_obs[]

        # Consistency check
        num_data_series_y = length(y_plot_data_methods[])
        if num_data_series_y != active_num
             num_to_plot = min(active_num, num_data_series_y); if num_to_plot <= 0; return; end
             @warn "Lift 3: Data series mismatch. Plotting $num_to_plot series."
        else; num_to_plot = active_num; end

        plotted_objects = []
        for i = 1:num_to_plot
            plotLabel = active_methods[i]
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            y_data_obs = y_plot_data_methods[][i] # Get the observable for Y snapshot

            # === Plot using the CONSTANT actual_param_values_used for X ===
            obj_for_legend = nothing
            # Note: Check local_ui_dict exists and has these keys
            show_lines = get(local_ui_dict, "show_lines", true)
            show_scatter = get(local_ui_dict, "show_scatter", true)

            if show_lines
                 l = lines!(ax, actual_param_values_used, y_data_obs;
                       color=color, linewidth=get(local_ui_dict,"linewidth", 1.5), label=plotLabel)
                 obj_for_legend = l
            end
            if show_scatter
                 s = scatter!(ax, actual_param_values_used, y_data_obs;
                         color=color, markersize=get(local_ui_dict,"markersize", 8), marker=marker, label=plotLabel)
                 if obj_for_legend === nothing; obj_for_legend = s; end
            end
            if obj_for_legend !== nothing; push!(plotted_objects, obj_for_legend); end
            # ======================================================
        end

        # Add Legend
        if !isempty(plotted_objects)
             try # Add legend in column 2
                 for c in contents(plot_fig.layout); if isa(c, Legend); end; end
                 Legend(plot_fig[1, 2], plotted_objects, active_methods[1:num_to_plot], "Methods", tellheight=false)
                 colsize!(plot_fig.layout, 2, Auto())
             catch e; @error "Error adding Legend" exception=(e, catch_backtrace()); end
        end
        #autolimits!(ax) # Update limits
    end # --- End Lift 3 ---

        # --- NEW Lift Block 4: Dynamic Y-Limits ---
    # Triggered whenever the Y plot data snapshot changes
    lift(y_plot_data_methods, cb_log_y.active, tSlider.value; ignore_equal_values=true) do current_y_data_observables, y_active, _ # Vector{Observable{Vector{Float64}}}
        ymin_overall = Inf
        ymax_overall = -Inf
        found_valid_y = false

        for y_obs in current_y_data_observables # Iterate through observables
            y_vec = y_obs[] # Get current vector value
            valid_y = filter(isfinite, y_vec) # Filter NaN/Inf
            if !isempty(valid_y)
                ymin_local, ymax_local = extrema(valid_y)
                ymin_overall = min(ymin_overall, ymin_local)
                ymax_overall = max(ymax_overall, ymax_local)
                found_valid_y = true
            end
        end

        # Apply padding and set limits
        if found_valid_y
            print(y_active, "HELLO")
            pad_y_factor = to_value(y_active) ? 0 : get(local_ui_dict, "y_axis_limit_padding", 0.1) # Default 10%
            y_range = ymax_overall - ymin_overall
            y_pad = y_range ≈ 0 ? 0.1 : (y_range * pad_y_factor / 2.0)
            final_ylims = (ymin_overall - y_pad, ymax_overall + y_pad)
        else
            final_ylims = (0.0, 1.0) # Default if no valid Y data
        end

        # Set the Y limits (use try-catch for robustness)
        try
            current_limits = ax.finallimits[]
            # Only update if limits actually changed significantly
            if abs(current_limits.origin[2] - final_ylims[1]) > 1e-9 || abs(current_limits.widths[2] - (final_ylims[2] - final_ylims[1])) > 1e-9
                 ylims!(ax, final_ylims)
            end
        catch e
            @warn "Failed to set dynamic ylims" exception=(e, catch_backtrace())
        end
        return nothing # Lift blocks don't need to return
    end # --- End Lift Block 4 ---

    # --- Display ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return plot_fig, control_fig
end

"""
    showConvergencePlot(sim_config::SimulationConfig,
                        key::String,
                        param_values::Union{AbstractVector, AbstractRange},
                        x_stat_key::String,
                        y_stat_key::String;
                        run_simulations::Bool = true,
                        force_int_param::Bool = false)

Plots one simulation statistic against another, across variations of a parameter `key`.

Runs simulations varying `key` over `param_values` for active methods.
Plots statistic `x_stat_key` (X-axis) vs. statistic `y_stat_key` (Y-axis).
A time slider is shown and used if *either* statistic is time-dependent.
Axis limits are dynamic based on the current data snapshot.

# Arguments
- `sim_config`: Base SimulationConfig defining methods, base params, sim function.
- `key`: String name of the parameter to vary.
- `param_values`: Vector or Range of values for `key`.
- `x_stat_key`: String name of the statistic for the X-axis.
- `y_stat_key`: String name of the statistic for the Y-axis.
- `run_simulations`: If true (default), runs simulations. Assumes `loadSimData` otherwise.
- `force_int_param`: If true, attempts `trunc(Int, value)` for the varied parameter `key`.
"""
function showConvergencePlot(
    sim_config::SimulationConfig,
    key::String,
    param_values::Union{AbstractVector, AbstractRange},
    x_stat_key::String,
    y_stat_key::String;
    force_int_param::Bool = false
    )

    # --- Basic Setup & UI ---
    local_ui_dict = deepcopy(ui_dict) # Load default UI settings
    # updateUI(...)
    plot_fig = Figure(size = local_ui_dict["figsize"])
    # Use stat keys for initial labels
    ax = Axis(plot_fig[1,1], title="Convergence: $y_stat_key vs $x_stat_key (varying $key)", xlabel=x_stat_key, ylabel=y_stat_key)

    # --- Process Varied Parameter Values ---
    # Calculate the actual parameter values used for the varied key ONCE.
    # These are NOT directly plotted unless key == x_stat_key or key == y_stat_key
    actual_param_values_used = try
        vals = force_int_param ? map(v -> trunc(Int, v), param_values) : collect(param_values)
        # Keep original type if possible, needed if key itself is plotted
        # Float64.(vals) # Convert only if necessary later? Keep as Any[] for now.
         collect(vals) # Ensure it's a vector
    catch e
        @error "Could not process param_values for $key." exception=(e, catch_backtrace())
        return plot_fig, Figure() # Return empty figures on error
    end
    if isempty(actual_param_values_used); @warn "Empty parameter values provided."; return plot_fig, Figure(); end
    num_params = length(actual_param_values_used)

    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    # --- NEW: Notification Observable ---
    parameter_update_notifier = Observable(0)

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    default_method = sim_config.default_method in all_method_names ? sim_config.default_method : (isempty(all_method_names) ? "" : all_method_names[1])
    methods_obs = Observable(isempty(all_method_names) ? String[] : [default_method])
    method_number = lift(length, methods_obs)

    # --- Call the NEW createControls function ---
    control_fig = createControls(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        parameter_update_notifier
    )
    # -----------------------------------------

# --- Log Scale Toggles ---

    # Add Checkboxes to control figure (adjust row/column layout as needed)
    # Example: Placing them side-by-side in a new row, spanning 2 columns each
    log_scale_layout = control_fig[end+1, :] = GridLayout() # Span 4 columns for example
    cb_log_x = Toggle(log_scale_layout[1, 1], active = false) # Span cols 1-2
    Label(log_scale_layout[1,2], "Log-scale x-axis")
    cb_log_y = Toggle(log_scale_layout[1, 3], active = false) # Span cols 3-4
    Label(log_scale_layout[1,4], "Log-scale y-axis")

    # --- Link Log Scale Toggles to Axis Scale ---
    on(cb_log_x.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        xlims!(ax, (.1, 1))
        # --- CORRECT WAY: Update value inside the observable ---
        ax.xscale[] = new_scale_func
        # ------------------------------------------------------
        println("X-Axis scale set to: ", ax.xscale[]) # Debug print shows the function name
    end

    on(cb_log_y.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        ylims!(ax, (.1, 1))
        # --- CORRECT WAY: Update value inside the observable ---
        ax.yscale[] = new_scale_func
        # ------------------------------------------------------
        println("Y-Axis scale set to: ", ax.yscale[])
    end
    # ------------------------------------------

    # --- Time Slider (Always Visible, label changes based on dependence) ---
    is_any_stat_time_dependent = Observable(true) # If either X or Y is time-dependent
    is_x_stat_time_dependent = Observable(true)   # Individual flag for X
    is_y_stat_time_dependent = Observable(true)   # Individual flag for Y
    tLabel_text = Observable("t = ...")
    Label(control_fig[end+1, 1:2], tLabel_text, tellwidth=false).padding = (0, 0, 5, 0) # Span columns as needed
    tSlider = Slider(control_fig[end+1, 1:2], range = 0.0:1.0, startvalue = 0.0) # Span columns as needed

    # --- SIMPLIFIED Data Storage ---
    # Structure: [method_idx][param_idx] -> Tuple(raw_X_stat::Any, raw_Y_stat::Any, times::Vector{Float64})
    raw_data_store = Observable(Vector{Vector{Tuple{Any, Any, Vector{Float64}}}}(undef, 0))

    # Structure: [method_idx] -> Observable{Vector{Float64}} (holds current snapshot)
    x_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    y_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

    # --- Helper Function for Time Dependence Check (Revised from previous answer) ---
    function check_stat_time_dependence(stat_key_to_check::String, raw_data::Vector{Vector{Tuple{Any, Any, Vector{Float64}}}}, key_index::Int)
        # key_index: 1 for X stat, 2 for Y stat
        found_vector = false; found_scalar = false; found_any_valid = false
        for method_data_list in raw_data
            for run_data in method_data_list
                raw_val = run_data[key_index]
                if !ismissing(raw_val)
                    found_any_valid = true
                    if isa(raw_val, AbstractVector) && !isempty(raw_val) && all(isa.(raw_val, Number)); found_vector = true;
                    elseif isa(raw_val, Number); found_scalar = true; end
                    if found_vector && found_scalar; break; end # Inconsistent found
                end
            end
            if found_vector && found_scalar; break; end
        end

        local is_td
        if !found_any_valid; is_td = false; # Treat as scalar if not found or invalid
        elseif found_vector && found_scalar; is_td = true; # Inconsistent -> time-dependent
        elseif found_vector; is_td = true; # Only vectors -> time-dependent
        elseif found_scalar; is_td = false; end # Only scalars -> not time-dependent
        println("Time dependence check for '$stat_key_to_check': is_td = $is_td (V=$found_vector, S=$found_scalar)")
        return is_td
    end
    # --- End Helper Function ---

    # --- Lift 1: Data Loading / Simulation & Initial Snapshot ---
    lift(method_number, parameter_update_notifier; ignore_equal_values=true) do active_num, _...
        if active_num == 0 # Handle no active methods
            raw_data_store[] = []; x_plot_data_methods[] = []; y_plot_data_methods[] = []
            is_x_stat_time_dependent[] = true; is_y_stat_time_dependent[] = true; is_any_stat_time_dependent[] = true;
            tSlider.range = 0.0:1.0; set_close_to!(tSlider, 0.0); tLabel_text[] = "t = N/A"
            return
        end

        println("Lift 1: Running/Loading simulations...")
        # Initialize temporary storage
        temp_raw_data = Vector{Vector{Tuple{Any, Any, Vector{Float64}}}}(undef, active_num)
        all_times_union = Set{Float64}()

        # --- Simulation Loop ---
        for i = 1:active_num
            method = methods_obs[][i]
            raw_data_for_method = Vector{Tuple{Any, Any, Vector{Float64}}}(undef, num_params)
            base_params = assemble_params_for_run(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )

            # === Optional: Threads.@threads for j = 1:num_params ===
            for j = 1:num_params
                current_value = actual_param_values_used[j]
                current_params = copy(base_params); 
                current_params[key] = current_value;

                stat_x_for_run = missing; stat_y_for_run = missing; time_vec_for_run = Float64[]
                try
                    # --- Run or Load ---
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                    if !Utils.doesSimDataExist(current_params)
                        println(" Running simulation for method: $method")
                        sim_data = sim_config.sim_function(current_params)
                        Utils.saveSimData(sim_data) # Assumes saveSimData exists
                    else
                        println(" Loading data for method: $method")
                        sim_data = Utils.loadSimData(current_params)
                    end
                    # Extract X, Y stats and times
                    if !isnothing(sim_data) && hasproperty(sim_data, :stats) && hasproperty(sim_data, :t) && isa(sim_data.stats, AbstractDict)
                        # Use get for safety, default to missing
                        stat_x_for_run = get(sim_data.stats, x_stat_key, missing)
                        # Special case: if x_stat_key is the varied key itself
                        if x_stat_key == key; stat_x_for_run = current_value; end

                        stat_y_for_run = get(sim_data.stats, y_stat_key, missing)
                        # Special case: if y_stat_key is the varied key itself
                        if y_stat_key == key; stat_y_for_run = current_value; end

                        if isa(sim_data.t, AbstractVector); time_vec_for_run = sim_data.t; union!(all_times_union, time_vec_for_run); end
                    end
                catch e; @error "Sim/Load Error" exception=(e, catch_backtrace()); end
                raw_data_for_method[j] = (stat_x_for_run, stat_y_for_run, time_vec_for_run)
            end # End j loop
            temp_raw_data[i] = raw_data_for_method
        end # End i loop
        # --- End Simulation Loop ---

        println("Finished runs. Updating observables and UI...")
        raw_data_store[] = temp_raw_data # Update main raw data store

        # --- Check Time Dependence for BOTH Keys ---
        is_x_td = check_stat_time_dependence(x_stat_key, temp_raw_data, 1)
        is_y_td = check_stat_time_dependence(y_stat_key, temp_raw_data, 2)
        # Handle cases where key is the varied parameter (always scalar)
        if x_stat_key == key; is_x_td = false; end
        if y_stat_key == key; is_y_td = false; end
        # Update observables
        is_x_stat_time_dependent[] = is_x_td
        is_y_stat_time_dependent[] = is_y_td
        is_any_td = is_x_td || is_y_td
        is_any_stat_time_dependent[] = is_any_td
        # --- End Time Dependence Check ---

        # --- Update Time Slider Range AND Label Text ---
        time_vec = isempty(all_times_union) ? [0.0] : sort(collect(all_times_union))
        t_range = range(extrema(time_vec)..., length=max(2, length(time_vec)*2+80))
        if tSlider.range[] != t_range; tSlider.range = t_range; end
        set_close_to!(tSlider, clamp(tSlider.value[], extrema(t_range)...))
        if is_any_td; tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"; else; tLabel_text[] = "t = N/A (Both Scalar)"; end

        # --- Calculate Initial Plot Data Snapshot ---
        current_x_plot_data = [Observable(fill(NaN, num_params)) for _ in 1:active_num]
        current_y_plot_data = [Observable(fill(NaN, num_params)) for _ in 1:active_num]
        current_t = tSlider.value[]
        current_raw_data = raw_data_store[] # Use the data just stored

        for i = 1:active_num
            x_vals = fill(NaN, num_params); y_vals = fill(NaN, num_params)
            if i > length(current_raw_data) continue end
            raw_method_data = current_raw_data[i]

            for j = 1:num_params
                 if j > length(raw_method_data) continue end
                 raw_x_val, raw_y_val, times = raw_method_data[j]

                 # Calculate X value snapshot
                 if !ismissing(raw_x_val)
                     if is_x_td # Apply time logic only if X is time-dependent
                         if isa(raw_x_val, AbstractVector) && !isempty(times) && !isempty(raw_x_val)
                             (_, m_ij) = findmin(a -> abs(a - current_t), times)
                             if m_ij <= length(raw_x_val); x_vals[j] = Float64(raw_x_val[m_ij]); end
                         elseif isa(raw_x_val, Number); x_vals[j] = Float64(raw_x_val); end # Inconsistent case
                     elseif isa(raw_x_val, Number); x_vals[j] = Float64(raw_x_val); end # Scalar case
                 end
                 # Calculate Y value snapshot
                 if !ismissing(raw_y_val)
                     if is_y_td # Apply time logic only if Y is time-dependent
                         if isa(raw_y_val, AbstractVector) && !isempty(times) && !isempty(raw_y_val)
                             # Assume times are the same for X/Y stat within a run
                             (_, m_ij) = findmin(a -> abs(a - current_t), times)
                             if m_ij <= length(raw_y_val); y_vals[j] = Float64(raw_y_val[m_ij]); end
                         elseif isa(raw_y_val, Number); y_vals[j] = Float64(raw_y_val); end # Inconsistent case
                     elseif isa(raw_y_val, Number); y_vals[j] = Float64(raw_y_val); end # Scalar case
                 end
            end
            current_x_plot_data[i][] = x_vals
            current_y_plot_data[i][] = y_vals
        end
        x_plot_data_methods[] = current_x_plot_data
        y_plot_data_methods[] = current_y_plot_data
        # --- End Snapshot Calculation ---
    end # --- End Lift 1 ---


    # --- Lift 2: Snapshot Update (triggered by time slider) ---
    lift(tSlider.value; ignore_equal_values=true) do t
        # Only run if at least one stat is time-dependent
        if !is_any_stat_time_dependent[]; return; end

        tLabel_text[] = "t = $(round(t, digits=3))"
        active_num = method_number[]
        # Consistency checks
        if length(x_plot_data_methods[])!=active_num || length(y_plot_data_methods[])!=active_num || length(raw_data_store[])!=active_num || active_num==0; return; end

        # Recalculate X and Y snapshots based on new time t
        is_x_td = is_x_stat_time_dependent[] # Read current flags
        is_y_td = is_y_stat_time_dependent[]
        current_raw_data = raw_data_store[]

        for i = 1:active_num
            x_vals = fill(NaN, num_params); y_vals = fill(NaN, num_params)
            if i > length(current_raw_data) continue end
            raw_method_data = current_raw_data[i]

            for j = 1:num_params
                 if j > length(raw_method_data) continue end
                 raw_x_val, raw_y_val, times = raw_method_data[j]

                 # Calculate X value snapshot (only if time-dependent)
                 if is_x_td && !ismissing(raw_x_val)
                     if isa(raw_x_val, AbstractVector) && !isempty(times) && !isempty(raw_x_val)
                         (_, m_ij) = findmin(a -> abs(a - t), times)
                         if m_ij <= length(raw_x_val); x_vals[j] = Float64(raw_x_val[m_ij]); end
                     elseif isa(raw_x_val, Number); x_vals[j] = Float64(raw_x_val); end # Inconsistent case
                 elseif !is_x_td && !ismissing(raw_x_val) && isa(raw_x_val, Number) # If scalar, keep original value
                     x_vals[j] = Float64(raw_x_val)
                 else # Keep NaN
                      x_vals[j] = x_plot_data_methods[][i][][j] # Use previous value if possible? Or just keep NaN
                 end

                 # Calculate Y value snapshot (only if time-dependent)
                  if is_y_td && !ismissing(raw_y_val)
                     if isa(raw_y_val, AbstractVector) && !isempty(times) && !isempty(raw_y_val)
                         (_, m_ij) = findmin(a -> abs(a - t), times)
                         if m_ij <= length(raw_y_val); y_vals[j] = Float64(raw_y_val[m_ij]); end
                     elseif isa(raw_y_val, Number); y_vals[j] = Float64(raw_y_val); end # Inconsistent case
                 elseif !is_y_td && !ismissing(raw_y_val) && isa(raw_y_val, Number) # If scalar, keep original value
                     y_vals[j] = Float64(raw_y_val)
                 else # Keep NaN
                      y_vals[j] = y_plot_data_methods[][i][][j] # Use previous value if possible? Or just keep NaN
                 end
            end
            # Update inner observables only if value changed? Makie might handle this.
            if i <= length(x_plot_data_methods[]); x_plot_data_methods[][i][] = x_vals; end
            if i <= length(y_plot_data_methods[]); y_plot_data_methods[][i][] = y_vals; end
        end
    end # --- End Lift 2 ---


    # --- Lift 3: Plot Management (Plots X vs Y) ---
    lift(method_number; ignore_equal_values=true) do active_num
        # (Same as previous version - redraws plots using x_plot_data_methods and y_plot_data_methods)
        empty!(ax)
        for c in contents(plot_fig.layout); if isa(c, Legend); delete!(c); end; end
        if active_num == 0; return; end
        active_methods = methods_obs[]

        num_data_series_x = length(x_plot_data_methods[]); num_data_series_y = length(y_plot_data_methods[])
        if num_data_series_x != active_num || num_data_series_y != active_num
             num_to_plot = min(active_num, num_data_series_x, num_data_series_y); if num_to_plot <= 0; return; end
             @warn "Lift 3: Data series mismatch. Plotting $num_to_plot series."
        else; num_to_plot = active_num; end

        plotted_objects = []
        for i = 1:num_to_plot
            plotLabel = active_methods[i]
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            x_data_obs = x_plot_data_methods[][i] # Observable for X snapshot
            y_data_obs = y_plot_data_methods[][i] # Observable for Y snapshot

            obj_for_legend = nothing
            if get(local_ui_dict, "show_lines", true)
                 l = lines!(ax, x_data_obs, y_data_obs; color=color, linewidth=get(local_ui_dict,"linewidth", 1.5), label=plotLabel)
                 obj_for_legend = l
            end
            if get(local_ui_dict, "show_scatter", true)
                 s = scatter!(ax, x_data_obs, y_data_obs; color=color, markersize=get(local_ui_dict,"markersize", 8), marker=marker, label=plotLabel)
                 if obj_for_legend === nothing; obj_for_legend = s; end
            end
            if obj_for_legend !== nothing; push!(plotted_objects, obj_for_legend); end
        end

        # Add Legend
        if !isempty(plotted_objects)
             try; Legend(plot_fig[1, 2], plotted_objects, active_methods[1:num_to_plot], "Methods", tellheight=false); colsize!(plot_fig.layout, 2, Auto());
             catch e; @error "Error adding Legend" exception=(e, catch_backtrace()); end
        end
        # Limits are handled by Lift 4
    end # --- End Lift 3 ---


    # --- Lift Block 4: Dynamic X/Y Limits ---
    # Triggered by time slider OR changes in the underlying plot data observables
    lift(tSlider.value, x_plot_data_methods, y_plot_data_methods, cb_log_x.active, cb_log_y.active; ignore_equal_values=true) do t, current_x_data_obs, current_y_data_obs, x_active, y_active
        # Calculate X limits
        xmin_overall = Inf; xmax_overall = -Inf; found_valid_x = false
        for x_obs in current_x_data_obs
            valid_x = filter(isfinite, x_obs[]);
            if !isempty(valid_x); xmin_local, xmax_local = extrema(valid_x); xmin_overall = min(xmin_overall, xmin_local); xmax_overall = max(xmax_overall, xmax_local); found_valid_x = true; end
        end
        # Calculate Y limits
        ymin_overall = Inf; ymax_overall = -Inf; found_valid_y = false
        for y_obs in current_y_data_obs
            valid_y = filter(isfinite, y_obs[]);
            if !isempty(valid_y); ymin_local, ymax_local = extrema(valid_y); ymin_overall = min(ymin_overall, ymin_local); ymax_overall = max(ymax_overall, ymax_local); found_valid_y = true; end
        end

        # Apply padding and set limits
        pad_x_factor = to_value(x_active) ? 0 : get(local_ui_dict, "x_axis_limit_padding", 0.1)
        pad_y_factor = to_value(y_active) ? 0 : get(local_ui_dict, "y_axis_limit_padding", 0.1)

        final_xlims = if found_valid_x
            x_range = xmax_overall - xmin_overall; x_pad = x_range ≈ 0 ? 0.1 : (x_range * pad_x_factor / 2.0); (xmin_overall - x_pad, xmax_overall + x_pad)
        else (0.0, 1.0) end # Default X limits

        final_ylims = if found_valid_y
            y_range = ymax_overall - ymin_overall; y_pad = y_range ≈ 0 ? 0.1 : (y_range * pad_y_factor / 2.0); (ymin_overall - y_pad, ymax_overall + y_pad)
        else (0.0, 1.0) end # Default Y limits
        try # Set limits only if they differ significantly to avoid jitter
            current_lims = ax.finallimits[]
            xlims_changed = abs(current_lims.origin[1] - final_xlims[1]) > 1e-9 || abs(current_lims.widths[1] - (final_xlims[2] - final_xlims[1])) > 1e-9
            ylims_changed = abs(current_lims.origin[2] - final_ylims[1]) > 1e-9 || abs(current_lims.widths[2] - (final_ylims[2] - final_ylims[1])) > 1e-9
            # Use non-blocking update variants if available and needed, otherwise standard functions
            if xlims_changed; xlims!(ax, final_xlims); end
            if ylims_changed; ylims!(ax, final_ylims); end
        catch e; @warn "Failed to set dynamic limits" exception=(e, catch_backtrace()); end

        return nothing
    end # --- End Lift Block 4 ---


    # --- Display ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return plot_fig, control_fig
end # --- End Function ---

end