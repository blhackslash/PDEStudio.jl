include("ControlUtils.jl") 

"""
    create_controls(...)

Creates the static UI window. The Menus and Sliders are generated once based 
on the maximum dimensionality of the simulation.
"""
function create_controls(
    plot_fig::Makie.Figure, 
    manager::PlotManager{D}, 
    plot_data_obs::Observable, 
) where {D}
    GLMakie.activate!()
    plot_screen = GLMakie.Screen(title = "Makie Plot")
    # 2. FIX: Attach the Figure to the Screen immediately
    display(plot_screen, plot_fig)
    
    base_controls_fig = Figure(size = (450, 950)) 
    fig_layout = base_controls_fig.layout[1,1] = GridLayout(tellheight=false)
    rowgap!(fig_layout, 15) 
    current_row = 1

    active_params = manager.plot_vars
    n_params = length(active_params)
    total_len = n_params + 1 + D + 1
    
    if !haskey(manager.controls, "base_types")
        # Default symbols from VariableControls
        defaults = vcat(fill(:slider, n_params), :menu, fill(:slider, D), :slider)
        manager.controls["base_types"] = Observable(defaults)
    end

    # 1. HEADER & REFRESH
    header_layout = fig_layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Simulation Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1
    
    update_layout = fig_layout[current_row, 1] = GridLayout()
    update_button = Button(update_layout[1,1], label="Refresh / Run Simulation", 
                           halign=:center, width=250, buttoncolor=:lightblue)
    
    update_notifier = Observable(0)
    manager.controls["Simulation_Update"] = update_notifier
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

# 2. METHOD SELECTION (Updated to Button trigger)
    Label(fig_layout[current_row, 1], "Comparison Methods:", fontsize=16, font=:bold)
    current_row += 1
    
    method_btn_layout = fig_layout[current_row, 1] = GridLayout()
    method_button = Button(method_btn_layout[1, 1], label="Select Methods...", 
                           width=250, buttoncolor=:lightgray)
    
    # Identify all possible methods from the simulation dictionary [cite: 291]
    all_method_names = sort(filter(k -> k != "shared", collect(keys(manager.simulation))))

    on(method_button.clicks) do _
        # Create the separate, auto-sizing figure [cite: 292]
        m_fig, _ = create_method_checkboxes_figure(
            all_method_names,
            manager.methods;
            target_layout_ratio = 0.5 # Maintain your preferred 1:2 ratio
        )
        
        # Display the new window
        if !isnothing(m_fig)
            display(m_fig)
        end
    end
    current_row += 1

    # 3. HIERARCHICAL PARAMETER NAVIGATOR
    Label(fig_layout[current_row, 1], "Parameter & UI Editor:", fontsize=16, font=:bold, color=:royalblue)
    current_row += 1
    param_nav_layout = fig_layout[current_row, 1] = GridLayout()
    create_hierarchical_param_controls!(param_nav_layout, manager)
    current_row += 1
    Label(fig_layout[current_row, 1], "Dimension Overwrites", fontsize=16, font=:bold, color=:darkred)
    current_row += 1
    
    lock_layout = fig_layout[current_row, 1] = GridLayout()
    create_base_overwrite_controls!(lock_layout, manager)
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
    
    # STATIC PLOT CONTROLS SLOT
    menu_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1

    x_obs, y_obs, dim_obs, selectors, widgets = build_static_plot_controls!(
        menu_area, slider_area, plot_data_obs, active_params, manager
    )

