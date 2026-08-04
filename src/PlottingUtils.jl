function allMethodNames(config::SimulationConfig)
    return sort_methods_robust(collect(keys(config.methods_dict)))
end

# =============================================================================
# THE FIX: Robust Priority Sorting
# =============================================================================
function sort_methods_robust(methods::Vector{Symbol})
    priority_keys = ["analytic", "reference", "exact", "baseline", "true"]
    
    function method_rank(m::String)
        lm = lowercase(m)
        rank = any(k -> occursin(k, lm), priority_keys) ? 0 : 1
        return (rank, m)
    end
    
    return Symbol.(sort(String.(methods), by=method_rank))
end

"""
    generate_dynamic_title(plot_dims::Tuple, dim_names::Vector{Symbol}, sel_vals, sim_data)
"""
function generate_dynamic_title(
    plot_dims::Tuple, 
    dim_names::Vector{Symbol}, 
    sel_vals,
    sim_data::Union{Nothing, AbstractSimData} = nothing
)
    title_parts = String[]
    base_vars = get_base_variables() # Gets (:x, :y, :z, :t)
    
    for i in 1:length(dim_names)
        name_sym = dim_names[i]
        
        # Skip base variables that do not physically exist in this simulation
        if !isnothing(sim_data) && (name_sym in base_vars) && !(name_sym in sim_data.domain.dim_keys)
            continue
        end
        
        name = titlecase(string(name_sym))
        
        if i in plot_dims
            push!(title_parts, "$name = [Axis]")
        else
            val = sel_vals[i]
            val_str = val isa AbstractFloat ? @sprintf("%.3f", val) : string(val)
            push!(title_parts, "$name = $val_str")
        end
    end
    
    return join(title_parts, " | ")
end


function plot_reference_lines!(
    ax::Axis,
    exponents::Vector;
    label::String = "Reference Lines",
    color = :black,
    line_style = :dash,
    kwargs...
)
    if isnothing(exponents) || isempty(exponents); return []; end

    plotted_lines = []
    for p_signed in exponents
        if p_signed == 0; continue; end
        
        pts = lift(ax.finallimits, ax.xscale, ax.yscale) do lims, xscl, yscl
            xmin, xmax = lims.origin[1], lims.origin[1] + lims.widths[1]
            ymin, ymax = lims.origin[2], lims.origin[2] + lims.widths[2]
            
            xmin = max(1e-12, xmin)
            xmax = max(1e-11, max(xmax, xmin + 1e-11))
            ymin = max(1e-12, ymin)
            ymax = max(1e-11, max(ymax, ymin + 1e-11))
            
            if xmin >= xmax || ymin >= ymax
                return [Point2f(1.0, 1.0), Point2f(10.0, 10.0)]
            end
            
            xs = xscl == log10 ? (10 .^ range(log10(xmin), log10(xmax), length=100)) : collect(range(xmin, xmax, length=100))
            
            y_anchor = p_signed > 0 ? ymin : ymax
            ref_x = xs[1]
            C = ref_x > 0 ? (y_anchor / (ref_x^p_signed)) : 0.0
            ys = C .* (xs .^ p_signed)
            
            return Point2f.(xs, ys)
        end
        
        l = lines!(ax, pts; color=color, linestyle=line_style, label=label, kwargs...)
        push!(plotted_lines, l)
    end
    return plotted_lines
end

"""
    get_colorrange(ui_app::Dict, u_data::AbstractArray)

Extracts the colorrange from the UI dict, or calculates it dynamically from the data 
if set to "default". Always returns an Observable Tuple of Float64 so it can bind to Makie.
"""
function get_colorrange(ui_app::Dict, u_data::AbstractArray)
    cr_val = ui_app[:color_range] 
    
    if isempty(cr_val)
        valid_u = filter(isfinite, vec(u_data))
        l_u, h_u = isempty(valid_u) ? (0.0, 1.0) : (minimum(valid_u), maximum(valid_u))
        if l_u == h_u; h_u += 1e-6; end
        return Observable((l_u, h_u))
    else
        return Observable(Tuple(Float64.(cr_val)))
    end
end

