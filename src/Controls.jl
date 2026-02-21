module Controls

export PlotManager, create_plot_manager, create_controls, attach_plot_controls!

using GLMakie
using CairoMakie
using Printf
using Statistics
using LibGit2
using CSV, DataFrames
using Dates
using ..Structs
using ..Utils

# Type Alias for Scope -> Key -> Observable
const NestedObsDict = Dict{String, Dict{String, Observable}}

mutable struct PlotManager
    simulation::NestedObsDict
    ui::NestedObsDict
    scene::NestedObsDict
    methods::Observable{Vector{String}}  # NEW: Tracks active checkboxes
    last_run_params::Dict{String, Any}

    function PlotManager(sim, ui, scene, methods, last_run)
        new(sim, ui, scene, methods, last_run)
    end
end

function create_plot_manager(sim_config::SimulationConfig, ui_raw::Dict, scene_raw::Dict)
    # --- 1. Simulation Field ---
    sim_obs = NestedObsDict()
    # Add Shared
    sim_obs["shared"] = Dict(k => Observable(v) for (k, v) in sim_config.shared_params)
    # Add Methods
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => Observable(v) for (k, v) in m_params)
    end

    # --- 2. UI Field ---
    ui_obs = NestedObsDict()
    for (scope, keys_dict) in ui_raw
        ui_obs[scope] = Dict(k => Observable(v) for (k, v) in keys_dict)
    end

    # 3. Initialize Active Methods from sim_config defaults
    methods_obs = Observable(copy(sim_config.default_methods))

    # --- 4. Scene Field ---
    scene_obs = NestedObsDict()
    # Scene usually has one scope, e.g., "Current"
    scene_obs["Current"] = Dict(k => Observable(v) for (k, v) in scene_raw)

    return PlotManager(sim_obs, ui_obs, scene_obs, methods_obs, copy(sim_config.shared_params))
end

include("ControlUtils.jl")

"""
    create_controls(...)

Creates the static UI window. The Menus and Sliders are generated once based 
on the maximum dimensionality of the simulation.
"""
function create_controls(
    plot_fig::Makie.Figure, 
    manager::PlotManager, 
    plot_data_obs::Observable, 
    active_params::Vector{String}
)
    GLMakie.activate!()
    plot_screen = GLMakie.Screen(title = "Makie Plot")
    # 2. FIX: Attach the Figure to the Screen immediately
    display(plot_screen, plot_fig)
    
    base_controls_fig = Figure(size = (350, 850)) 
    fig_layout = base_controls_fig.layout[1,1] = GridLayout(tellheight=false)
    rowgap!(fig_layout, 15) 
    current_row = 1

    # 1. HEADER & REFRESH
    header_layout = fig_layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Simulation Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1
    
    update_layout = fig_layout[current_row, 1] = GridLayout()
    update_button = Button(update_layout[1,1], label="Refresh / Run Simulation", 
                           halign=:center, width=250, buttoncolor=:lightblue)
    
    update_notifier = Observable(0)
    on(update_button.clicks) do _
        update_notifier[] += 1
        if !GLMakie.isopen(plot_screen)
            display(plot_fig)
        end
