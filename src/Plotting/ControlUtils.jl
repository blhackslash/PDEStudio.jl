"""
    create_method_checkboxes_figure(possible_methods, active_methods; target_layout_ratio=0.5, cell_size=(150, 30), fig_padding=20) -> (fig, fig_layout)

Creates a separate Figure containing checkboxes for all `possible_methods`. The checkboxes
are connected to the `active_methods` Observable for synchronous toggling.

The figure size and number of rows/columns in the grid are automatically calculated 
to optimize space based on the number of methods and a target layout aspect ratio.
- `target_layout_ratio`: Target ratio of grid rows:grid columns (default 0.5, meaning twice as wide).
- `cell_size`: Estimated pixel size (width, height) for each checkbox+label unit.
"""
function create_method_checkboxes_figure(
    possible_methods::Vector{String},
    active_methods::Observable{Vector{String}};
    target_layout_ratio::Real = 0.5, 
    cell_size::Tuple{Int, Int} = (150, 30),
    fig_padding::Int = 20
)
    # --- 1. Calculate Optimal Layout & Figure Size ---
    total_methods = length(possible_methods)
    
    # Handle edge case for zero or empty inputs safely
    if total_methods == 0 || isempty(possible_methods)
        @warn "No possible methods provided. Unable to create figure."
        return nothing, nothing
    end
    
    # Based on the formula: Rows/Cols ≈ TargetRatio AND Rows*Cols ≈ TotalMethods
    # We solve for columns: Cols ≈ sqrt(TotalMethods / TargetRatio)
    cols = ceil(Int, sqrt(total_methods / target_layout_ratio))
    
    # Safety checks for single-column/single-row cases
    if cols < 1; cols = 1; end
    rows = ceil(Int, total_methods / cols)
    
    # Add one row for the title
    total_rows_with_title = rows + 1
    
    # Calculate physical figure size based on layout and estimated cell sizes
    fig_width = cols * cell_size[1] + fig_padding
    fig_height = total_rows_with_title * cell_size[2] + fig_padding + 10 # extra for title gap

    # --- 2. Create Figure & GridLayout ---
    fig = Figure(size = (fig_width, fig_height))
    fig_layout = fig[1, 1] = GridLayout()
    # Force the title row size, leave others flexible
    rowsize!(fig_layout, 1, Fixed(40)) 

    # --- 3. Add Figure Title ---
    Label(fig_layout[1, 1:cols], "Toggle Active Comparison Methods", fontsize=18, font=:bold, halign=:center)

    # --- 4. Create Grid of Checkboxes & Labels ---
    checkbox_layout = fig_layout[2:total_rows_with_title, 1:cols] = GridLayout()


    # Dictionaries to store widgets for mass updates
    checkbox_widgets = Dict{String, Checkbox}()
    is_internal_bulk_update = Observable(false) # Flag to prevent circular updates

    for (i, method_name) in enumerate(possible_methods)
        # Calculate cell coordinates (r: rows index, c: columns index)
        r = ((i - 1) ÷ cols) + 1
        c = ((i - 1) % cols) + 1
        
        # Sub-layout for Checkbox + Label inside the target cell
        cell_layout = checkbox_layout[r, c] = GridLayout(tellwidth=false, tellheight=false)

        # Create the widgets, initial checked state based on active_methods vector
        cb = Checkbox(cell_layout[1, 1]; checked = (method_name in active_methods[]))
        Label(cell_layout[1, 2], method_name, halign=:right) # User requested right alignment
        
        checkbox_widgets[method_name] = cb
        colsize!(cell_layout, 1, Fixed(30)) # Fixed size for the box itself
        # Remaining area is Auto sized for the label to allow it to right align easily
        colsize!(cell_layout, 2, Auto()) 
        # --- 5. Observer: Update observable when checkbox is clicked (UI -> Observable) ---
        on(cb.checked) do is_checked
            # Only trigger logic if this isn't a bulk update from the manager
            if !is_internal_bulk_update[]
                # Modify active_methods
                curr_list = active_methods[]
                if is_checked
                    # Add
                    method_name ∉ curr_list && (active_methods[] = [curr_list; method_name])
                else
                    # Remove
                    active_methods[] = filter(s -> s != method_name, curr_list)
                end
            end
        end
    end
    # Align all label columns with right alignment, fixed checkbox widths
    for r in 1:rows
        rowsize!(checkbox_layout, r, Fixed(cell_size[2]))
    end
    # --- 6. Bulk Observer: Update all checkboxes when the list changes (Observable -> UI) ---
    on(active_methods) do new_list
        # Apply lock flag
        is_internal_bulk_update[] = true
        
        # Synchronize all checkbox visual states
        for (m_name, cb) in checkbox_widgets
            new_checked_state = (m_name in new_list)
            # Only trigger updates/notify visually if the state actually changes
            if cb.checked[] != new_checked_state
                cb.checked[] = new_checked_state
            end
        end
        
        # Release lock
        is_internal_bulk_update[] = false
    end

    return fig, fig_layout
