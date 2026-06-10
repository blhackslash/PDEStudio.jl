function plot_reference_lines!(
    ax::Axis,
    exponents::Vector;
    label::String = "Reference Lines",
    color = :black,
    linestyle = :dash,
    kwargs...
)
    if isnothing(exponents) || isempty(exponents)
        return []
    end

    bbox = Makie.data_limits(ax.scene)
    if !isfinite(bbox.origin[1]) || !isfinite(bbox.widths[1])
        return []
    end
    
    xmin, ymin = bbox.origin[1], bbox.origin[2]
    xmax = xmin + bbox.widths[1]
    ymax = ymin + bbox.widths[2]
    
    if (xmin <= 0 || xmax <= 0) && (ax.xscale[] == log10 || ax.yscale[] == log10)
        return [] 
    end

    x_ref_values = 10 .^ range(log10(xmin), log10(xmax), length=100)
    ref_x = xmin
    plotted_lines = []
    
    for p_signed in exponents
        if p_signed == 0; continue; end

        local y_anchor
        if p_signed > 0
            y_anchor = ymin
        else 
            y_anchor = ymax
        end

        C = y_anchor / (ref_x^p_signed)
        y_ref_line = C .* (x_ref_values .^ p_signed)
        
        line = lines!(ax, x_ref_values, y_ref_line;
            label = label, 
            color = (color, 0.65),
            linestyle = linestyle,
            kwargs...
        )
        push!(plotted_lines, line)
    end

    return plotted_lines
end

"""
    get_colorrange(ui_app::Dict, u_data::AbstractArray)

Extracts the colorrange from the UI dict, or calculates it dynamically from the data 
if set to "default". Always returns an Observable Tuple of Float64.
"""
function get_colorrange(ui_app::Dict, u_data::AbstractArray)
    cr_val = ui_app["colorrange"][]
    
    if isempty(cr_val)
        valid_u = filter(isfinite, vec(u_data))
        l_u, h_u = isempty(valid_u) ? (0.0, 1.0) : (minimum(valid_u), maximum(valid_u))
        if l_u == h_u; h_u += 1e-6; end
        return Observable((l_u, h_u))
    else
        return Observable(Tuple(Float64.(cr_val)))
    end
end

function apply_axis_limits_overrides!(ax, manager::PlotManager)
    ui_x = manager.ui["X-Axis"]
    ui_y = manager.ui["Y-Axis"]
    
    try
        if haskey(ui_x, "lims") && length(ui_x["lims"][]) == 2
            lx = Float64.(ui_x["lims"][])
            if lx[1] < lx[2]; xlims!(ax, lx[1], lx[2]); end
        end
        
        if haskey(ui_y, "lims") && length(ui_y["lims"][]) == 2
            ly = Float64.(ui_y["lims"][])
            if ly[1] < ly[2]; ylims!(ax, ly[1], ly[2]); end
        end
        
        if ax isa Axis3 && haskey(manager.ui, "Z-Axis")
            ui_z = manager.ui["Z-Axis"]
            if haskey(ui_z, "lims") && length(ui_z["lims"][]) == 2
                lz = Float64.(ui_z["lims"][])
                if lz[1] < lz[2]; zlims!(ax, lz[1], lz[2]); end
            end
        end
    catch
        @warn "Failed to apply manual axis limits. Please ensure the input is a 2-element vector like [-5.0, 5.0]."
    end
end

"""
    delete_plots_by_label!(ax::Axis, label_to_delete::String)

Finds all plot objects in a given axis that have a specific label and deletes them.
"""
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

function set_axis_limits_manager!(ax::Axis, xs, us, manager::PlotManager)
    ui_x = manager.ui["X-Axis"]
    ui_y = manager.ui["Y-Axis"]
    
    raw_xlims = _safe_extrema(xs)
    raw_ylims = _safe_extrema(us)

    use_log_x = ui_x["logscale"][]
    use_log_y = ui_y["logscale"][]

    if raw_xlims[1] <= 0 && use_log_x
        ui_x["logscale"][] = false
        use_log_x = false
        @warn "X-Axis data contains non-positive values. Logscale disabled."
    end
    if raw_ylims[1] <= 0 && use_log_y
        ui_y["logscale"][] = false
        use_log_y = false
        @warn "Y-Axis data contains non-positive values. Logscale disabled."
    end

    final_xlims = calculate_padded_axis_range(raw_xlims, ui_x["padding"][], use_log_x)
    final_ylims = calculate_padded_axis_range(raw_ylims, ui_y["padding"][], use_log_y)

    try limits!(ax, final_xlims..., final_ylims...) catch; end

    if use_log_x; ax.xscale[] = log10; end
    if use_log_y; ax.yscale[] = log10; end
end

