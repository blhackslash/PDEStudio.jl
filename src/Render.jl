# =============================================================================
# --- Render.jl ---
# =============================================================================
"""
    get_base_method_index(ui_app::Dict, active_methods::Vector{Symbol})

Determines which active numerical method acts as the foundational "base" layer for complex 2D/3D primitives (like heatmaps or volume renders) where overlying multiple fields is visually impossible. Falls back to the first method if none is explicitly targeted.
"""
function get_base_method_index(ui_app::Dict, active_methods::Vector{Symbol})
    isempty(active_methods) && return 1
    raw_idx = get(ui_app, :base_method_idx, 1) 
    return clamp(raw_idx, 1, length(active_methods))
end

"""
    _unwrap_1tuples(data)

Safely unwraps deeply nested arrays of 1-element tuples (common when isolating single variables from complex vector states) into a flat `Vector{Float64}` required by Makie's native 1D drawing routines.
"""
function _unwrap_1tuples(data)
    if !isempty(data) && (first(data) isa Tuple || first(data) isa AbstractVector) && length(first(data)) == 1
        return Float64[d[1] for d in data]
    end
    return data
end

# -----------------------------------------------------------------------------
# GRID FLATTENING HELPERS (NaN Separators for Connected Lines)
# -----------------------------------------------------------------------------
"""
    build_2d_lines_grid(xs, ys, us, dir::Symbol)

Flattens a dense 2D Eulerian grid into a single, contiguous 1D array of coordinates by interlacing `NaN` separators. 
This mathematical trick forces Makie's `lines!` function to draw hundreds of independent, parallel slices (either `:vertical` or `:horizontal`) in a single ultra-fast render call without creating a dense mesh.
"""
function build_2d_lines_grid(xs, ys, us, dir::Symbol)
    X, Y, U = Float64[], Float64[], Float64[]
    Nx, Ny = length(xs), length(ys)
    
    if dir === :vertical
        for i in 1:Nx
            append!(X, fill(xs[i], Ny)); push!(X, NaN)
            append!(Y, ys); push!(Y, NaN)
            append!(U, us[i, :]); push!(U, NaN)
        end
    else 
        for j in 1:Ny
            append!(X, xs); push!(X, NaN)
            append!(Y, fill(ys[j], Nx)); push!(Y, NaN)
            append!(U, us[:, j]); push!(U, NaN)
        end
    end
    return X, Y, U
end

"""
    build_3d_lines_grid(xs, ys, zs, us, dir::Symbol)

Expands the `NaN` separator trick to 3D Eulerian tensors, constructing massive point clouds of independent line segments projected along a specific primary viewing axis (`:vertical`, `:depth`, or `:horizontal`).
"""
function build_3d_lines_grid(xs, ys, zs, us, dir::Symbol)
    X, Y, Z, U = Float64[], Float64[], Float64[], Float64[]
    Nx, Ny, Nz = length(xs), length(ys), length(zs)
    
    if dir === :vertical || dir === :along_y
        for i in 1:Nx, k in 1:Nz
            append!(X, fill(xs[i], Ny)); push!(X, NaN)
            append!(Y, ys); push!(Y, NaN)
            append!(Z, fill(zs[k], Ny)); push!(Z, NaN)
            append!(U, us[i, :, k]); push!(U, NaN)
        end
    elseif dir === :depth || dir === :along_z
        for i in 1:Nx, j in 1:Ny
            append!(X, fill(xs[i], Nz)); push!(X, NaN)
            append!(Y, fill(ys[j], Nz)); push!(Y, NaN)
            append!(Z, zs); push!(Z, NaN)
            append!(U, us[i, j, :]); push!(U, NaN)
        end
    else 
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
# PRIMITIVE INITIALIZERS 
# -----------------------------------------------------------------------------
# Note: The following docstring applies generally to all `initialize_base_plot!` dispatches.


