using CairoMakie
using Printf
using Statistics

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
        placeholder_string = isempty(strip(string(val))) ? "empty" : string(val)
        tb = Textbox(item_layout[1,2], placeholder = placeholder_string, 
                        validator = validator_type, width = Auto(), reset_on_defocus=true)
        on(tb.stored_string) do s
            target_type = typeof(val)
            try
                parsed_val = if target_type == String; s
                                elseif validator_type == Float64 || validator_type == Int; parse(target_type,s)
                                elseif target_type == Symbol; Symbol(s)
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
    fig_size = (500,600)
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
    create_or_update_selection_menu!(menu_container, current_menu_handle,
                                     available_options, persistent_selection_obs)

Robustly creates or updates a `Menu` widget within a given container.
It uses a delete-and-recreate pattern to avoid stability issues with
dynamically updating menu options.

# Arguments
- `menu_container::GridLayout`: The layout cell where the menu will be placed.
- `current_menu_handle::Observable{Union{Nothing, Menu}}`: An observable that holds
  the handle to the current `Menu` widget, allowing it to be deleted.
- `available_options::Vector{String}`: The new list of options for the menu.
- `persistent_selection_obs::Observable{String}`: The observable that holds the
  currently selected value. This function ensures its value stays valid and
  links the new menu to it.
"""
function create_or_update_selection_menu!(
    menu_container::GridLayout,
    current_menu_handle::Observable{Union{Nothing, Menu}},
    available_options::AbstractArray,
    persistent_selection_obs::Observable
)
    # 1. If a menu from a previous run exists, delete it.
    if !isnothing(current_menu_handle[])
        try
            delete!(current_menu_handle[])
        catch e
            # Ignore if already deleted or invalid
        end
    end
    # Also clear the container of any other elements (like a "No stats" label).
    for c in copy(menu_container.content); delete!(c); end

    # 2. Handle the case where there are no options to display.
    if isempty(available_options)
        Label(menu_container[1,1], "No options available")
        current_menu_handle[] = nothing # Ensure handle is cleared
        return
    end

    # 3. Determine the correct default selection.
    # If the currently selected option is still in the new list, keep it.
    # Otherwise, default to the first option in the new list.
    new_default = if persistent_selection_obs[] in available_options
        persistent_selection_obs[]
    else
        if isAtomic(available_options[1])
            available_options[1]
        else
            available_options[1][2]
        end
    end
    # Update the persistent observable to ensure it's in a valid state.
    persistent_selection_obs[] = new_default

    # 4. Create a brand new Menu widget inside the container.
    new_menu = Menu(menu_container[1,1],
                    options = available_options,
                    default = new_default)
    
    # 5. Link this new menu's selection back to our persistent observable.
    on(new_menu.selection) do selected_key
        # This check prevents a feedback loop if the update came from the persistent obs.
        if persistent_selection_obs[] != selected_key
            persistent_selection_obs[] = selected_key
        end
    end

    # 6. Store the handle to the new menu so we can delete it on the next update.
    current_menu_handle[] = new_menu
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
    all_method_sorted = sort!(all_method_names)
    # --- Parameter View Selection Menu ---
    Label(fig_layout[current_row, 1], "View Parameters & Options:", fontsize=16, halign=:left)
    current_row += 1
    
    menu_options = ["UI Options"; "Shared Parameters"; all_method_sorted] # Menu items
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
    createMethodCheckboxes(method_checkbox_layout, methods_obs, all_method_sorted) # (source: 46, 47, 48, 61)
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
    # create UI update_notifier
    ui_update = Observable(0)
    for ui_obs = values(ui_options_obs)
        on(ui_obs) do _
            ui_update[] += 1
        end
    end
   # --- GENERIC SELECTION MENU SETUP ---
   Label(fig_layout[current_row, 1], "Select Component", fontsize=16, halign=:left)
   current_row += 1
   
   # These are the key observables that form the "interface"
   components = Observable{Tuple}(("Component 1",))
   comp_options = lift(components) do comps; ([(name,ind) for (ind,name) = enumerate(comps)]) end # Holds the list of strings for the menu
   sel_comp = Observable{Int}(1) # Holds the final selected value
   
   # This container will hold the menu widget, which will be deleted and recreated
   menu_container = fig_layout[current_row, 1] = GridLayout()
   current_menu_handle = Observable{Union{Nothing, Menu}}(nothing)
   current_row += 1

   # --- REACTIVE LINK: Rebuild the menu whenever the options list changes ---
   # This `on` block is the core of the generalization. It lives here and handles all
   # the UI logic for updating the menu.
   on(comp_options) do _
       println("Updating selection menu with new options...")
       create_or_update_selection_menu!(
           menu_container,
           current_menu_handle,
           comp_options[],
           sel_comp
       )
   end
    return base_controls_fig, update_notifier, ui_update, components, sel_comp
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
    ui_options_obs::Dict{String, Observable},
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
        # --- NEW: Add UI Options ---
        push!(params_to_save, "# UI Options" => "====================")
        ui_keys = sort(collect(keys(ui_options_obs)))
        if isempty(ui_keys)
            push!(params_to_save, "(None)" => "")
        else
            for ui_key in ui_keys
                if haskey(ui_options_obs, ui_key)
                    # Get the value from the observable and convert to string
                    push!(params_to_save, string(ui_key) => string(ui_options_obs[ui_key][]))
                end
            end
        end
        # ---------------------------
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

        #original_update_state = ui_options_obs["update_limits"][]
        # Turn off auto-limiting. This prevents the plot from resetting.
        #ui_options_obs["update_limits"][] = false
        base_name = string(strip(s))
        
        if isempty(base_name)
            println("Save cancelled (empty name).")
            return
        end

        save_figures_path = get_save_dir()
        if ui_options_obs["create_savefolder"][]; save_figures_path *= "/$base_name" end
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
                    CairoMakie.save(full_filename, plot_fig, update = false)
                else
                    GLMakie.save(full_filename, plot_fig, update = false)
                end

                # Save the figure
                
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
             ui_options_obs,
             optional_info
         )
         # --------------------------------------------------
        #ui_options_obs["update_limits"][] = original_update_state
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
        title_str = ui_options_obs["legend"][]
        final_title = isempty(strip(title_str)) ? nothing : title_str

        if position == "detached"
            # For a detached legend, create it in column 2 of the figure's layout.
            Legend(fig[1, 2], plotted_objects, labels, final_title; # <-- Use final_title
                tellheight=false,
                titlesize=ui_options_obs["font_size"][], # Use [] to get value
                labelsize=ui_options_obs["font_size"][]
            )
            # Ensure the new column's width is determined by the legend's content
            colsize!(fig.layout, 2, Auto())
        else
            # For an attached legend, create it directly inside the axis's grid position
            halign, valign = _parse_legend_position(position)
            Legend(fig[1,1], plotted_objects, labels, final_title; # <-- Use final_title
                orientation = :vertical,
                tellheight=false, 
                tellwidth=false,
                halign = halign,
                valign = valign,
                titlesize=ui_options_obs["font_size"][],
                labelsize=ui_options_obs["font_size"][],
                margin=(10, 10, 10, 10)
            )
            # After creating an attached legend, trim the layout to remove empty columns
            trim!(fig.layout)
        end
    catch e
        @error "Failed to create or update legend." exception=(e, catch_backtrace())
    end
end

"""
    set_axis_styles!(ax, ui_options_obs, final_label_obs)

