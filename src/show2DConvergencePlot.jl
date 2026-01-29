function show2DConvergencePlot(
    sim_config::SimulationConfig,
    key1::String,
    param_values1::Union{AbstractVector, AbstractRange},
    key2::String,
    param_values2::Union{AbstractVector, AbstractRange};
    # Options
    calc_stats = false,
    reference_function::Union{Function,Nothing} = nothing,
    force_int_param1::Bool = false,
    force_int_param2::Bool = false,
    initial_calc::Bool = false,
    ui_options::UIType = :default,
    scene_options::Dict = Dict{String,Any}()
)
    # --- Initial Setup ---
    GLMakie.activate!()
    base_ui_dict = createUIDict2D(ui_options)
    ui_options_obs = create_ui_observables(base_ui_dict)
    plot_fig = Figure(size = ui_options_obs["figsize"][])

    # Prepare Parameter Values
    p1_vals = force_int_param1 ? map(v -> trunc(Int64, v), param_values1) : collect(param_values1)
    p2_vals = force_int_param2 ? map(v -> trunc(Int64, v), param_values2) : collect(param_values2)

    num_params = length(p1_vals) * length(p2_vals)
    # --- Observables ---
    shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)
    all_method_names = collect(keys(sim_config.methods_dict))
    methods_obs = Observable(issubset(sim_config.default_methods, all_method_names) ? 
                             sim_config.default_methods : all_method_names)

    scene_default = Dict{String,Any}("t"=> 0., "stat_key" => "default", "component" => 1)
    scene_dict = merge(scene_default, scene_options)
    scene_obs = createObsDict(scene_dict)

    # --- Controls ---
    control_fig, update_notifier, ui_update, components, comp_sel = 
        createBaseControlsFigure(plot_fig, shared_params_obs, method_params_collection_obs, methods_obs, all_method_names, ui_options_obs, scene_obs)

    # 2D Controls
    Label(control_fig[end+1,:], "Plot Type:")
    plot_type_menu = Menu(control_fig[end+1,:], options = ui_options_obs["plot_options"][])
    on(plot_type_menu.selection) do sel; ui_options_obs["plot_type"][] = sel; end
    plot_type_menu.selection[] = ui_options_obs["plot_type"][] 

    Label(control_fig[end+1, :], "Statistic:")
    stat_menu_container = control_fig[end+1,:] = GridLayout()
    stat_menu_handle = Observable{Union{Nothing, Menu}}(nothing)
    selected_stat_key_obs = Observable(scene_obs["stat_key"][])
    
    comp_sel[] = scene_obs["component"][]

    # Axis Labels & Slider
    z_label_obs = lift(k -> "$k", selected_stat_key_obs)
    default_labels = Dict(
        "xlabel" => key1, "ylabel" => key2, "zlabel" => z_label_obs, 
        "title" => lift((z,t)->"$z (t=$(round(t,digits=3)))", z_label_obs, scene_obs["t"]),
        "colorbar_label" => z_label_obs
    )
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)
    ax = Axis3(plot_fig[1,1], xlabel=label_obs["xlabel"], ylabel=label_obs["ylabel"], zlabel=label_obs["zlabel"], title=label_obs["title"])

    tSlider = Slider(control_fig[end+1,:], range = 0:0.1:1, startvalue = 0)
    Label(control_fig[end-1,:], lift(t -> "t = $(round(t; digits=4))", tSlider.value))
    connectObsDict!(scene_obs, ["t", "stat_key", "component"], [tSlider.value, selected_stat_key_obs, comp_sel])

    # --- DATA STORAGE ---
    # Stores Matrix (Methods x Runs) of (StatsDict, TimeVec)
    raw_stats_matrix = Observable(Matrix{Tuple{Dict{String,Any}, Vector{Float64}}}(undef, 0, 0))
    
    # xData: Vector (Methods) of Tuple(PointsVec, DummyTime)
    xData = Observable(Vector{Vector{NTuple{2,Float64}}}(undef, 0))
    
    

    
    # uData: Vector (Methods) of Tuple(ValuesVec, DummyTime)
    raw_data_store = Observable(Vector{Vector{Tuple{Dict{String,Any}, Vector{Float64}}}}())
    extracted_y_data = Observable(Vector{Vector{Tuple{Any, Vector{Float64}}}}())
    
    color_range = Observable((0.0, 1.0))

    # --- LIFT 1: LOADING ---
    lift(update_notifier) do _
        active_methods = methods_obs[]
        active_num = length(active_methods)
        sets_of_plottable_keys = [Set{String}() for _ in 1:active_num]
        temp_raw_data = [Vector{Tuple{Dict{String, Any}, Vector{<:Real}}}(undef, num_params) for _ in 1:active_num]
        xData[] = [vec([NTuple{2, Float64}((v1, v2)) for v1 in p1_vals, v2 in p2_vals]) for _ in 1:length(active_methods)]
        # 1. Create Tasks (Using new 2D helper)
        # Result is Matrix (Methods x Runs)
        tasks_matrix = assemble_simulation_tasks(
            shared_params_obs, method_params_collection_obs, active_methods,
            key1, p1_vals, key2, p2_vals; 
            force_int_param1=force_int_param1, force_int_param2=force_int_param2
        )
        
        # 2. Run Simulations
        ensure_sim_data_exists!(tasks_matrix, sim_config)
        
        num_methods, num_params = size(tasks_matrix)
        first_run = true

        for i in 1:num_methods    
            is_first_run_for_method = true
            for j in 1:num_params
                sim_data = loadSimData(tasks_matrix[i,j])

                # save results
                time_vec_for_run = sim_data.t
                temp_raw_data[i][j] = (sim_data.stats, time_vec_for_run)

                
                # Update components
                current_comps = length(sim_data.u[1][1,:])
                if first_run
                    components[] = Tuple(["u_$k" for k = 1:current_comps])
                    first_run = false
                elseif current_comps != length(components[])
                    @warn "Inconsistent components amount detected! Current: $current_comps vs $(length(components[]))"
                end

                current_run_plottable_keys = Set(keys(filter(p -> isa(p.second, Union{Number, AbstractVector, AbstractMatrix}), sim_data.stats)))
                if is_first_run_for_method
                    sets_of_plottable_keys[i] = current_run_plottable_keys
                    is_first_run_for_method = false
                else
                    intersect!(sets_of_plottable_keys[i], current_run_plottable_keys)
                end
            end
        end
        raw_data_store[] = temp_raw_data
        common_keys = if !isempty(sets_of_plottable_keys); intersect(sets_of_plottable_keys...); else Set{String}(); end
        sorted_keys = sort(collect(common_keys))        
        create_or_update_selection_menu!(stat_menu_container, stat_menu_handle, sorted_keys, selected_stat_key_obs)

        # 4. Populate xData (Static Grid)
        # Generate the flattened grid points once.
        # Iterators.product creates order (v1, v2) with v1 changing fastest (column-major behavior in Julia)
        # Note: assemble_simulation_tasks uses the same iterator order!
    end

    # --- LIFT 2: EXTRACTION ---
    lift(selected_stat_key_obs, comp_sel, raw_data_store) do stat_key, sel, all_raw_data
        if isempty(all_raw_data) || isnothing(stat_key); return; end
        
        extracted_y_data[] = extractData(all_raw_data, stat_key,sel)
        set_axis_limits!(ax, xData[], extracted_y_data[], ui_options_obs, color_range)
        update_time_slider!(tSlider, extracted_y_data[])
    end

    # --- LIFT 3: PLOTTING ---
    lift(tSlider.value, extracted_y_data, ui_update) do t, y_data, _
        if isempty(y_data); return; end
        
        # calculate_snapshot returns Vector{Any} (abstrakt).
        u_snapshot_abstract = calculate_snapshot(y_data, t)
        
        # FIX: Konvertiere explizit zu Vector{Vector{Float64}}
        # GLMakie braucht konkrete Typen für den Shader.
        u_snapshot = [Float64.(u) for u in u_snapshot_abstract]
        # println((y_data))
        # println((xData[][2]))
        # error("TEST")
        create_base_plot_2D!(
            plot_fig, ax, methods_obs[],
            xData[], u_snapshot,
            ui_options_obs,
            color_range,
            label_obs
        )
    end

    return plot_fig, control_fig
end