# -----------------------------------------------------------------------------
# 1D PRIMITIVES
# -----------------------------------------------------------------------------
"""
    initialize_base_plot!(plot_layout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{PlotStyle}, plot_idx)

The fundamental dispatch bridge between numeric arrays and graphical representations. 

For each supported `PlotStyle` (e.g., `:lines_1d`, `:heatmap_flat`, `:scatter_surface`), this function:
1. Allocates a fresh `EulerianPlotCache` or `LagrangianPlotCache`.
2. Binds the initial numeric slices (from `data_tuples`) to Makie `Observable`s.
3. Extracts visual styles (colors, line widths, marker sizes, rasterization settings) from the UI dictionary.
4. Instantiates the low-level Makie primitive (e.g., `lines!`, `contour3d!`, `volume!`).
5. Stores the primitive references back into the global cache for subsequent color/style syncing and legend generation.
"""
function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:lines_1d}, plot_idx::Int)
    
    xs_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = EulerianPlotCache()
        cache.obs_x.val = _unwrap_1tuples(xs_slices[m_idx])
        cache.obs_u.val = _unwrap_1tuples(us_slices[m_idx])
        
        c  = Makie.to_color(ui_app[:colors][mod1(m_idx, end)])
        ls = ui_app[:dashed_lines] ? ui_app[:line_styles][mod1(m_idx, end)] : nothing 
        lw = ui_app[:line_width] 

        raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false
        
        l = lines!(ax, cache.obs_x, cache.obs_u; color=c, linewidth=lw, linestyle=ls, rasterize=raster)
        cache.primitives[:lines_1d] = l
        cache_dict[label] = cache
        
        push!(plotted_objects, [Makie.LineElement(color=c, linewidth=lw, linestyle=ls)])
        push!(labels_for_legend, frontend_key(label))
    end
end

