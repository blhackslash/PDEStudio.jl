# ==============================================================================
# --- WORKER FUNCTIONS FOR PURE LOGIC ---
# ==============================================================================
"""
    _handle_layout_trigger!(rebuild_func::Function)

Safely resolves layout-altering UI interactions (like adding subplots for comparisons or changing the base plot geometry). 

If a valid `SimulationConfig` is active, it triggers a background data cache refresh via `update_plot_data_collection!` before invoking the provided `rebuild_func` (which destroys the old Makie layout and rebuilds the grid and primitives).
"""
function _handle_layout_trigger!(rebuild_func::Function)
    curr_config = manager.active_config

    if !isnothing(curr_config) && curr_config.simulation_func !== dummy_simulation_function
        update_plot_data_collection!(manager.plot_data[], curr_config, manager.methods[]; force_reload = false)
    end
    
    notify(manager.plot_data)

    rebuild_func()
end

"""
    _handle_data_fetch_trigger!()

Re-evaluates the active `SimulationConfig` and updates the `PlotManager`'s internal memory cache. 

Triggered when the underlying simulation parameters change fundamentally (e.g., a new method is activated or a sweep is requested). It notifies the `manager.plot_data` observable to alert downstream render listeners to fetch the new memory references.
"""
function _handle_data_fetch_trigger!()
    curr_config = manager.active_config
    if curr_config.simulation_func != "none" && !isnothing(curr_config.simulation_func)
        update_plot_data_collection!(manager.plot_data[], curr_config, manager.methods[]; force_reload = false)
    end
    notify(manager.plot_data)
end