function apply_axis_limits_overrides!(ax)
    
    if get(manager.state, :Camera_Locked, Observable(false))[]
        return
    end
    ui_x = manager.ui[:x_axis]
    ui_y = manager.ui[:y_axis]
    
    try
        if haskey(ui_x, :lims) && length(ui_x[:lims]) == 2 
            lx = Float64.(ui_x[:lims])
            if lx[1] < lx[2]; xlims!(ax, lx[1], lx[2]); end
        end
        
        if haskey(ui_y, :lims) && length(ui_y[:lims]) == 2 
            ly = Float64.(ui_y[:lims])
            if ly[1] < ly[2]; ylims!(ax, ly[1], ly[2]); end
        end
        
        if ax isa Axis3 && haskey(manager.ui, :z_axis)
            ui_z = manager.ui[:z_axis]
            if haskey(ui_z, :lims) && length(ui_z[:lims]) == 2 
                lz = Float64.(ui_z[:lims])
                if lz[1] < lz[2]; zlims!(ax, lz[1], lz[2]); end
            end
        end
    catch
        @warn "Failed to apply manual axis limits. Please ensure the input is a 2-element vector like [-5.0, 5.0]."
    end
end

function delete_plots_by_label!(ax::Axis, label_to_delete::String)
    plots_to_delete = [p for p in ax.scene.plots if haskey(p,:label) && p.label[] == label_to_delete]
    
    if !isempty(plots_to_delete)
        for p in plots_to_delete
            delete!(ax.scene, p)
        end
        return true
    end
    return false
end

function set_axis_limits_manager!(ax::Axis, xs, us)
    
    ui_x = manager.ui[:x_axis]
    ui_y = manager.ui[:y_axis]
    
    raw_xlims = _safe_extrema(xs)
    raw_ylims = _safe_extrema(us)

    use_log_x = ui_x[:log_scale] 
    use_log_y = ui_y[:log_scale] 

    if raw_xlims[1] <= 0 && use_log_x
        use_log_x = false
        @warn "X-Axis data contains non-positive values. log_scale temporarily disabled."
    end
    if raw_ylims[1] <= 0 && use_log_y
        use_log_y = false
        @warn "Y-Axis data contains non-positive values. log_scale temporarily disabled."
    end

    new_xscale = use_log_x ? log10 : identity
    new_yscale = use_log_y ? log10 : identity

    # FIX: Calculate and apply the valid padded limits BEFORE changing the scale!
    is_locked = get(manager.state, :Camera_Locked, Observable(false))[]
    
    if !is_locked
        final_xlims = calculate_padded_axis_range(raw_xlims, ui_x[:padding], use_log_x) 
        final_ylims = calculate_padded_axis_range(raw_ylims, ui_y[:padding], use_log_y) 
        try limits!(ax, final_xlims..., final_ylims...) catch; end
    else
        # Safety net: If camera is locked but the current limits are invalid for a log scale, 
        # force an override to prevent a hard Makie crash.
        curr_lims = ax.finallimits[]
        if (use_log_x && curr_lims.origin[1] <= 0) || (use_log_y && curr_lims.origin[2] <= 0)
            final_xlims = calculate_padded_axis_range(raw_xlims, ui_x[:padding], use_log_x) 
            final_ylims = calculate_padded_axis_range(raw_ylims, ui_y[:padding], use_log_y) 
            try limits!(ax, final_xlims..., final_ylims...) catch; end
        end
    end

    # NOW update the scales safely
    if ax.xscale[] !== new_xscale; ax.xscale[] = new_xscale; end
    if ax.yscale[] !== new_yscale; ax.yscale[] = new_yscale; end

    return
end

