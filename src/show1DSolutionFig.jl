
"""
    show1DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot for `SimData1D` with animation playback
and an option to save the animation as a GIF (which may close the window).
Saves corresponding parameters to a CSV file.
Uses closest data point logic for animation frames.
"""
function show1DSolutionFig(sim_config::SimulationConfig; calc_stats = false, reference_function::Union{Function,Nothing} = nothing, scene_options::Dict = Dict{String,Any}(), ui_options::UIType = :default)

    # --- Basic Setup & UI ---
    base_ui_dict = createUIDict(ui_options)
    ui_options_obs = create_ui_observables(base_ui_dict)
    plot_fig = Figure(size = ui_options_obs["figsize"])

    scene_info = Dict{String,Any}()
    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)
    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    methods_obs = Observable(issubset(sim_config.default_methods,all_method_names) ? sim_config.default_methods : all_method_names)

    # --- Call the NEW createControls function ---
    control_fig, update_notifier, ui_update, components, comp_sel = createBaseControlsFigure(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        ui_options_obs,
        scene_info
    )
    # -----------------------------------------

    
    # --- Time Slider & Label ---
    tLabel_text = Observable("t = 0.0")
    # Add a new row for the time label
    # --- Time Slider, Log Toggles, etc. ---
    tSlider = Slider(control_fig[end+2,:], range = 0:0)

    tLabel_text = lift(tSlider.value, tSlider.range) do val, range; 
        if range == [0]
            "t = N/A"
        else
            "t = $(round(val; digits = 3))"
        end 
    end
    

    Label(control_fig[end-1,:], tLabel_text)
    axis_label = lift(comp_sel) do sel; sel == 1 ? "Solution (u)" : components[][sel] end
    axis_title = @lift("t = " * string(round($(tSlider.value),digits = 3)))
    
    default_labels = Dict("xlabel" => "Position (x)",
                      "ylabel" => axis_label,                        
                      "title" => axis_title)
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)

    ax = Axis(plot_fig[1,1], xlabel = label_obs["xlabel"], ylabel = label_obs["ylabel"], title = label_obs["title"])

    ani_layout = control_fig[end+1,:] = GridLayout()
    createAnimationControls!(ani_layout, plot_fig, tSlider,shared_params_obs,method_params_collection_obs,methods_obs, ui_options_obs,scene_info)
    scene_obs = Dict{String,Observable}(
        "component" => comp_sel,
        "t" => tSlider.value 
    )
    set_scene_options!(scene_obs, scene_options)

    # --- Data Structures ---
    datatype = Vector{Vector{Float64}}
    # Outer Observable holds Vector of Inner Observables (one per method)
    xData = Observable(Vector{Tuple{datatype, Vector{Float64}}}(undef, 0)) # Full x data series
    uData = Observable(Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, 0)) # Full u data series
    uData_extr = Observable(Vector{Tuple{datatype, Vector{Float64}}}(undef, 0)) # Full u data series

    # ------------------------------------
    # --- Lift Block 1: Data Loading / Simulation Execution ---
    lift(update_notifier; ignore_equal_values=true) do _
        active_num = length(methods_obs[])
        println("Lift 1: Running sims / loading data...") # Concise print

        xData_tmp = Vector{Tuple{datatype, Vector{Float64}}}(undef, active_num)
        uData_tmp = Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, active_num)
        active_methods_now = methods_obs[]

        # --- STEP 1: Assemble the list of simulation tasks ---
        tasks = assemble_simulation_tasks(
            shared_params_obs, method_params_collection_obs, active_methods_now
        )

        # --- STEP 2: Ensure SimData exists for all tasks ---
        ensure_sim_data_exists!(tasks, sim_config)

        # --- STEP 3 (Optional): Calculate all statistics ---
        if calc_stats
            calculateAllStats!(sim_config; ref_func_cont = reference_function)
        end

        first_run = true

        for (i, method) in enumerate(active_methods_now)
            params = tasks[i] # Get the correct parameter dict
            local sim_data
            try
                sim_data = Utils.loadSimData(params)
            catch e
                @warn "simData for method $method could not be loaded. Skipping!"
                sim_data = nothing
                continue
            end

            xData_tmp[i] = (sim_data.x, sim_data.t)
            uData_tmp[i] = (Dict("u" => sim_data.u), sim_data.t)
            current_comps = length(sim_data.u[1][1,:])
            if first_run
                components[] = Tuple(["Component $k" for k = 1:current_comps])
                first_run = false
            elseif current_comps != length(components[])
                @warn "Inconsistent components amount detected!"
            end
            # -----------------------------
        end # End loop over methods
        
        xData[] = xData_tmp
        uData[] = uData_tmp
        update_time_slider!(tSlider,xData[])
    println("Lift 1: Update complete.")

    end # --- End Lift Block 1 ---
    lift(comp_sel, uData) do sel, u
        if isempty(u); return; end
        uData_extr[] = extractData(u, "u", sel);
        set_axis_limits!(ax, xData[], uData_extr[], ui_options_obs)
        return nothing

    end

    #lift(method_number, tSlider.value, xs, us, track_max_obs, x_at_max_obs, u_at_max_obs; ignore_equal_values=true) do active_num, _, current_xs_obsvec, current_us_obsvec, track_max_enabled, current_x_max_obsvec, current_u_max_obsvec
    lift(uData_extr, tSlider.value, ui_update) do u_data, t, _

        save_scene_info!(scene_obs, scene_info)
        x_snapshot, y_snapshot = calculate_snapshot(xData[], u_data, t)
        create_base_plot_1D!(plot_fig, ax, 
                             methods_obs[],
                             x_snapshot,
                             y_snapshot,
                             ui_options_obs; 
                             plot_observable = false)        
     
    end # --- End Lift Block 3 ---

    # --- Display Figures ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end
    return nothing
    # return control_fig, plot_fig
end

function show1DSolutionFig(csv_filepath::String; kwargs...)
    ui_options = load_additional_options_from_csv(csv_filepath, "UI")
    scene_options = load_additional_options_from_csv(csv_filepath, "Scene")
    sim_config = create_sim_config_from_csv(csv_filepath)
    show1DSolutionFig(sim_config; scene_options = scene_options, ui_options = ui_options, kwargs...)
end