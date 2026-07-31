# ==============================================================================
# --- WORKER FUNCTIONS FOR PURE LOGIC ---
# ==============================================================================
function _handle_layout_trigger!(rebuild_func::Function)
    curr_config = manager.active_config
    if !isnothing(curr_config) && curr_config.simulation_func != "none"
        update_plot_data_collection!(manager.plot_data[], curr_config, manager.methods[]; force_reload = false)
    end
    
    notify(manager.plot_data)

    if !isempty(manager.staged[:Layout])
        # 1. Reset to base layout if requested
        if get(manager.staged[:Layout], :reset, false)
            apply_layout_options!(get_base_layout_options())
        end
        # 2. Apply explicit overrides
        apply_layout_options!(manager.staged[:Layout])
        empty!(manager.staged[:Layout])
    end

    if !isempty(manager.staged[:Plot])
        # 1. Apply explicit overrides
        apply_plot_options!(manager.staged[:Plot])
        empty!(manager.staged[:Plot])
    end

    rebuild_func()
end

function _handle_data_fetch_trigger!()
    curr_config = manager.active_config
    if curr_config.simulation_func != "none" && !isnothing(curr_config.simulation_func)
        update_plot_data_collection!(manager.plot_data[], curr_config, manager.methods[]; force_reload = false)
    end
    notify(manager.plot_data)
end

