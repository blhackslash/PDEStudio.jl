# ==============================================================================
# --- INTERACTION CONTROLLER ---
# ==============================================================================
# This file contains ONLY the reactive logic connecting the UI to the Data.

function setup_ui_interactions!(master_fig::Figure, plot_layout::GridLayout, manager::PlotManager, plot_data_obs::Observable)
    _setup_run_and_drop_interactions!(master_fig, manager)
    _setup_overwrite_interactions!(manager, plot_data_obs)
    _setup_hierarchy_interactions!(manager)
    
    # THE FIX: Pass plot_data_obs into the exporter!
    _setup_export_interactions!(master_fig, plot_layout, manager, plot_data_obs)
    
    _setup_data_sync_interactions!(manager, plot_data_obs)
    notify(manager.methods)
end

function _setup_run_and_drop_interactions!(master_fig::Figure, manager::PlotManager)
    drop_label = manager.controls["Widget"]["Drop_Label"][]
    drop_box   = manager.controls["Widget"]["Drop_Box"][]
    run_btn    = manager.controls["Widget"]["Run_Button"][]

# --- CSV DROP PIPELINE ---
    on(events(master_fig.scene).dropped_files) do files
        if !isempty(files) && endswith(lowercase(files[1]), ".csv")
            path = files[1]
            drop_label.text[] = "Loaded:\n" * basename(path)
            drop_label.color[] = RGBAf(0.0, 0.5, 0.0, 1.0)
            drop_box.color[] = RGBAf(0.8, 1.0, 0.8, 1.0)
            run_btn.buttoncolor[] = :lightgreen
            
            # Call the new helper!
            load_and_apply_csv!(manager, path)
        end
    end

    # --- REFRESH / RUN BUTTON ---
    on(manager.controls["Button"]["Run_Clicks"]) do _
        manager.controls["State"]["Simulation_Update"][] += 1
    end
end

function _setup_overwrite_interactions!(manager::PlotManager, plot_data_obs::Observable)
    menu_var = manager.controls["Widget"]["Overwrite_Var"][]
    tb_val   = manager.controls["Widget"]["Overwrite_Text"][]
    mode_btn = manager.controls["Widget"]["Mode_Button"][]
    menu_mth = manager.controls["Widget"]["Method_Toggle"][]
    
    is_activate_mode = manager.controls["State"]["Is_Activate_Mode"]
    # --- NEW: Dynamic Overwrite Options Sync ---
    # Variable Overwrite Dynamic Options Sync
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
            
            is_fixed_by_user = manager.controls["State"]["base_types"][][i] isa Number
            
            if has_variation || is_fixed_by_user
                push!(valid_base_names, name)
            end
        end
        
        current_sel = manager.controls["Selection"]["Overwrite_Var"][]
        manager.controls["Options"]["Overwrite_Var"][] = isempty(valid_base_names) ? ["-"] : valid_base_names
        
        if current_sel == "-" || isnothing(current_sel) || current_sel ∉ valid_base_names
            menu_var.i_selected[] = isempty(valid_base_names) ? 0 : 1
        else
            menu_var.i_selected[] = findfirst(isequal(current_sel), valid_base_names)
        end
    end
    # Dimension Overwrites 
    on(manager.controls["String"]["Overwrite_Text"]) do input_str
        var_name = manager.controls["Selection"]["Overwrite_Var"][]
        if isnothing(var_name) || var_name == "-" || isempty(input_str)
            @warn "Overwrite Error: Please select a variable and provide an input."
            return
        end

        idx = findfirst(isequal(var_name), VariableNames)
        isnothing(idx) && return
        
        vt = copy(manager.controls["State"]["base_types"][])
        n_params = length(manager.plot_vars) - 5
        abs_idx = n_params + idx
      
        if abs_idx in manager.controls["State"]["Active_Axes"][]
            @warn "Cannot fix the value of an active Plot Axis!"
            return
        end

        if lowercase(strip(input_str)) == "default"
            vt[idx] = VariableControls[idx]
            @info "Restored default control for $var_name."
        else
            val = tryparse(Int, input_str)
            if isnothing(val); val = tryparse(Float64, input_str); end
            if isnothing(val); @warn "Invalid Input."; return; end
            vt[idx] = val
        end
        
        manager.controls["State"]["base_types"][] = vt
        manager.controls["State"]["Simulation_Update"][] += 1
        tb_val.stored_string.val = "" 
        Makie.reset!(tb_val)
    end

    # Methods Toggle
    all_method_names = sort(filter(k -> k != "shared", collect(keys(manager.simulation))))
    
    onany(manager.methods, is_activate_mode) do active_list, activate_mode
        # Move this INSIDE the observer so it dynamically checks the simulation dictionary every time!
        all_method_names = sort(filter(k -> k != "shared", collect(keys(manager.simulation))))
        
        opts = activate_mode ? filter(m -> !(m in active_list), all_method_names) : copy(active_list)
        new_opts = isempty(opts) ? ["-"] : sort(opts)
        
        if menu_mth.options[] != new_opts
            menu_mth.options[] = new_opts
            menu_mth.i_selected[] = 0
        end
    end

    on(manager.controls["Button"]["Mode_Clicks"]) do _
        is_activate_mode[] = !is_activate_mode[]
        mode_btn.label[] = is_activate_mode[] ? "Mode: Activate" : "Mode: Deact."
        mode_btn.buttoncolor[] = is_activate_mode[] ? :lightgreen : :lightcoral
    end

    on(manager.controls["Selection"]["Method_Toggle"]) do m
        (isnothing(m) || m == "-") && return
        curr_list = manager.methods[]
        
        changed = false
        if is_activate_mode[]
            if !(m in curr_list); manager.methods[] = [curr_list; m]; changed = true; end
        else
            if (m in curr_list); manager.methods[] = filter(s -> s != m, curr_list); changed = true; end
        end
        
        # Reset the selection box visually to the prompt
        menu_mth.i_selected[] = 0
        
        # THE FIX: Instantly trigger the plot recalculation!
        if changed
            manager.controls["State"]["Simulation_Update"][] += 1
        end
    end
