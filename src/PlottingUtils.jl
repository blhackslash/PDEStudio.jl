using CairoMakie

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


# Assuming ParamDictType is defined elsewhere, e.g.:
# const ParamDictType = Dict{String, Any}

function isAtomic(val)
    return isa(val, Real) || isa(val, String) || isa(val, Bool) || isa(val,Symbol)
end

"""
Determines if a value should be treated as a "simple interactive type" 
for creating a Makie widget.
This includes:
- Real, String, Bool
- 1D Tuples where ALL elements are Real, String, or Bool.
Excludes:
- Vectors, Dicts, other container types.
- Tuples containing other Tuples, Vectors, Dicts, etc.
- Custom structs (unless they are Real, String, or Bool themselves).
"""
function shouldCreateWidget(val)
    if isAtomic(val)
        return true  # It's a Real, String, or Bool
    elseif isa(val, Tuple)
        if isempty(val)
            # Decide how to treat empty tuple. For UI, usually non-interactive or special placeholder.
            # Let's consider it non-interactive for simplicity, as there's no value to edit.
            return false 
        end
        # Check if all elements of the tuple are simple atomic types
        for element in val
            if !isAtomic(element)
                # Found an element that is not Real, String, or Bool (e.g., another Tuple, a Vector)
                return false 
            end
        end
        return true # All elements are simple atomic types; it's a 1D tuple of simple types
    else
        # It's an AbstractVector, AbstractDict, custom struct, etc.
        return false 
    end
end

# --- Helper 1: For Shared Params (each param is its own nested 2-col grid) ---
function add_param_as_nested_grid!(parent_cell_for_item, key_name::String, param_obs::Observable, 
                                    is_toggle::Bool, is_fixed_const::Bool, label_fontsize::Int, p_internal_item_colgap::Int)
    
    item_layout = parent_cell_for_item[] = GridLayout(tellwidth=false) 
    colgap!(item_layout, p_internal_item_colgap) 

    val = param_obs[]
    is_regular_tuple = isa(val, Tuple)
    
    Label(item_layout[1,1], 
            (is_fixed_const ? "(fixed) " : "") * key_name * (is_toggle ? "" : " ="), 
            halign=:right, fontsize=label_fontsize, padding=(0, 2, 0, 0))

    if is_fixed_const
        Label(item_layout[1,2], string(val), halign=:left, fontsize=label_fontsize)
    elseif is_toggle
        current_bool_val = isa(val, Bool) ? val : false
        tgl = Toggle(item_layout[1,2], active = current_bool_val)
        on(tgl.active) do active_val
            if param_obs[] != active_val; param_obs[] = active_val; end
        end
    elseif is_regular_tuple
        validator_type = Tuple #typeof(val)  # More restrictive alternative
        validator = s -> isa(StringToTuple(s),validator_type)
        tb = Textbox(item_layout[1,2], placeholder = string(val), 
                    validator = validator, width = Auto(), reset_on_defocus=true)
        on(tb.stored_string) do s
            param_obs[] = StringToTuple(s)
        end
    else # Textbox
        validator_type = if isa(val, AbstractFloat) Float64
                            elseif isa(val, Integer) Int
                            elseif isa(val, String) s -> true # Function for String
                            else (s -> true) # Fallback
                            end
        tb = Textbox(item_layout[1,2], placeholder = string(val), 
                        validator = validator_type, width = Auto(), reset_on_defocus=true)
        on(tb.stored_string) do s
            target_type = typeof(val)
            try
                parsed_val = if target_type == String; s
                                elseif validator_type == Float64 || validator_type == Int; parse(target_type,s)
                                else s end # If generic validator, treat as string or handle based on target_type
                if !is_fixed_const && param_obs[] != parsed_val; param_obs[] = parsed_val; end
            catch e
                current_display_val = is_fixed_const ? param_obs[][2] : param_obs[]
                tb.stored_string = string(current_display_val) 
            end
        end
    end
    colsize!(item_layout, 1, Auto()) 
    colsize!(item_layout, 2, Auto()) 
end

# Add this to MakiePlotting.txt

# In MakiePlotting.txt

