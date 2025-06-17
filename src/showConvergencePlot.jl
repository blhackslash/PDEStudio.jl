
"""
    showConvergencePlot(sim_config::SimulationConfig,
                        key::String,
                        param_values::Union{AbstractVector, AbstractRange},
                        y_stat_key::String;
                        run_simulations::Bool = true,
                        force_int_param::Bool = false)

Plots a specific simulation statistic against a varied parameter.

Runs simulations varying `key` over `param_values` for active methods.
Plots `param_values` (X-axis) vs. the statistic `y_stat_key` (Y-axis).
A time slider is shown only if `y_stat_key` is found to be time-dependent.

# Arguments
- `sim_config`: Base SimulationConfig defining methods, base params, sim function.
- `key`: String name of the parameter to vary (plots on X-axis).
- `param_values`: Vector or Range of values for `key`.
- `y_stat_key`: String name of the statistic to plot on the Y-axis.
- `run_simulations`: If true (default), runs simulations. Assumes `loadSimData` otherwise.
- `force_int_param`: If true, attempts `trunc(Int, value)` for the varied parameter `key`.
"""
function showConvergencePlot(
    sim_config::SimulationConfig,
    key::String,
    param_values::Union{AbstractVector, AbstractRange},
    y_stat_key::String;
    force_int_param::Bool = false,
    initial_calc::Bool = true,
    ui_options::UIType = :default
    )

    # Runs the simulation for the initial values
    if initial_calc
        calculateConvergenceData(sim_config, key, param_values; force_int_param = force_int_param, force_overwrite = false)
    end

    # --- Basic Setup & UI ---
    local_ui_dict = createUIDict(ui_options)
    plot_fig = Figure(size = local_ui_dict["figsize"])
    ax = Axis(plot_fig[1,1], title="Convergence: $y_stat_key vs $key", xlabel=key, ylabel=y_stat_key)
    
    # --- CONSTANT X-Axis Data ---
    actual_param_values_used = try
        force_int_param ? map(v -> trunc(Int64, v), param_values) : collect(param_values)
        #Float64.(vals) # Ensure Float64 for plotting
    catch e
        @error "Could not process param_values for $key." exception=(e, catch_backtrace())
        return plot_fig, Figure() # Return empty figures on error
    end
    if isempty(actual_param_values_used); @warn "Empty parameter values provided."; return plot_fig, Figure(); end
    num_params = length(actual_param_values_used)

    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    methods_obs = Observable(issubset(sim_config.default_methods,all_method_names) ? sim_config.default_methods : all_method_names)
    method_number = lift(length, methods_obs)

    # --- Call the NEW createControls function ---
    control_fig, update_notifier, legend_pos_obs = createBaseControlsFigure(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        local_ui_dict
    )
    # -----------------------------------------