end

"""
    createAnimationPreview!(layout, manager, plot_dim_obs, selector_widgets, active_params)

Populates a layout with a menu to select a target dimension and a Play/Stop button.
Returns the observable tracking the selected animation target index.
"""
function createAnimationPreview!(
    layout::GridLayout,
    manager::PlotManager,
    active_axes_obs::Observable{Vector{Int}}, # Update signature
    selector_widgets::Vector{Any},
    active_params::Vector{String}
)
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    
    n_params = length(active_params)
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"

    # Dropdown to select the target
    all_opts = [(dim_names[i], i) for i in 1:length(selector_widgets)]
    anim_target_menu = Menu(layout[1, 1], options = all_opts, width=120)
    anim_target_menu.i_selected[] = length(selector_widgets) # Default to Time

    # Play/Stop Button
    play_btn = Button(layout[1, 2], label="Play Preview", width=100, buttoncolor=:lightyellow)
    
    on(is_animating) do animating
        play_btn.label[] = animating ? "Stop Preview" : "Play Preview"
    end

    function check_selection_validity(idx)
        if idx == 0 || isnothing(idx)
            @warn "Animation Error: No target selected."
            return false
        end
        if idx in active_axes_obs[]
            @warn "Animation Error: Cannot animate '$(dim_names[idx])' because it is an active plotting axis."
            return false
        end
        widget = selector_widgets[idx]
        if !(widget isa Slider)
            @warn "Animation Error: '$(dim_names[idx])' is a discrete Menu. Only Sliders can be animated."
            return false
        end
        if length(widget.range[]) < 2
            @warn "Animation Error: Slider for '$(dim_names[idx])' has no range to animate."
            return false
        end
        return true
    end

    on(play_btn.clicks) do _
        if is_animating[]
            is_animating[] = false
            !isnothing(animation_timer[]) && close(animation_timer[])
            animation_timer[] = nothing
        else
            target_idx = anim_target_menu.selection[]
            !check_selection_validity(target_idx) && return
            
            target_widget = selector_widgets[target_idx]
            is_animating[] = true
            
            duration = manager.ui["Various"]["animation_duration_s"][]
            fps = manager.ui["Various"]["animation_fps"][]
            rng = target_widget.range[]
            start_time = time()
            
            animation_timer[] = Timer(0.0, interval = 1/fps) do t
                if !is_animating[]
                    close(t); return
                end
                elapsed = mod(time() - start_time, duration)
                progress = elapsed / duration
                val = rng[1] + progress * (rng[end] - rng[1])
                set_close_to!(target_widget, val)
            end
        end
    end

    return anim_target_menu.selection
end

