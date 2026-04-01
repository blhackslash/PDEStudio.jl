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
)
    GLMakie.activate!()
    plot_screen = GLMakie.Screen(title = "Makie Plot")
    # 2. FIX: Attach the Figure to the Screen immediately
    display(plot_screen, plot_fig)
    
    base_controls_fig = Figure(size = (450, 1000)) 
    fig_layout = base_controls_fig.layout[1,1] = GridLayout(tellheight=false)
    rowgap!(fig_layout, 15) 
    current_row = 1

    active_params = manager.plot_vars
    n_params = length(active_params)
    
    if !haskey(manager.controls, "base_types")
        # Default symbols from VariableControls
        defaults = vcat(fill(:slider, n_params), :menu, fill(:slider, 4))
        manager.controls["base_types"] = Observable(defaults)
    end

    # 1. HEADER & REFRESH
    header_layout = fig_layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Simulation Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1
    
    update_layout = fig_layout[current_row, 1] = GridLayout()
    update_button = Button(update_layout[1,1], label="Refresh / Run Simulation", 
                           width=190, buttoncolor=:lightgreen)
    
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
    
    method_button = Button(update_layout[1, 2], label="Select Methods...", 
                           width=190, buttoncolor=:lightgray)
    
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
    # ADD plot_data_obs here!
    create_base_overwrite_controls!(lock_layout, manager, plot_data_obs) 
    current_row += 1
    # 5. STATIC PLOT CONTROLS SLOT
    Label(fig_layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
    Label(fig_layout[current_row, 1], "Data Exploration (Axes & Sliders)", 
          fontsize=16, font=:bold, color=:darkgreen)
    current_row += 1
    
# STATIC PLOT CONTROLS SLOT
    menu_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1

    # Updated to return active_axes_obs instead of plot_dim_idx_obs
    x_obs, y_obs, z_obs, u_obs, active_axes_obs, selectors, widgets = build_static_plot_controls!(
        menu_area, slider_area, plot_data_obs, active_params, manager
    )

    # 4. ANIMATION PREVIEW
    Label(fig_layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
    Label(fig_layout[current_row, 1], "Animation Preview:", fontsize=16, font=:bold, color=:darkorange)
    current_row += 1
    
    anim_layout = fig_layout[current_row, 1] = GridLayout()
    anim_target_obs = createAnimationPreview!(anim_layout, manager, active_axes_obs, widgets, active_params)
    current_row += 1

    # 5. EXPORT OPTIONS
    Label(fig_layout[current_row, 1], "Export Options:", fontsize=16, font=:bold, color=:purple)
    current_row += 1
    
    export_layout = fig_layout[current_row, 1] = GridLayout()
    createExportOptions!(export_layout, plot_fig, manager, anim_target_obs, active_axes_obs, widgets, active_params)
    current_row += 1

    display(GLMakie.Screen(title="Makie Controls"), base_controls_fig)

    return base_controls_fig
end
function build_static_plot_controls!(
    menu_layout::GridLayout, 
    slider_layout::GridLayout, 
    plot_data_obs::Observable,
    active_params::Vector{String}, 
    manager::PlotManager
)
    # 1. Metadata & Initialization
    dim_names = active_params
    total_dims = length(dim_names)
    n_params = total_dims - 5
    comp_idx = n_params + 1 # The exact index of the Component dimension
    
    x_key_obs = Observable{String}("-")
    y_key_obs = Observable{String}("-")
    z_key_obs = Observable{String}("-")
    u_key_obs = Observable{String}("-")
    plot_dim_idx_obs = Observable{Int}(0)
    plot_dim_obs = Observable{Int}(1) # NEW: Master dimension observable
    manager.controls["Plot_Dimension"] = plot_dim_obs
    
    control_objects = Vector{Any}(undef, total_dims)
    selector_values = Vector{Observable}(undef, total_dims)

    # 2. Setup Menus Grid



    # Row 2 & 3: Independent Axes
    Label(menu_layout[1,1], "X-Axis", font=:bold)
    Label(menu_layout[1,2], "Y-Axis", font=:bold)
    Label(menu_layout[1,3], "Z-Axis", font=:bold)
    menu_x = Menu(menu_layout[2,1], options = ["-"], width = 120)
    menu_y = Menu(menu_layout[2,2], options = ["disabled"], width = 120)
    menu_z = Menu(menu_layout[2,3], options = ["disabled"], width = 120)

# Row 4 & 5: Dependent Axis, Component (REMOVED Plot-Along)
    Label(menu_layout[3,1], "U-Axis (Dep)", font=:bold)
    Label(menu_layout[3,2], "Component", font=:bold)
    menu_u    = Menu(menu_layout[4,1], options = ["-"], width = 120)
    menu_comp = Menu(menu_layout[4,2], options = ["1"], width = 120)
    # Row 1: Plot Type Selection
    Label(menu_layout[3,3], "Plot Type", font=:bold)
    plot_options = ["Lines", "Heatmap", "Contour", "Contourf", "Volume","Contour 3D", "Surface", "Scatter 2D", "Scatter 3D"]
    menu_type = Menu(menu_layout[4,3], options = plot_options, width = 120)
    menu_type.i_selected[] = 1
    colsize!(menu_layout, 1, Fixed(120))
    colsize!(menu_layout, 2, Fixed(120))
    colsize!(menu_layout, 3, Fixed(120))    

    # --- NEW: Master Active Axes Tracker ---
    active_axes_obs = Observable{Vector{Int}}(Int[])
    manager.controls["Active_Axes"] = active_axes_obs

    # EXPOSE OPTIONS AND SELECTIONS
    manager.controls["X-Axis_Selection"], manager.controls["X-Axis_Options"], manager.controls["X-Axis_Widget"] = menu_x.selection, menu_x.options, menu_x
    manager.controls["Y-Axis_Selection"], manager.controls["Y-Axis_Options"], manager.controls["Y-Axis_Widget"] = menu_y.selection, menu_y.options, menu_y
    manager.controls["Z-Axis_Selection"], manager.controls["Z-Axis_Options"], manager.controls["Z-Axis_Widget"] = menu_z.selection, menu_z.options, menu_z
    manager.controls["U-Axis_Selection"], manager.controls["U-Axis_Options"], manager.controls["U-Axis_Widget"] = menu_u.selection, menu_u.options, menu_u
    plot_type_obs = Observable{Symbol}(:lines)
    manager.controls["Plot-Type_Selection"] = plot_type_obs

    on(menu_type.selection) do raw_str
        # Convert "Scatter 2D" to :scatter2d
        ptype_sym = Symbol(lowercase(replace(raw_str, " " => "")))
        
        plot_type_obs[] = ptype_sym
        
        # When applied, force the Y and Z menus to respect the new dimensionality
        notify(plot_data_obs) 
    end
    # Map the isolated Component Menu
    control_objects[comp_idx] = menu_comp
    selector_values[comp_idx] = Observable{Int}(1)
    on(menu_comp.selection) do s
        if !isnothing(s) && s != "-" && s != "disabled"
            selector_values[comp_idx][] = parse(Int, s)
        end
    end
    manager.controls["$(dim_names[comp_idx])_Selection"], manager.controls["$(dim_names[comp_idx])_Options"], manager.controls["$(dim_names[comp_idx])_Widget"] = menu_comp.selection, menu_comp.options, menu_comp

    # 3. Unified Widget Creation (Sliders Only now)
    current_row = 1
    for i in 1:total_dims
        if i == comp_idx
            continue # Skipped because it's now cleanly integrated into the top menu block
        end
        
        Label(slider_layout[current_row, 1], "$(dim_names[i]):", halign=:right)
        
        is_basevar = i > n_params
        ctrl_type = is_basevar ? VariableControls[i - n_params] : :slider
        
        if ctrl_type == :menu
            m = Menu(slider_layout[current_row, 2], options = ["1"], width = 200)
            control_objects[i] = m
            selector_values[i] = Observable{Int}(1)
            on(m.selection) do s
                if !isnothing(s) && s != "-"; selector_values[i][] = parse(Int, s); end
            end
            manager.controls["$(dim_names[i])_Selection"], manager.controls["$(dim_names[i])_Options"], manager.controls["$(dim_names[i])_Widget"] = m.selection, m.options, m
        else
            sl = Slider(slider_layout[current_row, 2], range = 0:0.1:1, width = 200)
            control_objects[i] = sl
            selector_values[i] = sl.value
            manager.controls["$(dim_names[i])_Value"], manager.controls["$(dim_names[i])_Range"], manager.controls["$(dim_names[i])_Widget"] = sl.value, sl.range, sl
        end
        
        Label(slider_layout[current_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), selector_values[i]), width=50)
        current_row += 1
    end

    # 4. Handle Overwrites/Locks via base_types
    on(manager.controls["Simulation_Update"]) do _
        vt = manager.controls["base_types"][]
        for base_idx in 1:5
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
        notify(plot_data_obs)      
    end

    # --- REACTIVE LOGIC: Axis Menus Cascade ---
    
    function get_varied_dims(key_val, plot_data_dict, active_methods)
        v_dims = nothing
        for (m, pd) in plot_data_dict
            !(m in active_methods) && continue
            if haskey(pd.data, key_val)
                curr_dims = Set(findall(s -> s > 1, size(pd.data[key_val])))
                v_dims = isnothing(v_dims) ? curr_dims : intersect(v_dims, curr_dims)
            end
        end
        return isnothing(v_dims) ? Set{Int}() : v_dims
    end

    on(plot_data_obs) do plot_data_dict
        isempty(plot_data_dict) && return
        active_methods = manager.methods[]
        
        all_keys = Set{String}()
        comp_max = 1
        for (m, pd) in plot_data_dict
            if m in active_methods
                for (key, tensor) in pd.data
                    if any(s -> s > 1, size(tensor))
                        push!(all_keys, key)
                    end
                end
                if haskey(pd.data, "u")
                    comp_max = max(comp_max, size(pd.data["u"], comp_idx))
                end
            end
        end
        sorted_keys = sort(collect(all_keys))

        # Update Component Dropdown
        comp_opts = [string(i) for i in 1:comp_max]
        if menu_comp.selection[] ∉ comp_opts
            menu_comp.options[] = comp_opts
            menu_comp.i_selected[] = 1
        else
            menu_comp.options[] = comp_opts
        end

        # Update U-Axis (Dependent) Dropdown
        current_u = menu_u.selection[]
        menu_u.options[] = isempty(sorted_keys) ? ["-"] : sorted_keys
        if current_u == "-" || isnothing(current_u) || current_u ∉ sorted_keys
            u_idx = findfirst(isequal("u"), sorted_keys)
            menu_u.i_selected[] = isnothing(u_idx) ? (isempty(sorted_keys) ? 0 : 1) : u_idx
        else
            menu_u.i_selected[] = findfirst(isequal(current_u), sorted_keys)
        end

        # Update X-Axis
        current_x = menu_x.selection[]
        menu_x.options[] = isempty(sorted_keys) ? ["-"] : sorted_keys
        if current_x == "-" || isnothing(current_x) || current_x ∉ sorted_keys
            menu_x.i_selected[] = isempty(sorted_keys) ? 0 : 1 
        else
            menu_x.i_selected[] = findfirst(isequal(current_x), sorted_keys)
        end
        notify(menu_x.selection)
    end

    on(menu_x.selection) do x_val
        (isnothing(x_val) || x_val == "-") && return
        p_dim = PLOT_DIM_MAP[manager.controls["Plot-Type_Selection"][]]
        if p_dim < 2
            menu_y.options[] = ["disabled"]
            menu_y.i_selected[] = 1
            notify(menu_y.selection)
            return
        end
        
        plot_data_dict = plot_data_obs[]
        active_methods = manager.methods[]
        x_varied = get_varied_dims(x_val, plot_data_dict, active_methods)
        
        valid_y = String[]
        for y_can in menu_x.options[]
            y_varied = get_varied_dims(y_can, plot_data_dict, active_methods)
            if !isempty(intersect(x_varied, y_varied))
                push!(valid_y, y_can)
            end
        end
        
        current_y = menu_y.selection[]
        menu_y.options[] = isempty(valid_y) ? ["-"] : valid_y
        if current_y == "-" || current_y == "disabled" || isnothing(current_y) || current_y ∉ valid_y
            menu_y.i_selected[] = isempty(valid_y) ? 0 : 1 
        else
            menu_y.i_selected[] = findfirst(isequal(current_y), valid_y)
        end
        x_key_obs[] = x_val
        notify(menu_y.selection)
    end

    on(menu_y.selection) do y_val
        (isnothing(y_val) || y_val == "-") && return
        p_dim = PLOT_DIM_MAP[manager.controls["Plot-Type_Selection"][]]
        if y_val == "disabled" || p_dim < 3
            menu_z.options[] = ["disabled"]
            menu_z.i_selected[] = 1
            notify(menu_z.selection)
            return
        end
        
        x_val = menu_x.selection[]
        plot_data_dict = plot_data_obs[]
        active_methods = manager.methods[]
        
        xy_varied = intersect(get_varied_dims(x_val, plot_data_dict, active_methods), 
                              get_varied_dims(y_val, plot_data_dict, active_methods))
        
        valid_z = String[]
        for z_can in menu_x.options[]
            z_varied = get_varied_dims(z_can, plot_data_dict, active_methods)
            if !isempty(intersect(xy_varied, z_varied))
                push!(valid_z, z_can)
            end
        end
        
        current_z = menu_z.selection[]
        menu_z.options[] = isempty(valid_z) ? ["-"] : valid_z
        if current_z == "-" || current_z == "disabled" || isnothing(current_z) || current_z ∉ valid_z
            menu_z.i_selected[] = isempty(valid_z) ? 0 : 1 
        else
            menu_z.i_selected[] = findfirst(isequal(current_z), valid_z)
        end
        y_key_obs[] = y_val
        notify(menu_z.selection)
    end

# --- MULTIDIMENSIONAL AXES TRACKER ---
    onany(menu_x.selection, menu_y.selection, menu_z.selection, manager.controls["Plot-Type_Selection"]) do x_val, y_val, z_val, ptype
        p_dim = PLOT_DIM_MAP[ptype]
        axes = Int[]
        
        for (dim_req, val) in zip([1, 2, 3], [x_val, y_val, z_val])
            if p_dim >= dim_req && !isnothing(val) && val != "-" && val != "disabled"
                idx = findfirst(isequal(val), dim_names)
                !isnothing(idx) && push!(axes, idx)
            end
        end
        
        active_axes_obs[] = axes
    end

    # --- REACTIVE LOGIC: Sliders Ranges ---
    # Sliders now dynamically react to BOTH axis changes and data dictionary updates
    onany(active_axes_obs, plot_data_obs) do active_axes, plot_data_dict
        isempty(plot_data_dict) && return
        vt = manager.controls["base_types"][]

        for i in 1:total_dims
            is_basevar = i > n_params
            if is_basevar
                base_idx = i - n_params
                vt[base_idx] isa Number && continue
            end
            
            ctrl = control_objects[i]
            
            # THE CRITICAL FIX: Multidimensional slider locking!
            is_axis = (i in active_axes) 
            
            g_min, g_max = Inf, -Inf
            for pd in values(plot_data_dict)
                vals = nothing
                if i <= n_params 
                    vals = pd.active_param_values[i]
                elseif i == n_params + 1 
                    vals = [1.0, Float64(size(pd.data["u"], length(pd.active_param_keys) + 1))]
                elseif i > n_params + 1 && i < total_dims 
                    dim_idx = i - (n_params + 1)
                    x_tensor = get(pd.data, "x", nothing)
                    
                    if !isnothing(x_tensor) && !all(isnan.(x_tensor))
                        grid_c = size(x_tensor, n_params + 1)
                        if grid_c == 3 
                            inds = ntuple(d -> d == n_params + 1 ? dim_idx : (:), ndims(x_tensor))
                            vals = filter(!isnan, x_tensor[inds...])
                        elseif dim_idx == 1 
                            vals = filter(!isnan, x_tensor)
                        else 
                            sz = size(pd.data["u"], i)
                            vals = sz == 1 ? [0.0] : [1.0, Float64(sz)]
                        end
                    else
                        sz = size(pd.data["u"], i)
                        vals = sz == 1 ? [0.0] : [1.0, Float64(sz)]
                    end
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

    return x_key_obs, y_key_obs, z_key_obs, u_key_obs, active_axes_obs, selector_values, control_objects

    on(menu_u.selection) do u_val
        (isnothing(u_val) || u_val == "-") && return
        u_key_obs[] = u_val
        notify(menu_z.selection) # Re-evaluate common dims for Plot-Along axis!
    end

    on(manager.methods) do _
        notify(plot_data_obs)
    end

    return x_key_obs, y_key_obs, z_key_obs, u_key_obs, plot_dim_idx_obs, selector_values, control_objects
end

"""
    create_hierarchical_param_controls!(layout, manager::PlotManager)

Creates a 3-menu + 1-textbox interface to navigate and edit all parameters.
"""
function create_hierarchical_param_controls!(layout::GridLayout, mgr::PlotManager)
    # 1. Menus
    # Categories are fixed strings matching the field names (capitalized for UI)
    cat_mapping = Dict("Simulation" => :simulation, "UI" => :ui)
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
        
        menu_scope.options[] = sort(collect(keys(data)))
    end

    # 3. Scope -> Key
    on(menu_scope.selection) do scope
        isnothing(scope) && return
        cat = menu_cat.selection[]
        field_name = cat_mapping[cat]
        data = getproperty(mgr, field_name)
        
        menu_key.options[] = sort(collect(keys(data[scope])))
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
    # 1. Convert the value to a string
        val_str = string(to_value(obs))
        
        # 2. Update both the stored and the displayed observables
        tb.stored_string[] = val_str
        tb.displayed_string[] = val_str  # This forces the text to appear visually
        
        # 3. Programmatically focus the textbox
        #tb.focused[] = true
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