Applies a set of styles to a given `Axis` object. It now takes a dictionary
of final, combined observables for the title and labels.
"""
function set_axis_styles!(
    ax::Axis,
    ui_options_obs::Dict{String, Observable}
)
    try
        
        # Set other visual properties directly from the ui_options_obs dictionary
        ax.xgridvisible = ui_options_obs["xgridvisible"][]
        ax.ygridvisible = ui_options_obs["ygridvisible"][]
        ax.xticklabelsvisible = ui_options_obs["xticklabelsvisible"][]
        ax.yticklabelsvisible = ui_options_obs["yticklabelsvisible"][]
        
        # Set text sizes
        ax.titlesize = ui_options_obs["title_size"][]
        ax.xlabelsize = ui_options_obs["label_size"][]
        ax.ylabelsize = ui_options_obs["label_size"][]
        ax.xticklabelsize = ui_options_obs["ticklabel_size"][]
        ax.yticklabelsize = ui_options_obs["ticklabel_size"][]

        # --- NEW: Set Tick Positions ---
        xtick_count = ui_options_obs["xtick_count"][]
        ytick_count = ui_options_obs["ytick_count"][]
        
        # Use a tick count of 0 as a signal to use Makie's automatic default.
        if xtick_count > 0
            ax.xticks = ax.xscale[] == log10 ? LogTicks(LinearTicks(xtick_count)) : LinearTicks(xtick_count)
        end
        if ytick_count > 0
            ax.yticks = ax.yscale[] == log10 ? LogTicks(LinearTicks(ytick_count)) : LinearTicks(ytick_count)
        end

        # --- Set X-Axis Scale and Tick Formatting ---
        x_offset = ui_options_obs["xscale_offset"][]
        if x_offset != 0.0
            #ax.xscale = identity
            ax.xtickformat = tick_values -> map(x -> "$(round(x_offset, sigdigits=3)) + $(@sprintf("%.1e", x - x_offset))", tick_values)
        else
            xformat = ui_options_obs["xtickformat"][]
            ax.xtickformat = xformat == "default" ? Makie.automatic : xformat
        end

        # --- Set Y-Axis Scale and Tick Formatting ---
        y_offset = ui_options_obs["yscale_offset"][]
        if y_offset != 0.0
            #ax.yscale = identity
            ax.ytickformat = tick_values -> map(tick_values) do y
                deviation = y - y_offset
                offset_str = string(round(y_offset, sigdigits=3))
                # --- THIS IS THE FIX FOR THE SIGN ---
                sign_str = deviation < 0 ? "-" : "+"
                "$(offset_str) $(sign_str) $(@sprintf("%.1e", abs(deviation)))"
            end
        else
            yformat = ui_options_obs["ytickformat"][]
            ax.ytickformat = yformat == "default" ? Makie.automatic : yformat
        end
    catch e
        @warn "An error occurred while setting axis styles. A required key might be missing." exception=(e, catch_backtrace())
    end
end
"""
    set_axis_styles!(ax::Axis3, ui_options_obs, final_label_obs)

Applies styles to a 3D `Axis3` object. It dynamically switches between a 3D
surface view and a 2D top-down view based on the `plot_as_surface` UI option.
"""
function set_axis_styles!(
    ax::Axis3,
    ui_options_obs::Dict{String, Observable}
)
    try
        # Check the UI option to decide which mode to use
        is_surface_view = get(ui_options_obs, "plot_as_surface", Observable(false))[]

        # Set common properties first
        # ax.title = get(final_label_obs, "title", Observable("Default Title"))[]
        # ax.xlabel = get(final_label_obs, "xlabel", Observable("x"))[]
        # ax.ylabel = get(final_label_obs, "ylabel", Observable("y"))[]
        
        ax.titlesize = get(ui_options_obs, "title_size", Observable(16))[]
        ax.xlabelsize = get(ui_options_obs, "label_size", Observable(16))[]
        ax.ylabelsize = get(ui_options_obs, "label_size", Observable(16))[]
        ax.xticklabelsize = get(ui_options_obs, "ticklabel_size", Observable(14))[]
        ax.yticklabelsize = get(ui_options_obs, "ticklabel_size", Observable(14))[]

        if is_surface_view
            # --- Configure for 3D Surface View ---
            ax.zlabelsize = get(ui_options_obs, "label_size", Observable(16))[]
            ax.zticklabelsize = get(ui_options_obs, "ticklabel_size", Observable(14))[]
            
            ax.aspect = (1, 1, 0.5) # Or lift from a UI option: `ui_options_obs["aspect"][]`
            ax.perspectiveness = 0.5 # Or lift from a UI option

            ax.xgridvisible = true; ax.ygridvisible = true; ax.zgridvisible = true
            ax.xticklabelsvisible = true; ax.yticklabelsvisible = true; ax.zticklabelsvisible = true
        else
            # --- Configure for 2D Top-Down View ---
            ax.zlabel = "" # Hide Z label
            ax.zlabelsize = 0 # Ensure it takes no space
            ax.zticklabelsvisible = false # Hide Z tick labels
            
            ax.aspect = :data
            ax.perspectiveness = 0.0
            
            # Set the view to be directly from above
            ax.elevation = pi/2
            ax.azimuth = 0

            ax.xgridvisible = true; ax.ygridvisible = true; ax.zgridvisible = false # Hide Z grid
        end

    catch e
        @warn "An error occurred while setting 3D axis styles. A required key might be missing." exception=(e, catch_backtrace())
    end
end
"""
    create_axis_label_observables(ui_options_obs, default_values) -> Dict

Creates a dictionary of final, combined observables for axis labels and titles.

It iterates through a `default_values` dictionary. For each entry, it creates
a `lift` that combines the user's input from `ui_options_obs` with the
provided default. If the user's input is "default", the fallback value is used.
The fallback can be static (e.g., a String) or dynamic (an Observable).

# Arguments
- `ui_options_obs::Dict{String, Observable}`: The dictionary of raw UI observables.
- `default_values::Dict{String, Any}`: Maps a UI key (e.g., "xlabel") to its default value.

# Returns
- `Dict{String, Observable}`: A dictionary mapping UI keys to the final observables
  that should be used to set axis properties.
"""
function create_axis_label_observables(
    ui_options_obs::Dict{String, Observable},
    default_values::Dict{String, Any}
)
    final_label_obs_dict = Dict{String, Observable}()

    for (key, default_val) in default_values
        if !haskey(ui_options_obs, key)
            @warn "UI option key '$key' not found in ui_options_obs. Skipping label creation."
            continue
        end

        ui_obs = ui_options_obs[key]

        local final_obs # Ensure it's scoped for the if/else block
        if isa(default_val, Observable)
            # Dynamic default: lift on both user input and the default's observable
            final_obs = lift(ui_obs, default_val) do user_input, dynamic_default
                user_input == "default" ? dynamic_default : user_input
            end
        else # Static default (e.g., a simple String)
            final_obs = lift(ui_obs) do user_input
                user_input == "default" ? default_val : user_input
            end
        end
        final_label_obs_dict[key] = final_obs
    end

    return final_label_obs_dict
end

"""
    plot_reference_lines!(ax, exponents; kwargs...)

Plots reference power-law lines anchored to the corners of the current axis view.
The sign of each exponent determines the anchor point:
- Positive exponent `p`: Anchors at the top-right `(xmax, ymax)`.
- Negative exponent `p`: Anchors at the bottom-right `(xmax, ymin)`.

# Arguments
- `ax::Axis`: The Makie axis to plot into.
- `exponents::Union{Tuple, Nothing}`: A tuple of signed exponents.

