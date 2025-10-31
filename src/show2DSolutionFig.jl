
"""
    show2DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot for `SimData2D` with animation playback.
This version uses a modular, reactive architecture analogous to the 1D plotting functions.
"""
function show2DSolutionFig(sim_config::SimulationConfig; calc_stats = false, reference_function::Union{Function,Nothing} = nothing, scene_options::Dict = Dict{String,Any}(), ui_options::UIType = :default)

    # --- Basic Setup & UI ---
    base_ui_dict = createUIDict2D(ui_options)
    ui_options_obs = create_ui_observables(base_ui_dict)
    plot_fig = Figure(size = ui_options_obs["figsize"][])

    scene_default = Dict{String,Any}("t"=> 0., "component" => 1)
    scene_dict = merge(scene_default, scene_options)
    scene_obs = createObsDict(scene_dict)

    # --- Parameter & Method Observables ---
    shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)
    all_method_names = collect(keys(sim_config.methods_dict))
    methods_obs = Observable(issubset(sim_config.default_methods, all_method_names) ? sim_config.default_methods : all_method_names)

    # --- Base Controls Figure ---
    control_fig, update_notifier, ui_update, components, comp_sel = createBaseControlsFigure(
        plot_fig, shared_params_obs, method_params_collection_obs, methods_obs,
        all_method_names, ui_options_obs, scene_obs
    )

    # --- 2D-Specific Controls ---
    Label(control_fig[end+1,:], "Plot Type: (Scatter / Surface)")
    plot_type_toggle = Toggle(control_fig[end+1,:], active = ui_options_obs["plot_as_surface"][])
    on(plot_type_toggle.active) do active_state
        ui_options_obs["plot_as_surface"][] = active_state
    end
    
    Label(control_fig[end+1,:], "Colormap:")
    cmap_menu = Menu(control_fig[end+1,:], options = ui_options_obs["colormaps"][])
    cmap_menu.selection[] = ui_options_obs["colormap"][]
    on(cmap_menu.selection) do cmap
        ui_options_obs["colormap"][] = cmap
    end

    #--- Time Slider & Animation Controls ---
    tSlider = GLMakie.Slider(control_fig[end+1, 1:end], range=0:0.01:1, startvalue=scene_dict["t"])
    comp_sel[] = scene_dict["component"]
    # --- 3. Scene-Specific Observables for 2D Plot ---
    connectObsDict!(scene_obs, ["t","component"],[tSlider.value,comp_sel])

    Label(control_fig[end-1,:], lift(t -> "t = $(round(t; digits=3))", tSlider.value))
    ani_layout = control_fig[end+1,:] = GridLayout()
    createAnimationControls!(ani_layout, plot_fig, tSlider, shared_params_obs, method_params_collection_obs, methods_obs, ui_options_obs, scene_obs)

    # --- Axis and Labels ---
    dynamic_zlabel = lift(comp_sel, ui_options_obs["plot_as_surface"]) do c, is_surf
        is_surf && c <= length(components[]) ? "$(components[][c])" : ""
    end
    dynamic_clabel = lift(comp_sel) do c; c <= length(components[]) ? "$(components[][c])" : "" end
    dynamic_title = lift(tSlider.value) do t; "t = $(round(t, digits=3))" end

    default_labels = Dict("xlabel" => "Position (x)", "ylabel" => "Position (y)", "zlabel" => dynamic_zlabel, "colorbar_label" => dynamic_clabel, "title" => dynamic_title)
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)
    ax = Axis3(plot_fig[1,1], xlabel=label_obs["xlabel"], ylabel=label_obs["ylabel"], zlabel=label_obs["zlabel"], title=label_obs["title"])
    
    # Scene observables for saving/reloading state
    scene_obs = Dict{String,Observable}(
        "component" => comp_sel,
        "t" => tSlider.value
    )
    #set_scene_options!(scene_obs, scene_options)

    # --- Data Structures ---
    xData = Observable(Vector{Tuple{Vector{Vector{NTuple{2,Float64}}}, Vector{Float64}}}(undef, 0))
    uData = Observable(Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, 0))
    uData_extr = Observable(Vector{Tuple{Vector{VecOrMat}, Vector{Float64}}}(undef, 0))
    color_range = Observable((0.0, 1.0)) # Global range for color and Z-axis

    # --- LIFT BLOCK 1: Data Loading / Simulation ---
    lift(update_notifier; ignore_equal_values=true) do _
        @info "Lift 1 (2D): Running sims / loading data..."
        active_methods_now = methods_obs[]
        tasks = assemble_simulation_tasks(shared_params_obs, method_params_collection_obs, active_methods_now)
        ensure_sim_data_exists!(tasks, sim_config)

        if calc_stats; calculateAllStats!(sim_config; ref_func_cont = reference_function); end

        xData_tmp = Vector{Tuple{Vector{Vector{NTuple{2,Float64}}}, Vector{Float64}}}(undef, length(tasks))
        uData_tmp = Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, length(tasks))
        
        g_umin, g_umax = Inf, -Inf
        first_run = true

        for (i, params) in enumerate(tasks)
            sim_data = Utils.loadSimData(params)
            if isnothing(sim_data) || !isa(sim_data, SimData2D); continue; end
            
            xData_tmp[i] = (sim_data.x, sim_data.t)
            uData_tmp[i] = (Dict("u" => sim_data.u), sim_data.t)
            
            # Update global U limits for color range
            for u_vec in sim_data.u; if !isempty(u_vec); umin_t, umax_t = extrema(u_vec); g_umin=min(g_umin, umin_t); g_umax=max(g_umax, umax_t); end; end

            # Update components menu
            if first_run && !isempty(sim_data.u) && !isempty(sim_data.u[1])
                num_comps = sim_data.u[1] isa AbstractMatrix ? size(sim_data.u[1], 2) : 1
                components[] = Tuple(["Component $k" for k = 1:num_comps])
                first_run = false
            end
        end
        
        xData[] = xData_tmp
        uData[] = uData_tmp
        update_time_slider!(tSlider, xData[])
        
        # # Finalize and store global Z limits / color range
        # pad_range = g_umax - g_umin
        # pad = ui_options_obs["axis_limit_padding"][] * (isinf(pad_range) || isnan(pad_range) ? 0.0 : pad_range) / 2.0
        # pad = (pad <= 1e-6 && pad_range <= 1e-6) ? 0.1 : pad
        # global_zlims[] = (g_umin - pad, g_umax + pad)

        @info "Lift 1 (2D): Update complete."
    end

    # --- LIFT BLOCK 2: Component Extraction ---
    lift(comp_sel, uData) do sel, u
        if isempty(u); return; end
        uData_extr[] = extractData(u, "u", sel)
        set_axis_limits!(ax, xData[], uData_extr[], ui_options_obs, color_range)
        return 
    end

    # --- LIFT BLOCK 3: Plotting ---
    lift(tSlider.value, uData_extr, ui_update) do t, u_data, _
        #save_scene_info!(scene_obs, scene_info)
        x_snapshot, u_snapshot = calculate_snapshot(xData[], u_data, t)
        
        create_base_plot_2D!(
            plot_fig, ax, methods_obs[],
            x_snapshot, u_snapshot,
            ui_options_obs,
            color_range,
            label_obs
        )
    end

    # --- Display Figures ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return nothing
end