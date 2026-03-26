function updateUI(ui_dict::Dict, ui_input::Dict)
    @assert issubset(Set(keys(ui_input)), Set(keys(ui_dict))) "At least one of the given UI keys is not used! Check spelling!"
    for (key, val) in ui_input
        # Special handling if user provides scalar for 3d markersize
        if key == "markersize_3d" && isa(val, Real)
            ui_dict[key] = Vec3f(val)
        else
            ui_dict[key] = val
        end
    end
end
# Functions for Makie Controls

# This function goes into your plotting_helpers.jl file
"""
    _parse_legend_position(s::String) -> Tuple{Symbol, Symbol}

Parses a descriptive string like "topright" or "bottomleft" into a
Tuple of Symbols `(halign, valign)` suitable for Makie's alignment.
Handles all combinations of top, bottom, left, right, and center.
"""
function _parse_legend_position(s_in::String)
    s = lowercase(s_in)

    if s == "center"
        return (:center, :center)
    end

    # Determine vertical alignment
    valign = if occursin("top", s)
        :top
    elseif occursin("bottom", s)
        :bottom
    else
        :center
    end

    # Determine horizontal alignment
    halign = if occursin("left", s)
        :left
    elseif occursin("right", s)
        :right
    else
        :center
    end

    return (halign, valign)
end
"""
    create_or_update_legend!(fig::Figure, plotted_objects::Vector, 
                             labels::Vector, manager::PlotManager)

Clears any existing Legend from the figure and creates a new one based on the
position specified in the manager's UI "Legend" scope[cite: 1601, 1607].
"""
function create_or_update_legend!(
    fig::Figure, 
    plotted_objects::Vector, 
    labels::Vector, 
    manager::PlotManager
)
   # --- 1. Find and Delete any existing Legend in the Figure ---
    # We search the main layout for any existing Legend block to ensure a clean update[cite: 1149].
    for elem in copy(contents(fig.layout))
        if elem isa Legend
            delete!(elem)
        end
    end

    # --- 2. Get Legend Properties from PlotManager ---
    # Access the scoped observables directly from the manager.
    ui_leg = manager.ui["Legend"]
    ui_axis = manager.ui["Axis"]
    
    position = ui_leg["legend_pos"][]
    title_str = ui_leg["legend"][]
    font_size = ui_axis["font_size"][]

    if isempty(plotted_objects) || isempty(labels)
        # If no items are plotted, clean up the layout and return[cite: 1151].
        try
            trim!(fig.layout) 
        catch e
            # Ignore if layout is already clean
        end
        return
    end

    # --- 3. Create and Place the New Legend ---
    try
        # Convert empty strings to nothing for cleaner Makie titles[cite: 1152].
        final_title = isempty(strip(title_str)) ? nothing : title_str

        if position == "detached"
            # Places the legend in a new column to the right of the axis[cite: 1147, 1153].
            trim!(fig.layout)
            Legend(fig[1, end+1], plotted_objects, labels, final_title;
                tellheight=false,
                merge = true,
                unique = true,
                titlesize=font_size,
                labelsize=font_size
            )
            # Ensure the new column's width is determined by the legend content[cite: 1155].
            colsize!(fig.layout, 2, Auto())
        else
            # Places the legend inside the axis at a specified anchor point[cite: 1148].
            # This uses your existing _parse_legend_position helper[cite: 1144, 1156].
            halign, valign = _parse_legend_position(position)
            
            Legend(fig[1,1], plotted_objects, labels, final_title;
                orientation = :vertical,
                tellheight=false, 
                tellwidth=false,
                halign = halign,
                valign = valign,
                merge = true,
                unique = true,
                titlesize=font_size,
                labelsize=font_size,
                margin=(10, 10, 10, 10)
            )
            # Trim layout to ensure no empty ghost columns remain[cite: 1158].
            trim!(fig.layout)
        end
    catch e
        @error "Failed to create or update legend." exception=(e, catch_backtrace())
    end
end

