
# Dispatched Plotter
function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:lines})
    xs_slices, us_slices = data_tuples
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    plotted_objects, labels_for_legend = [], String[]
    
    for (plot_idx, label) in enumerate(active_methods)
        # Cycle through colors and markers
        color = ui_app["colors"][][mod1(plot_idx, end)]
        marker = ui_app["markers"][][mod1(plot_idx, end)]
        
        # Apply dashed lines only if the toggle is true, otherwise force solid
        linestyle = ui_app["dashed_lines"][] ? ui_app["lineStyles"][][mod1(plot_idx, end)] : :solid
        
        # We group the plots for this method so the legend can combine them
        group_plots = []
        
        # 1. Plot Lines
        if ui_app["show_lines"][]
            l = lines!(ax, xs_slices[plot_idx], us_slices[plot_idx]; 
                color=color, linewidth=ui_app["linewidth"][], linestyle=linestyle)
            push!(group_plots, l)
        end
        
        # 2. Plot Scatter Markers
        if ui_app["show_scatter"][]
            s = scatter!(ax, xs_slices[plot_idx], us_slices[plot_idx]; 
                color=color, markersize=ui_app["markersize"][], marker=marker)
            push!(group_plots, s)
        end

        # Ensure we actually drew something to prevent legend crashes
        if !isempty(group_plots)
            push!(plotted_objects, group_plots)
            push!(labels_for_legend, label)
        end
        
        # Extrema Tracking (Max/Min lines)
        plot_extrema_lines_manager!(ax, xs_slices[plot_idx], us_slices[plot_idx], manager, plot_idx)
    end

    # --- Feature: Sort Legend ---
    if manager.ui["Axis-General"]["sort_legend"][]
        sort_idx = sortperm(labels_for_legend)
        plotted_objects = plotted_objects[sort_idx]
        labels_for_legend = labels_for_legend[sort_idx]
    end

    # Apply standard styling and limits
    set_axis_styles!(ax, manager, x_key, u_key, title_str)
    set_axis_limits_manager!(ax, xs_slices, us_slices, manager)
    plot_reference_lines!(ax,ui_app["reference"][])
    create_or_update_legend!(plot_fig, plotted_objects, labels_for_legend, manager)
end

function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:heatmap})
    xs, ys, us = data_tuples
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    x_data, y_data, u_data = xs[1], ys[1], us[1]
    valid_u = filter(isfinite, u_data)

    cr_obs = get_colorrange(ui_app, valid_u)

    hm = heatmap!(ax, x_data, y_data, u_data; colormap=ui_app["colormap"][], colorrange=cr_obs)

    set_axis_styles!(ax, manager, x_key, y_key, title_str)
    
    valid_x = filter(isfinite, x_data)
    valid_y = filter(isfinite, y_data)
    
    # Only update limits if there is actually valid coordinate data
    if !isempty(valid_x)
        xlims!(ax, extrema(valid_x)...)
    end
    if !isempty(valid_y)
        ylims!(ax, extrema(valid_y)...)
    end

    create_or_update_colorbar!(plot_fig, hm, manager, cr_obs, active_methods[1])
end

function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter2d})
    xs_slices, ys_slices, us_slices = data_tuples
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    # Only plot the base method for scatter to avoid massive point overlap
    x_data, y_data, u_data = xs_slices[1], ys_slices[1], us_slices[1]
    
    # Meshgrid broadcast X and Y vectors to match the U matrix
    X_grid = vec([x for x in x_data, y in y_data])
    Y_grid = vec([y for x in x_data, y in y_data])
    U_flat = vec(u_data)

    valid_u = filter(isfinite, U_flat)
    cr_obs = get_colorrange(ui_app, valid_u)

    sc = scatter!(ax, X_grid, Y_grid; 
        color=U_flat, 
        colormap=ui_app["colormap"][], 
        colorrange=cr_obs, 
        markersize=ui_app["markersize"][],
        marker=ui_app["markers"][][1]
    )

    set_axis_styles!(ax, manager, x_key, y_key, title_str)
    
    valid_x = filter(isfinite, x_data)
    valid_y = filter(isfinite, y_data)
    
    # Only update limits if there is actually valid coordinate data
    if !isempty(valid_x)
        xlims!(ax, extrema(valid_x)...)
    end
    if !isempty(valid_y)
        ylims!(ax, extrema(valid_y)...)
    end

    create_or_update_colorbar!(plot_fig, sc, manager, cr_obs, active_methods[1])
end
function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:contour})
    xs_slices, ys_slices, us_slices = data_tuples
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    plotted_objects, labels_for_legend = [], String[]

    for (plot_idx, label) in enumerate(active_methods)
        color = ui_app["colors"][][mod1(plot_idx, end)]
        lw = ui_app["linewidth"][]
        
        contour!(ax, xs_slices[plot_idx], ys_slices[plot_idx], us_slices[plot_idx]; 
            levels=ui_app["levels"][], 
            color=color, 
            linewidth=lw, 
            labels=true
        )
        
        # THE FIX: Force the legend to use a perfect colored line proxy!
        push!(plotted_objects, Makie.LineElement(color=color, linewidth=lw))
        push!(labels_for_legend, label)
    end

    set_axis_styles!(ax, manager, x_key, y_key, title_str)
    
    valid_x = filter(isfinite, xs_slices[1])
    valid_y = filter(isfinite, ys_slices[1])
    if !isempty(valid_x); xlims!(ax, extrema(valid_x)...); end
    if !isempty(valid_y); ylims!(ax, extrema(valid_y)...); end
    
    create_or_update_legend!(plot_fig, plotted_objects, labels_for_legend, manager)
end

