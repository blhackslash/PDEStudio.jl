"""
    create_method_checkboxes_figure(possible_methods, active_methods; target_rows=20, cell_size=(250, 30), fig_padding=20) -> (fig, fig_layout)

Creates a separate Figure containing checkboxes for all `possible_methods`. 
Fills downwards up to `target_rows`, then automatically spills into new columns.
"""
function create_method_checkboxes_figure(
    possible_methods::Vector{String},
    active_methods::Observable{Vector{String}};
    target_rows::Int = 20, 
    cell_size::Tuple{Int, Int} = (250, 30), # Increased width to fit explicit labels
    fig_padding::Int = 20
)
    # --- 1. Calculate Optimal Layout & Figure Size ---
    total_methods = length(possible_methods)
    
    if total_methods == 0 || isempty(possible_methods)
        @warn "No possible methods provided. Unable to create figure."
        return nothing, nothing
    end
    
    # THE FIX: Column-major layout based on a fixed maximum row count
    rows = min(total_methods, target_rows)
    cols = ceil(Int, total_methods / rows)
    
    total_rows_with_title = rows + 1
    
    # Calculate physical figure size
    fig_width = cols * cell_size[1] + fig_padding
    fig_height = 1050#2*total_rows_with_title * cell_size[2] + fig_padding + 10

    # --- 2. Create Figure & GridLayout ---
    fig = Figure(size = (fig_width, fig_height))
    fig_layout = fig[1, 1] = GridLayout()
    rowsize!(fig_layout, 1, Fixed(40)) 

    # --- 3. Add Figure Title ---
    Label(fig_layout[1, 1:cols], "Toggle Active Comparison Methods", fontsize=18, font=:bold, halign=:center)

    # --- 4. Create Grid of Checkboxes & Labels ---
    checkbox_layout = fig_layout[2:total_rows_with_title, 1:cols] = GridLayout()

    checkbox_widgets = Dict{String, Checkbox}()
    is_internal_bulk_update = Observable(false) 

    for (i, method_name) in enumerate(possible_methods)
        # THE FIX: Column-major coordinate mapping
        c = ((i - 1) ÷ rows) + 1
        r = ((i - 1) % rows) + 1
        
        cell_layout = checkbox_layout[r, c] = GridLayout(tellwidth=false, tellheight=false)

        cb = Checkbox(cell_layout[1, 1]; checked = (method_name in active_methods[]))
        
        # Changed to :left alignment for a much cleaner grid appearance
        Label(cell_layout[1, 2], method_name, halign=:left) 
        
        checkbox_widgets[method_name] = cb
        
        # THE FIX: Explicitly fix both the checkbox and the label width
        colsize!(cell_layout, 1, Fixed(30)) 
        colsize!(cell_layout, 2, Fixed(cell_size[1] - 40)) 
        
        on(cb.checked) do is_checked
            if !is_internal_bulk_update[]
                curr_list = active_methods[]
                if is_checked
                    method_name ∉ curr_list && (active_methods[] = [curr_list; method_name])
                else
                    active_methods[] = filter(s -> s != method_name, curr_list)
                end
            end
        end
    end
    
    # Force strict alignment across the entire parent grid
    for r in 1:rows
        rowsize!(checkbox_layout, r, Fixed(cell_size[2]))
    end
    for c in 1:cols
        colsize!(checkbox_layout, c, Fixed(cell_size[1]))
    end

    # --- 5. Bulk Observer (UI <-> Observable sync) ---
    on(active_methods) do new_list
        is_internal_bulk_update[] = true
        for (m_name, cb) in checkbox_widgets
            new_checked_state = (m_name in new_list)
            if cb.checked[] != new_checked_state
                cb.checked[] = new_checked_state
            end
        end
        is_internal_bulk_update[] = false
    end

    return fig, fig_layout
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
    active_axes_obs::Observable{Vector{Int}}, 
    selector_widgets::Vector{Any},
    active_params::Vector{String}
)
    n_params = length(active_params)
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"

    saveBox = Textbox(layout[2, 1:4], placeholder = "Filename...", width=nothing)
    
    btn_save_def = Button(layout[1, 1], label="Save Defs", buttoncolor=:lightcoral)
    btn_play     = Button(layout[1, 2], label="Play Anim", buttoncolor=:lightyellow)
    btn_img      = Button(layout[1, 3], label="Save Image", buttoncolor=:lightblue)
    btn_gif      = Button(layout[1, 4], label="Save GIF", buttoncolor=:lightgreen)

    # THE FIX: Alle 4 Buttons auf exakt gleiche Breite zwingen
    for i in 1:4
        colsize!(layout, i, Relative(0.25))
    end

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
        
        # --- THE FIX: Hard-Lock the Interactive Zoom State ---
        # Sync the user's interactive mouse zoom (finallimits) back to the hard limits 
        # so CairoMakie doesn't reset the view when switching backends.
        for block in plot_fig.content
            if block isa Axis
                lims = block.finallimits[]
                limits!(block, 
                    lims.origin[1], lims.origin[1] + lims.widths[1], 
                    lims.origin[2], lims.origin[2] + lims.widths[2]
                )
            elseif block isa Axis3
                lims = block.finallimits[]
                limits!(block, 
                    lims.origin[1], lims.origin[1] + lims.widths[1], 
                    lims.origin[2], lims.origin[2] + lims.widths[2],
                    lims.origin[3], lims.origin[3] + lims.widths[3]
                )
            end
        end
        # -----------------------------------------------------

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
        
        saveBox.stored_string.val = "" # Reset silently without triggering observers
        Makie.reset!(saveBox)
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
        
        saveBox.stored_string.val = "" # Reset silently without triggering observers
        Makie.reset!(saveBox)
    end
    on(btn_save_def.clicks) do _
        GLOBAL_SCENE_OPTIONS[] = extract_scene_options(manager)
        new_ui = Dict{String, Any}()
        for (scope, subdict) in manager.ui
            new_ui[scope] = Dict{String, Any}()
            for (k, v) in subdict; new_ui[scope][k] = to_value(v); end
        end
        GLOBAL_UI_OVERWRITE[] = new_ui
        GLOBAL_VAR_OVERWRITE[] = copy(manager.controls["base_types"][])
        @info "Current UI and Scene options successfully saved to global defaults!"
    end
    # Anim Play Logic (Die aus createAnimationPreview! übernommen wurde)
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    
    on(is_animating) do animating
        btn_play.label[] = animating ? "Stop Anim" : "Play Anim"
    end

    on(btn_play.clicks) do _
        if is_animating[]
            is_animating[] = false
            !isnothing(animation_timer[]) && close(animation_timer[])
            animation_timer[] = nothing
        else
            target_idx = anim_target_obs[]
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
end