# -----------------------------------------------------------------------------
# 2D PRIMITIVES
# -----------------------------------------------------------------------------

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:contour_colors}, plot_idx::Int)
    
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = EulerianPlotCache()
        cache.obs_x.val = xs_slices[m_idx]
        cache.obs_y.val = ys_slices[m_idx]
        cache.obs_u.val = us_slices[m_idx]

        color = Makie.to_color(ui_app[:colors][mod1(m_idx, length(ui_app[:colors]))])
        lw    = ui_app[:line_width] 
        raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false
        
        ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; levels=ui_app[:levels], color=color, linewidth=lw, labels=ui_app[:labels], rasterize=raster) 
        
        cache.primitives[:contour_colors] = ct
        cache_dict[label] = cache

        push!(plotted_objects, [Makie.LineElement(color=color, linewidth=lw)])
        push!(labels_for_legend, frontend_key(label))
    end
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:heatmap_flat}, plot_idx::Int)
    
    xs, ys, us = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx] 
    cache = EulerianPlotCache()
    
    cache.obs_x.val = xs[base_idx]
    cache.obs_y.val = ys[base_idx]
    cache.obs_u.val = us[base_idx]

    valid_u = filter(isfinite, us[base_idx])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false

    hm = heatmap!(ax, cache.obs_x, cache.obs_y, cache.obs_u; colormap=ui_app[:color_map], colorrange=cr_obs, rasterize=raster) 

    cache.primitives[:heatmap_flat] = hm
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, hm, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:lines_2d}, plot_idx::Int)
    
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    cache = EulerianPlotCache()
    
    dir = get(ui_app, :line_direction, :horizontal) 
    X, Y, U = build_2d_lines_grid(xs_slices[base_idx], ys_slices[base_idx], us_slices[base_idx], dir)
    cache.obs_x.val = X
    cache.obs_y.val = Y
    cache.obs_u.val = U

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false

    l2d = lines!(ax, cache.obs_x, cache.obs_y; color=cache.obs_u, colormap=ui_app[:color_map], colorrange=cr_obs, linewidth=ui_app[:line_width], rasterize=raster) 
    cache.primitives[:lines_2d] = l2d
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, l2d, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:contour_cmap}, plot_idx::Int)
    
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    base_label = active_methods[base_idx]

    cache = EulerianPlotCache()
    cache.obs_x.val = xs_slices[base_idx]
    cache.obs_y.val = ys_slices[base_idx]
    cache.obs_u.val = us_slices[base_idx]
    
    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false

    ct = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_u; 
        colormap=ui_app[:color_map], colorrange=cr_obs, 
        levels=ui_app[:levels], linewidth=ui_app[:line_width], labels=ui_app[:labels] , rasterize=raster
    )
    
    cache.primitives[:contour_cmap] = ct
    cache_dict[base_label] = cache
    create_or_update_colorbar!(plot_layout, ct, cr_obs, frontend_key(base_label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:contour_f}, plot_idx::Int)

    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]

    valid_u = filter(isfinite, us_slices[base_idx])
    cr_obs = get_colorrange(ui_app, valid_u)
    
    lvl_range = range(cr_obs[][1], cr_obs[][2], length=ui_app[:levels]) 
    
    cache = EulerianPlotCache()
    cache.obs_x.val = xs_slices[base_idx]
    cache.obs_y.val = ys_slices[base_idx]
    cache.obs_u.val = us_slices[base_idx]
    
    raster = manager.ui[:export][:rasterization_enabled] ? manager.ui[:export][:rasterization_quality] : false

    cf = contourf!(ax, cache.obs_x, cache.obs_y, cache.obs_u; 
                   colormap=ui_app[:color_map], 
                   colorrange=cr_obs, 
                   levels=lvl_range, 
                   rasterize=raster) 

    cache.primitives[:contour_f] = cf
    cache_dict[label] = cache

    create_or_update_colorbar!(plot_layout, cf, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:heatmap_surface}, plot_idx::Int)
    
    xs_slices, ys_slices, us_slices = data_tuples 
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    
    cache = EulerianPlotCache()
    cache.obs_x.val = xs_slices[base_idx]
    cache.obs_y.val = ys_slices[base_idx]
    cache.obs_u.val = us_slices[base_idx]
    
    valid_u = filter(isfinite, us_slices[base_idx])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false

    sf = surface!(ax, cache.obs_x, cache.obs_y, cache.obs_u; colormap=ui_app[:color_map], colorrange=cr_obs, rasterize=raster ) 
    cache.primitives[:heatmap_surface] = sf
    cache_dict[label] = cache
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter_surface}, plot_idx::Int)
    
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    pts_slices, us_slices = data_tuples

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    
    cache = LagrangianPlotCache()
    cache.obs_pts.val = pts_slices[base_idx]
    cache.obs_u.val   = us_slices[base_idx]

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false
    
    pts_3d = lift(cache.obs_pts, cache.obs_u) do pts, us
        [Point3f(p[1], p[2], u) for (p, u) in zip(pts, us)]
    end

    sc = scatter!(ax, pts_3d; color=cache.obs_u, colormap=ui_app[:color_map], colorrange=cr_obs, markersize=ui_app[:marker_size], marker=ui_app[:markers][1], rasterize=raster) 
    
    cache.primitives[:scatter_surface] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:contour_surface}, plot_idx::Int)
    
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    plotted_objects, labels_for_legend = [], String[]
    
    for (m_idx, label) in enumerate(active_methods)
        cache = EulerianPlotCache()
        
        cache.obs_x.val = xs_slices[m_idx]
        cache.obs_y.val = ys_slices[m_idx]
        cache.obs_u.val = us_slices[m_idx]

        color = Makie.to_color(ui_app[:colors][mod1(m_idx, length(ui_app[:colors]))])
        lw    = ui_app[:line_width] 
        raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false
        
        cs = contour3d!(ax, cache.obs_x, cache.obs_y, cache.obs_u; 
                        levels=ui_app[:levels], color=color, linewidth=lw, rasterize=raster) 
        
        cache.primitives[:contour_surface] = cs
        cache_dict[label] = cache

        push!(plotted_objects, [Makie.LineElement(color=color, linewidth=lw)])
        push!(labels_for_legend, frontend_key(label))
    end
end

