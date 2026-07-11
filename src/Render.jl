# =============================================================================
# MODULAR HELPERS
# =============================================================================
function get_base_method_index(ui_app::Dict, active_methods::Vector{String})
    # Mathematically protect against empty arrays
    isempty(active_methods) && return 1
    
    raw_idx = get(ui_app, "base_method_idx", Ref(1))[]
    return clamp(raw_idx, 1, length(active_methods))
end

# THE FIX: Flattens Vectors of 1-Tuples or 1-SVectors into Float arrays
function _unwrap_1tuples(data)
    if !isempty(data) && (first(data) isa Tuple || first(data) isa AbstractVector) && length(first(data)) == 1
        return Float64[d[1] for d in data]
    end
    return data
end

# -----------------------------------------------------------------------------
# GRID FLATTENING HELPERS (NaN Separators for Connected Lines)
# -----------------------------------------------------------------------------
function build_2d_lines_grid(xs, ys, us, dir::String)
    X, Y, U = Float64[], Float64[], Float64[]
    Nx, Ny = length(xs), length(ys)
    if lowercase(strip(dir)) == "vertical"
        for i in 1:Nx
            append!(X, fill(xs[i], Ny)); push!(X, NaN)
            append!(Y, ys); push!(Y, NaN)
            append!(U, us[i, :]); push!(U, NaN)
        end
    else # Default Horizontal
        for j in 1:Ny
            append!(X, xs); push!(X, NaN)
            append!(Y, fill(ys[j], Nx)); push!(Y, NaN)
            append!(U, us[:, j]); push!(U, NaN)
        end
    end
    return X, Y, U
end

function build_3d_lines_grid(xs, ys, zs, us, dir::String)
    X, Y, Z, U = Float64[], Float64[], Float64[], Float64[]
    Nx, Ny, Nz = length(xs), length(ys), length(zs)
    dir_clean = lowercase(strip(dir))
    
    if dir_clean == "vertical" || dir_clean == "along y"
        for i in 1:Nx, k in 1:Nz
            append!(X, fill(xs[i], Ny)); push!(X, NaN)
            append!(Y, ys); push!(Y, NaN)
            append!(Z, fill(zs[k], Ny)); push!(Z, NaN)
            append!(U, us[i, :, k]); push!(U, NaN)
        end
    elseif dir_clean == "depth" || dir_clean == "along z"
        for i in 1:Nx, j in 1:Ny
            append!(X, fill(xs[i], Nz)); push!(X, NaN)
            append!(Y, fill(ys[j], Nz)); push!(Y, NaN)
            append!(Z, zs); push!(Z, NaN)
            append!(U, us[i, j, :]); push!(U, NaN)
        end
    else # Default Horizontal / Along X
        for j in 1:Ny, k in 1:Nz
            append!(X, xs); push!(X, NaN)
            append!(Y, fill(ys[j], Nx)); push!(Y, NaN)
            append!(Z, fill(zs[k], Nx)); push!(Z, NaN)
            append!(U, us[:, j, k]); push!(U, NaN)
        end
    end
    return X, Y, Z, U
end

# -----------------------------------------------------------------------------
# 1D PRIMITIVES
# -----------------------------------------------------------------------------

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:lines}, plot_idx::Int)
    xs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]
    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = PlotCache()
        cache.obs_x.val = _unwrap_1tuples(xs_slices[m_idx])
        cache.obs_u[]   = _unwrap_1tuples(us_slices[m_idx])
        
        c  = ui_app["colors"][][mod1(m_idx, end)]
        ls = ui_app["dashed_lines"][] ? ui_app["line_styles"][][mod1(m_idx, end)] : nothing
        lw = ui_app["line_width"][]
        
        l = lines!(ax, cache.obs_x, cache.obs_u; color=c, linewidth=lw, linestyle=ls)
        cache.primitives[:lines] = l
        cache_dict[label] = cache
        
        push!(plotted_objects, [Makie.LineElement(color=c, linewidth=lw, linestyle=ls)])
        push!(labels_for_legend, label)
    end
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter1d}, plot_idx::Int)
    xs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]
    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = PlotCache()
        cache.obs_x.val = _unwrap_1tuples(xs_slices[m_idx])
        cache.obs_u[]   = _unwrap_1tuples(us_slices[m_idx])
        
        c   = ui_app["colors"][][mod1(m_idx, end)]
        mrk = ui_app["markers"][][mod1(m_idx, end)]
        ms  = ui_app["marker_size"][]
        
        s = scatter!(ax, cache.obs_x, cache.obs_u; color=c, markersize=ms, marker=mrk)
        cache.primitives[:scatter1d] = s
        cache_dict[label] = cache
        
        push!(plotted_objects, [Makie.MarkerElement(color=c, marker=mrk, markersize=ms)])
        push!(labels_for_legend, label)
    end
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatterlines}, plot_idx::Int)
    xs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]
    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = PlotCache()
        cache.obs_x.val = _unwrap_1tuples(xs_slices[m_idx])
        cache.obs_u[]   = _unwrap_1tuples(us_slices[m_idx])
        
        c   = ui_app["colors"][][mod1(m_idx, end)]
        ls  = ui_app["dashed_lines"][] ? ui_app["line_styles"][][mod1(m_idx, end)] : nothing
        lw  = ui_app["line_width"][]
        mrk = ui_app["markers"][][mod1(m_idx, end)]
        ms  = ui_app["marker_size"][]
        
        sl = scatterlines!(ax, cache.obs_x, cache.obs_u; color=c, linewidth=lw, linestyle=ls, markersize=ms, marker=mrk)
        cache.primitives[:scatterlines] = sl
        cache_dict[label] = cache
        
        push!(plotted_objects, [Makie.LineElement(color=c, linewidth=lw, linestyle=ls), Makie.MarkerElement(color=c, marker=mrk, markersize=ms)])
        push!(labels_for_legend, label)
    end
