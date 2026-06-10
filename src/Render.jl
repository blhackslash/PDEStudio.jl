# -----------------------------------------------------------------------------
# 2D PRIMITIVES: INITIALIZERS
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

    hm = heatmap!(ax, cache.obs_x, cache.obs_y, cache.obs_u; colormap=ui_app["colormap"][], colorrange=cr_obs, rasterize=rast_val)

    cache.primitives["heatmap"] = hm
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, hm, manager, cr_obs, label, plot_idx)
end

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
        lw = ui_app["linewidth"][]
        
        ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; levels=ui_app["levels"][], color=color, linewidth=lw, labels=ui_app["labels"][])
        
        cache.primitives["contour"] = ct
        cache_dict[label] = cache

        push!(plotted_objects, [Makie.LineElement(color=color, linewidth=lw)])
        push!(labels_for_legend, label)
    end
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
    
    # Base method filled contour
    base_label = active_methods[base_idx]
    base_cache = PlotCache()
    base_cache.obs_x[] = xs_slices[base_idx]; base_cache.obs_y[] = ys_slices[base_idx]; base_cache.obs_u[] = us_slices[base_idx]

    cf = contourf!(ax, base_cache.obs_x, base_cache.obs_y, base_cache.obs_u; colormap=ui_app["colormap"][], levels=lvl_range, rasterize=rast_val)
    base_cache.primitives["contourf"] = cf
    cache_dict[base_label] = base_cache

    base_color = Makie.to_colormap(ui_app["colormap"][])[end]
    push!(plotted_objects, [Makie.PolyElement(color=base_color)]); push!(labels_for_legend, "$base_label (Base)")

    for (i, label) in enumerate(active_methods)
        if i == base_idx; continue; end
        cache = PlotCache()
        cache.obs_x[] = xs_slices[i]; cache.obs_y[] = ys_slices[i]; cache.obs_u[] = us_slices[i]
        
        color = ui_app["colors"][][mod1(i, end)]
        lw = ui_app["linewidth"][]
        
        ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; color=color, linewidth=lw, labels=true)
        cache.primitives["contour"] = ct
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

    sf = surface!(ax, cache.obs_x, cache.obs_y, cache.obs_u; colormap=ui_app["colormap"][], colorrange=cr_obs, rasterize=rast_val)
    cache.primitives["surface"] = sf
    cache_dict[label] = cache
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
        
        # --- THE FIX: Safe Proxies for Mutables, Static for Types! ---
        line_color = Observable{Any}(:black)
        line_width = Observable{Any}(1.0)
        line_vis   = Observable{Any}(true)
        
        scat_color = Observable{Any}(:black)
        scat_size  = Observable{Any}(10.0)
        scat_vis   = Observable{Any}(false)
        
        # Read structural styles exactly ONCE to prevent Makie type crashes
        static_ls = ui_app["dashed_lines"][] ? ui_app["line_styles"][][mod1(m_idx, end)] : nothing
        static_mk = ui_app["markers"][][mod1(m_idx, end)]
        
        l = lines!(ax, cache.obs_x, cache.obs_u; 
            color=line_color, linewidth=line_width, linestyle=static_ls, visible=line_vis
        )
        s = scatter!(ax, cache.obs_x, cache.obs_u; 
            color=scat_color, markersize=scat_size, marker=static_mk, visible=scat_vis
        )
        
        cache.primitives["line"] = l
        cache.primitives["scatter"] = s
        
        cache.primitives["line_color"] = line_color
        cache.primitives["line_width"] = line_width
        cache.primitives["line_visible"] = line_vis
        
        cache.primitives["scat_color"] = scat_color
        cache.primitives["scat_size"]  = scat_size
        cache.primitives["scat_visible"] = scat_vis
        
        cache_dict[label] = cache

        push!(plotted_objects, [l, s])
        push!(labels_for_legend, label)
    end
    
    create_or_update_legend!(plot_layout, plotted_objects, labels_for_legend, manager)
end

# -----------------------------------------------------------------------------
# 3D EXAMPLE: VOLUME
# -----------------------------------------------------------------------------
function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:volume}, plot_idx::Int)
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]
    
    x_data, y_data, z_data, u_data = xs_slices[1], ys_slices[1], zs_slices[1], us_slices[1]

    # 1. Seed the Observables cleanly! (Makie won't crash because u_data is a real 3D Array)
    cache = PlotCache()
    cache.obs_x[] = extrema(x_data)
    cache.obs_y[] = extrema(y_data)
    cache.obs_z[] = extrema(z_data)
    cache.obs_u[] = u_data
    
    valid_u = filter(isfinite, u_data)
    cr_obs = get_colorrange(ui_app, valid_u)

    # 2. Bind the primitives
    vol = volume!(ax, cache.obs_x, cache.obs_y, cache.obs_z, cache.obs_u; colormap=ui_app["colormap"][], colorrange=cr_obs)
    
    # 3. Save to cache
    cache.primitives["volume"] = vol
    cache_dict[active_methods[1]] = cache
    
    create_or_update_colorbar!(plot_layout, vol, manager, cr_obs, active_methods[1], plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter2d}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    label = active_methods[1]
    cache = PlotCache()
    
    # 1. Generate the initial flattened grid
    x_data, y_data, u_data = xs_slices[1], ys_slices[1], us_slices[1]
    cache.obs_x[] = vec([x for x in x_data, y in y_data])
    cache.obs_y[] = vec([y for x in x_data, y in y_data])
    cache.obs_u[] = vec(u_data)

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)

    sc = scatter!(ax, cache.obs_x, cache.obs_y; color=cache.obs_u, colormap=ui_app["colormap"][], colorrange=cr_obs, markersize=ui_app["markersize"][], marker=ui_app["markers"][][1])

    cache.primitives["scatter2d"] = sc
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

    sc = scatter!(ax, cache.obs_x, cache.obs_y, cache.obs_z; color=cache.obs_u, colormap=ui_app["colormap"][], colorrange=cr_obs, markersize=ui_app["markersize"][], marker=ui_app["markers"][][1])

    cache.primitives["scatter3d"] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, manager, cr_obs, label, plot_idx)
end

# -----------------------------------------------------------------------------
# TIER 3 DATA INJECTION HELPERS (One for 1D, 2D, and 3D)
# -----------------------------------------------------------------------------
function sync_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{1})
    xs_slices, us_slices = data_tuples
    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        # Silent update (.val) for x, trigger update ([]) for u to redraw exactly once!
        cache.obs_x.val = xs_slices[m_idx] 
        cache.obs_u[]   = us_slices[m_idx] 
    end
end

function sync_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{2})
    xs_slices, ys_slices, us_slices = data_tuples
    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        if haskey(cache.primitives, "scatter2d")
            # Flatten the grid dynamically for scatter plots
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
    
    if haskey(cache.primitives, "scatter3d")
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