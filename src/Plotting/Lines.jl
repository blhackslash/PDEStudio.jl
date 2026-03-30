# --- 1D LINES SETUP ---
function setup_render_lift!(plot_fig::Figure, plot_data_obs::Observable, manager::PlotManager, ::Val{:lines})
    ax = Axis(plot_fig[1, 1])
    c = manager.controls
    dim_names = manager.plot_vars 

    selector_obs = Observable[]
    for name in dim_names
        if haskey(c, "$(name)_Value"); push!(selector_obs, c["$(name)_Value"])
        elseif haskey(c, "$(name)_Selection"); push!(selector_obs, c["$(name)_Selection"])
        end
    end

    render_obs = onany(plot_data_obs, c["X-Axis_Selection"], c["U-Axis_Selection"], 
                       c["UI_Update"], selector_obs...) do data, x_key, u_key, _ui, sel_vals...
        
        if isnothing(x_key) || isnothing(u_key) || x_key == "-" || u_key == "-"; return; end
        isempty(data) && return
        
        x_dim_idx = findfirst(isequal(x_key), dim_names)
        
        active_methods = manager.methods[]
        xs_to_plot, us_to_plot, valid_labels = Vector{Float64}[], Vector{Float64}[], String[]

        for m_name in active_methods
            !haskey(data, m_name) && continue
            pd = data[m_name]
            x_tensor = get(pd.data, x_key, nothing)
            u_tensor = get(pd.data, u_key, nothing)
            (isnothing(x_tensor) || isnothing(u_tensor)) && continue
            
            # Slicing: X is the free dimension (:)
            slice_indices = map(1:ndims(u_tensor)) do i
                if i == x_dim_idx; return (:); end
                val = sel_vals[i] isa String ? parse(Int, sel_vals[i]) : sel_vals[i]
                return min(find_closest_index_for_dim(pd, i, val, ndims(u_tensor)-5), size(u_tensor, i))
            end
            
            try
                push!(xs_to_plot, vec(x_tensor[slice_indices...]))
                push!(us_to_plot, vec(u_tensor[slice_indices...]))
                push!(valid_labels, m_name)
            catch e; @warn "Slicing failed for $m_name" exception=e; end
        end

        title_str = generate_dynamic_title(x_dim_idx, dim_names, sel_vals)
        update_base_plot_lines!(plot_fig, ax, valid_labels, xs_to_plot, us_to_plot, manager, x_key, u_key, title_str)
    end
    return [render_obs]
end

function update_base_plot_lines!(plot_fig, ax, active_methods, xs_slices, us_slices, manager, xlabel, ylabel, title_str)
    # 1. Merge the referenced UI scopes
    ui_axis = merge(manager.ui["Axis-General"], manager.ui["X-Axis"], manager.ui["Y-Axis"], manager.ui["Labels"])
    ui_app  = manager.ui["Plot-Style"] # Maps to Style-Lines
    ui_var  = manager.ui["Various"]

    resize!(plot_fig, ui_axis["figsize"][][1], ui_axis["figsize"][][2])
    empty!(ax)
    isempty(active_methods) && return

    # 2. Plotting
    plotted_objects, labels_for_legend = [], String[]
    for (plot_idx, label) in enumerate(active_methods)
        x_data, u_data = xs_slices[plot_idx], us_slices[plot_idx]
        
        color = ui_app["colors"][][mod1(plot_idx, end)]
        linestyle = ui_app["lineStyles"][][mod1(plot_idx, end)]
        
        l = lines!(ax, x_data, u_data; color=color, linewidth=ui_app["linewidth"][], linestyle=linestyle, label=label)
        
        push!(plotted_objects, [l])
        push!(labels_for_legend, label)
    end

    # 3. Styling
    ax.xlabel = ui_axis["xlabel"][] == "default" ? xlabel : ui_axis["xlabel"][]
    ax.ylabel = ui_axis["ylabel"][] == "default" ? ylabel : ui_axis["ylabel"][]
    ax.title  = ui_axis["title"][] == "default" ? title_str : ui_axis["title"][]
    
    set_axis_limits_manager!(ax, xs_slices, us_slices, manager) # Use your PlottingUtils function
    create_or_update_legend!(plot_fig, plotted_objects, labels_for_legend, manager)
end