function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:contourf})
    xs_slices, ys_slices, us_slices = data_tuples
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    raw_idx = get(ui_app, "base_method_idx", Ref(1))[]
    base_idx = clamp(raw_idx, 1, length(active_methods))

    x_data, y_data, u_data = xs_slices[base_idx], ys_slices[base_idx], us_slices[base_idx]
    
    valid_u = filter(isfinite, u_data)
    cr_obs = get_colorrange(ui_app, valid_u)
    l_u, h_u = cr_obs[]

    plotted_objects, labels_for_legend = [], String[]

    lvl_count = ui_app["levels"][]
    lvl_range = range(l_u, h_u, length=lvl_count)

    cf = contourf!(ax, x_data, y_data, u_data; 
        colormap=ui_app["colormap"][], 
        levels=lvl_range 
    )
    
    # THE FIX: Convert the Symbol to an array of colors before grabbing the last one, and wrap in [ ]
    base_color = Makie.to_colormap(ui_app["colormap"][])[end]
    push!(plotted_objects, [Makie.PolyElement(color=base_color)])
    push!(labels_for_legend, "$(active_methods[base_idx]) (Base)")

    for i in 1:length(active_methods)
        if i == base_idx; continue; end
        
        color = ui_app["colors"][][mod1(i, end)]
        lw = ui_app["linewidth"][]
        
        contour!(ax, xs_slices[i], ys_slices[i], us_slices[i]; 
            color=color, 
            linewidth=lw, 
            labels=true
        )
        # THE FIX: Wrap the LineElement in an array [ ]
        push!(plotted_objects, [Makie.LineElement(color=color, linewidth=lw)])
        push!(labels_for_legend, active_methods[i])
    end

    set_axis_styles!(ax, manager, x_key, y_key, title_str)
    
    valid_x = filter(isfinite, x_data)
    valid_y = filter(isfinite, y_data)
    if !isempty(valid_x); xlims!(ax, extrema(valid_x)...); end
    if !isempty(valid_y); ylims!(ax, extrema(valid_y)...); end
    
    create_or_update_legend!(plot_fig, plotted_objects, labels_for_legend, manager)
    create_or_update_colorbar!(plot_fig, cf, manager, cr_obs, active_methods[base_idx])
end

function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:scatter3d})
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    # Base plot only (to avoid overlapping thousands of 3D points)
    x_data, y_data, z_data, u_data = xs_slices[1], ys_slices[1], zs_slices[1], us_slices[1]
    
    # Meshgrid broadcast X, Y, and Z vectors to match the 3D U matrix
    X_grid = vec([x for x in x_data, y in y_data, z in z_data])
    Y_grid = vec([y for x in x_data, y in y_data, z in z_data])
    Z_grid = vec([z for x in x_data, y in y_data, z in z_data])
    U_flat = vec(u_data)

    valid_u = filter(isfinite, U_flat)
    cr_obs = get_colorrange(ui_app, valid_u)

    sc = scatter!(ax, X_grid, Y_grid, Z_grid; 
        color=U_flat, 
        colormap=ui_app["colormap"][], 
        colorrange=cr_obs, 
        markersize=ui_app["markersize"][],
        marker=ui_app["markers"][][1]
    )

    set_axis_styles!(ax, manager, x_key, y_key, z_key, title_str)
    create_or_update_colorbar!(plot_fig, sc, manager, cr_obs, active_methods[1])
end

function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:surface})
    # Notice we unpack 3 items because PLOT_DIM_MAP[:surface] == 2
    xs_slices, ys_slices, us_slices = data_tuples 
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    x_data, y_data, u_data = xs_slices[1], ys_slices[1], us_slices[1]
    
    valid_u = filter(isfinite, u_data)
    cr_obs = get_colorrange(ui_app, valid_u)

    sf = surface!(ax, x_data, y_data, u_data; 
        colormap=ui_app["colormap"][], 
        colorrange=cr_obs
    )

    # We dynamically pass `u_key` as the Z-axis label because the Z height IS the U variable!
    set_axis_styles!(ax, manager, x_key, y_key, u_key, title_str)
    create_or_update_colorbar!(plot_fig, sf, manager, cr_obs, active_methods[1])
end

function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:contour3d})
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    for (plot_idx, label) in enumerate(active_methods)
        color = ui_app["colors"][][mod1(plot_idx, end)]
        
        # THE FIX: Just pass the 1D vectors directly! Makie handles the meshgrid natively.
        contour!(ax, 
            extrema(xs_slices[plot_idx]), 
            extrema(ys_slices[plot_idx]), 
            extrema(zs_slices[plot_idx]), 
            us_slices[plot_idx]; 
            levels=ui_app["levels"][], 
            color=color, 
            alpha=0.5 
        )
    end
    set_axis_styles!(ax, manager, x_key, y_key, z_key, title_str)
end

function update_base_plot!(plot_fig, ax, active_methods, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, ::Val{:volume})
    xs_slices, ys_slices, zs_slices, us_slices = data_tuples
    
    empty!(ax); isempty(active_methods) && return
    ui_app = manager.ui["Plot-Style"]

    x_data, y_data, z_data, u_data = xs_slices[1], ys_slices[1], zs_slices[1], us_slices[1]
    
    valid_u = filter(isfinite, u_data)
    cr_obs = get_colorrange(ui_app, valid_u)

    # THE FIX: Just pass the 1D vectors directly!
    vol = volume!(ax, extrema(x_data), extrema(y_data), extrema(z_data), u_data; 
        colormap=ui_app["colormap"][], 
        colorrange=cr_obs
    )

    set_axis_styles!(ax, manager, x_key, y_key, z_key, title_str)
    create_or_update_colorbar!(plot_fig, vol, manager, cr_obs, active_methods[1])
end