function calculate_layout_dictionary(num_plots::Int, cols_req::Int, link_mode::Symbol, has_legend::Bool, is_detached::Bool, halign::Symbol, valign::Symbol, has_colorbar::Bool)
    cols = min(num_plots, cols_req)
    rows = ceil(Int, num_plots / cols)
    
    layout_dict = Dict{Symbol, Any}()
    layout_dict[:Plots] = Vector{Tuple{Any, Any}}(undef, num_plots)
    layout_dict[:Colorbars] = Vector{Tuple{Any, Any}}()
    layout_dict[:Legend] = nothing
    
    row_offset = (has_legend && is_detached && valign == :top) ? 1 : 0
    col_offset = (has_legend && is_detached && halign == :left) ? 1 : 0

    if link_mode in (:decoupled, :axes_only) && has_colorbar
        for i in 1:num_plots
            r = (i - 1) ÷ cols + 1
            c = (i - 1) % cols + 1
            
            p_row = r + row_offset
            p_col = (2 * c - 1) + col_offset
            cb_col = (2 * c) + col_offset
            
            layout_dict[:Plots][i] = (p_row, p_col)
            push!(layout_dict[:Colorbars], (p_row, cb_col))
        end
        max_core_col = 2 * cols + col_offset
        max_core_row = rows + row_offset
    else
        for i in 1:num_plots
            r = (i - 1) ÷ cols + 1
            c = (i - 1) % cols + 1
            
            p_row = r + row_offset
            p_col = c + col_offset
            
            layout_dict[:Plots][i] = (p_row, p_col)
        end
        max_core_col = cols + col_offset
        max_core_row = rows + row_offset
        
        if has_colorbar
            cb_col = max_core_col + 1
            max_core_col += 1
            push!(layout_dict[:Colorbars], (1 + row_offset : rows + row_offset, cb_col))
        end
    end
    
    if has_legend
        if is_detached
            if valign == :top
                layout_dict[:Legend] = (1, 1:max_core_col)
            elseif valign == :bottom
                layout_dict[:Legend] = (max_core_row + 1, 1:max_core_col)
            elseif halign == :left
                layout_dict[:Legend] = (1+row_offset : max_core_row, 1)
            else 
                layout_dict[:Legend] = (1+row_offset : max_core_row, max_core_col + 1)
            end
        else
            layout_dict[:Legend] = layout_dict[:Plots][1]
        end
    end
    return layout_dict
end

function _parse_legend_position()
    
    base_align = manager.widgets[:legend_base].selection[]
    add_align  = manager.widgets[:legend_add].selection[]
    
    # Check for :none directly
    if base_align == :none || add_align == :none
        return (false, :none, :none)
    end
    
    is_detached = (add_align == :detached)
    
    # Safely retrieve the comparison target from the global state 
    # (fallback to the widget if the state hasn't been initialized yet)
    target = haskey(manager.state, :Compare_State) ? manager.state[:Compare_State][1] : manager.widgets[:compare_target].selection[]
    
    # Force a detached top-center legend for comparisons (apart from :Methods)
    if target != :None && target != :Methods && !is_detached
        return (true, :center, :top)
    end
    
    # Resolve vertical alignment
    valign = (:top in (base_align, add_align)) ? :top : 
             (:bottom in (base_align, add_align) ? :bottom : :center)
             
    # Resolve horizontal alignment
    halign = (:left in (base_align, add_align)) ? :left : 
             (:right in (base_align, add_align) ? :right : :center)

    return (is_detached, halign, valign)
end

function create_or_update_legend!(plot_layout::GridLayout, plotted_objects::Vector, labels::Vector)
    
    for c in copy(plot_layout.content)
        if c.content isa Makie.Legend; delete!(c.content); end
    end
    
    if isempty(plotted_objects) || isempty(labels); return; end
    
    layout_dict = manager.state[:Layout_Dict][]
    if !haskey(layout_dict, :Legend) || isnothing(layout_dict[:Legend]); return; end
    
    ui_style = manager.ui[:axis_general]
    title_str = manager.ui[:labels][:legend_label] 
    final_title = isempty(strip(title_str)) ? nothing : title_str
    font_size = ui_style[:font_size] 
    
    is_detached, halign, valign = _parse_legend_position()

    if halign==:none && valign==:none; return; end
    leg_pos = layout_dict[:Legend]

    try
        if is_detached
            orientation = (valign == :top || valign == :bottom) ? :horizontal : :vertical
            tw = orientation == :vertical
            th = !tw 
            Legend(plot_layout[leg_pos...], plotted_objects, labels, final_title;
                orientation=orientation, tellheight=th, tellwidth=tw, merge=true, unique=true,
                titlesize=font_size, labelsize=font_size)
        else
            Legend(plot_layout[leg_pos...], plotted_objects, labels, final_title;
                orientation=:vertical, tellheight=false, tellwidth=false,
                halign=halign, valign=valign, merge=true, unique=true,
                titlesize=font_size, labelsize=font_size, margin=(10, 10, 10, 10)
            )
        end
    catch e
        @error "Failed to create legend" exception=(e, catch_backtrace())
    end
