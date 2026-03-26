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

function createSaveFigBox(target_layout, plot_fig::Figure, manager::PlotManager)
    gb = target_layout[1, 1] = GridLayout()
    Label(gb[1, 1], "Save Image+CSV:", halign=:right)
    saveBox = Textbox(gb[1, 2], placeholder = "Filename", width=200)

    on(saveBox.stored_string) do s
        base_name = string(strip(s))
        if isempty(base_name); return; end

        # Setup directory
        save_dir = joinpath(get_save_path(), "figures")
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


"""
    createAnimationControls!(...)

Populates a layout with a static target menu. 
Validation occurs when 'Play' or 'Save' is clicked.
"""
function createAnimationControls!(
    layout::GridLayout,
    plot_fig::Figure,
    manager::PlotManager,
    plot_dim_obs::Observable{Int},
    selector_widgets::Vector{Any},
    active_params::Vector{String}
)
    # --- 1. Setup State & Metadata ---
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    
    n_params = length(active_params)
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"

    # --- 2. Build UI Widgets (Static Options) ---
    #Label(layout[1, 1], "Animate Target:")
    
    # We populate the menu ONCE with every possible dimension
    all_opts = [(dim_names[i], i) for i in 1:length(selector_widgets)]
    anim_target_menu = Menu(layout[1, 1], options = all_opts, width=120)
    # Set default to Time (the last index)
    anim_target_menu.selection[] = length(selector_widgets)

    play_btn = Button(layout[1, 2], label="Play", width=60)
    on(is_animating) do animating
        play_btn.label[] = animating ? "Stop" : "Play"
    end
    
    gif_name = Textbox(layout[1, 3], placeholder="filename", width=120)
    gif_name.stored_string = "wave_anim"
    save_btn = Button(layout[1, 4], label="Save GIF", buttoncolor=:lightgreen)

    # --- 3. Validation Helper ---
    function check_selection_validity(idx)
        if idx == 0 || isnothing(idx)
            @warn "Animation Error: No target selected."
            return false
        end
        
        if idx == plot_dim_obs[]
            @warn "Animation Error: Cannot animate '$(dim_names[idx])' because it is currently the plotting axis."
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

    # --- 4. Play/Stop Logic ---
    on(play_btn.clicks) do _
        if is_animating[]
            # Stop existing animation
            is_animating[] = false
            !isnothing(animation_timer[]) && close(animation_timer[])
            animation_timer[] = nothing
        else
            # Validate and Start
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
                
                # Sloop/Cycle logic
                elapsed = mod(time() - start_time, duration)
                progress = elapsed / duration
                val = rng[1] + progress * (rng[end] - rng[1])
                
                # Smoothly scrub the target slider
                set_close_to!(target_widget, val)
            end
        end
    end

    # --- 5. Record Logic ---
    on(save_btn.clicks) do _
        target_idx = anim_target_menu.selection[]
        !check_selection_validity(target_idx) && return
        
        target_widget = selector_widgets[target_idx]
        is_animating[] = false # Stop live playback
        
        # Setup Export
        save_path = joinpath(get_save_path(), "animations")
        mkpath(save_path)
        fname = joinpath(save_path, gif_name.stored_string[] * ".gif")
        
        duration = manager.ui["Various"]["animation_duration_s"][]
        fps = manager.ui["Various"]["animation_fps"][]
        rng = target_widget.range[]
        n_frames = Int(duration * fps)
        
        @info "Recording '$(dim_names[target_idx])' animation to $fname..."
        try
            record(plot_fig, fname, range(rng[1], rng[end], length=n_frames); framerate=fps) do val
                set_close_to!(target_widget, val)
                # Yield to ensure the plot lift has time to process the slider move
                yield() 
            end
            @info "GIF Saved Successfully."
        catch e
            @error "GIF Recording Failed" exception=(e, catch_backtrace())
        end
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
function create_base_overwrite_controls!(layout::GridLayout, manager::PlotManager{D}) where {D}
    # 1. Setup Labels and Widgets
    #Label(layout[1, 1], "Fix Dimension:", halign=:right, font=:bold)
    
    # Base variable names from Structs (Component, X, Y, Z, Time)
    # We filter them based on the simulation dimension D
    base_names = [VariableNames[1]; VariableNames[2:1+D]; VariableNames[5]]
    
    menu_var = Menu(layout[1, 1], options = base_names, width = 120, prompt = "Select...")
    tb_val = Textbox(layout[1, 2], placeholder = "Val / 'default'", width = 120)
    apply_btn = Button(layout[1, 3], label = "Apply", buttoncolor = :lightgray)

    # 2. Reactive Logic
    on(apply_btn.clicks) do _
        var_name = menu_var.selection[]
        input_str = tb_val.stored_string[]
        
        if isnothing(var_name) || isempty(input_str)
            @warn "Overwrite Error: Please select a variable and provide an input."
            return
        end

        # Find the index in the base_types vector (C=1, Space=2:D+1, T=D+2)
        idx = findfirst(==(var_name), base_names)
        
        # Access and copy the current base_types observable [cite: 316]
        vt = copy(manager.controls["base_types"][])

        if lowercase(strip(input_str)) == "default"
            # Restore the default symbol from Structs [cite: 167]
            # VariableControls mapping: 1=menu, 2-4=slider, 5=slider
            default_map = [1, (2 for _ in 1:D)..., 5]
            vt[idx] = VariableControls[default_map[idx]]
            @info "Restored default control for $var_name."
        else
            # Attempt to parse as a number to fix the dimension [cite: 227]
            val = tryparse(Float64, input_str)
            if isnothing(val)
                @warn "Invalid Input: '$input_str' is not a number or 'default'."
                return
            end
            vt[idx] = val
            @info "Fixed $var_name to value/index: $val."
        end

        # Update the manager and trigger a data reload [cite: 317-318]
        manager.controls["base_types"][] = vt
        manager.controls["Simulation_Update"][] += 1
        
        # Reset textbox
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