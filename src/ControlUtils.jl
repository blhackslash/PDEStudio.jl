
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