"""
    _handle_plot_trigger!(...)

The core rendering engine payload. It is triggered when new visual primitives must be drawn (e.g., switching from 2D Heatmaps to 3D Surfaces).

# Data Flow:
1. Validates that the active axis selectors (X, Y, Z, U) provide enough dimensionality for the requested plot type `T`.
2. Resolves multi-plot grid targets (e.g., comparing methods side-by-side) and allocates fresh `AbstractPlotCache` objects.
3. Invokes the data extraction pipeline (`fetch_pipeline_tuples`) to flatten the N-dimensional data into primitives based on the slider positions.
4. Generates dynamic titles, applies axis limit linking, and mounts the objects onto the Makie `GridLayout`.
"""
function _handle_plot_trigger!(
    ::Val{T}, plot_layout, axes, num_plots, compare_labels,
    x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs,
    _build_param_indices, _mutate_compare_vals
) where T
    (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == :none || u_sel[] == :none) && return false
    if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == :none) && return false; end
    if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == :none) && return false; end

    data = manager.plot_data[]
    isempty(data) && return false

    target, _, _, _ = manager.state[:Compare_State]
    is_compare = target != :none
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || is_surface(T)

    empty!(manager.caches)
    
    for ax in axes
        empty!(ax)
        if !is_3d_axis; ax.xscale[] = identity; ax.yscale[] = identity; end
    end
    
    if !isempty(manager.methods[])
        sel_vals = [to_value(obs) for obs in selector_obs]

        plot_x_slices = Dict{Int, Any}()
        plot_y_slices = Dict{Int, Any}()

        manager.state[:Plot_Titles] = fill("", num_plots)

        for i in 1:num_plots
            manager.caches[i] = Dict{Symbol, _cache_type(Val(manager.mode[]))}()
            
            mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
            target_c_int = (is_compare && target == :component) ? i : c_sel[]
            local_methods = is_compare && target == :methods ? [manager.methods[][i]] : manager.methods[]
            
            data_tuples, valid_methods = fetch_pipeline_tuples(Val(manager.mode[]), data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
            isempty(valid_methods) && continue
            
            data_tuples = apply_outlier_mask(axes[i], data_tuples, valid_methods, is_3d_axis)
            plot_extrema_lines_manager!(axes[i], data_tuples, valid_methods, is_3d_axis)

            sim_data = _get_first_valid(first(values(data)))
            active_title_indices = _get_active_title_indices(Val(manager.mode[]), x_sel, y_sel, z_sel, sim_data)
            
            ts = generate_dynamic_title(Tuple(active_title_indices), manager.plot_vars, mutated_sel_vals, sim_data)
            
            manager.state[:Plot_Titles][i] = ts
            
            default_title = is_compare ? "$(compare_labels[i])" : ts
            
            x_str = frontend_key(x_sel[])
            y_str = frontend_key(y_sel[])
            z_str = frontend_key(z_sel[])
            u_str = frontend_key(u_sel[])

            initialize_base_plot!(plot_layout, axes[i], valid_methods, data_tuples, x_str, y_str, z_str, u_str, ts, Val(T), i)
            axes[i].title[] = manager.ui[:labels][:title] == "default" ? default_title : manager.ui[:labels][:title]
            
            if !is_3d_axis
                if manager.mode[] == :lagrangian
                    pts_slices = data_tuples[1]
                    if !isempty(pts_slices) && eltype(pts_slices[1]) <: Point2f
                        plot_x_slices[i] = [[p[1] for p in s] for s in pts_slices]
                        plot_y_slices[i] = [[p[2] for p in s] for s in pts_slices]
                    else
                        plot_x_slices[i] = pts_slices
                        plot_y_slices[i] = data_tuples[end]
                    end
                else
                    plot_x_slices[i] = data_tuples[1]
                    plot_y_slices[i] = data_tuples[2]
                end
            end
        end

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

"""
    _handle_slider_trigger!(u_sel)

Analyzes the active N-dimensional data space and dynamically recalculates the `min`/`max` ranges of all UI sliders.

It guarantees that as users change fields (e.g., switching from Density to Momentum), the slider widgets instantly scale to the global bounds of the newly targeted field across all active simulation methods. It locks the `:PlotData` cascade while remapping to prevent accidental race conditions during evaluation.
"""
function _handle_slider_trigger!(u_sel)
    data = manager.plot_data[]
    isempty(data) && return false
    
    w = manager.widgets
    active_axes = manager.state[:Active_Axes][]
    u_val = u_sel[]
    anim_val = w[:anim_target].selection[]

    target, target_idx, _, _ = manager.state[:Compare_State]
    pd_first, sim_data = _get_active_sim_data(data)
    isnothing(sim_data) && return

    dim_names = manager.plot_vars
    total_dims = length(dim_names)
    n_params = total_dims - length(get_base_variables())
    
    target_field = (isnothing(u_val) || u_val == :none) ? :Solution : u_val
    base_stat = occursin("|", string(target_field)) ? Symbol(split(string(target_field), "|")[1]) : target_field
    kept_syms = base_stat == :Solution ? Tuple(sim_data.domain.dim_keys) : Tuple(PDEStudioCore.get_kept_dims(base_stat, sim_data.domain))

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
            
            slider_cache = manager.state[:Slider_Cache]
            if length(ctrl.range[]) > 1
                slider_cache[widget_key] = Float64(ctrl.value[])
            end
            
            if is_axis || is_spatial || is_physically_disabled || is_compare
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
                    s_data = _get_first_valid(pd)
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

"""
    _handle_data_trigger!(...)

A highly optimized update path used when the layout geometry and primitive types remain identical, but the internal numeric data needs to change (e.g., dragging a time slider or swapping parameter limits).

Instead of destroying and rebuilding the Makie `Axis`, this function extracts the new slice data via `fetch_pipeline_tuples` and directly mutates the active `Observable` buffers inside the `PlotManager` cache, achieving instant, tear-free rendering.
"""
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

    target, _, _, _ = manager.state[:Compare_State]
    is_compare = target != :none
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || is_surface(T)
    
    sel_vals = [to_value(obs) for obs in selector_obs]
    sim_data = _get_first_valid(first(values(data)))
    
    # Create pooling dictionaries for data triggers
    plot_x_slices = Dict{Int, Any}()
    plot_y_slices = Dict{Int, Any}()

    manager.state[:Plot_Titles] = fill("", num_plots)

    for i in 1:num_plots
        mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
        target_c_int = (is_compare && target == :component) ? i : c_sel[]
        local_methods = is_compare && target == :methods ? [manager.methods[][i]] : manager.methods[]
        
        data_tuples, valid_methods = fetch_pipeline_tuples(Val(manager.mode[]), data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
        isempty(valid_methods) && continue
        
        data_tuples = apply_outlier_mask(axes[i], data_tuples, valid_methods, is_3d_axis)
        plot_extrema_lines_manager!(axes[i], data_tuples, valid_methods, is_3d_axis)

        if !is_3d_axis
            if manager.mode[] == :lagrangian
                pts_slices = data_tuples[1]
                if !isempty(pts_slices) && eltype(pts_slices[1]) <: Point2f
                    plot_x_slices[i] = [[p[1] for p in s] for s in pts_slices]
                    plot_y_slices[i] = [[p[2] for p in s] for s in pts_slices]
                else
                    plot_x_slices[i] = pts_slices
                    plot_y_slices[i] = data_tuples[end]
                end
            else
                plot_x_slices[i] = data_tuples[1]
                plot_y_slices[i] = data_tuples[2]
            end
        end
        
        sync_data_to_cache!(caches[i], valid_methods, data_tuples, Val(PLOT_DIM_MAP[T]))
        
        active_title_indices = _get_active_title_indices(Val(manager.mode[]), x_sel, y_sel, z_sel, sim_data)
        
        ts = generate_dynamic_title(Tuple(active_title_indices), manager.plot_vars, mutated_sel_vals, sim_data)
        
        manager.state[:Plot_Titles][i] = ts
            
        default_title = is_compare ? "$(compare_labels[i])" : ts

        axes[i].title[] = manager.ui[:labels][:title] == "default" ? default_title : manager.ui[:labels][:title]
    end
    
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

"""
    _handle_ui_trigger!(::Val{T}, master_fig, plot_layout, axes, has_colorbar, u_sel) where T

The final step in the render pipeline cascade. 

Applies superficial aesthetic overrides (e.g., colormaps, line widths, marker styles, legend positioning) without recalculating or extracting underlying numeric data. It computes global/local color ranges for linked plots and finally resizes the `Figure` to fit the newly generated layout constraints.
"""
function _handle_ui_trigger!(::Val{T}, master_fig, plot_layout, axes, has_colorbar, u_sel) where T

    ui_app = manager.ui[:plot_style]
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || is_surface(T)

    target, _, old_compare_labels, _ = manager.state[:Compare_State]
    is_compare = target != :none
    
    dyn_compare_labels = copy(old_compare_labels)
    if target == :methods
        dyn_compare_labels = String[frontend_key(m) for m in manager.methods[]]
    elseif target == :component
        dyn_compare_labels = String[frontend_key(Symbol("component_$j")) for j in 1:length(axes)]
    end

    # Calculate Global Colorrange for Linked Colorbars
    link_mode = manager.widgets[:compare_link].selection[]
    is_linked_cb = link_mode in (:fully_coupled, :colorbar_only)
    
    global_u = Float64[]
    if is_linked_cb
        for i in 1:length(axes)
            haskey(manager.caches, i) || continue
            for cache in values(manager.caches[i])
                append!(global_u, filter(isfinite, vec(cache.obs_u[])))
            end
        end
    end
    global_cr_obs = get_colorrange(ui_app, global_u)

    for (i, ax) in enumerate(axes)
        if haskey(manager.state, :Plot_Titles) && i <= length(manager.state[:Plot_Titles])
            ts = manager.state[:Plot_Titles][i]
            default_title = is_compare && !isempty(dyn_compare_labels) && i <= length(dyn_compare_labels) ? "$(dyn_compare_labels[i])" : ts
            ax.title[] = manager.ui[:labels][:title] == "default" ? default_title : manager.ui[:labels][:title]
        end
        
        _apply_axis_styles!(ax, T)
        apply_axis_limits_overrides!(ax)
        
        if !is_3d_axis && haskey(ui_app, :reference)
            delete_plots_by_label!(ax, "Reference Lines")
            ref_exp = ui_app[:reference]
            !isempty(ref_exp) && plot_reference_lines!(ax, ref_exp; label="Reference Lines")
        end
        
        if haskey(manager.caches, i)
            # Calculate Local Colorrange
            local_u = Float64[]
            for cache in values(manager.caches[i])
                append!(local_u, filter(isfinite, vec(cache.obs_u[])))
            end
            local_cr_obs = get_colorrange(ui_app, local_u)
            
            cr_obs = is_linked_cb ? global_cr_obs : local_cr_obs

            for (method_name, cache) in manager.caches[i]
                m_idx = findfirst(isequal(method_name), manager.methods[])
                isnothing(m_idx) && continue 
                
                colors = get(ui_app, :colors, nothing)
                c = !isnothing(colors) ? colors[mod1(m_idx, length(colors))] : :black
                
                for (key, prim) in cache.primitives
                    # Pass the computed cr_obs
                    apply_ui_style!(key, prim, ui_app, c, cr_obs)
                end
            end
            
            if has_colorbar
                plot_obj = _find_first_drawable_primitive(manager.caches[i])
                if !isnothing(plot_obj)
                    # Push the mathematically perfect cr_obs to the colorbar
                    create_or_update_colorbar!(plot_layout, plot_obj, cr_obs, string(u_sel[]), i)
                end
            end
        end
    end
    
    if !is_3d_axis && T in LEGEND_SUPPORTED_PLOTS
        create_or_update_legend!(plot_layout, _collect_legend_elements(ui_app)...)
    end
    
    # Block dynamic resizing if backend is recording
    if !get(manager.state, :Is_Exporting, false)
        resize_to_layout!(master_fig)
    end
    
    _enforce_camera_lock!(axes)
end

# ==============================================================================
# --- RENDER PIPELINE HELPERS ---
# ==============================================================================

"""
    _mutate_compare_vals(current_sels, idx)

Helper function for multi-column comparison grids. Intercepts the global slider positions and substitutes the specific value required by the current subplot `idx` (e.g., assigning a specific time step to column 2).
"""
function _mutate_compare_vals(current_sels, idx)
    t_val, t_idx, c_labels, c_vals = manager.state[:Compare_State]
    mutated = collect(current_sels)
    if !isnothing(t_idx) && !isempty(c_vals) && idx <= length(c_vals)
        mutated[t_idx] = c_vals[idx]
    end
    return mutated
end

"""
    _build_param_indices(pd, mutated_vals)

Transforms continuous floating-point UI slider values into strict integer array indices to query the active `PlotSweepData` tensor using nearest-neighbor bounds checking.
"""
function _build_param_indices(pd, mutated_vals)
    n_params = length(pd.active_param_keys)
    return ntuple(d -> begin
        val = mutated_vals[d]
        vals = pd.active_param_values[d]
        isempty(vals) ? 1 : findmin(v -> abs(v - val), vals)[2]
    end, n_params)
end

"""
    _initialize_render_layout!(plot_layout::GridLayout, ::Val{T}) where T

Analyzes the active `PlotManager` states to determine the exact grid dimensions, spanning constraints, and component requirements (e.g., Colorbars, Legends) before any plot primitives are instantiated. 

Returns a structured dictionary allocating specific Makie objects to concrete row/col coordinates.
"""
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

    manager.state[:Compare_State] = (target, target_idx, compare_labels, compare_vals)

    return axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, has_colorbar
end
