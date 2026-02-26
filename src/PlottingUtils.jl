using CairoMakie
using Printf
using Statistics
using LibGit2

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


#======================================================================#
#              2. WIDGET CREATION LOGIC
#======================================================================#

"""
    shouldCreateWidget(val)

Determines if a value is of a type that should have an interactive
widget created for it (i.e., it's an Atomic or an AtomicTuple).
"""
function shouldCreateWidget(val)
    if isa(val, AtomicType)
        return true
    elseif isa(val, Tuple)
        # Check if all elements of the tuple are of Atomic type.
        return all(x -> isa(x, AtomicType), val)
    else
        return false
    end
end


"""
    add_param_as_nested_grid!(...)

Creates a UI element (Label, Toggle, or Textbox) for a given parameter
observable. This version uses the robust `parseValue` function for Textbox validation
and updates.
"""
function add_param_as_nested_grid!(
    parent_cell_for_item,
    key_name::String,
    param_obs::Observable,
    is_toggle::Bool,
    is_fixed_const::Bool,
    label_fontsize::Int,
    p_internal_item_colgap::Int
)
    item_layout = parent_cell_for_item[] = GridLayout(tellwidth=false)
    colgap!(item_layout, p_internal_item_colgap)

    val = param_obs[]
    
    Label(item_layout[1,1], 
          (is_fixed_const ? "(fixed) " : "") * key_name * (is_toggle ? "" : " ="), 
          halign=:right, fontsize=label_fontsize, padding=(0, 2, 0, 0))

    if is_fixed_const
        Label(item_layout[1,2], string(val), halign=:left, fontsize=label_fontsize)
    elseif is_toggle
        tgl = Toggle(item_layout[1,2], active = isa(val, Bool) ? val : false)
        on(tgl.active) do active_val
            if param_obs[] != active_val; param_obs[] = active_val; end
        end
    else # It's a Textbox for an Atomic or AtomicTuple
        val_str = string(val)
        # 1. If the string representation is empty, use a safe, non-empty placeholder.
        placeholder_str = isempty(strip(val_str)) ? "<empty>" : val_str

        # 2. The validator must understand that "<empty>" should be treated as "".
        validator = s -> begin
            input_to_parse = s == "<empty>" ? "" : s
            parsed = parseValue(input_to_parse)
            isa(parsed, typeof(val)) || isa(val, String) || isa(val, Tuple)
        end

        # 3. Create the Textbox with the SAFE placeholder.
        tb = Textbox(item_layout[1,2],
                     placeholder = placeholder_str,
                     validator = validator,
                     width = Auto(),
                     reset_on_defocus=true)
        
        # 4. The update logic must also handle the special placeholder.
        on(tb.stored_string) do s
            input_to_parse = (s == "<empty>") ? "" : s
            parsed_val = parseValue(input_to_parse)
            if param_obs[] != parsed_val
                param_obs[] = parsed_val
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
    title_str::String,
    params_obs_dict::Dict{String, Observable}, # Should be Dict{String, Observable}
    num_param_columns::Int,
    target_fig::Figure;
    param_label_fontsize=14,
    header_fontsize=16,
    gap_size=10,
    internal_item_colgap=4,
    fig_size = (500,600),
)
    empty!(target_fig.scene) # Clear all previous content and layouts
    #target_fig = Figure(size = fig_size)
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
        if available_options[1] isa AtomicType
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
    ui_options_obs::Dict{String, Observable},
    scene_obs::Dict{String,Observable}
)
    GLMakie.activate!()

    plot_screen = GLMakie.Screen(title = "Makie Plot")
    # --- Create the SINGLE Parameter Display Figure ---
    params_fig = Figure() # Adjust size as needed
    params_screen = GLMakie.Screen(title = "Makie Parameters")
    base_controls_fig = Figure() # Initial size, will grow as more controls are added
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
        if !GLMakie.isopen(plot_screen)
            plot_screen = GLMakie.Screen(title = "Makie Plot")
            display(plot_screen,plot_fig_ref)
        end
    end
    current_row += 1
    all_method_sorted = sort!(all_method_names)
    # --- Parameter View Selection Menu ---
    Label(fig_layout[current_row, 1], "View Parameters & Options:", fontsize=16, halign=:left)
    current_row += 1
    
    menu_options = ["UI Options"; "Shared Parameters"; all_method_sorted] # Menu items
    # Ensure a default selection if possible, or handle no selection
    #default_selection = isempty(menu_options) ? nothing : menu_options[2]

    param_view_menu = Menu(fig_layout[current_row, 1], options = menu_options)
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
    createSaveFigBox(save_box_layout, plot_fig_ref, shared_params_obs, method_params_collection_obs, methods_obs, ui_options_obs, scene_obs) # (source: 37-45, 62)
    current_row += 1

    # Ensure the fig_layout rows can auto-size based on content added so far
    for i in 1:current_row-1 # -1 because current_row is ready for the next item
        try rowsize!(fig_layout, i, Auto()); catch; end
    end
    # --- Listener for Menu Selection to Repopulate the params_fig ---
    on(selected_param_key_obs) do selected_key
        if selected_key == "Shared Parameters"
            populate_parameter_figure!( # Assuming populate_parameter_figure! is defined
                "Shared Parameters", 
                shared_params_obs, 
                2, params_fig
            )
        elseif selected_key == "UI Options"
            populate_parameter_figure!("UI Style Options", ui_options_obs, 2, params_fig)
        elseif haskey(method_params_collection_obs, selected_key)
            populate_parameter_figure!(
                "$selected_key Parameters", 
                method_params_collection_obs[selected_key], 
                2, params_fig
            )
        else
            empty!(params_fig) # Clear if selection is invalid
            Label(params_fig[1,1], "Select a parameter set to view.", halign=:center)
        end
        if !GLMakie.isopen(params_screen)
            params_screen = GLMakie.Screen(title = "Makie Parameters")
            display(params_screen,params_fig)
        end
    end
    
    #display(GLMakie.Screen(),params_fig)

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
   components = Observable{Tuple}(("u_1",))
   comp_options = lift(components) do comps; ([(name,ind) for (ind,name) = enumerate(comps)]) end # Holds the list of strings for the menu
   sel_comp = Observable{Int}(1) # Holds the final selected value
   
   # This container will hold the menu widget, which will be deleted and recreated
   menu_container = fig_layout[current_row, 1] = GridLayout()
   current_menu_handle = Observable{Union{Nothing, Menu}}(nothing)
   current_row += 1

   # --- REACTIVE LINK: Rebuild the menu whenever the options list changes ---
   # This `on` block is the core of the generalization. It lives here and handles all
   # the UI logic for updating the menu.
   on(ui_update) do _
        if ui_options_obs["comp_names"][] != ("default",) 
            if length(ui_options_obs["comp_names"][]) == length(components[])
                components[] = ui_options_obs["comp_names"][]
            else
                @warn "Could not match components to the given names because of length mismatch!"
            end
        else
            components[] = Tuple(["u_$k" for k = eachindex(components[])])
        end
    end
   on(comp_options) do _
       @info "Updating selection menu with new options..."
       create_or_update_selection_menu!(
           menu_container,
           current_menu_handle,
           comp_options[],
           sel_comp
       )
   end
   display(params_screen,params_fig)
   display(plot_screen, plot_fig_ref)
   display(GLMakie.Screen(title="Makie Controls"), base_controls_fig)
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
                @warn "Invalid input '$s' for parameter '$key' (expected type $target_type): $e"
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
    _value_to_string_for_csv(v)