"""
Clears and populates a given Figure with a title and parameter controls.
Parameters are laid out in a specified number of columns.
"""
function populate_parameter_figure!(
    #target_fig::Figure,
    title_str::String,
    params_obs_dict::Dict{String, Observable}, # Should be Dict{String, Observable}
    num_param_columns::Int;
    param_label_fontsize=14,
    header_fontsize=16,
    gap_size=10,
    internal_item_colgap=4,
    fig_size = (500,500)
)
    #empty!(target_fig.scene) # Clear all previous content and layouts
    target_fig = Figure(size = fig_size)
    main_layout = target_fig[1,1] = GridLayout(tellheight=false)
    rowgap!(main_layout, gap_size)

    # Row 1: Title
    Label(main_layout[1,1], title_str, font=:bold, fontsize=header_fontsize, 
          tellwidth=false, halign=:center, padding=(0,0,10,0))
    rowsize!(main_layout, 1, Auto())

    # Row 2: Parameters or "No parameters" message
    if isempty(params_obs_dict)
        Label(main_layout[2,1], "(No parameters for this selection)", 
              fontsize=param_label_fontsize, halign=:center)
        rowsize!(main_layout, 2, Auto())
        Makie.trim!(main_layout)
        return
    end

    params_content_layout = main_layout[2,1] = GridLayout(tellheight=false)
    rowgap!(params_content_layout, gap_size)
    colgap!(params_content_layout, gap_size)

    sorted_keys = sort(collect(keys(params_obs_dict)))
    widget_keys = []
    
    current_row_in_block, current_col_in_block = 1, 1
    for key in sorted_keys
        val_check = params_obs_dict[key][]
        if !shouldCreateWidget(val_check) continue end
        is_fixed_const = isa(val_check, Tuple) && length(val_check) == 2 && val_check[1] == :const
        actual_val = is_fixed_const ? val_check[2] : val_check
        is_bool_toggle = isa(actual_val, Bool) && !is_fixed_const

        # Remove constant flag:
        if is_fixed_const
            params_obs_dict[key] = Observable(actual_val)
        end
        # Assuming add_param_as_nested_grid! is your working helper from before
        add_param_as_nested_grid!(
            params_content_layout[current_row_in_block, current_col_in_block], 
            key, 
            params_obs_dict[key], 
            is_bool_toggle, 
            is_fixed_const,
            param_label_fontsize, 
            internal_item_colgap
        )
        
        current_col_in_block += 1
        if current_col_in_block > num_param_columns
            current_col_in_block = 1
            current_row_in_block += 1
        end
        push!(widget_keys, key)
    end

    if !isempty(widget_keys)
        actual_num_cols_used = min(num_param_columns, length(widget_keys))
        for c_idx in 1:actual_num_cols_used
            colsize!(params_content_layout, c_idx, Auto())
        end

        # Calculate the number of rows that actually received content
        true_num_rows_used = ceil(Int, length(widget_keys) / num_param_columns)
        # If length(sorted_keys) is 0, true_num_rows_used will be 0.
        # If length(sorted_keys) > 0 but less than or equal to num_param_columns, it's 1.
        # If length(sorted_keys) is (num_param_columns + 1), it's 2.
        if true_num_rows_used == 0 && !isempty(widget_keys)
             true_num_rows_used = 1 # Should not happen if sorted_keys is not empty
        end
        
        # Ensure true_num_rows_used is at least 1 if there are any keys, to avoid 1:0 range
        if !isempty(widget_keys) && true_num_rows_used < 1
            true_num_rows_used = 1
        end

        for r_idx in 1:true_num_rows_used
            # By this point, row r_idx should have been populated if true_num_rows_used is correct
            rowsize!(params_content_layout, r_idx, Auto())
        end
    end
    
    rowsize!(main_layout, 2, Auto()) 
    Makie.trim!(main_layout) 
    GLMakie.display(target_fig.scene)
end