end

function create_or_update_colorbar!(plot_layout::GridLayout, plot_object, color_range_obs, default_label::String, plot_idx::Int=1)
    
    ui_stl = manager.ui[:plot_style]
    if !haskey(ui_stl, :color_map); return; end 
    safe_limits = color_range_obs isa Tuple ? color_range_obs : lift(cr -> (Float64(cr[1]), Float64(cr[2])), color_range_obs)
    layout_dict = manager.state[:Layout_Dict][]
    cb_list = layout_dict[:Colorbars]
    isempty(cb_list) && return
    
    is_global = length(cb_list) == 1
    
    if is_global && plot_idx > 1; return; end
    
    if plot_idx == 1
        for c in copy(plot_layout.content)
            if c.content isa Makie.Colorbar; delete!(c.content); end
        end
    end
    
    cb_pos = is_global ? cb_list[1] : cb_list[plot_idx]
    
    ui_lbl = manager.ui[:labels]
    ui_gen = manager.ui[:axis_general]
    final_label = ui_lbl[:colorbar_label] == "default" ? default_label : ui_lbl[:colorbar_label] 
    
    try
        Colorbar(plot_layout[cb_pos...];
            colormap = ui_stl[:color_map], 
            limits = safe_limits,
            label = final_label,
            labelsize = ui_gen[:label_size], 
            ticklabelsize = ui_gen[:ticklabel_size] 
        )
    catch e
        @error "Failed to create colorbar." exception=(e, catch_backtrace())
    end
end

function calculate_padded_axis_range(raw_limits::Tuple, padding_factor::Real, is_log_scale::Bool)
    min_raw, max_raw = raw_limits
    if isnothing(min_raw) || isnothing(max_raw) || !isfinite(min_raw) || !isfinite(max_raw)
        return is_log_scale ? (0.1, 1.0) : (0.0, 1.0)
    end

    if is_log_scale && min_raw > 0
        log_min, log_max = log10(min_raw), log10(max_raw)
        log_range = max(log_max - log_min, 0.1) 
        pad = log_range * padding_factor / 2.0
        return (10^(log_min - pad), 10^(log_max + pad))
    else
        data_range = max_raw - min_raw
        pad = data_range ≈ 0 ? 0.1 : (data_range * padding_factor / 2.0)
        return (min_raw - pad, max_raw + pad)
    end
end

function _safe_extrema(data_slices)
    mins, maxs = Float64[], Float64[]
    for slice in data_slices
        valid_data = filter(isfinite, slice)
        if !isempty(valid_data)
            push!(mins, minimum(valid_data))
            push!(maxs, maximum(valid_data))
        end
    end
    isempty(mins) && return (0.0, 1.0)
    return (minimum(mins), maximum(maxs))
end

function plot_extrema_lines_manager!(ax::Axis, data_tuples, valid_methods, is_3d_axis)
    # Clear old extrema lines
    delete_plots_by_label!(ax, "Extrema_Max")
    delete_plots_by_label!(ax, "Extrema_Min")
    
    is_3d_axis && return
    
    ui_ext = get(manager.ui, :outliers_extrema, Dict())
    track_max = get(ui_ext, :track_max, false)
    track_min = get(ui_ext, :track_min, false)
    (!track_max && !track_min) && return

    ui_stl = manager.ui[:plot_style]
    colors = get(ui_stl, :colors, [:black])
    lw = haskey(ui_stl, :line_width) ? (ui_stl[:line_width] / 2) : 2.0 

    if length(data_tuples) >= 2 
        xs_all = data_tuples[1]
        us_all = data_tuples[end]
        
        for (m_idx, m_name) in enumerate(valid_methods)
            x_data, u_data = xs_all[m_idx], us_all[m_idx]
            valid_pairs = filter(p -> isfinite(p[2]), collect(zip(x_data, u_data)))
            isempty(valid_pairs) && continue
            
            c = colors[mod1(m_idx, length(colors))]
            
            if track_max
                max_u, idx = findmax(p -> p[2], valid_pairs)
                max_x = valid_pairs[idx][1]
                linesegments!(ax, [Point2f(max_x, 0), Point2f(max_x, max_u)]; color=(c, 0.7), linestyle=:dash, linewidth=lw, label="Extrema_Max")
            end
            if track_min
                min_u, idx = findmin(p -> p[2], valid_pairs)
                min_x = valid_pairs[idx][1]
                linesegments!(ax, [Point2f(min_x, 0), Point2f(min_x, min_u)]; color=(c, 0.7), linestyle=:dot, linewidth=lw, label="Extrema_Min")
            end
        end
    end