# Keyword Arguments
- `label::String`: A single label for all reference lines to group them in the legend.
- Other keywords are passed to `Makie.lines!`.
"""
function plot_reference_lines!(
    ax::Axis,
    exponents::Union{Tuple, Nothing};
    label::String = "Reference Lines",
    color = :black,
    linestyle = :dash,
    kwargs...
)
    # --- Input and Axis Validation ---
    if isnothing(exponents) || isempty(exponents)
        return []
    end

    current_limits_nested = ax.limits[]
    if isnothing(current_limits_nested) || isnothing(current_limits_nested[1]) || isnothing(current_limits_nested[2])
        @warn "Cannot plot reference lines, axis view limits are not yet set."
        return []
    end
    
    xlims, ylims = current_limits_nested
    
    # On a log scale, limits must be positive.
    if any(x -> x <= 0, (xlims..., ylims...))
        @warn "Cannot plot reference lines on a log-log plot with non-positive axis limits."
        return []
    end
    
    xmin, xmax = xlims
    ymin, ymax = ylims

    # For a visually straight line on a log-log plot, we create log-spaced x-values.
    x_ref_values = 10 .^ range(log10(xmin), log10(xmax), length=100)
    
    # The anchor x-position is always the leftmost edge.
    ref_x = xmin

    plotted_lines = []
    
    for p_signed in exponents
        if p_signed == 0; continue; end

        # --- Correctly determine the y-anchor point ---
        local y_anchor
        if p_signed > 0
            # An O(x^2) line should start low on the left.
            y_anchor = ymin
        else # p_signed < 0
            # An O(x^-1) line should start high on the left.
            y_anchor = ymax
        end

        # --- Calculate the line using the power-law formula ---
        
        # Calculate scaling constant C so that y = C * x^p passes through (ref_x, y_anchor)
        C = y_anchor / (ref_x^p_signed)
        
        # Calculate the y-values for the reference line using the power law
        y_ref_line = C .* (x_ref_values .^ p_signed)
        
        # Create a single line plot for this exponent
        line = lines!(ax, x_ref_values, y_ref_line;
            label = label, # Use the same label for grouping in the legend
            color = (color, 0.65),
            linestyle = linestyle,
            kwargs...
        )
        
        push!(plotted_lines, line)
    end

    return plotted_lines
end

"""
    delete_plots_by_label!(ax::Axis, label_to_delete::String)

Finds all plot objects in a given axis that have a specific label
and deletes them. This version correctly accesses plots via `ax.scene`.
"""
function delete_plots_by_label!(ax::Axis, label_to_delete::String)
    # CORRECT API: Access plots via the axis's scene.
    # The `ax.scene` contains the list of all plot objects drawn into that axis.
    plots_to_delete = [p for p in ax.scene.plots if haskey(p,:label) && p.label[] == label_to_delete]
    
    if !isempty(plots_to_delete)
        for p in plots_to_delete
            delete!(ax.scene, p) # Delete from the scene
        end
        return true
    end
    
    return false
end

#======================================================================#
#           RECURSIVE MIN/MAX CALCULATION
#======================================================================#

# --- Base Cases ---
# For a single number
_get_val(x::Real) = isfinite(x) ? x : nothing
# For a vector of numbers
_get_val(v::AbstractVector{<:Real}) = isempty(v) ? nothing : filter(isfinite, v)

# --- Recursive Helpers ---
"""
    get_min_val(data) -> Union{Real, Nothing}

Recursively finds the minimum finite value in a potentially nested collection
of vectors and numbers. Returns `nothing` if no finite values are found.
"""
function get_min_val(data)
    # Use multiple dispatch to handle the base cases (a single number or a vector of numbers)
    # and the recursive case (a vector of other things).
    _get_min_val(data)
end

_get_min_val(data::Real) = _get_val(data)
_get_min_val(data::AbstractVector{<:Real}) = minimum(_get_val(data); init=Inf)
_get_min_val(data::Tuple{<:Any,<:Vector}) = _get_min_val(data[1])

function _get_min_val(data::AbstractVector) # Recursive case for nested vectors
    # Use a generator to recursively call get_min_val on each element,
    # filtering out `nothing` results before finding the minimum.
    return minimum((v for v in (get_min_val(d) for d in data) if !isnothing(v)); init=Inf)
end

"""
    get_max_val(data) -> Union{Real, Nothing}

Recursively finds the maximum finite value in a potentially nested collection.
"""
function get_max_val(data)
    _get_max_val(data)
end

_get_max_val(data::Real) = _get_val(data)
_get_max_val(data::AbstractVector{<:Real}) = maximum(_get_val(data); init=-Inf)
_get_max_val(data::Tuple{<:Any,<:Vector}) = _get_max_val(data[1])

function _get_max_val(data::AbstractVector) # Recursive case
    return maximum((v for v in (get_max_val(d) for d in data) if !isnothing(v)); init=-Inf)
end


#======================================================================#
#           TOP-LEVEL LIMIT CALCULATION & APPLICATION
#======================================================================#

"""
    get_raw_global_range(data) -> Tuple

Uses the recursive helpers to find the raw (min, max) tuple for a given dataset.
"""
function get_raw_global_range(data)
    min_val = get_min_val(data)
    max_val = get_max_val(data)
    return (min_val, max_val)
end

"""
    calculate_padded_axis_range(raw_limits, padding_factor, is_log_scale) -> Tuple

Takes raw (min, max) limits and applies padding, correctly handling the
fallback from log to linear scale if the data range is not positive.
"""
function calculate_padded_axis_range(raw_limits::Tuple, padding_factor::Real, is_log_scale::Bool)
    min_raw, max_raw = raw_limits
    
    if isnothing(min_raw) || isnothing(max_raw) || !isfinite(min_raw) || !isfinite(max_raw)
        return (0.0, 1.0) # Default if no valid data
    end

    # Check for log scale validity. If user wants log but data is not positive,
    # fall back to linear scale for this calculation.
    use_log = is_log_scale && (min_raw > 0)
    
    if use_log
        pad = padding_factor
        final_min = min_raw / (1 + pad)
        final_max = max_raw * (1 + pad)
    else
        if is_log_scale && min_raw <= 0
            @warn "Log scale requested but data contains non-positive values. Applying linear padding instead."
        end
        data_range = max_raw - min_raw
        pad = data_range ≈ 0 ? 0.1 : (data_range * padding_factor / 2.0)
        final_min = min_raw - pad
        final_max = max_raw + pad
    end
    
    return (final_min, final_max)
end

"""
    set_axis_limits!(ax, x_data, y_data, ui_options_obs)

The main convenience function. It calculates and applies final padded limits
for both x and y axes, and sets the axis scale based on UI options.
"""
function set_axis_limits!(
    ax::Axis,
    x_data, # Can be a nested collection
    y_data, # Can be a nested collection
    ui_options_obs::Dict{String, Observable}
)
    try
        # --- Get UI Options ---
        x_padding = ui_options_obs["xpadding"][]
        y_padding = ui_options_obs["ypadding"][]
        x_is_log_requested = ui_options_obs["xlogscale"][]
        y_is_log_requested = ui_options_obs["ylogscale"][]

        # --- Calculate Raw and Padded Limits ---
        raw_xlims = get_raw_global_range(x_data)
        raw_ylims = get_raw_global_range(y_data)
    

        final_xlims = calculate_padded_axis_range(raw_xlims, x_padding, x_is_log_requested)
        final_ylims = calculate_padded_axis_range(raw_ylims, y_padding, y_is_log_requested)

        # Apply limits
        try limits!(ax, final_xlims..., final_ylims...) catch e; end
        # --- Set Axis Scale and Limits ---
        ax.xscale[] = final_xlims[1] > 0 && x_is_log_requested ? log10 : identity
        ax.yscale[] = final_ylims[1] > 0 && y_is_log_requested ? log10 : identity
        
    catch e
        @error "Failed to set dynamic axis limits. A required UI option key might be missing." exception=(e, catch_backtrace())
    end
    return nothing
end

function deleteUIOptions!(
    ui_options_dict::Dict,
    keys_to_delete::AbstractVector{String}
)
    for key in keys_to_delete
        if haskey(ui_options_dict, key)
            delete!(ui_options_dict, key)
        else
            # Optional: Warn if a key to be deleted doesn't exist.
            # @warn "Attempted to delete non-existent UI option key: '$key'"
        end
    end
    # The dictionary is modified in-place, so no return is necessary.
    return nothing
end

function _is_log_save(x::Real)::Bool
    return x > 0
end
function _is_log_save(xs::AbstractVector)::Bool
    return all(map(x -> _is_log_save(x), xs))
end

"""
    plot_extrema_lines!(ax, x_snapshot, u_snapshot, ui_options_obs, method_index)