# -----------------------------------------------------------------------------
# 3D PRIMITIVES
# -----------------------------------------------------------------------------
function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:volume_3d}, plot_idx::Int)
    
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    
    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    x_data, y_data, z_data, u_data = xs_slices[base_idx], ys_slices[base_idx], zs_slices[base_idx], us_slices[base_idx]

    cache = EulerianPlotCache()
    cache.obs_x.val = extrema(x_data)
    cache.obs_y.val = extrema(y_data)
    cache.obs_z.val = extrema(z_data)
    cache.obs_u.val = u_data
    
    valid_u = filter(isfinite, u_data)
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false

    vol = volume!(ax, cache.obs_x, cache.obs_y, cache.obs_z, cache.obs_u; colormap=ui_app[:color_map], colorrange=cr_obs, rasterize=raster) 
    
    cache.primitives[:volume_3d] = vol
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, vol, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:lines_3d}, plot_idx::Int)
    
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    cache = EulerianPlotCache()
    
    dir = get(ui_app, :line_direction, "Horizontal") 
    X, Y, Z, U = build_3d_lines_grid(xs_slices[base_idx], ys_slices[base_idx], zs_slices[base_idx], us_slices[base_idx], dir)
    cache.obs_x.val = X
    cache.obs_y.val = Y
    cache.obs_z.val = Z
    cache.obs_u.val = U

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false

    l3d = lines!(ax, cache.obs_x, cache.obs_y, cache.obs_z; color=cache.obs_u, colormap=ui_app[:color_map], colorrange=cr_obs, linewidth=ui_app[:line_width], rasterize=raster) 
    cache.primitives[:lines_3d] = l3d
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, l3d, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:contour_3d}, plot_idx::Int)
    
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    
    cache = EulerianPlotCache()
    
    cache.obs_x.val = extrema(xs_slices[base_idx])
    cache.obs_y.val = extrema(ys_slices[base_idx])
    cache.obs_z.val = extrema(zs_slices[base_idx])
    cache.obs_u.val = us_slices[base_idx]
    
    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false

    ct3d = contour!(ax, cache.obs_x, cache.obs_y, cache.obs_z, cache.obs_u; 
                    colormap=ui_app[:color_map], colorrange=cr_obs, levels=ui_app[:levels], rasterize=raster) 
    
    cache.primitives[:contour_3d] = ct3d
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, ct3d, cr_obs, frontend_key(label), plot_idx)
end

# =============================================================================
# HYBRID 2D/3D PRIMITIVES (Eulerian Grids and Lagrangian Particles)
# =============================================================================

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter_2d}, plot_idx::Int)
    
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    is_eul = manager.mode[] == :eulerian

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    
    cache = is_eul ? EulerianPlotCache() : LagrangianPlotCache()

    if is_eul
        xs_slices, ys_slices, us_slices = data_tuples
        cache.obs_x.val = xs_slices[base_idx]
        cache.obs_y.val = ys_slices[base_idx]
        cache.obs_u.val = us_slices[base_idx]
        
        pts_2d = lift(cache.obs_x, cache.obs_y) do xs, ys
            vec([Point2f(xs[i], ys[j]) for i in eachindex(xs), j in eachindex(ys)])
        end
        vals_1d = lift(vec, cache.obs_u)
    else
        pts_slices, us_slices = data_tuples
        cache.obs_pts.val = pts_slices[base_idx]
        cache.obs_u.val   = us_slices[base_idx]
        
        pts_2d = cache.obs_pts
        vals_1d = cache.obs_u
    end

    valid_u = filter(isfinite, vals_1d[])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false
    
    sc = scatter!(ax, pts_2d; color=vals_1d, colormap=ui_app[:color_map], colorrange=cr_obs, markersize=ui_app[:marker_size], marker=ui_app[:markers][1], rasterize=raster) 
    
    cache.primitives[:scatter_2d] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter_3d}, plot_idx::Int)
    
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    is_eul = manager.mode[] == :eulerian

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    
    cache = is_eul ? EulerianPlotCache() : LagrangianPlotCache()

    if is_eul
        xs_slices, ys_slices, zs_slices, us_slices = data_tuples
        cache.obs_x.val = xs_slices[base_idx]
        cache.obs_y.val = ys_slices[base_idx]
        cache.obs_z.val = zs_slices[base_idx]
        cache.obs_u.val = us_slices[base_idx]
        
        pts_3d = lift(cache.obs_x, cache.obs_y, cache.obs_z) do xs, ys, zs
            vec([Point3f(xs[i], ys[j], zs[k]) for i in eachindex(xs), j in eachindex(ys), k in eachindex(zs)])
        end
        vals_1d = lift(vec, cache.obs_u)
    else
        pts_slices, us_slices = data_tuples
        cache.obs_pts.val = pts_slices[base_idx]
        cache.obs_u.val   = us_slices[base_idx]
        
        pts_3d = cache.obs_pts
        vals_1d = cache.obs_u
    end

    valid_u = filter(isfinite, vals_1d[])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false
    
    sc = scatter!(ax, pts_3d; color=vals_1d, colormap=ui_app[:color_map], colorrange=cr_obs, markersize=ui_app[:marker_size], marker=ui_app[:markers][1], rasterize=raster) 
    
    cache.primitives[:scatter_3d] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter_1d}, plot_idx::Int)
    
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    xs_slices, us_slices = data_tuples
    is_eul = manager.mode[] == :eulerian

    base_idx = get_base_method_index(ui_app, active_methods)
    label = active_methods[base_idx]
    
    cache = is_eul ? EulerianPlotCache() : LagrangianPlotCache()
    if is_eul
        cache.obs_x.val = _unwrap_1tuples(xs_slices[base_idx])
        cache.obs_u.val = _unwrap_1tuples(us_slices[base_idx])
    else
        cache.obs_pts.val = _unwrap_1tuples(xs_slices[base_idx])
        cache.obs_u.val   = _unwrap_1tuples(us_slices[base_idx])
    end

    valid_u = filter(isfinite, cache.obs_u[])
    cr_obs = get_colorrange(ui_app, valid_u)
    raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false
    
    obs_coord = is_eul ? cache.obs_x : cache.obs_pts
    sc = scatter!(ax, obs_coord, cache.obs_u; color=cache.obs_u, colormap=ui_app[:color_map], colorrange=cr_obs, markersize=ui_app[:marker_size], marker=ui_app[:markers][1], rasterize=raster) 
    
    cache.primitives[:scatter_1d] = sc
    cache_dict[label] = cache
    create_or_update_colorbar!(plot_layout, sc, cr_obs, frontend_key(label), plot_idx)
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter_colors}, plot_idx::Int)
    
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    xs_slices, us_slices = data_tuples
    plotted_objects, labels_for_legend = [], String[]
    is_eul = manager.mode[] == :eulerian

    for (m_idx, label) in enumerate(active_methods)
        cache = is_eul ? EulerianPlotCache() : LagrangianPlotCache()
        if is_eul
            cache.obs_x.val = _unwrap_1tuples(xs_slices[m_idx])
            cache.obs_u.val = _unwrap_1tuples(us_slices[m_idx])
        else
            cache.obs_pts.val = _unwrap_1tuples(xs_slices[m_idx])
            cache.obs_u.val   = _unwrap_1tuples(us_slices[m_idx])
        end

        c   = Makie.to_color(ui_app[:colors][mod1(m_idx, end)])
        mrk = ui_app[:markers][mod1(m_idx, end)] 
        ms  = ui_app[:marker_size] 
        
        raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false

        obs_coord = is_eul ? cache.obs_x : cache.obs_pts
        s = scatter!(ax, obs_coord, cache.obs_u; color=c, markersize=ms, marker=mrk, rasterize=raster)
        
        
        cache.primitives[:scatter_colors] = s
        cache_dict[label] = cache
        
        push!(plotted_objects, [Makie.MarkerElement(color=c, marker=mrk, markersize=ms)])
        push!(labels_for_legend, frontend_key(label))
    end
