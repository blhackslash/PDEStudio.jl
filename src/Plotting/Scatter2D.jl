

# --- 2D SCATTER SETUP ---
function setup_render_lift!(plot_fig::Figure, plot_data_obs::Observable, manager::PlotManager, ::Val{:scatter2d})
    ax = Axis(plot_fig[1, 1])
    c = manager.controls
    dim_names = manager.plot_vars 

    selector_obs = Observable[]
    for name in dim_names
        if haskey(c, "$(name)_Value"); push!(selector_obs, c["$(name)_Value"])
        elseif haskey(c, "$(name)_Selection"); push!(selector_obs, c["$(name)_Selection"])
        end
    end

    render_obs = onany(plot_data_obs, c["X-Axis_Selection"], c["Y-Axis_Selection"], c["U-Axis_Selection"], 
                       c["UI_Update"], selector_obs...) do data, x_key, y_key, u_key, _ui, sel_vals...
        
        if isnothing(x_key) || isnothing(y_key) || isnothing(u_key) || x_key == "-" || y_key == "-" || u_key == "-"; return; end
        isempty(data) && return
        
        x_dim_idx = findfirst(isequal(x_key), dim_names)
        y_dim_idx = findfirst(isequal(y_key), dim_names)

        active_methods = manager.methods[]
        xs_to_plot, ys_to_plot, us_to_plot, valid_labels = Vector{Float64}[], Vector{Float64}[], Vector{Float64}[], String[]

        for m_name in active_methods
            !haskey(data, m_name) && continue
            pd = data[m_name]
            x_tensor, y_tensor, u_tensor = get(pd.data, x_key, nothing), get(pd.data, y_key, nothing), get(pd.data, u_key, nothing)
            (isnothing(x_tensor) || isnothing(y_tensor) || isnothing(u_tensor)) && continue
            
            # For scatter, we want to extract the full 2D slice for U, 
            # and broadcast X and Y to match the grid so every point has an (x,y) pair.
            slice_idx = map(i -> (i == x_dim_idx || i == y_dim_idx) ? (:) : min(find_closest_index_for_dim(pd, i, sel_vals[i] isa String ? parse(Int, sel_vals[i]) : sel_vals[i], ndims(u_tensor)-5), size(u_tensor, i)), 1:ndims(u_tensor))
            
            try
                u_mat = u_tensor[slice_idx...]
                x_vec_1d = vec(x_tensor[map(i -> i == x_dim_idx ? (:) : slice_idx[i], 1:ndims(x_tensor))...])
                y_vec_1d = vec(y_tensor[map(i -> i == y_dim_idx ? (:) : slice_idx[i], 1:ndims(y_tensor))...])
                
                # Create coordinate grids
                X_grid = [x for x in x_vec_1d, y in y_vec_1d]
                Y_grid = [y for x in x_vec_1d, y in y_vec_1d]
                
                if x_dim_idx > y_dim_idx
                    u_mat = transpose(u_mat) |> collect
                end

                # Flatten everything for scatter!
                push!(xs_to_plot, vec(X_grid))
                push!(ys_to_plot, vec(Y_grid))
                push!(us_to_plot, vec(u_mat))
                push!(valid_labels, m_name)
            catch e; @warn "Slicing failed" exception=e; end
        end

        title_str = generate_dynamic_title(x_dim_idx, dim_names, sel_vals)
        update_base_plot_scatter2d!(plot_fig, ax, valid_labels, xs_to_plot, ys_to_plot, us_to_plot, manager, x_key, y_key, title_str)
    end
    return [render_obs]
end

function update_base_plot_scatter2d!(plot_fig, ax, active_methods, xs, ys, us, manager, xlabel, ylabel, title_str)
    ui_merged = merge(manager.ui["Axis-General"], manager.ui["X-Axis"], manager.ui["Y-Axis"], manager.ui["Labels"], manager.ui["Plot-Style"])
    
    empty!(ax)
    isempty(active_methods) && return

    # Plot the scatter with color mapped to U
    x_data, y_data, u_data = xs[1], ys[1], us[1]
    
    valid_u = filter(isfinite, u_data)
    l_u, h_u = isempty(valid_u) ? (0.0, 1.0) : (minimum(valid_u), maximum(valid_u))
    if l_u == h_u; h_u += 1e-6; end
    cr_obs = Observable((l_u, h_u))

    sc = scatter!(ax, x_data, y_data; 
        color=u_data, 
        colormap=ui_merged["colormap"][], 
        colorrange=cr_obs, 
        markersize=ui_merged["markersize"][],
        marker=ui_merged["markers"][][1]
    )

    # Styling
    ax.xlabel = ui_merged["xlabel"][] == "default" ? xlabel : ui_merged["xlabel"][]
    ax.ylabel = ui_merged["ylabel"][] == "default" ? ylabel : ui_merged["ylabel"][]
    ax.title  = ui_merged["title"][] == "default" ? title_str : ui_merged["title"][]
    
    xlims!(ax, extrema(filter(isfinite, x_data))...)
    ylims!(ax, extrema(filter(isfinite, y_data))...)

    create_or_update_colorbar!(plot_fig, sc, ui_merged, cr_obs, active_methods[1])
end