function _handle_plot_trigger!(
    ::Val{T}, plot_layout, axes, num_plots, compare_labels,
    x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs,
    _build_param_indices, _mutate_compare_vals
) where T
    (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == :none || u_sel[] == :none) && return false
    if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == :none) && return false; end
    if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == :none) && return false; end
    
    if !isempty(manager.staged[:Plot])
        apply_plot_options!(manager.staged[:Plot])
        empty!(manager.staged[:Plot])
    end
    data = manager.plot_data[]
    isempty(data) && return false

    target, _, _, _ = manager.staged[:Compare_State]
    is_compare = target != :none
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || is_surface(T)

    empty!(manager.caches)
    
    for ax in axes
        empty!(ax)
        if !is_3d_axis; ax.xscale[] = identity; ax.yscale[] = identity; end
    end
    
    if !isempty(manager.methods[])
        sel_vals = [to_value(obs) for obs in selector_obs]

        # THE FIX: Create pooling dictionaries for global max/min accumulation
        plot_x_slices = Dict{Int, Any}()
        plot_y_slices = Dict{Int, Any}()

        for i in 1:num_plots
            manager.caches[i] = Dict{Symbol, _cache_type(Val(manager.mode[]))}()
            
            mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
            target_c_int = (is_compare && target == :component) ? i : c_sel[]
            local_methods = is_compare && target == :methods ? [manager.methods[][i]] : manager.methods[]
            
            data_tuples, valid_methods = fetch_pipeline_tuples(Val(manager.mode[]), data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
            isempty(valid_methods) && continue
            
            sim_data = _get_first_valid(first(values(data)))
            active_title_indices = _get_active_title_indices(Val(manager.mode[]), x_sel, y_sel, z_sel, sim_data)
            
            ts = generate_dynamic_title(Tuple(active_title_indices), manager.plot_vars, mutated_sel_vals, sim_data)
            
            default_title = is_compare ? "$(compare_labels[i]) | $ts" : ts 
            
            x_str = frontend_key(x_sel[])
            y_str = frontend_key(y_sel[])
            z_str = frontend_key(z_sel[])
            u_str = frontend_key(u_sel[])

            initialize_base_plot!(plot_layout, axes[i], valid_methods, data_tuples, x_str, y_str, z_str, u_str, ts, Val(T), i)
            axes[i].title[] = manager.ui[:labels][:title] == "default" ? default_title : manager.ui[:labels][:title]
            
            if !is_3d_axis
                plot_x_slices[i] = data_tuples[1]
                plot_y_slices[i] = data_tuples[2]
            end
        end

        # THE FIX: Apply aggregated axis limits globally if linked!
        if !is_3d_axis
            link_mode = manager.widgets[:compare_link].selection[]
            is_linked = link_mode in (:fully_coupled, :axes_only)
            
            global_x_slices = Any[]
            global_y_slices = Any[]
            if is_linked
                for i in 1:num_plots
                    if haskey(plot_x_slices, i)
                        append!(global_x_slices, plot_x_slices[i])
                        append!(global_y_slices, plot_y_slices[i])
                    end
                end
            end
            
            for i in 1:num_plots
                !haskey(plot_x_slices, i) && continue
                
                use_x = is_linked ? global_x_slices : plot_x_slices[i]
                use_y = is_linked ? global_y_slices : plot_y_slices[i]
                
                # Check safe log scales instantly
                min_x = _safe_extrema(use_x)[1]
                min_y = _safe_extrema(use_y)[1]
                
                if axes[i].xscale[] == log10 && min_x <= 0; axes[i].xscale[] = identity; end
                if axes[i].yscale[] == log10 && min_y <= 0; axes[i].yscale[] = identity; end
                
                set_axis_limits_manager!(axes[i], use_x, use_y)
            end
        end
        _enforce_camera_lock!(axes)
    end
    return true
end

function _handle_slider_trigger!(u_sel)
    data = manager.plot_data[]
    isempty(data) && return false
    
    w = manager.widgets
    active_axes = manager.state[:Active_Axes][]
    u_val = u_sel[]
    anim_val = w[:anim_target].selection[]

    target, target_idx, _, _ = manager.staged[:Compare_State]
    pd_first, sim_data = _get_active_sim_data(data)
    isnothing(sim_data) && return

    dim_names = manager.plot_vars
    total_dims = length(dim_names)
    n_params = total_dims - length(get_base_variables())
    
    target_field = (isnothing(u_val) || u_val == :none) ? :Solution : u_val
    base_stat = occursin("|", string(target_field)) ? Symbol(split(string(target_field), "|")[1]) : target_field
    kept_syms = base_stat == :Solution ? Tuple(sim_data.domain.dim_keys) : Tuple(IRunPDESims.get_kept_dims(base_stat, sim_data.domain))

    manager.locks[:PlotData] = true
    try
        for i in 1:total_dims
            dim_sym = dim_names[i]
            dim_str = String(dim_sym)
            
            is_axis = i in active_axes
            is_compare = (target_idx == i) 
            is_anim = dim_sym == anim_val
            
            is_spatial = false
            is_physically_disabled = false
            
            if i > n_params
                is_spatial, is_physically_disabled = _is_spatial_dim(Val(manager.mode[]), dim_sym, sim_data, kept_syms)
            end
            
            widget_key = i > n_params ? Symbol(dim_str) : get(manager.maps[:Reverse], dim_sym, Symbol("param_$i"))
            haskey(w, widget_key) || continue
            ctrl = w[widget_key]
            
            slider_cache = manager.staged[:Slider]
            if length(ctrl.range[]) > 1
                slider_cache[widget_key] = Float64(ctrl.value[])
            end
            
            if is_axis || is_spatial || is_physically_disabled || is_compare || is_anim
                if ctrl.range[] != [0.0]
                    ctrl.range[] = [0.0] 
                end
                continue
            end
            
            g_min, g_max = Inf, -Inf
            for pd in values(data)
                vals = nothing
                if i <= n_params 
                    vals = pd.active_param_values[i]
                else
                    s_data = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))
                    isnothing(s_data) && continue
                    vals = _get_dim_vals(Val(manager.mode[]), s_data, dim_sym)
                end
            
                if !isnothing(vals) && !isempty(vals)
                    l, h = extrema(vals)
                    g_min = min(l, g_min)  
                    g_max = max(h, g_max)
                end
            end
            
            if isinf(g_min); g_min = 0.0; g_max = 1.0; end
            old_val = get(slider_cache, widget_key, Float64(ctrl.value[]))
            
            new_range = [0.0]
            if i <= n_params
                all_vals = Any[]
                for pd in values(data)
                    append!(all_vals, pd.active_param_values[i])
                end
                new_range = isempty(all_vals) ? [0.0] : sort(unique(identity.(all_vals)))
            else
                new_range = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
            end
            
            if ctrl.range[] != new_range
                ctrl.range[] = new_range
                set_close_to!(ctrl, old_val)
            end
        end
    finally
        manager.locks[:PlotData] = false
    end
    return true