"""
    set_axis_styles!(ax, ui_options_obs, final_label_obs)

Applies a set of styles to a given `Axis` object. It now takes a dictionary
of final, combined observables for the title and labels.
"""
function set_axis_styles!(
    ax::Axis,
    ui_options_obs::Dict{String, Observable}
)
    try
        
        # Set other visual properties directly from the ui_options_obs dictionary
        ax.xgridvisible = ui_options_obs["xgridvisible"][]
        ax.ygridvisible = ui_options_obs["ygridvisible"][]
        ax.xticklabelsvisible = ui_options_obs["xticklabelsvisible"][]
        ax.yticklabelsvisible = ui_options_obs["yticklabelsvisible"][]
        
        # Set text sizes
        ax.titlesize = ui_options_obs["title_size"][]
        ax.xlabelsize = ui_options_obs["label_size"][]
        ax.ylabelsize = ui_options_obs["label_size"][]
        ax.xticklabelsize = ui_options_obs["ticklabel_size"][]
        ax.yticklabelsize = ui_options_obs["ticklabel_size"][]

        # --- NEW: Set Tick Positions ---
        xtick_count = ui_options_obs["xtick_count"][]
        ytick_count = ui_options_obs["ytick_count"][]
        
        # Use a tick count of 0 as a signal to use Makie's automatic default.
        if xtick_count > 0
            ax.xticks = ax.xscale[] == log10 ? LogTicks(LinearTicks(xtick_count)) : LinearTicks(xtick_count)
        end
        if ytick_count > 0
            ax.yticks = ax.yscale[] == log10 ? LogTicks(LinearTicks(ytick_count)) : LinearTicks(ytick_count)
        end

        # --- Set X-Axis Scale and Tick Formatting ---
        x_offset = ui_options_obs["xscale_offset"][]
        if x_offset != 0.0
            #ax.xscale = identity
            ax.xtickformat = tick_values -> map(x -> "$(round(x_offset, sigdigits=3)) + $(@sprintf("%.1e", x - x_offset))", tick_values)
        else
            xformat = ui_options_obs["xtickformat"][]
            ax.xtickformat = xformat == "default" ? Makie.automatic : xformat
        end

        # --- Set Y-Axis Scale and Tick Formatting ---
        y_offset = ui_options_obs["yscale_offset"][]
        if y_offset != 0.0
            #ax.yscale = identity
            ax.ytickformat = tick_values -> map(tick_values) do y
                deviation = y - y_offset
                offset_str = string(round(y_offset, sigdigits=3))
                # --- THIS IS THE FIX FOR THE SIGN ---
                sign_str = deviation < 0 ? "-" : "+"
                "$(offset_str) $(sign_str) $(@sprintf("%.1e", abs(deviation)))"
            end
        else
            yformat = ui_options_obs["ytickformat"][]
            ax.ytickformat = yformat == "default" ? Makie.automatic : yformat
        end
    catch e
        @warn "An error occurred while setting axis styles. A required key might be missing." exception=(e, catch_backtrace())
    end
end
"""
    set_axis_styles!(ax::Axis3, ui_options_obs)

Dynamically switches between 3D perspective and 2D top-down views.
Assumes all required keys exist in `ui_options_obs`.
"""
function set_axis_styles!(
    ax::Axis3,
    ui_options_obs::Dict{String, Observable}
)
    try
        plot_type = ui_options_obs["plot_type"][]
        is_3d_view = plot_type in [:surface, :scatter3d] 

        # --- Common Font Sizes ---
        ax.titlesize = ui_options_obs["title_size"][]
        ax.xlabelsize = ui_options_obs["label_size"][]
        ax.ylabelsize = ui_options_obs["label_size"][]
        ax.xticklabelsize = ui_options_obs["ticklabel_size"][]
        ax.yticklabelsize = ui_options_obs["ticklabel_size"][]

        if is_3d_view
            # --- 3D Perspective Configuration ---
            ax.zlabel = "z"
            ax.zlabelsize = ui_options_obs["label_size"][]
            ax.zticklabelsize = ui_options_obs["ticklabel_size"][]
            
            ax.aspect = (1, 1, 0.6) 
            ax.perspectiveness = 0.5
            #ax.viewmode = :fit

            ax.xgridvisible = true; ax.ygridvisible = true; ax.zgridvisible = true
            ax.xticklabelsvisible = true; ax.yticklabelsvisible = true; ax.zticklabelsvisible = true
            
            # --- 3D Offsets & Pads ---
            ax.xlabeloffset = ui_options_obs["xlabel_offset_3d"][]
            ax.ylabeloffset = ui_options_obs["ylabel_offset_3d"][]
            ax.zlabeloffset = ui_options_obs["zlabel_offset_3d"][]
            

        else
            # Use Mixed alignmode to force padding at the bottom
            b_margin = ui_options_obs["bottom_margin_2d"][]
            
            # Mixed(bottom = X) reserves X pixels at the bottom, shrinking the axis height
            ax.alignmode = Mixed(bottom = b_margin, left = 0, right = 0, top = 0)
            # --- 2D Top-Down Configuration ---
            ax.zlabel = "" 
            ax.zlabelsize = 0
            ax.zticklabelsvisible = false
            ax.zgridvisible = false
            
            ax.perspectiveness = 0.0 
            ax.elevation = pi/2       
            ax.azimuth = -pi/2        
            ax.aspect = :data 

            
            # Move Labels away from the Ticks
            ax.xlabeloffset = ui_options_obs["xlabel_offset_2d"][]
            ax.ylabeloffset = ui_options_obs["ylabel_offset_2d"][]
            
            ax.xgridvisible = true; ax.ygridvisible = true
        end

    catch e
        @warn "Error setting axis styles. A required key might be missing in ui_options_obs." exception=(e, catch_backtrace())
    end
