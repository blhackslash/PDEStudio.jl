# ==============================================================================
# --- GLOBAL UI STATE REFERENCES ---
# ==============================================================================
const GLOBAL_UI_OVERWRITE = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_VAR_OVERWRITE = Ref{Vector{Any}}(Any[:menu, :slider, :slider, :slider, :slider])
const GLOBAL_SCENE_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_LAYOUT_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())

# Singleton Global Observables & State
const ACTIVE_SIM_CONFIG = Observable{Any}(nothing) # THE FIX: Reactive Config Pipeline
const ACTIVE_PLOT_MANAGER = Ref{PlotManager}()
#const PLOTTER_UI_STATE = Ref{Dict{Symbol, Any}}(Dict(:is_open => false, :ctrl_fig => nothing, :plot_layout => nothing))
const PLOTTER_UI_STATE = Ref{Dict{Symbol, Any}}(Dict(:is_open => false, :master_fig => nothing))

function set_sim_config!(config::SimulationConfig)
    ACTIVE_SIM_CONFIG[] = config
    return
end

const LEGEND_REF = Ref{Symbol}(:none)
function dummy_simulation_function(args...); return nothing; end

"""
    set_sim_config!(csv_name::String, manager)

Searches for a CSV by name in the figures, animations, and Experiments folders.
If found, it parses it, reconstructs the `SimulationConfig`, runs the simulations,
and dynamically updates the active Plotter UI.
"""
function set_sim_config!(csv_name::String)
    manager = ACTIVE_PLOT_MANAGER[]
    filename = endswith(lowercase(csv_name), ".csv") ? csv_name : csv_name * ".csv"
    
    save_root = get_save_path()
    sim_root = _SIM_ROOT_PATH[]
    search_dirs = [
        joinpath(save_root, "figures"),
        joinpath(save_root, "animations"),
        joinpath(sim_root, "Experiments")
    ]
    
    filepath = ""
    for dir in search_dirs
        if isdir(dir)
            test_path = joinpath(dir, filename)
            if isfile(test_path); filepath = test_path; break; end
            
            for subdir in readdir(dir; join=true)
                if isdir(subdir)
                    test_path = joinpath(subdir, filename)
                    if isfile(test_path); filepath = test_path; break; end
                end
            end
        end
        if !isempty(filepath); break; end
    end
    
    if isempty(filepath)
        @warn "CSV file '$filename' not found."
        return
    end
    
    # Call the new helper!
    load_and_apply_csv!(manager, filepath)
end

"""
    reset_plotter!()

Completely wipes the UI state, purges observables, and destroys the active window. 
Guarantees a 100% clean slate for the next @plot call.
"""
function reset_plotter!()
    fig = PLOTTER_UI_STATE[][:master_fig]
    if !isnothing(fig)
        try
            screen = Makie.getscreen(fig.scene)
            if !isnothing(screen); close(screen); end
        catch
        end
        empty!(fig)
    end
    PLOTTER_UI_STATE[][:is_open] = false
    PLOTTER_UI_STATE[][:master_fig] = nothing
    empty!(ACTIVE_SIM_CONFIG.listeners)
    ACTIVE_SIM_CONFIG.val = nothing
    @info "Plotter state completely cleared!"
end

