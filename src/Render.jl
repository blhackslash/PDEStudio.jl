# -----------------------------------------------------------------------------
# 1D PRIMITIVES: MODULAR COMPONENTS
# -----------------------------------------------------------------------------
function draw_lines!(ax, cache, m_idx, ui_app)
    c  = ui_app["colors"][][mod1(m_idx, end)]
    ls = ui_app["dashed_lines"][] ? ui_app["line_styles"][][mod1(m_idx, end)] : nothing
    lw = ui_app["line_width"][]
    
    l = lines!(ax, cache.obs_x, cache.obs_u; color=c, linewidth=lw, linestyle=ls)
    cache.primitives[:lines] = l
    
    return Makie.LineElement(color=c, linewidth=lw, linestyle=ls)
end

function draw_scatter!(ax, cache, m_idx, ui_app)
    c   = ui_app["colors"][][mod1(m_idx, end)]
    mrk = ui_app["markers"][][mod1(m_idx, end)]
    ms  = ui_app["marker_size"][]
    
    s = scatter!(ax, cache.obs_x, cache.obs_u; color=c, markersize=ms, marker=mrk)
    cache.primitives[:scatter] = s
    
    return Makie.MarkerElement(color=c, marker=mrk, markersize=ms)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:lines}, plot_idx::Int)
    xs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = PlotCache()
        cache.obs_x[] = xs_slices[m_idx]
        cache.obs_u[] = us_slices[m_idx]
        
        group = []
        if ui_app["show_lines"][]
            push!(group, draw_lines!(ax, cache, m_idx, ui_app))
        end
        if ui_app["show_scatter"][]
            push!(group, draw_scatter!(ax, cache, m_idx, ui_app))
        end
        
        cache_dict[label] = cache
        if !isempty(group)
            push!(plotted_objects, group)
            push!(labels_for_legend, label)
        end
    end
end


# -----------------------------------------------------------------------------
# 2D PRIMITIVES
# -----------------------------------------------------------------------------
function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:heatmap}, plot_idx::Int)
    xs, ys, us = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    label = active_methods[1] 
    cache = PlotCache()
    cache.obs_x[] = xs[1]
    cache.obs_y[] = ys[1]
    cache.obs_u[] = us[1]

    valid_u = filter(isfinite, us[1])
    cr_obs = get_colorrange(ui_app, valid_u)
    rast_val = ui_app["rasterize"][] == 0 ? false : ui_app["rasterize"][]

    hm = heatmap!(ax, cache.obs_x, cache.obs_y, cache.obs_u; colormap=ui_app["color_map"][], colorrange=cr_obs, rasterize=rast_val)

    cache.primitives[:heatmap] = hm
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, hm, manager, cr_obs, label, plot_idx)
end

# --- THE FIX: Solid Color Contour (Multi-Method Overlay) ---
function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:contour}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = PlotCache()
        cache.obs_x[] = xs_slices[m_idx]
        cache.obs_y[] = ys_slices[m_idx]
        cache.obs_u[] = us_slices[m_idx]

        color = ui_app["colors"][][mod1(m_idx, end)]
        lw    = ui_app["line_width"][]
        
        ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; levels=ui_app["levels"][], color=color, linewidth=lw, labels=ui_app["labels"][])
        
        cache.primitives[:contour] = ct
        cache_dict[label] = cache

        push!(plotted_objects, [Makie.LineElement(color=color, linewidth=lw)])
        push!(labels_for_legend, label)
    end
end

# --- THE FIX: Colormapped Contour (Single Base Method) ---
function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:contour_cmap}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    # Select base method
    raw_idx = get(ui_app, "base_method_idx", Ref(1))[]
    base_idx = clamp(raw_idx, 1, length(active_methods))
    base_label = active_methods[base_idx]

    cache = PlotCache()
    cache.obs_x[] = xs_slices[base_idx]
    cache.obs_y[] = ys_slices[base_idx]
    cache.obs_u[] = us_slices[base_idx]
    
    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)

    ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; 
        colormap=ui_app["color_map"][], colorrange=cr_obs, 
        levels=ui_app["levels"][], linewidth=ui_app["line_width"][], labels=ui_app["labels"][]
    )
    
    cache.primitives[:contour_cmap] = ct
    cache_dict[base_label] = cache

    create_or_update_colorbar!(plot_layout, ct, manager, cr_obs, base_label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:contourf}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    raw_idx = get(ui_app, "base_method_idx", Ref(1))[]
    base_idx = clamp(raw_idx, 1, length(active_methods))
    
    valid_u = filter(isfinite, us_slices[base_idx])
    cr_obs = get_colorrange(ui_app, valid_u)
    lvl_range = range(cr_obs[][1], cr_obs[][2], length=ui_app["levels"][])
    rast_val = ui_app["rasterize"][] == 0 ? false : ui_app["rasterize"][]

    plotted_objects, labels_for_legend = [], String[]
    
    base_label = active_methods[base_idx]
    base_cache = PlotCache()
    base_cache.obs_x[] = xs_slices[base_idx]; base_cache.obs_y[] = ys_slices[base_idx]; base_cache.obs_u[] = us_slices[base_idx]

    cf = contourf!(ax, base_cache.obs_x, base_cache.obs_y, base_cache.obs_u; colormap=ui_app["color_map"][], levels=lvl_range, rasterize=rast_val)
    base_cache.primitives[:contourf] = cf
    cache_dict[base_label] = base_cache

    base_color = Makie.to_colormap(ui_app["color_map"][])[end]
    push!(plotted_objects, [Makie.PolyElement(color=base_color)]); push!(labels_for_legend, "$base_label (Base)")

    for (i, label) in enumerate(active_methods)
        if i == base_idx; continue; end
        cache = PlotCache()
        cache.obs_x[] = xs_slices[i]; cache.obs_y[] = ys_slices[i]; cache.obs_u[] = us_slices[i]
        
        color = ui_app["colors"][][mod1(i, end)]
        lw = ui_app["line_width"][]
        
        ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; color=color, linewidth=lw, labels=true)
        cache.primitives[:contour] = ct
        cache_dict[label] = cache
        
        push!(plotted_objects, [Makie.LineElement(color=color, linewidth=lw)]); push!(labels_for_legend, label)
    end

    create_or_update_colorbar!(plot_layout, cf, manager, cr_obs, base_label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:surface}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples 
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    label = active_methods[1]
    cache = PlotCache()
    cache.obs_x[] = xs_slices[1]; cache.obs_y[] = ys_slices[1]; cache.obs_u[] = us_slices[1]
    
    valid_u = filter(isfinite, us_slices[1])
    cr_obs = get_colorrange(ui_app, valid_u)
    rast_val = ui_app["rasterize"][] == 0 ? false : ui_app["rasterize"][]

    sf = surface!(ax, cache.obs_x, cache.obs_y, cache.obs_u; colormap=ui_app["color_map"][], colorrange=cr_obs, rasterize=rast_val)
    cache.primitives[:surface] = sf
    cache_dict[label] = cache
