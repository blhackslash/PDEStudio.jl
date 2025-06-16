
"""
    showDynamicDependence(sim_config::SimulationConfig)

Creates an interactive Makie plot showing the time evolution of selected statistics 
from simulation data. Handles stats stored as Dict{String, Any}.

Plots `stats` values (selected via slider, must be Vector{<:Real}) against time (`t`) 
for different simulation methods defined in `sim_config`. Allows comparison of 
statistics across methods.

# Arguments
- `sim_config::SimulationConfig`: Configuration object containing simulation function,
  methods, parameters, and UI options. Assumes the simulation function returns an
  `AbstractSimData` object with non-empty `t::Vector{Float64}` and 
  `stats::Dict{String, Any}` fields.
"""
function showDynamicDependence(sim_config::SimulationConfig, ui_options::UIType = :default)
    # --- Standard Setup ---
    local_ui_dict = createUIDict(ui_options)
    plot_fig = Figure(size = local_ui_dict["figsize"])
    ax = Axis(plot_fig[1,1], xlabel = "Time (t)", ylabel = "Statistic Value")

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

    # --- Call the NEW createControls function ---
    control_fig, update_notifier = createBaseControlsFigure(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names
    )
    # -----------------------------------------

    # --- Data Structures for Statistics (using Dict{String, Any}) ---
    statsData = Observable(Vector{Observable{Dict{String, Any}}}(undef, 0)) # Stores the full stats dict
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))    # Stores the time vector
    stat_keys_obs = Observable(String[]) # Stores the available PLOTTABLE keys
    selected_stat_index_obs = Observable(1) # Index of the statistic currently selected

    # --- Statistic Selection Slider & Label (using Observable for text) ---
    stats_label_text = Observable("Selected Statistic: <calculating>") # Observable for the label text
    stats_label = Label(control_fig[end+1, :], text = stats_label_text) # Assign observable to text
    stats_slider = Slider(control_fig[end+1, :], range = 1:1, startvalue = 1)

    # --- Lift Block 1: Load Data, Filter Plottable Stat Keys, Update UI ---
    lift(update_notifier; ignore_equal_values = true) do _
        println("Updating data based on methods/parameters...")
        active_methods_now = methods_obs[]
        active_num = length(active_methods_now)
        statsData[] = Vector{Observable{Dict{String, Any}}}(undef, active_num)
        tData[] = Vector{Observable{Vector{Float64}}}(undef, active_num)

        # Store potential keys temporarily before checking type and intersection
        potential_keys_per_method = Vector{Set{String}}(undef, active_num) 
        

        for i = 1:active_num
            method = active_methods_now[i]
            # Assemble params for this method run
            # --- Assemble Parameters using Helper ---
            params = assembleParams(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )
            # ------------------------------------

            # --- Load or Compute Data ---
            local sim_data::Union{AbstractSimData, Nothing} = nothing
            try
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                if !Utils.doesSimDataExist(params)
                     println(" Running simulation for method: $method")
                     sim_data = sim_config.sim_function(params)
                     Utils.saveSimData(sim_data) # Assumes saveSimData exists
                else
                     println(" Loading data for method: $method")
                     sim_data = Utils.loadSimData(params)
                end
            catch e
                 @warn "Simulation/Load failed for method '$method'" exception=(e, catch_backtrace())
                 sim_data = nothing
            end
            # --------------------------

            # --- Store Data & Update Limits ---
            if isnothing(sim_data) || !isa(sim_data, SimData1D)
                 @warn "Invalid SimData1D for '$method'. Assigning empty."
                 xData[][i][] = Vector{Vector{Float64}}(); uData[][i][] = Vector{Vector{Float64}}(); tData[][i][] = Float64[]
                 xs[][i][] = Float64[]; us[][i][] = Float64[]
                 continue # Skip to next method
            end

            # --- Store Raw Data ---
            statsData[][i] = Observable(sim_data.stats) # Store the Dict{String, Any}
            tData[][i] = Observable(sim_data.t)

            # --- Identify PLOTTABLE keys for *this* method ---
            plottable_keys_this_method = Set{String}()
            if !isempty(sim_data.stats) && isa(sim_data.stats, Dict)
                for (key, value) in sim_data.stats
                    # *** Check if the value is a Vector of Real numbers ***
                    if isa(value, Vector{<:Real}) && length(value) == length(sim_data.t)
                        push!(plottable_keys_this_method, key)
                    else
                         # Optionally warn if a key exists but is not plottable
                         # println("Info: Stat '$key' in method '$method' is not a Vector{<:Real} or has mismatched length, skipping.")
                    end
                end
            else
                 @warn "Method '$method' produced empty or invalid stats. Skipping stats processing."
            end
            potential_keys_per_method[i] = plottable_keys_this_method
        end # End loop over methods

        # --- Determine Common Plottable Keys ---
        common_plottable_keys = Set{String}()
        if active_num > 0
            common_plottable_keys = potential_keys_per_method[1] # Start with the first set
            for i = 2:active_num
                intersect!(common_plottable_keys, potential_keys_per_method[i]) # Intersect with subsequent sets
            end
        end

        # --- Update Stat Selection UI ---
        sorted_keys = sort(collect(common_plottable_keys))
        stat_keys_obs[] = sorted_keys # Update the observable list of keys

        if isempty(sorted_keys)
            stats_label_text[] = "No common plottable statistics found." # Update observable text
            stats_slider.range = 1:1
            # stats_slider.startvalue = 1 # Might not be needed if range is 1:1
            set_close_to!(stats_slider, 1) # Ensure slider is at 1
            selected_stat_index_obs[] = 1
            println("Warning: No common plottable statistics available to plot.")
        else
            num_keys = length(sorted_keys)
            current_index = selected_stat_index_obs[]
            valid_index = clamp(current_index, 1, num_keys)

            stats_slider.range = 1:num_keys
            set_close_to!(stats_slider, valid_index)
            selected_stat_index_obs[] = valid_index # Ensure observable matches

            # Update the label text observable
            stats_label_text[] = "Selected Statistic: $(sorted_keys[valid_index])" 
            println("Available plottable statistics updated: ", sorted_keys)
        end

        # Trigger downstream lifts manually if necessary (usually automatic)
        # notify(stat_keys_obs) 
        # notify(selected_stat_index_obs) 

        println("Data update complete.")
    end # End of lift block 1

    # --- Connect Statistic Slider to Observable ---
    on(stats_slider.value) do idx
        # Check bounds before accessing stat_keys_obs
        if !isempty(stat_keys_obs[]) && idx >= 1 && idx <= length(stat_keys_obs[])
            if idx != selected_stat_index_obs[]
                 selected_stat_index_obs[] = idx
                 # Update label text directly when slider changes index
                 stats_label_text[] = "Selected Statistic: $(stat_keys_obs[][idx])" 
                 println("Statistic selection changed to index: $idx ($(stat_keys_obs[][idx]))")
            end
        # Handle edge case where slider might briefly be out of sync
        elseif !isempty(stat_keys_obs[]) && selected_stat_index_obs[] != 1
             selected_stat_index_obs[] = 1 # Reset to 1 if slider is somehow invalid
             stats_label_text[] = "Selected Statistic: $(stat_keys_obs[][1])" 
        end
    end

    # --- Lift Block 2: Update Plot ---
    lift(update_notifier, selected_stat_index_obs) do _, stat_idx
        #stat_idx = selected_stat_index_obs[]
        active_num = length(methods_obs[])
        println("Updating plot...")
        empty!(ax)
        try
            target_pos = (1, 2)
            existing_content = contents(plot_fig[target_pos...]) # Get content at specific position
            for item in existing_content
                if isa(item, Legend)
                    println("Deleting existing Legend at ", target_pos) # Debug print
                    delete!(item)
                end
            end
        catch e
            # Ignore errors if position doesn't exist or content access fails initially
            # @warn "Could not check/clear legend position [1, 2]: $e" # Optional warning
        end

        if isempty(stat_keys_obs[]) || active_num == 0 || stat_idx > length(stat_keys_obs[]) || stat_idx < 1
            println("Plotting skipped: No data or no valid statistic selected.")
            ax.ylabel = "Statistic Value" # Reset label
            return
        end

        selected_key = stat_keys_obs[][stat_idx]
        ax.ylabel = selected_key # Update y-axis label based on selection

        println("Plotting statistic: $selected_key")
        valid_plots = 0
        for i = 1:active_num
            method = methods_obs[][i]
            plotLabel = method

            # --- Check data validity for this method and selected key ---
            # Ensure indices are valid before accessing observables
            if i > length(tData[]) || i > length(statsData[])
                 @warn "Data arrays out of sync for method index $i. Skipping plot."
                 continue
            end
            
            local_t_obs = tData[][i]
            current_stats_dict = statsData[][i][] # Get the actual dictionary

            # Check if key exists and if the value is appropriate BEFORE plotting
            if !haskey(current_stats_dict, selected_key)
                # This shouldn't happen if common_plottable_keys logic is correct, but good safeguard
                @warn "Statistic '$selected_key' unexpectedly not found for method '$method'. Skipping."
                continue
            end

            stat_value = current_stats_dict[selected_key]

            # *** Final check: Is it a Vector of Real and lengths match? ***
            if !(isa(stat_value, Vector{<:Real}) && length(stat_value) == length(local_t_obs[]))
                @warn "Statistic '$selected_key' for method '$method' is not Vector{<:Real} or length mismatch. Skipping plot."
                continue
            end

            # If checks pass, create observables for plotting this specific data
            # No need to store these long term, just create for the plot call
            local_t_plot = local_t_obs # Can use the existing observable
            local_stat_y_plot = Observable(convert(Vector{Float64}, stat_value)) # Convert to Float64 for plotting consistency

            if isempty(local_t_plot[]) # Check after potential filtering/conversion
                @info "Time or statistic vector empty for method '$method', statistic '$selected_key'. Skipping."
                continue
            end

            # --- Apply Plotting Styles ---
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            line_style = :solid
            if local_ui_dict["dashed_lines"]; line_style = local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))]; end
            marker_style = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]

            # --- Plot Lines/Scatter ---
            if local_ui_dict["show_lines"]
                lines!(ax, local_t_plot, local_stat_y_plot, label = plotLabel, linestyle = line_style, color = color, linewidth=local_ui_dict["linewidth"])
            end
            if local_ui_dict["show_scatter"]
                scatter!(ax, local_t_plot, local_stat_y_plot, label = plotLabel, marker = marker_style, color = color, markersize=local_ui_dict["markersize"])
            end
            valid_plots += 1
        end # End loop over methods

        # --- Add Legend ---
        if valid_plots > 0
            Legend(plot_fig[1,1], ax, local_ui_dict["legend"], merge = true, tellheight = false, tellwidth = false,
                    titlesize = local_ui_dict["font_size"], labelsize = local_ui_dict["label_size"],
                    valign = local_ui_dict["vPos"], halign = local_ui_dict["hPos"])
        end

        autolimits!(ax)
        println("Plot update complete.")
    end # End of lift block 2

    # --- Display Figures ---
    GLMakie.activate!()
    display(GLMakie.Screen(), control_fig)
    display(GLMakie.Screen(), plot_fig)
    
    # Optionally return figures
    # return control_fig, plot_fig 
end