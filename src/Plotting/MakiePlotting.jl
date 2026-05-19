include("UIStyles.jl")
include("PlottingUtils.jl")
include("ControlUtils.jl")
include("Controls.jl")
include("Render.jl")
include("CSVLauncher.jl")

# ==============================================================================
# --- GLOBAL UI STATE REFERENCES ---
# ==============================================================================
const GLOBAL_UI_OVERWRITE = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_VAR_OVERWRITE = Ref{Vector{Any}}(Any[:menu, :slider, :slider, :slider, :slider])
const GLOBAL_SCENE_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())

const LEGEND_REF = Ref{Symbol}(:none)

function create_plot_manager(sim_config::SimulationConfig{F}, master_ui::Dict, ui_overwrite::Dict, init_type::Symbol) where {F}
    varied_dict = sim_config.varied_params
    vars = isempty(varied_dict) ? [] : collect(keys(varied_dict))
    append!(vars, BaseVariables)

    base_types = Observable{Vector{Any}}([[:menu]; [:slider for _ in 2:5]])
    sim_obs = NestedObsDict()
    
    make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
    sim_obs["shared"] = Dict(k => make_obs(v) for (k, v) in sim_config.shared_params)
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => make_obs(v) for (k, v) in m_params)
    end

    ui_obs = NestedObsDict()
    methods_obs = Observable(copy(sim_config.default_methods))

    controls_obs = Dict{String, Observable}(
        "base_types" => base_types, 
        "Master_UI_Ref" => Observable(master_ui)
    )

    config_dict = ParamDict(
        "Parameters" => copy(sim_config.varied_params),
        "General"    => Dict{String, Any}(
            "simulation_func" => string(sim_config.simulation_func),
            "reference_func"  => isnothing(sim_config.reference_name) ? "none" : string(sim_config.reference_name)
        )
    )
    
    manager = PlotManager(sim_obs, ui_obs, config_dict, controls_obs, methods_obs, vars, copy(sim_config.shared_params))
    switch_ui_plot_type!(manager, init_type)
    
    for (scope, keys_dict) in ui_overwrite
        if haskey(manager.ui, scope)
            for (k, v) in keys_dict
                if haskey(manager.ui[scope], k)
                    manager.ui[scope][k][] = v
                end
            end
        end
    end
    
    return manager
end