Calculates and plots vertical dashed lines for the maximum and/or minimum of a
single data snapshot, based on boolean toggles in the UI options.

# Arguments
- `ax::Axis`: The axis to plot into.
- `x_snapshot::AbstractVector`: The x-coordinates for a single method's snapshot.
- `u_snapshot::AbstractVector`: The u-coordinates for a single method's snapshot.
- `ui_options_obs::Dict{String, Observable}`: The dictionary of UI styling observables.
  It checks for the keys "track_max" and "track_min".
- `method_index::Int`: The index of the current method, used to select the correct color.
"""
function plot_extrema_lines!(
    ax::Axis,
    x_snapshot::AbstractVector,
    u_snapshot::AbstractVector,
    ui_options_obs::Dict{String, Observable},
    method_index::Int
)
    # --- Check which lines to plot from UI options ---
    # Use `get` with a default of `false` to safely handle missing keys.
    track_max = get(ui_options_obs, "track_max", Observable(false))[]
    track_min = get(ui_options_obs, "track_min", Observable(false))[]

    # If neither is enabled, do nothing.
    if !track_max && !track_min
        return nothing
    end

    # --- Find valid data once ---
    valid_indices = findall(isfinite, u_snapshot)
    if isempty(valid_indices)
        return nothing
    end
    
    # Get common styling options
    color = ui_options_obs["colors"][][mod1(method_index, end)]
    linewidth = ui_options_obs["linewidth"][]

    # --- Plot Maximum Line if enabled ---
    if track_max
        u_max, idx_in_valid = findmax(u_snapshot[valid_indices])
        original_idx = valid_indices[idx_in_valid]
        x_at_max = x_snapshot[original_idx]
        
        linesegments!(ax, [Point2f(x_at_max, 0), Point2f(x_at_max, u_max)];
            color = (color, 0.75),
            linestyle = :dash,
            linewidth = linewidth / 2
        )
    end

    # --- Plot Minimum Line if enabled ---
    if track_min
        u_min, idx_in_valid = findmin(u_snapshot[valid_indices])
        original_idx = valid_indices[idx_in_valid]
        x_at_min = x_snapshot[original_idx]

        linesegments!(ax, [Point2f(x_at_min, 0), Point2f(x_at_min, u_min)];
            color = (color, 0.75),
            linestyle = :dot, # Use a different linestyle for min to distinguish
            linewidth = linewidth / 2
        )
    end
    
    return nothing
end

#======================================================================#
#           NEW INTERNAL HELPER FOR OUTLIER DETECTION
#======================================================================#

"""
    _find_outlier_indices(y_data, ui_options_obs) -> Vector{Int}

Identifies the indices of extreme outliers in a vector using a tunable IQR method.
The threshold is controlled by the "outlier_threshold" key in `ui_options_obs`.
"""
function _find_outlier_indices(
    y_data::AbstractVector,
    threshold::Real
)
    if length(y_data) < 5; return Int[]; end

    finite_y_data = filter(isfinite, y_data)
    if length(finite_y_data) < 5; return Int[]; end

    q1 = quantile(finite_y_data, 0.25)
    q3 = quantile(finite_y_data, 0.75)
    iqr = q3 - q1
    
    # Define the valid range using the tunable threshold
    lower_bound = q1 - threshold * iqr
    upper_bound = q3 + threshold * iqr
    
    # Find the indices of the original vector that are outliers
    return findall(y -> isfinite(y) && (y < lower_bound || y > upper_bound), y_data)
end


"""
    create_base_plot_1D!(...)

Handles the core plotting for 1D data series. This version uses a pre-calculated
permutation vector to draw plots in a sorted order (e.g., "Analytic" first)
while maintaining a consistent styling order for colors and markers.
"""
function create_base_plot_1D!(
    plot_fig::Figure,
    ax::Axis,
    active_methods::Vector{String},
    xs::AbstractVector,
    us::AbstractVector,
    ui_options_obs::Dict{String, Observable};
    plot_observable::Bool = false,
    is_static::Bool = false
)

    # Defining variables
    mark_outliers = ui_options_obs["mark_outliers"][]
    remove_outliers = ui_options_obs["remove_outliers"][]

    # --- Setup and Styling (as before) ---
    width, height = ui_options_obs["figsize"][]
    resize!(plot_fig, width, height)
    empty!(ax)

    if isempty(active_methods); return nothing; end

    # --- 1. Create the Sorting Permutation ---
    # Define the sorting key function.
    sort_key(label) = ((contains(lowercase(label), "analytic")) ? 0 : 1, label)
    # `sortperm` returns a vector of indices that would sort the original vector.
    # E.g., if active_methods is ["B", "Analytic", "A"], p will be [2, 3, 1].
    p = ui_options_obs["sort_legend"][] ? sortperm(active_methods, by = sort_key) : 1:length(active_methods)

    # --- 2. Plot in the Sorted Order ---
    plotted_objects = []
    labels_for_legend = String[]
    
    # The main loop now iterates through the permutation vector `p`.
    # `plot_idx` will be 1, 2, 3... for consistent styling.
    # `data_idx` will be the sorted index, e.g., 2, 3, 1... for accessing data.
    for (plot_idx, data_idx) in enumerate(p)
        # Safety check
        if data_idx > length(xs) || data_idx > length(us); continue; end

        # Use `data_idx` to get the correctly sorted label and data.
        plotLabel = active_methods[data_idx]
        x_data = plot_observable ? xs[data_idx] : to_value(xs[data_idx])
        u_data = plot_observable ? us[data_idx] : to_value(us[data_idx])

        # Use `plot_idx` to get consistent styling.
        color = ui_options_obs["colors"][][mod1(plot_idx, end)]
        marker = ui_options_obs["markers"][][mod1(plot_idx, end)]
        linestyle = ui_options_obs["dashed_lines"][] ? ui_options_obs["lineStyles"][][mod1(plot_idx,end)] : :solid

        if mark_outliers || remove_outliers
            outlier_indices = _find_outlier_indices(u_data, ui_options_obs["outlier_threshold"][])
            if mark_outliers 
                outlier_x_positions = x_data[outlier_indices]
                color = ui_options_obs["colors"][][mod1(plot_idx, end)]
                vlines!(ax, outlier_x_positions; color=(color, 0.4), linestyle=:dot, linewidth=ui_options_obs["linewidth"][]/1.5)
            end
            if remove_outliers
                us[data_idx][outlier_indices] .= NaN
            end
        end

        # Plot main data
        obj_for_legend = nothing
        if ui_options_obs["show_lines"][]
            l = lines!(ax, x_data, u_data; 
                color=color, linewidth=ui_options_obs["linewidth"], 
                label=plotLabel, linestyle=linestyle)
            obj_for_legend = l
        end
        if ui_options_obs["show_scatter"][]
            s = scatter!(ax, x_data, u_data; 
                color=color, markersize=ui_options_obs["markersize"], 
                marker=marker, label=plotLabel)
            if isnothing(obj_for_legend); obj_for_legend = s; end
        end
        
        # Call extrema tracking with the correct data and styling index
        plot_extrema_lines!(ax, x_data, u_data, ui_options_obs, plot_idx)
        
        if !isnothing(obj_for_legend)
            push!(plotted_objects, obj_for_legend)
            push!(labels_for_legend, plotLabel)
        end
    end

    if is_static || ui_options_obs["update_limits"][]; set_axis_limits!(ax, xs, us, ui_options_obs) end
    set_axis_styles!(ax, ui_options_obs)
    # --- 3. Create the Legend ---
    # The `plotted_objects` and `labels_for_legend` are now already in the desired
    # sorted order, so no extra sorting is needed here.
    create_or_update_legend!(
        plot_fig,
        ax,
        plotted_objects,
        labels_for_legend,
        ui_options_obs
    )
    
    return nothing
end

"""
    _update_minmax(current_min, current_max, new_data_vec, is_log_scale)

