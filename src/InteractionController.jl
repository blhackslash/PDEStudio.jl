# ==============================================================================
# --- INTERACTION CONTROLLER ---
# ==============================================================================

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

    on(run_btn.clicks) do _
        manager.triggers["Simulation_Update"][] += 1
    end
end

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
            
            val_str = string(to_value(obs))
            tb.displayed_string[] = isempty(val_str) ? "<empty>" : val_str
        end
    end

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

    on(menu_key.selection) do _
        sync_textbox_to_active_key()
    end

    on(tb.stored_string) do s
        obs = active_target_obs[]
        isnothing(obs) && return
        smart_parse_and_update!(obs, s)
        if menu_cat.selection[] == "UI"
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
    btn_lock = manager.widgets["Lock_Camera_Button"] 
    
    if !haskey(manager.state, "Camera_Locked")
        manager.state["Camera_Locked"] = Observable(false)
    end

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

    function get_target_widget(target_name)
        target_name == :None && return nothing
        target_str = string(target_name)
        rev_map = haskey(manager.state, "Reverse_Map") ? manager.state["Reverse_Map"][] : Dict{Symbol, String}()
        w_key = haskey(rev_map, target_name) ? rev_map[target_name] : target_str
        return haskey(manager.widgets, w_key) ? manager.widgets[w_key] : nothing
    end

    function check_selection_validity(target_name)
        if isnothing(target_name) || target_name == :None
            @warn "Export Error: No target selected."
            return false 
        end
        
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
        
        base_sel  = manager.widgets["Base_Plot"].selection[]
        style_sel = manager.widgets["Plot_Style"].selection[]
        ptype_sym = get(PLOT_ROUTING_MATRIX, (base_sel, style_sel), :lines)
        
        local_data_obs = Observable(plot_data_obs[])
        export_obs = setup_render_lift!(export_fig, export_layout, local_data_obs, manager, Val(ptype_sym))
        
        current_axes = [c.content for c in plot_layout.content if c.content isa Axis || c.content isa Axis3]
        export_axes = [c.content for c in export_layout.content if c.content isa Axis || c.content isa Axis3]
        manager.triggers["Primitive_Rebuild"][] += 1
        for (c_ax, e_ax) in zip(current_axes, export_axes)
            if c_ax isa Axis3
                e_ax.azimuth[] = c_ax.azimuth[]
                e_ax.elevation[] = c_ax.elevation[]
                e_ax.perspectiveness[] = c_ax.perspectiveness[]
                
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
        
        resize_to_layout!(export_fig)
        return export_fig, export_obs
    end

    on(manager.widgets["Save_Image_Button"].clicks) do _
        was_locked = manager.state["Camera_Locked"][]
        manager.state["Camera_Locked"][] = true 
        
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
        
        was_locked = manager.state["Camera_Locked"][]
        manager.state["Camera_Locked"][] = true 
        
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
            
            if !was_locked
                manager.state["Camera_Locked"][] = false
                GLOBAL_CAMERA_OPTIONS[] = Dict{String, Any}()
            end
            manager.triggers["Primitive_Rebuild"][] += 1
        end
    end

    on(manager.widgets["Save_Defs_Button"].clicks) do _
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
        @info "Current UI, Layout, and Scene options successfully saved to global defaults!"
    end
    
    on(manager.widgets["Clear_Defs_Button"].clicks) do _
        GLOBAL_SCENE_OPTIONS[] = Dict{String, Any}()
        GLOBAL_UI_OVERWRITE[]  = Dict{String, Any}()
        GLOBAL_LAYOUT_OPTIONS[]= Dict{String, Any}()
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

function _get_active_sim_data(plot_data_dict)
    isempty(plot_data_dict) && return nothing, nothing
    pd_first = first(values(plot_data_dict))
    
    _get_first_valid(pd) = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))
    sim_data = _get_first_valid(pd_first)
    
    return pd_first, sim_data
end

