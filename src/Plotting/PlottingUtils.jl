

"""
    plot_reference_lines!(ax, exponents; kwargs...)

Plots reference power-law lines anchored to the corners of the current axis view.
The sign of each exponent determines the anchor point:
- Positive exponent `p`: Anchors at the top-right `(xmax, ymax)`.
- Negative exponent `p`: Anchors at the bottom-right `(xmax, ymin)`.

# Arguments
- `ax::Axis`: The Makie axis to plot into.
- `exponents::Union{Tuple, Nothing}`: A tuple of signed exponents.

# Keyword Arguments
- `label::String`: A single label for all reference lines to group them in the legend.
- Other keywords are passed to `Makie.lines!`.
"""
function plot_reference_lines!(
    ax::Axis,
    exponents::Union{Tuple, Nothing};
    label::String = "Reference Lines",
    color = :black,
    linestyle = :dash,
    kwargs...
)
    # --- Input and Axis Validation ---
    if isnothing(exponents) || isempty(exponents)
        return []
    end

    current_limits_nested = ax.limits[]
    if isnothing(current_limits_nested) || isnothing(current_limits_nested[1]) || isnothing(current_limits_nested[2])
        @warn "Cannot plot reference lines, axis view limits are not yet set."
        return []
    end
    
    xlims, ylims = current_limits_nested
    
    # On a log scale, limits must be positive.
    if any(x -> x <= 0, (xlims..., ylims...))
        @warn "Cannot plot reference lines on a log-log plot with non-positive axis limits."
        return []
    end
    
    xmin, xmax = xlims
    ymin, ymax = ylims

    # For a visually straight line on a log-log plot, we create log-spaced x-values.
    x_ref_values = 10 .^ range(log10(xmin), log10(xmax), length=100)
    
    # The anchor x-position is always the leftmost edge.
    ref_x = xmin

    plotted_lines = []
    
    for p_signed in exponents
        if p_signed == 0; continue; end

        # --- Correctly determine the y-anchor point ---
        local y_anchor
        if p_signed > 0
            # An O(x^2) line should start low on the left.
            y_anchor = ymin
        else # p_signed < 0
            # An O(x^-1) line should start high on the left.
            y_anchor = ymax
        end

        # --- Calculate the line using the power-law formula ---
        
        # Calculate scaling constant C so that y = C * x^p passes through (ref_x, y_anchor)
        C = y_anchor / (ref_x^p_signed)
        
        # Calculate the y-values for the reference line using the power law
        y_ref_line = C .* (x_ref_values .^ p_signed)
        
        # Create a single line plot for this exponent
        line = lines!(ax, x_ref_values, y_ref_line;
            label = label, # Use the same label for grouping in the legend
            color = (color, 0.65),
            linestyle = linestyle,
            kwargs...
        )
        
        push!(plotted_lines, line)
    end

    return plotted_lines
end

"""
    delete_plots_by_label!(ax::Axis, label_to_delete::String)

Finds all plot objects in a given axis that have a specific label
and deletes them. This version correctly accesses plots via `ax.scene`.
"""
function delete_plots_by_label!(ax::Axis, label_to_delete::String)
    # CORRECT API: Access plots via the axis's scene.
    # The `ax.scene` contains the list of all plot objects drawn into that axis.
    plots_to_delete = [p for p in ax.scene.plots if haskey(p,:label) && p.label[] == label_to_delete]
    
    if !isempty(plots_to_delete)
        for p in plots_to_delete
            delete!(ax.scene, p) # Delete from the scene
        end
        return true
    end
    
    return false
end

"""
    generate_dynamic_title(x_key, y_key, dim_idx, manager, dim_names, sel_vals)

Constructs the plot title dynamically. It lists all fixed parameters and base variables,
marks the actively plotted dimension, and allows for a user-defined override via `manager.ui`.
"""
function generate_dynamic_title(
    dim_idx::Int, 
    dim_names::Vector{String}, 
    sel_vals
)
    # 2. Build the Default Dynamic Title
    title_parts = String[]
    
    for i in 1:length(dim_names)
        name = dim_names[i]
        
        if i == dim_idx
            # This is the axis we are currently plotting along (the colon ':' in the tensor slice)
            push!(title_parts, "$name = [Axis]")
        else
            val = sel_vals[i]
            # Format floats neatly to 3 decimal places to prevent title bloat
            val_str = val isa AbstractFloat ? @sprintf("%.3f", val) : string(val)
            push!(title_parts, "$name = $val_str")
        end
    end
    
    # Join all the parts together with a separator
    return join(title_parts, " | ")