"""
    createExportOptions!(...)

Populates a layout with a filename textbox and save buttons for Images and GIFs.
"""
function createExportOptions!(
    layout::GridLayout,
    plot_fig::Figure,
    manager::PlotManager,
    anim_target_obs::Observable,
    active_axes_obs::Observable{Vector{Int}}, # Update signature
    selector_widgets::Vector{Any},
    active_params::Vector{String}
)
    n_params = length(active_params)
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"

    # UI Layout: [ Filename Box ] [ Save Image ] [ Save GIF ]
    saveBox = Textbox(layout[1, 1], placeholder = "Filename...", width=150)
    btn_img = Button(layout[1, 2], label="Save Image", buttoncolor=:lightblue, width=100)
    btn_gif = Button(layout[1, 3], label="Save GIF", buttoncolor=:lightgreen, width=100)

    # Helper: Validation for GIF export
    function check_selection_validity(idx)
        if idx == 0 || isnothing(idx)
            @warn "Export Error: No target selected in Animation Preview."
            return false
        end
        if idx in active_axes_obs[]
            @warn "Animation Error: Cannot animate '$(dim_names[idx])' because it is an active plotting axis."
            return false
        end
        widget = selector_widgets[idx]
        if !(widget isa Slider)
            @warn "Export Error: '$(dim_names[idx])' is a discrete Menu. Only Sliders can be animated."
            return false
        end
        if length(widget.range[]) < 2
            @warn "Export Error: Slider for '$(dim_names[idx])' has no range to animate."
            return false
        end
        return true
    end

    # --- Image Save Logic ---
    on(btn_img.clicks) do _
        base_name = string(strip(saveBox.stored_string[]))
        if isempty(base_name)
            @info "No filename provided, using default 'plot_export'"
            base_name = "plot_export"
        end

        save_dir = joinpath(get_save_path(), "figures")
        if manager.ui["Various"]["create_savefolder"][]
            save_dir = joinpath(save_dir, base_name)
        end
        mkpath(save_dir)

        formats = manager.ui["Various"]["save_formats"][]
        for fmt in formats
            ext = lowercase(strip(fmt))
            full_path = joinpath(save_dir, base_name * ".$ext")
            
            if ext in ["pdf", "svg"]
                CairoMakie.activate!()
                save(full_path, plot_fig)
                GLMakie.activate!() 
            else
                save(full_path, plot_fig)
            end
        end

        metadata_general = Dict("Save Type" => "Static Frame", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
        saveParametersToCSV(base_name, save_dir, manager, metadata_general)
        @info "Image saved successfully as $(base_name)!"
        
        saveBox.stored_string = "" # Reset
    end

    # --- GIF Save Logic ---
    on(btn_gif.clicks) do _
        target_idx = anim_target_obs[]
        !check_selection_validity(target_idx) && return
        
        target_widget = selector_widgets[target_idx]
        
        base_name = string(strip(saveBox.stored_string[]))
        if isempty(base_name)
            @info "No filename provided, using default 'anim_export'"
            base_name = "anim_export"
        end
        
        save_path = joinpath(get_save_path(), "animations")
        mkpath(save_path)
        fname = joinpath(save_path, base_name * ".gif")
        
        duration = manager.ui["Various"]["animation_duration_s"][]
        fps = manager.ui["Various"]["animation_fps"][]
        rng = target_widget.range[]
        n_frames = Int(duration * fps)
        
        @info "Recording '$(dim_names[target_idx])' animation to $fname..."
        try
            record(plot_fig, fname, range(rng[1], rng[end], length=n_frames); framerate=fps) do val
                set_close_to!(target_widget, val)
                yield() 
            end
            metadata_general = Dict("Save Type" => "Animation", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
            saveParametersToCSV(base_name, save_path, manager, metadata_general) 
            @info "GIF Saved Successfully."
            if !isnothing(plot_fig); display(plot_fig) end
        catch e
            @error "GIF Recording Failed" exception=(e, catch_backtrace())
        end
        
        saveBox.stored_string = "" # Reset
    end
end

"""
    attach_plot_controls!(target_layout::GridLayout, plot_data_dict)

Clears the designated slot and populates it with dynamic plot controls.
Handles the deletion of both UI Blocks and nested GridLayouts.
"""
function attach_plot_controls!(target_layout::GridLayout, plot_data_dict)
# 1. Clean the slot robustly with a recursive helper
    function delete_blocks!(layout)
        # Using copy() is crucial because deleting modifies the underlying collection
        for c in copy(contents(layout))
            if c isa Makie.Block
                delete!(c)
            elseif c isa GridLayout
                delete_blocks!(c) # Dive into nested layouts
            end
        end
    end
    
    # 2. Reset the row/col sizes of the parent layout 
    # (otherwise old row definitions persist)
    trim!(target_layout)

    # 3. Re-populate
    menu_area = target_layout[1, 1] = GridLayout()
    slider_area = target_layout[2, 1] = GridLayout()
    
    # Return the observables from your existing function
    return create_plot_controls!(menu_area, slider_area, plot_data_dict)
end

function createMethodCheckboxes!(layout, methods_obs::Observable, mgr::PlotManager)
    # Get all scopes in simulation except 'shared'
    all_method_names = filter(k -> k != "shared", collect(keys(mgr.simulation)))
    sort!(all_method_names)
    
    # Call your existing checkbox creation logic
    # (assuming createMethodCheckboxes is the function from your PlottingUtils.jl)
    createMethodCheckboxes(layout, methods_obs, all_method_names)
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

"""
    create_base_overwrite_controls!(layout, manager)

Creates a UI block with a Menu to select a base variable and a Textbox to 
overwrite its type with a fixed numeric value. Inputting 'default' restores 
the original widget type (slider/menu).
"""
function create_base_overwrite_controls!(
    layout::GridLayout, 
    manager::PlotManager, 
    plot_data_obs::Observable
)
    # 1. Setup Labels and Widgets
    menu_var = Menu(layout[1, 1], options = ["-"], width = 120, prompt = "Select...")
    menu_var.i_selected[] = 0
    tb_val = Textbox(layout[1, 2], placeholder = "Val / 'default'", width = 120)
    apply_btn = Button(layout[1, 3], label = "Apply", buttoncolor = :lightgray)

    # 2. REACTIVE LOGIC: Update Options based on Data Shape
    on(plot_data_obs) do plot_data_dict
        isempty(plot_data_dict) && return
        
        active_methods = manager.methods[]
        n_params = length(manager.plot_vars) - 5 # 5 Base Variables
        
        valid_base_names = String[]
        
        for (i, name) in enumerate(VariableNames)
            tensor_dim = n_params + i
            
            # Check if this dimension has size > 1 in any active method
            has_variation = false
            for m in active_methods
                if haskey(plot_data_dict, m)
                    u_tensor = plot_data_dict[m].data["u"]
                    if size(u_tensor, tensor_dim) > 1
                        has_variation = true
                        break
                    end
                end
            end
            
            # We MUST also include it if the user currently has it fixed (so they can un-fix it)
            is_fixed_by_user = manager.controls["base_types"][][i] isa Number
            
            if has_variation || is_fixed_by_user
                push!(valid_base_names, name)
            end
        end
        
        current_sel = menu_var.selection[]
        menu_var.options[] = isempty(valid_base_names) ? ["-"] : valid_base_names
        
        if current_sel == "-" || isnothing(current_sel) || current_sel ∉ valid_base_names
            menu_var.i_selected[] = isempty(valid_base_names) ? 0 : 1
        else
            menu_var.i_selected[] = findfirst(isequal(current_sel), valid_base_names)
        end
    end

    # 3. Apply Button Logic
on(apply_btn.clicks) do _
        var_name = menu_var.selection[]
        input_str = tb_val.stored_string[]
        
        if isnothing(var_name) || var_name == "-" || isempty(input_str)
            @warn "Overwrite Error: Please select a variable and provide an input."
            return
        end

        idx = findfirst(isequal(var_name), VariableNames)
        isnothing(idx) && return
        
        vt = copy(manager.controls["base_types"][])
        
        # Check against Active Plot Axes [cite: 60]
        n_params = length(manager.plot_vars) - 5
        abs_idx = n_params + idx
        if abs_idx in manager.controls["Active_Axes"][]
            @warn "Cannot fix the value of an active Plot Axis! Change the Plot Axes before fixing the value!"
            return
        end

        if lowercase(strip(input_str)) == "default"
            vt[idx] = VariableControls[idx]
            @info "Restored default control for $var_name."
        else
            # --- THE SMART PARSER ---
            # 1. Try Integer first (represents a direct Index)
            val = tryparse(Int, input_str)
            
            # 2. Try Float if Int fails (represents a Physical Coordinate)
            if isnothing(val)
                val = tryparse(Float64, input_str)
            end
            
            if isnothing(val)
                @warn "Invalid Input: '$input_str' is not a number or 'default'."
                return
            end
            
            vt[idx] = val
            @info "Fixed $var_name to $(val isa Integer ? "index" : "coordinate"): $val."
        end
        
        manager.controls["base_types"][] = vt
        manager.controls["Simulation_Update"][] += 1
        tb_val.stored_string[] = ""
    end
end

"""
    apply_scene_state!(manager::PlotManager, saved_state::Dict)

Programmatically updates UI widgets to match a saved configuration.
"""
function apply_scene_state!(manager::PlotManager, saved_state::Dict)
    for (key, val) in saved_state
        if haskey(manager.controls, key)
            obs = manager.controls[key]
            
            # If it's a Slider, use set_close_to! to update the physical handle
            # We find the slider via the manager's widget references (if stored)
            # or simply update the observable value directly.
            if endswith(key, "_Value")
                obs[] = val
            elseif endswith(key, "_Selection")
                obs[] = string(val)
            end
        end
    end
end

"""
    get_base_scene_options() -> Dict{String, Any}

Returns the fallback/default configuration for the UI menus and sliders.
These values are used as a base and can be overwritten by user input.
"""
function get_base_scene_options()
    return Dict{String, Any}(
        # 1. Main Axis Selections
        "X-Axis_Selection"      => "x",      # Standard spatial coordinate
        "U-Axis_Selection"      => "u",      # THE FIX: Updated from Y-Axis to U-Axis
        
        # 2. Base Variable Defaults (Set to 1 to snap to the minimum value)
        "c_Selection"   => 1,        
        "t_Value"       => 1,        # THE FIX: Was 25
        "x_Value"       => 1,        # THE FIX: Was 50
    )
end
"""
    set_defaults!(manager::PlotManager, scene_options::Dict)

Safely initializes UI widgets. Programmatically sets Menus by finding the target index 
and modifying `i_selected[]`, and moves Sliders using `set_close_to!`.
"""
function set_defaults!(manager::PlotManager, scene_options::Dict)
    isempty(scene_options) && return

    # --- 1. STRICT RESOLUTION ORDER FOR MENUS ---
    priority_keys = ["X-Axis", "Y-Axis", "Plot-Along"]

    for key in priority_keys
        sel_key = "$(key)_Selection"
        widget_key = "$(key)_Widget"

        (!haskey(scene_options, sel_key) || !haskey(manager.controls, widget_key)) && continue

        desired_value = scene_options[sel_key]
        widget = manager.controls[widget_key][]
        opts = widget.options[]
        isempty(opts) && continue

        # If options are normal Strings (like X-Axis): ["x", "u", "t"]
        idx = findfirst(v -> string(v) == string(desired_value), opts)

        # If not found, check if the user passed an integer index directly as a fallback
        if isnothing(idx) && desired_value isa Integer && 1 <= desired_value <= length(valid_values)
            idx = desired_value
        end
        
        # Ultimate fallback to 1 if nothing matches
        if isnothing(idx)
            @warn "Plot Along Fallback was set!"
            idx = 1 
        else
            idx = idx
        end
        
        # Trigger Makie natively by setting the internal index pointer!
        widget.i_selected[] = idx
    end

    # --- 2. RESOLVE SLIDERS & COMPONENT MENUS ---
# --- 2. RESOLVE SLIDERS & COMPONENT MENUS ---
    for (key, desired_value) in scene_options
        if endswith(key, "_Value") || endswith(key, "_Selection")
            base_name = replace(key, r"(_Value|_Selection)" => "")
            widget_key = "$(base_name)_Widget"

            if haskey(manager.controls, widget_key)
                
                # THE FIX 1: Unwrap the Observable to get the physical widget!
                widget = manager.controls[widget_key][] 

                if widget isa Slider
                    rng_key = "$(base_name)_Range"
                    rng = manager.controls[rng_key][]
                    isempty(rng) && continue

                    val = Float64(rng[1])
                    if (desired_value isa Real) && (rng[1] <= desired_value <= rng[end])
                        val = Float64(desired_value)
                    elseif desired_value isa Integer && 1 <= desired_value <= length(rng)
                        val = Float64(rng[desired_value])
                    end
                    
                    # THE FIX 2: Pass the widget itself to set_close_to!, not widget.value
                    set_close_to!(widget, val)

                elseif widget isa Menu
                    opts = manager.controls["$(base_name)_Options"][]
                    isempty(opts) && continue
                    
                    is_tuple_opts = !isempty(opts) && opts[1] isa Tuple
                    valid_values = is_tuple_opts ? [o[2] for o in opts] : opts

                    idx = findfirst(v -> string(v) == string(desired_value), valid_values)
                    idx = isnothing(idx) ? 1 : idx
                    
                    widget.i_selected[] = idx
                end
            end
        end
    end
end