# 4. ANIMATION PREVIEW
    Label(fig_layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
    Label(fig_layout[current_row, 1], "Animation Preview:", fontsize=16, font=:bold, color=:darkorange)
    current_row += 1
    
    anim_layout = fig_layout[current_row, 1] = GridLayout()
    # Returns the target observable so the GIF exporter knows what to animate!
    anim_target_obs = createAnimationPreview!(anim_layout, manager, dim_obs, widgets, active_params)
    current_row += 1

    # 5. EXPORT OPTIONS
    Label(fig_layout[current_row, 1], "Export Options:", fontsize=16, font=:bold, color=:purple)
    current_row += 1
    
    export_layout = fig_layout[current_row, 1] = GridLayout()
    createExportOptions!(export_layout, plot_fig, manager, anim_target_obs, dim_obs, widgets, active_params)
    current_row += 1

    display(GLMakie.Screen(title="Makie Controls"), base_controls_fig)

    return base_controls_fig
end

function build_static_plot_controls!(
    menu_layout::GridLayout, 
    slider_layout::GridLayout, 
    plot_data_obs::Observable,
    active_params::Vector{String}, 
    manager::PlotManager{D}
) where {D}
    # 1. Metadata & Initialization
    dim_names = active_params
    println(dim_names)
    total_dims = length(dim_names)
    n_params = total_dims - (D + 2) 
    
    x_key_obs = Observable{String}("-")
    y_key_obs = Observable{String}("-")
    plot_dim_idx_obs = Observable{Int}(0)
    
    control_objects = Vector{Any}(undef, total_dims)
    selector_values = Vector{Observable}(undef, total_dims)

# 2. Setup Axis Menus
    Label(menu_layout[1,1],"X-Axis")
    Label(menu_layout[1,2],"Y-Axis")
    Label(menu_layout[1,3],"Plot-Along")
    menu_x = Menu(menu_layout[2,1], options = ["-"], width = 120)
    menu_y = Menu(menu_layout[2,2], options = ["-"], width = 120)
    menu_axis = Menu(menu_layout[2,3], options = [("-", 1)], width = 120)

    colsize!(menu_layout, 1, Fixed(120))
    colsize!(menu_layout, 2, Fixed(120))
    colsize!(menu_layout, 3, Fixed(120))    
    
    # EXPOSE OPTIONS AND SELECTIONS
    manager.controls["X-Axis_Selection"] = menu_x.selection
    manager.controls["X-Axis_Options"]   = menu_x.options
    manager.controls["X-Axis_Widget"]    = menu_x   # <-- ADD THIS

    manager.controls["Y-Axis_Selection"] = menu_y.selection
    manager.controls["Y-Axis_Options"]   = menu_y.options
    manager.controls["Y-Axis_Widget"]    = menu_y   # <-- ADD THIS

    manager.controls["Plot-Along_Selection"] = menu_axis.selection
    manager.controls["Plot-Along_Options"]   = menu_axis.options
    manager.controls["Plot-Along_Widget"]    = menu_axis # <-- ADD THIS

    # 3 & 4. Unified Widget Creation 
    for i in 1:total_dims
        Label(slider_layout[i, 1], "$(dim_names[i]):", halign=:right)
        
        is_basevar = i > n_params
        ctrl_type = :slider
        
        if is_basevar
            base_idx = i - n_params
            if base_idx == 1; ctrl_type = VariableControls[1]
            elseif base_idx <= 1 + D; ctrl_type = VariableControls[base_idx]
            else; ctrl_type = VariableControls[5]; end
        end
        
        if ctrl_type == :menu
            m = Menu(slider_layout[i, 2], options = ["1"], width = 200)
            control_objects[i] = m
            selector_values[i] = Observable{Int}(1)
            on(m.selection) do s
                if !isnothing(s) && s != "-"; selector_values[i][] = parse(Int, s); end
            end
            
            # EXPOSE OPTIONS AND SELECTIONS
            manager.controls["$(dim_names[i])_Selection"] = m.selection
            manager.controls["$(dim_names[i])_Options"]   = m.options 
            manager.controls["$(dim_names[i])_Widget"]    = m  # <-- ADD THIS
        else
            sl = Slider(slider_layout[i, 2], range = 0:0.1:1, width = 200)
            control_objects[i] = sl
            selector_values[i] = sl.value
            
            # EXPOSE RANGES AND VALUES
            manager.controls["$(dim_names[i])_Value"] = sl.value
            manager.controls["$(dim_names[i])_Range"] = sl.range
            manager.controls["$(dim_names[i])_Widget"] = sl  # <-- ADD THIS
        end
        
        Label(slider_layout[i, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), selector_values[i]), width=50)
    end

    # 5. Handle Overwrites/Locks via base_types
    on(manager.controls["Simulation_Update"]) do _
        vt = manager.controls["base_types"][]
        for base_idx in 1:(D+2)
            abs_idx = n_params + base_idx
            ctrl = control_objects[abs_idx]
            val = vt[base_idx]
            
            if val isa Number
                if ctrl isa Slider
                    ctrl.range[] = [val] 
                elseif ctrl isa Menu
                    ctrl.options[] = [string(val)]
                    ctrl.selection[] = string(val)
                end
            end
        end
    end