Internal helper to update min/max values from a vector of new data.
For log scale, it only considers positive values.
"""
function _update_minmax(current_min, current_max, new_data_vec::AbstractVector{<:Real}, is_log_scale::Bool)
    valid_data = if is_log_scale
        filter(x -> isfinite(x) && x > 0, new_data_vec)
    else
        filter(isfinite, new_data_vec)
    end
    
    if isempty(valid_data)
        return current_min, current_max
    end
    
    min_local, max_local = extrema(valid_data)
    return min(current_min, min_local), max(current_max, max_local)
end
"""
    calculate_padded_global_range(all_methods_data, padding_factor, is_log_scale) -> Tuple

Calculates the global min/max range for a single axis across all data, then applies
padding suitable for either a linear or log scale.

# Arguments
- `all_methods_data::Vector{<:Vector{<:Tuple}}`: The raw data structure.
- `padding_factor::Real`: The padding to apply, as a fraction (e.g., 0.1 for 10%).
- `is_log_scale::Bool`: If true, calculates padding suitable for a log-scaled axis.

# Returns
- A `Tuple{Float64, Float64}` representing `(limit_min, limit_max)`.
"""
function calculate_global_axis_range(
    all_methods_data::Vector{<:Vector{<:Tuple{<:Any,<:AbstractVector}}},
    padding_factor::Real,
    is_log_scale::Bool
)
    min_overall = Inf
    max_overall = -Inf
    found_data = false

    for method_data in all_methods_data
        for (value, time_vector) in method_data
            if ismissing(value); continue; end

            if isa(value, AbstractVector{<:Real})
                if !isempty(value)
                    found_data = true
                    min_overall, max_overall = _update_minmax(min_overall, max_overall, value, is_log_scale)
                end
            elseif isa(value, Real)
                val_to_check = is_log_scale ? (value > 0 ? value : Inf) : value
                if isfinite(val_to_check)
                    found_data = true
                    min_overall = min(min_overall, val_to_check)
                    max_overall = max(max_overall, val_to_check)
                end
            end
        end
    end

    if !found_data
        return is_log_scale ? (0.1, 10.0) : (0.0, 1.0)
    end

    # --- Apply Padding ---
    if is_log_scale
        # For log scale, padding is multiplicative (a factor).
        pad_amount_log = padding_factor
        final_min = min_overall / (1 + pad_amount_log)
        final_max = max_overall * (1 + pad_amount_log)
    else
        # For linear scale, padding is additive.
        data_range = max_overall - min_overall
        pad_amount_linear = data_range ≈ 0 ? 0.1 : (data_range * padding_factor / 2.0)
        final_min = min_overall - pad_amount_linear
        final_max = max_overall + pad_amount_linear
    end

    return (final_min, final_max)
end

#======================================================================#
#                      1. DATA COMPONENT EXTRACTION
#======================================================================#

"""
    extractU(u_data_all_methods, component_index) -> Vector{Vector{Vector{Float64}}}

Extracts a single component's time series data from the full `uData` structure.

This function is robust and handles cases where the solution `u` at each time step
is either a `Vector` (for 1D single-component systems) or a `Matrix` (for
multi-component systems).

# Arguments
- `u_data_all_methods`: The full data structure, which can contain a mix of
  vectors and matrices. Expected Type: `Vector{<:Vector{<:AbstractArray}}`.
- `component_index::Int`: The column index of the component to extract.

# Returns
- A `Vector{Vector{Vector{Float64}}}` containing the extracted data for the
  specified component, structured as `(method -> run -> time series)`.
"""
function extractU(
    u_data_all_methods::Vector{<:AbstractVector{<:AbstractArray}},
    component_index::Int
)
    # The final data structure for the single extracted component
    extracted_u = Vector{Vector{Vector{Float64}}}()

    # Loop through each method's data
    for method_data in u_data_all_methods
        method_component_data = Vector{Vector{Float64}}()
        
        # Loop through each run's data for that method
        for run_data in method_data
            
            local component_time_series::Vector{Float64}

            # --- CASE DISTINCTION to handle VecOrMat ---
            if isa(run_data, AbstractMatrix)
                # --- Handle the Matrix case (e.g., time x components) ---
                if component_index > size(run_data, 2)
                    @warn "Component index $component_index is out of bounds for a Matrix with $(size(run_data, 2)) components. Defaulting to component 1."
                    component_time_series = run_data[:, 1]
                else
                    component_time_series = run_data[:, component_index]
                end
            elseif isa(run_data, AbstractVector)
                # --- Handle the Vector case (assumed to be for component 1) ---
                if component_index == 1
                    component_time_series = run_data
                else
                    # It's a 1D solution, but a component > 1 was requested. Return empty.
                    @warn "Component index $component_index requested for a single-component (Vector) solution. Returning empty data for this run."
                    component_time_series = Float64[]
                end
            else
                @warn "Unsupported data structure of type `$(typeof(run_data))` found in uData. Skipping."
                component_time_series = Float64[]
            end
            
            push!(method_component_data, component_time_series)
        end
        push!(extracted_u, method_component_data)
    end

    return extracted_u
end

#======================================================================#
#                      2. GLOBAL LIMIT CALCULATION (CORRECTED)
#======================================================================#

"""Internal helper to update min/max, handling log scale for filtering."""
function _update_minmax(current_min, current_max, new_data, is_log_scale)
    valid_data = if is_log_scale
        filter(x -> isfinite(x) && x > 0, new_data)
    else
        filter(isfinite, new_data)
    end
    if isempty(valid_data); return current_min, current_max; end
    min_local, max_local = extrema(valid_data)
    return min(current_min, min_local), max(current_max, max_local)
end

# --- CORRECTED Method for FULL TIME-SERIES data (1D) ---
"""
    calculate_global_axis_range(data, padding_factor, is_log_scale) -> Tuple

Calculates the global padded min/max range for a 1D dataset (like `u` or 1D `x`).
This version correctly iterates over the data structure.
"""
function calculate_global_axis_range(
    data::Vector{<:Vector{<:Vector{<:Real}}},
    padding_factor::Real,
    is_log_scale::Bool
)
    min_overall, max_overall = Inf, -Inf
    found = false
    # CORRECTED LOOP: Iterate only two levels deep. `run_data` is now the Vector.
    for method_data in data, run_data in method_data
        if !isempty(run_data)
            found = true
            min_overall, max_overall = _update_minmax(min_overall, max_overall, run_data, is_log_scale)
        end
    end
    
    if !found; return is_log_scale ? (0.1, 10.0) : (0.0, 1.0); end
    
    # Apply padding
    if is_log_scale
        pad = padding_factor
        return (min_overall / (1 + pad), max_overall * (1 + pad))
    else
        data_range = max_overall - min_overall
        pad = data_range ≈ 0 ? 0.1 : (data_range * padding_factor / 2.0)
        return (min_overall - pad, max_overall + pad)
    end
end

# --- CORRECTED Method for 2D data ---
"""
    calculate_global_axis_range(data, padding_factors, is_log_scales) -> Tuple{Tuple, Tuple}