end

function set_scene_options!(scene_obs::Dict{String,Observable}, scene_options::Dict{String,Any})
    for (key, val) = scene_obs
        if haskey(scene_options, key); val[] = scene_options[key] end
    end
end

function save_scene_info!(scene_obs::Dict{String,Observable}, scene_info::Dict{String,Any})
    for (key,val) = scene_obs
        scene_info[key] = to_value(val)
    end
end

"""
    create_axis_label_observables(ui_options_obs, default_values) -> Dict

Creates a dictionary of final, combined observables for axis labels and titles.

It iterates through a `default_values` dictionary. For each entry, it creates
a `lift` that combines the user's input from `ui_options_obs` with the
provided default. If the user's input is "default", the fallback value is used.
The fallback can be static (e.g., a String) or dynamic (an Observable).

# Arguments
- `ui_options_obs::Dict{String, Observable}`: The dictionary of raw UI observables.
- `default_values::Dict{String, Any}`: Maps a UI key (e.g., "xlabel") to its default value.

# Returns
- `Dict{String, Observable}`: A dictionary mapping UI keys to the final observables
  that should be used to set axis properties.
"""
function create_axis_label_observables(
    ui_options_obs::Dict{String, Observable},
    default_values::Dict{String, Any}
)
    final_label_obs_dict = Dict{String, Observable}()

    for (key, default_val) in default_values
        if !haskey(ui_options_obs, key)
            @warn "UI option key '$key' not found in ui_options_obs. Skipping label creation."
            continue
        end

        ui_obs = ui_options_obs[key]

        local final_obs # Ensure it's scoped for the if/else block
        if isa(default_val, Observable)
            # Dynamic default: lift on both user input and the default's observable
            final_obs = lift(ui_obs, default_val) do user_input, dynamic_default
                user_input == "default" ? dynamic_default : user_input
            end
        else # Static default (e.g., a simple String)
            final_obs = lift(ui_obs) do user_input
                user_input == "default" ? default_val : user_input
            end
        end
        final_label_obs_dict[key] = final_obs
    end

    return final_label_obs_dict
end

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
    calculate_padded_axis_range(raw_limits, padding_factor, is_log_scale) -> Tuple

Takes raw (min, max) limits and applies padding, correctly handling the
fallback from log to linear scale if the data range is not positive.
"""
function calculate_padded_axis_range(raw_limits::Tuple, padding_factor::Real, is_log_scale::Bool)
    min_raw, max_raw = raw_limits
    
    if isnothing(min_raw) || isnothing(max_raw) || !isfinite(min_raw) || !isfinite(max_raw)
        return (0.0, 1.0) # Default if no valid data
    end

    # Check for log scale validity. If user wants log but data is not positive,
    # fall back to linear scale for this calculation.
    use_log = is_log_scale && (min_raw > 0)
    
    if use_log
        pad = padding_factor
        final_min = min_raw / (1 + pad)
        final_max = max_raw * (1 + pad)
    else
        if is_log_scale && min_raw <= 0
            @warn "Log scale requested but data contains non-positive values. Applying linear padding instead."
        end
        data_range = max_raw - min_raw
        pad = data_range ≈ 0 ? 0.1 : (data_range * padding_factor / 2.0)
        final_min = min_raw - pad
        final_max = max_raw + pad
    end
    
    return (final_min, final_max)
end

function deleteUIOptions!(
    ui_options_dict::Dict,
    keys_to_delete::AbstractVector{String}
)
    for key in keys_to_delete
        if haskey(ui_options_dict, key)
            delete!(ui_options_dict, key)
        else
            # Optional: Warn if a key to be deleted doesn't exist.
            # @warn "Attempted to delete non-existent UI option key: '$key'"
        end
    end
    # The dictionary is modified in-place, so no return is necessary.
    return nothing
end

"""
    _safe_extrema(data_slices::Vector{Vector{Float64}})