end

# -----------------------------------------------------------------------------
# 2D PRIMITIVES
# -----------------------------------------------------------------------------

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:contour}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]
    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = PlotCache()
        cache.obs_x.val = xs_slices[m_idx]
        cache.obs_y.val = ys_slices[m_idx]
        cache.obs_u[]   = us_slices[m_idx]

        color = ui_app["colors"][][mod1(m_idx, length(ui_app["colors"][]))]
        lw    = ui_app["line_width"][]
        
        ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; levels=ui_app["levels"][], color=color, linewidth=lw, labels=ui_app["labels"][])
        
        cache.primitives[:contour] = ct
        cache_dict[label] = cache

        push!(plotted_objects, [Makie.LineElement(color=color, linewidth=lw)])
        push!(labels_for_legend, label)
    end
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:heatmap}, plot_idx::Int)
    xs, ys, us = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx] 
    cache = PlotCache()
    
    cache.obs_x.val = xs[base_idx]
    cache.obs_y.val = ys[base_idx]
    cache.obs_u[]   = us[base_idx]

    valid_u = filter(isfinite, us[base_idx])
    cr_obs = get_colorrange(ui_app, valid_u)
    rast_val = ui_app["rasterize"][] == 0 ? false : ui_app["rasterize"][]

    hm = heatmap!(ax, cache.obs_x, cache.obs_y, cache.obs_u; colormap=ui_app["color_map"][], colorrange=cr_obs, rasterize=rast_val)

    cache.primitives[:heatmap] = hm
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, hm, manager, cr_obs, label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:lines2d}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    cache = PlotCache()
    
    dir = get(ui_app, "line_direction", Observable("Horizontal"))[]
    X, Y, U = build_2d_lines_grid(xs_slices[base_idx], ys_slices[base_idx], us_slices[base_idx], dir)
    cache.obs_x.val = X
    cache.obs_y.val = Y
    cache.obs_u[]   = U

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)

    l2d = lines!(ax, cache.obs_x, cache.obs_y; color=cache.obs_u, colormap=ui_app["color_map"][], colorrange=cr_obs, linewidth=ui_app["line_width"][])
    cache.primitives[:lines2d] = l2d
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, l2d, manager, cr_obs, label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter2d}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    cache = PlotCache()
    
    x_data, y_data, u_data = xs_slices[base_idx], ys_slices[base_idx], us_slices[base_idx]
    
    # Bypass meshgrid generation if we are in Lagrangian Mode
    if get(manager.state, "Data_Mode", Observable(:eulerian))[] == :lagrangian
        cache.obs_x.val = x_data
        cache.obs_y.val = y_data
        cache.obs_u[]   = u_data
    else
        cache.obs_x.val = vec([x for x in x_data, y in y_data])
        cache.obs_y.val = vec([y for x in x_data, y in y_data])
        cache.obs_u[]   = vec(u_data)
    end

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)

    sc = scatter!(ax, cache.obs_x, cache.obs_y; color=cache.obs_u, colormap=ui_app["color_map"][], colorrange=cr_obs, markersize=ui_app["marker_size"][], marker=ui_app["markers"][][1])

    cache.primitives[:scatter2d] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, manager, cr_obs, label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:contour_cmap}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    base_label = active_methods[base_idx]

    cache = PlotCache()
    cache.obs_x.val = xs_slices[base_idx]
    cache.obs_y.val = ys_slices[base_idx]
    cache.obs_u[]   = us_slices[base_idx]
    
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

    base_idx = get_base_method_index(ui_app, active_methods)
    base_label = active_methods[base_idx]
    
    valid_u = filter(isfinite, us_slices[base_idx])
    cr_obs = get_colorrange(ui_app, valid_u)
    lvl_range = range(cr_obs[][1], cr_obs[][2], length=ui_app["levels"][])
    rast_val = ui_app["rasterize"][] == 0 ? false : ui_app["rasterize"][]

    plotted_objects, labels_for_legend = [], String[]
    
    base_cache = PlotCache()
    base_cache.obs_x.val = xs_slices[base_idx]
    base_cache.obs_y.val = ys_slices[base_idx]
    base_cache.obs_u[]   = us_slices[base_idx]

    cf = contourf!(ax, base_cache.obs_x, base_cache.obs_y, base_cache.obs_u; colormap=ui_app["color_map"][], levels=lvl_range, rasterize=rast_val)
    base_cache.primitives[:contourf] = cf
    cache_dict[base_label] = base_cache

    base_color = Makie.to_colormap(ui_app["color_map"][])[end]
    push!(plotted_objects, [Makie.PolyElement(color=base_color)])
    push!(labels_for_legend, "$base_label (Base)")

    for (i, label) in enumerate(active_methods)
        if i == base_idx; continue; end
        cache = PlotCache()
        cache.obs_x.val = xs_slices[i]
        cache.obs_y.val = ys_slices[i]
        cache.obs_u[]   = us_slices[i]
        
        color = ui_app["colors"][][mod1(i, end)]
        lw = ui_app["line_width"][]
        
        ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; color=color, linewidth=lw, labels=true)
        cache.primitives[:contour] = ct
        cache_dict[label] = cache
        
        push!(plotted_objects, [Makie.LineElement(color=color, linewidth=lw)])
        push!(labels_for_legend, label)
    end

    create_or_update_colorbar!(plot_layout, cf, manager, cr_obs, base_label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:surface}, plot_idx::Int)
    xs_slices, ys_slices, us_slices = data_tuples 
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    
    cache = PlotCache()
    cache.obs_x.val = xs_slices[base_idx]
    cache.obs_y.val = ys_slices[base_idx]
    cache.obs_u[]   = us_slices[base_idx]
    
    valid_u = filter(isfinite, us_slices[base_idx])
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
    
    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    x_data, y_data, z_data, u_data = xs_slices[base_idx], ys_slices[base_idx], zs_slices[base_idx], us_slices[base_idx]

    cache = PlotCache()
    cache.obs_x.val = extrema(x_data)
    cache.obs_y.val = extrema(y_data)
    cache.obs_z.val = extrema(z_data)
    cache.obs_u[]   = u_data
    
    valid_u = filter(isfinite, u_data)
    cr_obs = get_colorrange(ui_app, valid_u)

    vol = volume!(ax, cache.obs_x, cache.obs_y, cache.obs_z, cache.obs_u; colormap=ui_app["color_map"][], colorrange=cr_obs)
    
    cache.primitives[:volume] = vol
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, vol, manager, cr_obs, label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:lines3d}, plot_idx::Int)
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    cache = PlotCache()
    
    dir = get(ui_app, "line_direction", Observable("Horizontal"))[]
    X, Y, Z, U = build_3d_lines_grid(xs_slices[base_idx], ys_slices[base_idx], zs_slices[base_idx], us_slices[base_idx], dir)
    cache.obs_x.val = X
    cache.obs_y.val = Y
    cache.obs_z.val = Z
    cache.obs_u[]   = U

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)

    l3d = lines!(ax, cache.obs_x, cache.obs_y, cache.obs_z; color=cache.obs_u, colormap=ui_app["color_map"][], colorrange=cr_obs, linewidth=ui_app["line_width"][])
    cache.primitives[:lines3d] = l3d
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, l3d, manager, cr_obs, label, plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter3d}, plot_idx::Int)
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    cache = PlotCache()

    x_data, y_data, z_data, u_data = xs_slices[base_idx], ys_slices[base_idx], zs_slices[base_idx], us_slices[base_idx]
    
    if get(manager.state, "Data_Mode", Observable(:eulerian))[] == :lagrangian
        cache.obs_x.val = x_data
        cache.obs_y.val = y_data
        cache.obs_z.val = z_data
        cache.obs_u[]   = u_data
    else
        cache.obs_x.val = vec([x for x in x_data, y in y_data, z in z_data])
        cache.obs_y.val = vec([y for x in x_data, y in y_data, z in z_data])
        cache.obs_z.val = vec([z for x in x_data, y in y_data, z in z_data])
        cache.obs_u[]   = vec(u_data)
    end

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)

    sc = scatter!(ax, cache.obs_x, cache.obs_y, cache.obs_z; color=cache.obs_u, colormap=ui_app["color_map"][], colorrange=cr_obs, markersize=ui_app["marker_size"][], marker=ui_app["markers"][][1])

    cache.primitives[:scatter3d] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, manager, cr_obs, label, plot_idx)