end

function initialize_base_plot!(plot_layout::GridLayout, ax, active_methods, data_tuples, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter_lines}, plot_idx::Int)
    
    ui_app = manager.ui[:plot_style]
    cache_dict = manager.caches[plot_idx]
    xs_slices, us_slices = data_tuples
    plotted_objects, labels_for_legend = [], String[]
    is_eul = manager.mode[] == :eulerian

    for (m_idx, label) in enumerate(active_methods)
        cache = is_eul ? EulerianPlotCache() : LagrangianPlotCache()
        if is_eul
            cache.obs_x.val = _unwrap_1tuples(xs_slices[m_idx])
            cache.obs_u.val = _unwrap_1tuples(us_slices[m_idx])
        else
            cache.obs_pts.val = _unwrap_1tuples(xs_slices[m_idx])
            cache.obs_u.val   = _unwrap_1tuples(us_slices[m_idx])
        end
        
        c   = Makie.to_color(ui_app[:colors][mod1(m_idx, end)])
        ls  = ui_app[:dashed_lines] ? ui_app[:line_styles][mod1(m_idx, end)] : nothing 
        lw  = ui_app[:line_width] 
        mrk = ui_app[:markers][mod1(m_idx, end)] 
        ms  = ui_app[:marker_size] 
        raster = manager.ui[:export][:rasterization_enabled] ?  manager.ui[:export][:rasterization_quality] : false
        
        obs_coord = is_eul ? cache.obs_x : cache.obs_pts
        sl = scatterlines!(ax, obs_coord, cache.obs_u; color=c, linewidth=lw, linestyle=ls, markersize=ms, marker=mrk, rasterize=raster)
        
        cache.primitives[:scatter_lines] = sl
        cache_dict[label] = cache
        
        push!(plotted_objects, [Makie.LineElement(color=c, linewidth=lw, linestyle=ls), Makie.MarkerElement(color=c, marker=mrk, markersize=ms)])
        push!(labels_for_legend, frontend_key(label))
    end