function show_unified_fig(sim_config::SimulationConfig)
    ui_overwrite = deepcopy(GLOBAL_UI_OVERWRITE[])
    var_overwrite = deepcopy(GLOBAL_VAR_OVERWRITE[])
    scene_options = deepcopy(GLOBAL_SCENE_OPTIONS[])

    ui_obs = create_master_ui_observables()
    final_scene = get_base_scene_options()
    
    if haskey(scene_options, "Menu")
        for (k, v) in scene_options["Menu"]; final_scene["$(k)_Selection"] = v; end
    end
    if haskey(scene_options, "Slider")
        for (k, v) in scene_options["Slider"]; final_scene["$(k)_Value"] = v; end
    end
    for (k, v) in scene_options
        if k != "Menu" && k != "Slider"; final_scene[k] = v; end
    end
    
    raw_type = get(final_scene, "Plot-Type_Selection", "Lines")
    init_type = raw_type isa String ? Symbol(lowercase(replace(raw_type, " " => ""))) : raw_type

    GLMakie.activate!()
    manager = create_plot_manager(sim_config, ui_obs, ui_overwrite, init_type)
    plot_fig = Figure(size = manager.ui["Axis-General"]["figsize"][])
    plot_screen_ref = Ref(GLMakie.Screen(title = "Makie Plot"))
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())

    manager.controls["base_types"][] = var_overwrite
    ctrl_fig = create_controls(plot_fig, manager, plot_data_obs, final_scene)    
    
    sim_update = manager.controls["Simulation_Update"]
    methods_obs = manager.methods

    on(sim_update) do _
        if !GLMakie.isopen(plot_screen_ref[])
            plot_screen_ref[] = GLMakie.Screen(title = "Makie Plot")
            display(plot_screen_ref[], plot_fig)
        end
    end

    render_observers = ObserverFunction[]

    function rebuild_plot_layout!()
        ptype_sym = manager.controls["Plot-Type_Selection"][]
        # Clear existing observers
        for obs in render_observers; off(obs); end
        empty!(render_observers)
        
        # Clear the entire figure layout properly
        empty!(plot_fig)  # This should clear everything
        for elem in contents(plot_fig.layout)
            if is_target && elem isa Makie.Block
                delete!(elem)
            end
        end
        # Reset the layout structure
        trim!(plot_fig.layout)  # Remove empty rows/columns
        println(contents(plot_fig.layout))
        # Switch to new plot type
        switch_ui_plot_type!(manager, ptype_sym)
        
        # Setup new rendering
        new_obs = setup_render_lift!(plot_fig, plot_data_obs, manager, Val(ptype_sym))
        if !isnothing(new_obs)
            append!(render_observers, new_obs)
        end
        
        # Properly handle screen refresh
        scr = plot_screen_ref[]
        if GLMakie.isopen(scr)
            try
                GLMakie.close(scr) 
            catch e
                @debug "Screen close suppressed: $e"
            end
        end
        
        # Create fresh screen reference
        plot_screen_ref[] = GLMakie.Screen(title = "Makie Plot")
        
        # Display the figure properly
        display(plot_screen_ref[], plot_fig)
        notify(plot_data_obs)
    end

    onany(sim_update, methods_obs) do _, active_methods
        Base.invokelatest(update_plot_data_collection!,
            plot_data_obs[], sim_config, manager, active_methods, to_value(manager.controls["base_types"]);
            force_reload = (sim_update[] > 0), 
        )
        
        target = manager.controls["Compare_Target_Selection"][]
        if target != "None"
            rebuild_plot_layout!()
        else
            notify(plot_data_obs)
        end
    end

    on(manager.controls["Plot-Type_Selection"]) do ptype_sym
        rebuild_plot_layout!()
    end

    on(manager.controls["Compare_Target_Selection"]) do _
        rebuild_plot_layout!()
    end

    on(manager.controls["Compare_Columns_Selection"]) do _
        rebuild_plot_layout!()
    end
    
    on(manager.controls["Compare_Link_Selection"]) do _
        rebuild_plot_layout!()
    end
    on(manager.ui["Axis-General"]["legend_pos"]) do _
        rebuild_plot_layout!()
    end
    # --- THE FIX: Eliminate the Startup Cascade! ---
    # 1. Load the data silently bypassing the reactive UI cascade
    Base.invokelatest(update_plot_data_collection!,
        plot_data_obs.val, sim_config, manager, methods_obs.val, to_value(manager.controls["base_types"]);
        force_reload = true, 
    )
    
    # 2. Assign the update toggle silently so future clicks work
    sim_update.val = 1 
    
    # 3. Build the layout EXACTLY once. This will push the data and trigger the first render!
    rebuild_plot_layout!()
    
    return plot_fig, ctrl_fig, manager
end