function createMethodCheckboxes!(layout, methods_obs::Observable, mgr::PlotManager)
    # Get all scopes in simulation except 'shared'
    all_method_names = filter(k -> k != "shared", collect(keys(mgr.simulation)))
    sort!(all_method_names)
    
    # Call your existing checkbox creation logic
    # (assuming createMethodCheckboxes is the function from your PlottingUtils.jl)
    createMethodCheckboxes(layout, methods_obs, all_method_names)
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
function get_base_scene_options()
    return Dict{String, Any}(
        "X-Axis_Selection"          => "x",      
        "U-Axis_Selection"          => "u",      
        "Plot-Type_Selection"       => "Lines",  
        "c_Selection"               => 1,        
        "t_Value"                   => 0.0,      
        "x_Value"                   => 0.0,
        "Compare_Target_Selection"  => "None", 
        "Compare_Columns_Selection" => "2",     
        "Compare_Link_Selection"    => "Fully Coupled",
        "Legend_Base_Selection"     => "right",
        "Legend_Add_Selection"      => "detached",
        "Plot-Width_Selection"      => 600,
        "Plot-Height_Selection"     => 400,
        #"Anim-Target_Selection"     => 1,
    )
end

function extract_scene_options(manager::PlotManager)
    opts = Dict{String, Any}()
    
    for k in ["X-Axis", "Y-Axis", "Z-Axis", "U-Axis", "Plot-Type", "c", "Compare_Target", 
              "Compare_Columns", "Compare_Link", "Legend_Base", "Legend_Add", "Plot-Height", "Plot-Height", "Anim-Target"]
        key = "$(k)_Selection"
        if haskey(manager.controls, key)
            opts[key] = to_value(manager.controls[key])
        end
    end
    
    for k in manager.plot_vars
        key = "$(k)_Value"
        if haskey(manager.controls, key)
            opts[key] = to_value(manager.controls[key])
        end
    end
    
    return opts
end