A robust helper to convert a Julia object to a string for CSV saving,
paying special attention to `Symbol`s to ensure they can be parsed back correctly.
"""
function _value_to_string_for_csv(v)
    # If the value is a Symbol, prepend a colon to its string representation.
    # This saves `:periodic` as the string `":periodic"`.
    if isa(v, Symbol)
        return ":" * string(v)
    end

    if v == ""
        return "<empty>"
    end
    # For all other types (Tuples, Vectors, Numbers, Strings), the default
    # `string` representation is usually a valid Julia expression that
    # `parseValue` can handle.
    return string(v)
end

"""
    saveParametersToCSV(...)

Saves all relevant context, simulation parameters, and UI styling options to a
CSV file using a "tidy" format and robust type serialization.
"""
function saveParametersToCSV(
    base_filename::String,
    save_dir::String,
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}},
    methods_obs::Observable{Vector{String}},
    ui_options_obs::Dict{String, Observable},
    optional_info::Dict,
    scene_obs::Dict,
)::Bool
    if isempty(base_filename); @warn "CSV save skipped: filename is empty."; return false; end

    csv_filename = joinpath(save_dir, base_filename * "_params.csv")
    @info "Saving parameters and UI options to $csv_filename..."

    try
        # --- Initialize vectors for each column of the DataFrame ---
        sections = String[]
        method_names = Union{String, Missing}[]
        parameters = String[]
        values = String[]

        # --- Helper function to push a row ---
        function add_row(section, method, param, value)
            push!(sections, section)
            push!(method_names, method)
            push!(parameters, string(param))
            # Use the new robust string converter here
            push!(values, _value_to_string_for_csv(value))
        end

        # --- Add Data (Context, Shared, Methods, UI) ---
        for key in sort(collect(keys(optional_info))); add_row("Context", missing, key, optional_info[key]); end
        for s_key in sort(collect(keys(scene_obs))); add_row("Scene", missing, s_key, scene_obs[s_key][]); end
        for p_key in sort(collect(keys(shared_params_obs))); add_row("Shared", missing, p_key, shared_params_obs[p_key][]); end
        for ui_key in sort(collect(keys(ui_options_obs))); add_row("UI", missing, ui_key, ui_options_obs[ui_key][]); end
        
        for method_name in sort(methods_obs[])
            if haskey(method_params_collection_obs, method_name)
                for p_key in sort(collect(keys(method_params_collection_obs[method_name])))
                    add_row("Method", method_name, p_key, method_params_collection_obs[method_name][p_key][])
                end
            end
        end

        # --- Convert to DataFrame and write CSV ---
        df_to_save = DataFrame(
            Section = sections,
            MethodName = method_names,
            Parameter = parameters,
            Value = values
        )
        CSV.write(csv_filename, df_to_save)
        
        @info "Parameters and UI options successfully saved."
        return true

    catch e
        @error "Failed to save parameters to CSV ($csv_filename)!" exception=(e, catch_backtrace())
        return false
    end
end

# This function can be added to your plotting_helpers.jl or a similar utility file.


"""
    get_git_info(start_path=".") -> Union{Dict{String, Any}, Nothing}