end

function _setup_hierarchy_interactions!(manager::PlotManager)
    menu_cat   = manager.controls["Widget"]["Editor_Cat"][]
    menu_scope = manager.controls["Widget"]["Editor_Scope"][]
    menu_key   = manager.controls["Widget"]["Editor_Key"][]
    tb         = manager.controls["Widget"]["Editor_Text"][]
    
    active_target_obs = manager.controls["State"]["Active_Target_Obs"]
    cat_mapping = Dict("Simulation" => :simulation, "UI" => :ui)

    onany(manager.controls["Selection"]["Editor_Cat"], manager.methods) do cat, active_methods
        isnothing(cat) && return
        field_name = cat_mapping[cat]
        data = getproperty(manager, field_name)
        
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
            menu_scope.i_selected[] = 0; menu_key.i_selected[] = 0
            tb.stored_string.val = ""; Makie.reset!(tb)
        end
    end

    on(manager.controls["Selection"]["Editor_Scope"]) do scope
        isnothing(scope) && return
        cat = menu_cat.selection[]
        data = getproperty(manager, cat_mapping[cat])
        
        menu_key.options[] = sort(collect(keys(data[scope])))
        active_target_obs[] = nothing 
        menu_key.i_selected[] = 0
        Makie.reset!(tb)
    end

    on(manager.controls["Selection"]["Editor_Key"]) do key
        isnothing(key) && return
        cat, scope = menu_cat.selection[], menu_scope.selection[]
        obs = getproperty(manager, cat_mapping[cat])[scope][key]
        
        active_target_obs[] = obs
        manager.controls["String"]["Editor_Display"][] = string(to_value(obs))
    end

    on(manager.controls["String"]["Editor_Text"]) do s
        obs = active_target_obs[]
        isnothing(obs) && return
        smart_parse_and_update!(obs, s)
        if menu_cat.selection[] == "UI"; manager.controls["State"]["UI_Update"][] += 1; end
    end
    
    on(manager.controls["Button"]["Editor_Toggle"]) do _
        obs = active_target_obs[]
        isnothing(obs) && return
        if to_value(obs) isa Bool
            obs[] = !to_value(obs)
            manager.controls["String"]["Editor_Display"][] = string(to_value(obs))
            if menu_cat.selection[] == "UI"; manager.controls["State"]["UI_Update"][] += 1; end
        end
    end

    on(manager.controls["Button"]["Editor_Reset"]) do _
        obs = active_target_obs[]
        isnothing(obs) && return
        manager.controls["String"]["Editor_Text"][] = "default" 
    end