end

plot_extrema_lines_manager!(ax::Axis3, args...) = nothing

function apply_outlier_mask(ax::Axis, data_tuples, valid_methods, is_3d_axis)
    # 1. Always clear the old markers first
    delete_plots_by_label!(ax, "Outlier")
    
    ui_ext = get(manager.ui, :outliers_extrema, Dict())
    remove_outs = get(ui_ext, :remove_outliers, false)
    mark_outs   = get(ui_ext, :mark_outliers, false)

    # 2. If both features are inactive, exit early and return unmodified data
    if !remove_outs && !mark_outs
        return data_tuples
    end

    thresh = get(ui_ext, :outlier_threshold, 1.5)
    u_slices = data_tuples[end]
    new_u_slices = Any[]
    
    # Fetch method colors so the markers match the plot lines
    ui_stl = manager.ui[:plot_style]
    colors = get(ui_stl, :colors, [:red])

    for (m_idx, m_name) in enumerate(valid_methods)
        u_clean = u_slices[m_idx]
        out_idx = _find_outlier_indices(u_clean, thresh)

        # 3. Draw the Outliers immediately on the axis
        if !isempty(out_idx) && mark_outs && !is_3d_axis
            c = colors[mod1(m_idx, length(colors))]
            
            if length(data_tuples) == 2 # 1D Line/Scatter Plot
                xs = data_tuples[1][m_idx]
                segments = Point2f[]
                for idx in out_idx
                    x_val, u_val = Float64(xs[idx]), Float64(u_clean[idx])
                    push!(segments, Point2f(x_val, 0.0), Point2f(x_val, u_val))
                end
                linesegments!(ax, segments; color=(c, 0.6), linewidth=2.0, linestyle=:dash, label="Outlier")
                
            elseif length(data_tuples) >= 3 # 2D Heatmap/Contour Fallback
                xs, ys = data_tuples[1][m_idx], data_tuples[2][m_idx]
                pts = Point2f[]
                if out_idx isa Vector{CartesianIndex{2}}
                    for idx in out_idx; push!(pts, Point2f(xs[idx[1]], ys[idx[2]])); end
                else
                    for idx in out_idx; push!(pts, Point2f(xs[idx], ys[idx])); end
                end
                scatter!(ax, pts; color=c, marker=:xcross, markersize=15, label="Outlier")
            end
        end

        # 4. Conditionally apply NaN masking
        if remove_outs && !isempty(out_idx)
            u_clean_copy = copy(u_clean)
            if !(eltype(u_clean_copy) <: AbstractFloat)
                u_clean_copy = float.(u_clean_copy)
            end
            for idx in out_idx
                u_clean_copy[idx] = NaN
            end
            push!(new_u_slices, u_clean_copy)
        else
            push!(new_u_slices, u_clean)
        end
    end

    # Return modified tuple only if removal was explicitly requested
    return remove_outs ? (data_tuples[1:end-1]..., new_u_slices) : data_tuples
end

# Safety fallback for Axis3
apply_outlier_mask(ax::Axis3, data_tuples, valid_methods, is_3d_axis) = data_tuples