end
# --- Legend Helpers ---
function _parse_legend_position(s_in::String)
    s = lowercase(s_in)
    if s == "center"; return (:center, :center); end

    valign = occursin("top", s) ? :top : (occursin("bottom", s) ? :bottom : :center)
    halign = occursin("left", s) ? :left : (occursin("right", s) ? :right : :center)

    return (halign, valign)
end

function create_or_update_legend!(
    fig::Figure, 
    plotted_objects::Vector, 
    labels::Vector, 
    manager::PlotManager
)
    # 1. Clean up old legends
    for elem in copy(contents(fig.layout))
        if elem isa Legend; delete!(elem); end
    end

    # 2. Extract properties hierarchically
    ui_style = manager.ui["Plot-Style"]
    
    # If the current Plot-Style doesn't support legends (like Heatmaps), skip entirely!
    if !haskey(ui_style, "legend_pos"); return; end 

    position = ui_style["legend_pos"][]
    title_str = manager.ui["Labels"]["legend"][]
    font_size = manager.ui["Axis-General"]["font_size"][]

    if isempty(plotted_objects) || isempty(labels)
        try trim!(fig.layout) catch; end
        return
    end

    final_title = isempty(strip(title_str)) ? nothing : title_str

    # 3. Create new Legend
    try
        if position == "detached"
            trim!(fig.layout)
            Legend(fig[1, end+1], plotted_objects, labels, final_title;
                tellheight=false, merge=true, unique=true,
                titlesize=font_size, labelsize=font_size
            )
            colsize!(fig.layout, 2, Auto())
        else
            halign, valign = _parse_legend_position(position)
            Legend(fig[1,1], plotted_objects, labels, final_title;
                orientation=:vertical, tellheight=false, tellwidth=false,
                halign=halign, valign=valign, merge=true, unique=true,
                titlesize=font_size, labelsize=font_size, margin=(10, 10, 10, 10)
            )
            trim!(fig.layout)
        end
    catch e; @error "Failed to create legend" exception=(e, catch_backtrace()); end
end


# --- Axis Styling Helpers ---
"""
    set_axis_styles!(ax::Axis, manager, def_x, def_y, def_title)

Pulls from the hierarchical UI dictionary to style a 2D axis. 
Automatically applies Labels, Limits, Grids, and Offsets.
"""
function set_axis_styles!(ax::Axis, manager::PlotManager, def_x::String, def_y::String, def_title::String)
    ui_gen = manager.ui["Axis-General"]
    ui_lbl = manager.ui["Labels"]
    ui_x   = manager.ui["X-Axis"]
    ui_y   = manager.ui["Y-Axis"]
    ui_stl = manager.ui["Plot-Style"]

    # 1. Labels
    ax.xlabel = ui_lbl["xlabel"][] == "default" ? def_x : ui_lbl["xlabel"][]
    ax.ylabel = ui_lbl["ylabel"][] == "default" ? def_y : ui_lbl["ylabel"][]
    ax.title  = ui_lbl["title"][] == "default" ? def_title : ui_lbl["title"][]

    # 2. Font Sizes
    ax.titlesize = ui_gen["title_size"][]
    ax.xlabelsize = ui_gen["label_size"][]
    ax.ylabelsize = ui_gen["label_size"][]
    ax.xticklabelsize = ui_gen["ticklabel_size"][]
    ax.yticklabelsize = ui_gen["ticklabel_size"][]

    # 3. Offsets & Margins
    if haskey(ui_stl, "xlabel_offset")
        ax.xlabelpadding = ui_stl["xlabel_offset"][]
        ax.ylabelpadding = ui_stl["ylabel_offset"][]
    end
    if haskey(ui_stl, "bottom_margin")
        ax.alignmode = Mixed(bottom = ui_stl["bottom_margin"][], left=0, right=0, top=0)
    end

    # 4. Grids & Visibility
    ax.xgridvisible = ui_x["gridvisible"][]
    ax.ygridvisible = ui_y["gridvisible"][]
    ax.xticklabelsvisible = ui_x["ticklabelsvisible"][]
    ax.yticklabelsvisible = ui_y["ticklabelsvisible"][]

    # 5. Ticks & Formats
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