"""
Creates a base control figure with common elements:
Refresh button, method checkboxes, and save box.
Returns the figure and the update_notifier.
"""
function createBaseControlsFigure(
    plot_fig_ref::Makie.Figure, # For save box action
    shared_params_obs::Dict{String, Observable}, # For save box data
    method_params_collection_obs::Dict{String, Dict{String, Observable}}, # For save box data
    methods_obs::Observable{Vector{String}},
    all_method_names::Vector{String},
    ui_options_obs::Dict{String, Observable}
)
    GLMakie.activate!()
    base_controls_fig = Figure(size=(500, 600)) # Initial size, will grow as more controls are added
    #createParameterFigure(shared_params_obs, method_params_collection_obs, all_method_names)
    fig_layout = base_controls_fig.layout[1,1] = GridLayout(tellheight=false)
    rowgap!(fig_layout, 15) 

    current_row = 1

    # --- Main "Controls" Label & Refresh Button ---
    header_layout = fig_layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1
    update_layout = fig_layout[current_row, 1] = GridLayout()
    update_button = Button(update_layout[1,1], label="Refresh Plot Data", halign=:center, width=180)
    
    update_notifier = Observable(0)
    on(update_button.clicks) do _
        update_notifier[] += 1
    end
    current_row += 1

    # --- Parameter View Selection Menu ---
    Label(fig_layout[current_row, 1], "View Parameters & Options:", fontsize=16, halign=:left)
    current_row += 1
    
    menu_options = ["UI Options"; "Shared Parameters"; all_method_names] # Menu items
    # Ensure a default selection if possible, or handle no selection
    default_selection = isempty(menu_options) ? nothing : menu_options[2]

    param_view_menu = Menu(fig_layout[current_row, 1], options = menu_options, default = default_selection)
    selected_param_key_obs = param_view_menu.selection # This is the Observable for the selected menu item
    current_row += 1

    # --- Method Selection Checkboxes ---
    Label(fig_layout[current_row, 1], "Active Methods", fontsize=16, font=:bold, halign=:center)
    current_row += 1
    method_checkbox_layout = fig_layout[current_row, 1] = GridLayout()
    # Adapt createMethodCheckboxes to populate this layout
    createMethodCheckboxes(method_checkbox_layout, methods_obs, all_method_names) # (source: 46, 47, 48, 61)
    current_row += 1
     
    # --- Save Figure/Data Box ---
    Label(fig_layout[current_row, 1], "Save View", fontsize=16, font=:bold, halign=:center)
    current_row += 1
    save_box_layout = fig_layout[current_row, 1] = GridLayout()
    # Adapt createSaveFigBox to populate this layout
    createSaveFigBox(save_box_layout, plot_fig_ref, shared_params_obs, method_params_collection_obs, methods_obs, ui_options_obs) # (source: 37-45, 62)
    current_row += 1

    # Ensure the fig_layout rows can auto-size based on content added so far
    for i in 1:current_row-1 # -1 because current_row is ready for the next item
        try rowsize!(fig_layout, i, Auto()); catch; end
    end
    # --- Create the SINGLE Parameter Display Figure ---
    #params_fig = Figure(size=(700, 500)) # Adjust size as needed

    # --- Listener for Menu Selection to Repopulate the params_fig ---
    on(selected_param_key_obs) do selected_key
        if selected_key == "Shared Parameters"
            populate_parameter_figure!( # Assuming populate_parameter_figure! is defined
                "Shared Parameters", 
                shared_params_obs,
                2
            )
        elseif selected_key == "UI Options"
            populate_parameter_figure!("UI Style Options", ui_options_obs, 2)
        elseif haskey(method_params_collection_obs, selected_key)
            populate_parameter_figure!(
                "$selected_key Parameters", 
                method_params_collection_obs[selected_key], 
                2
            )
        else
            empty!(params_fig) # Clear if selection is invalid
            Label(params_fig[1,1], "Select a parameter set to view.", halign=:center)
        end
    end

    # --- Initially populate the params_fig ---
    if param_view_menu.selection[] !== nothing
        notify(param_view_menu.selection) # Trigger the on listener for initial population
    else
        empty!(params_fig[1,1])
        Label(params_fig[1,1], "Select a parameter set from the Controls window.", halign=:center)
    end
    
    return base_controls_fig, update_notifier
end