function _find_outlier_indices(y_data::AbstractVector, threshold::Real)
    if length(y_data) < 5; return Int[]; end
    finite_y_data = filter(isfinite, y_data)
    if length(finite_y_data) < 5; return Int[]; end

    q1, q3 = quantile(finite_y_data, 0.25), quantile(finite_y_data, 0.75)
    iqr = q3 - q1
    lower_bound, upper_bound = q1 - threshold * iqr, q3 + threshold * iqr
    
    return findall(y -> isfinite(y) && (y < lower_bound || y > upper_bound), y_data)
end

function _find_outlier_indices(matrix::AbstractMatrix, threshold::Real)
    flat_vector = vec(matrix)
    linear_outlier_indices = _find_outlier_indices(flat_vector, threshold)
    return CartesianIndices(matrix)[linear_outlier_indices]
end

function set_axis_styles!(ax::Axis, def_x::String, def_y::String, def_title::String)
    
    gen = manager.ui[:axis_general]
    lbl = manager.ui[:labels]
    x_ui, y_ui = manager.ui[:x_axis], manager.ui[:y_axis]

    ax.xlabel = lbl[:x_label] == "default" ? def_x : lbl[:x_label] 
    ax.ylabel = lbl[:y_label] == "default" ? def_y : lbl[:y_label] 
    ax.title  = lbl[:title]   == "default" ? def_title : lbl[:title] 

    ax.titlesize = gen[:title_size] 
    ax.xlabelsize = ax.ylabelsize = gen[:label_size] 
    ax.xticklabelsize = ax.yticklabelsize = gen[:ticklabel_size] 

    haskey(x_ui, :label_offset) && (ax.xlabelpadding = x_ui[:label_offset]) 
    haskey(y_ui, :label_offset) && (ax.ylabelpadding = y_ui[:label_offset]) 
    
    ax.xgridvisible, ax.xticklabelsvisible = x_ui[:grid_visibility], x_ui[:tick_label_visibility] 
    ax.ygridvisible, ax.yticklabelsvisible = y_ui[:grid_visibility], y_ui[:tick_label_visibility] 

    x_ui[:tick_count] > 0 && (ax.xticks = ax.xscale[] == log10 ? LogTicks(LinearTicks(x_ui[:tick_count])) : LinearTicks(x_ui[:tick_count])) 
    y_ui[:tick_count] > 0 && (ax.yticks = ax.yscale[] == log10 ? LogTicks(LinearTicks(y_ui[:tick_count])) : LinearTicks(y_ui[:tick_count])) 

    x_off = x_ui[:scale_offset] 
    ax.xtickformat = x_off != 0.0 ? (t -> map(v -> "$(round(x_off, sigdigits=3)) + $(@sprintf("%.1e", v - x_off))", t)) : (x_ui[:tick_format] == "default" ? Makie.automatic : x_ui[:tick_format]) 

    y_off = y_ui[:scale_offset] 
    ax.ytickformat = y_off != 0.0 ? (t -> map(v -> "$(round(y_off, sigdigits=3)) $(v - y_off < 0 ? "-" : "+") $(@sprintf("%.1e", abs(v - y_off)))", t)) : (y_ui[:tick_format] == "default" ? Makie.automatic : y_ui[:tick_format]) 
end

function set_axis_styles!(ax::Axis3, def_x::String, def_y::String, def_z::String, def_title::String)
    
    gen = manager.ui[:axis_general]
    lbl = manager.ui[:labels]
    x_ui, y_ui, z_ui = manager.ui[:x_axis], manager.ui[:y_axis], manager.ui[:z_axis]

    ax.xlabel = lbl[:x_label] == "default" ? def_x : lbl[:x_label] 
    ax.ylabel = lbl[:y_label] == "default" ? def_y : lbl[:y_label] 
    ax.zlabel = lbl[:z_label] == "default" ? def_z : lbl[:z_label] 
    ax.title  = lbl[:title]   == "default" ? def_title : lbl[:title] 

    ax.titlesize = gen[:title_size] 
    ax.xlabelsize = ax.ylabelsize = ax.zlabelsize = gen[:label_size] 
    ax.xticklabelsize = ax.yticklabelsize = ax.zticklabelsize = gen[:ticklabel_size] 

    ax.xgridvisible, ax.xticklabelsvisible = x_ui[:grid_visibility], x_ui[:tick_label_visibility] 
    ax.ygridvisible, ax.yticklabelsvisible = y_ui[:grid_visibility], y_ui[:tick_label_visibility] 
    ax.zgridvisible, ax.zticklabelsvisible = z_ui[:grid_visibility], z_ui[:tick_label_visibility] 

    haskey(x_ui, :label_offset) && (ax.xlabeloffset = x_ui[:label_offset]) 
    haskey(y_ui, :label_offset) && (ax.ylabeloffset = y_ui[:label_offset]) 
    haskey(z_ui, :label_offset) && (ax.zlabeloffset = z_ui[:label_offset]) 

    ax.perspectiveness = 0.5
    if !get(manager.state, :Camera_Locked, Observable(false))[]
        ax.aspect = (1, 1, 0.6)
    end