# --- REACTIVE LOGIC: Axis Menus Cascade ---
    
    on(plot_data_obs) do plot_data_dict
        isempty(plot_data_dict) && return
        active_methods = manager.methods[]
        
        # 1. Update X Options
        all_keys = Set{String}()
        for (m, pd) in plot_data_dict
            if m in active_methods
                union!(all_keys, keys(pd.data))
            end
        end
        sorted_keys = sort(collect(all_keys))
        
        menu_x.options[] = sorted_keys
    end

    on(menu_x.selection) do x_val
        (isnothing(x_val) || x_val == "-") && return
        plot_data_dict = plot_data_obs[]
        active_methods = manager.methods[]
        
        # 2. Update Y Options
        varied_dims = nothing
        for (m, pd) in plot_data_dict
            !(m in active_methods) && continue
            if haskey(pd.data, x_val)
                v_dims = Set(findall(s -> s > 1, size(pd.data[x_val])))
                varied_dims = isnothing(varied_dims) ? v_dims : intersect(varied_dims, v_dims)
            end
        end
        varied_dims = isnothing(varied_dims) ? Set{Int}() : varied_dims
        
        valid_y = String[]
        for y_can in menu_x.options[]
            y_varied = nothing
            for (m, pd) in plot_data_dict
                !(m in active_methods) && continue
                if haskey(pd.data, y_can)
                    v_dims = Set(findall(s -> s > 1, size(pd.data[y_can])))
                    y_varied = isnothing(y_varied) ? v_dims : intersect(y_varied, v_dims)
                end
            end
            y_varied = isnothing(y_varied) ? Set{Int}() : y_varied
            if !isempty(intersect(varied_dims, y_varied))
                push!(valid_y, y_can)
            end
        end
        
        menu_y.options[] = valid_y
        x_key_obs[] = x_val
        
    end

    on(menu_y.selection) do y_val
        (isnothing(y_val) || y_val == "-") && return
        x_val = menu_x.selection[]
        plot_data_dict = plot_data_obs[]
        active_methods = manager.methods[]
        
        # 3. Update Axis Options
        x_varied, y_varied = nothing, nothing
        for (m, pd) in plot_data_dict
            !(m in active_methods) && continue
            if haskey(pd.data, x_val)
                v_dims = Set(findall(s -> s > 1, size(pd.data[x_val])))
                x_varied = isnothing(x_varied) ? v_dims : intersect(x_varied, v_dims)
            end
            if haskey(pd.data, y_val)
                v_dims = Set(findall(s -> s > 1, size(pd.data[y_val])))
                y_varied = isnothing(y_varied) ? v_dims : intersect(y_varied, v_dims)
            end
        end
        
        x_varied = isnothing(x_varied) ? Set{Int}() : x_varied
        y_varied = isnothing(y_varied) ? Set{Int}() : y_varied
        
        common = sort(collect(intersect(x_varied, y_varied)))
        menu_axis.options[] = isempty(common) ? [("-", 1)] : [(dim_names[d], d) for d in common]
        y_key_obs[] = y_val
        
        if menu_axis.selection[] == "-" || menu_axis.selection[] ∉ common
            menu_axis.selection[] = isempty(common) ? 1 : common[end]
            menu_axis.i_selected[] = isempty(common) ? 1 : length(common)
        else
            notify(menu_axis.selection)
        end
    end

    # 4. Bind Checkboxes to the UI Menus directly!
    on(manager.methods) do _
        # When a checkbox changes, artificially "poke" the data to force the axis menus to recalculate
        notify(plot_data_obs)
    end
    # --- REACTIVE LOGIC: Sliders Ranges ---
    
    on(menu_axis.selection) do axis_idx
        (isnothing(axis_idx) || axis_idx == "-") && return
        plot_dim_idx_obs[] = axis_idx
        
        plot_data_dict = plot_data_obs[] 
        vt = manager.controls["base_types"][]

        for i in 1:total_dims
            is_basevar = i > n_params
            if is_basevar
                base_idx = i - n_params
                vt[base_idx] isa Number && continue
            end
            
            ctrl = control_objects[i]
            is_axis = (i == axis_idx)
            
            g_min, g_max = Inf, -Inf
            for pd in values(plot_data_dict)
                vals = nothing
                if i <= n_params 
                    vals = pd.active_param_values[i]
                elseif i == n_params + 1 
                    vals = [1.0, Float64(size(pd.data["u"], length(pd.active_param_keys) + 1))]
                elseif i > n_params + 1 && i < total_dims 
                    x_data = get(pd.data, "x", nothing)
                    if !isnothing(x_data) && !all(isnan.(x_data)); vals = filter(!isnan, x_data); end
                elseif i == total_dims 
                    vals = pd.t_vals
                end
                
                if !isnothing(vals) && !isempty(vals)
                    l, h = extrema(vals)
                    if l < g_min; g_min = l; end
                    if h > g_max; g_max = h; end
                end
            end
            
            if isinf(g_min); g_min = 0.0; g_max = 1.0; end
            
            if is_axis
                if ctrl isa Slider; ctrl.range[] = [0]; else; ctrl.options[] = ["-"]; end
            else
                if ctrl isa Slider
                    ctrl.range[] = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
                end
            end
        end
    end

    return x_key_obs, y_key_obs, plot_dim_idx_obs, selector_values, control_objects
