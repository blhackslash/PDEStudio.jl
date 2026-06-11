# ==============================================================================
# --- INTERACTION CONTROLLER ---
# ==============================================================================
# This file contains ONLY the reactive logic connecting the UI to the Data.

function setup_ui_interactions!(master_fig::Figure, plot_layout::GridLayout, manager::PlotManager, plot_data_obs::Observable)
    _setup_run_and_drop_interactions!(master_fig, manager)
    _setup_overwrite_interactions!(manager, plot_data_obs)
    _setup_hierarchy_interactions!(manager)
    _setup_export_interactions!(master_fig, plot_layout, manager, plot_data_obs)
    _setup_data_sync_interactions!(manager, plot_data_obs)
    
    # Kick off the cascade and FORCE Makie to listen
    manager.widgets["Editor_Cat"].i_selected[] = 1
    notify(manager.widgets["Editor_Cat"].selection)
    
    notify(manager.methods)
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
function _setup_overwrite_interactions!(manager::PlotManager, plot_data_obs::Observable)
    menu_var = manager.widgets["Overwrite_Var"]
    tb_val   = manager.widgets["Overwrite_Text"]
    mode_btn = manager.widgets["Mode_Button"]
    menu_mth = manager.widgets["Method_Toggle"]
    
    is_activate_mode = manager.state["Is_Activate_Mode"]
    
    # -------------------------------------------------------------------------
    # STAGED METHODS STATE: Decouples UI selection from simulation execution
    # -------------------------------------------------------------------------
    if !haskey(manager.state, "Staged_Methods")
        manager.state["Staged_Methods"] = Observable(copy(manager.methods[]))
    end
    staged_methods = manager.state["Staged_Methods"]

    # Keep staging in sync if a completely new CSV config is loaded
    on(manager.methods) do active_methods
        staged_methods[] = copy(active_methods)
    end

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
            
            is_fixed_by_user = manager.state["base_types"][][i] isa Number
            if has_variation || is_fixed_by_user
                push!(valid_base_names, name)
            end
        end
        
        current_sel = menu_var.selection[]
        menu_var.options[] = isempty(valid_base_names) ? ["-"] : valid_base_names
        
        if current_sel == "-" || isnothing(current_sel) || current_sel ∉ valid_base_names
            menu_var.i_selected[] = 1
        else
            menu_var.i_selected[] = findfirst(isequal(current_sel), valid_base_names)
        end
    end

    # =========================================================================
    # APPLY BUTTON: Dimension Overwrites 
    # =========================================================================
    on(manager.widgets["Overwrite_Apply"].clicks) do _
        var_name = menu_var.selection[]
        input_str = tb_val.stored_string.val # Safely pull the text on click
        
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

    # =========================================================================
    # APPLY BUTTON: Methods Toggle 
    # =========================================================================
    onany(staged_methods, is_activate_mode) do staged, activate_mode
        @with_lock manager "Menu_Sync" begin
            all_method_names = sort(filter(k -> k != "shared", collect(keys(manager.simulation))))
            opts = activate_mode ? filter(m -> !(m in staged), all_method_names) : copy(staged)
            
            # ALWAYS provide a default "-" dash at index 1
            new_opts = isempty(opts) ? [("Methods...","-")] : [("Methods...","-"); sort(opts)]
            
            if menu_mth.options[] != new_opts
                menu_mth.options[] = new_opts
                menu_mth.i_selected[] = 1
            end
        end
    end

    on(mode_btn.clicks) do _
        is_activate_mode[] = !is_activate_mode[]
        mode_btn.label[] = is_activate_mode[] ? "Mode: Activate" : "Mode: Deact."
        mode_btn.buttoncolor[] = is_activate_mode[] ? :lightgreen : :lightcoral
    end

    on(menu_mth.selection) do m
        @with_lock manager "Menu_Sync" begin
            (isnothing(m) || m == "-") && return
            
            curr_staged = staged_methods[]
            
            if is_activate_mode[]
                if !(m in curr_staged)
                    staged_methods[] = [curr_staged; m]
                end
            else
                if (m in curr_staged)
                    staged_methods[] = filter(s -> s != m, curr_staged)
                end
            end
            
            # Snap back to default
            menu_mth.i_selected[] = 1
        end
    end

    # Only fire the simulation when Apply is explicitly clicked!
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
            tb.displayed_string[] = string(to_value(obs))
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
            for m in sort(active_methods)
                haskey(data, m) && push!(new_scopes, m)
            end
        else
            new_scopes = sort(collect(keys(data)))
        end
        
        new_scopes = isempty(new_scopes) ? ["-"] : new_scopes
        
        if menu_scope.options[] != new_scopes
            menu_scope.options[] = new_scopes
            menu_scope.i_selected[] = 1 
            # THE FIX: Force the cascade downward even if string is unchanged!
            notify(menu_scope.selection)
        end
    end

    # =========================================================================
    # TIER 2: Scope Selection -> Rebuilds Key Options Vector
    # =========================================================================
    on(menu_scope.selection) do scope
        if isnothing(scope) || scope == "-"
            if menu_key.options[] != ["-"]
                menu_key.options[] = ["-"]
                menu_key.i_selected[] = 1
                notify(menu_key.selection)
            end
            sync_textbox_to_active_key()
            return
        end
        
        cat = menu_cat.selection[]
        data = getproperty(manager, cat_mapping[cat])
        
        raw_keys = sort(collect(keys(data[scope])))
        new_keys = isempty(raw_keys) ? [("-", "-")] : [(nice_string(k), k) for k in raw_keys]
        
        if menu_key.options[] != new_keys
            menu_key.options[] = new_keys
            menu_key.i_selected[] = 1
            # THE FIX: Force the cascade downward!
            notify(menu_key.selection)
        end
        
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
        if menu_cat.selection[] == "UI"; manager.triggers["UI_Update"][] += 1; end
    end
    
    on(manager.widgets["Editor_Toggle"].clicks) do _
        obs = active_target_obs[]
        isnothing(obs) && return
        if to_value(obs) isa Bool
            obs[] = !to_value(obs)
            tb.displayed_string[] = string(obs[])
            if menu_cat.selection[] == "UI"; manager.triggers["UI_Update"][] += 1; end
        end
    end

    on(manager.widgets["Editor_Reset"].clicks) do _
        obs = active_target_obs[]
        isnothing(obs) && return
        tb.stored_string[] = "default" 
        tb.displayed_string[] = "default"
    end