"""
Creates Textboxes for non-boolean parameters, arranged in rows.
Disables Makie's internal validator for non-numeric types (like String)
to avoid errors, relying on parsing within the callback instead.
"""
# Functions for Makie Controls
function createTextBoxes(
    current_layout,
    keys::Vector{String},
    params_obs::Dict{String, Observable},
    header::String
    )

    # Create a new grid layout in the next row of the parent figure
    Label(current_layout[1,:], header; valign = :top)
    sort!(keys) # Sort keys for consistent order

    if isempty(keys); return; end


    for (i, key) in enumerate(keys)

        layout_row = i+1
        label_col = 1
        textbox_col = 2
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
        Label(current_layout[layout_row, label_col], label_prefix *key * " = ", halign=:right).padding = (0,5,0,0)            

        # Create Textbox, passing Float64, Int, or Any as the validator
        tb = Textbox(current_layout[layout_row, textbox_col],
                     placeholder = string(value_to_display),
                     validator = validator, # Pass the determined Type
                     reset_on_defocus = true,
                     valign = :top
                     #width = 100
                     )

        # --- Callback for Textbox Submission ---
        on(tb.stored_string) do s
            target_type = typeof(params_obs[key][])
            try
                local parsed_val

                if target_type == String
                    parsed_val = s # Assign string directly
                else
                    # Attempt to parse to the target numeric type
                    parsed_val = parse(target_type, s)
                end

                if params_obs[key][] != parsed_val
                    params_obs[key][] = parsed_val
                end
            catch e
                rethrow(e)
                println("Invalid input '$s' for parameter '$key' (expected type $target_type): $e")
                # Reset textbox on error
                tb.stored_string = string(params_obs[key][])
            end
        end # End on
        # -------------------------------------
    end # End for loop

    # Optional: Adjust column sizes within tbLayout
    # num_cols_used = 2 * num_items_per_row
    # for c = 1:num_cols_used
    #     # Basic auto sizing
    #     try; colsize!(tbLayout, c, Auto()); catch; end
    # end
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
    methods_obs::Observable{Vector{String}}, # <<< Pass through
    ui_options_obs::Dict
    )

    gb = target_layout[1, 1:2] = GridLayout() # Example layout
    Label(gb[1, 1], "Save Image+CSV:", halign=:right).padding=(0,5,0,0)
    saveBox = Textbox(gb[1, 2], placeholder = "Type name (no ext)", width=200)
    try; colsize!(gb, 1, Auto()); colsize!(gb, 2, Auto()); catch; end

    get_save_dir() = joinpath(Utils.get_save_path(), "figures")

    # --- Modified `on` listener ---
    on(saveBox.stored_string) do s

        base_name = string(strip(s))
        
        if isempty(base_name)
            println("Save cancelled (empty name).")
            return
        end

        save_figures_path = get_save_dir()
        try
            mkpath(save_figures_path)
        catch e
            @warn "Could not create directory $save_figures_path: $e"
        end

        # Get the list of formats to save from the ui_options dictionary
        # Default to only ["png"] if the key is not found.
        formats_to_save = ui_options_obs["save_formats"][]
        
        println("Saving figure in formats: $(join(formats_to_save, ", "))...")

        # --- Save the figure in each requested format ---
        for format in formats_to_save
            # Sanitize format string
            fmt = lowercase(strip(format))
            if !(fmt in ["png", "pdf", "svg"])
                @warn "Unsupported save format '$fmt' specified. Skipping."
                continue
            end

            # Construct the full filename with the correct extension
            full_filename = joinpath(save_figures_path, base_name * ".$fmt")

            try
                # Temporarily activate CairoMakie for vector formats for high-quality output
                if fmt in ["pdf", "svg"]
                    CairoMakie.activate!()
                end

                # Save the figure
                Makie.save(full_filename, plot_fig)
                println("Plot saved as $full_filename")

            catch e
                @error "Failed to save figure in format .$fmt!" exception=(e, catch_backtrace())
            finally
                # IMPORTANT: Always reactivate GLMakie to keep the interactive window running
                GLMakie.activate!()
            end
        end # End loop over formats
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

function createMethodCheckboxes(cb_layout::GridLayout, methods_obs::Observable{Vector{String}}, methods::Vector{String})
    
    toLayout = cb_layout[end,1:div(length(methods),5)+1] = GridLayout() # 5 hard coded atm can be added to ui_dict

    for (i,method) = enumerate(methods)
        j = div(i-1,5) + 1
        Label(toLayout[mod1(i,5),j*2-1], method)
        init_methods = methods_obs[]
        if method in init_methods
            tmp = Checkbox(toLayout[mod1(i,5),j*2], checked = true)
        else
            tmp = Checkbox(toLayout[mod1(i,5),j*2], checked = false)
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

