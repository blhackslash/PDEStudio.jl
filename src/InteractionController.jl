# ==============================================================================
# --- INTERACTION CONTROLLER ---
# ==============================================================================
# This file contains ONLY the reactive logic connecting the UI to the Data.

function setup_common_interactions!(master_fig::Figure, plot_layout::GridLayout, manager::PlotManager, plot_data_obs::Observable)
    _setup_run_and_drop_interactions!(master_fig, manager)
    _setup_method_interactions!(manager)
    _setup_hierarchy_interactions!(manager)
    _setup_export_interactions!(master_fig, plot_layout, manager, plot_data_obs)
    
    manager.widgets["Editor_Cat"].i_selected[] = 1
    notify(manager.widgets["Editor_Cat"].selection)
    notify(manager.methods)
end

function setup_eulerian_interactions!(manager::PlotManager, plot_data_obs::Observable)
    @info "Initializing Eulerian Interaction Pipeline..."
    _setup_overwrite_interactions!(manager, plot_data_obs)
    _setup_eulerian_data_sync!(manager, plot_data_obs)
end

function setup_lagrangian_interactions!(manager::PlotManager, plot_data_obs::Observable)
    @info "Initializing Lagrangian Interaction Pipeline..."
    _setup_lagrangian_data_sync!(manager, plot_data_obs)
end

function _setup_run_and_drop_interactions!(master_fig::Figure, manager::PlotManager)
    drop_label = manager.widgets["Drop_Label"]
    drop_box   = manager.widgets["Drop_Box"]
    run_btn    = manager.widgets["Run_Button"]

    # --- CSV DROP PIPELINE ---
    on(events(master_fig.scene).dropped_files) do files
        if !isempty(files) && endswith(lowercase(files[1]), ".csv")
            path = files[1]
            drop_label.text[] = "Loaded:\n" * basename(path)
            drop_label.color[] = RGBAf(0.0, 0.5, 0.0, 1.0)
            drop_box.color[] = RGBAf(0.8, 1.0, 0.8, 1.0)
            run_btn.buttoncolor[] = :lightgreen
            
            load_and_apply_csv!(manager, path)
        end
    end

    # --- REFRESH / RUN BUTTON ---
    on(run_btn.clicks) do _
        manager.triggers["Simulation_Update"][] += 1
    end
end
# ==============================================================================
# --- SPLIT: METHOD & OVERWRITE LISTENERS ---
# ==============================================================================

function _setup_method_interactions!(manager::PlotManager)
    mode_btn = manager.widgets["Mode_Button"]
    menu_mth = manager.widgets["Method_Toggle"]
    is_activate_mode = manager.state["Is_Activate_Mode"]
    
    if !haskey(manager.state, "Staged_Methods")
        manager.state["Staged_Methods"] = Observable(copy(manager.methods[]))
    end
    staged_methods = manager.state["Staged_Methods"]

    on(manager.methods) do active_methods
        staged_methods[] = copy(active_methods)
    end

    onany(staged_methods, is_activate_mode) do staged, activate_mode
        @with_lock manager "Menu_Sync" begin
            raw_method_names = filter(k -> k != "shared", collect(keys(manager.simulation)))
            all_method_names = sort_methods_robust(raw_method_names)
            opts = activate_mode ? filter(m -> !(m in staged), all_method_names) : copy(staged)
            
            new_opts = isempty(opts) ? [("Methods...","-")] : [("Methods...","-"); sort(opts)]
            update_menu_safe!(menu_mth, new_opts)
        end
    end

    on(mode_btn.clicks) do _
        is_activate_mode[] = !is_activate_mode[]
        mode_btn.label[] = is_activate_mode[] ? "Mode: Activate" : "Mode: Deact."
        mode_btn.buttoncolor[] = is_activate_mode[] ? :lightgreen : :lightcoral
    end

    on(menu_mth.selection) do sel
        (isnothing(sel) || sel == "-") && return
        
        new_staged = copy(staged_methods[])
        if is_activate_mode[]
            if !(sel in new_staged)
                push!(new_staged, sel)
                new_staged = sort_methods_robust(new_staged) 
            end
        else
            filter!(x -> x != sel, new_staged)
        end
        staged_methods[] = new_staged
    end

    on(manager.widgets["Method_Apply"].clicks) do _
        if sort(manager.methods[]) != sort(staged_methods[])
            manager.methods[] = copy(staged_methods[])
            manager.triggers["Simulation_Update"][] += 1
        end
    end
end