Safely finds the global (min, max) across multiple data slices, ignoring NaNs and Infs.
"""
function _safe_extrema(data_slices)
    mins, maxs = Float64[], Float64[]
    for slice in data_slices
        valid_data = filter(isfinite, slice) # Removes NaN and Inf
        if !isempty(valid_data)
            push!(mins, minimum(valid_data))
            push!(maxs, maximum(valid_data))
        end
    end
    isempty(mins) && return (0.0, 1.0) # Fallback if all data is NaN
    return (minimum(mins), maximum(maxs))
end

"""
    set_axis_limits_manager!(ax, xs, us, manager)
"""
function set_axis_limits_manager!(ax::Axis, xs, us, manager::PlotManager)
    ui_axis = manager.ui["Axis"]
    
    # Use the new safe extrema helper
    raw_xlims = _safe_extrema(xs)
    raw_ylims = _safe_extrema(us)

    final_xlims = calculate_padded_axis_range(raw_xlims, ui_axis["xpadding"][], ui_axis["xlogscale"][])
    final_ylims = calculate_padded_axis_range(raw_ylims, ui_axis["ypadding"][], ui_axis["ylogscale"][])

    try limits!(ax, final_xlims..., final_ylims...) catch; end
    
    ax.xscale[] = final_xlims[1] > 0 && ui_axis["xlogscale"][] ? log10 : identity
    ax.yscale[] = final_ylims[1] > 0 && ui_axis["ylogscale"][] ? log10 : identity
end

"""
    plot_extrema_lines_manager!(ax, x_data, u_data, manager, plot_idx)
"""
function plot_extrema_lines_manager!(ax, x_data, u_data, manager, plot_idx)
    ui_app = manager.ui["Appearance"]
    ui_various = manager.ui["Various"]
    
    track_max = ui_various["track_max"][]
    track_min = ui_various["track_min"][]
    (!track_max && !track_min) && return

    # Filter pairs to keep x and u aligned
    valid_pairs = filter(p -> isfinite(p[2]), collect(zip(x_data, u_data)))
    isempty(valid_pairs) && return
    
    color = ui_app["colors"][][mod1(plot_idx, end)]
    lw = ui_app["linewidth"][] / 2

    if track_max
        # findmax on tuples compares the first element by default, so we map to u_data
        max_u, idx = findmax(p -> p[2], valid_pairs)
        max_x = valid_pairs[idx][1]
        linesegments!(ax, [Point2f(max_x, 0), Point2f(max_x, max_u)]; 
                      color=(color, 0.7), linestyle=:dash, linewidth=lw)
    end
    
    if track_min
        min_u, idx = findmin(p -> p[2], valid_pairs)
        min_x = valid_pairs[idx][1]
        linesegments!(ax, [Point2f(min_x, 0), Point2f(min_x, min_u)]; 
                      color=(color, 0.7), linestyle=:dot, linewidth=lw)
    end
end

#======================================================================#
#           NEW INTERNAL HELPER FOR OUTLIER DETECTION
#======================================================================#

"""
    _find_outlier_indices(y_data, ui_options_obs) -> Vector{Int}

Identifies the indices of extreme outliers in a vector using a tunable IQR method.
The threshold is controlled by the "outlier_threshold" key in `ui_options_obs`.
"""
function _find_outlier_indices(
    y_data::AbstractVector,
    threshold::Real
)
    if length(y_data) < 5; return Int[]; end

    finite_y_data = filter(isfinite, y_data)
    if length(finite_y_data) < 5; return Int[]; end

    q1 = quantile(finite_y_data, 0.25)
    q3 = quantile(finite_y_data, 0.75)
    iqr = q3 - q1
    
    # Define the valid range using the tunable threshold
    lower_bound = q1 - threshold * iqr
    upper_bound = q3 + threshold * iqr
    
    # Find the indices of the original vector that are outliers
    return findall(y -> isfinite(y) && (y < lower_bound || y > upper_bound), y_data)
end


"""
    _find_outlier_indices(matrix::AbstractMatrix, threshold::Real) -> Vector{CartesianIndex}