end

function plot_HUD!(ax::Axis)
    # THE FIX: Always clear the previous HUD before drawing or exiting
    delete_plots_by_label!(ax, "HUD")
    
    ui_hud = manager.ui[:hud]
    if !ui_hud[:visible] || isempty(ui_hud[:points])::Bool; return; end 
    
    pts = ui_hud[:points] 
    try
        x_pct = [Float64(p[1]) for p in pts]
        y_pct = [Float64(p[2]) for p in pts]
        
        if ui_hud[:close_loop] && length(x_pct) > 2 
            push!(x_pct, x_pct[1])
            push!(y_pct, y_pct[1])
        end

        mode  = lowercase(strip(ui_hud[:mode])) 
        color = ui_hud[:color] 
        lw    = ui_hud[:line_width] 
        ls    = ui_hud[:line_style] 
        ms    = ui_hud[:marker_size] 

        # THE FIX: Add label="HUD" to all primitives so they can be targeted and deleted
        if mode == "scatter"
            scatter!(ax, x_pct, y_pct; color=color, markersize=ms, space=:relative, label="HUD")
        elseif mode == "scatterlines"
            scatterlines!(ax, x_pct, y_pct; color=color, linewidth=lw, linestyle=ls, markersize=ms, space=:relative, label="HUD")
        elseif mode == "polygon"
            poly_pts = Point2f.(zip(x_pct, y_pct))
            poly!(ax, poly_pts; color=(color, 0.3), strokecolor=color, strokewidth=lw, space=:relative, label="HUD")
        else
            lines!(ax, x_pct, y_pct; color=color, linewidth=lw, linestyle=ls, space=:relative, label="HUD")
        end
    catch e
        @warn "Failed to plot HUD. Ensure 'points' is a vector of tuples, e.g., [(0.1, 0.1), (0.9, 0.9)]."
    end
end

plot_HUD!(ax::Axis3) = nothing

function _apply_axis_styles!(ax, T::Symbol)
    x = frontend_key(manager.widgets[:x_axis].selection[])
    y = frontend_key(manager.widgets[:y_axis].selection[])
    z = frontend_key(manager.widgets[:z_axis].selection[])
    u = frontend_key(manager.widgets[:u_axis].selection[])
    
    dim = PLOT_DIM_MAP[T] 
    def_title = ax.title[]
    
    if ax isa Axis
        def_y = dim == 1 ? u : y
        set_axis_styles!(ax, x, def_y, def_title)
        
        # THE FIX: Actually call the HUD drawing function!
        plot_HUD!(ax)
    elseif ax isa Axis3
        def_z = dim == 2 ? u : z
        set_axis_styles!(ax, x, y, def_z, def_title)
    end
end

function _find_first_drawable_primitive(cache_dict)
    for method_name in keys(cache_dict)
        prims = cache_dict[method_name].primitives
        for (pkey, prim) in prims
            if pkey in COLORBAR_SUPPORTED_PLOTS
                return prim
            end
        end
    end
    return nothing
end