function _setup_overwrite_interactions!(manager::PlotManager, plot_data_obs::Observable)
    menu_var = manager.widgets["Overwrite_Var"]
    tb_val   = manager.widgets["Overwrite_Text"]

    onany(plot_data_obs, manager.methods) do plot_data_dict, active_methods
        isempty(plot_data_dict) && return
        
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
            
            is_fixed_by_user = manager.state["base_types"][][i] isa Number
            if has_variation || is_fixed_by_user
                push!(valid_base_names, name)
            end
        end
        update_menu_safe!(menu_var, valid_base_names)
    end

    on(manager.widgets["Overwrite_Apply"].clicks) do _
        var_name = menu_var.selection[]
        input_str = tb_val.stored_string.val 
        
        if isnothing(var_name) || var_name == "-" || isempty(input_str)
            @warn "Overwrite Error: Please select a variable and provide an input."
            return
        end

        idx = findfirst(isequal(var_name), VariableNames)
        isnothing(idx) && return
        
        vt = copy(manager.state["base_types"][])
        n_params = length(manager.plot_vars) - 5
        abs_idx = n_params + idx
      
        if abs_idx in manager.state["Active_Axes"][]
            @warn "Cannot fix the value of an active Plot Axis!"
            return
        end

        if lowercase(strip(input_str)) == "default"
            vt[idx] = (idx == 1 ? :menu : :slider)
            @info "Restored default control for $var_name."
        else
            val = tryparse(Int, input_str)
            if isnothing(val); val = tryparse(Float64, input_str); end
            if isnothing(val); @warn "Invalid Input."; return; end
            vt[idx] = val
        end
        
        manager.state["base_types"][] = vt
        tb_val.stored_string.val = "" 
        Makie.reset!(tb_val)
        
        manager.triggers["Simulation_Update"][] += 1
    end
end

function _setup_hierarchy_interactions!(manager::PlotManager)
    menu_cat   = manager.widgets["Editor_Cat"]
    menu_scope = manager.widgets["Editor_Scope"]
    menu_key   = manager.widgets["Editor_Key"]
    tb         = manager.widgets["Editor_Text"]
    
    active_target_obs = manager.state["Active_Target_Obs"]
    cat_mapping = Dict("Simulation" => :simulation, "UI" => :ui)

    function sync_textbox_to_active_key()
        key = menu_key.selection[]
        if isnothing(key) || key == "-"
            active_target_obs[] = nothing
            tb.stored_string.val = ""
            if tb.displayed_string[] != ""
                Makie.reset!(tb)
            end
            return
        end
        
        cat = menu_cat.selection[]
        scope = menu_scope.selection[]
        (isnothing(cat) || isnothing(scope) || scope == "-") && return
        
        data = getproperty(manager, cat_mapping[cat])
        if haskey(data, scope) && haskey(data[scope], key)
            obs = data[scope][key]
            active_target_obs[] = obs
            
            # THE FIX: Safely display empty strings to prevent Makie BoundsError
            val_str = string(to_value(obs))
            tb.displayed_string[] = isempty(val_str) ? "<empty>" : val_str
        end
    end

    # =========================================================================
    # TIER 1: Cat Selection -> Updates Scope Options Vector
    # =========================================================================
    onany(menu_cat.selection, manager.methods) do cat, active_methods
        isnothing(cat) && return
        field_name = cat_mapping[cat]
        data = getproperty(manager, field_name)
        
        new_scopes = String[]
        if field_name == :simulation
            haskey(data, "shared") && push!(new_scopes, "shared")
            for m in sort_methods_robust(active_methods)
                haskey(data, m) && push!(new_scopes, m)
            end
        else
            new_scopes = sort(collect(keys(data)))
        end
        
        new_scopes = isempty(new_scopes) ? ["-"] : new_scopes
        
        update_menu_safe!(menu_scope, new_scopes; force_notify=true)
    end

    # =========================================================================
    # TIER 2: Scope Selection -> Rebuilds Key Options Vector
    # =========================================================================
    on(menu_scope.selection) do scope
        if isnothing(scope) || scope == "-"
            update_menu_safe!(menu_key, String[]; force_notify=true)
            sync_textbox_to_active_key()
            return
        end
        
        cat = menu_cat.selection[]
        data = getproperty(manager, cat_mapping[cat])
        
        raw_keys = sort(collect(keys(data[scope])))
        if scope == "Plot-Style"
            base_sel  = manager.widgets["Base_Plot"].selection[]
            style_sel = manager.widgets["Plot_Style"].selection[]
            ptype = get(PLOT_ROUTING_MATRIX, (base_sel, style_sel), :lines)
            
            valid_keys = get(STYLE_DEPENDENCIES, ptype, raw_keys)
            filter!(k -> k in valid_keys, raw_keys)
        end
        new_keys = isempty(raw_keys) ? [("-", "-")] : [(nice_string(k), k) for k in raw_keys]
        
        update_menu_safe!(menu_key, new_keys; force_notify=true)
        sync_textbox_to_active_key()
    end

    # =========================================================================
    # TIER 3: Key Selection -> Refreshes Textbox Content
    # =========================================================================
    on(menu_key.selection) do _
        sync_textbox_to_active_key()
    end

    # =========================================================================
    # TIER 4: Textbox Submissions & Mutation
    # =========================================================================
    on(tb.stored_string) do s
        obs = active_target_obs[]
        isnothing(obs) && return
        smart_parse_and_update!(obs, s)
        if menu_cat.selection[] == "UI"
            # THE FIX: Dynamically switching to a colormap requires a full WebGL geometry rebuild!
            if menu_key.selection[] in ("use_color_map", "line_direction", "base_method_idx","log_scale","dashed_lines")
                manager.triggers["Primitive_Rebuild"][] += 1
            else
                manager.triggers["UI_Update"][] += 1
            end
        end
    end
    
    on(manager.widgets["Editor_Toggle"].clicks) do _
        obs = active_target_obs[]
        isnothing(obs) && return
        if to_value(obs) isa Bool
            obs[] = !to_value(obs)
            
            val_str = string(obs[])
            tb.displayed_string[] = isempty(val_str) ? "<empty>" : val_str
            
            if menu_cat.selection[] == "UI"
                # THE FIX: Dynamically switching to a colormap requires a full WebGL geometry rebuild!
                if menu_key.selection[] in ("use_color_map", "line_direction", "base_method_idx")
                    manager.triggers["Primitive_Rebuild"][] += 1
                else
                    manager.triggers["UI_Update"][] += 1
                end
            end
        end
    end