function createParameterToggles(to_layout, keys::Vector{String}, params_obs::Dict{String, Observable})
    ptoLayout = to_layout[:,:] = GridLayout()
    for (i,key) = enumerate(keys)
        Label(ptoLayout[i,1], key)
        toggleTmp= Toggle(ptoLayout[i,2], active = to_value(params_obs[key]))
        on(toggleTmp.active) do active
            if params_obs[key][] != to_value(active)
                params_obs[key][] = to_value(active) # Update observable
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
    all_method_names::Vector{String}   # FULL list of possible methods                
    )
    update_notifier = Observable(0)
    column_number = length(all_method_names)+1
    #row_number = max(length(shared_params_obs), maximum(map(dict -> length(dict), values(method_params_collection_obs)))) + 1
    control_fig = Figure(size=(800, 1000)) # Adjust size as needed, likely taller
    Label(control_fig[1, 1:column_number], "Control Panel", fontsize = 24, font=:bold, tellwidth=false, halign = :center) # Main title
    update_button = Button(control_fig[1,end], label = "Update", halign = :left)

    on(update_button.clicks) do _
        update_notifier[] += 1
    end
    tb_layout = control_fig[2, 1:column_number] = GridLayout()
    # --- Shared Parameters Section ---
    if !isempty(shared_params_obs)
        # The content goes into the layout of the GroupBox   
        #Label(tb_layout, "Shared Parameters", fontsize=18, font=:bold, halign=:center, tellwidth=false).padding = (0,0,10,5)
        # Separate keys
        # --- Filter out keys marked as :const ---
        # -------------------------------------
        shared_keys = sort(collect(keys(shared_params_obs)))
        shared_bool_keys = filter(k -> shared_params_obs[k][] isa Bool, shared_keys)
        shared_other_keys = filter(k -> !(shared_params_obs[k][] isa Bool), shared_keys)
        # Call user's helpers (they will add rows using end+1)
        if !isempty(shared_other_keys)
            rows = length(shared_other_keys)+1
            createTextBoxes(tb_layout[1:rows,1], shared_other_keys, shared_params_obs, "Shared Parameters")
        end
        if !isempty(shared_bool_keys)
            row_end = rows + length(shared_bool_keys) + 1
            createParameterToggles(tb_layout[rows+1:row_end,1], shared_bool_keys, shared_params_obs)
        end
    end

    # --- Method-Specific Parameters Section ---
    #Label(control_fig[end+1, :], "Method-Specific Parameters", fontsize=18, font=:bold, halign=:center, tellwidth=false).padding = (0,0,10,5)
    any_method_specific_params = false
    # Iterate through ALL possible methods to create sections consistently
    for (i,method_name) in enumerate(sort(all_method_names))
        # Check if this method has specific parameter observables defined
        if haskey(method_params_collection_obs, method_name)
            method_params_obs = method_params_collection_obs[method_name]
            if !isempty(method_params_obs)
                any_method_specific_params = true
                #tb_layout = control_fig[end, end+1]
                # Add a sub-header for the method
                #Label(control_fig[end+1, :], method_name, font=:bold, halign=:center, tellwidth=false).padding = (0,0,5,15) # Indent slightly

                # Separate keys for this method
                method_keys = sort(collect(keys(method_params_obs)))
                method_bool_keys = filter(k -> method_params_obs[k][] isa Bool, method_keys)
                method_other_keys = filter(k -> !(method_params_obs[k][] isa Bool), method_keys)

                # Call user's helpers for this method's params
                if !isempty(method_other_keys)
                    rows = length(method_other_keys)+1
                    createTextBoxes(tb_layout[1:rows,i+1], method_other_keys, method_params_obs, method_name)
                end
                if !isempty(method_bool_keys)
                    #row_end = rows + length(method_bool_keys)
                    createParameterToggles(tb_layout[rows + 1 : end,i+1], method_bool_keys, method_params_obs)
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
    cb_layout = control_fig[end+1, :] = GridLayout()
    createMethodCheckboxes(cb_layout, methods_obs, all_method_names)

    # --- Save Box Section ---
    # Note: This currently only passes shared_params_obs to be saved in the CSV.
    # Modifying createSaveFigBox would be needed to save method-specific params too.
    #Label(control_fig[end+1, :], "Save Current View", fontsize=18, font=:bold, halign=:center, tellwidth=false).padding = (0,0,10,5)
    createSaveFigBox(control_fig[end+1,:], plot_fig, shared_params_obs, method_params_collection_obs, methods_obs)

    return control_fig, update_notifier