function create_plot_manager(sim_config::SimulationConfig{F}, master_ui::Dict, ui_overwrite::Dict, init_type::Symbol) where {F}
    varied_dict = sim_config.varied_params
    vars = isempty(varied_dict) ? String[] : sort(collect(keys(varied_dict)))
    append!(vars, BaseVariables)

    sim_obs = NestedObsDict()
    make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
    sim_obs["shared"] = Dict(k => make_obs(v) for (k, v) in sim_config.shared_params)
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => make_obs(v) for (k, v) in m_params)
    end

    ui_obs = NestedObsDict()
    methods_obs = Observable(copy(sim_config.default_methods))

    # --- THE FIX: Clean Semantic State ---
    triggers = Dict{String, Observable{Int}}(
        "Layout_Update"     => Observable(0),
        "Scene_Update"      => Observable(0),
        "Primitive_Rebuild" => Observable(0),
        "Data_Sync"         => Observable(0),
        "UI_Update"         => Observable(0),
        "Simulation_Update" => Observable(0)
    )
    locks = Dict{String, Bool}(
        "Menu_Sync" => false, 
        "Layout"    => false, 
        "Scene"     => false,  # <-- ADD THIS 
        "Primitive" => false,
        "Data"      => false, 
        "UI"        => false   
    )
    state = Dict{String, Any}(
        "Config_Just_Loaded"      => Observable(false),
        "plot_window_initialized" => Observable(false),
        "base_types"              => Observable{Vector{Any}}([[:menu]; [:slider for _ in 2:5]]),
        "Active_Axes"             => Observable{Vector{Int}}(Int[]),
        "Is_Activate_Mode"        => Observable(true),
        "Is_Animating"            => Observable(false),
        "Animation_Timer"         => Observable{Any}(nothing),
        "Active_Target_Obs"       => Observable{Any}(nothing),
        "Master_UI_Ref"           => Observable(master_ui),
        "Layout_Dict"             => Observable(Dict{String, Any}())
    )
    # THE FIX: Restore the config_dict initialization!
    config_dict = ParamDict(
        "Parameters" => copy(sim_config.varied_params),
        "General"    => Dict{String, Any}(
            "simulation_func" => sim_config.simulation_name,
            "reference_func"  => isnothing(sim_config.reference_name) ? "none" : sim_config.reference_name
        )
    )
    manager = PlotManager(
        sim_obs, 
        ui_obs, 
        config_dict, 
        Dict{String, Any}(), 
        triggers, 
        state, 
        locks,               # PASS IT DIRECTLY HERE
        methods_obs, 
        vars, 
        copy(sim_config.shared_params),
        Dict{Int, Dict{String, PlotCache}}()
    )

    # Notice we pass `state` directly here instead of using the old nested keys!
    manager.state["Master_UI_Ref"] = Observable(master_ui)

    switch_ui_plot_type!(manager, init_type)
    
    for (scope, keys_dict) in ui_overwrite
        if haskey(manager.ui, scope)
            for (k, v) in keys_dict
                if haskey(manager.ui[scope], k); manager.ui[scope][k][] = v; end
            end
        end
    end
    return manager