function _collect_legend_elements(ui_app::Dict)
    
    plotted_objects = []
    labels_for_legend = String[]
    
    if !haskey(manager.caches, 1)
        return [], []
    end
    
    get_color(idx) = get(ui_app, :colors, nothing) !== nothing ? ui_app[:colors][mod1(idx, end)] : :black 

    for (m_idx, method_name) in enumerate(manager.methods[])
        if haskey(manager.caches[1], method_name)
            prims = manager.caches[1][method_name].primitives
            color = get_color(m_idx)
            
            group = []
            is_base = false
            
            # THE FIX: Map the backend method symbol to its UI string immediately!
            method_label_str = frontend_key(method_name)
            
            for (pkey, prim) in prims
                deps = get(STYLE_DEPENDENCIES, pkey, Symbol[])
                
                if pkey == :contour_f
                    push!(plotted_objects, [Makie.PolyElement(color=Makie.to_colormap(ui_app[:color_map])[end])]) 
                    push!(labels_for_legend, "$(method_label_str) (Base)")
                    is_base = true
                end
                
                if :line_width in deps && :colors in deps
                    ls = (ui_app[:dashed_lines] && :dashed_lines in deps) ? ui_app[:line_styles][mod1(m_idx, end)] : nothing 
                    push!(group, Makie.LineElement(color=color, linewidth=ui_app[:line_width], linestyle=ls)) 
                end
                
                if :markers in deps && :colors in deps
                    mrk = ui_app[:markers][mod1(m_idx, end)] 
                    push!(group, Makie.MarkerElement(color=color, marker=mrk, markersize=ui_app[:marker_size])) 
                end
            end
            
            if !isempty(group)
                push!(plotted_objects, group)
                if !is_base
                    push!(labels_for_legend, method_label_str)
                end
            end
        end
    end
    
    return plotted_objects, labels_for_legend
end

function extract_and_store_camera_state!(plot_layout::GridLayout)
    cam_opts = Dict{Symbol, Any}()
    axes = [c.content for c in plot_layout.content if c.content isa Axis || c.content isa Axis3]
    for (i, ax) in enumerate(axes)
        if ax isa Axis
            lims = ax.finallimits[]
            cam_opts[Symbol("Axis_$(i)_Limits")] = Float64[lims.origin[1], lims.origin[1] + lims.widths[1], lims.origin[2], lims.origin[2] + lims.widths[2]]
        elseif ax isa Axis3
            lims = ax.finallimits[]
            cam_opts[Symbol("Axis_$(i)_Limits3D")]  = Float64[
                lims.origin[1], lims.origin[1] + lims.widths[1], 
                lims.origin[2], lims.origin[2] + lims.widths[2], 
                lims.origin[3], lims.origin[3] + lims.widths[3]
            ]
            cam_opts[Symbol("Axis_$(i)_Azimuth")]   = Float64(ax.azimuth[])
            cam_opts[Symbol("Axis_$(i)_Elevation")] = Float64(ax.elevation[])
        end
    end
    manager.state[:Camera_Cache] = cam_opts
end

function _enforce_camera_lock!(axes::Vector)
    
    is_locked = get(manager.state, :Camera_Locked, Observable(false))[]
    cam_opts = get(manager.state, :Camera_Cache, Dict{Symbol, Any}())
    
    if !isempty(cam_opts)
        for (i, ax) in enumerate(axes)
            if ax isa Axis && haskey(cam_opts, Symbol("Axis_$(i)_Limits"))
                l = cam_opts[Symbol("Axis_$(i)_Limits")]
                try limits!(ax, l[1], l[2], l[3], l[4]) catch; end
            elseif ax isa Axis3
                try
                    if haskey(cam_opts, Symbol("Axis_$(i)_Limits3D"))
                        l = cam_opts[Symbol("Axis_$(i)_Limits3D")]
                        limits!(ax, l[1], l[2], l[3], l[4], l[5], l[6])
                    end
                    if haskey(cam_opts, Symbol("Axis_$(i)_Azimuth"))
                        ax.azimuth[] = Float32(cam_opts[Symbol("Axis_$(i)_Azimuth")])
                    end
                    if haskey(cam_opts, Symbol("Axis_$(i)_Elevation"))
                        ax.elevation[] = Float32(cam_opts[Symbol("Axis_$(i)_Elevation")])
                    end
                catch
                end
            end
        end
        
        # FIX: If it wasn't permanently locked by the user, this was a temporary staged state.
        # Clear it out so auto-scaling resumes on the next data update!
        if !is_locked
            empty!(manager.state[:Camera_Cache])
        end
    end
end