Identifies the indices of extreme outliers in a matrix using a tunable IQR method.
It works by flattening the matrix and applying the 1D outlier logic.
"""
function _find_outlier_indices(
    matrix::AbstractMatrix,
    threshold::Real
)::Vector{CartesianIndex}
    # Flatten the matrix to a vector to reuse the existing IQR logic
    flat_vector = vec(matrix)
    
    # Get the linear indices of outliers in the flattened vector
    linear_outlier_indices = _find_outlier_indices(flat_vector, threshold)
    
    # Convert the linear indices back to Cartesian indices for the original matrix
    return CartesianIndices(matrix)[linear_outlier_indices]
end


"""
    create_or_update_colorbar!(fig::Figure, ui_options_obs, color_range_obs, label)

Creates a Colorbar explicitly linked to the global colormap and colorrange observables.
This avoids errors when plotting objects like Contours which contain Text elements.
"""
function create_or_update_colorbar!(
    fig::Figure,
    plot_object, # We keep this argument to check if a plot exists, but we won't extract from it
    ui_options_obs::Dict{String, Observable},
    color_range_obs::Observable{Tuple{Float64, Float64}}, # Pass the observable directly
    label::String,
)
    # --- 1. Find and Delete any existing Colorbar ---
    for elem in copy(contents(fig.layout))
        if elem isa Colorbar
            delete!(elem)
        end
    end

    # If no plot was actually created (e.g. empty data), don't draw a colorbar
    if isnothing(plot_object)
        return
    end

    # --- 2. Create the New Colorbar Explicitly ---
    try
        # Instead of passing `plot_object`, we pass the attributes explicitly.
        # This bypasses the "Text" error for contours.
        cb = Colorbar(fig[1, 2];
            colormap = ui_options_obs["colormap"],
            colorrange = color_range_obs,
            label = label,
            labelsize = ui_options_obs["label_size"][],
            ticklabelsize = ui_options_obs["ticklabel_size"][],
            # Optional: Add highclip/lowclip here if you use them in the main plot
        )
        
        # Ensure the colsize adjusts automatically
        colsize!(fig.layout, 2, Auto())
        
    catch e
        @error "Failed to create or update colorbar." exception=(e, catch_backtrace())
    end
end

"""
    extract_line_cut_data(x_points, u_values, line_point, line_vector, tolerance_dist)

Extracts a 1D slice of data from a 2D snapshot, preserving all solution components.

It finds all points within a specified orthogonal distance (`tolerance_dist`) of a line
and projects them to get a 1D coordinate. It returns these coordinates along with their
corresponding `u` values, which can be a vector (single component) or a matrix
(multiple components). The new 1D coordinate system is centered at `line_point`.

# Arguments
- `x_points::Vector{NTuple{2, Float64}}`: The (x,y) coordinates of the 2D data.
- `u_values::VecOrMat{<:Real}`: The solution values (Vector or Matrix) at each point.
- `line_point::NTuple{2, <:Real}`: The point `p` that the cut line passes through.
- `line_vector::NTuple{2, <:Real}`: The direction vector `v` of the cut line.
- `tolerance_dist::Real`: The maximum orthogonal distance for a point to be included.