# 3. FIX: Safely recreate and display if the user accidentally closed the window
        if !GLMakie.isopen(plot_screen)
            plot_screen = GLMakie.Screen(title = "Makie Plot")
            display(plot_screen, plot_fig)
        end
    end
    current_row += 1

    # 2. METHOD SELECTION 
    Label(fig_layout[current_row, 1], "Active Comparison Methods:", fontsize=16, font=:bold)
    current_row += 1
    
    method_checkbox_layout = fig_layout[current_row, 1] = GridLayout()
    all_methods = filter(k -> k != "shared", collect(keys(manager.simulation)))
    methods_obs = Observable(all_methods)
    createMethodCheckboxes!(method_checkbox_layout, methods_obs, manager) 
    current_row += 1

    # 3. HIERARCHICAL PARAMETER NAVIGATOR
    Label(fig_layout[current_row, 1], "Parameter & UI Editor:", fontsize=16, font=:bold, color=:royalblue)
    current_row += 1
    param_nav_layout = fig_layout[current_row, 1] = GridLayout()
    ui_update = create_hierarchical_param_controls!(param_nav_layout, manager)
    current_row += 1

    # 4. SAVE CONTROLS
    Label(fig_layout[current_row, 1], "Export Options:", fontsize=16, font=:bold)
    current_row += 1
    save_box_layout = fig_layout[current_row, 1] = GridLayout()
    createSaveFigBox(save_box_layout, plot_fig, manager)
    current_row += 1

    # 5. STATIC PLOT CONTROLS SLOT
    Label(fig_layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
    Label(fig_layout[current_row, 1], "Data Exploration (Axes & Sliders)", 
          fontsize=16, font=:bold, color=:darkgreen)
    current_row += 1
    
    # We build the controls ONCE here.
    menu_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1
    
    # ... after current_row += 1 ...
    Label(fig_layout[current_row, 1], "Animation Control", fontsize=16, font=:bold)
    current_row += 1
    anim_layout = fig_layout[current_row, 1] = GridLayout()

    # Note: build_static_plot_controls! should now return the WIDGETS too
    x_obs, y_obs, dim_obs, selectors, widgets = build_static_plot_controls!(menu_area, slider_area, plot_data_obs, active_params)

    createAnimationControls!(anim_layout, plot_fig, manager, dim_obs, widgets)
    
    display(GLMakie.Screen(title="Makie Controls"), base_controls_fig)

    return base_controls_fig, update_notifier, ui_update, methods_obs, x_obs, y_obs, dim_obs, selectors
end


function createAnimationControls!(
    layout::GridLayout,
    plot_fig::Figure,
    manager::PlotManager,
    plot_dim_obs::Observable{Int},
    selector_widgets::Vector{Any}
)
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    
    # 1. Metadata setup
    active_params = sort(collect(keys(manager.last_run_params)))
    n_params = length(active_params)
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"

    # 2. Build Widgets with static defaults first
    Label(layout[1, 1], "Animate Target:")
    # Initialize with a dummy option to prevent empty buffer errors
    anim_target_menu = Menu(layout[1, 2], options = ["None"], width=120)

    # Use a standard Button and update it via 'on' instead of '@lift' during init
    play_btn = Button(layout[1, 3], label="Play", width=60)
    on(is_animating) do animating
        play_btn.label[] = animating ? "Stop" : "Play"
    end
    
    gif_name = Textbox(layout[1, 4], placeholder="filename", width=120)
    gif_name.stored_string = "wave_anim"
    save_btn = Button(layout[1, 5], label="Save GIF", buttoncolor=:lightgreen)

    # 3. Setup the Listener (REMOVE update=true)
    on(plot_dim_obs) do current_plot_idx
        opts = []
        for i in 1:length(selector_widgets)
            # Only animate Sliders that aren't the current plotting axis
            if i != current_plot_idx && selector_widgets[i] isa Slider
                push!(opts, (get(dim_names, i, "Dim $i"), i))
            end
        end
        
        # Guard against empty options
        if isempty(opts)
            anim_target_menu.options[] = [("None", 0)]
        else
            anim_target_menu.options[] = opts
            # Set default selection if none exists
            if anim_target_menu.selection[] == 0 || isnothing(anim_target_menu.selection[])
                anim_target_menu.selection[] = opts[end][2] 
            end
        end
    end

    # --- MANUALLY TRIGGER THE FIRST UPDATE AFTER WIDGETS ARE CREATED ---
    notify(plot_dim_obs)

    # --- 3. Animation Controls ---
    play_btn = Button(layout[1, 3], label=@lift($is_animating ? "Stop" : "Play"), width=60)
    
    gif_name = Textbox(layout[1, 4], placeholder="filename", width=120)
    gif_name.stored_string = "wave_anim"
    
    save_btn = Button(layout[1, 5], label="Save GIF", buttoncolor=:lightgreen)

    # --- 4. Play Logic ---
    on(play_btn.clicks) do _
        if is_animating[]
            # STOP
            is_animating[] = false
            !isnothing(animation_timer[]) && close(animation_timer[])
            animation_timer[] = nothing
        else
            # START
            target_idx = anim_target_menu.selection[]
            (target_idx == 0 || isnothing(target_idx)) && return
            
            target_widget = selector_widgets[target_idx]
            !(target_widget isa Slider) && return
            
            rng = target_widget.range[]
            (length(rng) < 2) && return
            
            is_animating[] = true
            
            # Use settings from Manager UI
            duration = manager.ui["Various"]["animation_duration_s"][]
            fps = manager.ui["Various"]["animation_fps"][]
            
            start_time = time()
            
            animation_timer[] = Timer(0.0, interval = 1/fps) do t
                if !is_animating[]
                    close(t); return
                end
                
                elapsed = mod(time() - start_time, duration)
                progress = elapsed / duration
                
                # Calculate value and update slider
                val = rng[1] + progress * (rng[end] - rng[1])
                set_close_to!(target_widget, val)
            end
        end
    end

    # --- 5. GIF Recording Logic ---
    on(save_btn.clicks) do _
        target_idx = anim_target_menu.selection[]
        (target_idx == 0 || isnothing(target_idx)) && return
        target_widget = selector_widgets[target_idx]
        
        # Prep Paths
        save_path = joinpath(Utils.get_save_path(), "animations")
        mkpath(save_path)
        fname = joinpath(save_path, gif_name.stored_string[] * ".gif")
        
        # Stop live animation if running
        is_animating[] = false
        
        # Capture settings
        duration = manager.ui["Various"]["animation_duration_s"][]
        fps = manager.ui["Various"]["animation_fps"][]
        rng = target_widget.range[]
        n_frames = Int(duration * fps)
        
        @info "Recording GIF to $fname..."
        
        # Record block
        try
            record(plot_fig, fname, range(rng[1], rng[end], length=n_frames); framerate=fps) do val
                set_close_to!(target_widget, val)
            end
            @info "GIF Saved!"
        catch e
            @error "GIF failed" exception=(e, catch_backtrace())
        end
    end
end

"""
    build_static_plot_controls!(...)

Builds the Menus and Sliders once. They react internally to `plot_data_obs` to 
update their ranges and options without destroying the UI.
"""
function build_static_plot_controls!(
    menu_layout::GridLayout, 
    slider_layout::GridLayout, 
    plot_data_obs::Observable,
    active_params::Vector{String}
)
    n_params = length(active_params)
    
    # Define Dimension Metadata
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"
    total_dims = length(dim_names)
    
    x_key_obs = Observable{String}("-")
    y_key_obs = Observable{String}("-")
    plot_dim_idx_obs = Observable{Int}(0)
    
    selector_values = Vector{Observable}(undef, total_dims)
    for i in 1:total_dims
        val_type = i == n_params+1 ? Int : Float64
        selector_values[i] = Observable{val_type}(val_type(1)) 
    end

    # --- Build UI Widgets Once ---
    Label(menu_layout[1,1], "X-Axis:")
    menu_x = Menu(menu_layout[1,2], options = ["-"], default = "-")
    
    Label(menu_layout[2,1], "Y-Axis:")
    menu_y = Menu(menu_layout[2,2], options = ["-"], default = "-")
    
    Label(menu_layout[3,1], "Plot Along:")
    menu_axis = Menu(menu_layout[3,2], options = [("-", 1)], default = 1)

    control_objects = Vector{Any}(undef, total_dims) 
    for dim_i in 1:total_dims
        Label(slider_layout[dim_i, 1], "$(dim_names[dim_i]):", halign=:right)
        
        if dim_i == n_params+1 # Component
            c_menu = Menu(slider_layout[dim_i, 2], options = ["1"])
            control_objects[dim_i] = c_menu
            Label(slider_layout[dim_i, 3], lift(s -> "C = $s", c_menu.selection))
            on(c_menu.selection) do v
                if v != "-" && !isnothing(v); selector_values[dim_i][] = parse(Int, v); end
            end
        else # Continuous Params/Space/Time
            sl = Slider(slider_layout[dim_i, 2], range = 0:1:10)
            control_objects[dim_i] = sl
            lab_text = lift(sl.value, sl.range) do val, r
                r == [0] ? "Axis" : string(round(val, digits=3))
            end
            Label(slider_layout[dim_i, 3], lab_text, width=60, halign=:left)
            on(sl.value) do v
                selector_values[dim_i][] = v
            end
        end
    end

    # --- Reactive Logic (Triggers when data refreshes) ---
    on(plot_data_obs) do plot_data_dict
        isempty(plot_data_dict) && return
        
        # 1. Update X Options
        all_keys = Set{String}()
        for pd in values(plot_data_dict); union!(all_keys, keys(pd.data)); end
        sorted_keys = sort(collect(all_keys))
        
        menu_x.options[] = sorted_keys
        if menu_x.selection[] == "-" || isnothing(menu_x.selection[])
            menu_x.selection[] = sorted_keys[1]
        end
        notify(menu_x.selection) # Cascade updates
    end

    on(menu_x.selection) do x_val
        (isnothing(x_val) || x_val == "-") && return
        plot_data_dict = plot_data_obs[]
        
        # 2. Update Y Options
        varied_dims = Set{Int}()
        for pd in values(plot_data_dict)
            if haskey(pd.data, x_val); union!(varied_dims, findall(s -> s > 1, size(pd.data[x_val]))); end
        end
        
        valid_y = String[]
        for y_can in menu_x.options[]
            y_varied = Set{Int}()
            for pd in values(plot_data_dict)
                if haskey(pd.data, y_can); union!(y_varied, findall(s -> s > 1, size(pd.data[y_can]))); end
            end
            if !isempty(intersect(varied_dims, y_varied)); push!(valid_y, y_can); end
        end
        
        menu_y.options[] = valid_y
        x_key_obs[] = x_val
        if menu_y.selection[] ∉ valid_y
            menu_y.selection[] = isempty(valid_y) ? "-" : valid_y[1]
        end
        notify(menu_y.selection)
    end

    on(menu_y.selection) do y_val
        (isnothing(y_val) || y_val == "-") && return
        x_val = menu_x.selection[]
        plot_data_dict = plot_data_obs[]

        # 3. Update Axis Options
        x_varied, y_varied = Set{Int}(), Set{Int}()
        for pd in values(plot_data_dict)
            if haskey(pd.data, x_val); union!(x_varied, findall(s -> s > 1, size(pd.data[x_val]))); end
            if haskey(pd.data, y_val); union!(y_varied, findall(s -> s > 1, size(pd.data[y_val]))); end
        end
        
        common = sort(collect(intersect(x_varied, y_varied)))
        menu_axis.options[] = isempty(common) ? [("-", 1)] : [(dim_names[d], d) for d in common]
        y_key_obs[] = y_val
        
        if menu_axis.selection[] ∉ common
            menu_axis.selection[] = isempty(common) ? 1 : common[end]
        else
            notify(menu_axis.selection)
        end
    end

    on(menu_axis.selection) do axis_idx
        (isnothing(axis_idx) || axis_idx == "-") && return
        plot_dim_idx_obs[] = axis_idx
        plot_data_dict = plot_data_obs[]
        
        # 4. Update Sliders Ranges
        for dim_i in 1:total_dims
            ctrl = control_objects[dim_i]
            is_axis = (dim_i == axis_idx)
            
            if dim_i == n_params+1 # Component
                max_c = 1
                for pd in values(plot_data_dict)
                    if haskey(pd.data, "u"); max_c = max(max_c, size(pd.data["u"], n_params + 1)); end
                end
                
                if is_axis
                    ctrl.options[] = ["-"]
                else
                    ctrl.options[] = string.(1:max_c)
                    if ctrl.selection[] == "-" || parse(Int, ctrl.selection[]) > max_c
                        ctrl.selection[] = "1"
                    end
                end
            else # Continuous Sliders
                g_min, g_max = Inf, -Inf
                for pd in values(plot_data_dict)
                    vals = nothing
                    if dim_i <= n_params 
                        vals = pd.active_param_values[dim_i]
                    elseif dim_i == n_params + 2; vals = get(pd.data, "x", nothing)
                    elseif dim_i == n_params + 3; vals = pd.t_vals
                    end
                    if !isnothing(vals) && !isempty(vals)
                        l, h = extrema(vals)
                        if l < g_min; g_min = l; end
                        if h > g_max; g_max = h; end
                    end
                end
                if isinf(g_min); g_min=0.0; g_max=1.0; end
                
                if is_axis
                    ctrl.range[] = [0] # Marks as disabled
                else
                    ctrl.range[] = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
                end
            end
        end
    end

    return x_key_obs, y_key_obs, plot_dim_idx_obs, selector_values, control_objects
end

"""
    create_plot_controls!(fig, plot_data_dict::Dict{String, UnifiedPlotData})

Creates a control panel with:
1. X/Y/Axis Selection Menus.
2. Permanent Sliders/Menus for [Component, P1..., Space, Time].

Instead of hiding controls, it "disables" the control for the active plot axis 
by setting its range to `[0]` (or options to `["-"]`) and updating the label.
"""
function create_plot_controls!(
    menu_layout::GridLayout, 
    slider_layout::GridLayout, 
    plot_data_dict::Dict{String, UnifiedPlotData}
)
    if isempty(plot_data_dict)
        error("No plot data available to generate controls.")
    end
    
    # --- 1. Metadata Setup ---
    # Use the first dataset to determine the dimension structure
    template_data = first(values(plot_data_dict))
    
    active_params = template_data.active_param_keys
    n_params = length(active_params)
    
    # Map Index -> Name
    # 1=Comp, 2..N+1=Params, N+2=Space, N+3=Time
    dim_names = Dict{Int, String}()
    
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"
    
    total_dims = length(dim_names)
    
    # The outputs
    x_key_obs = Observable{String}("-")
    y_key_obs = Observable{String}("-")
    plot_dim_idx_obs = Observable{Int}(0) # 0 means "Not selected yet"
    
    # Holds the current selected values (Physical Float for Params/Time, Int for Component)
    # If a dimension is disabled (plot axis), this might hold a dummy value.
    selector_values = Vector{Observable}(undef, total_dims)
    for i in 1:total_dims
        val_type = i == n_params+1 ? Int : Float64
        selector_values[i] = Observable{val_type}(val_type(1)) 
    end

    # --- 3. Build Selection Menus ---
    all_keys = Set{String}()
    for pd in values(plot_data_dict); union!(all_keys, keys(pd.data)); end
    sorted_keys = sort(collect(all_keys))

    Label(menu_layout[1,1], "X-Axis:")
    menu_x = Menu(menu_layout[1,2], options = sorted_keys, default = sorted_keys[1])
    
    Label(menu_layout[2,1], "Y-Axis:")
    menu_y = Menu(menu_layout[2,2], options = ["-"], default = "-")
    
    Label(menu_layout[3,1], "Plot Along:")
    menu_axis = Menu(menu_layout[3,2], options = [("-",1)], default = 1)

    # --- 4. Build Static Controls (Sliders/Menus) ---
    # We create them once. We will manipulate their 'range'/'options' observables later.
    
    # Store references to update them later
    control_objects = Vector{Any}(undef, total_dims) 

    for dim_i in 1:total_dims
        d_name = dim_names[dim_i]
        
        Label(slider_layout[dim_i, 1], "$d_name:", halign=:right)
        
        if dim_i == n_params+1
            # --- COMPONENT (Menu) ---
            # Default options (will be overwritten)
            c_menu = Menu(slider_layout[dim_i, 2], options = ["1"], default = "1")
            control_objects[dim_i] = c_menu
            
            # Label for Component (Display selection)
            Label(slider_layout[dim_i, 3], lift(s -> "C = $s", c_menu.selection))
            
            # Connect to Output
            on(c_menu.selection) do v
                if v != "-" && !isnothing(v)
                    selector_values[dim_i][] = parse(Int, v)
                end
            end
            notify(c_menu.selection)
            
        else
            # --- CONTINUOUS (Slider) ---
            # Default range (will be overwritten)
            sl = Slider(slider_layout[dim_i, 2], range = 0:1:10)
            control_objects[dim_i] = sl
            
            # Label with "N/A" Logic
            # Note: Makie sliders usually have a vector/abstract range as 'range'
            lab_text = lift(sl.value, sl.range) do val, r
                if r == [0] # The "Disabled" flag
                    "Axis"
                else
                    string(round(val, digits=3))
                end
            end
            Label(slider_layout[dim_i, 3], lab_text, width=60, halign=:left)
            
            # Connect to Output
            on(sl.value) do v
                # Only update if valid (not the dummy 0 from disable)
                # However, usually we just update anyway. 
                # The plotting lift checks `plot_dim_idx` and ignores this value if it's the axis.
                selector_values[dim_i][] = v
            end
        end
    end

    # --- 5. Menu Logic (Filters) ---
    
    # X -> Y
    on(menu_x.selection) do x_val
        if isnothing(x_val); return; end
        
        # Identify varied dimensions
        varied_dims = Set{Int}()
        for pd in values(plot_data_dict)
            if haskey(pd.data, x_val)
                union!(varied_dims, findall(s -> s > 1, size(pd.data[x_val])))
            end
        end
        
        # Filter Y
        valid_y = String[]
        for y_can in sorted_keys
            y_varied = Set{Int}()
            for pd in values(plot_data_dict)
                if haskey(pd.data, y_can)
                    union!(y_varied, findall(s -> s > 1, size(pd.data[y_can])))
                end
            end
            if !isempty(intersect(varied_dims, y_varied)); push!(valid_y, y_can); end
        end
        
        menu_y.options[] = valid_y
        x_key_obs[] = x_val
        menu_y.selection[] = isempty(valid_y) ? "Not Plottable" : valid_y[1]
    end
    notify(menu_x.selection)

    # Y -> Axis
    on(menu_y.selection) do y_val
        if isnothing(y_val); return; end
        x_val = menu_x.selection[]
        
        # Intersect varied dims
        x_varied, y_varied = Set{Int}(), Set{Int}()
        for pd in values(plot_data_dict)
            if haskey(pd.data, x_val); union!(x_varied, findall(s -> s > 1, size(pd.data[x_val]))); end
            if haskey(pd.data, y_val); union!(y_varied, findall(s -> s > 1, size(pd.data[y_val]))); end
        end
        
        common = sort(collect(intersect(x_varied, y_varied)))
        menu_axis.options[] = [(dim_names[d], d) for d in common]
        
        y_key_obs[] = y_val
        if !isempty(common); menu_axis.selection[] = common[end]; end
    end
    notify(menu_y.selection)

    # Axis -> Disable/Enable Sliders
    on(menu_axis.selection) do axis_idx
        if isnothing(axis_idx); return; end
        plot_dim_idx_obs[] = axis_idx
        
        # Loop through all controls and update their state
        for dim_i in 1:total_dims
            ctrl = control_objects[dim_i]
            
            # Is this the plot axis?
            is_axis = (dim_i == axis_idx)
            
            if dim_i == n_params+1
                # --- Update Component Menu ---
                # Find max components
                max_c = maximum(size(pd.data["u"], 1) for pd in values(plot_data_dict))
                
                if is_axis
                    ctrl.options[] = ["-"] # Disable
                    ctrl.selection[] = "-"
                else
                    ctrl.options[] = string.(1:max_c)
                    # Try to keep selection or reset to 1
                    if ctrl.selection[] == "-"; ctrl.selection[] = "1"; end
                end
                
            else
                # --- Update Continuous Slider ---
                # 1. Determine Global Range
                g_min, g_max = Inf, -Inf
                
                # Check data
                for pd in values(plot_data_dict)
                    vals = nothing
                    if dim_i <= n_params 
                        p_idx = dim_i
                        vals = pd.active_param_values[p_idx]
                    elseif dim_i == n_params + 2 # Space
                        if haskey(pd.data, "x"); vals = pd.data["x"]; end
                    elseif dim_i == n_params + 3 # Time
                        vals = pd.t_vals
                    end
                    
                    if !isnothing(vals) && !isempty(vals)
                        l, h = extrema(vals)
                        if l < g_min; g_min = l; end
                        if h > g_max; g_max = h; end
                    end
                end
                if isinf(g_min); g_min=0.0; g_max=1.0; end
                
                # 2. Update Slider Range
                if is_axis
                    ctrl.range[] = [0] # Disable!
                    # Value automatically jumps to 0
                else
                    # Construct range (approx 100 steps for smooth slider)
                    ctrl.range[] = range(g_min, g_max, length=100)
                end
            end
        end
    end
    notify(menu_axis.selection)

    return x_key_obs, y_key_obs, plot_dim_idx_obs, selector_values
end

# Backward compatibility (if you use it elsewhere)
function create_plot_controls!(fig::Figure, plot_data_dict)
    menu_layout = fig[1,1] = GridLayout()
    slider_layout = fig[2,1] = GridLayout()
    return create_plot_controls!(
        menu_layout, 
        slider_layout, 
        plot_data_dict
    )
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

"""
    create_hierarchical_param_controls!(layout, manager::PlotManager)

Creates a 3-menu + 1-textbox interface to navigate and edit all parameters.
"""
function create_hierarchical_param_controls!(layout::GridLayout, mgr::PlotManager)
    # 1. Menus
    # Categories are fixed strings matching the field names (capitalized for UI)
    cat_mapping = Dict("Simulation" => :simulation, "UI" => :ui, "Scene" => :scene)
    sorted_cat = sort(collect(keys(cat_mapping)))
    menu_cat = Menu(layout[1, 1:2], options = sorted_cat, default = "UI", prompt = "Category...")
    
    menu_scope = Menu(layout[2, 1:2], options = ["-"], default = "-", prompt = "Scope...")
    menu_key = Menu(layout[3, 1:2], options = ["-"], default = "-", prompt = "Key...")
    
    active_target_obs = Observable{Any}(nothing)
    ui_update = Observable{Int}(0)
    # 2. Category -> Scope (Accessing fields directly)
    on(menu_cat.selection) do cat
        isnothing(cat) && return
        # Access mgr.simulation, mgr.ui, or mgr.scene
        field_data = getproperty(mgr, cat_mapping[cat])
        menu_scope.options[] = sort(collect(keys(field_data)))
        menu_scope.selection[] = nothing
    end

    # 3. Scope -> Key
    on(menu_scope.selection) do scope
        isnothing(scope) && return
        cat = menu_cat.selection[]
        field_data = getproperty(mgr, cat_mapping[cat])
        
        menu_key.options[] = sort(collect(keys(field_data[scope])))
        menu_key.selection[] = nothing
    end

    # 4. Textbox with Live Placeholder
    Label(layout[4, 1], "Edit Value:", halign=:right)
    
    # Show what is currently loaded in the plot
    placeholder_text = lift(menu_key.selection) do k
        isnothing(k) && return "Select key..."
        val = get(mgr.last_run_params, k, "default")
        return "Loaded: $val"
    end

    tb = Textbox(layout[4, 2], placeholder = placeholder_text, reset_on_defocus = true)

# When a key is selected, we update the Textbox
    on(menu_key.selection) do key
        isnothing(key) && return
        cat, scope = menu_cat.selection[], menu_scope.selection[]
        
        field_data = getproperty(mgr, cat_mapping[cat])
        obs = field_data[scope][key]
        
        active_target_obs[] = obs
        # Show the actual value as a string for editing
        tb.stored_string[] = string(to_value(obs))
    end

    # Handle Textbox Submission with the NEW Smart Parser
    on(tb.stored_string) do s
        obs = active_target_obs[]
        isnothing(obs) && return
        
        # This replaces the old 'parsed = parseValue(s)' logic
        smart_parse_and_update!(obs, s)
        if menu_cat.selection[] == "UI"; ui_update[] += 1 end
    end
    return ui_update
end

function createMethodCheckboxes!(layout, methods_obs::Observable, mgr::PlotManager)
    # Get all scopes in simulation except 'shared'
    all_method_names = filter(k -> k != "shared", collect(keys(mgr.simulation)))
    sort!(all_method_names)
    
    # Call your existing checkbox creation logic
    # (assuming createMethodCheckboxes is the function from your PlottingUtils.jl)
    createMethodCheckboxes(layout, methods_obs, all_method_names)
end

function createSaveFigBox(
    target_layout,
    plot_fig::Makie.Figure,
    manager::PlotManager;
    context_info = Dict{String, Any}()
)
    gb = target_layout[1, 1:2] = GridLayout()
    Label(gb[1, 1], "Save Image+CSV:", halign=:right).padding=(0,5,0,0)
    saveBox = Textbox(gb[1, 2], placeholder = "Type name (no ext)", width=200)

    get_save_dir() = joinpath(Utils.get_save_path(), "figures")

    on(saveBox.stored_string) do s
        base_name = string(strip(s))
        if isempty(base_name); return; end

        # Access UI options via the nested "Various" scope
        ui_various = manager.ui["Various"]
        save_figures_path = get_save_dir()
        
        if ui_various["create_savefolder"][]; save_figures_path = joinpath(save_figures_path, base_name) end
        mkpath(save_figures_path)

        formats = ui_various["save_formats"][]
        
        for format in formats
            fmt = lowercase(strip(format))
            full_filename = joinpath(save_figures_path, base_name * ".$fmt")

            try
                if fmt in ["pdf", "svg"]
                    # Use CairoMakie for vector export
                    # Note: You must have 'using CairoMakie' in your scope
                    CairoMakie.activate!()
                    CairoMakie.save(full_filename, plot_fig)
                else
                    GLMakie.save(full_filename, plot_fig)
                end
                @info "Saved: $full_filename"
            catch e
                @error "Save failed for $fmt" exception=(e, catch_backtrace())
            finally
                GLMakie.activate!()
            end
        end

        # Metadata gathering
        context_info["Save Type"] = "Static Frame"
        context_info["Timestamp"] = string(Dates.now())
        
        git_info = Utils.get_git_info(Utils.get_save_path())
        if !isnothing(git_info); merge!(context_info, git_info) end

        # Call parameter saver
        saveParametersToCSV(base_name, save_figures_path, manager, context_info)
    end
end

function saveParametersToCSV(
    base_filename::String,
    save_dir::String,
    manager::PlotManager,
    optional_info::Dict
)::Bool
    csv_filename = joinpath(save_dir, base_filename * "_params.csv")
    
    sections = String[]
    method_names = Union{String, Missing}[]
    parameters = String[]
    values = String[]

    function add_row(sec, meth, param, val)
        push!(sections, sec); push!(method_names, meth)
        push!(parameters, string(param))
        # _value_to_string_for_csv should handle conversion of colors/symbols
        push!(values, Utils._value_to_string_for_csv(to_value(val)))
    end

    # 1. Context Info
    for k in sort(collect(keys(optional_info)))
        add_row("Context", missing, k, optional_info[k])
    end

    # 2. Simulation - Shared
    for k in sort(collect(keys(manager.simulation["shared"])))
        add_row("Shared", missing, k, manager.simulation["shared"][k])
    end

    # 3. Simulation - Active Methods
    # We only save the parameters for methods that are currently checked (active)
    for m_name in sort(manager.methods[])
        if haskey(manager.simulation, m_name)
            for k in sort(collect(keys(manager.simulation[m_name])))
                add_row("Method", m_name, k, manager.simulation[m_name][k])
            end
        end
    end

    # 4. UI Options (Iterate through Scopes: Axis, Appearance, etc.)
    for (scope, dict) in manager.ui
        for k in sort(collect(keys(dict)))
            # We prefix the parameter with the scope for clarity in the CSV
            add_row("UI", missing, "$scope:$k", dict[k])
        end
    end

    # 5. Scene State
    for k in sort(collect(keys(manager.scene["Current"])))
        add_row("Scene", missing, k, manager.scene["Current"][k])
    end

    try
        df = DataFrame(Section=sections, MethodName=method_names, Parameter=parameters, Value=values)
        CSV.write(csv_filename, df)
        @info "Parameters saved to $csv_filename"
        return true
    catch e
        @error "CSV write failed" exception=(e, catch_backtrace())
        return false
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



end