Inspects the Git repository containing the given path and returns key information
about the current state (HEAD commit). It robustly finds the repository root by
searching upwards from the `start_path`.
"""
function get_git_info(start_path::String = ".")
    try
        # --- Robust Repo Discovery Logic ---
        current_path = abspath(start_path)
        repo_root_path = nothing

        while true
            if isdir(joinpath(current_path, ".git"))
                repo_root_path = current_path
                break
            end
            parent_path = dirname(current_path)
            if parent_path == current_path; break; end
            current_path = parent_path
        end

        if isnothing(repo_root_path)
            @warn "Could not find a .git repository in or above the path: $(abspath(start_path))"
            return nothing
        end
        
        repo = LibGit2.GitRepo(repo_root_path)
        
        # --- Extract Information ---
        head_ref = LibGit2.head(repo)
        commit = LibGit2.peel(LibGit2.GitCommit, head_ref)
        
        # --- THIS IS THE FINAL FIX ---
        # The most robust, idiomatic way to get the hash is to construct a
        # `GitHash` object from the commit, then convert it to a string.
        commit_hash = string(LibGit2.GitHash(commit))
        # --- END OF FIX ---

        commit_summary = LibGit2.summary(commit)
        
        commit_count = try
            parse(Int, readchomp(`git -C $repo_root_path rev-list --count HEAD`))
        catch
            -1 # Indicate count could not be determined
        end

        return Dict{String, Any}(
            "git_commit_hash" => commit_hash,
            "git_commit_count" => commit_count,
            "git_commit_summary" => commit_summary,
            "julia_version" => string(VERSION)
        )
        
    catch e
        @warn "Could not retrieve Git information." exception=(e, catch_backtrace())
        return nothing
    end
end

function saveParametersToCSV(
    base_filename::String,
    save_dir::String,
    manager::PlotManager,
    metadata_general::Dict
)::Bool
    csv_filename = joinpath(save_dir, base_filename * "_params.csv")
    
    try
        cats, scopes, params, vals = String[], String[], String[], String[]

        function add_row(cat, scope, p, v)
            push!(cats, string(cat)); push!(scopes, string(scope))
            push!(params, string(p)); push!(vals, Utils._value_to_string_for_csv(to_value(v)))
        end

        # --- 1. CATEGORY: Metadata ---
        # Scope: General (Timestamp, Save Type)
        for (k, v) in metadata_general; add_row("Metadata", "General", k, v); end
        
        # Scope: Git
        git_info = Utils.get_git_info(pwd()) # Uses your existing util
        if !isnothing(git_info)
            for (k, v) in git_info; add_row("Metadata", "Git", k, v); end
        end

        # Scope: Julia (Versions)
        julia_info = get_julia_info()
        for (k, v) in julia_info; add_row("Metadata", "Julia", k, v); end

        # Scope: Scene (The specific snapshot settings)
        # We flatten the scene dicts (usually manager.scene["Current"])
        for (scope, dict) in manager.scene
            for (k, v) in dict; add_row("Metadata", "Scene", k, v); end
        end

        # --- 2. CATEGORY: Simulation ---
        # Shared params
        for (k, v) in manager.simulation["shared"]
            add_row("Simulation", "shared", k, v)
        end
        # Active method params
        for m_name in manager.methods[]
            if haskey(manager.simulation, m_name)
                for (k, v) in manager.simulation[m_name]
                    add_row("Simulation", m_name, k, v)
                end
            end
        end

        # --- 3. CATEGORY: UI ---
        for (scope, dict) in manager.ui
            for (k, v) in dict; add_row("UI", scope, k, v); end
        end

        CSV.write(csv_filename, DataFrame(Category=cats, Scope=scopes, Parameter=params, Value=vals))
        @info "Metadata and Parameters saved to $csv_filename"
        return true
    catch e
        @error "CSV Save Failed" exception=(e, catch_backtrace())
        return false
    end
end

function createSaveFigBox(target_layout, plot_fig::Figure, manager::PlotManager)
    gb = target_layout[1, 1] = GridLayout()
    Label(gb[1, 1], "Save Image+CSV:", halign=:right)
    saveBox = Textbox(gb[1, 2], placeholder = "Filename", width=200)

    on(saveBox.stored_string) do s
        base_name = string(strip(s))
        if isempty(base_name); return; end

        # Setup directory
        save_dir = joinpath(Utils.get_save_path(), "figures")
        if manager.ui["Various"]["create_savefolder"][]
            save_dir = joinpath(save_dir, base_name)
        end
        mkpath(save_dir)

        # 1. Save Figures (Handle formats)
        formats = manager.ui["Various"]["save_formats"][]
        for fmt in formats
            ext = lowercase(strip(fmt))
            full_path = joinpath(save_dir, base_name * ".$ext")
            
            if ext in ["pdf", "svg"]
                CairoMakie.activate!()
                save(full_path, plot_fig)
                GLMakie.activate!() # Always switch back for interactivity
            else
                save(full_path, plot_fig)
            end
        end

        # 2. Gather General Metadata and Save CSV
        metadata_general = Dict(
            "Save Type" => "Static Frame",
            "Timestamp" => string(Dates.now()),
            "Project Root" => pwd()
        )

        saveParametersToCSV(base_name, save_dir, manager, metadata_general)
        
        saveBox.stored_string = "" # Reset
    end
end

function createMethodCheckboxes(cb_layout::GridLayout, methods_obs::Observable{Vector{String}}, methods::Vector{String}; n = 20)
    
    toLayout = cb_layout[end,1:div(length(methods),n)+1] = GridLayout() # n hard coded atm can be added to ui_dict

    for (i,method) = enumerate(methods)
        j = div(i-1,n) + 1
        Label(toLayout[mod1(i,n),j*2-1], method)
        init_methods = methods_obs[]
        if method in init_methods
            tmp = Checkbox(toLayout[mod1(i,n),j*2], checked = true)
        else
            tmp = Checkbox(toLayout[mod1(i,n),j*2], checked = false)
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
    create_or_update_legend!(fig::Figure, plotted_objects::Vector, 
                             labels::Vector, manager::PlotManager)

Clears any existing Legend from the figure and creates a new one based on the
position specified in the manager's UI "Legend" scope[cite: 1601, 1607].
"""
function create_or_update_legend!(
    fig::Figure, 
    plotted_objects::Vector, 
    labels::Vector, 
    manager::PlotManager
)
   # --- 1. Find and Delete any existing Legend in the Figure ---
    # We search the main layout for any existing Legend block to ensure a clean update[cite: 1149].
    for elem in copy(contents(fig.layout))
        if elem isa Legend
            delete!(elem)
        end
    end

    # --- 2. Get Legend Properties from PlotManager ---
    # Access the scoped observables directly from the manager.
    ui_leg = manager.ui["Legend"]
    ui_axis = manager.ui["Axis"]
    
    position = ui_leg["legend_pos"][]
    title_str = ui_leg["legend"][]
    font_size = ui_axis["font_size"][]

    if isempty(plotted_objects) || isempty(labels)
        # If no items are plotted, clean up the layout and return[cite: 1151].
        try
            trim!(fig.layout) 
        catch e
            # Ignore if layout is already clean
        end
        return
    end

    # --- 3. Create and Place the New Legend ---
    try
        # Convert empty strings to nothing for cleaner Makie titles[cite: 1152].
        final_title = isempty(strip(title_str)) ? nothing : title_str

        if position == "detached"
            # Places the legend in a new column to the right of the axis[cite: 1147, 1153].
            trim!(fig.layout)
            Legend(fig[1, end+1], plotted_objects, labels, final_title;
                tellheight=false,
                merge = true,
                unique = true,
                titlesize=font_size,
                labelsize=font_size
            )
            # Ensure the new column's width is determined by the legend content[cite: 1155].
            colsize!(fig.layout, 2, Auto())
        else
            # Places the legend inside the axis at a specified anchor point[cite: 1148].
            # This uses your existing _parse_legend_position helper[cite: 1144, 1156].
            halign, valign = _parse_legend_position(position)
            
            Legend(fig[1,1], plotted_objects, labels, final_title;
                orientation = :vertical,
                tellheight=false, 
                tellwidth=false,
                halign = halign,
                valign = valign,
                merge = true,
                unique = true,
                titlesize=font_size,
                labelsize=font_size,
                margin=(10, 10, 10, 10)
            )
            # Trim layout to ensure no empty ghost columns remain[cite: 1158].
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
    set_axis_styles!(ax::Axis3, ui_options_obs)