Calculates the global padded min/max for a 2D dataset (like 2D `x`).
"""
function calculate_global_axis_range(
    data::Vector{<:Vector{<:Vector{<:NTuple{2}}}},
    padding_factors::Tuple{Real, Real},
    is_log_scales::Tuple{Bool, Bool}
)
    xmin, xmax = Inf, -Inf
    ymin, ymax = Inf, -Inf
    found = false
    # CORRECTED LOOP: Iterate only two levels deep. `run_data` is the Vector of Tuples.
    for method_data in data, run_data in method_data
        if !isempty(run_data)
            found = true
            x_coords = first.(run_data)
            y_coords = last.(run_data)
            xmin, xmax = _update_minmax(xmin, xmax, x_coords, is_log_scales[1])
            ymin, ymax = _update_minmax(ymin, ymax, y_coords, is_log_scales[2])
        end
    end

    if !found; return ((0.0, 1.0), (0.0, 1.0)); end

    # Apply padding for x-axis
    x_range = xmax - xmin
    x_pad = x_range ≈ 0 ? 0.1 : (x_range * padding_factors[1] / 2.0)
    final_xlims = (xmin - x_pad, xmax + x_pad)

    # Apply padding for y-axis
    y_range = ymax - ymin
    y_pad = y_range ≈ 0 ? 0.1 : (y_range * padding_factors[2] / 2.0)
    final_ylims = (ymin - y_pad, ymax + y_pad)
    
    return (final_xlims, final_ylims)
end


# --- Base Case: We've drilled down to the Tuple containing the Dict and the time vector. ---
# This is the "workhorse" that performs the actual extraction.
function extractStats(
    run_data::Tuple{<:Dict, <:AbstractVector},
    selected_key::String
)
    stats_dict, times = run_data
    # Use `get` for safety, defaulting to `missing` if the key isn't in this run's stats.
    stat_val = stats_dict[selected_key]
    # Return the new tuple with the extracted value and its original time vector.
    return (stat_val, times)
end
function extractStats(
    run_data::Dict,
    selected_key::String
)
    return run_data[selected_key]
end

# --- Recursive Case: For any collection of runs/methods ---
# This function takes a vector (e.g., of methods, or of runs), iterates
# through it, and calls `extractStats` on each element.
function extractStats(
    all_series_data::Vector,
    selected_key::String
)
    # This handles any level of nesting (e.g., Vector{Vector{...}})
    
    num_series = length(all_series_data)
    # Pre-allocate the output vector. It will have the same nesting structure as the input.
    extracted = Vector{Any}(undef, num_series)

    # Use an indexed loop with an `isassigned` check for robustness.
    for i in 1:num_series
        extracted[i] = extractStats(all_series_data[i], selected_key)
    end

    return filter(!ismissing, extracted)
end


#======================================================================#
#              GENERALIZED `extractData` FUNCTION SUITE
#======================================================================#

# --- RECURSIVE `_extract_component` HELPERS ---

# Base Case 1: The data is a Matrix. This is the "workhorse".
# It extracts the specified column (for time-dependent) or value (for time-independent).
function _extract_component(stat_val::AbstractMatrix, selected_comp::Int)
    return 1 <= selected_comp <= size(stat_val, 2) ? stat_val[:, selected_comp] : missing
end

# Base Case 2: The data is a single Number (scalar).
function _extract_component(stat_val::Number, selected_comp::Int)
    return selected_comp == 1 ? stat_val : missing
end

# Recursive Case: The data is a Vector.
# This function calls `_extract_component` on each element of the vector.
function _extract_component(stat_val::AbstractVector, selected_comp::Int)
    # This handles any level of nesting, e.g., Vector{Matrix}, Vector{Vector{Matrix}}, etc.
    return [_extract_component(item, selected_comp) for item in stat_val]
end

# Fallback for any other unsupported type.
function _extract_component(stat_val, selected_comp::Int)
    @warn "Unsupported statistic type `$(typeof(stat_val))` for component extraction. Returning missing."
    return missing
end


# --- Main `extractData` functions ---

# Base Case 1: Operates on the (Dict, time_vector) tuple for time-dependent data.
function extractData(
    run_data::Tuple{<:Dict, <:AbstractVector},
    selected_key::String,
    selected_comp::Int
)
    stats_dict, times = run_data
    stat_val = get(stats_dict, selected_key, missing)
    
    if ismissing(stat_val)
        return (missing, times)
    end
    
    # Call the recursive helper to get the single component data
    component_data = _extract_component(stat_val, selected_comp)
    
    # Return the new tuple with the extracted component data and its original time vector.
    return (component_data, times)
end

# Base Case 2: Operates on a raw Dict for time-independent data.
function extractData(
    run_data::Dict,
    selected_key::String,
    selected_comp::Int
)
    stat_val = get(run_data, selected_key, missing)
    
    if ismissing(stat_val)
        return (missing, Float64[]) 
    end
    
    component_data = _extract_component(stat_val, selected_comp)
    
    # Return a tuple with an empty time vector for type consistency.
    return (component_data, Float64[])
end


# Recursive Case: This handles any level of nesting (e.g., Vector{Vector{...}})
function extractData(
    all_series_data::Vector,
    selected_key::String,
    selected_comp::Int
)
    num_series = length(all_series_data)
    extracted = Vector{Any}(undef, num_series)

    for i in 1:num_series
        if isassigned(all_series_data, i)
            # RECURSIVE CALL: Julia's multiple dispatch will call this same function
            # if the element is another Vector, or one of the base cases if it's a Tuple or Dict.
            extracted[i] = extractData(all_series_data[i], selected_key, selected_comp)
        else
            extracted[i] = missing
        end
    end

    return filter(!ismissing, extracted)
end

# --- Base Case: We've drilled down to the Tuple containing the data and the time vector. ---
"""
    get_all_times(run_data::Tuple) -> Set{Float64}