"""
    set_axis_styles!(ax::Axis3, manager, def_x, def_y, def_z, def_title)

Pulls from the hierarchical UI dictionary to style a 3D perspective axis.
"""
function set_axis_styles!(ax::Axis3, manager::PlotManager, def_x::String, def_y::String, def_z::String, def_title::String)
    ui_gen = manager.ui["Axis-General"]
    ui_lbl = manager.ui["Labels"]
    ui_x, ui_y, ui_z = manager.ui["X-Axis"], manager.ui["Y-Axis"], manager.ui["Z-Axis"]
    ui_stl = manager.ui["Plot-Style"]

    ax.xlabel = ui_lbl["xlabel"][] == "default" ? def_x : ui_lbl["xlabel"][]
    ax.ylabel = ui_lbl["ylabel"][] == "default" ? def_y : ui_lbl["ylabel"][]
    ax.zlabel = ui_lbl["zlabel"][] == "default" ? def_z : ui_lbl["zlabel"][]
    ax.title  = ui_lbl["title"][] == "default" ? def_title : ui_lbl["title"][]

    ax.titlesize = ui_gen["title_size"][]
    ax.xlabelsize = ui_gen["label_size"][]; ax.ylabelsize = ui_gen["label_size"][]; ax.zlabelsize = ui_gen["label_size"][]
    ax.xticklabelsize = ui_gen["ticklabel_size"][]; ax.yticklabelsize = ui_gen["ticklabel_size"][]; ax.zticklabelsize = ui_gen["ticklabel_size"][]

    ax.xgridvisible = ui_x["gridvisible"][]; ax.ygridvisible = ui_y["gridvisible"][]; ax.zgridvisible = ui_z["gridvisible"][]
    ax.xticklabelsvisible = ui_x["ticklabelsvisible"][]; ax.yticklabelsvisible = ui_y["ticklabelsvisible"][]; ax.zticklabelsvisible = ui_z["ticklabelsvisible"][]

    if haskey(ui_stl, "xlabel_offset")
        ax.xlabeloffset = ui_stl["xlabel_offset"][]
        ax.ylabeloffset = ui_stl["ylabel_offset"][]
        ax.zlabeloffset = ui_stl["zlabel_offset"][]
    end

    ax.perspectiveness = 0.5
    ax.aspect = (1, 1, 0.6)
end


# --- Utility Functions ---
function calculate_padded_axis_range(raw_limits::Tuple, padding_factor::Real, is_log_scale::Bool)
    min_raw, max_raw = raw_limits
    if isnothing(min_raw) || isnothing(max_raw) || !isfinite(min_raw) || !isfinite(max_raw); return (0.0, 1.0); end

    use_log = is_log_scale && (min_raw > 0)
    
    if use_log
        pad = padding_factor
        return (min_raw / (1 + pad), max_raw * (1 + pad))
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

function set_axis_limits_manager!(ax::Axis, xs, us, manager::PlotManager)
    ui_x = manager.ui["X-Axis"]
    ui_y = manager.ui["Y-Axis"]
    
    raw_xlims = _safe_extrema(xs)
    raw_ylims = _safe_extrema(us)

    final_xlims = calculate_padded_axis_range(raw_xlims, ui_x["padding"][], ui_x["logscale"][])
    final_ylims = calculate_padded_axis_range(raw_ylims, ui_y["padding"][], ui_y["logscale"][])

    try limits!(ax, final_xlims..., final_ylims...) catch; end
    
    ax.xscale[] = final_xlims[1] > 0 && ui_x["logscale"][] ? log10 : identity
    ax.yscale[] = final_ylims[1] > 0 && ui_y["logscale"][] ? log10 : identity
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


function create_or_update_colorbar!(
    fig::Figure,
    plot_object,
    manager::PlotManager,
    color_range_obs::Observable,
    default_label::String,
)
    for elem in copy(contents(fig.layout))
        if elem isa Colorbar; delete!(elem); end
    end
    isnothing(plot_object) && return

    ui_stl = manager.ui["Plot-Style"]
    
    # If the plot style doesn't have a colormap (like Lines), it shouldn't have a colorbar!
    if !haskey(ui_stl, "colormap"); return; end 

    ui_lbl = manager.ui["Labels"]
    ui_gen = manager.ui["Axis-General"]

    final_label = ui_lbl["colorbar_label"][] == "default" ? default_label : ui_lbl["colorbar_label"][]

    try
        cb = Colorbar(fig[1, 2];
            colormap = ui_stl["colormap"][],
            colorrange = color_range_obs,
            label = final_label,
            labelsize = ui_gen["label_size"][],
            ticklabelsize = ui_gen["ticklabel_size"][],
        )
        colsize!(fig.layout, 2, Auto())
    catch e; @error "Failed to create colorbar." exception=(e, catch_backtrace()); end
end

# (Keep plot_reference_lines! and delete_plots_by_label! exactly as they were...)