end
"""
    launch_plotter()

Backend-agnostic Single Dashboard entry point. 
Returns the Figure natively so the active backend (GLMakie, WGLMakie) can display it.
"""
function launch_plotter()
    if isnothing(ACTIVE_SIM_CONFIG[])
        ACTIVE_SIM_CONFIG[] = SimulationConfig(
            dummy_simulation_function,"none", nothing, "none", ParamDict(), MethodDict(), String[], VariedDict()
        )
    end

    if PLOTTER_UI_STATE[][:is_open]
        old_manager = ACTIVE_PLOT_MANAGER[]
        new_vars = [collect(keys(ACTIVE_SIM_CONFIG[].varied_params)); BaseVariables]
        
        if old_manager.plot_vars == new_vars
            old_manager.triggers["Simulation_Update"][] += 1
            return PLOTTER_UI_STATE[][:master_fig], old_manager
        else
            @info "Dimensionality changed. Rebuilding UI..."
            PLOTTER_UI_STATE[][:is_open] = false
        end
    end

    ui_overwrite = deepcopy(GLOBAL_UI_OVERWRITE[])
    var_overwrite = deepcopy(GLOBAL_VAR_OVERWRITE[])
    ui_obs = create_master_ui_observables()
    
    manager = create_plot_manager(ACTIVE_SIM_CONFIG[], ui_obs, ui_overwrite, :lines)
    manager.state["base_types"][] = var_overwrite
    ACTIVE_PLOT_MANAGER[] = manager

    # Single Dashboard Layout Definition
    master_fig = Figure()
    #display(master_fig)
    ctrl_layout = master_fig[1, 1] = GridLayout(width = 550)
    plot_layout = master_fig[1, 2] = GridLayout() 
    plot_data_obs = Observable(Dict{String, UnifiedPlotData}())
    
    create_controls(ctrl_layout, manager)
    setup_ui_interactions!(master_fig, plot_layout, manager, plot_data_obs)

    PLOTTER_UI_STATE[][:is_open] = true
    PLOTTER_UI_STATE[][:master_fig] = master_fig

    empty!(ACTIVE_SIM_CONFIG.listeners)

    on(ACTIVE_SIM_CONFIG) do new_config
        (isnothing(new_config) || new_config.simulation_func === dummy_simulation_function) && return
        
        # --- THE FIX: Map real physics names to the static abstract UI sliders ---
        real_params = sort(collect(keys(new_config.varied_params)))
        param_map = Dict{String, String}()
        reverse_map = Dict{String, String}()
        
        for i in 1:3
            p_key = "param_$i"
            if haskey(manager.widgets, "$(p_key)_Label")
                lbl_obs = manager.widgets["$(p_key)_Label"]
                
                if i <= length(real_params)
                    real_name = real_params[i]
                    param_map[p_key] = real_name
                    reverse_map[real_name] = p_key
                    lbl_obs[] = real_name * ":"  
                else
                    param_map[p_key] = "-"
                    lbl_obs[] = "Unused:"
                    if haskey(manager.widgets, p_key)
                        manager.widgets[p_key].range[] = [0.0] 
                    end
                end
            end
        end
        
        manager.state["Param_Map"] = Observable(param_map)
        manager.state["Reverse_Map"] = Observable(reverse_map)
        manager.plot_vars = [real_params; ["c", "x", "y", "z", "t"]]
        
        manager.config["Parameters"] = copy(new_config.varied_params)
        if !haskey(manager.config, "General"); manager.config["General"] = Dict{String, Any}(); end
        manager.config["General"]["simulation_func"] = new_config.simulation_name
        manager.config["General"]["reference_func"]  = isnothing(new_config.reference_name) ? "none" : new_config.reference_name
        
        make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
        empty!(manager.simulation)
        manager.simulation["shared"] = Dict(k => make_obs(v) for (k, v) in new_config.shared_params)
        for (m, p) in new_config.methods_dict
            manager.simulation[m] = Dict(k => make_obs(v) for (k, v) in p)
        end

        if isempty(new_config.default_methods)
            manager.methods[] = filter(k -> k != "shared", collect(keys(new_config.methods_dict)))
        else
            manager.methods[] = filter(k -> k != "shared", copy(new_config.default_methods))
        end
        # 1. LOCK THE PIPELINE
        manager.state["Config_Just_Loaded"][] = true
        
        layout_opts = isempty(GLOBAL_LAYOUT_OPTIONS[]) ? get_base_layout_options() : GLOBAL_LAYOUT_OPTIONS[]
        apply_layout_options!(manager, layout_opts)
        
        
        if !isempty(GLOBAL_UI_OVERWRITE[])
            for (scope, keys_dict) in GLOBAL_UI_OVERWRITE[]
                if haskey(manager.ui, scope)
                    for (k, v) in keys_dict
                        if haskey(manager.ui[scope], k)
                            manager.ui[scope][k].val = v 
                        end
                    end
                end
            end
            GLOBAL_UI_OVERWRITE[] = Dict{String, Any}()
            manager.triggers["UI_Update"][] += 1
        end

        manager.triggers["Layout_Update"][] += 1
    end
    on(manager.triggers["Simulation_Update"]) do _
        curr_config = ACTIVE_SIM_CONFIG[]
        if curr_config.simulation_func === dummy_simulation_function; return; end
        Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[], to_value(manager.state["base_types"]); force_reload = true)
        
        notify(plot_data_obs)
        manager.triggers["Primitive_Rebuild"][] += 1
    end

    setup_plot_window!(master_fig, plot_layout, manager, plot_data_obs)

    

    if ACTIVE_SIM_CONFIG[].simulation_func !== dummy_simulation_function
        manager.triggers["Simulation_Update"][] += 1
    end

    return master_fig, manager 