# ==============================================================================
# --- MASTER GRID CALCULATOR ---
# ==============================================================================
function calculate_layout_dictionary(num_plots::Int, cols_req::Int, link_mode::String, has_legend::Bool, is_detached::Bool, halign::Symbol, valign::Symbol, has_colorbar::Bool)
    cols = min(num_plots, cols_req)
    rows = ceil(Int, num_plots / cols)
    
    layout_dict = Dict{String, Any}()
    layout_dict["Plots"] = Vector{Tuple{Any, Any}}(undef, num_plots)
    layout_dict["Colorbars"] = Vector{Tuple{Any, Any}}()
    layout_dict["Legend"] = nothing
    
    row_offset = (has_legend && is_detached && valign == :top) ? 1 : 0
    col_offset = (has_legend && is_detached && halign == :left) ? 1 : 0

    if link_mode in ("Decoupled", "Axes Only") && has_colorbar
        for i in 1:num_plots
            r = (i - 1) ÷ cols + 1
            c = (i - 1) % cols + 1
            
            p_row = r + row_offset
            p_col = (2 * c - 1) + col_offset
            cb_col = (2 * c) + col_offset
            
            layout_dict["Plots"][i] = (p_row, p_col)
            push!(layout_dict["Colorbars"], (p_row, cb_col))
        end
        max_core_col = 2 * cols + col_offset
        max_core_row = rows + row_offset
    else
        for i in 1:num_plots
            r = (i - 1) ÷ cols + 1
            c = (i - 1) % cols + 1
            
            p_row = r + row_offset
            p_col = c + col_offset
            
            layout_dict["Plots"][i] = (p_row, p_col)
        end
        max_core_col = cols + col_offset
        max_core_row = rows + row_offset
        
        if has_colorbar
            cb_col = max_core_col + 1
            max_core_col += 1
            push!(layout_dict["Colorbars"], (1 + row_offset : rows + row_offset, cb_col))
        end
    end
    
    if has_legend
        if is_detached
            if valign == :top
                layout_dict["Legend"] = (1, 1:max_core_col)
            elseif valign == :bottom
                layout_dict["Legend"] = (max_core_row + 1, 1:max_core_col)
            elseif halign == :left
                layout_dict["Legend"] = (1+row_offset : max_core_row, 1)
            else 
                layout_dict["Legend"] = (1+row_offset : max_core_row, max_core_col + 1)
            end
        else
            layout_dict["Legend"] = layout_dict["Plots"][1]
        end
    end
    return layout_dict
end

# ==============================================================================
# --- LEGEND & COLORBAR BUILDERS ---
# ==============================================================================
function _parse_legend_position(manager::PlotManager, is_compare::Bool=false)
    # THE FIX: Read Directly from the native Makie Menu selections
    base_align = manager.widgets["Legend_Base"].selection[]
    add_align  = manager.widgets["Legend_Add"].selection[]
    
    s = lowercase(string(base_align) * "_" * string(add_align))
    if occursin("none", s); return (false, :none, :none); end
    
    is_detached = occursin("detached", s)
    
    if is_compare && !is_detached
        return (true, :center, :top)
    end
    
    valign = occursin("top", s) ? :top : (occursin("bottom", s) ? :bottom : :center)
    halign = occursin("left", s) ? :left : (occursin("right", s) ? :right : :center)

    return (is_detached, halign, valign)
end

function create_or_update_legend!(plot_layout::GridLayout, plotted_objects::Vector, labels::Vector, manager::PlotManager)
    for c in copy(plot_layout.content)
        if c.content isa Legend; delete!(c.content); end
    end
    
    if isempty(plotted_objects) || isempty(labels); return; end
    
    layout_dict = manager.state["Layout_Dict"][]
    if !haskey(layout_dict, "Legend") || isnothing(layout_dict["Legend"]); return; end
    
    ui_style = manager.ui["Axis-General"]
    title_str = manager.ui["Labels"]["legend"][]
    final_title = isempty(strip(title_str)) ? nothing : title_str
    font_size = ui_style["font_size"][]
    
    # THE FIX: Query the native Compare_Target menu selection cleanly
    is_compare = manager.widgets["Compare_Target"].selection[] != "None"
    is_detached, halign, valign = _parse_legend_position(manager, is_compare)

    if halign==:none && valign==:none; return; end
    leg_pos = layout_dict["Legend"]

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