end

"""
    create_hierarchical_param_controls!(layout, manager::PlotManager)

Creates a 3-menu + 1-textbox interface to navigate and edit all parameters.
"""
function create_hierarchical_param_controls!(layout::GridLayout, mgr::PlotManager)
    # 1. Menus
    # Categories are fixed strings matching the field names (capitalized for UI)
    cat_mapping = Dict("Simulation" => :simulation, "UI" => :ui, "Controls" => :controls)
    sorted_cat = sort(collect(keys(cat_mapping)))
    menu_cat = Menu(layout[1, 1], options = sorted_cat, prompt = "Category...",width = 120)
    menu_cat.i_selected[] = 0
    menu_scope = Menu(layout[1, 2], options = ["-"], default = "-", prompt = "Scope...",width = 120)
    menu_scope.i_selected[] = 0
    menu_key = Menu(layout[1, 3], options = ["-"], default = "-", prompt = "Key...",width = 120)
    menu_key.i_selected[] = 0
    
    active_target_obs = Observable{Any}(nothing)
    ui_update = Observable{Int}(0)
    # 2. Category -> Scope (Accessing fields directly)
    on(menu_cat.selection) do cat
        isnothing(cat) && return
        field_name = cat_mapping[cat]
        data = getproperty(mgr, field_name)
        
        if field_name == :controls
            menu_scope.options[] = ["Live"] # Flat dict has one virtual scope
        else
            menu_scope.options[] = sort(collect(keys(data)))
        end
        menu_scope.selection[] = nothing
    end

    # 3. Scope -> Key
    on(menu_scope.selection) do scope
        isnothing(scope) && return
        cat = menu_cat.selection[]
        field_name = cat_mapping[cat]
        data = getproperty(mgr, field_name)
        
        if field_name == :controls
            menu_key.options[] = sort(collect(keys(data)))
        else
            menu_key.options[] = sort(collect(keys(data[scope])))
        end
    end

    # 4. Textbox with Live Placeholder
    Label(layout[2, 1], "Edit Value:", halign=:right)
    
    # Show what is currently loaded in the plot
    placeholder_text = lift(menu_key.selection) do k
        isnothing(k) && return "Select key..."
        val = get(mgr.last_run_params, k, "default")
        return "Loaded: $val"
    end

    tb = Textbox(layout[2, 2:3], placeholder = placeholder_text, reset_on_defocus = true,width = 250)

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
    mgr.controls["UI_Update"] = ui_update
    return
end
