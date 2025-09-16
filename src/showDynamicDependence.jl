
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
function showDynamicDependence(sim_config::SimulationConfig; reference_function::Union{Function,Nothing} = nothing, calc_stats = false, scene_options= Dict{String,Any}(), ui_options::UIType = :default)
    # --- Standard Setup ---
    base_ui_dict = createUIDict(ui_options)
    deleteUIOptions!(base_ui_dict, ["system_dimension", "animation_duration_s", "animation_duration_s"])
    ui_options_obs = create_ui_observables(base_ui_dict)

    plot_fig = Figure(size = ui_options_obs["figsize"])


    shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)

    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    methods_obs = Observable(issubset(sim_config.default_methods,all_method_names) ? sim_config.default_methods : all_method_names)

    scene_default = Dict{String,Any}("y_key" => "Temp", "component" => 1)
    scene_dict = merge(scene_default, scene_options)
    scene_obs = createObsDict(scene_dict)

    # --- Call the NEW createControls function ---
    control_fig, update_notifier, ui_update, components, comp_sel = createBaseControlsFigure(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        ui_options_obs,
        scene_obs
    )
    # -----------------------------------------
    comp_sel[] = scene_obs["component"][]
    Label(control_fig[end+1, :], "Choose Statistic:")
    menu_container = control_fig[end+1,:] = GridLayout()
    menu_handle = Observable{Union{Nothing, Menu}}(nothing)
    selected_key_obs = Observable(scene_obs["y_key"][])

    ylabel = lift(selected_key_obs, comp_sel) do sel, c_sel
        sel * " (" * components[][c_sel] * ")"
    end
    title = lift(ylabel) do label
        "Time dependance of $label"
    end
    # -----------------------------------------
    default_labels = Dict("xlabel" => "Time (t)",
                          "ylabel" => ylabel,                        
                          "title" => title)
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)
    ax = Axis(plot_fig[1,1], xlabel=label_obs["xlabel"], ylabel=label_obs["ylabel"], title = label_obs["title"]) 

        connectObsDict!(scene_obs, ["y_key", "component"],[selected_key_obs,comp_sel])  

    # --- Data Structures for Statistics (using Dict{String, Any}) ---
    statsData = Observable(Vector{Dict{String, Any}}(undef, 0)) # Stores the full stats dict
    tData = Observable(Vector{Vector{Float64}}(undef, 0))    # Stores the time vector
    yData = Observable(Vector{Vector{Float64}}(undef, 0))

    # --- Lift Block 1: Load Data, Filter Plottable Stat Keys, Update UI ---
    lift(update_notifier; ignore_equal_values = true) do _
        println("Updating data based on methods/parameters...")
        active_methods_now = methods_obs[]
        active_num = length(methods_obs[])
        statsData[] = Vector{Observable{Dict{String, Any}}}(undef, active_num)
        tData[] = Vector{Vector{Float64}}(undef, active_num)

        # --- STEP 1: Assemble the list of simulation tasks ---
        tasks = assemble_simulation_tasks(
            shared_params_obs, method_params_collection_obs, active_methods_now
        )

        # --- STEP 2: Ensure SimData exists for all tasks ---
        ensure_sim_data_exists!(tasks, sim_config; force_overwrite = false)

        # --- STEP 3 (Optional): Calculate all statistics ---
        if calc_stats
            calculateAllStats!(sim_config; ref_func_cont = reference_function)
        end

        # Store potential keys temporarily before checking type and intersection
        potential_keys_per_method = Vector{Set{String}}(undef, active_num) 
        first_run = true    

        for (i, method) in enumerate(active_methods_now)
            params = tasks[i] # Get the correct parameter dict
            sim_data = Utils.loadSimData(params)

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
                    if isa(value, AbstractVector) && length(value) == length(sim_data.t) || isa(value, AbstractMatrix) && size(value, 1) == length(sim_data.t)
                        push!(plottable_keys_this_method, key)
                        
                    else
                         # Optionally warn if a key exists but is not plottable
                         try @info "Length of t-vector = $(length(sim_data.t)). Length of stat-vector = $(length(value))"  catch e end
                         @warn "Info: Stat '$key' in method '$method' is not a Vector{<:Real} or has mismatched length, skipping."
                    end
                end
            else
                 @warn "Method '$method' produced empty or invalid stats. Skipping stats processing."
            end

            current_comps = length(sim_data.u[1][1,:])
            if first_run
                components[] = Tuple(["u_$k" for k = 1:current_comps])
                first_run = false
            elseif current_comps != length(components[])
                @warn "Inconsistent components amount detected!"
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
        create_or_update_selection_menu!(menu_container, menu_handle, sorted_keys, selected_key_obs)

        println("Data update complete.")
    end # End of lift block 1

    lift(selected_key_obs, comp_sel, statsData) do sel, c_sel, data
        yData[] = extractData(data, sel, c_sel)
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