end

function _handle_data_trigger!(
    ::Val{T}, axes, num_plots, compare_labels,
    x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs,
    _build_param_indices, _mutate_compare_vals
) where T
    (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == :none || u_sel[] == :none) && return false
    if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == :none) && return false; end
    if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == :none) && return false; end
    
    caches = manager.caches
    data = manager.plot_data[]

    (isempty(data) || isempty(caches) || isempty(manager.methods[])) && return false

    target, _, _, _ = manager.staged[:Compare_State]
    is_compare = target != :none
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || is_surface(T)
    
    sel_vals = [to_value(obs) for obs in selector_obs]
    sim_data = _get_first_valid(first(values(data)))
    
    # THE FIX: Create pooling dictionaries for data triggers as well
    plot_x_slices = Dict{Int, Any}()
    plot_y_slices = Dict{Int, Any}()
    
    for i in 1:num_plots
        mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
        target_c_int = (is_compare && target == :component) ? i : c_sel[]
        local_methods = is_compare && target == :methods ? [manager.methods[][i]] : manager.methods[]
        
        data_tuples, valid_methods = fetch_pipeline_tuples(Val(manager.mode[]), data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
        isempty(valid_methods) && continue
        
        if !is_3d_axis
            plot_x_slices[i] = data_tuples[1]
            plot_y_slices[i] = data_tuples[2]
        end
        
        sync_data_to_cache!(caches[i], valid_methods, data_tuples, Val(PLOT_DIM_MAP[T]))
        
        active_title_indices = _get_active_title_indices(Val(manager.mode[]), x_sel, y_sel, z_sel, sim_data)
        
        ts = generate_dynamic_title(Tuple(active_title_indices), manager.plot_vars, mutated_sel_vals, sim_data)
        
        default_title = is_compare ? compare_labels[i] : ts
        axes[i].title[] = manager.ui[:labels][:title] == "default" ? default_title : manager.ui[:labels][:title]
    end
    
    # THE FIX: Accumulate global axes max limits and set globally
    if !is_3d_axis
        link_mode = manager.widgets[:compare_link].selection[]
        is_linked = link_mode in (:fully_coupled, :axes_only)
        
        global_x_slices = Any[]
        global_y_slices = Any[]
        if is_linked
            for i in 1:num_plots
                if haskey(plot_x_slices, i)
                    append!(global_x_slices, plot_x_slices[i])
                    append!(global_y_slices, plot_y_slices[i])
                end
            end
        end
        
        for i in 1:num_plots
            !haskey(plot_x_slices, i) && continue
            
            use_x = is_linked ? global_x_slices : plot_x_slices[i]
            use_y = is_linked ? global_y_slices : plot_y_slices[i]
            
            min_x = _safe_extrema(use_x)[1]
            min_y = _safe_extrema(use_y)[1]
            
            if axes[i].xscale[] == log10 && min_x <= 0; axes[i].xscale[] = identity; end
            if axes[i].yscale[] == log10 && min_y <= 0; axes[i].yscale[] = identity; end
            
            set_axis_limits_manager!(axes[i], use_x, use_y)
        end
    end
    
    for ax in axes; apply_axis_limits_overrides!(ax); end
    _enforce_camera_lock!(axes)
    return true
end

function _handle_ui_trigger!(::Val{T}, master_fig, plot_layout, axes, has_colorbar, u_sel) where T

    if !isempty(manager.staged[:UI])
        # Force a UI rebuild if the reset flag is present
        if get(manager.staged[:UI], :reset, false)
            switch_ui_plot_type!(T)
        end
        
        for (scope, dict) in manager.staged[:UI]
            scope === :reset && continue # Skip applying the flag itself
            if haskey(manager.ui, scope)
                for (k, v) in dict
                    manager.ui[scope][k] = v
                end
            end
        end
        empty!(manager.staged[:UI])
    end

    if !isempty(manager.staged[:Camera])
        manager.state[:Camera_Locked][] = true
        if haskey(manager.widgets, :Lock_Camera_Button)
            btn = manager.widgets[:Lock_Camera_Button]
            btn.label[] = "Unlock Camera"
            btn.buttoncolor[] = :lightgreen
        end
    else
        if get(manager.staged, :Camera_Locked, Observable(false))[]
            manager.state[:Camera_Locked][] = false
            if haskey(manager.widgets, :Lock_Camera_Button)
                btn = manager.widgets[:Lock_Camera_Button]
                btn.label[] = "Lock Camera"
                btn.buttoncolor[] = :lightgray
            end
        end
    end

    ui_app = manager.ui[:plot_style]
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || is_surface(T)
    
    for (i, ax) in enumerate(axes)
        _apply_axis_styles!(ax, T)
        apply_axis_limits_overrides!(ax)
        
        if !is_3d_axis && haskey(ui_app, :reference)
            delete_plots_by_label!(ax, "Reference Lines")
            ref_exp = ui_app[:reference]
            !isempty(ref_exp) && plot_reference_lines!(ax, ref_exp; label="Reference Lines")
        end
        
        if haskey(manager.caches, i)
            for (method_name, cache) in manager.caches[i]
                m_idx = findfirst(isequal(method_name), manager.methods[])
                isnothing(m_idx) && continue 
                
                colors = get(ui_app, :colors, nothing)
                c = !isnothing(colors) ? colors[mod1(m_idx, length(colors))] : :black
                
                for (key, prim) in cache.primitives
                    apply_ui_style!(key, prim, ui_app, c)
                end
            end
            
            if has_colorbar
                plot_obj = _find_first_drawable_primitive(manager.caches[i])
                if !isnothing(plot_obj)
                    cr_obs = haskey(plot_obj.attributes, :colorrange) ? plot_obj.colorrange : Observable((0.0, 1.0))
                    create_or_update_colorbar!(plot_layout, plot_obj, cr_obs, string(u_sel[]), i)
                end
            end
        end
    end
    
    if !is_3d_axis && T in LEGEND_SUPPORTED_PLOTS
        create_or_update_legend!(plot_layout, _collect_legend_elements(ui_app)...)
    end
    
    resize_to_layout!(master_fig)
    _enforce_camera_lock!(axes)
end

# ==============================================================================
# --- RENDER PIPELINE HELPERS ---
# ==============================================================================

function _mutate_compare_vals(current_sels, idx)
    t_val, t_idx, c_labels, c_vals = manager.staged[:Compare_State]
    mutated = collect(current_sels)
    if !isnothing(t_idx) && !isempty(c_vals) && idx <= length(c_vals)
        mutated[t_idx] = c_vals[idx]
    end
    return mutated
end

function _build_param_indices(pd, mutated_vals)
    n_params = length(pd.active_param_keys)
    return ntuple(d -> begin
        val = mutated_vals[d]
        vals = pd.active_param_values[d]
        isempty(vals) ? 1 : findmin(v -> abs(v - val), vals)[2]
    end, n_params)
end

function _initialize_render_layout!(plot_layout::GridLayout, ::Val{T}) where T
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || is_surface(T)
    w = manager.widgets
    rev_map = get(manager.maps, :Reverse, Dict{Symbol, Symbol}())
    
    selector_obs = map(manager.plot_vars) do n
        w_key = haskey(rev_map, n) ? rev_map[n] : n
        w[w_key].value
    end

    x_sel, y_sel = w[:x_axis].selection, w[:y_axis].selection
    z_sel, u_sel = w[:z_axis].selection, w[:u_axis].selection
    c_sel = w[:component].selection
    
    target = w[:compare_target].selection[]
    cols = w[:compare_columns].selection[]
    link_mode = w[:compare_link].selection[]
    
    num_plots, compare_labels, compare_vals = 1, String[], Any[]

    sim_data = nothing
    if !isempty(manager.plot_data[])
        pd_first = first(values(manager.plot_data[]))
        sim_data = _get_first_valid(pd_first)
        
        if !isnothing(sim_data)
            if target == :methods
                compare_labels = String[frontend_key(m) for m in manager.methods[]]
                num_plots = length(compare_labels)
            elseif target == :component
                target_tensor = get(sim_data.stats, u_sel[], sim_data.stats[:Solution])
                num_plots = _get_component_num_plots(Val(manager.mode[]), target_tensor)
                
                compare_labels = String[]
                for i in 1:num_plots
                    sym = Symbol("component_$i")
                    push!(compare_labels, frontend_key(sym))
                end
                compare_vals = collect(1:num_plots)
            elseif target == :Time
                t_dim = findfirst(==(sim_data.domain.time_dim), sim_data.domain.dim_keys) 
                t_vals = _get_time_vals(Val(manager.mode[]), sim_data, t_dim)
                
                num_plots = length(t_vals)
                compare_labels = ["t = $(round(t, sigdigits=4))" for t in t_vals]
                compare_vals = t_vals
            elseif target in manager.plot_vars
                idx = findfirst(isequal(target), manager.plot_vars)
                vals = pd_first.active_param_values[idx]
                num_plots = length(vals)
                compare_labels = ["$(string(target)) = $(v isa Int ? v : round(v, sigdigits=4))" for v in vals]
                compare_vals = vals
            end
        end
    end
    
    if target == :none || num_plots == 0; num_plots = 1; target = :none; end
    is_det, halign, valign = _parse_legend_position()
    
    has_legend = T in LEGEND_SUPPORTED_PLOTS && target != :methods
    has_colorbar = T in COLORBAR_SUPPORTED_PLOTS

    layout_dict = calculate_layout_dictionary(num_plots, cols, link_mode, has_legend, is_det, halign, valign, has_colorbar)
    manager.state[:Layout_Dict][] = layout_dict
    
    axes = []
    for i in 1:num_plots
        r, c_idx = layout_dict[:Plots][i]
        ax = is_3d_axis ? Axis3(plot_layout[r, c_idx], perspectiveness=0.5) : Axis(plot_layout[r, c_idx])
        push!(axes, ax)
    end
    
    p_w = w[:plot_width].selection[]
    p_h = w[:plot_height].selection[]
    for i in 1:plot_layout.size[1]; rowsize!(plot_layout, i, Auto()); end
    for i in 1:plot_layout.size[2]; colsize!(plot_layout, i, Auto()); end
    
    for i in 1:num_plots
        r, c_idx = layout_dict[:Plots][i]
        rowsize!(plot_layout, r, Fixed(p_h))
        colsize!(plot_layout, c_idx, Fixed(p_w))
    end
    
    if !is_3d_axis && link_mode in (:fully_coupled, :axes_only)
        linkaxes!(axes...)
    end
    
    target_idx = target == :Time ? (isnothing(sim_data) ? nothing : findfirst(isequal(sim_data.domain.time_dim), manager.plot_vars)) : findfirst(isequal(target), manager.plot_vars)

    manager.staged[:Compare_State] = (target, target_idx, compare_labels, compare_vals)

    return axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, has_colorbar
end