end


# -----------------------------------------------------------------------------
# 3D PRIMITIVES
# -----------------------------------------------------------------------------
function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:volume}, plot_idx::Int)
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]
    
    x_data, y_data, z_data, u_data = xs_slices[1], ys_slices[1], zs_slices[1], us_slices[1]

    cache = PlotCache()
    cache.obs_x[] = extrema(x_data)
    cache.obs_y[] = extrema(y_data)
    cache.obs_z[] = extrema(z_data)
    cache.obs_u[] = u_data
    
    valid_u = filter(isfinite, u_data)
    cr_obs = get_colorrange(ui_app, valid_u)

    vol = volume!(ax, cache.obs_x, cache.obs_y, cache.obs_z, cache.obs_u; colormap=ui_app["color_map"][], colorrange=cr_obs)
    
    cache.primitives[:volume] = vol
    cache_dict[active_methods[1]] = cache
    
    create_or_update_colorbar!(plot_layout, vol, manager, cr_obs, active_methods[1], plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter2d}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    label = active_methods[1]
    cache = PlotCache()
    
    x_data, y_data, u_data = xs_slices[1], ys_slices[1], us_slices[1]
    cache.obs_x[] = vec([x for x in x_data, y in y_data])
    cache.obs_y[] = vec([y for x in x_data, y in y_data])
    cache.obs_u[] = vec(u_data)

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)

    sc = scatter!(ax, cache.obs_x, cache.obs_y; color=cache.obs_u, colormap=ui_app["color_map"][], colorrange=cr_obs, markersize=ui_app["marker_size"][], marker=ui_app["markers"][][1])

    cache.primitives[:scatter2d] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, manager, cr_obs, label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter3d}, plot_idx::Int)
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    label = active_methods[1]
    cache = PlotCache()

    x_data, y_data, z_data, u_data = xs_slices[1], ys_slices[1], zs_slices[1], us_slices[1]
    cache.obs_x[] = vec([x for x in x_data, y in y_data, z in z_data])
    cache.obs_y[] = vec([y for x in x_data, y in y_data, z in z_data])
    cache.obs_z[] = vec([z for x in x_data, y in y_data, z in z_data])
    cache.obs_u[] = vec(u_data)

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)

    sc = scatter!(ax, cache.obs_x, cache.obs_y, cache.obs_z; color=cache.obs_u, colormap=ui_app["color_map"][], colorrange=cr_obs, markersize=ui_app["marker_size"][], marker=ui_app["markers"][][1])

    cache.primitives[:scatter3d] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, manager, cr_obs, label, plot_idx)
end

# -----------------------------------------------------------------------------
# TIER 3 DATA INJECTION HELPERS (Unchanged)
# -----------------------------------------------------------------------------
function sync_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{1})
    xs_slices, us_slices = data_tuples
    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        cache.obs_x.val = xs_slices[m_idx] 
        cache.obs_u[]   = us_slices[m_idx] 
    end
end

function sync_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{2})
    xs_slices, ys_slices, us_slices = data_tuples
    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        if haskey(cache.primitives, :scatter2d) || haskey(cache.primitives, :scatter3d)
            cache.obs_x.val = vec([x for x in xs_slices[m_idx], y in ys_slices[m_idx]])
            cache.obs_y.val = vec([y for x in xs_slices[m_idx], y in ys_slices[m_idx]])
            cache.obs_u[]   = vec(us_slices[m_idx])
        else
            cache.obs_x.val = xs_slices[m_idx]
            cache.obs_y.val = ys_slices[m_idx]
            cache.obs_u[]   = us_slices[m_idx]
        end
    end
end

function sync_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{3})
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    label = active_methods[1]
    haskey(cache_dict, label) || return
    cache = cache_dict[label]
    
    if haskey(cache.primitives, :scatter3d)
        cache.obs_x.val = vec([x for x in xs_slices[1], y in ys_slices[1], z in zs_slices[1]])
        cache.obs_y.val = vec([y for x in xs_slices[1], y in ys_slices[1], z in zs_slices[1]])
        cache.obs_z.val = vec([z for x in xs_slices[1], y in ys_slices[1], z in zs_slices[1]])
        cache.obs_u[]   = vec(us_slices[1])
    else
        cache.obs_x.val = extrema(xs_slices[1])
        cache.obs_y.val = extrema(ys_slices[1])
        cache.obs_z.val = extrema(zs_slices[1])
        cache.obs_u[]   = us_slices[1]
    end
end