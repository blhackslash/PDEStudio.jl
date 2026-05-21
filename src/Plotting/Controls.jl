"""
    create_controls(...)

Creates the static UI window. The Menus and Sliders are generated once based 
on the maximum dimensionality of the simulation.
"""
function create_controls(
    plot_fig::Makie.Figure, 
    manager::PlotManager, 
    plot_data_obs::Observable, 
    scene_options::Dict = Dict{String, Any}() 
)
    base_controls_fig = Figure(size=(500,1000)) 
    fig_layout = base_controls_fig.layout[1,1] = GridLayout()
    rowgap!(fig_layout, 15) 
    current_row = 1

    window_rect = events(base_controls_fig).window_area

    # 2. Wir "liften" die Breite (die Breite ist das erste Element der widths)
    window_width = lift(rect -> floor(Int,rect.widths[1]*.95), window_rect)

    active_params = manager.plot_vars
    n_params = length(active_params)
    
    if !haskey(manager.controls, "base_types")
        defaults = vcat(fill(:slider, n_params), :menu, fill(:slider, 4))
        manager.controls["base_types"] = Observable(defaults)
    end

    # 1. HEADER & REFRESH
    header_layout = fig_layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Simulation Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1
    
    update_layout = fig_layout[current_row, 1] = GridLayout(width=window_width)
    
    # THE FIX: width=nothing für volle Flexibilität
    update_button  = Button(update_layout[1,1], label="Refresh / Run", width=nothing, buttoncolor=:lightgreen)
    method_button  = Button(update_layout[1,2], label="Methods...", width=nothing, buttoncolor=:lightgray)
    
    # THE FIX: Exakt 50% Breite für beide
    colsize!(update_layout, 1, Relative(0.5))
    colsize!(update_layout, 2, Relative(0.5))
    
    update_notifier = Observable(0)
    manager.controls["Simulation_Update"] = update_notifier
    
    on(update_button.clicks) do _
        update_notifier[] += 1
    end
    
    on(method_button.clicks) do _
        all_method_names = sort(filter(k -> k != "shared", collect(keys(manager.simulation))))
        m_fig, _ = create_method_checkboxes_figure(all_method_names, manager.methods; target_rows = 20)
        if !isnothing(m_fig); display(m_fig); end
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
    create_base_overwrite_controls!(lock_layout, manager, plot_data_obs) 
    current_row += 1
    
    # 5. STATIC PLOT CONTROLS SLOT
    Label(fig_layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
    
    menu_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1

    x_obs, y_obs, z_obs, u_obs, active_axes_obs, selectors, widgets = build_static_plot_controls!(
        menu_area, slider_area, plot_data_obs, active_params, manager, scene_options
    )

    Label(fig_layout[current_row, 1], "Export & Save Options:", fontsize=16, font=:bold, color=:purple)
    current_row += 1
    
    export_layout = fig_layout[current_row, 1] = GridLayout()
    # anim_target_obs kommt jetzt aus dem static plot controls dict!
    anim_target_obs = manager.controls["Anim-Target_Selection"]
    createExportOptions!(export_layout, plot_fig, manager, anim_target_obs, active_axes_obs, widgets, active_params)
    current_row += 1

    display(GLMakie.Screen(title="Makie Controls"), base_controls_fig)

    return base_controls_fig
end
function build_static_plot_controls!(
    menu_layout::GridLayout, slider_layout::GridLayout, plot_data_obs::Observable, active_params::Vector{String}, manager::PlotManager, scene_options::Dict = Dict{String, Any}()
)
    dim_names = active_params
    total_dims = length(dim_names)
    n_params = total_dims - 5
    comp_idx = n_params + 1 
    
    x_key_obs = Observable{String}("-"); y_key_obs = Observable{String}("-"); z_key_obs = Observable{String}("-"); u_key_obs = Observable{String}("-")
    plot_dim_obs = Observable{Int}(1)
    manager.controls["Plot_Dimension"] = plot_dim_obs
    
    control_objects = Vector{Any}(undef, total_dims)
    selector_values = Vector{Observable}(undef, total_dims)

    init_x = string(get(scene_options, "X-Axis_Selection", "-"))
    init_y = string(get(scene_options, "Y-Axis_Selection", "disabled"))
    init_z = string(get(scene_options, "Z-Axis_Selection", "disabled"))
    init_u = string(get(scene_options, "U-Axis_Selection", "-"))
    init_comp = string(get(scene_options, "c_Selection", "1"))
    
    # 1. REIHE: Die Achsen
    Label(menu_layout[1,1], "X-Axis", font=:bold); Label(menu_layout[1,2], "Y-Axis", font=:bold)
    Label(menu_layout[1,3], "Z-Axis", font=:bold); Label(menu_layout[1,4], "U-Axis (Dep)", font=:bold)
    
    menu_x = Menu(menu_layout[2,1], options = [init_x])
    menu_y = Menu(menu_layout[2,2], options = [init_y])
    menu_z = Menu(menu_layout[2,3], options = [init_z])
    menu_u = Menu(menu_layout[2,4], options = [init_u])
    menu_x.i_selected = 1; menu_y.i_selected = 1; menu_z.i_selected = 1; menu_u.i_selected = 1

    # 2. REIHE: Compare & Animation
    Label(menu_layout[3,1], "Compare Target", font=:bold, color=:darkorange)
    Label(menu_layout[3,2], "Grid Columns", font=:bold, color=:darkorange)
    Label(menu_layout[3,3], "Compare Link", font=:bold, color=:darkorange)
    Label(menu_layout[3,4], "Anim Target", font=:bold, color=:darkorange)

    compare_targets = ["None", "Methods", "Component", "Time"]
    append!(compare_targets, filter(p -> p ∉ ["c", "x", "y", "z", "t"], active_params))

    menu_tgt  = Menu(menu_layout[4,1], options = compare_targets)
    menu_cols = Menu(menu_layout[4,2], options = ["1", "2", "3", "4", "5"])
    menu_link = Menu(menu_layout[4,3], options = ["Fully Coupled", "Coupled Colorbar", "Decoupled"])
    
    # --- THE FIX: Animation Menu direkt mit Tuples initialisieren ---
    dim_names_anim = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names_anim[i] = p; end
    dim_names_anim[n_params+1] = "Component"
    dim_names_anim[n_params+2] = "Space"
    dim_names_anim[n_params+3] = "Time"
    
    all_opts = [(dim_names_anim[i], i) for i in 1:total_dims]
    
    menu_anim = Menu(menu_layout[4,4], options = all_opts)
    init_anim = get(scene_options, "Anim-Target_Selection", total_dims)
    menu_anim.i_selected[] = init_anim

    # 3. REIHE: Legende, Plot Typ & Component
    Label(menu_layout[5,1], "Legend Base", font=:bold, color=:darkorchid)
    Label(menu_layout[5,2], "Legend Modifier", font=:bold, color=:darkorchid)
    Label(menu_layout[5,3], "Plot Type", font=:bold)
    Label(menu_layout[5,4], "Component", font=:bold)

    leg_base_opts = ["none", "center", "left", "right", "top", "bottom"]
    leg_add_opts  = ["none", "detached", "left", "right", "top", "bottom"]
    plot_options = [
        ("Lines", :lines), ("Heatmap", :heatmap), ("Contour", :contour), 
        ("Contourf", :contourf), ("Volume", :volume), ("Contour 3D", :contour3d), 
        ("Surface", :surface), ("Scatter 2D", :scatter2d), ("Scatter 3D", :scatter3d)
    ]
    
    menu_lbase = Menu(menu_layout[6,1], options = leg_base_opts)
    menu_ladd  = Menu(menu_layout[6,2], options = leg_add_opts)
    menu_type  = Menu(menu_layout[6,3], options = plot_options)
    menu_comp  = Menu(menu_layout[6,4], options = [init_comp]); menu_comp.i_selected = 1

    init_lbase = string(get(scene_options, "Legend_Base_Selection", "right"))
    init_ladd  = string(get(scene_options, "Legend_Add_Selection", "detached"))
    raw_type   = get(scene_options, "Plot-Type_Selection", :lines)
    init_type_sym = raw_type isa String ? Symbol(lowercase(replace(raw_type, " " => ""))) : raw_type

    idx_lbase = findfirst(isequal(init_lbase), leg_base_opts); menu_lbase.i_selected[] = isnothing(idx_lbase) ? 4 : idx_lbase
    idx_ladd  = findfirst(isequal(init_ladd), leg_add_opts); menu_ladd.i_selected[] = isnothing(idx_ladd) ? 2 : idx_ladd
    idx_type  = findfirst(x -> x[2] == init_type_sym, plot_options); menu_type.i_selected[] = isnothing(idx_type) ? 1 : idx_type

    # 4. REIHE: Plot Sizes
    Label(menu_layout[7,1], "Plot Width", font=:bold, color=:teal)
    Label(menu_layout[7,2], "Plot Height", font=:bold, color=:teal)
    
    size_opts = [string(i) for i in 100:100:1000]
    menu_w = Menu(menu_layout[8,1], options = size_opts)
    menu_h = Menu(menu_layout[8,2], options = size_opts)

    init_w = string(get(scene_options, "Plot-Width_Selection", "500"))
    init_h = string(get(scene_options, "Plot-Height_Selection", "400"))
    idx_w = findfirst(isequal(init_w), size_opts); menu_w.i_selected[] = isnothing(idx_w) ? 5 : idx_w
    idx_h = findfirst(isequal(init_h), size_opts); menu_h.i_selected[] = isnothing(idx_h) ? 4 : idx_h

    # Manager Updates
    manager.controls["Compare_Target_Selection"] = menu_tgt.selection
    manager.controls["Compare_Columns_Selection"] = menu_cols.selection
    manager.controls["Compare_Link_Selection"] = menu_link.selection
    manager.controls["Legend_Base_Selection"] = menu_lbase.selection
    manager.controls["Legend_Add_Selection"] = menu_ladd.selection
    manager.controls["Plot-Width_Selection"] = menu_w.selection
    manager.controls["Plot-Height_Selection"] = menu_h.selection
    manager.controls["Anim-Target_Selection"] = menu_anim.selection

    # Spaltengrößen automatisch anpassen statt fest auf 120px
    for i in 1:4
        colsize!(menu_layout, i, Relative(0.25)) 
    end

    active_axes_obs = Observable{Vector{Int}}(Int[])
    manager.controls["Active_Axes"] = active_axes_obs

    manager.controls["X-Axis_Selection"], manager.controls["X-Axis_Options"], manager.controls["X-Axis_Widget"] = menu_x.selection, menu_x.options, menu_x
    manager.controls["Y-Axis_Selection"], manager.controls["Y-Axis_Options"], manager.controls["Y-Axis_Widget"] = menu_y.selection, menu_y.options, menu_y
    manager.controls["Z-Axis_Selection"], manager.controls["Z-Axis_Options"], manager.controls["Z-Axis_Widget"] = menu_z.selection, menu_z.options, menu_z
    manager.controls["U-Axis_Selection"], manager.controls["U-Axis_Options"], manager.controls["U-Axis_Widget"] = menu_u.selection, menu_u.options, menu_u
    
    plot_type_obs = Observable{Symbol}(init_type_sym)
    manager.controls["Plot-Type_Selection"] = plot_type_obs

    on(menu_type.selection) do ptype_sym
        # Makie liefert uns direkt das Symbol, kein String-Parsing mehr nötig!
        plot_type_obs[] = ptype_sym
    end

    control_objects[comp_idx] = menu_comp
    selector_values[comp_idx] = Observable{Int}(1)
    on(menu_comp.selection) do s
        if !isnothing(s) && s != "-" && s != "disabled"
            selector_values[comp_idx][] = parse(Int, s)
        end
    end
    manager.controls["$(dim_names[comp_idx])_Selection"], manager.controls["$(dim_names[comp_idx])_Options"], manager.controls["$(dim_names[comp_idx])_Widget"] = menu_comp.selection, menu_comp.options, menu_comp

    current_row = 1
    for i in 1:total_dims
        if i == comp_idx; continue; end 
        
        Label(slider_layout[current_row, 1], "$(dim_names[i]):", halign=:right)
        val_key = "$(dim_names[i])_Value"
        init_val = Float64(get(scene_options, val_key, 0.0))
        
        # THE FIX: width=nothing statt 200 erlaubt dem Slider, die Spalte voll zu nutzen
        sl = Slider(slider_layout[current_row, 2], range = [init_val], startvalue = init_val, width=nothing)
        control_objects[i] = sl
        selector_values[i] = sl.value
      
        manager.controls["$(dim_names[i])_Value"], manager.controls["$(dim_names[i])_Range"], manager.controls["$(dim_names[i])_Widget"] = sl.value, sl.range, sl
        Label(slider_layout[current_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), selector_values[i]), halign=:left)
        current_row += 1
    end

    # THE FIX: Platz optimal aufteilen: Label fixiert, Slider expandiert flexibel
    colsize!(slider_layout, 1, Fixed(40))    
    colsize!(slider_layout, 2, Relative(0.7)) 
    colsize!(slider_layout, 3, Fixed(60))

    on(manager.controls["Simulation_Update"]) do _
        vt = manager.controls["base_types"][]
        for base_idx in 1:5
            abs_idx = n_params + base_idx
            abs_idx == comp_idx && continue
            
            ctrl = control_objects[abs_idx]
            val = vt[base_idx]
            
            if val isa Number
                ctrl.range[] = [Float64(val)] 
            end
        end
        notify(plot_data_obs)     
    end

    function _update_menu!(menu, new_options; fallbacks=["x", "y", "z", "t"])
        curr = menu.selection[]
        menu.options[] = isempty(new_options) ? ["-"] : new_options
        if curr == "-" || isnothing(curr) || curr ∉ new_options
            if isempty(new_options)
                menu.i_selected[] = 0
            else
                idx = nothing
                for f in fallbacks
                    idx = findfirst(isequal(f), new_options)
                    !isnothing(idx) && break
                end
                menu.i_selected[] = isnothing(idx) ? 1 : idx
            end
        else
            menu.i_selected[] = findfirst(isequal(curr), new_options)
        end
    end

    onany(plot_data_obs, plot_type_obs, menu_tgt.selection) do plot_data_dict, ptype, comp_tgt
        isempty(plot_data_dict) && return
        
        valid_axes = String[]
        comp_max = 1
        
        pd_first = first(values(plot_data_dict))
        
        for (key, tensor) in pd_first.data
            varying = findall(s -> s > 1, size(tensor))
            isempty(varying) && continue
            
            if key in dim_names
                push!(valid_axes, key)
            else
                param_varying = filter(d -> d <= n_params, varying)
                phys_varying = filter(d -> d > n_params && d != n_params + 1, varying)
                
                is_pure_series = (length(phys_varying) == 1 && phys_varying[1] == n_params + 5) && isempty(param_varying)
                is_pure_param = isempty(phys_varying) && length(param_varying) == 1
                
                if is_pure_series || is_pure_param
                    push!(valid_axes, key)
                end
            end
            if key == "u"; comp_max = max(comp_max, size(tensor, n_params + 1)); end
        end
        
        if comp_tgt == "Time"; filter!(k -> k != "t", valid_axes)
        elseif comp_tgt == "Component"; filter!(k -> k != "c", valid_axes)
        elseif comp_tgt in active_params; filter!(k -> k != comp_tgt, valid_axes)
        end
        
        sort!(valid_axes)
        _update_menu!(menu_x, valid_axes; fallbacks=["x", "t", "y", "z"])
        _update_menu!(menu_comp, [string(i) for i in 1:comp_max]; fallbacks=["1"])
        
        p_dim = PLOT_DIM_MAP[ptype]
        if p_dim >= 2
             _update_menu!(menu_y, valid_axes; fallbacks=["y", "t", "z", "x"])
        else
            menu_y.options[] = ["disabled"]; menu_y.i_selected[] = 1
        end
        if p_dim >= 3
            _update_menu!(menu_z, valid_axes; fallbacks=["z", "t", "x", "y"])
        else
            menu_z.options[] = ["disabled"]; menu_z.i_selected[] = 1
        end
    end

    on(menu_x.selection) do x_val
        x_key_obs[] = isnothing(x_val) ? "-" : x_val
        opts_y = menu_y.options[]
        if opts_y != ["disabled"] && menu_y.selection[] == x_val && length(opts_y) > 1
            idx = findfirst(isequal(x_val), opts_y)
            menu_y.i_selected[] = mod1(idx + 1, length(opts_y))
        end
    end

    on(menu_y.selection) do y_val
        y_key_obs[] = isnothing(y_val) ? "-" : y_val
        opts_z = menu_z.options[]
        if opts_z != ["disabled"] && length(opts_z) > 2
            while menu_z.selection[] in (menu_x.selection[], menu_y.selection[])
                menu_z.i_selected[] = mod1(menu_z.i_selected[] + 1, length(opts_z))
            end
        end
    end

    on(menu_z.selection) do z_val
        z_key_obs[] = isnothing(z_val) ? "-" : z_val
    end
    
    on(menu_u.selection) do u_val
        (isnothing(u_val) || u_val == "-") && return
        u_key_obs[] = u_val
        notify(menu_z.selection) 
    end

    onany(menu_x.selection, menu_y.selection, menu_z.selection, plot_type_obs, plot_data_obs) do x_val, y_val, z_val, ptype, plot_data_dict
        isempty(plot_data_dict) && return
        p_dim = PLOT_DIM_MAP[ptype]
        axes = Set{Int}()
        active_indep_keys = String[]
        pd_first = first(values(plot_data_dict))
        
        for (dim_req, val) in zip([1, 2, 3], [x_val, y_val, z_val])
            if p_dim >= dim_req && !isnothing(val) && val != "-" && val != "disabled"
                idx = get_base_dim_idx(pd_first, val, dim_names)
                !isnothing(idx) && push!(axes, idx)
                push!(active_indep_keys, val)
            end
        end
        
        active_axes_obs[] = collect(axes)
        
        req_space = false; req_time = false; req_params = Int[]
        
        for key in active_indep_keys
            tensor = get(pd_first.data, key, nothing)
            isnothing(tensor) && continue
            varying = findall(s -> s > 1, size(tensor))
            
            idx = findfirst(isequal(key), dim_names)
            !isnothing(idx) && push!(varying, idx)
            
            if any(d -> d in (n_params+2, n_params+3, n_params+4), varying); req_space = true; end
            if any(d -> d == n_params+5, varying); req_time = true; end
            for d in varying
                if d <= n_params && !(d in req_params); push!(req_params, d); end
            end
        end
        
        valid_fields = String[]
        for (key, tensor) in pd_first.data
            varying = findall(s -> s > 1, size(tensor))
            isempty(varying) && continue
            
            has_space = any(d -> d in (n_params+2, n_params+3, n_params+4), varying)
            has_time = any(d -> d == n_params+5, varying)
            has_params = filter(d -> d <= n_params, varying)
            
            is_valid = true
            req_space && !has_space && (is_valid = false)
            req_time && !has_time && (is_valid = false)
            for p in req_params; !(p in has_params) && (is_valid = false); end
            if is_valid; push!(valid_fields, key); end
        end
        
        sort!(valid_fields)
        _update_menu!(menu_u, valid_fields)
    end

    onany(active_axes_obs, plot_data_obs) do active_axes, plot_data_dict
        isempty(plot_data_dict) && return
        vt = manager.controls["base_types"][]

        for i in 1:total_dims
            if i == comp_idx; continue; end 

            is_basevar = i > n_params
            if is_basevar
                base_idx = i - n_params
                vt[base_idx] isa Number && continue 
            end
            
            ctrl = control_objects[i]
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
                    tensor_key = dim_idx == 1 ? "x" : (dim_idx == 2 ? "y" : "z")
                    coord_tensor = get(pd.data, tensor_key, nothing)
                    
                    if !isnothing(coord_tensor) && !all(isnan.(coord_tensor))
                        vals = filter(!isnan, coord_tensor)
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
                ctrl.range[] = [0.0] 
            else
                ctrl.range[] = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
            end
        end
    end

    on(manager.methods) do _
        notify(plot_data_obs)
    end

    return x_key_obs, y_key_obs, z_key_obs, u_key_obs, active_axes_obs, selector_values, control_objects
