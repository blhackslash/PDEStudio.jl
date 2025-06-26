
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
    base_ui_dict = createUIDict(ui_options)
    deleteUIOptions!(base_ui_dict, ["system_dimension", "animation_duration_s", "animation_duration_s"])
    ui_options_obs = Dict{String, Observable}()
    for (key, value) in base_ui_dict
        if isa(value, Tuple)
            ui_options_obs[key] = Observable{Tuple}(value)
        else
            ui_options_obs[key] = Observable(value)
        end
    end

    plot_fig = Figure(size = ui_options_obs["figsize"])


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
    control_fig, update_notifier, ui_update, y_options, selector = createBaseControlsFigure(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        ui_options_obs
    )
    # -----------------------------------------

    # --- Stats Selection Menu & Time Slider ---
    Label(control_fig[end+1,:], "Statistic to Plot:")
    

    ylabel = lift(selector) do sel
        string(sel)
    end
    title = lift(selector) do sel
        "Time dependance of $sel"
    end
    # -----------------------------------------
    default_labels = Dict("xlabel" => "Time (t)",
                          "ylabel" => ylabel,                        
                          "title" => title)
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)
    ax = Axis(plot_fig[1,1], xlabel=label_obs["xlabel"], ylabel=label_obs["ylabel"], title = label_obs["title"]) 


    # --- Data Structures for Statistics (using Dict{String, Any}) ---
    statsData = Observable(Vector{Dict{String, Any}}(undef, 0)) # Stores the full stats dict
    tData = Observable(Vector{Vector{Float64}}(undef, 0))    # Stores the time vector
    yData = Observable(Vector{Vector{Float64}}(undef, 0))

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
                    
                 continue # Skip to next method
            end

            # --- Store Raw Data ---
            statsData[][i] = sim_data.stats # Store the Dict{String, Any}
            tData[][i] = sim_data.t

            # --- Identify PLOTTABLE keys for *this* method ---
            plottable_keys_this_method = Set{String}()
            if !isempty(sim_data.stats) && isa(sim_data.stats, Dict)
                for (key, value) in sim_data.stats
                    # *** Check if the value is a Vector of Real numbers ***
                    if isa(value, AbstractVector) && length(value) == length(sim_data.t)
                        push!(plottable_keys_this_method, key)
                    else
                         # Optionally warn if a key exists but is not plottable
                         try println("Length of t-vector = $(length(sim_data.t)). Length of stat-vector = $(length(value))" ) catch e end
                         println("Info: Stat '$key' in method '$method' is not a Vector{<:Real} or has mismatched length, skipping.")
                    end
                end
            else
                 @warn "Method '$method' produced empty or invalid stats. Skipping stats processing."
            end
            println("hello", plottable_keys_this_method)
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

        y_options[] = sorted_keys # Update the observable list of keys

        println("Data update complete.")
    end # End of lift block 1

    lift(selector, update_notifier) do sel, _ 
        updateData!(yData, statsData[], sel)
        return nothing
    end

    # --- Lift Block 2: Update Plot ---
    lift(ui_update, yData) do _...
        create_base_plot_1D!(plot_fig, ax, 
                        methods_obs[],
                        tData[],
                        yData[],
                        ui_options_obs; 
                        plot_observable = false,
                        is_static = true)       
    end # End of lift block 2

    # --- Display Figures ---
    GLMakie.activate!()
    display(GLMakie.Screen(), control_fig)
    display(GLMakie.Screen(), plot_fig)
    
    # Optionally return figures
    # return control_fig, plot_fig 
end