end

# This function goes into your plotting_helpers.jl file
"""
    _parse_legend_position(s::String) -> Tuple{Symbol, Symbol}

Parses a descriptive string like "topright" or "bottomleft" into a
Tuple of Symbols `(halign, valign)` suitable for Makie's alignment.
Handles all combinations of top, bottom, left, right, and center.
"""
function _parse_legend_position(s_in::String)
    s = lowercase(s_in)

    if s == "center"
        return (:center, :center)
    end

    # Determine vertical alignment
    valign = if occursin("top", s)
        :top
    elseif occursin("bottom", s)
        :bottom
    else
        :center
    end

    # Determine horizontal alignment
    halign = if occursin("left", s)
        :left
    elseif occursin("right", s)
        :right
    else
        :center
    end

    return (halign, valign)
end
"""
    create_or_update_legend!(fig::Figure, ax::Axis, plotted_objects::Vector, 
                             labels::Vector, ui_options::Dict)

Clears any existing Legend from the figure and creates a new one based on the
position specified in `ui_options["legend_pos"]`.

The position can be:
- `:detached`: Places the legend in a new column to the right of the axis.
- A Symbol like `:rt`, `:ct`, `:rb`, etc., or a Tuple like `(:right, :top)`:
  Places the legend inside the axis at the specified position.
"""
function create_or_update_legend!(
    fig::Figure, 
    ax::Axis, 
    plotted_objects::Vector, 
    labels::Vector, 
    ui_options_obs::Dict
)
   # --- 1. Find and Delete any existing Legend in the Figure ---
    # We search the main layout for a legend in a separate column (e.g., fig[1,2])
    # and we also search inside the main axis for an attached legend.
    # It's crucial to delete from a copy of the contents list as we are modifying it.
    for elem in copy(contents(fig.layout))
        if elem isa Legend
            delete!(elem)
        end
    end

    # --- 2. Get Legend Properties from UI Options ---
    position = ui_options_obs["legend_pos"][]
    title = ui_options_obs["legend"][]

    if isempty(plotted_objects) || isempty(labels)
        # If no items, ensure the layout is clean (e.g., no empty legend column)
        # Check if column 2 exists and is empty, then delete it.
        try
            trim!(fig.layout) # trim! is often safer and more general
        catch e
            # Ignore if layout is already clean
        end
        return
    end

    # --- 3. Create and Place the New Legend ---
    try
        if position == "detached"
            # For a detached legend, create it in column 2 of the figure's layout.
            # This assumes the main axis is at fig[1, 1].
            Legend(fig[1, 2], plotted_objects, labels, title; 
                   tellheight=false,
                   titlesize=ui_options_obs["font_size"],
                   labelsize=ui_options_obs["label_size"]
            )
            # Ensure the new column's width is determined by the legend's content
            colsize!(fig.layout, 2, Auto())
        else
            # For an attached legend, create it directly inside the axis `ax`.
            # Makie correctly interprets position symbols like :rt, :lt, etc.
            # to place the legend at the corners of the axis.
            halign, valign = _parse_legend_position(position)
            Legend(fig[1,1], plotted_objects, labels, title; 
                   orientation = :vertical, # or :horizontal
                   tellheight=false, 
                   tellwidth=false,
                   # The position is set via halign/valign based on the symbol
                   halign = halign,
                   valign = valign,
                   titlesize=ui_options_obs["font_size"],
                   labelsize=ui_options_obs["label_size"],
                   margin=(10, 10, 10, 10)
            )
            # After creating an attached legend, ensure the layout is tidy.
            # If we switched from detached, column 2 might still exist but be empty.
            trim!(fig.layout)
            #colsize!(fig.layout, 1, Auto())
        end
    catch e
        @error "Failed to create or update legend." exception=(e, catch_backtrace())
    end
end

### Deprecated: ui_option specific figure

# """
#     add_ui_option_widget!(parent_cell, key_name, obs; kwargs...)