end

# ... (Keep create_hierarchical_param_controls! exactly as it was) ...
function create_hierarchical_param_controls!(layout::GridLayout, mgr::PlotManager)
    cat_mapping = Dict("Simulation" => :simulation, "UI" => :ui)
    sorted_cat = sort(collect(keys(cat_mapping)))

    # 1. ZEILE: 3 Dropdowns gleichmäßig (3-Spalten-Layout)
    menu_cat   = Menu(layout[1, 1], options = sorted_cat, prompt = "Category...", width=nothing)
    menu_scope = Menu(layout[1, 2], options = ["-"], default = "-", prompt = "Scope...", width=nothing)
    menu_key   = Menu(layout[1, 3], options = ["-"], default = "-", prompt = "Key...", width=nothing)
    
    # THE FIX: Exakt ein Drittel pro Spalte
    colsize!(layout, 1, Relative(1/3))
    colsize!(layout, 2, Relative(1/3))
    colsize!(layout, 3, Relative(1/3))
    
    menu_cat.i_selected[] = 0; menu_scope.i_selected[] = 0; menu_key.i_selected[] = 0
    
    active_target_obs = Observable{Any}(nothing)
    ui_update = Observable{Int}(0)

    # 2. ZEILE: Buttons in einem eigenen Sub-Grid für perfekte 50/50 Aufteilung
    btn_layout = layout[2, 1:3] = GridLayout()
    btn_bool   = Button(btn_layout[1, 1], label="Toggle (Bool)", buttoncolor=:lightgray, width=nothing)
    btn_reset  = Button(btn_layout[1, 2], label="Reset", buttoncolor=:lightcoral, width=nothing)
    
    colsize!(btn_layout, 1, Relative(0.5))
    colsize!(btn_layout, 2, Relative(0.5))
    
    placeholder_text = lift(menu_key.selection) do k
        isnothing(k) && return "Select key..."
        val = get(mgr.last_run_params, k, "default")
        return "Loaded: $val"
    end

    # 3. ZEILE: Textbox über alle 3 Spalten
    tb = Textbox(layout[3, 1:3], placeholder = placeholder_text, reset_on_defocus = false, width = nothing)
    onany(menu_cat.selection, mgr.methods) do cat, active_methods
        isnothing(cat) && return
        field_name = cat_mapping[cat]
        data = getproperty(mgr, field_name)
        
        new_scopes = String[]
        if field_name == :simulation
            haskey(data, "shared") && push!(new_scopes, "shared")
            for m in sort(active_methods)
                haskey(data, m) && push!(new_scopes, m)
            end
        else
            new_scopes = sort(collect(keys(data)))
        end
        
        if menu_scope.options[] != new_scopes
            menu_scope.options[] = new_scopes
            active_target_obs[] = nothing 
            menu_scope.i_selected[] = 0
            menu_key.i_selected[] = 0
            tb.stored_string.val = ""
            Makie.reset!(tb)
        end
    end

    on(menu_scope.selection) do scope
        isnothing(scope) && return
        cat = menu_cat.selection[]
        field_name = cat_mapping[cat]
        data = getproperty(mgr, field_name)
        
        menu_key.options[] = sort(collect(keys(data[scope])))
        active_target_obs[] = nothing 
        menu_key.i_selected[] = 0
        
        Makie.reset!(tb)
    end

    on(menu_key.selection) do key
        isnothing(key) && return
        cat, scope = menu_cat.selection[], menu_scope.selection[]
        
        field_data = getproperty(mgr, cat_mapping[cat])
        obs = field_data[scope][key]
        
        active_target_obs[] = obs
        val_str = string(to_value(obs))
        tb.displayed_string[] = val_str
        
    end

    on(tb.stored_string) do s
        obs = active_target_obs[]
        isnothing(obs) && return
        
        smart_parse_and_update!(obs, s)
        
        if menu_cat.selection[] == "UI"; ui_update[] += 1 end
    end
    
    on(btn_bool.clicks) do _
        obs = active_target_obs[]
        isnothing(obs) && return
        if to_value(obs) isa Bool
            obs[] = !to_value(obs) # Flip it!
            tb.displayed_string[] = string(to_value(obs))
            if menu_cat.selection[] == "UI"; ui_update[] += 1 end
        end
    end

    on(btn_reset.clicks) do _
        obs = active_target_obs[]
        isnothing(obs) && return
        tb.stored_string[] = "default" # Dies löst den tb.stored_string observer aus und stellt den Standard wieder her!
    end
    
    mgr.controls["UI_Update"] = ui_update
    return
end

# ... (Keep create_base_overwrite_controls! exactly as it was) ...
function create_base_overwrite_controls!(
    layout::GridLayout, 
    manager::PlotManager, 
    plot_data_obs::Observable
)
    menu_var = Menu(layout[1, 1], options = ["-"], prompt = "Select...")
    menu_var.i_selected[] = 0
    # THE FIX: width=nothing
    tb_val = Textbox(layout[1, 2], placeholder = "Val / 'default'", width = nothing) 
    apply_btn = Button(layout[1, 3], label = "Apply", buttoncolor = :lightgray)

    # THE FIX: Spaltenaufteilung
    colsize!(layout, 1, Relative(1/3))
    colsize!(layout, 2, Relative(1/3))
    colsize!(layout, 3, Relative(1/3))

    on(plot_data_obs) do plot_data_dict
        isempty(plot_data_dict) && return
        
        active_methods = manager.methods[]
        n_params = length(manager.plot_vars) - 5 
        
        valid_base_names = String[]
        
        for (i, name) in enumerate(VariableNames)
            tensor_dim = n_params + i
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
            val = tryparse(Int, input_str)
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