function _setup_common_chain_c!(manager::PlotManager, plot_data_obs::Observable, mode::Symbol)
    w = manager.widgets
    onany(w["U-Axis"].selection, plot_data_obs) do u_val, plot_data_dict
        @with_lock manager "Menu_C" begin
            pd_first, sim_data = _get_active_sim_data(plot_data_dict)
            isnothing(sim_data) && return
            
            target_field = (isnothing(u_val) || u_val == :None) ? :Solution : u_val
            target_tensor = get(sim_data.stats, target_field, sim_data.stats[:Solution])
            
            # Mode-specific tensor evaluation
            if mode == :lagrangian
                target_tensor_arr = target_tensor isa AbstractArray && ndims(target_tensor) == 1 ? target_tensor : target_tensor[1]
                comp_max = length(target_tensor_arr[1])
            else
                comp_max = length(eltype(target_tensor))
            end
            
            comp_names_tuple = manager.ui["Labels"]["comp_names"][]
            c_options = Any[]
            for i in 1:comp_max
                name = (comp_names_tuple isa Tuple && length(comp_names_tuple) >= i && comp_names_tuple[i] != "default" && !isempty(string(comp_names_tuple[i]))) ? string(comp_names_tuple[i]) : string(i)
                push!(c_options, (name, i))
            end
            update_menu_safe!(w["c"], c_options; fallbacks=[1])
        end
    end
end

function _setup_common_chain_d!(manager::PlotManager, plot_data_obs::Observable, mode::Symbol)
    w = manager.widgets
    active_axes_obs = manager.state["Active_Axes"]
    
    onany(active_axes_obs, w["U-Axis"].selection, plot_data_obs) do active_axes, u_val, plot_data_dict
        @with_lock manager "Menu_D" begin
            pd_first, sim_data = _get_active_sim_data(plot_data_dict)
            isnothing(sim_data) && return

            dim_names = manager.plot_vars
            total_dims = length(dim_names)
            n_params = total_dims - length(get_base_variables())
            
            target_field = (isnothing(u_val) || u_val == :None) ? :Solution : u_val
            kept_syms = Tuple(IRunPDESims.get_kept_dims(target_field, sim_data.domain))

            for i in 1:total_dims
                dim_sym = dim_names[i]
                dim_str = String(dim_sym)
                is_axis = i in active_axes
                
                is_spatial = false
                is_physically_disabled = false
                
                # Mode-specific domain logic
                if i > n_params
                    if mode == :lagrangian
                        is_spatial = dim_sym != sim_data.domain.time_dim
                        is_physically_disabled = !is_spatial && !(dim_sym in kept_syms)
                    else
                        is_physically_disabled = !(dim_sym in kept_syms)
                    end
                end
                
                widget_key = i > n_params ? dim_str : get(manager.state["Reverse_Map"][], dim_sym, "param_$i")
                haskey(w, widget_key) || continue
                ctrl = w[widget_key]
                
                if is_axis || is_spatial || is_physically_disabled
                    ctrl.range[] = [0.0] 
                    continue
                end
                
                g_min, g_max = Inf, -Inf
                for pd in values(plot_data_dict)
                    vals = nothing
                    if i <= n_params 
                        vals = pd.active_param_values[i]
                    else
                        # Safe extraction helper per dataset
                        s_data = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))
                        isnothing(s_data) && continue
                        
                        if mode == :lagrangian
                            if dim_sym == s_data.domain.time_dim
                                vals = s_data.t
                            end
                        else
                            idx = findfirst(==(dim_sym), s_data.domain.dim_keys)
                            if !isnothing(idx)
                                vals = s_data.axes[idx]
                            end
                        end
                    end
                
                    if !isnothing(vals) && !isempty(vals)
                        l, h = extrema(vals)
                        g_min = min(l, g_min)  # Note: Unified the min/max calls here for cleanliness
                        g_max = max(h, g_max)
                    end
                end
                
                if isinf(g_min); g_min = 0.0; g_max = 1.0; end
                
                if i <= n_params
                    all_vals = Float64[]
                    for pd in values(plot_data_dict)
                        append!(all_vals, pd.active_param_values[i])
                    end
                    ctrl.range[] = isempty(all_vals) ? [0.0] : sort(unique(all_vals))
                else
                    ctrl.range[] = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
                end
                set_close_to!(ctrl, ctrl.value[])
            end
            
            if manager.state["Config_Just_Loaded"][]
                opts = GLOBAL_SCENE_OPTIONS[]
                apply_scene_options!(manager, opts)
                manager.state["Config_Just_Loaded"].val = false
            end
        end
    end
end