end

# -----------------------------------------------------------------------------
# TIER 3 DATA INJECTION HELPERS
# -----------------------------------------------------------------------------
function sync_data_to_cache!(cache_dict, active_methods, data_tuples, manager::PlotManager, ::Val{1})
    xs_slices, us_slices = data_tuples
    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        # Flatten 1-Tuples safely if present
        cache.obs_x.val = _unwrap_1tuples(xs_slices[m_idx])
        cache.obs_u[]   = _unwrap_1tuples(us_slices[m_idx])
    end
end

function sync_data_to_cache!(cache_dict, active_methods, data_tuples, manager::PlotManager, ::Val{2})
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]
    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        if haskey(cache.primitives, :scatter2d) || haskey(cache.primitives, :scatter3d)
            if get(manager.state, "Data_Mode", Observable(:eulerian))[] == :lagrangian
                cache.obs_x.val = xs_slices[m_idx]
                cache.obs_y.val = ys_slices[m_idx]
                cache.obs_u[]   = us_slices[m_idx]
            else
                cache.obs_x.val = vec([x for x in xs_slices[m_idx], y in ys_slices[m_idx]])
                cache.obs_y.val = vec([y for x in xs_slices[m_idx], y in ys_slices[m_idx]])
                cache.obs_u[]   = vec(us_slices[m_idx])
            end
        elseif haskey(cache.primitives, :lines2d)
            dir = get(ui_app, "line_direction", Observable("Horizontal"))[]
            X, Y, U = build_2d_lines_grid(xs_slices[m_idx], ys_slices[m_idx], us_slices[m_idx], dir)
            cache.obs_x.val = X
            cache.obs_y.val = Y
            cache.obs_u[]   = U
        else
            cache.obs_x.val = xs_slices[m_idx]
            cache.obs_y.val = ys_slices[m_idx]
            cache.obs_u[]   = us_slices[m_idx]
        end
    end
