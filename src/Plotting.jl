# plotting_module.jl

module Plotting

using Plots
using Plots.PlotMeasures # Optional: for units like px, mm
using StatsBase          # For findmin
using ..Structs          # Access types from parent/sibling Structs module
using ..Utils            # Access utilities like loadSimData from parent/sibling Utils module

# Set a default backend for Plots.jl (optional, GR is common)
# gr()

export plot1dSolution

"""
    plot1dSolution(param_dicts::Vector{ParamDictType}, t_target::Real; plt_kwargs...)

Creates a non-interactive plot of 1D simulation data for multiple methods at a
specific target time using Plots.jl.

Loads data corresponding to each dictionary in `param_dicts`, finds the time step
closest to `t_target`, and plots the solution `u` vs. position `x` for that time step.

# Arguments
- `param_dicts`: A vector of parameter dictionaries. Each dict must allow loading
                 simulation data (SimData1D expected) and should contain a
                 "method" key for labeling.
- `t_target`: The target time point to plot.
- `plt_kwargs`: Keyword arguments to be passed to the `Plots.plot` or `Plots.plot!`
                functions (e.g., `linewidth=3`, `legend=:outertopright`,
                `markershape=:circle`, `markersize=4`, `size=(900,600)`).

# Returns
- A `Plots.Plot` object. Returns an empty plot if no valid data is found.
"""
function plot1dSolution(param_dicts::Vector{ParamDictType}, t_target::Real; plt_kwargs...)
    # --- Default plot attributes (can be overridden by plt_kwargs) ---
    defaults = Dict(
        :linewidth => 2,
        :markershape => :none, # Default to lines without markers
        :markersize => 4,
        :legend => :outertopright,
        :size => (800, 600), # Default figure size
        :margin => 5mm # Add some margin
    )
    plot_attrs = merge(defaults, Dict(plt_kwargs))

    # --- Initialize Plot ---
    # Extract attributes relevant for the initial plot call
    init_attrs = Dict(k => v for (k, v) in plot_attrs if k in (:size, :legend, :title, :xlabel, :ylabel, :xlims, :ylims, :margin))
    plt = plot(; init_attrs...) # Create an empty plot with basic settings

    actual_time_used = NaN # To store the time actually plotted for the title
    plot_occurred = false  # Flag to check if any data was plotted

    println("Generating 1D plot for t ≈ $t_target...")

    # --- Loop through provided parameter sets ---
    for (i, params) in enumerate(param_dicts)
        method_name = get(params, "method", "Method $i") # Use "Method i" as fallback label
        println(" Processing: $method_name")

        local sim_data::Union{AbstractSimData, Nothing} = nothing
        try
            # Load the simulation data using the utility function
            sim_data = Utils.loadSimData(params)
        catch e
            if isa(e, SimFileNotFoundError) # Catch the specific error
                 @warn "Data not found for method '$method_name' (Params: $params)."
            else # Handle other unexpected loading errors
                @warn "Failed to load data for method '$method_name'." exception=(e, catch_backtrace())
            end
            continue # Skip this method if loading fails
        end

        # --- Validate Data ---
        if isnothing(sim_data) || !isa(sim_data, SimData1D) ||
           !hasproperty(sim_data, :t) || !hasproperty(sim_data, :x) || !hasproperty(sim_data, :u)
            @warn "Loaded data for '$method_name' is not valid SimData1D or missing required fields. Skipping."
            continue
        end
        if isempty(sim_data.t) || isempty(sim_data.x) || isempty(sim_data.u) ||
           length(sim_data.t) != length(sim_data.x) || length(sim_data.t) != length(sim_data.u)
             @warn "Loaded data for '$method_name' has empty or inconsistent array lengths. Skipping."
             continue
        end
        # --- End Validation ---

        # --- Find Closest Time Step ---
        t_vec = sim_data.t
        if isempty(t_vec) # Should be caught above, but double-check
            @warn "Time vector empty for '$method_name'. Skipping."
            continue
        end
        (_, m) = findmin(a -> abs(a - t_target), t_vec) # Find index of closest time
        # Store the first valid time found for the title
        if isnan(actual_time_used); actual_time_used = t_vec[m]; end
        # --------------------------

        # --- Extract Snapshot ---
        if !(1 <= m <= length(sim_data.x) && 1 <= m <= length(sim_data.u))
             @warn "Closest time index '$m' is invalid for data arrays for method '$method_name'. Skipping."
             continue
        end
        x_snapshot = sim_data.x[m]
        u_snapshot = sim_data.u[m]
        if isempty(x_snapshot) || isempty(u_snapshot)
             @warn "Snapshot data empty at index '$m' (t=$(t_vec[m])) for method '$method_name'. Skipping."
             continue
        end
        # --------------------

        # --- Add Data Series to Plot ---
        # Extract attributes relevant for series plotting from plot_attrs
        series_attrs = Dict(k => v for (k, v) in plot_attrs if k in (:linewidth, :markershape, :markersize, :linecolor, :markercolor, :linestyle, :seriescolor, :markerstrokewidth, :markerstrokecolor))
        # Plots.jl handles color cycling automatically by default

        try
            plot!(plt, x_snapshot, u_snapshot; label=method_name, series_attrs...)
            plot_occurred = true # Mark that we plotted something
        catch e
             @error "Failed to plot data for method '$method_name'." exception=(e, catch_backtrace())
        end
        # ------------------------

    end # --- End loop over param_dicts ---

    # --- Finalize Plot ---
    final_title = isnan(actual_time_used) ? "Solution (No Data Found)" : "Solution at t ≈ $(round(actual_time_used, digits=3))"
    # Apply overall attributes (title, labels) only if not already set by kwargs
    plot!(plt;
          title = get(plot_attrs, :title, final_title),
          xlabel = get(plot_attrs, :xlabel, "Position (x)"),
          ylabel = get(plot_attrs, :ylabel, "Solution Value (u)")
         )

    if !plot_occurred
        # Add annotation if nothing was plotted
        annotate!(plt, 0.5, 0.5, text("No valid data to plot", :center, :red, 12), subplot=1)
    end

    println("Plot generation complete.")
    return plt
    # --- End Finalize ---

end # End function plot1dSolution

# --- Add other non-interactive plotting functions below ---
# function plot2dSolution(...) ... end
# function plotConvergence(...) ... end

end # --- End module Plotting ---