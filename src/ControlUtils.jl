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
        capture_scene_metadata!(manager,)
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
        save_path = joinpath(Utils.get_save_path(), "animations")
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
    smart_parse_and_update!(obs::Observable, input_str::String)

Attempts to parse `input_str` into the same type as the current value of `obs`.
If parsing fails or types are incompatible, it prints a warning and leaves the 
observable unchanged.
"""
function smart_parse_and_update!(obs::Observable, input_str::String)
    # Ignore empty inputs (usually handled by the placeholder logic)
    (isempty(input_str) || input_str == "default") && return
    
    current_val = to_value(obs)
    T = typeof(current_val)

    try
        if T == String
            obs[] = input_str
        elseif T == Symbol
            obs[] = Symbol(input_str)
        elseif T == Bool
            # Handle true/false, 1/0, yes/no
            s = lowercase(strip(input_str))
            obs[] = (s == "true" || s == "1" || s == "yes")
        elseif T <: Int
            obs[] = parse(Int, input_str)
        elseif T <: AbstractFloat
            obs[] = parse(Float64, input_str)
        elseif T <: Tuple || T <: Vector
            # For complex types, we use the general parser but check the result type
            parsed = parseValue(input_str) 
            if typeof(parsed) == T
                obs[] = parsed
            else
                @warn "Type mismatch for complex input. Expected $T, but got $(typeof(parsed))."
            end
        else
            # Fallback for any other types
            obs[] = parse(T, input_str)
        end
    catch e
        @warn "Invalid input: Could not parse '$input_str' as $T. The value remains: $current_val"
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
    base_names = [Structs.VariableNames[1]; Structs.VariableNames[2:1+D]; Structs.VariableNames[5]]
    
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
            vt[idx] = Structs.VariableControls[default_map[idx]]
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

# """
#     capture_scene_metadata!(manager::PlotManager, x_key, y_key, plot_dim_idx, selector_values, active_params)

# Automatically populates the manager.scene["Current"] dictionary based on the 
# current state of the axis selection menus and exploration sliders.
# """
# function capture_scene_metadata!(
#     manager::PlotManager,
#     x_key::String,
#     y_key::String,
#     plot_dim_idx::Int,
#     selector_values::Vector{Observable},
#     active_params::Vector{String}
# )
#     scene_dict = manager.scene["Current"]
    
#     # 1. Save Axis Context
#     scene_dict["x_key"] = Observable(x_key)
#     scene_dict["y_key"] = Observable(y_key)
#     scene_dict["plot_along_idx"] = Observable(plot_dim_idx)

#     # 2. Map indices back to names for clarity
#     n_params = length(active_params)
#     dim_names = Dict{Int, String}()
#     for (i, p) in enumerate(active_params); dim_names[i] = p; end
#     dim_names[n_params+1] = "Component"
#     dim_names[n_params+2] = "Space"
#     dim_names[n_params+3] = "Time"

#     # 3. Save Slider/Menu Values
#     for i in 1:length(selector_values)
#         name = dim_names[i]
#         val = to_value(selector_values[i])
        
#         # We mark the plotting axis value as :axis for clarity in the CSV
#         scene_dict[name] = i == plot_dim_idx ? Observable(:axis) : Observable(val)
#     end
# end

"""
    capture_scene_metadata!(manager::PlotManager)

Iterates through all registered UI controls and saves their current values
into the metadata for the CSV export.
"""
function capture_scene_metadata!(manager::PlotManager)
    # We grab the to_value of every observable in controls
    return Dict(k => to_value(v) for (k, v) in manager.controls)
end

# """
#     apply_scene_state!(manager::PlotManager, widgets::Vector{Any}, menu_x::Menu, menu_y::Menu, menu_axis::Menu)

# Sets the values of UI widgets based on the state stored in manager.scene["Current"].
# """
# function apply_scene_state!(
#     manager::PlotManager, 
#     widgets::Vector{Any}, # From build_static_plot_controls!
#     menu_x::Menu, 
#     menu_y::Menu, 
#     menu_axis::Menu
# )
#     state = manager.scene["Current"]
#     active_params = sort(collect(keys(manager.simulation["shared"]))) # Approximation
#     n_params = length(active_params)
    
#     # 1. Restore Menus
#     if haskey(state, "x_key"); menu_x.selection[] = to_value(state["x_key"]); end
#     yield() # Let reactive filters update menu_y options
    
#     if haskey(state, "y_key"); menu_y.selection[] = to_value(state["y_key"]); end
#     yield()
    
#     if haskey(state, "plot_along_idx"); menu_axis.selection[] = to_value(state["plot_along_idx"]); end
#     yield()

#     # 2. Restore Sliders and Component Menus
#     dim_names = vcat(active_params, ["Component", "Space", "Time"])
    
#     for (i, name) in enumerate(dim_names)
#         !haskey(state, name) && continue
#         saved_val = to_value(state[name])
#         saved_val == :axis && continue # Skip the dimension being used as the X-axis
        
#         widget = widgets[i]
#         if widget isa Slider
#             set_close_to!(widget, saved_val)
#         elseif widget isa Menu
#             widget.selection[] = string(saved_val)
#         end
#     end
# end

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