# --- Log Scale Toggles ---

    # Add Checkboxes to control figure (adjust row/column layout as needed)
    # Example: Placing them side-by-side in a new row, spanning 2 columns each
    log_scale_layout = control_fig[end+1, :] = GridLayout() # Span 4 columns for example
    cb_log_x = Toggle(log_scale_layout[1, 1], active = false) # Span cols 1-2
    Label(log_scale_layout[1,2], "Log-scale x-axis")
    cb_log_y = Toggle(log_scale_layout[1, 3], active = false) # Span cols 3-4
    Label(log_scale_layout[1,4], "Log-scale y-axis")

    # --- Link Log Scale Toggles to Axis Scale ---
    on(cb_log_x.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        # --- CORRECT WAY: Update value inside the observable ---
        xlims!(ax, (.1,1))
        ax.xscale[] = new_scale_func
        # ------------------------------------------------------
        println("X-Axis scale set to: ", ax.xscale[]) # Debug print shows the function name
    end

    on(cb_log_y.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        # --- CORRECT WAY: Update value inside the observable ---
        ylims!(ax, (.1,1))
        ax.yscale[] = new_scale_func
        # ------------------------------------------------------
        println("Y-Axis scale set to: ", ax.yscale[])
    end
    # ------------------------------------------
    lift(cb_log_x.active) do is_active
            # --- Calculate and Set X-Limits ONCE ---
        min_x_data, max_x_data = extrema(actual_param_values_used)
        # Get padding factor from ui_dict, default to 0.1 (10%) if not found
        pad_x_factor = to_value(is_active) ? 0 : get(local_ui_dict, "x_axis_limit_padding", 0.1)
        x_range = max_x_data - min_x_data
        x_pad = x_range ≈ 0 ? 0.1 : (x_range * pad_x_factor / 2.0) # Handle zero range
        final_xlims = (min_x_data - x_pad, max_x_data + x_pad)
        try; xlims!(ax, final_xlims); catch e; @warn "Failed to set initial xlims" exception=(e, catch_backtrace()); end
    end
    # --- Time Slider (Always Visible, label changes) ---
    is_y_stat_time_dependent = Observable(true) # Updated in Lift 1
    tLabel_text = Observable("t = ...")
    Label(control_fig[end+1, 1:2], tLabel_text, tellwidth=false).padding = (0, 0, 5, 0)
    tSlider = Slider(control_fig[end+1, 1:2], range = 0.0:1.0, startvalue = 0.0)

    # --- SIMPLIFIED Data Storage ---
    # Structure: [method_idx][param_idx] -> Tuple( raw_Y_stat :: Any, times :: Vector{Float64} )
    raw_data_store = Observable(Vector{Vector{Tuple{Any, Vector{Float64}}}}(undef, 0))
    # Structure: [method_idx] -> Observable{Vector{Float64}} (holds current Y snapshot)
    y_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

    # --- Lift 1: Data Loading / Simulation & Initial Snapshot ---
    lift(update_notifier; ignore_equal_values=true) do _
        active_num = length(methods_obs[])
        if active_num == 0
            raw_data_store[] = []; y_plot_data_methods[] = []
            is_y_stat_time_dependent[] = true; tSlider.range = 0.0:1.0; set_close_to!(tSlider, 0.0); tLabel_text[] = "t = N/A"
            return
        end
        println("Lift 1: Running/Loading simulations...")

        temp_raw_data = Vector{Vector{Tuple{Any, Vector{Float64}}}}(undef, active_num)
        all_times_union = Set{Float64}()

        # --- Simulation Loop ---
        for i = 1:active_num
            method = methods_obs[][i]
            raw_data_for_method = Vector{Tuple{Any, Vector{Float64}}}(undef, num_params)
            base_params = assembleParams(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )

            # === Optional: Threads.@threads for j = 1:num_params ===
            for j = 1:num_params
                current_value = actual_param_values_used[j]
                current_params = copy(base_params); 
                current_params[key] = current_value;

                stat_val_for_run = missing; time_vec_for_run = Float64[]
                try
                    # --- Run or Load ---
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                    if !Utils.doesSimDataExist(current_params)
                        println(" Running simulation for method: $method")
                        sim_data = sim_config.sim_function(current_params)
                        Utils.saveSimData(sim_data) # Assumes saveSimData exists
                    else
                        println(" Loading data for method: $method")
                        sim_data = Utils.loadSimData(current_params)
                    end
                    # --- Extract ONLY Needed Data ---
                    if !isnothing(sim_data) && hasproperty(sim_data, :stats) && hasproperty(sim_data, :t) && isa(sim_data.stats, AbstractDict)
                        stat_val_for_run = get(sim_data.stats, y_stat_key, missing)# Use get for safety
                        if isa(sim_data.t, AbstractVector); time_vec_for_run = sim_data.t; union!(all_times_union, time_vec_for_run); end
                    end
                catch e; @error "Sim/Load Error" exception=(e, catch_backtrace()); end
                raw_data_for_method[j] = (stat_val_for_run, time_vec_for_run)
            end # End j loop
            temp_raw_data[i] = raw_data_for_method
        end # End i loop
        # --- End Simulation Loop ---

        println("Finished runs. Updating observables...")
        raw_data_store[] = temp_raw_data # Store the collected raw data

         # --- Check Time Dependence of y_stat_key (REVISED LOGIC + DEBUG PRINTS) ---
         println("--- Checking time dependence for key: '$y_stat_key' ---")
         found_vector = false        # Ever found a valid Vector?
         found_scalar = false        # Ever found a valid Number?
         found_any_valid = false     # Found the key with a valid type at least once?
         processed_runs_with_key = 0 # Count runs where key was present
 
         # Iterate through the collected raw data (List per method -> List per param -> Tuple(raw_val, times))
         for (i_meth, method_data_list) in enumerate(temp_raw_data) # Use temp_raw_data from this lift block
             for (j_param, (raw_val, _)) in enumerate(method_data_list) # Unpack the tuple
 
                  # Check if the key was actually present and extracted (value is not missing)
                  if !ismissing(raw_val)
                     processed_runs_with_key += 1
                     found_any_valid = true # Mark that we found the key at least once
                     val_type = typeof(raw_val)
                     #print("  Run (Meth $i_meth, Param $j_param): Found '$y_stat_key', Type: $val_type")
 
                     # Check for recognized types and update flags
                     # Ensure vectors are non-empty and contain numbers
                     if isa(raw_val, AbstractVector) && !isempty(raw_val) && all(isa.(raw_val, Number))
                         found_vector = true; #print(" -> Vector\n")
                     elseif isa(raw_val, Number)
                         found_scalar = true; #print(" -> Scalar\n")
                     else
                         # Key exists but value is not a Number or a valid Vector (e.g., empty Vector, Nothing, String)
                         #print(" -> Other/Empty/Invalid Type\n")
                     end
 
                     # Optimization: If we've already found both types, we know it's inconsistent
                     if found_vector && found_scalar
                         println("      Inconsistency (Vector & Scalar) detected.")
                         # Optional: break loops early if needed, but completing allows full type survey
                         # break # breaks inner loop
                     end
                  # else: raw_val is missing (key wasn't in original stats dict)
                  #   println(" Key '$y_stat_key' was missing in this run.") # Optional debug
                  end
             end # End inner loop (param values)
             # if found_vector && found_scalar; break; end # Optional: break outer loop
         end # End outer loop (methods)
         println("--- Finished check. Processed $processed_runs_with_key runs containing the key '$y_stat_key' ---")
         println("    Final flags: found_any_valid=$found_any_valid, found_vector=$found_vector, found_scalar=$found_scalar")
 
         # Determine final is_td based *only* on whether both types were found, or only one.
         local is_td
         if !found_any_valid
              @error "Stat key '$y_stat_key' not found or has no valid data (Number/Vector)! Assuming non-time-dependent."
              is_td = false # Or handle as error? Defaulting to false.
         elseif found_vector && found_scalar # Inconsistent types found across runs
              @warn "Stat key '$y_stat_key' has inconsistent types (scalar/vector)! Treating as time-dependent."
              is_td = true
         elseif found_vector # Only vectors found
              is_td = true
         elseif found_scalar # Only scalars found
              is_td = false
         else
              # This case should ideally not be reached if found_any_valid is true.
              # It might mean the value was present but wasn't Number or valid Vector.
              @warn "Stat key '$y_stat_key' found, but not as Number or valid Vector. Assuming non-time-dependent."
              is_td = false
         end
         is_y_stat_time_dependent[] = is_td # Update the observable
         println("Statistic is time dependent: $is_td")
         # --- End Time Dependence Check ---
 
         # --- Update Time Slider Range AND Label Text ---
         # (This part uses the is_td determined above - remains the same)
         time_vec = isempty(all_times_union) ? [0.0] : sort(collect(all_times_union))
         t_range = range(extrema(time_vec)..., length=max(2, length(time_vec)*2+80))
         if tSlider.range[] != t_range; tSlider.range = t_range; end
         set_close_to!(tSlider, clamp(tSlider.value[], extrema(t_range)...))
         if is_td; tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"; else; tLabel_text[] = "t = N/A (Scalar Stat)"; end

        # --- Calculate Initial Y Plot Data Snapshot ---
        current_y_plot_data = [Observable(fill(NaN, num_params)) for _ in 1:active_num] # Initialize with NaN
        current_t = tSlider.value[]

        for i = 1:active_num
            y_vals = fill(NaN, num_params) # Use NaN as default
            raw_method_data = raw_data_store[][i] # Access stored raw data

            for j = 1:num_params
                 raw_stat_val, times = raw_method_data[j]
                 if !ismissing(raw_stat_val)
                     if is_td
                         if isa(raw_stat_val, AbstractVector) && !isempty(times) && !isempty(raw_stat_val)
                             (_, m_ij) = findmin(a -> abs(a - current_t), times)
                             if m_ij <= length(raw_stat_val); y_vals[j] = Float64(raw_stat_val[m_ij]); end
                         elseif isa(raw_stat_val, Number); y_vals[j] = Float64(raw_stat_val); end # Inconsistent case
                     elseif isa(raw_stat_val, Number); y_vals[j] = Float64(raw_stat_val); end
                 end
            end
            current_y_plot_data[i][] = y_vals
        end
        y_plot_data_methods[] = current_y_plot_data # Update the observable for plotting
        # --- End Snapshot Calculation ---
    end # --- End Lift 1 ---


    # --- Lift 2: Snapshot Update (Simpler) ---
    lift(tSlider.value; ignore_equal_values=true) do t
        if !is_y_stat_time_dependent[]; return; end # Only run if time-dependent

        tLabel_text[] = "t = $(round(t, digits=3))"
        active_num = method_number[]
        # Consistency check for safety
        if length(y_plot_data_methods[]) != active_num || length(raw_data_store[]) != active_num || active_num == 0; return; end

        # Recalculate Y snapshot data based on new time t
        for i = 1:active_num
            y_vals = fill(NaN, num_params)
            raw_method_data = raw_data_store[][i] # Get stored raw data

            for j = 1:num_params
                 raw_stat_val, times = raw_method_data[j]
                 if !ismissing(raw_stat_val)
                     # is_td must be true here
                     if isa(raw_stat_val, AbstractVector) && !isempty(times) && !isempty(raw_stat_val)
                         (_, m_ij) = findmin(a -> abs(a - t), times)
                         if m_ij <= length(raw_stat_val); y_vals[j] = Float64(raw_stat_val[m_ij]); end
                     elseif isa(raw_stat_val, Number); y_vals[j] = Float64(raw_stat_val); end # Inconsistent case
                 end
            end
             # Update the inner observable for this method's Y plot data
             if i <= length(y_plot_data_methods[]); y_plot_data_methods[][i][] = y_vals; end
        end
    end # --- End Lift 2 ---


    # --- Lift 3: Plot Management (Uses constant X-data) ---
    lift(update_notifier; ignore_equal_values=true) do _ 
        active_num = length(methods_obs[])
        # Handles adding/removing plot objects when active methods change
        empty!(ax)
        for c in contents(plot_fig.layout); if isa(c, Legend); delete!(c); end; end # Clear potential legend
        if active_num == 0; return; end
        active_methods = methods_obs[]

        # Consistency check
        num_data_series_y = length(y_plot_data_methods[])
        if num_data_series_y != active_num
             num_to_plot = min(active_num, num_data_series_y); if num_to_plot <= 0; return; end
             @warn "Lift 3: Data series mismatch. Plotting $num_to_plot series."
        else; num_to_plot = active_num; end

        plotted_objects = []
        for i = 1:num_to_plot
            plotLabel = active_methods[i]
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            y_data_obs = y_plot_data_methods[][i] # Get the observable for Y snapshot

            # === Plot using the CONSTANT actual_param_values_used for X ===
            obj_for_legend = nothing
            # Note: Check local_ui_dict exists and has these keys
            show_lines = get(local_ui_dict, "show_lines", true)
            show_scatter = get(local_ui_dict, "show_scatter", true)

            if show_lines
                 l = lines!(ax, actual_param_values_used, y_data_obs;
                       color=color, linewidth=get(local_ui_dict,"linewidth", 1.5), label=plotLabel)
                 obj_for_legend = l
            end
            if show_scatter
                 s = scatter!(ax, actual_param_values_used, y_data_obs;
                         color=color, markersize=get(local_ui_dict,"markersize", 8), marker=marker, label=plotLabel)
                 if obj_for_legend === nothing; obj_for_legend = s; end
            end
            if obj_for_legend !== nothing; push!(plotted_objects, obj_for_legend); end
            # ======================================================
        end

        # Add Legend
        if !isempty(plotted_objects)
             try # Add legend in column 2
                 for c in contents(plot_fig.layout); if isa(c, Legend); end; end
                 Legend(plot_fig[1, 2], plotted_objects, active_methods[1:num_to_plot], "Methods", tellheight=false)
                 colsize!(plot_fig.layout, 2, Auto())
             catch e; @error "Error adding Legend" exception=(e, catch_backtrace()); end
        end
        #autolimits!(ax) # Update limits
    end # --- End Lift 3 ---

        # --- NEW Lift Block 4: Dynamic Y-Limits ---
    # Triggered whenever the Y plot data snapshot changes
    lift(y_plot_data_methods, cb_log_y.active, tSlider.value; ignore_equal_values=true) do current_y_data_observables, y_active, _ # Vector{Observable{Vector{Float64}}}
        ymin_overall = Inf
        ymax_overall = -Inf
        found_valid_y = false

        for y_obs in current_y_data_observables # Iterate through observables
            y_vec = y_obs[] # Get current vector value
            valid_y = filter(isfinite, y_vec) # Filter NaN/Inf
            if !isempty(valid_y)
                ymin_local, ymax_local = extrema(valid_y)
                ymin_overall = min(ymin_overall, ymin_local)
                ymax_overall = max(ymax_overall, ymax_local)
                found_valid_y = true
            end
        end

        # Apply padding and set limits
        if found_valid_y
            pad_y_factor = to_value(y_active) ? 0 : get(local_ui_dict, "y_axis_limit_padding", 0.1) # Default 10%
            y_range = ymax_overall - ymin_overall
            y_pad = y_range ≈ 0 ? 0.1 : (y_range * pad_y_factor / 2.0)
            final_ylims = (ymin_overall - y_pad, ymax_overall + y_pad)
        else
            final_ylims = (0.0, 1.0) # Default if no valid Y data
        end

        # Set the Y limits (use try-catch for robustness)
        try
            current_limits = ax.finallimits[]
            # Only update if limits actually changed significantly
            if abs(current_limits.origin[2] - final_ylims[1]) > 1e-9 || abs(current_limits.widths[2] - (final_ylims[2] - final_ylims[1])) > 1e-9
                 ylims!(ax, final_ylims)
            end
        catch e
            @warn "Failed to set dynamic ylims" exception=(e, catch_backtrace())
        end
        return nothing # Lift blocks don't need to return
    end # --- End Lift Block 4 ---

    # --- Display ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return plot_fig, control_fig
end

"""
    showConvergencePlot(sim_config::SimulationConfig,
                        key::String,
                        param_values::Union{AbstractVector, AbstractRange},
                        x_stat_key::String,
                        y_stat_key::String;
                        run_simulations::Bool = true,
                        force_int_param::Bool = false)

Plots one simulation statistic against another, across variations of a parameter `key`.

Runs simulations varying `key` over `param_values` for active methods.
Plots statistic `x_stat_key` (X-axis) vs. statistic `y_stat_key` (Y-axis).
A time slider is shown and used if *either* statistic is time-dependent.
Axis limits are dynamic based on the current data snapshot.

# Arguments
- `sim_config`: Base SimulationConfig defining methods, base params, sim function.
- `key`: String name of the parameter to vary.
- `param_values`: Vector or Range of values for `key`.
- `x_stat_key`: String name of the statistic for the X-axis.
- `y_stat_key`: String name of the statistic for the Y-axis.
- `run_simulations`: If true (default), runs simulations. Assumes `loadSimData` otherwise.
- `force_int_param`: If true, attempts `trunc(Int, value)` for the varied parameter `key`.
"""
function showConvergencePlot(
    sim_config::SimulationConfig,
    key::String,
    param_values::Union{AbstractVector, AbstractRange},
    x_stat_key::String,
    y_stat_key::String;
    force_int_param::Bool = false,
    ui_options::UIType = :default
    )

    # --- Basic Setup & UI ---
    local_ui_dict = GetUIDict(ui_options)
    # updateUI(...)
    plot_fig = Figure(size = local_ui_dict["figsize"])
    # Use stat keys for initial labels
    ax = Axis(plot_fig[1,1], title="Convergence: $y_stat_key vs $x_stat_key (varying $key)", xlabel=x_stat_key, ylabel=y_stat_key)

    # --- Process Varied Parameter Values ---
    # Calculate the actual parameter values used for the varied key ONCE.
    # These are NOT directly plotted unless key == x_stat_key or key == y_stat_key
    actual_param_values_used = try
        vals = force_int_param ? map(v -> trunc(Int, v), param_values) : collect(param_values)
        # Keep original type if possible, needed if key itself is plotted
        # Float64.(vals) # Convert only if necessary later? Keep as Any[] for now.
         collect(vals) # Ensure it's a vector
    catch e
        @error "Could not process param_values for $key." exception=(e, catch_backtrace())
        return plot_fig, Figure() # Return empty figures on error
    end
    if isempty(actual_param_values_used); @warn "Empty parameter values provided."; return plot_fig, Figure(); end
    num_params = length(actual_param_values_used)

    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end

    # --- NEW: Notification Observable ---
    parameter_update_notifier = Observable(0)

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    methods_obs = Observable(issubset(sim_config.default_methods,all_method_names) ? sim_config.default_methods : all_method_names)
    method_number = lift(length, methods_obs)

    # --- Call the NEW createControls function ---
    control_fig, update_notifier = createBaseControlsFigure(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names
    )
    # -----------------------------------------

# --- Log Scale Toggles ---

    # Add Checkboxes to control figure (adjust row/column layout as needed)
    # Example: Placing them side-by-side in a new row, spanning 2 columns each
    log_scale_layout = control_fig[end+1, :] = GridLayout() # Span 4 columns for example
    cb_log_x = Toggle(log_scale_layout[1, 1], active = false) # Span cols 1-2
    Label(log_scale_layout[1,2], "Log-scale x-axis")
    cb_log_y = Toggle(log_scale_layout[1, 3], active = false) # Span cols 3-4
    Label(log_scale_layout[1,4], "Log-scale y-axis")

    # --- Link Log Scale Toggles to Axis Scale ---
    on(cb_log_x.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        xlims!(ax, (.1, 1))
        # --- CORRECT WAY: Update value inside the observable ---
        ax.xscale[] = new_scale_func
        # ------------------------------------------------------
        println("X-Axis scale set to: ", ax.xscale[]) # Debug print shows the function name
    end

    on(cb_log_y.active) do is_active # is_active is the Bool value
        new_scale_func = is_active ? log10 : identity
        ylims!(ax, (.1, 1))
        # --- CORRECT WAY: Update value inside the observable ---
        ax.yscale[] = new_scale_func
        # ------------------------------------------------------
        println("Y-Axis scale set to: ", ax.yscale[])
    end
    # ------------------------------------------

    # --- Time Slider (Always Visible, label changes based on dependence) ---
    is_any_stat_time_dependent = Observable(true) # If either X or Y is time-dependent
    is_x_stat_time_dependent = Observable(true)   # Individual flag for X
    is_y_stat_time_dependent = Observable(true)   # Individual flag for Y
    tLabel_text = Observable("t = ...")
    Label(control_fig[end+1, 1:2], tLabel_text, tellwidth=false).padding = (0, 0, 5, 0) # Span columns as needed
    tSlider = Slider(control_fig[end+1, 1:2], range = 0.0:1.0, startvalue = 0.0) # Span columns as needed

    # --- SIMPLIFIED Data Storage ---
    # Structure: [method_idx][param_idx] -> Tuple(raw_X_stat::Any, raw_Y_stat::Any, times::Vector{Float64})
    raw_data_store = Observable(Vector{Vector{Tuple{Any, Any, Vector{Float64}}}}(undef, 0))

    # Structure: [method_idx] -> Observable{Vector{Float64}} (holds current snapshot)
    x_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
    y_plot_data_methods = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))

    # --- Helper Function for Time Dependence Check (Revised from previous answer) ---
    function check_stat_time_dependence(stat_key_to_check::String, raw_data::Vector{Vector{Tuple{Any, Any, Vector{Float64}}}}, key_index::Int)
        # key_index: 1 for X stat, 2 for Y stat
        found_vector = false; found_scalar = false; found_any_valid = false
        for method_data_list in raw_data
            for run_data in method_data_list
                raw_val = run_data[key_index]
                if !ismissing(raw_val)
                    found_any_valid = true
                    if isa(raw_val, AbstractVector) && !isempty(raw_val) && all(isa.(raw_val, Number)); found_vector = true;
                    elseif isa(raw_val, Number); found_scalar = true; end
                    if found_vector && found_scalar; break; end # Inconsistent found
                end
            end
            if found_vector && found_scalar; break; end
        end

        local is_td
        if !found_any_valid; is_td = false; # Treat as scalar if not found or invalid
        elseif found_vector && found_scalar; is_td = true; # Inconsistent -> time-dependent
        elseif found_vector; is_td = true; # Only vectors -> time-dependent
        elseif found_scalar; is_td = false; end # Only scalars -> not time-dependent
        println("Time dependence check for '$stat_key_to_check': is_td = $is_td (V=$found_vector, S=$found_scalar)")
        return is_td
    end
    # --- End Helper Function ---

    # --- Lift 1: Data Loading / Simulation & Initial Snapshot ---
    lift(update_notifier; ignore_equal_values=true) do _ 
        active_num = length(methods_obs[])
        if active_num == 0 # Handle no active methods
            raw_data_store[] = []; x_plot_data_methods[] = []; y_plot_data_methods[] = []
            is_x_stat_time_dependent[] = true; is_y_stat_time_dependent[] = true; is_any_stat_time_dependent[] = true;
            tSlider.range = 0.0:1.0; set_close_to!(tSlider, 0.0); tLabel_text[] = "t = N/A"
            return
        end

        println("Lift 1: Running/Loading simulations...")
        # Initialize temporary storage
        temp_raw_data = Vector{Vector{Tuple{Any, Any, Vector{Float64}}}}(undef, active_num)
        all_times_union = Set{Float64}()

        # --- Simulation Loop ---
        for i = 1:active_num
            method = methods_obs[][i]
            raw_data_for_method = Vector{Tuple{Any, Any, Vector{Float64}}}(undef, num_params)
            base_params = assembleParams(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )

            # === Optional: Threads.@threads for j = 1:num_params ===
            for j = 1:num_params
                current_value = actual_param_values_used[j]
                current_params = copy(base_params); 
                current_params[key] = current_value;

                stat_x_for_run = missing; stat_y_for_run = missing; time_vec_for_run = Float64[]
                try
                    # --- Run or Load ---
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                    if !Utils.doesSimDataExist(current_params)
                        println(" Running simulation for method: $method")
                        sim_data = sim_config.sim_function(current_params)
                        Utils.saveSimData(sim_data) # Assumes saveSimData exists
                    else
                        println(" Loading data for method: $method")
                        sim_data = Utils.loadSimData(current_params)
                    end
                    # Extract X, Y stats and times
                    if !isnothing(sim_data) && hasproperty(sim_data, :stats) && hasproperty(sim_data, :t) && isa(sim_data.stats, AbstractDict)
                        # Use get for safety, default to missing
                        stat_x_for_run = get(sim_data.stats, x_stat_key, missing)
                        # Special case: if x_stat_key is the varied key itself
                        if x_stat_key == key; stat_x_for_run = current_value; end

                        stat_y_for_run = get(sim_data.stats, y_stat_key, missing)
                        # Special case: if y_stat_key is the varied key itself
                        if y_stat_key == key; stat_y_for_run = current_value; end

                        if isa(sim_data.t, AbstractVector); time_vec_for_run = sim_data.t; union!(all_times_union, time_vec_for_run); end
                    end
                catch e; @error "Sim/Load Error" exception=(e, catch_backtrace()); end
                raw_data_for_method[j] = (stat_x_for_run, stat_y_for_run, time_vec_for_run)
            end # End j loop
            temp_raw_data[i] = raw_data_for_method
        end # End i loop
        # --- End Simulation Loop ---

        println("Finished runs. Updating observables and UI...")
        raw_data_store[] = temp_raw_data # Update main raw data store

        # --- Check Time Dependence for BOTH Keys ---
        is_x_td = check_stat_time_dependence(x_stat_key, temp_raw_data, 1)
        is_y_td = check_stat_time_dependence(y_stat_key, temp_raw_data, 2)
        # Handle cases where key is the varied parameter (always scalar)
        if x_stat_key == key; is_x_td = false; end
        if y_stat_key == key; is_y_td = false; end
        # Update observables
        is_x_stat_time_dependent[] = is_x_td
        is_y_stat_time_dependent[] = is_y_td
        is_any_td = is_x_td || is_y_td
        is_any_stat_time_dependent[] = is_any_td
        # --- End Time Dependence Check ---

        # --- Update Time Slider Range AND Label Text ---
        time_vec = isempty(all_times_union) ? [0.0] : sort(collect(all_times_union))
        t_range = range(extrema(time_vec)..., length=max(2, length(time_vec)*2+80))
        if tSlider.range[] != t_range; tSlider.range = t_range; end
        set_close_to!(tSlider, clamp(tSlider.value[], extrema(t_range)...))
        if is_any_td; tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"; else; tLabel_text[] = "t = N/A (Both Scalar)"; end

        # --- Calculate Initial Plot Data Snapshot ---
        current_x_plot_data = [Observable(fill(NaN, num_params)) for _ in 1:active_num]
        current_y_plot_data = [Observable(fill(NaN, num_params)) for _ in 1:active_num]
        current_t = tSlider.value[]
        current_raw_data = raw_data_store[] # Use the data just stored

        for i = 1:active_num
            x_vals = fill(NaN, num_params); y_vals = fill(NaN, num_params)
            if i > length(current_raw_data) continue end
            raw_method_data = current_raw_data[i]

            for j = 1:num_params
                 if j > length(raw_method_data) continue end
                 raw_x_val, raw_y_val, times = raw_method_data[j]

                 # Calculate X value snapshot
                 if !ismissing(raw_x_val)
                     if is_x_td # Apply time logic only if X is time-dependent
                         if isa(raw_x_val, AbstractVector) && !isempty(times) && !isempty(raw_x_val)
                             (_, m_ij) = findmin(a -> abs(a - current_t), times)
                             if m_ij <= length(raw_x_val); x_vals[j] = Float64(raw_x_val[m_ij]); end
                         elseif isa(raw_x_val, Number); x_vals[j] = Float64(raw_x_val); end # Inconsistent case
                     elseif isa(raw_x_val, Number); x_vals[j] = Float64(raw_x_val); end # Scalar case
                 end
                 # Calculate Y value snapshot
                 if !ismissing(raw_y_val)
                     if is_y_td # Apply time logic only if Y is time-dependent
                         if isa(raw_y_val, AbstractVector) && !isempty(times) && !isempty(raw_y_val)
                             # Assume times are the same for X/Y stat within a run
                             (_, m_ij) = findmin(a -> abs(a - current_t), times)
                             if m_ij <= length(raw_y_val); y_vals[j] = Float64(raw_y_val[m_ij]); end
                         elseif isa(raw_y_val, Number); y_vals[j] = Float64(raw_y_val); end # Inconsistent case
                     elseif isa(raw_y_val, Number); y_vals[j] = Float64(raw_y_val); end # Scalar case
                 end
            end
            current_x_plot_data[i][] = x_vals
            current_y_plot_data[i][] = y_vals
        end
        x_plot_data_methods[] = current_x_plot_data
        y_plot_data_methods[] = current_y_plot_data
        # --- End Snapshot Calculation ---
    end # --- End Lift 1 ---


    # --- Lift 2: Snapshot Update (triggered by time slider) ---
    lift(tSlider.value; ignore_equal_values=true) do t
        # Only run if at least one stat is time-dependent
        if !is_any_stat_time_dependent[]; return; end

        tLabel_text[] = "t = $(round(t, digits=3))"
        active_num = method_number[]
        # Consistency checks
        if length(x_plot_data_methods[])!=active_num || length(y_plot_data_methods[])!=active_num || length(raw_data_store[])!=active_num || active_num==0; return; end

        # Recalculate X and Y snapshots based on new time t
        is_x_td = is_x_stat_time_dependent[] # Read current flags
        is_y_td = is_y_stat_time_dependent[]
        current_raw_data = raw_data_store[]

        for i = 1:active_num
            x_vals = fill(NaN, num_params); y_vals = fill(NaN, num_params)
            if i > length(current_raw_data) continue end
            raw_method_data = current_raw_data[i]

            for j = 1:num_params
                 if j > length(raw_method_data) continue end
                 raw_x_val, raw_y_val, times = raw_method_data[j]

                 # Calculate X value snapshot (only if time-dependent)
                 if is_x_td && !ismissing(raw_x_val)
                     if isa(raw_x_val, AbstractVector) && !isempty(times) && !isempty(raw_x_val)
                         (_, m_ij) = findmin(a -> abs(a - t), times)
                         if m_ij <= length(raw_x_val); x_vals[j] = Float64(raw_x_val[m_ij]); end
                     elseif isa(raw_x_val, Number); x_vals[j] = Float64(raw_x_val); end # Inconsistent case
                 elseif !is_x_td && !ismissing(raw_x_val) && isa(raw_x_val, Number) # If scalar, keep original value
                     x_vals[j] = Float64(raw_x_val)
                 else # Keep NaN
                      x_vals[j] = x_plot_data_methods[][i][][j] # Use previous value if possible? Or just keep NaN
                 end

                 # Calculate Y value snapshot (only if time-dependent)
                  if is_y_td && !ismissing(raw_y_val)
                     if isa(raw_y_val, AbstractVector) && !isempty(times) && !isempty(raw_y_val)
                         (_, m_ij) = findmin(a -> abs(a - t), times)
                         if m_ij <= length(raw_y_val); y_vals[j] = Float64(raw_y_val[m_ij]); end
                     elseif isa(raw_y_val, Number); y_vals[j] = Float64(raw_y_val); end # Inconsistent case
                 elseif !is_y_td && !ismissing(raw_y_val) && isa(raw_y_val, Number) # If scalar, keep original value
                     y_vals[j] = Float64(raw_y_val)
                 else # Keep NaN
                      y_vals[j] = y_plot_data_methods[][i][][j] # Use previous value if possible? Or just keep NaN
                 end
            end
            # Update inner observables only if value changed? Makie might handle this.
            if i <= length(x_plot_data_methods[]); x_plot_data_methods[][i][] = x_vals; end
            if i <= length(y_plot_data_methods[]); y_plot_data_methods[][i][] = y_vals; end
        end
    end # --- End Lift 2 ---


    # --- Lift 3: Plot Management (Plots X vs Y) ---
    lift(update_notifier; ignore_equal_values=true) do _ 
        active_num = length(methods_obs[])
        # (Same as previous version - redraws plots using x_plot_data_methods and y_plot_data_methods)
        empty!(ax)
        for c in contents(plot_fig.layout); if isa(c, Legend); delete!(c); end; end
        if active_num == 0; return; end
        active_methods = methods_obs[]

        num_data_series_x = length(x_plot_data_methods[]); num_data_series_y = length(y_plot_data_methods[])
        if num_data_series_x != active_num || num_data_series_y != active_num
             num_to_plot = min(active_num, num_data_series_x, num_data_series_y); if num_to_plot <= 0; return; end
             @warn "Lift 3: Data series mismatch. Plotting $num_to_plot series."
        else; num_to_plot = active_num; end

        plotted_objects = []
        for i = 1:num_to_plot
            plotLabel = active_methods[i]
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            x_data_obs = x_plot_data_methods[][i] # Observable for X snapshot
            y_data_obs = y_plot_data_methods[][i] # Observable for Y snapshot

            obj_for_legend = nothing
            if get(local_ui_dict, "show_lines", true)
                 l = lines!(ax, x_data_obs, y_data_obs; color=color, linewidth=get(local_ui_dict,"linewidth", 1.5), label=plotLabel)
                 obj_for_legend = l
            end
            if get(local_ui_dict, "show_scatter", true)
                 s = scatter!(ax, x_data_obs, y_data_obs; color=color, markersize=get(local_ui_dict,"markersize", 8), marker=marker, label=plotLabel)
                 if obj_for_legend === nothing; obj_for_legend = s; end
            end
            if obj_for_legend !== nothing; push!(plotted_objects, obj_for_legend); end
        end

        # Add Legend
        if !isempty(plotted_objects)
             try; Legend(plot_fig[1, 2], plotted_objects, active_methods[1:num_to_plot], "Methods", tellheight=false); colsize!(plot_fig.layout, 2, Auto());
             catch e; @error "Error adding Legend" exception=(e, catch_backtrace()); end
        end
        # Limits are handled by Lift 4
    end # --- End Lift 3 ---


    # --- Lift Block 4: Dynamic X/Y Limits ---
    # Triggered by time slider OR changes in the underlying plot data observables
    lift(tSlider.value, x_plot_data_methods, y_plot_data_methods, cb_log_x.active, cb_log_y.active; ignore_equal_values=true) do t, current_x_data_obs, current_y_data_obs, x_active, y_active
        # Calculate X limits
        xmin_overall = Inf; xmax_overall = -Inf; found_valid_x = false
        for x_obs in current_x_data_obs
            valid_x = filter(isfinite, x_obs[]);
            if !isempty(valid_x); xmin_local, xmax_local = extrema(valid_x); xmin_overall = min(xmin_overall, xmin_local); xmax_overall = max(xmax_overall, xmax_local); found_valid_x = true; end
        end
        # Calculate Y limits
        ymin_overall = Inf; ymax_overall = -Inf; found_valid_y = false
        for y_obs in current_y_data_obs
            valid_y = filter(isfinite, y_obs[]);
            if !isempty(valid_y); ymin_local, ymax_local = extrema(valid_y); ymin_overall = min(ymin_overall, ymin_local); ymax_overall = max(ymax_overall, ymax_local); found_valid_y = true; end
        end

        # Apply padding and set limits
        pad_x_factor = to_value(x_active) ? 0 : get(local_ui_dict, "x_axis_limit_padding", 0.1)
        pad_y_factor = to_value(y_active) ? 0 : get(local_ui_dict, "y_axis_limit_padding", 0.1)

        final_xlims = if found_valid_x
            x_range = xmax_overall - xmin_overall; x_pad = x_range ≈ 0 ? 0.1 : (x_range * pad_x_factor / 2.0); (xmin_overall - x_pad, xmax_overall + x_pad)
        else (0.0, 1.0) end # Default X limits

        final_ylims = if found_valid_y
            y_range = ymax_overall - ymin_overall; y_pad = y_range ≈ 0 ? 0.1 : (y_range * pad_y_factor / 2.0); (ymin_overall - y_pad, ymax_overall + y_pad)
        else (0.0, 1.0) end # Default Y limits
        try # Set limits only if they differ significantly to avoid jitter
            current_lims = ax.finallimits[]
            xlims_changed = abs(current_lims.origin[1] - final_xlims[1]) > 1e-9 || abs(current_lims.widths[1] - (final_xlims[2] - final_xlims[1])) > 1e-9
            ylims_changed = abs(current_lims.origin[2] - final_ylims[1]) > 1e-9 || abs(current_lims.widths[2] - (final_ylims[2] - final_ylims[1])) > 1e-9
            # Use non-blocking update variants if available and needed, otherwise standard functions
            if xlims_changed; xlims!(ax, final_xlims); end
            if ylims_changed; ylims!(ax, final_ylims); end
        catch e; @warn "Failed to set dynamic limits" exception=(e, catch_backtrace()); end

        return nothing
    end # --- End Lift Block 4 ---


    # --- Display ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return plot_fig, control_fig
end # --- End Function ---