end

function _setup_export_interactions!(master_fig::Figure, plot_layout::GridLayout, manager::PlotManager, plot_data_obs::Observable)
    saveBox = manager.widgets["Export_Text"]
    btn_play = manager.widgets["Play_Anim_Button"]
    btn_lock = manager.widgets["Lock_Camera_Button"] # THE FIX
    
    if !haskey(manager.state, "Camera_Locked")
        manager.state["Camera_Locked"] = Observable(false)
    end

    # THE FIX: Listen to the new Lock Button!
    on(btn_lock.clicks) do _
        is_locked = !manager.state["Camera_Locked"][]
        manager.state["Camera_Locked"][] = is_locked
        extract_and_store_camera_state!(plot_layout)
        
        if is_locked
            extract_and_store_camera_state!(plot_layout)
            btn_lock.label[] = "Camera: Locked"
            btn_lock.buttoncolor[] = :lightgreen
            @info "Camera locked to current view."
        else
            GLOBAL_CAMERA_OPTIONS[] = Dict{String, Any}()
            btn_lock.label[] = "Lock Camera"
            btn_lock.buttoncolor[] = :lightgray
            @info "Camera unlocked. Will auto-scale on next data update."
        end
    end

    anim_target_obs = manager.widgets["Anim_Target"].selection
    is_animating = manager.state["Is_Animating"]
    animation_timer = manager.state["Animation_Timer"]

    # Helper to route parameter names to their UI slider widgets
    function get_target_widget(target_name)
        target_name == "None" && return nothing
        rev_map = haskey(manager.state, "Reverse_Map") ? manager.state["Reverse_Map"][] : Dict{String, String}()
        w_key = haskey(rev_map, target_name) ? rev_map[target_name] : target_name
        return haskey(manager.widgets, w_key) ? manager.widgets[w_key] : nothing
    end

    function check_selection_validity(target_name)
        if isnothing(target_name) || target_name == "None"
            @warn "Export Error: No target selected."
            return false 
        end
        
        # Prevent animating an active plot axis
        idx = findfirst(isequal(target_name), manager.plot_vars)
        if !isnothing(idx) && idx in manager.state["Active_Axes"][]
            @warn "Cannot animate an active plot axis."
            return false 
        end
        
        widget = get_target_widget(target_name)
        if isnothing(widget)
            return false
        end
        if !(widget isa Makie.Slider)
            @warn "Only Sliders can be animated."
            return false 
        end
        if length(widget.range[]) < 2
            @warn "Slider has no range to animate."
            return false 
        end
        return true
    end

    function build_pristine_export_figure()
        export_fig = Figure() 
        export_layout = export_fig[1, 1] = GridLayout()
        
        # =====================================================================
        # THE FIX: Resolve the Plot Type through the Routing Matrix!
        # =====================================================================
        base_sel  = manager.widgets["Base_Plot"].selection[]
        style_sel = manager.widgets["Plot_Style"].selection[]
        ptype_sym = get(PLOT_ROUTING_MATRIX, (base_sel, style_sel), :lines)
        
        local_data_obs = Observable(plot_data_obs[])
        export_obs = setup_render_lift!(export_fig, export_layout, local_data_obs, manager, Val(ptype_sym))
        # =====================================================================
        
        current_axes = [c.content for c in plot_layout.content if c.content isa Axis || c.content isa Axis3]
        export_axes = [c.content for c in export_layout.content if c.content isa Axis || c.content isa Axis3]
        # Manually force the export pipeline to draw the primitives!
        manager.triggers["Primitive_Rebuild"][] += 1
        for (c_ax, e_ax) in zip(current_axes, export_axes)
            if c_ax isa Axis3
                e_ax.azimuth[] = c_ax.azimuth[]
                e_ax.elevation[] = c_ax.elevation[]
                e_ax.perspectiveness[] = c_ax.perspectiveness[]
                
                # Transfer 3D limits to the Pristine Export figure!
                lims = c_ax.finallimits[]
                limits!(e_ax, lims.origin[1], lims.origin[1] + lims.widths[1],
                              lims.origin[2], lims.origin[2] + lims.widths[2],
                              lims.origin[3], lims.origin[3] + lims.widths[3])
            elseif c_ax isa Axis
                lims = c_ax.finallimits[]
                limits!(e_ax, lims.origin[1], lims.origin[1] + lims.widths[1], 
                              lims.origin[2], lims.origin[2] + lims.widths[2])
            end
        end
        
        
        # Shrink-wrap the export figure to perfectly match Plot_Width/Plot_Height!
        resize_to_layout!(export_fig)
        return export_fig, export_obs
    end

    on(manager.widgets["Save_Image_Button"].clicks) do _
        # Auto-lock during save to protect the view from the rebuild cycle
        was_locked = manager.state["Camera_Locked"][]
        manager.state["Camera_Locked"][] = true 
        
        # THE FIX: ALWAYS scrape the exact live view right before saving!
        extract_and_store_camera_state!(plot_layout)
        cam_cache = deepcopy(GLOBAL_CAMERA_OPTIONS[])
        
        base_name = string(strip(saveBox.stored_string[]))
        if isempty(base_name); base_name = "plot_export"; end

        save_dir = joinpath(get_save_path(), "figures")
        if manager.ui["Various"]["create_savefolder"][]; save_dir = joinpath(save_dir, base_name); end
        mkpath(save_dir)

        export_fig, export_obs = build_pristine_export_figure()

        for fmt in manager.ui["Various"]["save_formats"][]
            ext = lowercase(strip(fmt))
            full_path = joinpath(save_dir, base_name * ".$ext")
            save(full_path, export_fig; backend=CairoMakie)
            @info "Pristine Image ($ext) saved safely via CairoMakie!"
        end

        if !isnothing(export_obs); for obs in export_obs; off(obs); end; end
        
        metadata = Dict("Save Type" => "Static Frame", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
        saveParametersToCSV(base_name, save_dir, manager, metadata)
        
        # Restore lock state
        if !was_locked
            manager.state["Camera_Locked"][] = false
            GLOBAL_CAMERA_OPTIONS[] = Dict{String, Any}()
        end
        manager.triggers["Primitive_Rebuild"][] += 1
    end

    on(manager.widgets["Save_GIF_Button"].clicks) do _
        notify(manager.widgets["Save_Defs_Button"].clicks)
        target_name = anim_target_obs[]
        !check_selection_validity(target_name) && return
        target_widget = get_target_widget(target_name)
        
        # Auto-lock during save to protect the view from the rebuild cycle
        was_locked = manager.state["Camera_Locked"][]
        manager.state["Camera_Locked"][] = true 
        
        # THE FIX: ALWAYS scrape the exact live view right before saving!
        extract_and_store_camera_state!(plot_layout)
        cam_cache = deepcopy(GLOBAL_CAMERA_OPTIONS[])
        
        base_name = string(strip(saveBox.stored_string[]))
        if isempty(base_name); base_name = "anim_export"; end
        
        save_path = joinpath(get_save_path(), "animations")
        mkpath(save_path)
        fname = joinpath(save_path, base_name * ".gif")
        
        duration = manager.ui["Various"]["animation_time"][]
        fps = manager.ui["Various"]["animation_FPS"][]
        rng = target_widget.range[]
        n_frames = Int(duration * fps)
        
        @info "Recording pristine '$target_name' animation to $fname..."
        export_obs_ref = Ref{Any}(nothing)
        try
            export_fig, export_obs = build_pristine_export_figure()
            export_obs_ref[] = export_obs
            record(export_fig, fname, range(rng[1], rng[end], length=n_frames); framerate=fps) do val
                set_close_to!(target_widget, val)
                yield() 
            end
            
            metadata = Dict("Save Type" => "Animation", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
            saveParametersToCSV(base_name, save_path, manager, metadata) 
            @info "Pristine GIF Saved Successfully."
        catch e
            @error "GIF Recording Failed" exception=(e, catch_backtrace())
        finally
            if !isnothing(export_obs_ref[]); for obs in export_obs_ref[]; off(obs); end; end
            
            # Restore lock state
            if !was_locked
                manager.state["Camera_Locked"][] = false
                GLOBAL_CAMERA_OPTIONS[] = Dict{String, Any}()
            end
            manager.triggers["Primitive_Rebuild"][] += 1
        end
    end

    on(manager.widgets["Save_Defs_Button"].clicks) do _
        # THE FIX: ALWAYS scrape the exact live view right before saving!
        extract_and_store_camera_state!(plot_layout)
        cam_cache = deepcopy(GLOBAL_CAMERA_OPTIONS[])
        GLOBAL_SCENE_OPTIONS[]  = extract_scene_options(manager)
        GLOBAL_LAYOUT_OPTIONS[] = extract_layout_options(manager) 
        new_ui = Dict{String, Any}()
        for (scope, subdict) in manager.ui
            new_ui[scope] = Dict{String, Any}()
            for (k, v) in subdict; new_ui[scope][k] = to_value(v); end
        end
        GLOBAL_UI_OVERWRITE[] = new_ui
        GLOBAL_VAR_OVERWRITE[] = copy(manager.state["base_types"][])
        @info "Current UI, Layout, and Scene options successfully saved to global defaults!"
    end
    
    on(manager.widgets["Clear_Defs_Button"].clicks) do _
        GLOBAL_SCENE_OPTIONS[] = Dict{String, Any}()
        GLOBAL_UI_OVERWRITE[]  = Dict{String, Any}()
        GLOBAL_LAYOUT_OPTIONS[]= Dict{String, Any}()
        GLOBAL_VAR_OVERWRITE[] = Any[:menu, :slider, :slider, :slider, :slider]
        apply_scene_options!(manager, get_base_scene_options())
        @info "Global defaults cleared! Basic scene options restored."
    end

    on(is_animating) do animating
        btn_play.label[] = animating ? "Stop Anim" : "Play Anim"
    end

    on(btn_play.clicks) do _
        if is_animating[]
            is_animating[] = false
            !isnothing(animation_timer[]) && close(animation_timer[])
            animation_timer[] = nothing
        else
            target_name = anim_target_obs[]
            !check_selection_validity(target_name) && return
            
            target_widget = get_target_widget(target_name)
            is_animating[] = true
            
            duration = manager.ui["Various"]["animation_time"][]
            fps = manager.ui["Various"]["animation_FPS"][]
            rng = target_widget.range[]
            start_time = time()
            
            animation_timer[] = Timer(0.0, interval = 1/fps) do t
                if !is_animating[]; close(t); return; end
                elapsed = mod(time() - start_time, duration)
                progress = elapsed / duration
                val = rng[1] + progress * (rng[end] - rng[1])
                set_close_to!(target_widget, val)
            end
        end
    end
end

function _setup_eulerian_data_sync!(manager::PlotManager, plot_data_obs::Observable)
    w = manager.widgets
    x_sel = w["X-Axis"].selection
    y_sel = w["Y-Axis"].selection
    z_sel = w["Z-Axis"].selection
    comp_tgt_obs = w["Compare_Target"].selection
    
    # THE NEW MENU BRIDGE
    base_obs = w["Base_Plot"].selection
    style_obs = w["Plot_Style"].selection
    
    on(base_obs) do base_type
        isnothing(base_type) && return
        valid_styles = get(PLOT_STYLE_OPTIONS, base_type, ["2D"])
        update_menu_safe!(w["Plot_Style"], valid_styles)
        notify(manager.widgets["Editor_Scope"].selection)
    end
    on(style_obs) do _
        notify(manager.widgets["Editor_Scope"].selection)
    end

    active_axes_obs = manager.state["Active_Axes"]
    
    # Local observables to carry valid axes and their dimensional mappings
    base_valid_axes = Observable{Vector{String}}(String[])
    base_axis_to_dim = Observable{Dict{String, Int}}(Dict())

    # =========================================================================
    # 1. Sync Base Dropdown Options (Dimensionality-Driven)
    # =========================================================================
    onany(plot_data_obs, base_obs, style_obs, comp_tgt_obs) do plot_data_dict, base_sel, style_sel, comp_tgt
        @with_lock manager "Data" begin
            isempty(plot_data_dict) && return
            
            pd_first = first(values(plot_data_dict))
            n_params = length(pd_first.active_param_keys)
            if n_params > 0; manager.plot_vars[1:n_params] .= pd_first.active_param_keys; end
            
            dim_names = manager.plot_vars
            total_dims = length(dim_names)
            comp_idx = n_params + 1
            
            valid_axes = String[]
            axis_to_dim = Dict{String, Int}()
            comp_max = 1
            
            # --- THE MAGIC RULE ---
            # Any tensor that varies across EXACTLY ONE dimension (ignoring components) 
            # is mathematically valid as an independent 1D Axis!
            for (key, tensor) in pd_first.data
                if key == "u"; comp_max = max(comp_max, size(tensor, comp_idx)); end
                
                varying = findall(s -> s > 1, size(tensor))
                filter!(d -> d != comp_idx, varying) # Ignore the component dimension
                
                if length(varying) == 1
                    push!(valid_axes, key)
                    axis_to_dim[key] = varying[1]
                end
            end
            
            # Safety Fallback for 0D / static single-point simulations
            if isempty(valid_axes)
                push!(valid_axes, "x")
                axis_to_dim["x"] = n_params + 2
            end
            
            unique!(valid_axes); sort!(valid_axes)
            
            if comp_tgt == "Time"; filter!(k -> k != "t", valid_axes)
            elseif comp_tgt == "Component"; filter!(k -> k != "c", valid_axes)
            elseif comp_tgt in dim_names; filter!(k -> k != comp_tgt, valid_axes)
            end
            
            comp_names_tuple = manager.ui["Labels"]["comp_names"][]
            c_options = Any[]
            for i in 1:comp_max
                name = (comp_names_tuple isa Tuple && length(comp_names_tuple) >= i && comp_names_tuple[i] != "default" && !isempty(string(comp_names_tuple[i]))) ? string(comp_names_tuple[i]) : string(i)
                push!(c_options, (name, string(i)))
            end
            
            # X gets EVERYTHING. Y and Z are handled dynamically below.
            update_menu_safe!(w["X-Axis"], valid_axes; fallbacks=["x", "t", "y", "z"])
            update_menu_safe!(w["c"], c_options; fallbacks=["1"])
            
            # --- Animation Targets (Only base sliders can be animated) ---
            anim_options = Any[("None", "None")]
            for i in 1:n_params
                if length(pd_first.active_param_values[i]) > 1
                    p_name = dim_names[i]
                    push!(anim_options, (nice_string(p_name), p_name))
                end
            end
            for i in (n_params+2):total_dims
                ax_name = dim_names[i]
                if haskey(axis_to_dim, ax_name)
                    nice_ax = ax_name == "x" ? "Space(X)" : ax_name == "y" ? "Space(Y)" :
                              ax_name == "z" ? "Space(Z)" : ax_name == "t" ? "Time" : nice_string(ax_name)
                    push!(anim_options, (nice_ax, ax_name))
                end
            end
            update_menu_safe!(w["Anim_Target"], anim_options; fallbacks=["None"])
            
            # Pass the structural mappings downstream
            base_axis_to_dim[] = axis_to_dim
            base_valid_axes[] = valid_axes
        end
    end

    # =========================================================================
    # 1.5 Cascading Hierarchy: Dimensional Collision Prevention
    # =========================================================================
    onany(base_valid_axes, base_axis_to_dim, x_sel, y_sel, base_obs, style_obs) do valid_axes, axis_map, x_val, y_val, base_sel, style_sel
        (isempty(valid_axes) || isnothing(x_val) || isempty(axis_map)) && return
        
        ptype = get(PLOT_ROUTING_MATRIX, (base_sel, style_sel), :lines)
        p_dim = PLOT_DIM_MAP[ptype]
        
        # Grab the underlying dimension index of the chosen X-Axis
        dim_x = get(axis_map, x_val, -1)
        
        # 1. Update Y-Axis options (Exclude any variable sharing X's underlying dimension)
        if p_dim >= 2
            y_axes = filter(v -> get(axis_map, v, -2) != dim_x, valid_axes)
            update_menu_safe!(w["Y-Axis"], y_axes; fallbacks=["y", "t", "z", "x"], force_notify=false)
        else
            update_menu_safe!(w["Y-Axis"], ["disabled"]; fallbacks=["disabled"], force_notify=false)
        end
        
        curr_y = w["Y-Axis"].selection[]
        dim_y = get(axis_map, curr_y, -3)
        
        # 2. Update Z-Axis options (Exclude any variable sharing X's OR Y's underlying dimension)
        if p_dim >= 3
            z_axes = filter(v -> get(axis_map, v, -4) != dim_x && get(axis_map, v, -4) != dim_y, valid_axes)
            update_menu_safe!(w["Z-Axis"], z_axes; fallbacks=["z", "t", "x", "y"], force_notify=false)
        else
            update_menu_safe!(w["Z-Axis"], ["disabled"]; fallbacks=["disabled"], force_notify=false)
        end
    end

    # =========================================================================
    # 2. U-Axis Sync & Active Axes State (Subset Validation)
    # =========================================================================
    onany(x_sel, y_sel, z_sel, base_obs, style_obs, plot_data_obs, base_axis_to_dim) do x_val, y_val, z_val, base_sel, style_sel, plot_data_dict, axis_map
        (isempty(plot_data_dict) || isempty(axis_map)) && return

        ptype = get(PLOT_ROUTING_MATRIX, (base_sel, style_sel), :lines)
        p_dim = PLOT_DIM_MAP[ptype]
        pd_first = first(values(plot_data_dict))
        comp_idx = length(pd_first.active_param_keys) + 1
        
        axes_set = Set{Int}()
        
        for (dim_req, val) in zip([1, 2, 3], [x_val, y_val, z_val])
            if p_dim >= dim_req && !isnothing(val) && val != "-" && val != "disabled"
                idx = get(axis_map, val, nothing)
                !isnothing(idx) && push!(axes_set, idx)
            end
        end
        
        # --- THE FIX: Subset Validation ---
        # A tensor is mathematically valid for the U-Axis if it varies 
        # across AT LEAST the underlying dimensions currently locked into X, Y, Z.
        valid_fields = String[]
        for (key, tensor) in pd_first.data
            varying = Set(findall(s -> s > 1, size(tensor)))
            delete!(varying, comp_idx) 
            
            if issubset(axes_set, varying)
                push!(valid_fields, key)
            end
        end
        
        sort!(valid_fields)
        update_menu_safe!(w["U-Axis"], valid_fields; fallbacks=["u", "v", "rho", "p"], force_notify=false)
        
        # Update the internal state silently!
        active_axes_obs.val = collect(axes_set)
        
        if !manager.state["Config_Just_Loaded"][]
            notify(active_axes_obs)
        end
    end

    # =========================================================================
    # 3. Sync Slider Ranges (Data injection to UI & Config Load Finalization)
    # =========================================================================
    onany(active_axes_obs, plot_data_obs) do active_axes, plot_data_dict
        isempty(plot_data_dict) && return

        dim_names = manager.plot_vars
        total_dims = length(dim_names)
        n_params = total_dims - 5
        comp_idx = n_params + 1
        vt = manager.state["base_types"][]

        for i in 1:total_dims
            if i == comp_idx; continue; end 
            is_basevar = i > n_params
            if is_basevar
                base_idx = i - n_params
                vt[base_idx] isa Number && continue 
            end
            
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
            
            dim_name = dim_names[i]
            widget_key = dim_name
            if i <= n_params
                widget_key = haskey(manager.state["Reverse_Map"][], dim_name) ? manager.state["Reverse_Map"][][dim_name] : "param_$i"
            end
            
            if haskey(w, widget_key)
                ctrl = w[widget_key]
                if is_axis
                    ctrl.range[] = [0.0] 
                elseif i <= n_params
                    all_vals = Float64[]
                    for pd in values(plot_data_dict)
                        append!(all_vals, pd.active_param_values[i])
                    end
                    ctrl.range[] = isempty(all_vals) ? [0.0] : sort(unique(all_vals))
                    set_close_to!(ctrl, ctrl.value[])
                else
                    ctrl.range[] = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
                    set_close_to!(ctrl, ctrl.value[])
                end
            end
        end
        
        # --- Config Initialization Cleanup ---
        if manager.state["Config_Just_Loaded"][]
            opts = isempty(GLOBAL_SCENE_OPTIONS[]) ? get_base_scene_options() : GLOBAL_SCENE_OPTIONS[]
            apply_scene_options!(manager, opts)
            
            if !isempty(GLOBAL_UI_OVERWRITE[])
                for (scope, keys_dict) in GLOBAL_UI_OVERWRITE[]
                    if haskey(manager.ui, scope)
                        for (k, v) in keys_dict
                            if haskey(manager.ui[scope], k)
                                manager.ui[scope][k].val = v
                            end
                        end
                    end
                end
                GLOBAL_UI_OVERWRITE[] = Dict{String, Any}()
            end
            
            manager.state["Config_Just_Loaded"].val = false
        end
    end
    # =========================================================================
    # LAGRANGIAN GATEKEEPER LOGIC
    # =========================================================================
    on(manager.widgets["Data_Mode_Button"].clicks) do _
        current_mode = manager.state["Data_Mode"]
        new_mode = current_mode[] == :eulerian ? :lagrangian : :eulerian
        current_mode[] = new_mode
        
        btn = manager.widgets["Data_Mode_Button"]
        btn.label[] = new_mode == :eulerian ? "Mode: Eulerian" : "Mode: Lagrangian"
        btn.buttoncolor[] = new_mode == :eulerian ? :lightgray : :lightblue
        
        if new_mode == :lagrangian
            @info "Switching to Lagrangian Mode. Locking spatial axes..."
            
            # 1. Lock the Base Plot to Scatter logic
            update_menu_safe!(manager.widgets["Base_Plot"], ["Scatter"]; fallbacks=["Scatter"], force_notify=true)
            
            # 2. Hard-lock the spatial axes (Data Extraction will handle 1D vs 2D vs 3D)
            update_menu_safe!(manager.widgets["X-Axis"], ["x"]; fallbacks=["x"])
            update_menu_safe!(manager.widgets["Y-Axis"], ["y", "disabled"]; fallbacks=["y", "disabled"])
            update_menu_safe!(manager.widgets["Z-Axis"], ["z", "disabled"]; fallbacks=["z", "disabled"])
            
            # 3. Disable Animation Target for Space
            anim_menu = manager.widgets["Anim_Target"]
            if anim_menu.selection[] in ["x", "y", "z"]
                update_menu_safe!(anim_menu, anim_menu.options[]; fallbacks=["None"], force_notify=true)
            end
        else
            @info "Switching to Eulerian Mode. Rebuilding dense grids..."
            # Triggering a full update will naturally unlock the menus via your existing sync logic!
        end
        
        # Fire the simulation update to completely rebuild the PlotData dictionaries!
        manager.triggers["Simulation_Update"][] += 1
    end
end

# ==============================================================================
# --- LAGRANGIAN PIPELINE SPECIFICS ---
# ==============================================================================
function _setup_lagrangian_data_sync!(manager::PlotManager, plot_data_obs::Observable)
    w = manager.widgets
    active_axes_obs = manager.state["Active_Axes"]
    
    # 1. Lock the UI Menus and Populate U-Axis / Components
    onany(plot_data_obs) do plot_data_dict
        isempty(plot_data_dict) && return
        
        pd_first = first(values(plot_data_dict))
        l_data = pd_first.data[1] # Grab the first raw LSimData run
        n_params = length(pd_first.active_param_keys)
        dim_names = manager.plot_vars
        
        update_menu_safe!(w["Base_Plot"], ["Scatter"]; fallbacks=["Scatter"], force_notify=false)
        update_menu_safe!(w["X-Axis"], ["x"]; fallbacks=["x"])
        update_menu_safe!(w["Y-Axis"], ["y", "disabled"]; fallbacks=["y", "disabled"])
        update_menu_safe!(w["Z-Axis"], ["z", "disabled"]; fallbacks=["z", "disabled"])
        
        # --- THE FIX: POPULATE U-AXIS ---
        valid_fields = ["u"]
        if haskey(l_data.fields, "v"); push!(valid_fields, "v"); end
        if haskey(l_data.fields, "rho"); push!(valid_fields, "rho"); end
        if haskey(l_data.fields, "p"); push!(valid_fields, "p"); end
        append!(valid_fields, keys(l_data.fields))
        append!(valid_fields, keys(l_data.profiles))
        unique!(valid_fields); sort!(valid_fields)
        update_menu_safe!(w["U-Axis"], valid_fields; fallbacks=["u"], force_notify=false)
        
        # --- THE FIX: POPULATE COMPONENTS ---
        comp_max = length(l_data.u[1][1])
        comp_names_tuple = manager.ui["Labels"]["comp_names"][]
        c_options = Any[]
        for i in 1:comp_max
            name = (comp_names_tuple isa Tuple && length(comp_names_tuple) >= i && comp_names_tuple[i] != "default" && !isempty(string(comp_names_tuple[i]))) ? string(comp_names_tuple[i]) : string(i)
            push!(c_options, (name, string(i)))
        end
        update_menu_safe!(w["c"], c_options; fallbacks=["1"], force_notify=false)

        # --- THE FIX: SYNC ACTIVE AXES STATE ---
        axes_set = Set{Int}()
        push!(axes_set, n_params + 2) # X is always active
        if w["Y-Axis"].selection[] != "disabled"; push!(axes_set, n_params + 3); end
        if w["Z-Axis"].selection[] != "disabled"; push!(axes_set, n_params + 4); end
        
        active_axes_obs.val = collect(axes_set)
        if !manager.state["Config_Just_Loaded"][]
            notify(active_axes_obs)
        end

        # In Lagrangian, you can ONLY animate parameters, not space!
        anim_options = Any[("None", "None")]
        for i in 1:n_params
            if length(pd_first.active_param_values[i]) > 1
                push!(anim_options, (nice_string(dim_names[i]), dim_names[i]))
            end
        end
        update_menu_safe!(w["Anim_Target"], anim_options; fallbacks=["None"])
    end
    
    # 2. Sync Parameter & Time Sliders (Ignore Spatial Bounds)
    onany(plot_data_obs) do plot_data_dict
        isempty(plot_data_dict) && return

        dim_names = manager.plot_vars
        total_dims = length(dim_names)
        n_params = total_dims - 5
        
        for i in 1:total_dims
            if i == n_params + 1; continue end
            # Skip spatial axes
            if i in (n_params + 2, n_params + 3, n_params + 4)
                widget_key = dim_names[i]
                if haskey(w, widget_key)
                    w[widget_key].range[] = [0.0]
                end
                continue
            end
            
            g_min, g_max = Inf, -Inf
            for pd in values(plot_data_dict)
                vals = i <= n_params ? pd.active_param_values[i] : pd.t_vals
               
                if !isnothing(vals) && !isempty(vals)
                    l, h = extrema(vals)
                    if l < g_min; g_min = l; end
                    if h > g_max; g_max = h; end
                end
            end
            
            if isinf(g_min); g_min = 0.0; g_max = 1.0; end
            
            widget_key = dim_names[i]
            if i <= n_params
                widget_key = haskey(manager.state["Reverse_Map"][], dim_names[i]) ? manager.state["Reverse_Map"][][dim_names[i]] : "param_$i"
            end
            
            if haskey(w, widget_key)
                ctrl = w[widget_key]
                if i <= n_params
                    all_vals = Float64[]
                    for pd in values(plot_data_dict)
                        append!(all_vals, pd.active_param_values[i])
                    end
                    ctrl.range[] = isempty(all_vals) ? [0.0] : sort(unique(all_vals))
                    set_close_to!(ctrl, ctrl.value[])
                else # Time slider
                    ctrl.range[] = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
                    set_close_to!(ctrl, ctrl.value[])
                end
            end
        end
        
        # Cleanup
        if manager.state["Config_Just_Loaded"][]
            opts = isempty(GLOBAL_SCENE_OPTIONS[]) ? get_base_scene_options() : GLOBAL_SCENE_OPTIONS[]
            apply_scene_options!(manager, opts)
            manager.state["Config_Just_Loaded"].val = false
        end
    end
end