end

function _setup_export_interactions!(master_fig::Figure, plot_layout::GridLayout, manager::PlotManager, plot_data_obs::Observable)
    saveBox = manager.controls["Widget"]["Export_Text"][]
    btn_play = manager.controls["Widget"]["Play_Anim_Button"][]
    
    anim_target_obs = manager.controls["Selection"]["Anim_Target"]
    is_animating = manager.controls["State"]["Is_Animating"]
    animation_timer = manager.controls["Misc"]["Animation_Timer"]
    
    n_params = length(manager.plot_vars)
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(manager.plot_vars); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"

    function check_selection_validity(idx)
        if idx == 0 || isnothing(idx); @warn "Export Error: No target selected."; return false; end
        if idx in manager.controls["State"]["Active_Axes"][]; @warn "Cannot animate an active plot axis."; return false; end
        
        widget_key = "$(dim_names[idx])"
        if !haskey(manager.controls["Widget"], widget_key); return false; end
        
        widget = manager.controls["Widget"][widget_key][]
        if !(widget isa Makie.Slider); @warn "Only Sliders can be animated."; return false; end
        if length(widget.range[]) < 2; @warn "Slider has no range to animate."; return false; end
        return true
    end

    # --- THE FIX 1: Isolated Headless Clone Builder ---
    function build_pristine_export_figure()
        export_fig = Figure(size = (1200, 1000))
        export_layout = export_fig[1, 1] = GridLayout()
        
        ptype_sym = manager.controls["Selection"]["Plot_Type"][]
        
        # We create a local, disconnected observable. 
        # This prevents notify() from accidentally clearing the main window's active axes!
        local_data_obs = Observable(plot_data_obs[])
        
        export_obs = setup_render_lift!(export_fig, export_layout, local_data_obs, manager, Val(ptype_sym))
        
        # Safely trigger ONLY the clone figure to draw its plots
        notify(local_data_obs)
        
        # Sync limits and camera angles seamlessly from live dashboard to the clone
        current_axes = [c.content for c in plot_layout.content if c.content isa Axis || c.content isa Axis3]
        export_axes = [c.content for c in export_layout.content if c.content isa Axis || c.content isa Axis3]
        
        for (c_ax, e_ax) in zip(current_axes, export_axes)
            if c_ax isa Axis3
                e_ax.azimuth[] = c_ax.azimuth[]
                e_ax.elevation[] = c_ax.elevation[]
                e_ax.perspectiveness[] = c_ax.perspectiveness[]
                e_ax.lookat[] = c_ax.lookat[]
            elseif c_ax isa Axis
                e_ax.finallimits[] = c_ax.finallimits[]
            end
        end
        
        return export_fig, export_obs
    end

    # --- Image Export ---
    on(manager.controls["Button"]["Save_Image_Clicks"]) do _
        base_name = string(strip(saveBox.stored_string[]))
        if isempty(base_name); base_name = "plot_export"; end

        save_dir = joinpath(get_save_path(), "figures")
        if manager.ui["Various"]["create_savefolder"][]; save_dir = joinpath(save_dir, base_name); end
        mkpath(save_dir)

        export_fig, export_obs = build_pristine_export_figure()

        # THE FIX: Force CairoMakie for ALL static saves to protect the GL context
        for fmt in manager.ui["Various"]["save_formats"][]
            ext = lowercase(strip(fmt))
            full_path = joinpath(save_dir, base_name * ".$ext")
            
            save(full_path, export_fig; backend=CairoMakie)
            @info "Pristine Image ($ext) saved safely via CairoMakie!"
        end

        if !isnothing(export_obs); for obs in export_obs; off(obs); end; end

        metadata = Dict("Save Type" => "Static Frame", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
        saveParametersToCSV(base_name, save_dir, manager, metadata)
    end

    # --- GIF Export ---
    on(manager.controls["Button"]["Save_GIF_Clicks"]) do _
        notify(manager.controls["Button"]["Save_Defs_Clicks"])
        target_idx = anim_target_obs[]
        !check_selection_validity(target_idx) && return
        target_widget = manager.controls["Widget"]["$(dim_names[target_idx])"][]
        
        base_name = string(strip(saveBox.stored_string[]))
        if isempty(base_name); base_name = "anim_export"; end
        
        save_path = joinpath(get_save_path(), "animations")
        mkpath(save_path)
        fname = joinpath(save_path, base_name * ".gif")
        
        duration = manager.ui["Various"]["animation_duration_s"][]
        fps = manager.ui["Various"]["animation_fps"][]
        rng = target_widget.range[]
        n_frames = Int(duration * fps)
        
        @info "Recording pristine '$(dim_names[target_idx])' animation to $fname..."
        try
            export_fig, export_obs = build_pristine_export_figure()
            
            record(export_fig, fname, range(rng[1], rng[end], length=n_frames); framerate=fps) do val
                set_close_to!(target_widget, val)
                yield() 
            end
            
            if !isnothing(export_obs); for obs in export_obs; off(obs); end; end

            metadata = Dict("Save Type" => "Animation", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
            saveParametersToCSV(base_name, save_path, manager, metadata) 
            @info "Pristine GIF Saved Successfully."
        catch e
            @error "GIF Recording Failed" exception=(e, catch_backtrace())
        end
    end

    # --- Save / Clear Defaults ---
    on(manager.controls["Button"]["Save_Defs_Clicks"]) do _
        GLOBAL_SCENE_OPTIONS[] = extract_scene_options(manager)
        new_ui = Dict{String, Any}()
        for (scope, subdict) in manager.ui
            new_ui[scope] = Dict{String, Any}()
            for (k, v) in subdict; new_ui[scope][k] = to_value(v); end
        end
        GLOBAL_UI_OVERWRITE[] = new_ui
        GLOBAL_VAR_OVERWRITE[] = copy(manager.controls["State"]["base_types"][])
        @info "Current UI and Scene options successfully saved to global defaults!"
    end
    
    on(manager.controls["Button"]["Clear_Defs_Clicks"]) do _
        GLOBAL_SCENE_OPTIONS[] = Dict{String, Any}()
        GLOBAL_UI_OVERWRITE[] = Dict{String, Any}()
        GLOBAL_VAR_OVERWRITE[] = Any[:menu, :slider, :slider, :slider, :slider]
        
        apply_scene_options!(manager, get_base_scene_options())
        @info "Global defaults cleared! Basic scene options restored."
    end

    # --- Animation Play ---
    on(is_animating) do animating
        btn_play.label[] = animating ? "Stop Anim" : "Play Anim"
    end

    on(manager.controls["Button"]["Play_Anim_Clicks"]) do _
        if is_animating[]
            is_animating[] = false
            !isnothing(animation_timer[]) && close(animation_timer[])
            animation_timer[] = nothing
        else
            target_idx = anim_target_obs[]
            !check_selection_validity(target_idx) && return
            
            target_widget = manager.controls["Widget"]["$(dim_names[target_idx])"][]
            is_animating[] = true
            
            duration = manager.ui["Various"]["animation_duration_s"][]
            fps = manager.ui["Various"]["animation_fps"][]
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

function _setup_data_sync_interactions!(manager::PlotManager, plot_data_obs::Observable)
    c = manager.controls
    x_sel = c["Selection"]["X-Axis"]
    y_sel = c["Selection"]["Y-Axis"]
    z_sel = c["Selection"]["Z-Axis"]
    ptype_obs = c["Selection"]["Plot_Type"]
    comp_tgt_obs = c["Selection"]["Compare_Target"]
    
    active_axes_obs = c["State"]["Active_Axes"]
    dim_names = manager.plot_vars
    total_dims = length(dim_names)
    n_params = total_dims - 5
    comp_idx = n_params + 1

    function _update_menu!(menu_widget, new_options; fallbacks=["x", "y", "z", "t"])
        curr = menu_widget.selection[]
        menu_widget.options[] = isempty(new_options) ? ["-"] : new_options
        if curr == "-" || isnothing(curr) || curr ∉ new_options
            if isempty(new_options)
                menu_widget.i_selected[] = 0
            else
                idx = nothing
                for f in fallbacks
                    idx = findfirst(isequal(f), new_options)
                    !isnothing(idx) && break
                end
                menu_widget.i_selected[] = isnothing(idx) ? 1 : idx
            end
        else
            menu_widget.i_selected[] = findfirst(isequal(curr), new_options)
        end
    end

    # 1. Sync Dropdown Options (Valid Axes & Components)
    onany(plot_data_obs, ptype_obs, comp_tgt_obs) do plot_data_dict, ptype, comp_tgt
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
                if is_pure_series || is_pure_param; push!(valid_axes, key); end
            end
            if key == "u"; comp_max = max(comp_max, size(tensor, n_params + 1)); end
        end
        
        if comp_tgt == "Time"; filter!(k -> k != "t", valid_axes)
        elseif comp_tgt == "Component"; filter!(k -> k != "c", valid_axes)
        elseif comp_tgt in dim_names; filter!(k -> k != comp_tgt, valid_axes)
        end
        
        sort!(valid_axes)
        _update_menu!(c["Widget"]["X-Axis"][], valid_axes; fallbacks=["x", "t", "y", "z"])
        _update_menu!(c["Widget"]["c"][], [string(i) for i in 1:comp_max]; fallbacks=["1"])
        
        p_dim = PLOT_DIM_MAP[ptype]
        if p_dim >= 2
            _update_menu!(c["Widget"]["Y-Axis"][], valid_axes; fallbacks=["y", "t", "z", "x"])
        else
            c["Widget"]["Y-Axis"][].options[] = ["disabled"]
            c["Widget"]["Y-Axis"][].i_selected[] = 1
        end
        if p_dim >= 3
            _update_menu!(c["Widget"]["Z-Axis"][], valid_axes; fallbacks=["z", "t", "x", "y"])
        else
            c["Widget"]["Z-Axis"][].options[] = ["disabled"]
            c["Widget"]["Z-Axis"][].i_selected[] = 1
        end
    end

    # 2. Sync Active Axes State
    onany(x_sel, y_sel, z_sel, ptype_obs, plot_data_obs) do x_val, y_val, z_val, ptype, plot_data_dict
        isempty(plot_data_dict) && return
        p_dim = PLOT_DIM_MAP[ptype]
        axes_set = Set{Int}()
        active_indep_keys = String[]
        pd_first = first(values(plot_data_dict))
        
        for (dim_req, val) in zip([1, 2, 3], [x_val, y_val, z_val])
            if p_dim >= dim_req && !isnothing(val) && val != "-" && val != "disabled"
                idx = get_base_dim_idx(pd_first, val, dim_names)
                !isnothing(idx) && push!(axes_set, idx)
                push!(active_indep_keys, val)
            end
        end
        
        active_axes_obs[] = collect(axes_set)
        
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
        _update_menu!(c["Widget"]["U-Axis"][], valid_fields)
    end

    # 3. Sync Slider Ranges (The core data injection to the UI!)
    onany(active_axes_obs, plot_data_obs) do active_axes, plot_data_dict
        isempty(plot_data_dict) && return
        vt = c["State"]["base_types"][]

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
            
            # THE FIX: Route the physical name to the static UI widget!
            widget_key = dim_name
            if i <= n_params
                widget_key = c["State"]["Reverse_Map"][][dim_name]
            end
            
            if haskey(c["Widget"], widget_key)
                ctrl = c["Widget"][widget_key][]
                if is_axis
                    ctrl.range[] = [0.0] 
                else
                    ctrl.range[] = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
                end
            end
        end
        if c["State"]["Config_Just_Loaded"][]
            # Force the flag to false BEFORE applying options to completely prevent re-entrancy loops!
            c["State"]["Config_Just_Loaded"].val = false
            
            opts = isempty(GLOBAL_SCENE_OPTIONS[]) ? get_base_scene_options() : GLOBAL_SCENE_OPTIONS[]
            apply_scene_options!(manager, opts)
        end
    end
end