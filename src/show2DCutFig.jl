"""
    show2DCutFig(sim_config::SimulationConfig; ...)

Creates an interactive 1D plot representing a "cut" through 2D simulation data.
This version efficiently calculates the cut for all components simultaneously, allowing
for fast, interactive switching between components.
"""
function show2DCutFig(sim_config::SimulationConfig; calc_stats = false, reference_function::Union{Function,Nothing} = nothing, scene_options::Dict = Dict{String,Any}(), ui_options::UIType = :default)

    # --- Basic Setup & UI (Same as 1D) ---
    base_ui_dict = createUIDict(ui_options)
    ui_options_obs = create_ui_observables(base_ui_dict)
    plot_fig = Figure(size = ui_options_obs["figsize"][])

    scene_default = Dict{String,Any}("t"=> 0., "component" => 1, 
                                     "line_point" => (0.0,0.0), 
                                     "line_vector" => (1.0,0.),
                                     "deviation" => 5.0)
    scene_dict = merge(scene_default, scene_options)
    println(scene_dict, scene_options)
    scene_obs = createObsDict(scene_dict)

    # --- Parameter & Method Observables ---
    shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)
    all_method_names = collect(keys(sim_config.methods_dict))
    methods_obs = Observable(issubset(sim_config.default_methods,all_method_names) ? sim_config.default_methods : all_method_names)

    # --- Base Controls Figure ---
    control_fig, update_notifier, ui_update, components, comp_sel = createBaseControlsFigure(
        plot_fig, shared_params_obs, method_params_collection_obs, methods_obs,
        all_method_names, ui_options_obs, scene_obs
    )
    comp_sel[] = scene_dict["component"]

    # --- Interactive Cut Controls ---
    Label(control_fig[end+1, :], "Cut Parameters:")
    cut_controls_layout = control_fig[end+1, :] = GridLayout(tellwidth=false)
    
    line_point_obs = scene_obs["line_point"]
    line_vector_obs = scene_obs["line_vector"]
    deviation_perc_obs = scene_obs["deviation"]

    Label(cut_controls_layout[1,1], "Point (x,y):", halign=:right)
    tb_point = Textbox(cut_controls_layout[1,2], placeholder=string(line_point_obs[]))
    on(tb_point.stored_string) do s; line_point_obs[] = parseValue(s); end

    Label(cut_controls_layout[2,1], "Vector (vx,vy):", halign=:right)
    tb_vector = Textbox(cut_controls_layout[2,2], placeholder=string(line_vector_obs[]))
    on(tb_vector.stored_string) do s; line_vector_obs[] = parseValue(s); end

    Label(cut_controls_layout[3,1], "Deviation (%):", halign=:right)
    tb_dev = Textbox(cut_controls_layout[3,2], placeholder=string(deviation_perc_obs[]))
    on(tb_dev.stored_string) do s; deviation_perc_obs[] = parseValue(s); end

    # --- Time Slider & Animation ---
    tSlider = Slider(control_fig[end+2,:], range = 0:scene_dict["t"], startvalue=scene_dict["t"])
    Label(control_fig[end-1,:], lift(t -> "t = $(round(t, digits=3))", tSlider.value))
    ani_layout = control_fig[end+1,:] = GridLayout()
    createAnimationControls!(ani_layout, plot_fig, tSlider, shared_params_obs, method_params_collection_obs, methods_obs, ui_options_obs, scene_obs)
    connectObsDict!(scene_obs, ["t","component"],[tSlider.value,comp_sel])
    # --- Axis and Labels ---
    axis_title = lift((line,t) -> "Cut along $(line), t = $(round(t, digits=3)))", line_vector_obs, tSlider.value)
    default_labels = Dict("xlabel" => "Distance along line", "ylabel" => "Solution (u)", "title" => axis_title)
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)
    ax = Axis(plot_fig[1,1], xlabel=label_obs["xlabel"], ylabel=label_obs["ylabel"], title=label_obs["title"])

    # --- Scene Observables for Saving State ---
    scene_obs = Dict{String,Observable}(
        "component" => comp_sel,
        "t" => tSlider.value,
        "line_point" => line_point_obs,
        "line_vector" => line_vector_obs,
        "deviation_perc" => deviation_perc_obs
    )


    # --- Data Structures ---
    xData = Observable(Vector{Tuple{Vector{Vector{Float64}}, Vector{Float64}}}(undef, 0))
    uData = Observable(Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, 0)) # Now contains VecOrMat
    uData_extr = Observable(Vector{Tuple{Vector{Vector{Float64}}, Vector{Float64}}}(undef, 0)) # Will contain the extracted component

    # --- LIFT BLOCK 1: Data Loading & Cut Extraction (no longer depends on comp_sel) ---
    lift(update_notifier, line_point_obs, line_vector_obs, deviation_perc_obs; ignore_equal_values=true) do _, lp, lv, dev
        println("Lift 1 (Cut): Loading 2D data and extracting 1D cut for all components...")
        active_methods_now = methods_obs[]
        tasks = assemble_simulation_tasks(shared_params_obs, method_params_collection_obs, active_methods_now)
        ensure_sim_data_exists!(tasks, sim_config)
        
        xData_tmp = Vector{Tuple{Vector{Vector{Float64}}, Vector{Float64}}}(undef, length(tasks))
        uData_tmp = Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, length(tasks))
        
        first_run = true
        for (i, params) in enumerate(tasks)
            sim_data = Utils.loadSimData(params)
            if isnothing(sim_data) || !isa(sim_data, SimData2D); continue; end

            xmin, xmax = extrema(p[1] for p in sim_data.x[1])
            ymin, ymax = extrema(p[2] for p in sim_data.x[1])
            domain_diagonal = sqrt((xmax - xmin)^2 + (ymax - ymin)^2)
            tolerance_dist = domain_diagonal * (dev / 100.0)

            num_timesteps = length(sim_data.t)
            cut_x_all_t = Vector{Vector{Float64}}(undef, num_timesteps)
            cut_u_all_t = Vector{VecOrMat{Float64}}(undef, num_timesteps)

            for t_idx in 1:num_timesteps
                # Pass the entire u matrix to the helper function
                u_snapshot_matrix = sim_data.u[t_idx]
                
                cut_x, cut_u = extract_line_cut_data(sim_data.x[t_idx], u_snapshot_matrix, lp, lv, tolerance_dist)
                cut_x_all_t[t_idx] = cut_x
                cut_u_all_t[t_idx] = cut_u
            end
            
            xData_tmp[i] = (cut_x_all_t, sim_data.t)
            uData_tmp[i] = (Dict("u" => cut_u_all_t), sim_data.t)
            current_comps = length(sim_data.u[1][1,:])
            if first_run
                components[] = Tuple(["Component $k" for k = 1:current_comps])
                first_run = false
            elseif current_comps != length(components[])
                @warn "Inconsistent components amount detected!"
            end
        end

        xData[] = xData_tmp
        uData[] = uData_tmp
        update_time_slider!(tSlider, xData[])
        println("Lift 1 (Cut): Update complete.")
    end

    # --- LIFT BLOCK 2: Fast Component Extraction ---
    lift(comp_sel, uData) do sel, u
        if isempty(u); return; end
        # `extractData` is general and can extract a column from the time series of matrices
        uData_extr[] = extractData(u, "u", sel)
        if !ui_options_obs["update_limits"][]; set_axis_limits!(ax, xData[], uData_extr[], ui_options_obs); end
    end

    # --- LIFT BLOCK 3: Plotting (now depends on the extracted data) ---
    lift(tSlider.value, uData_extr, ui_update) do t, u_extr, _
        # We now use uData_extr, which contains the single component data
        x_snapshot, y_snapshot = calculate_snapshot(xData[], u_extr, t)
        
        create_base_plot_1D!(
            plot_fig, ax, methods_obs[],
            x_snapshot, y_snapshot,
            ui_options_obs; 
            plot_observable = false
        )
    end

    # --- Display Figures ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return nothing
end