function setup_render_lift!(plot_fig::Figure, plot_data_obs::Observable, manager::PlotManager, ::Val{T}) where T
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || T == :surface
    c = manager.controls 
    selector_obs = [haskey(c, "$(n)_Value") ? c["$(n)_Value"] : c["$(n)_Selection"] for n in manager.plot_vars]
    x_sel, y_sel, z_sel, u_sel = c["X-Axis_Selection"], c["Y-Axis_Selection"], c["Z-Axis_Selection"], c["U-Axis_Selection"]
    
    target = c["Compare_Target_Selection"][]
    cols = parse(Int, c["Compare_Columns_Selection"][])
    link_mode = get(c, "Compare_Link_Selection", Observable("Fully Coupled"))[]
    
    num_plots = 1
    compare_labels = String[]
    compare_vals = Any[]
    
    plot_data_dict = plot_data_obs[]
    if !isempty(plot_data_dict)
        pd_first = first(values(plot_data_dict))
        if target == "Methods"
            compare_labels = manager.methods[]
            num_plots = length(compare_labels)
        elseif target == "Component"
            comp_idx = findfirst(isequal("c"), manager.plot_vars)
            num_plots = size(pd_first.data["u"], comp_idx - (length(manager.plot_vars) - 5))
            compare_labels = ["Component $i" for i in 1:num_plots]
            compare_vals = collect(1:num_plots)
        elseif target == "Time"
            num_plots = length(pd_first.t_vals)
            compare_labels = ["t = $(round(t, sigdigits=4))" for t in pd_first.t_vals]
            compare_vals = pd_first.t_vals
        elseif target in manager.plot_vars
            idx = findfirst(isequal(target), manager.plot_vars)
            vals = pd_first.active_param_values[idx]
            num_plots = length(vals)
            compare_labels = ["$target = $(round(v, sigdigits=4))" for v in vals]
            compare_vals = vals
        end
    end
    
    if target == "None" || num_plots == 0
        num_plots = 1
        target = "None"
    end
    
    # --- RESTORED: Main content safely lives at [1, 1] ---
    main_content_layout = plot_fig[end, end] = GridLayout()
    
    axes = []
    if target != "None" && num_plots > 1
        for i in 1:num_plots
            row = (i - 1) ÷ cols + 1
            col = (i - 1) % cols + 1
            ax = is_3d_axis ? Axis3(main_content_layout[row, col], perspectiveness=0.5) : Axis(main_content_layout[row, col])
            push!(axes, ax)
        end
        if !is_3d_axis && link_mode == "Fully Coupled"
            linkaxes!(axes...) 
        end
    else
        ax = is_3d_axis ? Axis3(main_content_layout[1, 1], perspectiveness=0.5) : Axis(main_content_layout[1, 1])
        push!(axes, ax)
    end
    
    # --- MODULAR RENDER HELPERS ---
    function _render_no_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        data_tuples, valid_labels, title_str = extract_data(data, manager, sel_vals, x_key, y_key, z_key, u_key, Val(PLOT_DIM_MAP[T]))
        
        has_cr = haskey(ui_app, "colorrange")
        orig_cr = has_cr ? ui_app["colorrange"].val : "default"
        if has_cr && orig_cr == "default"
            u_all = Float64[]
            for us in data_tuples[end]
                append!(u_all, filter(isfinite, us))
            end
            l_u, h_u = isempty(u_all) ? (0.0, 1.0) : (minimum(u_all), maximum(u_all))
            if l_u == h_u; h_u += 1e-6; end
            ui_app["colorrange"].val = (l_u, h_u) 
        end

        ax = axes[1]
        update_base_plot!(plot_fig, ax, valid_labels, data_tuples, manager, x_key, y_key, z_key, u_key, title_str, Val(T))
        if !is_3d_axis; plot_HUD!(ax, manager) end
        
        if has_cr; ui_app["colorrange"].val = orig_cr; end
    end

    function _render_method_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        data_tuples, valid_labels, title_str = extract_data(data, manager, sel_vals, x_key, y_key, z_key, u_key, Val(PLOT_DIM_MAP[T]))
        
        has_cr = haskey(ui_app, "colorrange")
        orig_cr = has_cr ? ui_app["colorrange"].val : "default"
        
        if has_cr && orig_cr == "default" && link_mode != "Decoupled"
            u_all = Float64[]
            for us in data_tuples[end]
                append!(u_all, filter(isfinite, us))
            end
            l_u, h_u = isempty(u_all) ? (0.0, 1.0) : (minimum(u_all), maximum(u_all))
            if l_u == h_u; h_u += 1e-6; end
            ui_app["colorrange"].val = (l_u, h_u) 
        end
        
        orig_leg_pos = manager.ui["Axis-General"]["legend_pos"].val
        orig_title = manager.ui["Labels"]["title"].val
        orig_title_size = manager.ui["Axis-General"]["title_size"].val
        
        manager.ui["Axis-General"]["legend_pos"].val = :none
        manager.ui["Axis-General"]["title_size"].val = manager.ui["Axis-General"]["label_size"].val 
        
        for (i, label) in enumerate(valid_labels)
            if i > length(axes); break; end
            ax = axes[i]
            single_tuples = Tuple([dt[i]] for dt in data_tuples)
            manager.ui["Labels"]["title"].val = label
            
            update_base_plot!(plot_fig, ax, [label], single_tuples, manager, x_key, y_key, z_key, u_key, label, Val(T))
            
            if !is_3d_axis; plot_HUD!(ax, manager) end
        end
        
        manager.ui["Axis-General"]["legend_pos"].val = orig_leg_pos
        manager.ui["Labels"]["title"].val = orig_title
        manager.ui["Axis-General"]["title_size"].val = orig_title_size
        
        if has_cr; ui_app["colorrange"].val = orig_cr; end
    end

    function _render_variable_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        target_idx = -1
        if target == "Component"
            target_idx = findfirst(isequal("c"), manager.plot_vars)
        elseif target == "Time"
            target_idx = findfirst(isequal("t"), manager.plot_vars)
        else
            target_idx = findfirst(isequal(target), manager.plot_vars)
        end
        
        u_all = Float64[]
        all_subplots_data = []
        
        for i in 1:num_plots
            mutated_sel_vals = collect(sel_vals)
            mutated_sel_vals[target_idx] = compare_vals[i]
            dt, vl, ts = extract_data(data, manager, mutated_sel_vals, x_key, y_key, z_key, u_key, Val(PLOT_DIM_MAP[T]))
            push!(all_subplots_data, (dt, vl, ts))
            
            for us in dt[end]
                append!(u_all, filter(isfinite, us))
            end
        end
        
        has_cr = haskey(ui_app, "colorrange")
        orig_cr = has_cr ? ui_app["colorrange"].val : "default"
        
        if has_cr && orig_cr == "default" && link_mode != "Decoupled"
            l_u, h_u = isempty(u_all) ? (0.0, 1.0) : (minimum(u_all), maximum(u_all))
            if l_u == h_u; h_u += 1e-6; end
            ui_app["colorrange"].val = (l_u, h_u) 
        end
        
        orig_title = manager.ui["Labels"]["title"].val
        orig_title_size = manager.ui["Axis-General"]["title_size"].val
        orig_leg_pos = manager.ui["Axis-General"]["legend_pos"].val
        
        manager.ui["Axis-General"]["title_size"].val = manager.ui["Axis-General"]["label_size"].val 
        
        for i in 1:num_plots
            if i > length(axes); break; end
            ax = axes[i]
            dt, vl, ts = all_subplots_data[i]
            label = compare_labels[i]
            manager.ui["Labels"]["title"].val = label
            
            update_base_plot!(plot_fig, ax, vl, dt, manager, x_key, y_key, z_key, u_key, label, Val(T))
            
            if !is_3d_axis; plot_HUD!(ax, manager) end
        end
        
        manager.ui["Labels"]["title"].val = orig_title
        manager.ui["Axis-General"]["title_size"].val = orig_title_size
        manager.ui["Axis-General"]["legend_pos"].val = orig_leg_pos 
        
        if has_cr; ui_app["colorrange"].val = orig_cr; end
    end

    # --- THE RENDER LOOP ---
    render_obs = onany(plot_data_obs, x_sel, y_sel, z_sel, u_sel, c["UI_Update"], selector_obs...) do data, x_key, y_key, z_key, u_key, _ui, sel_vals...
        (isnothing(x_key) || isnothing(u_key) || x_key == "-" || u_key == "-") && return
        isempty(data) && return

        # 1. Nuclear Layout Cleanup (For Legend/Colorbar switching)
        for elem in copy(contents(plot_fig.layout))
            if elem isa Legend || elem isa Colorbar
                delete!(elem)
            end
        end
        

        # 3. Reset axes scales for data injection
        for ax in axes
            if !is_3d_axis
                ax.xscale[] = identity
                ax.yscale[] = identity
            end
        end
        
        ui_app = manager.ui["Plot-Style"]
        
        # 4. Dispatch Rendering
        if target == "None" || num_plots <= 1
            _render_no_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        elseif target == "Methods"
            _render_method_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        else
            _render_variable_comparison!(data, sel_vals, x_key, y_key, z_key, u_key, ui_app)
        end
    end
end