The base case for the recursive time extraction. It checks if the first element
of the tuple (the statistic's value) is a vector. If so, it returns the time
vector; otherwise, it returns an empty set.
"""
function get_all_times(run_data::Tuple)
    value, times = run_data
    # Only return the time vector if the corresponding value is also a vector (i.e., time-dependent).
    if isa(value, AbstractVector) && isa(times, AbstractVector{<:Real})
        return Set(times)
    else
        return Set{Float64}() # Return an empty set for scalar stats
    end
end

# --- Recursive Case: For any collection of runs/methods ---
"""
    get_all_times(all_series_data::Vector) -> Set{Float64}

The recursive step. It takes a vector (e.g., of methods, or of runs),
iterates through its elements, and calls `get_all_times` on each one,
collecting all the results into a single Set.
"""
function get_all_times(all_series_data::Vector)
    # This handles any level of nesting (e.g., Vector{Vector{...}})
    
    # Start with an empty set to collect all time points
    times_union = Set{Float64}()

    # Use an indexed loop with an `isassigned` check for robustness.
    for i in 1:length(all_series_data)
        if isassigned(all_series_data, i)
            # RECURSIVE CALL: Julia's multiple dispatch will call this same function
            # if the element is another Vector, or the base case if it's a Tuple.
            union!(times_union, get_all_times(all_series_data[i]))
        end
    end

    return times_union
end


#======================================================================#
#               2. GENERALIZED `update_time_slider!`
#======================================================================#

"""
    update_time_slider!(tSlider, tLabel_text, tData)

Updates the range and value of a time slider based on a potentially nested
collection of time data by calling the recursive `get_all_times` helper.
"""
function update_time_slider!(
    tSlider::Slider,
    extracted_data::AbstractVector # Can be Vector{Vector{...}}, etc.
)
    # Call the recursive helper to get a flat set of all relevant time points.
    all_time_points = get_all_times(extracted_data)

    if !isempty(all_time_points)
        t_min_data, t_max_data = extrema(all_time_points)
        
        # Create a dense range for smooth sliding
        t_range_slider = range(t_min_data, stop=t_max_data, length=max(2, 500))
        
        if tSlider.range[] != t_range_slider
            tSlider.range[] = t_range_slider
        end
        
        current_t_val = clamp(tSlider.value[], t_min_data, t_max_data)
        set_close_to!(tSlider, current_t_val)
    else
        # Default behavior if no time-dependent data is found
        if tSlider.range[] != [0]
            tSlider.range[] = [0]
        end
        set_close_to!(tSlider, 0)
    end
    
    return nothing
end
#======================================================================#
#              3. `calculate_snapshot` FOR TUPLE DATA
#======================================================================#

#======================================================================#
#              FINAL, ROBUST SNAPSHOT CALCULATION
#======================================================================#

# --- Base Case 1: For a single time-dependent run ---
# This is the "workhorse". It takes a single tuple of (value_vector, time_vector)
# and finds the value at the closest time `t`.
function calculate_snapshot(
    run_data::Tuple{<:AbstractVector{<:Real}, <:AbstractVector},
    t_snapshot::Real
)
    series_data, series_times = run_data
    
    if isempty(series_times) || isempty(series_data)
        return eltype(series_data)() # Return an empty vector of the correct type
    end
    
    _, time_idx = findmin(t -> abs(t - t_snapshot), series_times)
    
    return (1 <= time_idx <= length(series_data)) ? series_data[time_idx] : eltype(series_data)()
end

function calculate_snapshot(
    run_data::Tuple{<:AbstractVector{<:AbstractVector}, <:AbstractVector},
    t_snapshot::Real
)
    series_data, series_times = run_data
    
    if isempty(series_times) || isempty(series_data)
        return eltype(series_data)() # Return an empty vector of the correct type
    end
    
    _, time_idx = findmin(t -> abs(t - t_snapshot), series_times)
    
    return (1 <= time_idx <= length(series_data)) ? series_data[time_idx] : eltype(series_data)()
end

# --- Base Case 2: For a single time-independent (scalar) run ---
# If the data is just a number, it doesn't change with time, so we just return it.
function calculate_snapshot(run_data::Tuple{<:Real, <:AbstractVector}, t_snapshot::Real)
    scalar_data, _ = run_data # We ignore the time vector for scalar stats
    return scalar_data
end

# Conversion case from any
function calculate_snapshot(run_data::Tuple{Any, <:AbstractVector}, t_snapshot::Real)
    data = run_data[1]
    if data isa AbstractVector
        return calculate_snapshot(([d for d = data], run_data[2]), t_snapshot)
    elseif data isa Real
        return calculate_snapshot((data, run_data[2]), t_snapshot)
    else
        @error "Unsupported Type $(typeof(data)) found in the run_data!"
    end
end

# --- Recursive Case: For any collection of runs/methods ---
# This function takes a vector (e.g., of methods), iterates through it, and calls
# the appropriate `calculate_snapshot` method for each element.
function calculate_snapshot(
    all_series_data::Vector,
    t_snapshot::Real
)
    num_series = length(all_series_data)
    snapshots = Vector{Any}(undef, num_series)

    # Use an indexed loop with an `isassigned` check for robustness against #undef errors.
    for i in 1:num_series
        if isassigned(all_series_data, i)
            # RECURSIVE CALL: Julia's multiple dispatch will call the correct version of
            # `calculate_snapshot` based on the type of the element `all_series_data[i]`.
            # If it's another Vector, this function calls itself.
            # If it's a Tuple, it calls one of the base cases above.
            snapshots[i] = calculate_snapshot(all_series_data[i], t_snapshot)
        else
            snapshots[i] = missing
        end
    end

    return filter(!ismissing, snapshots)
end

# --- Top-Level Convenience Function for X and U data ---
"""
    calculate_snapshot(x_data, u_data, t_data, t_snapshot) -> Tuple

The main entry point for calculating snapshots for both x and u data.
This version assumes `x_data` and `u_data` contain the necessary time info
and no longer requires a separate `t_data` argument.
"""
function calculate_snapshot(x_data, u_data, t_snapshot::Real)
    # The recursive helper function is called for both x and u data.
    x_snapshots = calculate_snapshot(x_data, t_snapshot)
    u_snapshots = calculate_snapshot(u_data, t_snapshot)
    return (x_snapshots, u_snapshots)
end


"""
    create_parameter_observables(sim_config) -> Tuple

Creates the observable dictionaries for both shared and method-specific
parameters from a `SimulationConfig` object.

It correctly handles `Tuple` types to ensure type stability for the observables,
which is important for Makie's widgets.

# Arguments
- `sim_config::SimulationConfig`: The simulation configuration containing the
  parameter dictionaries.

# Returns
- A `Tuple` containing:
    - `shared_params_obs::Dict{String, Observable}`
    - `method_params_collection_obs::Dict{String, Dict{String, Observable}}`
"""
function create_parameter_observables(sim_config)
    # --- Create Observable dictionary for SHARED parameters ---
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        # Explicitly type the observable for tuples to help Makie's Textbox
        if isa(val, Tuple)
            shared_params_obs[key] = Observable{Tuple}(val)
        else
            shared_params_obs[key] = Observable(val)
        end
    end

    # --- Create NESTED Observable dictionary for METHOD-SPECIFIC parameters ---
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            if isa(param_val, Tuple)
                inner_obs_dict[param_key] = Observable{Tuple}(param_val)
            else
                inner_obs_dict[param_key] = Observable(param_val)
            end
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    return shared_params_obs, method_params_collection_obs
end

function create_ui_observables(ui_options)
    ui_options_obs = Dict{String, Observable}()
    for (key, val) in ui_options
        # Explicitly type the observable for tuples to help Makie's Textbox
        if isa(val, Tuple)
            ui_options_obs[key] = Observable{Tuple}(val)
        else
            ui_options_obs[key] = Observable(val)
        end
    end
    return ui_options_obs
end
# """
#     is_time_dependent(extracted_data) -> Bool

# Checks if a collection of extracted statistic data is time-dependent.
# It iterates through the data and returns `true` if it finds any value that is
# an AbstractVector, which signifies a time series.
# """
# function is_time_dependent(extracted_data::Vector{<:Vector})
#     # Use indexed loops for safety against #undef entries
#     for i in eachindex(extracted_data)
#         if isassigned(extracted_data, i)
#             for val in extracted_data[i]
#                 if !ismissing(val) && isa(val, AbstractVector)
#                     return true # Found a vector, so it's time-dependent
#                 end
#             end
#         end
#     end
#     return false # No vectors found, so it's time-independent
# end



# """
#     update_time_slider!(tSlider, tLabel_text, time_range_data, all_time_points)

# Updates the range and value of a time slider based on the union of all
# available time points from a dataset. Also updates a corresponding label text observable.
# """
# function update_time_slider!(
#     tSlider::Slider,
#     tLabel_text::Observable{String},
#     all_time_points::Set{Float64}
# )

#     if !isempty(all_time_points)
#         t_min_data, t_max_data = extrema(all_time_points)
        
#         # Create a dense range for smooth sliding
#         t_range_slider = range(t_min_data, stop=t_max_data, length=max(2, 500))
        
#         if tSlider.range[] != t_range_slider
#             tSlider.range[] = t_range_slider
#         end
        
#         current_t_val = clamp(tSlider.value[], t_min_data, t_max_data)
#         set_close_to!(tSlider, current_t_val)
#     else
#         # Default behavior if no time data is found
#         if tSlider.range[] != [0]
#             tSlider.range[] = [0]
#         end
#         set_close_to!(tSlider, 0)
#     end
    
#     tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"
#     return nothing
# end

# #======================================================================#
# #         2. `update_time_dependence!` FOR TUPLE DATA
# #======================================================================#

# """
#     update_time_dependence!(is_time_dependent_obs, tSlider, tLabel, extracted_data)

# Checks for time dependence by inspecting the first element of each data tuple.
# """
# function update_time_dependence!(
#     is_time_dependent_obs::Observable{Bool},
#     tSlider::Slider,
#     tLabel::Label,
#     extracted_data::Vector{<:Vector{<:Tuple}}
# )
#     found_vector = false
#     # Use indexed loops for safety against #undef entries
#     for i in eachindex(extracted_data)
#         if isassigned(extracted_data, i)
#             for j in eachindex(extracted_data[i])
#                 if isassigned(extracted_data[i], j)
#                     # Destructure the tuple to get the value
#                     val, _ = extracted_data[i][j]
#                     if !ismissing(val) && isa(val, AbstractVector)
#                         found_vector = true
#                         break
#                     end
#                 end
#             end
#         end
#         if found_vector; break; end
#     end
#     is_td = found_vector
#     is_time_dependent_obs[] = is_td

#     # Update Time Slider UI
#     if is_td
#         all_times_union = Set{Float64}()
#         for method_data in extracted_data, data_point in method_data
#             # Destructure to get the time vector (second element)
#             _, times = data_point
#             if isa(times, AbstractVector) && !isempty(times)
#                 union!(all_times_union, times)
#             end
#         end
#         # ... (rest of your slider update logic using all_times_union)
#     else
#         tLabel.text[] = "t = N/A (Scalar Stat)"
#         tSlider.range[] = [0]
#         tSlider.value[] = 0
#     end
# end

# """
#     update_time_dependence!(is_time_dependent_obs, tSlider, tLabel, extracted_data)

# Checks for time dependence by inspecting the first element of each data tuple.
# """
# function update_time_dependence!(
#     is_td::Bool,
#     tSlider::Slider,
#     tLabel::Label,
#     extracted_data::Vector{<:Vector{<:Tuple}}
# )
#     # Update Time Slider UI
#     if is_td
#         all_times_union = Set{Float64}()
#         for method_data in extracted_data, data_point in method_data
#             # Destructure to get the time vector (second element)
#             _, times = data_point
#             if isa(times, AbstractVector) && !isempty(times)
#                 union!(all_times_union, times)
#             end
#         end
#         # ... (rest of your slider update logic using all_times_union)
#     else
#         tLabel.text[] = "t = N/A (Scalar Stat)"
#         tSlider.range[] = [0]
#         tSlider.value[] = 0
#     end
# end
# """
#     updateData!(extracted_stat_data, all_raw_data, selected_key)

# Extracts the data for a selected statistic from a raw data store. This version
# is fully general and handles cases where different methods may have been run
# with a different number of parameter variations.
# """
# function updateData!(
#     extracted_stat_data::Observable,
#     all_raw_data::Vector{<:Vector{<:Any}},
#     selected_key::String
# )
#     # --- Guard Clauses ---
#     if isempty(all_raw_data) || selected_key == "calculating..." || selected_key == "No common stats"
#         extracted_stat_data[] = []
#         return
#     end

#     println("Extracting 1D data for statistic: '$selected_key'")
    
#     active_num = length(all_raw_data)
#     # The new data structure will hold vectors of varying lengths.
#     temp_extracted_data = Vector{Any}(undef, active_num)

#     for i in 1:active_num
#         method_data = all_raw_data[i]
#         # Get the number of parameters for THIS SPECIFIC method run.
#         num_params_for_method = length(method_data)
        
#         # Pre-allocate the vector for this specific method's results.
#         method_results = Vector{Any}(undef, num_params_for_method)
        
#         for j in 1:num_params_for_method
#             raw_data = method_data[j]
#             # The raw data point is a tuple, e.g., (stats_dict, time_vector)
#             if isa(raw_data, Tuple)
#                 stat_val = get(raw_data[1], selected_key, missing)
#                 method_results[j] = (stat_val,raw_data[2])
#             else
#                 stat_val = get(raw_data, selected_key, missing)
#                 method_results[j] = stat_val
#             end
#         end
#         temp_extracted_data[i] = method_results
#     end
    
#     # Update the observable with the newly extracted data.
#     extracted_stat_data[] = temp_extracted_data
#     notify(extracted_stat_data)
# end

# function updateData!(
#     extracted_stat_data::Observable,
#     all_raw_data::Vector{<:Union{Dict, Tuple}},
#     selected_key::String
# )
#     # --- Guard Clauses ---
#     if isempty(all_raw_data) || selected_key == "calculating..." || selected_key == "No common stats"
#         extracted_stat_data[] = []
#         return
#     end

#     println("Extracting 1D data for statistic: '$selected_key'")
#     println(typeof(all_raw_data))
#     active_num = length(all_raw_data)
#     # The new data structure will hold vectors of varying lengths.
#     method_results = Vector{Any}(undef, active_num)

#     for i in 1:active_num
#         raw_data = all_raw_data[i]
#         # The raw data point is a tuple, e.g., (stats_dict, time_vector)
#         if isa(raw_data, Tuple)
#             stat_val = get(raw_data[1], selected_key, missing)
#             method_results[i] = (stat_val,raw_data[2])
#         else
#             stat_val = raw_data[selected_key]
#             method_results[i] = stat_val
#         end
#     end
    
#     # Update the observable with the newly extracted data.
#     extracted_stat_data[] = method_results

# end

# """
#     is_time_dependent(extracted_data) -> Bool

# Internal helper that checks if an extracted dataset contains any vectors,
# which signifies time-dependence.
# """
# function is_time_dependent(extracted_data::Vector)
#     for method_data in extracted_data
#         # This check is crucial to prevent errors on uninitialized data
#         if isassigned(method_data, 1:length(method_data))
#             for val in method_data
#                 if !ismissing(val) && isa(val, AbstractVector)
#                     return true # Found a vector, so it's time-dependent
#                 end
#             end
#         end
#     end
#     return false # No vectors found
# end

# """
#     calculate_snapshot(extracted_data, t, is_time_dependent) -> Vector{Vector{Float64}}

# Calculates a "snapshot" of data at a specific time `t`.

# It takes the extracted data for a single statistic, where each data point is a
# tuple containing the value and its corresponding time vector.

# # Arguments
# - `extracted_data`: The data for a single statistic, with structure
#   `Vector{Vector{Tuple{Any, Vector{Float64}}}}`.
# - `t::Real`: The current time value from the time slider.
# - `is_time_dependent::Bool`: A flag indicating if the current statistic is a time series.

# # Returns
# - A `Vector{Vector{Float64}}` containing the calculated snapshot data, ready for plotting.
# """
# function calculate_snapshot(
#     extracted_data::Vector{Vector{Tuple{Any, Vector{Float64}}}},
#     t::Real,
#     is_time_dependent::Bool
# )
#     if isempty(extracted_data)
#         return Vector{Vector{Float64}}()
#     end

#     active_num = length(extracted_data)
#     snapshot = Vector{Vector{Float64}}(undef, active_num)

#     for i in 1:active_num
#         method_data = extracted_data[i]
#         num_params = length(method_data)
#         y_vals_for_snapshot = Vector{Float64}(undef, num_params)

#         for j in 1:num_params
#             if !isassigned(method_data, j); continue; end

#             # Destructure the tuple to get both the value and its time vector
#             stat_val, times = method_data[j]
#             final_val = NaN # Default to NaN

#             if !ismissing(stat_val)
#                 if is_time_dependent && isa(stat_val, AbstractVector)
#                     # For time-dependent data, find the value at the closest time `t`.
#                     if !isempty(times) && !isempty(stat_val)
#                         _, time_idx = findmin(val -> abs(val - t), times)
#                         if time_idx <= length(stat_val)
#                             final_val = Float64(stat_val[time_idx])
#                         end
#                     end
#                 elseif !is_time_dependent && isa(stat_val, Number)
#                     final_val = Float64(stat_val)
#                 elseif is_time_dependent && isa(stat_val, Number)
#                     # Handle case where a stat is time-dependent overall but this run was scalar
#                     final_val = Float64(stat_val)
#                 end
#             end
#             y_vals_for_snapshot[j] = final_val
#         end
#         snapshot[i] = y_vals_for_snapshot
#     end
    
#     return snapshot
# end

