
# This is the new, fully generalized showConvergencePlot function.

"""
    showConvergencePlot(sim_config, key, param_values; x_stat_key, y_stat_key, kwargs...)

Creates a fully interactive plot that can show any simulation statistic against
any other statistic, or against the varied parameter `key`.

It loads all statistics from all simulation runs, populates two menus to select
the X and Y axis variables, and reactively updates the plot.
"""
function showConvergencePlot(
    sim_config::SimulationConfig,
    key::String,
    param_values::Union{AbstractVector, AbstractRange};
    calc_stats = false,
    reference_function::Union{Function,Nothing} = nothing,
    force_int_param::Bool = false,
    initial_calc::Bool = false,
    ui_options::UIType = :default,
    scene_options::Dict = Dict{String,Any}()
)
    # --- Initial Setup ---
    if initial_calc; calculateConvergenceData(sim_config, key, param_values; force_int_param = force_int_param, calc_stats = calc_stats, force_overwrite = false); end
    GLMakie.activate!()
    base_ui_dict = createUIDict(ui_options)
    ui_options_obs = create_ui_observables(base_ui_dict)
    plot_fig = Figure(size = (ui_options_obs["figsize"]))
    x_vals = force_int_param ? map(v -> trunc(Int64, v), param_values) : collect(param_values)

    # --- Parameter & Method Observables ---
    shared_params_obs = Dict{String,Observable}(k => Observable(v) for (k,v) in sim_config.shared_params)
    method_params_collection_obs = Dict{String,Dict{String, Observable}}(m => Dict(k=>Observable(v) for (k,v) in p) for (m,p) in sim_config.methods_dict)
    all_method_names = collect(keys(sim_config.methods_dict))
    methods_obs = Observable(filter(m -> m in all_method_names, sim_config.default_methods))
    scene_default = Dict{String,Any}("t"=> 0., "x_key" => key, "y_key" => key, "varied_key" => key, "variation_range" => x_vals, "component" => 1)
    scene_dict = merge(scene_default, scene_options)
    scene_obs = createObsDict(scene_dict)
    # --- Control Figure Setup ---
    control_fig, update_notifier, ui_update, components, comp_sel = 
        createBaseControlsFigure(plot_fig, shared_params_obs, method_params_collection_obs, methods_obs, all_method_names, ui_options_obs, scene_obs)

    comp_sel[] = scene_obs["component"][]
    Label(control_fig[end+1, :], "X-Axis Statistic:")
    x_menu_container = control_fig[end+1,:] = GridLayout()
    x_menu_handle = Observable{Union{Nothing, Menu}}(nothing)
    #selected_x_key_obs = Observable(isnothing(x_stat_key) ? key : x_stat_key)
    selected_x_key_obs = Observable(scene_obs["x_key"][])

    Label(control_fig[end+1, :], "Y-Axis Statistic:")
    y_menu_container = control_fig[end+1,:] = GridLayout()
    y_menu_handle = Observable{Union{Nothing, Menu}}(nothing)
    #selected_y_key_obs = Observable(isnothing(y_stat_key) ? key : y_stat_key)
    selected_y_key_obs = Observable(scene_obs["y_key"][])
    
    # --- Reactive Axis Labels ---
    reactive_title = lift((x,y) -> "Convergence: $y vs $x", selected_x_key_obs, selected_y_key_obs)
    default_labels = Dict{String,Any}("xlabel" => selected_x_key_obs, "ylabel" => selected_y_key_obs, "title" => reactive_title)
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)
    ax = Axis(plot_fig[1,1], xlabel=label_obs["xlabel"], ylabel=label_obs["ylabel"], title = label_obs["title"])

    # --- Time Slider, Log Toggles, etc. ---
    tSlider = Slider(control_fig[end+2,:], range = 0:scene_obs["t"][], startvalue = scene_obs["t"][])

    tLabel_text = lift(tSlider.value, tSlider.range) do val, range; 
        if range == [0]
            "t = N/A"
        else
            "t = $(round(val; digits = 4))"
        end 
    end
    Label(control_fig[end-1,:], tLabel_text)

    connectObsDict!(scene_obs, ["t","x_key","y_key", "component"],[tSlider.value,selected_x_key_obs,selected_y_key_obs,comp_sel])    

    # --- DATA STORAGE (using the tuple structure) ---
    raw_data_store = Observable(Vector{Vector{Tuple{Dict{String,Any}, Vector{Float64}}}}())
    extracted_x_data = Observable(Vector{Vector{Tuple{Any, Vector{Float64}}}}())
    extracted_y_data = Observable(Vector{Vector{Tuple{Any, Vector{Float64}}}}())

    # --- DATA LOADING AND MENU POPULATION ---
    lift(update_notifier) do _
        println("Data Loading: Loading all stats and populating menus...")
        active_num = length(methods_obs[])
        num_params = length(x_vals)
        sets_of_plottable_keys = [Set{String}() for _ in 1:active_num]
        temp_raw_data = [Vector{Tuple{Dict{String, Any}, Vector{<:Real}}}(undef, num_params) for _ in 1:active_num]
        
        # 1. Assemble tasks. This now returns a Matrix.
        tasks_matrix = assemble_simulation_tasks(
            shared_params_obs,
            method_params_collection_obs,
            methods_obs[],
            key,
            param_values;
            force_int_param = force_int_param
        )

        # --- STEP 2: Ensure SimData exists for all tasks ---
        ensure_sim_data_exists!(tasks_matrix, sim_config)

        # --- STEP 3 (Optional): Calculate all statistics ---
        if calc_stats
            calculateAllStats!(sim_config, key, param_values; force_int_param = force_int_param, ref_func_cont = reference_function)
        end

        num_methods, num_params = size(tasks_matrix)
        first_run = true

        for i in 1:num_methods    
            is_first_run_for_method = true
            for j in 1:num_params
                sim_data = loadSimData(tasks_matrix[i,j])

                # save results
                time_vec_for_run = sim_data.t
                sim_data.stats[key] = x_vals[j]
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
        create_or_update_selection_menu!(x_menu_container, x_menu_handle, sorted_keys, selected_x_key_obs)
        create_or_update_selection_menu!(y_menu_container, y_menu_handle, sorted_keys, selected_y_key_obs)
        
    end

    # --- DATA EXTRACTION ---
    lift(selected_x_key_obs, selected_y_key_obs, comp_sel, raw_data_store) do x_key, y_key, sel, all_raw_data
        if isempty(all_raw_data); return; end
        extracted_x_data[] = extractData(all_raw_data, x_key, sel)
        extracted_y_data[] = extractData(all_raw_data, y_key, sel)
        if !ui_options_obs["update_limits"][]
            set_axis_limits!(ax, extracted_x_data[], extracted_y_data[], ui_options_obs)
        end
        return nothing
    end

    # --- TIME DEPENDENCE ANALYSIS ---
    lift(extracted_x_data, extracted_y_data) do x_data, y_data
        update_time_slider!(tSlider, [x_data, y_data])
        return nothing
    end

    # --- FINAL PLOTTING LIFT ---
    lift(tSlider.value, extracted_x_data, extracted_y_data, ui_update) do t, x_data, y_data, _

        if isempty(x_data) || isempty(y_data); return; end
           
        x_snapshot, y_snapshot = calculate_snapshot(x_data, y_data, t)
        create_base_plot_1D!(
            plot_fig, ax, methods_obs[], x_snapshot, y_snapshot, ui_options_obs
        )
        
        delete_plots_by_label!(ax, "Reference Lines")
        if ui_options_obs["xlogscale"][] && ui_options_obs["ylogscale"][]
            plot_reference_lines!(ax, get(ui_options_obs, "reference", Observable(()))[])
        end
        return nothing
    end
    
    # --- Final Steps ---
    #display(GLMakie.Screen(), control_fig)
    #display(GLMakie.Screen(), plot_fig)
    return plot_fig, control_fig
end