end

initialize_base_plot!(kwargs...) = @warn "Could not find requested Plotting Style!"

# =============================================================================
# TIER 3 DATA INJECTION HELPERS (Perfectly Forked)
# =============================================================================
"""
    sync_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{D})

The high-performance data update gateway. 
When a user scrubs a slider (like time), this function bypasses the heavy initialization routines. It takes the freshly sliced `data_tuples`, identifies whether the target is a `LagrangianPlotCache` or an `EulerianPlotCache`, and delegates to the appropriate dimensionality dispatch `Val(D)` to overwrite the underlying Makie Observables in place.
"""
function sync_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{D}) where D
    first_cache = isempty(cache_dict) ? nothing : first(values(cache_dict))
    
    if first_cache isa LagrangianPlotCache
        pts_slices, us_slices = data_tuples
        for (m_idx, label) in enumerate(active_methods)
            haskey(cache_dict, label) || continue
            cache = cache_dict[label]
            
            cache.obs_pts.val = _unwrap_1tuples(pts_slices[m_idx])
            cache.obs_u.val   = _unwrap_1tuples(us_slices[m_idx])
            notify(cache.obs_u)
        end        
    elseif first_cache isa EulerianPlotCache
        _sync_eulerian_data_to_cache!(cache_dict, active_methods, data_tuples, Val(D))
    end
end

"""
    _sync_eulerian_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{1})

Mutates 1-dimensional Eulerian `Observable`s in place. Unwraps tuples and pushes new X/U arrays directly to the GPU.
"""
function _sync_eulerian_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{1})
    xs_slices, us_slices = data_tuples
    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        cache.obs_x.val = _unwrap_1tuples(xs_slices[m_idx])
        cache.obs_u.val = _unwrap_1tuples(us_slices[m_idx])
        notify(cache.obs_u)
    end
end

"""
    _sync_eulerian_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{2})

Mutates 2-dimensional Eulerian `Observable`s. Intelligently checks the primitive type stored in the cache; if the plot is utilizing the `NaN` separator trick (`:lines_2d`), it recompiles the flat 1D grid before notifying the observers.
"""
function _sync_eulerian_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{2})
    
    xs_slices, ys_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]
    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        if haskey(cache.primitives, :lines_2d)
            dir = get(ui_app, :line_direction, :horizontal) 
            X, Y, U = build_2d_lines_grid(xs_slices[m_idx], ys_slices[m_idx], us_slices[m_idx], dir)
            cache.obs_x.val = X
            cache.obs_y.val = Y
            cache.obs_u.val = U
        else
            cache.obs_x.val = xs_slices[m_idx]
            cache.obs_y.val = ys_slices[m_idx]
            cache.obs_u.val = us_slices[m_idx]
        end
        notify(cache.obs_u)
    end
end

"""
    _sync_eulerian_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{3})

Mutates 3-dimensional Eulerian `Observable`s. Handles both dense volume grids and sparse `NaN`-separated line projections (`:lines_3d`) based on the cached primitive type.
"""
function _sync_eulerian_data_to_cache!(cache_dict, active_methods, data_tuples, ::Val{3})
    
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    ui_app = manager.ui[:plot_style]

    for (m_idx, label) in enumerate(active_methods)
        haskey(cache_dict, label) || continue
        cache = cache_dict[label]
        
        if haskey(cache.primitives, :lines_3d)
            dir = get(ui_app, :line_direction, :horizontal) 
            X, Y, Z, U = build_3d_lines_grid(xs_slices[m_idx], ys_slices[m_idx], zs_slices[m_idx], us_slices[m_idx], dir)
            cache.obs_x.val = X
            cache.obs_y.val = Y
            cache.obs_z.val = Z
            cache.obs_u.val = U
        else
            cache.obs_x.val = extrema(xs_slices[m_idx])
            cache.obs_y.val = extrema(ys_slices[m_idx])
            cache.obs_z.val = extrema(zs_slices[m_idx])
            cache.obs_u.val = us_slices[m_idx]
        end
        notify(cache.obs_u)
    end
end