# Returns
- A tuple `(cut_x_coords, cut_u_values::VecOrMat)` containing the sorted 1D data.
"""
function extract_line_cut_data(
    x_points::Vector{NTuple{2, Float64}},
    u_values::VecOrMat{<:Real},
    line_point::NTuple{2, <:Real},
    line_vector::NTuple{2, <:Real},
    tolerance_dist::Real
)
    if isempty(x_points) || isempty(u_values); return (Float64[], eltype(u_values)[]); end

    v_norm = sqrt(line_vector[1]^2 + line_vector[2]^2)
    if v_norm < 1e-9; return (Float64[], eltype(u_values)[]); end
    v_unit = (line_vector[1] / v_norm, line_vector[2] / v_norm)

    p = line_point
    cut_x = Float64[]
    
    # Store indices of points that are part of the cut
    valid_indices = Int[]

    for i in eachindex(x_points)
        q = x_points[i]
        w = (q[1] - p[1], q[2] - p[2])
        
        projected_coord = w[1] * v_unit[1] + w[2] * v_unit[2]
        dist_sq = (w[1]^2 + w[2]^2) - projected_coord^2
        orthogonal_dist = dist_sq > 0 ? sqrt(dist_sq) : 0.0
        
        if orthogonal_dist <= tolerance_dist
            push!(cut_x, projected_coord)
            push!(valid_indices, i)
        end
    end

    if !isempty(valid_indices)
        # Sort the results by the new 1D coordinate
        p = sortperm(cut_x)
        
        # Select and sort the u_values based on the valid indices and permutation
        if u_values isa AbstractMatrix
            cut_u = u_values[valid_indices, :]
            return (cut_x[p], cut_u[p, :])
        else # It's a Vector
            cut_u = u_values[valid_indices]
            return (cut_x[p], cut_u[p])
        end
    else
        # Return empty arrays with the correct type
        empty_u = u_values isa AbstractMatrix ? Matrix{eltype(u_values)}(undef, 0, size(u_values, 2)) : Vector{eltype(u_values)}()
        return (Float64[], empty_u)
    end
end

function update_base_plot_1D!(
    plot_fig::Figure,
    ax::Axis,
    active_methods::Vector{String}, # Labels
    xs_slices::Vector{Vector{Float64}}, # Sliced X data per method
    us_slices::Vector{Vector{Float64}}, # Sliced U data per method
    manager::PlotManager;
    xlabel::Union{String, Nothing} = nothing,    # NEW: Dynamic override
    ylabel::Union{String, Nothing} = nothing,    # NEW: Dynamic override
    title_str::Union{String, Nothing} = nothing  # NEW: Dynamic override
)
    # --- 1. Style & Figure Prep ---
    ui_axis = manager.ui["Axis"]
    ui_app = manager.ui["Appearance"]
    ui_leg = manager.ui["Legend"]
    ui_var = manager.ui["Various"]

    resize!(plot_fig, ui_axis["figsize"][][1], ui_axis["figsize"][][2])
    empty!(ax)
    isempty(active_methods) && return

    # --- 2. Sorting Logic (Matches your original) ---
    sort_key(label) = (contains(lowercase(label), "analytic") ? 0 : 1, label)
    p = ui_leg["sort_legend"][] ? sortperm(active_methods, by=sort_key) : 1:length(active_methods)

    plotted_objects = []
    labels_for_legend = String[]

    # --- 3. Plotting Loop ---
    for (plot_idx, data_idx) in enumerate(p)
        label = active_methods[data_idx]
        x_data = xs_slices[data_idx]
        u_data = us_slices[data_idx]

        # Styles
        color = ui_app["colors"][][mod1(plot_idx, end)]
        marker = ui_app["markers"][][mod1(plot_idx, end)]
        linestyle = ui_app["dashed_lines"][] ? ui_app["lineStyles"][][mod1(plot_idx, end)] : :solid
        lw = ui_app["linewidth"][]

        # Outlier Detection
        if ui_var["mark_outliers"][] || ui_var["remove_outliers"][]
            outlier_idx = _find_outlier_indices(u_data, ui_var["outlier_threshold"][])
            if ui_var["mark_outliers"][]
                vlines!(ax, x_data[outlier_idx]; color=(color, 0.4), linestyle=:dot, linewidth=lw/1.5)
            end
            if ui_var["remove_outliers"][]
                u_data[outlier_idx] .= NaN
            end
        end

        # Lines and Scatter
        objs = []
        if ui_app["show_lines"][]
            l = lines!(ax, x_data, u_data; color=color, linewidth=lw, linestyle=linestyle, label=label)
            push!(objs, l)
        end
        if ui_app["show_scatter"][]
            s = scatter!(ax, x_data, u_data; color=color, markersize=ui_app["markersize"][], marker=marker, label=label)
            push!(objs, s)
        end

        # Max/Min Tracking
        plot_extrema_lines_manager!(ax, x_data, u_data, manager, plot_idx)

        if !isempty(objs)
            push!(plotted_objects, objs)
            push!(labels_for_legend, label)
        end
    end

    # --- 4. Limits, Labels, and Legend ---
    set_axis_limits_manager!(ax, xs_slices, us_slices, manager)
    
# DYNAMIC LABEL LOGIC:
    # Use the passed key if provided, otherwise check UI dict for manual overrides [cite: 698, 699, 700]
    ax.xlabel = ui_axis["xlabel"][] == "default" ? xlabel : ui_axis["xlabel"][]
    ax.ylabel = ui_axis["ylabel"][] == "default" ? ylabel : ui_axis["ylabel"][]
    ax.title  = ui_axis["title"][] == "default" ? title_str : ui_axis["title"][]

    create_or_update_legend!(plot_fig, plotted_objects, labels_for_legend, manager)
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