Dynamically switches between 3D perspective and 2D top-down views.
Assumes all required keys exist in `ui_options_obs`.
"""
function set_axis_styles!(
    ax::Axis3,
    ui_options_obs::Dict{String, Observable}
)
    try
        plot_type = ui_options_obs["plot_type"][]
        is_3d_view = plot_type in [:surface, :scatter3d] 

        # --- Common Font Sizes ---
        ax.titlesize = ui_options_obs["title_size"][]
        ax.xlabelsize = ui_options_obs["label_size"][]
        ax.ylabelsize = ui_options_obs["label_size"][]
        ax.xticklabelsize = ui_options_obs["ticklabel_size"][]
        ax.yticklabelsize = ui_options_obs["ticklabel_size"][]

        if is_3d_view
            # --- 3D Perspective Configuration ---
            ax.zlabel = "z"
            ax.zlabelsize = ui_options_obs["label_size"][]
            ax.zticklabelsize = ui_options_obs["ticklabel_size"][]
            
            ax.aspect = (1, 1, 0.6) 
            ax.perspectiveness = 0.5
            #ax.viewmode = :fit

            ax.xgridvisible = true; ax.ygridvisible = true; ax.zgridvisible = true
            ax.xticklabelsvisible = true; ax.yticklabelsvisible = true; ax.zticklabelsvisible = true
            
            # --- 3D Offsets & Pads ---
            ax.xlabeloffset = ui_options_obs["xlabel_offset_3d"][]
            ax.ylabeloffset = ui_options_obs["ylabel_offset_3d"][]
            ax.zlabeloffset = ui_options_obs["zlabel_offset_3d"][]
            

        else
            # Use Mixed alignmode to force padding at the bottom
            b_margin = ui_options_obs["bottom_margin_2d"][]
            
            # Mixed(bottom = X) reserves X pixels at the bottom, shrinking the axis height
            ax.alignmode = Mixed(bottom = b_margin, left = 0, right = 0, top = 0)
            # --- 2D Top-Down Configuration ---
            ax.zlabel = "" 
            ax.zlabelsize = 0
            ax.zticklabelsvisible = false
            ax.zgridvisible = false
            
            ax.perspectiveness = 0.0 
            ax.elevation = pi/2       
            ax.azimuth = -pi/2        
            ax.aspect = :data 

            
            # Move Labels away from the Ticks
            ax.xlabeloffset = ui_options_obs["xlabel_offset_2d"][]
            ax.ylabeloffset = ui_options_obs["ylabel_offset_2d"][]
            
            ax.xgridvisible = true; ax.ygridvisible = true
        end

    catch e
        @warn "Error setting axis styles. A required key might be missing in ui_options_obs." exception=(e, catch_backtrace())
    end
end

function set_scene_options!(scene_obs::Dict{String,Observable}, scene_options::Dict{String,Any})
    for (key, val) = scene_obs
        if haskey(scene_options, key); val[] = scene_options[key] end
    end
end

function save_scene_info!(scene_obs::Dict{String,Observable}, scene_info::Dict{String,Any})
    for (key,val) = scene_obs
        scene_info[key] = to_value(val)
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
        line_for_legend = nothing
        if ui_options_obs["show_lines"][]
            l = lines!(ax, x_data, u_data; 
                color=color, linewidth=ui_options_obs["linewidth"], 
                label=plotLabel, linestyle=linestyle)
            line_for_legend = l
        end
        scatter_for_legend = nothing
        if ui_options_obs["show_scatter"][]
            s = scatter!(ax, x_data, u_data; 
                color=color, markersize=ui_options_obs["markersize"], 
                marker=marker, label=plotLabel)
            scatter_for_legend = s
        end
        
        # Call extrema tracking with the correct data and styling index
        plot_extrema_lines!(ax, x_data, u_data, ui_options_obs, plot_idx)
        vec_for_legend = Any[]
        push!(plotted_objects, vec_for_legend)
        if !isnothing(line_for_legend) 
            push!(vec_for_legend, line_for_legend)
        end
        if !isnothing(scatter_for_legend)
            push!(vec_for_legend, scatter_for_legend)
        end
        if !isempty(vec_for_legend)
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
        plotted_objects,
        labels_for_legend,
        ui_options_obs
    )
    
    return nothing
end

"""
    _find_outlier_indices(matrix::AbstractMatrix, threshold::Real) -> Vector{CartesianIndex}

Identifies the indices of extreme outliers in a matrix using a tunable IQR method.
It works by flattening the matrix and applying the 1D outlier logic.
"""
function _find_outlier_indices(
    matrix::AbstractMatrix,
    threshold::Real
)::Vector{CartesianIndex}
    # Flatten the matrix to a vector to reuse the existing IQR logic
    flat_vector = vec(matrix)
    
    # Get the linear indices of outliers in the flattened vector
    linear_outlier_indices = _find_outlier_indices(flat_vector, threshold)
    
    # Convert the linear indices back to Cartesian indices for the original matrix
    return CartesianIndices(matrix)[linear_outlier_indices]
end


"""
    create_or_update_colorbar!(fig::Figure, ui_options_obs, color_range_obs, label)