end

function _setup_export_interactions!(master_fig::Figure, plot_layout::GridLayout, manager::PlotManager, plot_data_obs::Observable)
    saveBox = manager.widgets["Export_Text"]
    btn_play = manager.widgets["Play_Anim_Button"]
    
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
        export_fig = Figure(size = (1200, 1000))
        export_layout = export_fig[1, 1] = GridLayout()
        
        ptype_sym = manager.widgets["Plot_Type"].selection[]
        local_data_obs = Observable(plot_data_obs[])
        export_obs = setup_render_lift!(export_fig, export_layout, local_data_obs, manager, Val(ptype_sym))
        notify(local_data_obs)
        
        current_axes = [c.content for c in plot_layout.content if c.content isa Axis || c.content isa Axis3]
        export_axes = [c.content for c in export_layout.content if c.content isa Axis || c.content isa Axis3]
        
        for (c_ax, e_ax) in zip(current_axes, export_axes)
            if c_ax isa Axis3
                e_ax.azimuth[] = c_ax.azimuth[]
                e_ax.elevation[] = c_ax.elevation[]
                e_ax.perspectiveness[] = c_ax.perspectiveness[]
                e_ax.lookat[] = c_ax.lookat[]
            elseif c_ax isa Axis
                lims = c_ax.finallimits[]
                limits!(e_ax, lims.origin[1], lims.origin[1] + lims.widths[1], 
                              lims.origin[2], lims.origin[2] + lims.widths[2])
            end
        end
        return export_fig, export_obs
    end

    on(manager.widgets["Save_Image_Button"].clicks) do _
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
    end

    on(manager.widgets["Save_GIF_Button"].clicks) do _
        notify(manager.widgets["Save_Defs_Button"].clicks)
        target_name = anim_target_obs[]
        !check_selection_validity(target_name) && return
        target_widget = get_target_widget(target_name)
        
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
        finally
            tmp = ACTIVE_SIM_CONFIG[]
            reset_plotter!()
            launch_plotter()
            ACTIVE_SIM_CONFIG[] = tmp
        end
    end

    on(manager.widgets["Save_Defs_Button"].clicks) do _
        GLOBAL_SCENE_OPTIONS[]  = extract_scene_options(manager)
        GLOBAL_LAYOUT_OPTIONS[] = extract_layout_options(manager) # THE FIX: Safely store the layout matrix!
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