end
# ==============================================================================
# --- 3. LAYOUT & RENDER HANDLERS ---
# ==============================================================================
function setup_plot_window!(master_fig::Figure, plot_layout::GridLayout, manager::PlotManager, plot_data_obs::Observable)
    if manager.state["plot_window_initialized"][]; return; end
    manager.state["plot_window_initialized"][] = true

    render_observers = ObserverFunction[]

    function rebuild_plot_layout!()
        ptype_sym = manager.widgets["Plot_Type"].selection[]
        for obs in render_observers; off(obs); end
        empty!(render_observers)
        empty!(manager.caches)
        
        for c in copy(plot_layout.content)
            if c.content isa Makie.Block; delete!(c.content); end
        end
        trim!(plot_layout)
        
        switch_ui_plot_type!(manager, ptype_sym)
        
        new_obs = setup_render_lift!(master_fig, plot_layout, plot_data_obs, manager, Val(ptype_sym))
        if !isnothing(new_obs); append!(render_observers, new_obs); end
    end

    on(manager.triggers["Layout_Update"]) do _
        @with_lock manager "Layout" begin
            curr_config = ACTIVE_SIM_CONFIG[]
            if curr_config.simulation_func != "none" && !isnothing(curr_config.simulation_func)
                Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[], to_value(manager.state["base_types"]); force_reload = false)
            end
            rebuild_plot_layout!()
        end
        notify(plot_data_obs)
        manager.triggers["Primitive_Rebuild"][] += 1
    end

    on(manager.triggers["Scene_Update"]) do _
        @with_lock manager "Scene" begin
            curr_config = ACTIVE_SIM_CONFIG[]
            if curr_config.simulation_func != "none" && !isnothing(curr_config.simulation_func)
                Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[], to_value(manager.state["base_types"]); force_reload = false)
            end
        end
        manager.triggers["Primitive_Rebuild"][] += 1
    end

    onany(
        manager.widgets["X-Axis"].selection, manager.widgets["Y-Axis"].selection,
        manager.widgets["Z-Axis"].selection, manager.widgets["U-Axis"].selection, manager.widgets["c"].selection
    ) do _...
        if manager.state["Config_Just_Loaded"][]; return; end
        manager.triggers["Primitive_Rebuild"][] += 1
    end
    
    on(manager.widgets["Layout_Apply"].clicks) do _
        if manager.state["Config_Just_Loaded"][]; return; end
        manager.triggers["Layout_Update"][] += 1
    end

    prev_leg_struct = Ref((false, :none, :none))
    onany(manager.widgets["Legend_Base"].selection, manager.widgets["Legend_Add"].selection) do _...
        if manager.state["Config_Just_Loaded"][]; return; end
        is_comp = manager.widgets["Compare_Target"].selection[] != "None"
        curr = _parse_legend_position(manager, is_comp)
        p = prev_leg_struct[]
        
        if (!curr[1] && !p[1])
            manager.triggers["UI_Update"][] += 1
        else
            prev_leg_struct[] = curr
            manager.triggers["Layout_Update"][] += 1
        end
    end

    rebuild_plot_layout!()
end