end

function sync_data_to_cache!(cache_dict, active_methods, data_tuples, manager::PlotManager, ::Val{3})
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui["Plot-Style"]

    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        if haskey(cache.primitives, :scatter3d)
            if get(manager.state, "Data_Mode", Observable(:eulerian))[] == :lagrangian
                cache.obs_x.val = xs_slices[m_idx]
                cache.obs_y.val = ys_slices[m_idx]
                cache.obs_z.val = zs_slices[m_idx]
                cache.obs_u[]   = us_slices[m_idx]
            else
                cache.obs_x.val = vec([x for x in xs_slices[m_idx], y in ys_slices[m_idx], z in zs_slices[m_idx]])
                cache.obs_y.val = vec([y for x in xs_slices[m_idx], y in ys_slices[m_idx], z in zs_slices[m_idx]])
                cache.obs_z.val = vec([z for x in xs_slices[m_idx], y in ys_slices[m_idx], z in zs_slices[m_idx]])
                cache.obs_u[]   = vec(us_slices[m_idx])
            end
        elseif haskey(cache.primitives, :lines3d)
            dir = get(ui_app, "line_direction", Observable("Horizontal"))[]
            X, Y, Z, U = build_3d_lines_grid(xs_slices[m_idx], ys_slices[m_idx], zs_slices[m_idx], us_slices[m_idx], dir)
            cache.obs_x.val = X
            cache.obs_y.val = Y
            cache.obs_z.val = Z
            cache.obs_u[]   = U
        else
            cache.obs_x.val = extrema(xs_slices[m_idx])
            cache.obs_y.val = extrema(ys_slices[m_idx])
            cache.obs_z.val = extrema(zs_slices[m_idx])
            cache.obs_u[]   = us_slices[m_idx]
        end
    end
end