function _setup_data_sync_interactions!(manager::PlotManager, plot_data_obs::Observable)
    w = manager.widgets
    x_sel = w["X-Axis"].selection
    y_sel = w["Y-Axis"].selection
    z_sel = w["Z-Axis"].selection
    ptype_obs = w["Plot_Type"].selection
    comp_tgt_obs = w["Compare_Target"].selection
    
    active_axes_obs = manager.state["Active_Axes"]
    
    function _update_menu!(menu_widget, new_options; fallbacks=["x", "y", "z", "t"])
        curr = menu_widget.selection[]
        menu_widget.options[] = isempty(new_options) ? ["-"] : new_options
        opt_values = (!isempty(new_options) && new_options[1] isa Tuple) ? [opt[2] for opt in new_options] : new_options

        if curr == "-" || isnothing(curr) || curr ∉ opt_values
            if isempty(new_options)
                menu_widget.i_selected[] = 1 
            else
                idx = nothing
                for f in fallbacks
                    idx = findfirst(isequal(f), opt_values)
                    !isnothing(idx) && break
                end
                menu_widget.i_selected[] = isnothing(idx) ? 1 : idx
            end
        else
            menu_widget.i_selected[] = findfirst(isequal(curr), opt_values)
        end
    end

    # 1. Sync Dropdown Options (Valid Axes & Components)