Creates a Colorbar explicitly linked to the global colormap and colorrange observables.
This avoids errors when plotting objects like Contours which contain Text elements.
"""
function create_or_update_colorbar!(
    fig::Figure,
    plot_object, # We keep this argument to check if a plot exists, but we won't extract from it
    ui_options_obs::Dict{String, Observable},
    color_range_obs::Observable{Tuple{Float64, Float64}}, # Pass the observable directly
    label::String,
)
    # --- 1. Find and Delete any existing Colorbar ---
    for elem in copy(contents(fig.layout))
        if elem isa Colorbar
            delete!(elem)
        end
    end

    # If no plot was actually created (e.g. empty data), don't draw a colorbar
    if isnothing(plot_object)
        return
    end

    # --- 2. Create the New Colorbar Explicitly ---
    try
        # Instead of passing `plot_object`, we pass the attributes explicitly.
        # This bypasses the "Text" error for contours.
        cb = Colorbar(fig[1, 2];
            colormap = ui_options_obs["colormap"],
            colorrange = color_range_obs,
            label = label,
            labelsize = ui_options_obs["label_size"][],
            ticklabelsize = ui_options_obs["ticklabel_size"][],
            # Optional: Add highclip/lowclip here if you use them in the main plot
        )
        
        # Ensure the colsize adjusts automatically
        colsize!(fig.layout, 2, Auto())
        
    catch e
        @error "Failed to create or update colorbar." exception=(e, catch_backtrace())
    end
end

"""
    set_axis_limits!(ax::Axis3, x_data_tuples, z_data, ui_options_obs)

Calculates and applies final padded limits for x, y, and z axes for a 3D plot.
It decomposes the `x_data_tuples` into separate x and y components and reuses
the 1D limit calculation logic for each axis.
"""
function set_axis_limits!(
    ax::Axis3,
    x_data, # Nested collection of NTuples, e.g., (x,y) points
    z_data,        # Nested collection of Reals, e.g., u(x,y) values
    ui_options_obs::Dict{String, Observable},
    color_range::Observable
)
    try
        # --- 1. Get UI Options ---
        x_padding = ui_options_obs["xpadding"][]
        y_padding = ui_options_obs["ypadding"][]
        # Use `get` to safely access a "zpadding" key, falling back to ypadding if it doesn't exist
        z_padding = get(ui_options_obs, "zpadding", Observable(ui_options_obs["ypadding"][]))[]

        # x_is_log_requested = ui_options_obs["xlogscale"][]
        # y_is_log_requested = ui_options_obs["ylogscale"][]
        # # Axis3 does not support a log z-scale, but we can use the flag for padding calculation
        # z_is_log_requested = get(ui_options_obs, "zlogscale", Observable(false))[]

        # --- 3. Calculate Raw and Padded Limits for Each Axis ---
        raw_xlims = get_raw_global_range(x_data; component = 1)
        raw_ylims = get_raw_global_range(x_data; component = 2)
        raw_zlims = get_raw_global_range(z_data)

        final_xlims = calculate_padded_axis_range(raw_xlims, x_padding, false)
        final_ylims = calculate_padded_axis_range(raw_ylims, y_padding, false)
        final_zlims = calculate_padded_axis_range(raw_zlims, z_padding, false)

        # --- 4. Apply Limits and Scales ---
        # Makie's limits! for Axis3 takes (xmin, xmax, ymin, ymax, zmin, zmax)
        try
            color_range[] = final_zlims
            is_3d_view = ui_options_obs["plot_type"][] in [:surface, :scatter3d]
            real_zlims = is_3d_view ? final_zlims : (-0.1,.1)
            limits!(ax, final_xlims..., final_ylims..., real_zlims...)
            
        catch e
            @warn "Failed to set 3D axis limits." exception=(e, catch_backtrace())
        end

        # # Set scales for X and Y axes (Axis3 does not support `zscale`)
        # ax.xscale[] = final_xlims[1] > 0 && x_is_log_requested ? log10 : identity
        # ax.yscale[] = final_ylims[1] > 0 && y_is_log_requested ? log10 : identity

    catch e
        @error "Failed to set dynamic 3D axis limits. A required UI option key might be missing." exception=(e, catch_backtrace())
    end
    return nothing
end

function irregular_to_grid(x_tuples, u_vals; resolution=100)
    # Extract x and y
    xs = [p[1] for p in x_tuples]
    ys = [p[2] for p in x_tuples]
    
    # Create a grid range
    x_min, x_max = extrema(xs)
    y_min, y_max = extrema(ys)
    
    # Handle case where data is a single point or line to prevent errors
    if x_min == x_max; x_max += 1.0; end
    if y_min == y_max; y_max += 1.0; end

    xg = range(x_min, x_max, length=resolution)
    yg = range(y_min, y_max, length=resolution)
    
    # Initialize grid with NaN (transparent)
    zg = fill(NaN, resolution, resolution)
    
    # Simple Binning (assign point to nearest grid cell)
    # For better results, consider Inverse Distance Weighting or Delaunay via external packages
    x_step = step(xg)
    y_step = step(yg)
    
    for (x, y, z) in zip(xs, ys, u_vals)
        # Map x/y to indices
        i = clamp(round(Int, (x - x_min) / x_step) + 1, 1, resolution)
        j = clamp(round(Int, (y - y_min) / y_step) + 1, 1, resolution)
        
        # Simple overwrite (or use average if multiple fall in same bin)
        zg[i, j] = z
    end
    
    return xg, yg, zg
end

"""
    create_base_plot_2D!(...)