function create_or_update_colorbar!(plot_layout::GridLayout, plot_object, manager::PlotManager, color_range_obs::Observable, default_label::String, plot_idx::Int=1)
    isnothing(plot_object) && return
    ui_stl = manager.ui["Plot-Style"]
    if !haskey(ui_stl, "colormap"); return; end 
    
    layout_dict = manager.state["Layout_Dict"][]
    cb_list = layout_dict["Colorbars"]
    isempty(cb_list) && return
    
    is_global = length(cb_list) == 1
    
    if is_global && plot_idx > 1; return; end
    
    if plot_idx == 1
        for c in copy(plot_layout.content)
            if c.content isa Colorbar; delete!(c.content); end
        end
    end
    
    cb_pos = is_global ? cb_list[1] : cb_list[plot_idx]
    
    ui_lbl = manager.ui["Labels"]
    ui_gen = manager.ui["Axis-General"]
    final_label = ui_lbl["colorbar_label"][] == "default" ? default_label : ui_lbl["colorbar_label"][]
    
    try
        Colorbar(plot_layout[cb_pos...], plot_object;
            labelsize = ui_gen["label_size"][],
            ticklabelsize = ui_gen["ticklabel_size"][]
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

function plot_extrema_lines_manager!(ax, x_data, u_data, manager, plot_idx)
    ui_var = manager.ui["Various"]
    ui_stl = manager.ui["Plot-Style"]
    
    track_max = ui_var["track_max"][]
    track_min = ui_var["track_min"][]
    (!track_max && !track_min) && return

    valid_pairs = filter(p -> isfinite(p[2]), collect(zip(x_data, u_data)))
    isempty(valid_pairs) && return
    
    color = ui_stl["colors"][][mod1(plot_idx, end)]
    lw = haskey(ui_stl, "linewidth") ? (ui_stl["linewidth"][] / 2) : 2.0

    if track_max
        max_u, idx = findmax(p -> p[2], valid_pairs)
        max_x = valid_pairs[idx][1]
        linesegments!(ax, [Point2f(max_x, 0), Point2f(max_x, max_u)]; color=(color, 0.7), linestyle=:dash, linewidth=lw)
    end
    if track_min
        min_u, idx = findmin(p -> p[2], valid_pairs)
        min_x = valid_pairs[idx][1]
        linesegments!(ax, [Point2f(min_x, 0), Point2f(min_x, min_u)]; color=(color, 0.7), linestyle=:dot, linewidth=lw)
    end
end

function _find_outlier_indices(y_data::AbstractVector, threshold::Real)
    if length(y_data) < 5; return Int[]; end
    finite_y_data = filter(isfinite, y_data)
    if length(finite_y_data) < 5; return Int[]; end

    q1, q3 = quantile(finite_y_data, 0.25), quantile(finite_y_data, 0.75)
    iqr = q3 - q1
    lower_bound, upper_bound = q1 - threshold * iqr, q3 + threshold * iqr
    
    return findall(y -> isfinite(y) && (y < lower_bound || y > upper_bound), y_data)
end

function _find_outlier_indices(matrix::AbstractMatrix, threshold::Real)::Vector{CartesianIndex}
    flat_vector = vec(matrix)
    linear_outlier_indices = _find_outlier_indices(flat_vector, threshold)
    return CartesianIndices(matrix)[linear_outlier_indices]
end

function set_axis_styles!(ax::Axis, manager::PlotManager, def_x::String, def_y::String, def_title::String)
    ui_gen = manager.ui["Axis-General"]
    ui_lbl = manager.ui["Labels"]
    ui_x   = manager.ui["X-Axis"]
    ui_y   = manager.ui["Y-Axis"]

    ax.xlabel = ui_lbl["xlabel"][] == "default" ? def_x : ui_lbl["xlabel"][]
    ax.ylabel = ui_lbl["ylabel"][] == "default" ? def_y : ui_lbl["ylabel"][]
    ax.title  = ui_lbl["title"][] == "default" ? def_title : ui_lbl["title"][]

    ax.titlesize = ui_gen["title_size"][]
    ax.xlabelsize = ui_gen["label_size"][]
    ax.ylabelsize = ui_gen["label_size"][]
    ax.xticklabelsize = ui_gen["ticklabel_size"][]
    ax.yticklabelsize = ui_gen["ticklabel_size"][]

    if haskey(ui_x, "label_offset")
        ax.xlabelpadding = ui_x["label_offset"][]
    end
    if haskey(ui_y, "label_offset")
        ax.ylabelpadding = ui_y["label_offset"][]
    end
    
    ax.xgridvisible = ui_x["gridvisible"][]
    ax.ygridvisible = ui_y["gridvisible"][]
    ax.xticklabelsvisible = ui_x["ticklabelsvisible"][]
    ax.yticklabelsvisible = ui_y["ticklabelsvisible"][]

    if ui_x["tick_count"][] > 0
        ax.xticks = ax.xscale[] == log10 ? LogTicks(LinearTicks(ui_x["tick_count"][])) : LinearTicks(ui_x["tick_count"][])
    end
    if ui_y["tick_count"][] > 0
        ax.yticks = ax.yscale[] == log10 ? LogTicks(LinearTicks(ui_y["tick_count"][])) : LinearTicks(ui_y["tick_count"][])
    end

    x_offset = ui_x["scale_offset"][]
    if x_offset != 0.0
        ax.xtickformat = ticks -> map(x -> "$(round(x_offset, sigdigits=3)) + $(@sprintf("%.1e", x - x_offset))", ticks)
    else
        ax.xtickformat = ui_x["tickformat"][] == "default" ? Makie.automatic : ui_x["tickformat"][]
    end

    y_offset = ui_y["scale_offset"][]
    if y_offset != 0.0
        ax.ytickformat = ticks -> map(ticks) do y
            dev = y - y_offset
            "$(round(y_offset, sigdigits=3)) $(dev < 0 ? "-" : "+") $(@sprintf("%.1e", abs(dev)))"
        end
    else
        ax.ytickformat = ui_y["tickformat"][] == "default" ? Makie.automatic : ui_y["tickformat"][]
    end
end

function set_axis_styles!(ax::Axis3, manager::PlotManager, def_x::String, def_y::String, def_z::String, def_title::String)
    ui_gen = manager.ui["Axis-General"]
    ui_lbl = manager.ui["Labels"]
    ui_x, ui_y, ui_z = manager.ui["X-Axis"], manager.ui["Y-Axis"], manager.ui["Z-Axis"]

    ax.xlabel = ui_lbl["xlabel"][] == "default" ? def_x : ui_lbl["xlabel"][]
    ax.ylabel = ui_lbl["ylabel"][] == "default" ? def_y : ui_lbl["ylabel"][]
    ax.zlabel = ui_lbl["zlabel"][] == "default" ? def_z : ui_lbl["zlabel"][]
    ax.title  = ui_lbl["title"][] == "default" ? def_title : ui_lbl["title"][]

    ax.titlesize = ui_gen["title_size"][]
    ax.xlabelsize = ui_gen["label_size"][]; ax.ylabelsize = ui_gen["label_size"][]; ax.zlabelsize = ui_gen["label_size"][]
    ax.xticklabelsize = ui_gen["ticklabel_size"][]; ax.yticklabelsize = ui_gen["ticklabel_size"][]; ax.zticklabelsize = ui_gen["ticklabel_size"][]

    ax.xgridvisible = ui_x["gridvisible"][]; ax.ygridvisible = ui_y["gridvisible"][]; ax.zgridvisible = ui_z["gridvisible"][]
    ax.xticklabelsvisible = ui_x["ticklabelsvisible"][]; ax.yticklabelsvisible = ui_y["ticklabelsvisible"][]; ax.zticklabelsvisible = ui_z["ticklabelsvisible"][]

    if haskey(ui_x, "label_offset")
        ax.xlabeloffset = ui_x["label_offset"][]
    end
    if haskey(ui_y, "label_offset")
        ax.ylabeloffset = ui_y["label_offset"][]
    end
    if haskey(ui_z, "label_offset")
        ax.zlabeloffset = ui_z["label_offset"][]
    end

    ax.perspectiveness = 0.5
    ax.aspect = (1, 1, 0.6)
end

function plot_HUD!(ax::Axis, manager::PlotManager)
    ui_hud = manager.ui["HUD"]
    if !ui_hud["visible"][] || isempty(ui_hud["points"][])::Bool; return; end
    
    pts = ui_hud["points"][]
    try
        x_pct = [Float64(p[1]) for p in pts]
        y_pct = [Float64(p[2]) for p in pts]
        
        if ui_hud["close_loop"][] && length(x_pct) > 2
            push!(x_pct, x_pct[1])
            push!(y_pct, y_pct[1])
        end

        mode  = lowercase(strip(ui_hud["mode"][]))
        color = ui_hud["color"][]
        lw    = ui_hud["linewidth"][]
        ls    = ui_hud["linestyle"][]
        ms    = ui_hud["markersize"][]

        if mode == "scatter"
            scatter!(ax, x_pct, y_pct; color=color, markersize=ms, space=:relative)
        elseif mode == "scatterlines"
            scatterlines!(ax, x_pct, y_pct; color=color, linewidth=lw, linestyle=ls, markersize=ms, space=:relative)
        elseif mode == "polygon"
            poly_pts = Point2f.(zip(x_pct, y_pct))
            poly!(ax, poly_pts; color=(color, 0.3), strokecolor=color, strokewidth=lw, space=:relative)
        else
            lines!(ax, x_pct, y_pct; color=color, linewidth=lw, linestyle=ls, space=:relative)
        end
    catch e
        @warn "Failed to plot HUD. Ensure 'points' is a vector of tuples, e.g., [(0.1, 0.1), (0.9, 0.9)]."
    end
end

plot_HUD!(ax::Axis3, manager::PlotManager) = nothing