onany(plot_data_obs, ptype_obs, comp_tgt_obs) do plot_data_dict, ptype, comp_tgt
        @with_lock manager "Data" begin
            isempty(plot_data_dict) && return

            pd_first = first(values(plot_data_dict))
            
            n_params = length(pd_first.active_param_keys)
            if n_params > 0
                manager.plot_vars[1:n_params] .= pd_first.active_param_keys
            end
            dim_names = manager.plot_vars
            total_dims = length(dim_names)
            n_params = total_dims - 5

            valid_axes = String[]
            comp_max = 1
            
            for i in 1:n_params
                if length(pd_first.active_param_values[i]) > 1
                    push!(valid_axes, dim_names[i])
                end
            end
            
            # --- THE FIX: DYNAMIC DIMENSION FILTERING ---
            # Inspect the 'u' tensor to see which dimensions actually exist
            u_tensor = haskey(pd_first.data, "u") ? pd_first.data["u"] : first(values(pd_first.data))
            for i in (n_params+2):total_dims
                # Only allow x, y, z, t if they have a length > 1!
                if size(u_tensor, i) > 1
                    push!(valid_axes, dim_names[i])
                end
            end
            
            # Safe Fallback: If it's a literal 0D point simulation, just give it 'x'
            if isempty(valid_axes)
                push!(valid_axes, "x")
            end
            # --------------------------------------------
            
            for (key, tensor) in pd_first.data
                varying = findall(s -> s > 1, size(tensor))
                isempty(varying) && continue
                
                if !(key in dim_names)
                    param_varying = filter(d -> d <= n_params, varying)
                    phys_varying = filter(d -> d > n_params && d != n_params + 1, varying)
                    is_pure_series = (length(phys_varying) == 1 && phys_varying[1] == n_params + 5) && isempty(param_varying)
                    is_pure_param = isempty(phys_varying) && length(param_varying) == 1
                    if is_pure_series || is_pure_param; push!(valid_axes, key); end
                end
                if key == "u"; comp_max = max(comp_max, size(tensor, n_params + 1)); end
            end
            unique!(valid_axes)
            
            if comp_tgt == "Time"; filter!(k -> k != "t", valid_axes)
            elseif comp_tgt == "Component"; filter!(k -> k != "c", valid_axes)
            elseif comp_tgt in dim_names; filter!(k -> k != comp_tgt, valid_axes)
            end
            
            sort!(valid_axes)
            
            comp_names_tuple = manager.ui["Labels"]["comp_names"][]
            c_options = Any[]
            for i in 1:comp_max
                name = (comp_names_tuple isa Tuple && length(comp_names_tuple) >= i && comp_names_tuple[i] != "default" && !isempty(string(comp_names_tuple[i]))) ? string(comp_names_tuple[i]) : string(i)
                push!(c_options, (name, string(i)))
            end
            
            _update_menu!(w["X-Axis"], valid_axes; fallbacks=["x", "t", "y", "z"])
            _update_menu!(w["c"], c_options; fallbacks=["1"])
            
            p_dim = PLOT_DIM_MAP[ptype]
            if p_dim >= 2
                _update_menu!(w["Y-Axis"], valid_axes; fallbacks=["y", "t", "z", "x"])
            else
                w["Y-Axis"].options[] = ["disabled"]; w["Y-Axis"].i_selected[] = 1
            end
            if p_dim >= 3
                _update_menu!(w["Z-Axis"], valid_axes; fallbacks=["z", "t", "x", "y"])
            else
                w["Z-Axis"].options[] = ["disabled"]; w["Z-Axis"].i_selected[] = 1
            end
            anim_options = Any[("None", "None")]
            
            # 1. Add all valid varied parameters (Formatted nicely!)
            for i in 1:n_params
                if length(pd_first.active_param_values[i]) > 1
                    p_name = dim_names[i]
                    push!(anim_options, (nice_string(p_name), p_name))
                end
            end

            for i in (n_params+2):total_dims
                ax_name = dim_names[i]
                if ax_name in valid_axes
                    # Format these to perfectly match your Dimension Overwrite labels!
                    nice_ax = ax_name == "x" ? "Space(X)" :
                              ax_name == "y" ? "Space(Y)" :
                              ax_name == "z" ? "Space(Z)" :
                              ax_name == "t" ? "Time"     : nice_string(ax_name)
                    
                    push!(anim_options, (nice_ax, ax_name))
                end
            end
            
            _update_menu!(w["Anim_Target"], anim_options; fallbacks=["None"])
        end
    end

    # 2. Sync Active Axes State
    onany(x_sel, y_sel, z_sel, ptype_obs, plot_data_obs) do x_val, y_val, z_val, ptype, plot_data_dict
        isempty(plot_data_dict) && return

        dim_names = manager.plot_vars
        total_dims = length(dim_names)
        n_params = total_dims - 5
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
        _update_menu!(w["U-Axis"], valid_fields; fallbacks=["u", "v", "rho", "p"])
    end

    # 3. Sync Slider Ranges (The core data injection to the UI!)
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
        
        if manager.state["Config_Just_Loaded"][]
            opts = isempty(GLOBAL_SCENE_OPTIONS[]) ? get_base_scene_options() : GLOBAL_SCENE_OPTIONS[]
            apply_scene_options!(manager, opts)
            
            if !isempty(GLOBAL_UI_OVERWRITE[])
                for (scope, keys_dict) in GLOBAL_UI_OVERWRITE[]
                    if haskey(manager.ui, scope)
                        for (k, v) in keys_dict
                            if haskey(manager.ui[scope], k); manager.ui[scope][k][] = v; end
                        end
                    end
                end
                GLOBAL_UI_OVERWRITE[] = Dict{String, Any}()
            end
            
            manager.state["Config_Just_Loaded"].val = false
            manager.triggers["Primitive_Rebuild"][] += 1
            manager.triggers["UI_Update"][] += 1
        end
    end
end