Handles plotting for 2D/3D data using various visualizations (:scatter2d, :surface, :contour, etc.).
"""
function create_base_plot_2D!(
    plot_fig::Figure,
    ax::Axis3,
    active_methods::Vector{String},
    x_snapshot::AbstractVector, 
    u_snapshot::AbstractVector, 
    ui_options_obs::Dict{String, Observable},
    color_range::Observable{Tuple{Float64, Float64}},
    label_obs
)
    # --- Setup and Styling ---
    width, height = ui_options_obs["figsize"][]
    resize!(plot_fig, width, height)
    empty!(ax) # Clear previous plots
    
    if isempty(active_methods)
        create_or_update_colorbar!(plot_fig, nothing, ui_options_obs, color_range, label_obs["colorbar_label"][])
        return nothing
    end
    #main_col_idx = ui_options_obs["main_plot_col"][]
    #colsize!(plot_fig.layout, 1, Auto(1.0))

    # --- Plotting Loop ---
    plotted_objects = []
    labels_for_legend = String[]
    plot_object_for_colorbar = nothing

    # Retrieve the plot type (default to :scatter2d if missing)
    plot_type = get(ui_options_obs, "plot_type", Observable(:scatter2d))[]

    for (i, method_label) in enumerate(active_methods)
        if i > length(x_snapshot) || i > length(u_snapshot); continue; end

        x_data = x_snapshot[i] # Vector{NTuple{2, Float64}}
        u_data = u_snapshot[i] # Vector{Float64} 
        if isempty(x_data) || isempty(u_data); continue; end

        # Handle outlier removal
        u_data_for_plotting = copy(u_data)
        if ui_options_obs["remove_outliers"][]
            outlier_indices = _find_outlier_indices(u_data, ui_options_obs["outlier_threshold"][])
            if !isempty(outlier_indices)
                u_data_for_plotting[outlier_indices] .= NaN
            end
        end

        local current_plot_object

        if plot_type == :scatter3d
            # 3D Scatter (MeshScatter)
            points_xyz = [Point3f(p[1], p[2], val) for (p, val) in zip(x_data, u_data_for_plotting)]
            current_plot_object = meshscatter!(ax, points_xyz; 
                markersize=ui_options_obs["markersize_3d"][], 
                color=u_data_for_plotting, 
                colormap=ui_options_obs["colormap"][], 
                colorrange=color_range, 
                label=method_label
            )

        elseif plot_type == :scatter2d
            # 2D Scatter (Flat on Z plane, or projected)
            # We plot at Z=0 or Z=val depending on preference. 
            # Standard scatter! in Axis3 requires 3D points usually, or it projects.
            # Let's map them to the XY plane explicitly if we want a "pure" 2D look in 3D axis
            points_xy = [Point3f(p[1], p[2], 0.0) for p in x_data] # Plot on floor
            #println(points_xy)
            #error("TEST")
            # OR if you want them floating at their Z-height but looked at from above:
            # points_xy = [Point3f(p[1], p[2], val) for (p, val) in zip(x_data, u_data_for_plotting)]
            
            current_plot_object = scatter!(ax, points_xy; 
                markersize=ui_options_obs["markersize_2d"][], 
                color=u_data_for_plotting, 
                colormap=ui_options_obs["colormap"][], 
                colorrange=color_range, 
                label=method_label
            )

        elseif plot_type in [:surface, :contour, :contourf]
            # Grid-based visualizations
            xg, yg, zg = irregular_to_grid(x_data, u_data_for_plotting; resolution=100)

            if plot_type == :surface
                current_plot_object = surface!(ax, xg, yg, zg; 
                    colormap=ui_options_obs["colormap"][], 
                    colorrange=color_range,
                    label=method_label
                )
            elseif plot_type == :contour
                current_plot_object = contour!(ax, xg, yg, zg; 
                    colormap=ui_options_obs["colormap"][], 
                    colorrange=color_range,
                    levels=ui_options_obs["contour_levels"][], # Or lift from options
                    linewidth=ui_options_obs["linewidth"][],
                    label=method_label
                )
            elseif plot_type == :contourf
                current_plot_object = contourf!(ax, xg, yg, zg; 
                    colormap=ui_options_obs["colormap"][], 
                    colorscale=color_range,
                    levels=ui_options_obs["contour_levels"][],
                    label=method_label
                )
            end
        end
        
        push!(plotted_objects, current_plot_object)
        push!(labels_for_legend, method_label)
        plot_object_for_colorbar = current_plot_object
    end

    # --- Final Touches ---
    if ui_options_obs["update_limits"][]; set_axis_limits!(ax, x_snapshot, u_snapshot, ui_options_obs, color_range) end
    
    create_or_update_colorbar!(plot_fig, plot_object_for_colorbar, ui_options_obs, color_range, label_obs["colorbar_label"][])
    create_or_update_legend!(plot_fig, plotted_objects, labels_for_legend, ui_options_obs)
    
    # Pass the plot_type to the styling function
    set_axis_styles!(ax, ui_options_obs)

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

# --- Method 1: For single-run plots (like showDynamicDependence) ---
"""
    assemble_simulation_tasks(...) -> Tuple{Vector{ParamDictType}, Vector{String}}

Assembles a flat list of parameter dictionaries for a single run of each active method.
Returns the list of tasks and a corresponding list of method names.
"""
function assemble_simulation_tasks(
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}},
    active_methods::Vector{String}
)
    tasks = ParamDictType[]
    for method_name in active_methods
        push!(tasks, assembleParams(shared_params_obs, method_params_collection_obs, method_name))
    end
    return tasks
end

# --- Method 2: For convergence plots (iterating over a parameter) ---
"""
    assemble_simulation_tasks(...) -> Matrix{ParamDictType}

Assembles a matrix of parameter dictionaries for convergence studies.
The rows of the matrix correspond to the `active_methods`, and the columns
correspond to the `param_values`. This structure allows for clean, nested
iteration in subsequent processing steps.
"""
function assemble_simulation_tasks(
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}},
    active_methods::Vector{String},
    key_varied::String,
    param_values::AbstractVector;
    force_int_param::Bool = false
)
    num_methods = length(active_methods)
    num_p_values = length(param_values)

    # Pre-allocate a Matrix to hold the parameter dictionaries.
    tasks = Matrix{ParamDictType}(undef, num_methods, num_p_values)

    # Iterate through methods (rows)
    for (i, method_name) in enumerate(active_methods)
        base_params = assembleParams(shared_params_obs, method_params_collection_obs, method_name)
        
        # Iterate through parameter values (columns)
        for (j, p_val) in enumerate(param_values)
            params_for_this_run = copy(base_params)
            params_for_this_run[key_varied] = force_int_param ? trunc(Int64, p_val) : p_val
            
            # Assign the parameter dictionary to its correct (method, param) position in the matrix.
            tasks[i, j] = params_for_this_run
        end
    end
    
    return tasks
end

"""
    assemble_simulation_tasks(..., key1, val1, key2, val2; ...) -> Matrix{ParamDictType}

Assembles a matrix of parameter dictionaries for 2D convergence studies.
Dimensions: (Num_Methods x Total_Grid_Points).