# ==============================================================================
# --- EULERIAN PIPELINE SPECIFICS ---
# ==============================================================================
function _setup_eulerian_data_sync!(manager::PlotManager, plot_data_obs::Observable)
    w = manager.widgets
    x_sel = w["X-Axis"].selection
    y_sel = w["Y-Axis"].selection
    z_sel = w["Z-Axis"].selection
    base_obs = w["Base_Plot"].selection
    style_obs = w["Plot_Style"].selection
    
    base_opts = PLOT_MODE[] == :eulerian ? 
        Any[("Lines", :lines), ("Scatter", :scatter), ("Contour", :contour), ("Heatmap", :heatmap), ("Volume", :volume)] : 
        Any[("Scatter", :scatter)]
    
    update_menu_safe!(w["Base_Plot"], base_opts; fallbacks=[:lines], force_notify=false)

    on(base_obs) do base_type
        (isnothing(base_type) || base_type == :None) && return
        manager.locks["Layout"] = true 
        active_dict = PLOT_MODE[] == :lagrangian ? LAGRANGIAN_PLOT_STYLE_OPTIONS : EULERIAN_PLOT_STYLE_OPTIONS
        valid_styles = get(active_dict, base_type, Any[("1D", :one_d)])
        update_menu_safe!(w["Plot_Style"], valid_styles; fallbacks=[:one_d], force_notify=false)
        notify(manager.widgets["Editor_Scope"].selection)
    end
    
    on(style_obs) do _
        manager.locks["Layout"] = true 
        notify(manager.widgets["Editor_Scope"].selection)
    end

    active_axes_obs = manager.state["Active_Axes"]

    # =========================================================================
    # CHAIN A: Structural Setup (Data, Base Plot, Plot Style) -> Axes, Anim, Compare
    # =========================================================================
    onany(plot_data_obs, base_obs, style_obs) do plot_data_dict, base_sel, style_sel
        @with_lock manager "Menu_A" begin
            isempty(plot_data_dict) && return
            
            pd_first = first(values(plot_data_dict))
            n_params = length(pd_first.active_param_keys)
            if n_params > 0; manager.plot_vars[1:n_params] .= Symbol.(pd_first.active_param_keys); end
            dim_names = manager.plot_vars
            
            _get_first_valid(pd) = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))
            sim_data = _get_first_valid(pd_first)
            isnothing(sim_data) && return
            
            valid_indep_axes = Symbol[]
            for p in pd_first.active_param_keys; push!(valid_indep_axes, Symbol(p)); end
            for k in sim_data.domain.dim_keys; push!(valid_indep_axes, k); end
            
            # Sub Axes
            for k in keys(sim_data.stats)
                k === :Solution && continue
                stat_dims = IRunPDESims.get_kept_dims(k, sim_data.domain)
                if isempty(stat_dims)
                    for p in pd_first.active_param_keys
                        push!(valid_indep_axes, Symbol("$(String(k))|$p"))
                    end
                elseif length(stat_dims) == 1
                    push!(valid_indep_axes, Symbol("$(String(k))|$(stat_dims[1])"))
                end
            end
            
            anim_options = Any[("None", :None)]
            for i in 1:length(dim_names)
                ax_sym = dim_names[i]
                ax_str = String(ax_sym)
                if i <= n_params && length(pd_first.active_param_values[i]) > 1
                    push!(anim_options, (nice_string(ax_str), ax_sym))
                elseif i > n_params && ax_sym in valid_indep_axes
                    push!(anim_options, (get(DIM_LABELS[], ax_sym, nice_string(ax_str)), ax_sym))
                end
            end
            update_menu_safe!(w["Anim_Target"], anim_options; fallbacks=[:None])

            compare_opts = Any[("None", :None), ("Methods", :Methods), ("Component", :Component)]
            if !isnothing(sim_data.domain.time_dim)
                push!(compare_opts, ("Time", :Time))
            end
            for p_key in pd_first.active_param_keys
                push!(compare_opts, (string(p_key), Symbol(p_key)))
            end
            update_menu_safe!(w["Compare_Target"], compare_opts; fallbacks=[:None], force_notify=false)

            ptype = get(PLOT_ROUTING_MATRIX, (base_sel, style_sel), :lines)
            p_dim = PLOT_DIM_MAP[ptype]
            
            function build_axis_opts(excluded_syms)
                excluded_loops = [occursin("|", string(ex)) ? Symbol(split(string(ex), "|")[2]) : ex for ex in excluded_syms]
                opts = Any[]
                for ax_sym in valid_indep_axes
                    ax_str = string(ax_sym)
                    loop_dim = occursin("|", ax_str) ? Symbol(split(ax_str, "|")[2]) : ax_sym
                    loop_dim in excluded_loops && continue
                    
                    if occursin("|", ax_str)
                        stat_name = split(ax_str, "|")[1]
                        nice_name = "$(nice_string(stat_name)) (over $(nice_string(string(loop_dim))))"
                        push!(opts, (nice_name, ax_sym))
                    elseif ax_sym in manager.plot_vars && ax_sym ∉ ALLOWED_PLOT_DIMS[]
                        push!(opts, (nice_string(ax_str), ax_sym))
                    else
                        push!(opts, (get(DIM_LABELS[], ax_sym, nice_string(ax_str)), ax_sym))
                    end
                end
                return isempty(opts) ? Any[("disabled", :None)] : opts
            end
            
            base_vars = get_base_variables()
            x_val = w["X-Axis"].selection[]
            
            update_menu_safe!(w["X-Axis"], build_axis_opts([]); fallbacks=base_vars, force_notify=false)
            if p_dim >= 2
                update_menu_safe!(w["Y-Axis"], build_axis_opts([x_val]); fallbacks=base_vars, force_notify=false)
            else
                update_menu_safe!(w["Y-Axis"], Any[("disabled", :None)]; fallbacks=[:None], force_notify=false)
            end
            
            curr_y = w["Y-Axis"].selection[]
            if p_dim >= 3
                update_menu_safe!(w["Z-Axis"], build_axis_opts([x_val, curr_y]); fallbacks=base_vars, force_notify=false)
            else
                update_menu_safe!(w["Z-Axis"], Any[("disabled", :None)]; fallbacks=[:None], force_notify=false)
            end
        end
    end

    # =========================================================================
    # CHAIN B: Axes Changes (X, Y, Z, Data) -> U-Axis, Active Axes
    # =========================================================================
    onany(x_sel, y_sel, z_sel, plot_data_obs) do x_val, y_val, z_val, plot_data_dict
        @with_lock manager "Menu_B" begin
            isempty(plot_data_dict) && return

            pd_first = first(values(plot_data_dict))
            _get_first_valid(pd) = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))
            sim_data = _get_first_valid(pd_first)
            isnothing(sim_data) && return
            
            axes_set = Set{Int}()
            active_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_val, y_val, z_val])
            active_loop_dims = Symbol[]
            
            for val in active_axes_syms
                loop_dim = occursin("|", string(val)) ? Symbol(split(string(val), "|")[2]) : val
                push!(active_loop_dims, loop_dim)
                idx = findfirst(isequal(loop_dim), manager.plot_vars)
                !isnothing(idx) && push!(axes_set, idx)
            end
            
            active_physical_axes = filter(a -> a in sim_data.domain.dim_keys, active_loop_dims)
            valid_fields = Any[]
            
            if issubset(active_physical_axes, sim_data.domain.dim_keys)
                push!(valid_fields, ("Solution", :Solution))
            end
            
            for k in keys(sim_data.stats)
                k === :Solution && continue
                kept_syms = IRunPDESims.get_kept_dims(k, sim_data.domain)
                if issubset(active_physical_axes, kept_syms)
                    push!(valid_fields, (string(k), k))
                end
            end
            
            sort!(valid_fields, by = x -> x[1])
            update_menu_safe!(w["U-Axis"], valid_fields; fallbacks=[:Solution], force_notify=false)
            
            active_axes_obs.val = collect(axes_set)
            if !manager.state["Config_Just_Loaded"][]
                notify(active_axes_obs)
            end
        end
    end

    _setup_common_chain_c!(manager, plot_data_obs, :eulerian)
    _setup_common_chain_d!(manager, plot_data_obs, :eulerian)