# Creates a UI element (a Label and a widget) for a single UI option. This function
# is simplified for UI options and does not handle `:const` or complex Tuples.
# It creates a Toggle for Bools, and a Textbox for Reals and Strings.
# """
# function add_ui_option_widget!(
#     parent_cell_for_item,
#     key_name::String,
#     param_obs::Observable;
#     label_fontsize::Int = 14,
#     internal_item_colgap::Int = 4
# )
#     # This item_layout holds ONLY one label and its corresponding widget
#     item_layout = parent_cell_for_item[] = GridLayout(tellwidth=false)
#     colgap!(item_layout, internal_item_colgap)

#     # The current value from the observable
#     val = param_obs[]

#     # Create the label for the UI option
#     Label(item_layout[1,1], key_name * " =",
#           halign=:right, fontsize=label_fontsize, padding=(0, 2, 0, 0))

#     # --- Create the appropriate widget based on the value's type ---

#     if isa(val, Bool)
#         # --- Create a Toggle for Boolean options ---
#         tgl = Toggle(item_layout[1,2], active = val)
#         on(tgl.active) do active_val
#             if param_obs[] != active_val
#                 param_obs[] = active_val
#             end
#         end
#     else # For Real or String types
#         # --- Create a Textbox for numeric or string options ---
#         validator_type = if isa(val, AbstractFloat)
#             Float64
#         elseif isa(val, Integer)
#             Int
#         else # Default to allowing any string (for String type and fallbacks)
#             s -> true
#         end

#         tb = Textbox(item_layout[1,2], placeholder = string(val),
#                      validator = validator_type, width = Auto(), reset_on_defocus=true)

#         on(tb.stored_string) do s
#             target_type = typeof(val)
#             try
#                 parsed_val = if target_type == String
#                     s
#                 elseif validator_type == Float64 || validator_type == Int
#                     parse(target_type, s)
#                 else
#                     s # If validator was a function, treat as string
#                 end

#                 if param_obs[] != parsed_val
#                     param_obs[] = parsed_val
#                 end
#             catch e
#                 # On parsing error, reset the textbox to the observable's last valid value
#                 tb.stored_string = string(param_obs[])
#             end
#         end
#     end

#     # Ensure the layout columns adapt to the content
#     colsize!(item_layout, 1, Auto())
#     colsize!(item_layout, 2, Auto())
# end

# """
#     create_interactive_ui_options_figure(ui_options_obs::Dict{String, Observable})

# Creates and displays a new interactive figure with widgets to control UI styling options.
# This version now uses the dedicated `add_ui_option_widget!` helper.
# """
# function create_interactive_ui_options_figure(
#     ui_options_obs::Dict{String, Observable};
#     num_columns::Int = 2,
#     figure_size = (500, 600)
# )
#     GLMakie.activate!()
#     ui_fig = Figure(size=figure_size)
#     Label(ui_fig[1, 1], "UI Styling Options", font=:bold, fontsize=18,
#           tellwidth=false, halign=:center, padding=(0,0,15,0))

#     options_layout = ui_fig[2, 1] = GridLayout(tellheight=false)
#     rowgap!(options_layout, 10)
#     colgap!(options_layout, 15)

#     # Filter keys to only show widgets for simple, editable types
#     displayable_keys = String[]
#     for (key, obs) in ui_options_obs
#         if isAtomic(obs[])
#             push!(displayable_keys, key)
#         end
#     end
#     sort!(displayable_keys)

#     if isempty(displayable_keys)
#         Label(options_layout[1,1], "(No editable UI options found)")
#         display(GLMakie.Screen(), ui_fig); return ui_fig
#     end

#     # --- Populate the Layout using the new, dedicated helper ---
#     r, c = 1, 1
#     for key in displayable_keys
#         add_ui_option_widget!(
#             options_layout[r, c],
#             key,
#             ui_options_obs[key] # Pass the corresponding observable
#             # You can pass styling kwargs like label_fontsize here if needed
#         )
#         c += 1
#         if c > num_columns; c = 1; r += 1; end
#     end

#     # Set final layout sizes
#     for c_idx in 1:min(num_columns, length(displayable_keys)); colsize!(options_layout, c_idx, Auto()); end
#     true_num_rows = ceil(Int, length(displayable_keys) / num_columns)
#     for r_idx in 1:true_num_rows; rowsize!(options_layout, r_idx, Auto()); end
    
#     rowsize!(ui_fig.layout, 1, Auto())
#     rowsize!(ui_fig.layout, 2, Auto())

#     display(GLMakie.Screen(), ui_fig)
#     return ui_fig
# end