The columns represent the flattened grid of `param_values1 x param_values2`.
"""
function assemble_simulation_tasks(
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}},
    active_methods::Vector{String},
    key1::String,
    param_values1::AbstractVector,
    key2::String,
    param_values2::AbstractVector;
    force_int_param1::Bool = false,
    force_int_param2::Bool = false
)
    num_methods = length(active_methods)
    # Create the grid logic once to ensure order consistency
    # We flatten (v1, v2) tuples
    param_grid = collect(Iterators.product(param_values1, param_values2)) 
    num_runs = length(param_grid)

    # Pre-allocate Matrix (Methods x Flat_Runs)
    tasks = Matrix{ParamDictType}(undef, num_methods, num_runs)

    # Iterate through methods (rows)
    for (i, method_name) in enumerate(active_methods)
        base_params = assembleParams(shared_params_obs, method_params_collection_obs, method_name)
        
        # Iterate through the flattened grid (columns)
        for (j, (p1_val, p2_val)) in enumerate(param_grid)
            params_for_this_run = copy(base_params)
            
            # Apply values and force int if requested
            params_for_this_run[key1] = force_int_param1 ? trunc(Int64, p1_val) : p1_val
            params_for_this_run[key2] = force_int_param2 ? trunc(Int64, p2_val) : p2_val
            
            tasks[i, j] = params_for_this_run
        end
    end
    
    return tasks
end
#======================================================================#
#              2. ENSURE SIMULATION DATA EXISTS
#======================================================================#
"""
    ensure_sim_data_exists!(tasks, sim_config; force_overwrite=false, parallel=false)

Streamlined version: Iterates (serially or in parallel) over tasks and ensures data exists.
"""
function ensure_sim_data_exists!(
    tasks::Union{Vector{ParamDictType}, Matrix{ParamDictType}},
    sim_config::SimulationConfig;
    force_overwrite::Bool = false,
    parallel::Bool = false
)
    # 1. Flatten tasks for uniform handling (if it's a matrix)
    # generic iteration handles both, but length() works better on a flat view or vec
    all_tasks = vec(tasks)
    num_tasks = length(all_tasks)
    if num_tasks == 0; return; end
    
    @debug "Checking data for $num_tasks simulations..."
    p = Progress(num_tasks; desc = "Running simulations...", showspeed=true)
    counter = Threads.Atomic{Int}(0)

    # 2. Define the core worker function (closure captures config/options)
    function process_task(params)
        try
            if force_overwrite || !doesSimDataExist(params)
                # invokelatest solves world-age issues if new methods were defined recently
                sim_data = Base.invokelatest(sim_config.sim_function, params)
                
                if !isnothing(sim_data)
                    saveSimData(sim_data; overwrite = force_overwrite)
                end
            end
        catch e
            @error "Simulation failed." exception=(e, catch_backtrace())
        end
        # Update progress safely
        Threads.atomic_add!(counter, 1)
        ProgressMeter.update!(p, counter[])
    end

    # 3. Execution Strategy
    if parallel
        Threads.@threads for task in all_tasks
            process_task(task)
        end
    else
        foreach(process_task, all_tasks)
    end
    
    @debug "Simulation check complete."
end


"""
    extract_line_cut_data(x_points, u_values, line_point, line_vector, tolerance_dist)

Extracts a 1D slice of data from a 2D snapshot, preserving all solution components.

It finds all points within a specified orthogonal distance (`tolerance_dist`) of a line
and projects them to get a 1D coordinate. It returns these coordinates along with their
corresponding `u` values, which can be a vector (single component) or a matrix
(multiple components). The new 1D coordinate system is centered at `line_point`.

# Arguments
- `x_points::Vector{NTuple{2, Float64}}`: The (x,y) coordinates of the 2D data.
- `u_values::VecOrMat{<:Real}`: The solution values (Vector or Matrix) at each point.
- `line_point::NTuple{2, <:Real}`: The point `p` that the cut line passes through.
- `line_vector::NTuple{2, <:Real}`: The direction vector `v` of the cut line.
- `tolerance_dist::Real`: The maximum orthogonal distance for a point to be included.

# Returns
- A tuple `(cut_x_coords, cut_u_values::VecOrMat)` containing the sorted 1D data.
"""
function extract_line_cut_data(
    x_points::Vector{NTuple{2, Float64}},
    u_values::VecOrMat{<:Real},
    line_point::NTuple{2, <:Real},
    line_vector::NTuple{2, <:Real},
    tolerance_dist::Real
)
    if isempty(x_points) || isempty(u_values); return (Float64[], eltype(u_values)[]); end

    v_norm = sqrt(line_vector[1]^2 + line_vector[2]^2)
    if v_norm < 1e-9; return (Float64[], eltype(u_values)[]); end
    v_unit = (line_vector[1] / v_norm, line_vector[2] / v_norm)

    p = line_point
    cut_x = Float64[]
    
    # Store indices of points that are part of the cut
    valid_indices = Int[]

    for i in eachindex(x_points)
        q = x_points[i]
        w = (q[1] - p[1], q[2] - p[2])
        
        projected_coord = w[1] * v_unit[1] + w[2] * v_unit[2]
        dist_sq = (w[1]^2 + w[2]^2) - projected_coord^2
        orthogonal_dist = dist_sq > 0 ? sqrt(dist_sq) : 0.0
        
        if orthogonal_dist <= tolerance_dist
            push!(cut_x, projected_coord)
            push!(valid_indices, i)
        end
    end

    if !isempty(valid_indices)
        # Sort the results by the new 1D coordinate
        p = sortperm(cut_x)
        
        # Select and sort the u_values based on the valid indices and permutation
        if u_values isa AbstractMatrix
            cut_u = u_values[valid_indices, :]
            return (cut_x[p], cut_u[p, :])
        else # It's a Vector
            cut_u = u_values[valid_indices]
            return (cut_x[p], cut_u[p])
        end
    else
        # Return empty arrays with the correct type
        empty_u = u_values isa AbstractMatrix ? Matrix{eltype(u_values)}(undef, 0, size(u_values, 2)) : Vector{eltype(u_values)}()
        return (Float64[], empty_u)
    end
end

"""
    set_axis_limits_manager!(ax, xs, us, manager)