end

# ==============================================================================
# --- LAGRANGIAN PIPELINE SPECIFICS ---
# ==============================================================================
function _setup_lagrangian_data_sync!(manager::PlotManager, plot_data_obs::Observable)
    w = manager.widgets
    active_axes_obs = manager.state["Active_Axes"]
    
    # =========================================================================
    # CHAIN A: Structural Setup (Data) -> Style, Axes, Anim, Compare
    # =========================================================================
    onany(plot_data_obs) do plot_data_dict
        @with_lock manager "Menu_A" begin
            isempty(plot_data_dict) && return
            
            pd_first = first(values(plot_data_dict))
            _get_first_valid(pd) = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))
            l_data = _get_first_valid(pd_first)
            isnothing(l_data) && return
            
            n_params = length(pd_first.active_param_keys)
            dim_names = manager.plot_vars
            
            D = length(l_data.domain.mins) - (isnothing(l_data.domain.time_dim) ? 0 : 1)
            spatial_keys = filter(k -> k != l_data.domain.time_dim, l_data.domain.dim_keys)
            
            sx = D >= 1 ? spatial_keys[1] : :x
            sy = D >= 2 ? spatial_keys[2] : :y
            sz = D >= 3 ? spatial_keys[3] : :z
            
            update_menu_safe!(w["X-Axis"], Any[(string(sx), sx)]; fallbacks=[sx], force_notify=true)
            if D == 1
                update_menu_safe!(w["Plot_Style"], Any[("1D", :one_d), ("Lines", :lines), ("Colors", :colors)]; fallbacks=[:one_d], force_notify=false)
                update_menu_safe!(w["Y-Axis"], Any[("disabled", :None)]; fallbacks=[:None])
                update_menu_safe!(w["Z-Axis"], Any[("disabled", :None)]; fallbacks=[:None])
            elseif D == 2
                update_menu_safe!(w["Plot_Style"], Any[("2D", :two_d), ("2D (Surface)", :surface2D)]; fallbacks=[:two_d], force_notify=false)
                update_menu_safe!(w["Y-Axis"], Any[(string(sy), sy)]; fallbacks=[sy])
                update_menu_safe!(w["Z-Axis"], Any[("disabled", :None)]; fallbacks=[:None])
            else
                update_menu_safe!(w["Plot_Style"], Any[("3D", :three_d)]; fallbacks=[:three_d], force_notify=false)
                update_menu_safe!(w["Y-Axis"], Any[(string(sy), sy)]; fallbacks=[sy])
                update_menu_safe!(w["Z-Axis"], Any[(string(sz), sz)]; fallbacks=[sz])
            end
            
            anim_options = Any[("None", :None)]
            for i in 1:n_params
                ax_sym = dim_names[i]
                ax_str = String(ax_sym)
                if length(pd_first.active_param_values[i]) > 1
                    push!(anim_options, (nice_string(ax_str), ax_sym))
                end
            end
            update_menu_safe!(w["Anim_Target"], anim_options; fallbacks=[:None])
            
            compare_opts = Any[("None", :None), ("Methods", :Methods), ("Component", :Component)]
            if !isnothing(l_data.domain.time_dim)
                push!(compare_opts, ("Time", :Time))
            end
            for p_key in pd_first.active_param_keys
                push!(compare_opts, (string(p_key), Symbol(p_key)))
            end
            update_menu_safe!(w["Compare_Target"], compare_opts; fallbacks=[:None], force_notify=false)
        end
    end
    
    # =========================================================================
    # CHAIN B: Axes Changes (X, Y, Z, Data) -> U-Axis, Active Axes
    # =========================================================================
    onany(w["X-Axis"].selection, w["Y-Axis"].selection, w["Z-Axis"].selection, plot_data_obs) do x_val, y_val, z_val, plot_data_dict
        @with_lock manager "Menu_B" begin
            isempty(plot_data_dict) && return
            
            pd_first = first(values(plot_data_dict))
            _get_first_valid(pd) = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))
            l_data = _get_first_valid(pd_first)
            isnothing(l_data) && return
            
            spatial_keys = filter(k -> k != l_data.domain.time_dim, l_data.domain.dim_keys)

            valid_fields = Any[("Solution", :Solution)]
            for k in keys(l_data.stats)
                k === :Solution && continue
                kept_syms = IRunPDESims.get_kept_dims(k, l_data.domain)
                if issubset(spatial_keys, kept_syms)
                    push!(valid_fields, (string(k), k))
                end
            end
            sort!(valid_fields, by = x -> x[1])
            update_menu_safe!(w["U-Axis"], valid_fields; fallbacks=[:Solution], force_notify=false)
            
            axes_set = Set{Int}()
            idx_x = findfirst(isequal(x_val), manager.plot_vars); !isnothing(idx_x) && push!(axes_set, idx_x)
            if y_val != :None
                idx_y = findfirst(isequal(y_val), manager.plot_vars); !isnothing(idx_y) && push!(axes_set, idx_y)
            end
            if z_val != :None
                idx_z = findfirst(isequal(z_val), manager.plot_vars); !isnothing(idx_z) && push!(axes_set, idx_z)
            end
            
            active_axes_obs.val = collect(axes_set)
            if !manager.state["Config_Just_Loaded"][]
                notify(active_axes_obs)
            end
        end
    end

    _setup_common_chain_c!(manager, plot_data_obs, :lagrangian)
    _setup_common_chain_d!(manager, plot_data_obs, :lagrangian)
end