function setup_render_lift!(master_fig::Figure, plot_layout::GridLayout, plot_data_obs::Observable, manager::PlotManager, ::Val{T}) where T
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || T == :surface
    w = manager.widgets
    rev_map = haskey(manager.state, "Reverse_Map") ? manager.state["Reverse_Map"][] : Dict{String, String}()
    
    # Read the data dimensions dynamically
    selector_obs = map(manager.plot_vars) do n
        w_key = haskey(rev_map, n) ? rev_map[n] : n
        haskey(w, w_key) ? (w[w_key] isa Slider ? w[w_key].value : w[w_key].selection) : Observable("-")
    end

    x_sel, y_sel = w["X-Axis"].selection, w["Y-Axis"].selection
    z_sel, u_sel = w["Z-Axis"].selection, w["U-Axis"].selection
    
    target = w["Compare_Target"].selection[]
    cols = parse(Int, w["Compare_Columns"].selection[])
    link_mode = w["Compare_Link"].selection[]
    
    num_plots, compare_labels, compare_vals = 1, String[], Any[]
    
    plot_data_dict = plot_data_obs[]
    if !isempty(plot_data_dict)
        pd_first = first(values(plot_data_dict))
        if target == "Methods"
            compare_labels = manager.methods[]
            num_plots = length(compare_labels)
        elseif target == "Component"
            n_params = length(manager.plot_vars) - 5
            target_tensor = haskey(pd_first.data, u_sel[]) ? pd_first.data[u_sel[]] : pd_first.data["u"]
            num_plots = size(target_tensor, n_params + 1) 
            
            comp_names_tuple = manager.ui["Labels"]["comp_names"][]
            compare_labels = String[]
            for i in 1:num_plots
                if comp_names_tuple isa Tuple && length(comp_names_tuple) >= i && comp_names_tuple[i] != "default" && !isempty(string(comp_names_tuple[i]))
                    push!(compare_labels, string(comp_names_tuple[i]))
                else
                    push!(compare_labels, "Component $i")
                end
            end
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
    
    if target == "None" || num_plots == 0; num_plots = 1; target = "None"; end
    
    is_compare = target != "None"
    is_det, halign, valign = _parse_legend_position(manager, is_compare)
    has_legend = T in (:lines, :contourf, :contour, :contour3d) && target != "Methods"
    has_colorbar = T in (:heatmap, :scatter2d, :contourf, :scatter3d, :surface, :volume)

    layout_dict = calculate_layout_dictionary(num_plots, cols, link_mode, has_legend, is_det, halign, valign, has_colorbar)
    manager.state["Layout_Dict"] = Observable(layout_dict)
    
    axes = []
    for i in 1:num_plots
        r, c_idx = layout_dict["Plots"][i]
        ax = is_3d_axis ? Axis3(plot_layout[r, c_idx], perspectiveness=0.5) : Axis(plot_layout[r, c_idx])
        push!(axes, ax)
    end
    
    p_w = parse(Int, w["Plot_Width"].selection[])
    p_h = parse(Int, w["Plot_Height"].selection[])
    for i in 1:plot_layout.size[1]; rowsize!(plot_layout, i, Auto()); end
    for i in 1:plot_layout.size[2]; colsize!(plot_layout, i, Auto()); end
    
    for i in 1:num_plots
        r, c_idx = layout_dict["Plots"][i]
        rowsize!(plot_layout, r, Fixed(p_h))
        colsize!(plot_layout, c_idx, Fixed(p_w))
    end
    
    if !is_3d_axis && link_mode in ("Fully Coupled", "Axes Only")
        linkaxes!(axes...)
    end
    
    target_idx = target == "Component" ? findfirst(isequal("c"), manager.plot_vars) :
                 target == "Time"      ? findfirst(isequal("t"), manager.plot_vars) :
                 findfirst(isequal(target), manager.plot_vars)

    function _mutate_compare_vals(current_sels, idx)
        mutated = collect(current_sels)
        if !isnothing(target_idx) && !isempty(compare_vals) && idx <= length(compare_vals)
            mutated[target_idx] = compare_vals[idx]
        end
        return mutated
    end

    # =========================================================================
    # TIER 2: PRIMITIVE REBUILD
    # =========================================================================
    prim_obs = on(manager.triggers["Primitive_Rebuild"]) do _
        @with_lock manager "Primitive" begin
            (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == "-" || u_sel[] == "-") && return
            if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == "-" || y_sel[] == "disabled") && return; end
            if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == "-" || z_sel[] == "disabled") && return; end
            
            data = plot_data_obs[]
            isempty(data) && return
            empty!(manager.caches)
            
            for ax in axes
                empty!(ax)
                if !is_3d_axis; ax.xscale[] = identity; ax.yscale[] = identity; end
            end
            
            sel_vals = [to_value(obs) for obs in selector_obs]

            for i in 1:num_plots
                manager.caches[i] = Dict{String, PlotCache}()
                
                mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
                dt, vl, ts = extract_data(data, manager, mutated_sel_vals, x_sel[], y_sel[], z_sel[], u_sel[], Val(PLOT_DIM_MAP[T]))
                
                local_methods = manager.methods[]
                if target == "Methods" && i <= length(vl)
                    vl = [vl[i]]
                    dt = Tuple([slice[i]] for slice in dt)
                    local_methods = [manager.methods[][i]]
                end
                
                initialize_base_plot!(plot_layout, axes[i], vl, dt, manager, x_sel[], y_sel[], z_sel[], u_sel[], ts, Val(T), i)
                default_title = is_compare ? compare_labels[i] : ts
                axes[i].title[] = manager.ui["Labels"]["title"][] == "default" ? default_title : manager.ui["Labels"]["title"][]
                if !is_3d_axis; 
                    plot_HUD!(axes[i], manager)
                    set_axis_limits_manager!(axes[i], dt[1], dt[2], manager)
                end
            end
        end
        manager.triggers["UI_Update"][] += 1
    end

    # =========================================================================
    # TIER 3: DATA SYNC
    # =========================================================================
    data_sync_obs = onany(plot_data_obs, selector_obs...) do data, sel_vals...
        @with_lock manager "Data" begin
            (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == "-" || u_sel[] == "-") && return
            if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == "-" || y_sel[] == "disabled") && return; end
            if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == "-" || z_sel[] == "disabled") && return; end
            
            caches = manager.caches
            (isempty(data) || isempty(caches)) && return
            
            for i in 1:num_plots
                mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
                dt, vl, ts = extract_data(data, manager, mutated_sel_vals, x_sel[], y_sel[], z_sel[], u_sel[], Val(PLOT_DIM_MAP[T]))
                
                local_methods = manager.methods[]
                if target == "Methods" && i <= length(vl)
                    vl = [vl[i]]
                    dt = Tuple([slice[i]] for slice in dt)
                    local_methods = [manager.methods[][i]]
                end
                
                if !is_3d_axis
                    safe_min(arrs) = isempty(arrs) ? 1.0 : minimum(v -> isempty(v) ? 1.0 : minimum(v), arrs)
                    if axes[i].xscale[] == log10 && safe_min(dt[1]) <= 0
                        @warn "Negative X data encountered. Disabling log_scale to prevent crash."
                        axes[i].xscale[] = identity
                    end
                    if axes[i].yscale[] == log10 && safe_min(dt[2]) <= 0
                        @warn "Negative Y/U data encountered. Disabling log_scale to prevent crash."
                        axes[i].yscale[] = identity
                    end
                end
                
                sync_data_to_cache!(caches[i], local_methods, dt, Val(PLOT_DIM_MAP[T]))
                
                default_title = is_compare ? compare_labels[i] : ts
                axes[i].title[] = manager.ui["Labels"]["title"][] == "default" ? default_title : manager.ui["Labels"]["title"][]
                
                if !is_3d_axis
                    set_axis_limits_manager!(axes[i], dt[1], dt[2], manager)
                end
            end
            for ax in axes; apply_axis_limits_overrides!(ax, manager); end
        end
    end

    # =========================================================================
    # TIER 4: UI & STYLE MUTATION 
    # =========================================================================
    ui_obs = on(manager.triggers["UI_Update"]) do _
        @with_lock manager "UI" begin
            ui_gen = manager.ui["Axis-General"]
            ui_app = manager.ui["Plot-Style"]
            
            x_str, y_str = w["X-Axis"].selection[], w["Y-Axis"].selection[]
            z_str, u_str = w["Z-Axis"].selection[], w["U-Axis"].selection[]
            
            for (i, ax) in enumerate(axes)
                if is_3d_axis
                    z_str = z_str == "disabled" ? u_str : z_str
                    set_axis_styles!(ax, manager, string(x_str), string(y_str), string(z_str), ax.title[])
                elseif PLOT_DIM_MAP[T] == 1
                    set_axis_styles!(ax, manager, string(x_str), string(u_str), ax.title[])
                else
                    set_axis_styles!(ax, manager, string(x_str), string(y_str), ax.title[])
                end
                apply_axis_limits_overrides!(ax, manager)
                
                if haskey(manager.caches, i)
                    for (m_idx, method_name) in enumerate(manager.methods[])
                        if haskey(manager.caches[i], method_name)
                            prims = manager.caches[i][method_name].primitives
                            colors = get(ui_app,"colors",nothing)
                            color = isnothing(colors) ? nothing : colors[][mod1(m_idx, end)]
                            
                            if haskey(prims, "line")
                                prims["line_color"][]   = color
                                prims["line_width"][]   = ui_app["line_width"][]
                                prims["line_visible"][] = ui_app["show_lines"][]
                            end
                            if haskey(prims, "scatter")
                                prims["scat_color"][]   = color
                                prims["scat_size"][]    = ui_app["marker_size"][]
                                prims["scat_visible"][] = ui_app["show_scatter"][]
                            end
                            if haskey(prims, "contour")
                                prims["contour"].color[] = color
                                prims["contour"].linewidth[] = ui_app["line_width"][]
                            end
                            if haskey(prims, "volume");    prims["volume"].colormap[]    = ui_app["color_map"][]; end
                            if haskey(prims, "heatmap");   prims["heatmap"].colormap[]   = ui_app["color_map"][]; end
                            if haskey(prims, "surface");   prims["surface"].colormap[]   = ui_app["color_map"][]; end
                            if haskey(prims, "contourf");  prims["contourf"].colormap[]  = ui_app["color_map"][]; end
                            
                            if haskey(prims, "scatter2d")
                                prims["scatter2d"].colormap[] = ui_app["color_map"][]
                                prims["scatter2d"].markersize[] = ui_app["marker_size"][]
                            end
                            if haskey(prims, "scatter3d")
                                prims["scatter3d"].colormap[] = ui_app["color_map"][]
                                prims["scatter3d"].markersize[] = ui_app["marker_size"][]
                            end
                        end
                    end
                    if has_colorbar
                        plot_obj = nothing
                        
                        # Find the first valid rendered primitive to attach the colorbar to
                        for method_name in manager.methods[]
                            if haskey(manager.caches[i], method_name)
                                prims = manager.caches[i][method_name].primitives
                                for pkey in ["heatmap", "contourf", "surface", "volume", "scatter2d", "scatter3d"]
                                    if haskey(prims, pkey)
                                        plot_obj = prims[pkey]
                                        break
                                    end
                                end
                            end
                            !isnothing(plot_obj) && break
                        end
                        
                        if !isnothing(plot_obj)
                            create_or_update_colorbar!(plot_layout, plot_obj, manager, Observable((0.0, 1.0)), string(u_str), i)
                        end
                    end
                end
            end
            
            if !is_3d_axis && T in (:lines, :contour, :contourf) && haskey(manager.caches, 1)
                plotted_objects = []
                labels_for_legend = String[]
                
                for (m_idx, method_name) in enumerate(manager.methods[])
                    if haskey(manager.caches[1], method_name)
                        prims = manager.caches[1][method_name].primitives
                        color = ui_app["colors"][][mod1(m_idx, end)]
                        
                        if haskey(prims, "contourf")
                            push!(plotted_objects, [Makie.PolyElement(color=Makie.to_colormap(ui_app["color_map"][])[end])])
                            push!(labels_for_legend, "$(method_name) (Base)")
                        end
                        
                        group = []
                        if haskey(prims, "line") && ui_app["show_lines"][]
                            ls = ui_app["dashed_lines"][] ? ui_app["line_styles"][][mod1(m_idx, end)] : nothing
                            push!(group, Makie.LineElement(color=color, linewidth=ui_app["line_width"][], linestyle=ls))
                        end
                        if haskey(prims, "scatter") && ui_app["show_scatter"][]
                            mrk = ui_app["markers"][][mod1(m_idx, end)]
                            push!(group, Makie.MarkerElement(color=color, marker=mrk, markersize=ui_app["marker_size"][]))
                        end
                        if haskey(prims, "contour")
                            push!(group, Makie.LineElement(color=color, linewidth=ui_app["line_width"][]))
                        end
                        
                        if !isempty(group)
                            push!(plotted_objects, group)
                            if !haskey(prims, "contourf"); push!(labels_for_legend, method_name); end
                        end
                    end
                end
                create_or_update_legend!(plot_layout, plotted_objects, labels_for_legend, manager)
            end
            resize_to_layout!(master_fig)
        end
    end
    return ObserverFunction[prim_obs; data_sync_obs; ui_obs]
end