Adapted from your old set_axis_limits! to read from manager.ui["Axis"].
"""
function set_axis_limits_manager!(ax::Axis, xs, us, manager::PlotManager)
    ui_axis = manager.ui["Axis"]
    
    # xs/us are now Vectors of the 1D slices for each method
    raw_xlims = (minimum(minimum.(xs)), maximum(maximum.(xs)))
    raw_ylims = (minimum(minimum.(us)), maximum(maximum.(us)))

    final_xlims = calculate_padded_axis_range(raw_xlims, ui_axis["xpadding"][], ui_axis["xlogscale"][])
    final_ylims = calculate_padded_axis_range(raw_ylims, ui_axis["ypadding"][], ui_axis["ylogscale"][])

    limits!(ax, final_xlims..., final_ylims...)
    
    ax.xscale[] = final_xlims[1] > 0 && ui_axis["xlogscale"][] ? log10 : identity
    ax.yscale[] = final_ylims[1] > 0 && ui_axis["ylogscale"][] ? log10 : identity
end

"""
    plot_extrema_lines_manager!(ax, x, u, manager, plot_idx)
Adapted to read colors/styles from manager.ui["Appearance"].
"""
function plot_extrema_lines_manager!(ax, x_data, u_data, manager, plot_idx)
    ui_app = manager.ui["Appearance"]
    ui_various = manager.ui["Various"]
    
    track_max = ui_various["track_max"][]
    track_min = ui_various["track_min"][]
    (!track_max && !track_min) && return

    valid_idx = findall(isfinite, u_data)
    isempty(valid_idx) && return
    
    color = ui_app["colors"][][mod1(plot_idx, end)]
    lw = ui_app["linewidth"][] / 2

    if track_max
        val, i = findmax(u_data[valid_idx])
        pos = x_data[valid_idx[i]]
        linesegments!(ax, [Point2f(pos, 0), Point2f(pos, val)]; color=(color, 0.7), linestyle=:dash, linewidth=lw)
    end
    # ... Similar for track_min ...
end

function update_base_plot_1D!(
    plot_fig::Figure,
    ax::Axis,
    active_methods::Vector{String}, # Labels
    xs_slices::Vector{Vector{Float64}}, # Sliced X data per method
    us_slices::Vector{Vector{Float64}}, # Sliced U data per method
    manager::PlotManager;
    xlabel::Union{String, Nothing} = nothing,    # NEW: Dynamic override
    ylabel::Union{String, Nothing} = nothing,    # NEW: Dynamic override
    title_str::Union{String, Nothing} = nothing  # NEW: Dynamic override
)
    # --- 1. Style & Figure Prep ---
    ui_axis = manager.ui["Axis"]
    ui_app = manager.ui["Appearance"]
    ui_leg = manager.ui["Legend"]
    ui_var = manager.ui["Various"]

    resize!(plot_fig, ui_axis["figsize"][][1], ui_axis["figsize"][][2])
    empty!(ax)
    isempty(active_methods) && return

    # --- 2. Sorting Logic (Matches your original) ---
    sort_key(label) = (contains(lowercase(label), "analytic") ? 0 : 1, label)
    p = ui_leg["sort_legend"][] ? sortperm(active_methods, by=sort_key) : 1:length(active_methods)

    plotted_objects = []
    labels_for_legend = String[]

    # --- 3. Plotting Loop ---
    for (plot_idx, data_idx) in enumerate(p)
        label = active_methods[data_idx]
        x_data = xs_slices[data_idx]
        u_data = us_slices[data_idx]

        # Styles
        color = ui_app["colors"][][mod1(plot_idx, end)]
        marker = ui_app["markers"][][mod1(plot_idx, end)]
        linestyle = ui_app["dashed_lines"][] ? ui_app["lineStyles"][][mod1(plot_idx, end)] : :solid
        lw = ui_app["linewidth"][]

        # Outlier Detection
        if ui_var["mark_outliers"][] || ui_var["remove_outliers"][]
            outlier_idx = _find_outlier_indices(u_data, ui_var["outlier_threshold"][])
            if ui_var["mark_outliers"][]
                vlines!(ax, x_data[outlier_idx]; color=(color, 0.4), linestyle=:dot, linewidth=lw/1.5)
            end
            if ui_var["remove_outliers"][]
                u_data[outlier_idx] .= NaN
            end
        end

        # Lines and Scatter
        objs = []
        if ui_app["show_lines"][]
            l = lines!(ax, x_data, u_data; color=color, linewidth=lw, linestyle=linestyle, label=label)
            push!(objs, l)
        end
        if ui_app["show_scatter"][]
            s = scatter!(ax, x_data, u_data; color=color, markersize=ui_app["markersize"][], marker=marker, label=label)
            push!(objs, s)
        end

        # Max/Min Tracking
        plot_extrema_lines_manager!(ax, x_data, u_data, manager, plot_idx)

        if !isempty(objs)
            push!(plotted_objects, objs)
            push!(labels_for_legend, label)
        end
    end

    # --- 4. Limits, Labels, and Legend ---
    set_axis_limits_manager!(ax, xs_slices, us_slices, manager)
    
# DYNAMIC LABEL LOGIC:
    # Use the passed key if provided, otherwise check UI dict for manual overrides [cite: 698, 699, 700]
    ax.xlabel = ui_axis["xlabel"][] == "default" ? xlabel : ui_axis["xlabel"][]
    ax.ylabel = ui_axis["ylabel"][] == "default" ? ylabel : ui_axis["ylabel"][]
    ax.title  = ui_axis["title"][] == "default" ? title_str : ui_axis["title"][]

    create_or_update_legend!(plot_fig, plotted_objects, labels_for_legend, manager)
end

"""
    generate_dynamic_title(x_key, y_key, dim_idx, manager, dim_names, sel_vals)

Constructs the plot title dynamically. It lists all fixed parameters and base variables,
marks the actively plotted dimension, and allows for a user-defined override via `manager.ui`.
"""
function generate_dynamic_title(
    dim_idx::Int, 
    dim_names::Vector{String}, 
    sel_vals
)
    # 2. Build the Default Dynamic Title
    title_parts = String[]
    
    for i in 1:length(dim_names)
        name = dim_names[i]
        
        if i == dim_idx
            # This is the axis we are currently plotting along (the colon ':' in the tensor slice)
            push!(title_parts, "$name = [Axis]")
        else
            val = sel_vals[i]
            # Format floats neatly to 3 decimal places to prevent title bloat
            val_str = val isa AbstractFloat ? @sprintf("%.3f", val) : string(val)
            push!(title_parts, "$name = $val_str")
        end
    end
    
    # Join all the parts together with a separator
    return join(title_parts, " | ")
end


