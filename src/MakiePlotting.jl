# ==============================================================================
# --- GLOBAL UI STATE REFERENCES ---
# ==============================================================================
const GLOBAL_UI_OVERWRITE = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_SCENE_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_LAYOUT_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())
const GLOBAL_CAMERA_OPTIONS = Ref{Dict{String, Any}}(Dict{String, Any}())

function extract_and_store_camera_state!(plot_layout::GridLayout)
    cam_opts = Dict{String, Any}()
    axes = [c.content for c in plot_layout.content if c.content isa Axis || c.content isa Axis3]
    for (i, ax) in enumerate(axes)
        if ax isa Axis
            lims = ax.finallimits[]
            cam_opts["Axis_$(i)_Limits"] = Float64[lims.origin[1], lims.origin[1] + lims.widths[1], lims.origin[2], lims.origin[2] + lims.widths[2]]
        elseif ax isa Axis3
            lims = ax.finallimits[]
            cam_opts["Axis_$(i)_Limits3D"]  = Float64[
                lims.origin[1], lims.origin[1] + lims.widths[1], 
                lims.origin[2], lims.origin[2] + lims.widths[2], 
                lims.origin[3], lims.origin[3] + lims.widths[3]
            ]
            cam_opts["Axis_$(i)_Azimuth"]   = Float64(ax.azimuth[])
            cam_opts["Axis_$(i)_Elevation"] = Float64(ax.elevation[])
        end
    end
    GLOBAL_CAMERA_OPTIONS[] = cam_opts
end

# Singleton Global Observables & State
const ACTIVE_SIM_CONFIG = Observable{Any}(nothing)
const ACTIVE_PLOT_MANAGER = Ref{Union{Nothing, PlotManager}}(nothing)
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
    vars = isempty(varied_dict) ? Symbol[] : Symbol.(sort(collect(keys(varied_dict))))
    append!(vars, get_base_variables())

    sim_obs = NestedObsDict()
    make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
    sim_obs["shared"] = Dict(k => make_obs(v) for (k, v) in sim_config.shared_params)
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => make_obs(v) for (k, v) in m_params)
    end

    ui_obs = NestedObsDict()
    methods_obs = Observable(copy(sim_config.default_methods))

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
        "Scene"     => false, 
        "Primitive" => false,
        "Data"      => false,
        "Sliders"    => false,
        "UI"        => false   
    )
    state = Dict{String, Any}(
        "Config_Just_Loaded"      => Observable(false),
        "plot_window_initialized" => Observable(false),
        "Active_Axes"             => Observable{Vector{Int}}(Int[]),
        "Is_Activate_Mode"        => Observable(true),
        "Is_Animating"            => Observable(false),
        "Animation_Timer"         => Observable{Any}(nothing),
        "Active_Target_Obs"       => Observable{Any}(nothing),
        "Master_UI_Ref"           => Observable(master_ui),
        "Layout_Dict"             => Observable(Dict{String, Any}())
    )
    
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
        locks, 
        methods_obs, 
        vars, 
        copy(sim_config.shared_params),
        Dict{Int, Dict{String, AbstractPlotCache}}()
    )

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
Initializes either the dense Eulerian or unstructured Lagrangian pipeline.
"""
function launch_plotter()
        
    if isnothing(ACTIVE_SIM_CONFIG[])
        ACTIVE_SIM_CONFIG[] = SimulationConfig(
            dummy_simulation_function,"none", nothing, "none", ParamDict(), MethodDict(), String[], VariedDict()
        )
    end

    if PLOTTER_UI_STATE[][:is_open]
        old_manager = ACTIVE_PLOT_MANAGER[]
        
        new_vars = [Symbol.(collect(keys(ACTIVE_SIM_CONFIG[].varied_params))); get_base_variables()]
        
        if old_manager.plot_vars == new_vars
            old_manager.triggers["Simulation_Update"][] += 1
            return PLOTTER_UI_STATE[][:master_fig], old_manager
        else
            @info "Configuration changed. Rebuilding UI..."
            PLOTTER_UI_STATE[][:is_open] = false
        end
    end

    ui_overwrite = deepcopy(GLOBAL_UI_OVERWRITE[])
    ui_obs = create_master_ui_observables()
    
    init_type = PLOT_MODE[] == :eulerian ? :lines : :scatter1d
    manager = create_plot_manager(ACTIVE_SIM_CONFIG[], ui_obs, ui_overwrite, init_type)
    
    ACTIVE_PLOT_MANAGER[] = manager

    master_fig = Figure()
    ctrl_layout = master_fig[1, 1] = GridLayout(width = 550)
    plot_layout = master_fig[1, 2] = GridLayout() 
    plot_data_obs = Observable(Dict{String, AbstractPlotData}())
    
    create_controls(ctrl_layout, manager)
    setup_common_interactions!(master_fig, plot_layout, manager, plot_data_obs)
    
    if PLOT_MODE[] == :eulerian
        setup_eulerian_interactions!(manager, plot_data_obs)
    else
        setup_lagrangian_interactions!(manager, plot_data_obs)
    end

    PLOTTER_UI_STATE[][:is_open] = true
    PLOTTER_UI_STATE[][:master_fig] = master_fig

    empty!(ACTIVE_SIM_CONFIG.listeners)

    on(ACTIVE_SIM_CONFIG) do new_config
        (isnothing(new_config) || new_config.simulation_func === dummy_simulation_function) && return
        
        real_params = Symbol.(sort(collect(keys(new_config.varied_params))))
        
        param_map = Dict{String, Symbol}()
        reverse_map = Dict{Symbol, String}()
        
        i = 1
        while haskey(manager.widgets, "param_$(i)_Label")
            p_key = "param_$i"
            lbl_obs = manager.widgets["$(p_key)_Label"]
            
            if i <= length(real_params)
                real_sym = real_params[i]
                param_map[p_key] = real_sym
                reverse_map[real_sym] = p_key
                lbl_obs[] = string(real_sym) * ":"  
            else
                lbl_obs[] = "Unused:"
                if haskey(manager.widgets, p_key)
                    manager.widgets[p_key].range[] = [0.0] 
                end
            end
            i += 1
        end
        
        manager.state["Param_Map"] = Observable(param_map)
        manager.state["Reverse_Map"] = Observable(reverse_map)
        
        manager.plot_vars = [real_params; get_base_variables()]
        
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
        Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[]; force_reload = true)
        
        notify(plot_data_obs)
        manager.triggers["Layout_Update"][] += 1
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

    # Quick helper to extract a valid simulation for dimension checking
    _get_first_valid(pd) = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))

    function rebuild_plot_layout!()
        if get(manager.state, "Camera_Locked", Observable(false))[] && !manager.state["Config_Just_Loaded"][]
            extract_and_store_camera_state!(plot_layout)
        end

        base_sel  = manager.widgets["Base_Plot"].selection[]
        style_sel = manager.widgets["Plot_Style"].selection[]
        ptype_sym = PLOT_ROUTING_MATRIX[(base_sel, style_sel)]

        if PLOT_MODE[] == :lagrangian && !isempty(plot_data_obs[])
            pd = first(values(plot_data_obs[]))
            sim_data = _get_first_valid(pd)
            if !isnothing(sim_data)
                # D represents the number of spatial dimensions in DomainInfo
                D = length(sim_data.domain.dim_keys) - (isnothing(sim_data.domain.time_dim) ? 0 : 1)
                
                if style_sel == "Lines" && D == 1
                    ptype_sym = :scatterlines
                elseif style_sel == "Colors" && D == 1
                    ptype_sym = :scattercolors
                elseif style_sel == "2D (Surface)" && D == 2
                    ptype_sym = :scatter2d_surface
                else
                    ptype_sym = D == 1 ? :scatter1d : (D == 2 ? :scatter2d : :scatter3d)
                end
            end
        end

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
                Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[]; force_reload = false)
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
                Base.invokelatest(update_plot_data_collection!, plot_data_obs[], curr_config, manager, manager.methods[]; force_reload = false)
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
    
    onany(manager.widgets["Base_Plot"].selection,manager.widgets["Plot_Style"].selection) do _,_
        manager.locks["Layout"] = true
    end

    on(manager.widgets["Layout_Apply"].clicks) do _
        if manager.state["Config_Just_Loaded"][]; return; end
        manager.locks["Layout"] = false
        manager.triggers["Layout_Update"][] += 1
    end

    prev_leg_struct = Ref((false, :none, :none))
    onany(manager.widgets["Legend_Base"].selection, manager.widgets["Legend_Add"].selection) do _...
        if manager.state["Config_Just_Loaded"][]; return; end
        is_comp = manager.widgets["Compare_Target"].selection[] != :None
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
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || T == :surface || T == :scatter2d_surface
    w = manager.widgets
    rev_map = haskey(manager.state, "Reverse_Map") ? manager.state["Reverse_Map"][] : Dict{Symbol, String}()
    CT = PLOT_MODE[] == :eulerian ? EulerianPlotCache : LagrangianPlotCache
    
    # Read the data dimensions dynamically
    selector_obs = map(manager.plot_vars) do n
        w_key = haskey(rev_map, n) ? rev_map[n] : string(n)
        w[w_key].value
    end

    x_sel, y_sel = w["X-Axis"].selection, w["Y-Axis"].selection
    z_sel, u_sel = w["Z-Axis"].selection, w["U-Axis"].selection
    c_sel = w["c"].selection
    
    target = w["Compare_Target"].selection[]
    cols = w["Compare_Columns"].selection[]
    link_mode = w["Compare_Link"].selection[]
    
    num_plots, compare_labels, compare_vals = 1, String[], Any[]
    
    _get_first_valid(pd) = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))

    plot_data_dict = plot_data_obs[]
    sim_data = nothing
    if !isempty(plot_data_dict)
        pd_first = first(values(plot_data_dict))
        sim_data = _get_first_valid(pd_first)
        
        if !isnothing(sim_data)
            if target == :Methods
                compare_labels = manager.methods[]
                num_plots = length(compare_labels)
            elseif target == :Component
                target_tensor = get(sim_data.stats, u_sel[], sim_data.stats[:Solution])
                target_tensor_arr = target_tensor isa AbstractArray && ndims(target_tensor) == 1 ? target_tensor : target_tensor[1]
                num_plots = length(target_tensor_arr[1]) 
                
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
            elseif target == :Time
                t_dim = get_time_dim(sim_data.domain)
                t_vals = PLOT_MODE[] == :lagrangian ? sim_data.t : (isnothing(t_dim) ? [0.0] : sim_data.axes[t_dim])
                
                num_plots = length(t_vals)
                compare_labels = ["t = $(round(t, sigdigits=4))" for t in t_vals]
                compare_vals = t_vals
            elseif target in manager.plot_vars
                idx = findfirst(isequal(target), manager.plot_vars)
                vals = pd_first.active_param_values[idx]
                num_plots = length(vals)
                compare_labels = ["$(string(target)) = $(round(v, sigdigits=4))" for v in vals]
                compare_vals = vals
            end
        end
    end
    
    if target == :None || num_plots == 0; num_plots = 1; target = :None; end
    
    is_compare = target != :None
    is_det, halign, valign = _parse_legend_position(manager, is_compare)
    
    has_legend = T in LEGEND_SUPPORTED_PLOTS && target != :Methods
    has_colorbar = T in COLORBAR_SUPPORTED_PLOTS

    layout_dict = calculate_layout_dictionary(num_plots, cols, link_mode, has_legend, is_det, halign, valign, has_colorbar)
    manager.state["Layout_Dict"] = Observable(layout_dict)
    
    axes = []
    for i in 1:num_plots
        r, c_idx = layout_dict["Plots"][i]
        ax = is_3d_axis ? Axis3(plot_layout[r, c_idx], perspectiveness=0.5) : Axis(plot_layout[r, c_idx])
        push!(axes, ax)
    end
    
    p_w = w["Plot_Width"].selection[]
    p_h = w["Plot_Height"].selection[]
    for i in 1:plot_layout.size[1]; rowsize!(plot_layout, i, Auto()); end
    for i in 1:plot_layout.size[2]; colsize!(plot_layout, i, Auto()); end
    
    for i in 1:num_plots
        r, c_idx = layout_dict["Plots"][i]
        rowsize!(plot_layout, r, Fixed(p_h))
        colsize!(plot_layout, c_idx, Fixed(p_w))
    end
    
    if !is_3d_axis && link_mode in (:fully_coupled, :axes_only)
        linkaxes!(axes...)
    end
    
    target_idx = target == :Time ? (isnothing(sim_data) ? nothing : findfirst(isequal(sim_data.domain.time_dim), manager.plot_vars)) : 
                 findfirst(isequal(target), manager.plot_vars)

    function _mutate_compare_vals(current_sels, idx)
        mutated = collect(current_sels)
        if !isnothing(target_idx) && !isempty(compare_vals) && idx <= length(compare_vals)
            mutated[target_idx] = compare_vals[idx]
        end
        return mutated
    end

    function _build_param_indices(pd, mutated_vals)
        n_params = length(pd.active_param_keys)
        return ntuple(d -> begin
            val = mutated_vals[d]
            vals = pd.active_param_values[d]
            isempty(vals) ? 1 : findmin(v -> abs(v - val), vals)[2]
        end, n_params)
    end

    # =========================================================================
    # TIER 2: PRIMITIVE REBUILD
    # =========================================================================
    prim_obs = on(manager.triggers["Primitive_Rebuild"]) do _
        @with_lock manager "Primitive" begin
            (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == :None || u_sel[] == :None) && return
            if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == :None) && return; end
            if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == :None) && return; end
            
            data = plot_data_obs[]
            isempty(data) && return
            empty!(manager.caches)
            
            for ax in axes
                empty!(ax)
                if !is_3d_axis; ax.xscale[] = identity; ax.yscale[] = identity; end
            end
            
            if !isempty(manager.methods[])
                sel_vals = [to_value(obs) for obs in selector_obs]

                for i in 1:num_plots
                    manager.caches[i] = Dict{String, CT}()
                    
                    mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
                    target_c_int = (is_compare && target == :Component) ? i : c_sel[]

                    local_methods = is_compare && target == :Methods ? [manager.methods[][i]] : manager.methods[]
                    valid_methods = String[]
                    local data_tuples
                    
                    # 1. Pipeline Routing
                    if PLOT_MODE[] == :lagrangian
                        local DS = 1
                        for m_name in local_methods
                            if haskey(data, m_name)
                                sim = _get_first_valid(data[m_name])
                                if !isnothing(sim); DS = length(sim.domain.mins) - (isnothing(sim.domain.time_dim) ? 0 : 1); break; end
                            end
                        end
                        
                        ax_cols = [Any[] for _ in 1:DS]
                        u_col = Any[]
                        
                        for m_name in local_methods
                            !haskey(data, m_name) && continue
                            pd = data[m_name]
                            p_idx = _build_param_indices(pd, mutated_sel_vals)
                            
                            res = extract_lagrangian_data(pd, p_idx, mutated_sel_vals, manager.plot_vars, u_sel[], target_c_int)
                            if !isnothing(res)
                                p_axes, u_flat = res
                                for d in 1:DS
                                    push!(ax_cols[d], p_axes[d])
                                end
                                push!(u_col, u_flat)
                                push!(valid_methods, m_name)
                            end
                        end
                        data_tuples = Tuple([ax_cols..., u_col])
                    else
                        active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
                        ax_cols = [Any[] for _ in 1:length(active_plot_axes_syms)]
                        u_col = Any[]
                        
                        active_plot_axes_strs = string.(active_plot_axes_syms) # Cast to String array purely for DataHandler

                        for m_name in local_methods
                            !haskey(data, m_name) && continue
                            pd = data[m_name]
                            p_idx = _build_param_indices(pd, mutated_sel_vals)
                            
                            res = extract_eulerian_data(pd, p_idx, mutated_sel_vals, manager.plot_vars, active_plot_axes_strs, string(u_sel[]), target_c_int)
                            if !isnothing(res)
                                p_axes, u_flat = res
                                for d in 1:length(active_plot_axes_syms)
                                    push!(ax_cols[d], p_axes[d])
                                end
                                push!(u_col, u_flat)
                                push!(valid_methods, m_name)
                            end
                        end
                        data_tuples = Tuple([ax_cols..., u_col])
                    end
                    
                    isempty(valid_methods) && continue
                    
                    active_title_indices = if PLOT_MODE[] == :eulerian
                        active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
                        [findfirst(isequal(occursin("|", string(ax)) ? Symbol(split(string(ax), "|")[2]) : ax), manager.plot_vars) for ax in active_plot_axes_syms]
                    else
                        spatial_axes = filter(k -> k != sim_data.domain.time_dim, sim_data.domain.dim_keys)
                        filter(!isnothing, [findfirst(isequal(ax), manager.plot_vars) for ax in spatial_axes])
                    end
                    
                    ts = generate_dynamic_title(Tuple(active_title_indices), manager.plot_vars, mutated_sel_vals)
                    default_title = is_compare ? compare_labels[i] : ts
                    
                    # Convert primary selected axes to Strings cleanly before initializing plot limits
                    x_str = x_sel[] == :None ? "disabled" : string(x_sel[])
                    y_str = y_sel[] == :None ? "disabled" : string(y_sel[])
                    z_str = z_sel[] == :None ? "disabled" : string(z_sel[])
                    u_str = string(u_sel[])

                    initialize_base_plot!(plot_layout, axes[i], valid_methods, data_tuples, manager, x_str, y_str, z_str, u_str, ts, Val(T), i)
                    axes[i].title[] = manager.ui["Labels"]["title"][] == "default" ? default_title : manager.ui["Labels"]["title"][]
                    
                    # 2. Safe Limit Synchronization (Unified for Eulerian & Lagrangian)
                    if !is_3d_axis
                        x_lims, y_lims = data_tuples[1], data_tuples[2]
                        
                        safe_min(arrs) = isempty(arrs) ? 1.0 : minimum(v -> isempty(v) ? 1.0 : minimum(v), arrs)
                        if axes[i].xscale[] == log10 && safe_min(x_lims) <= 0
                            axes[i].xscale[] = identity
                        end
                        if axes[i].yscale[] == log10 && safe_min(y_lims) <= 0
                            axes[i].yscale[] = identity
                        end
                        
                        set_axis_limits_manager!(axes[i], x_lims, y_lims, manager)
                    end
                    _enforce_camera_lock!(axes, manager)
                end
            end
        end
        manager.triggers["UI_Update"][] += 1
    end

    # =========================================================================
    # TIER 3: DATA SYNC
    # =========================================================================
    data_sync_obs = onany(c_sel,selector_obs...) do c,sel_vals...
        @with_lock manager "Data" begin
            (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == :None || u_sel[] == :None) && return
            if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == :None) && return; end
            if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == :None) && return; end
            
            caches = manager.caches
            data = plot_data_obs[]

            (isempty(data) || isempty(caches) || isempty(manager.methods[])) && return
            
            for i in 1:num_plots
                mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
                target_c_int = (is_compare && target == :Component) ? i : c_sel[]

                local_methods = is_compare && target == :Methods ? [manager.methods[][i]] : manager.methods[]
                valid_methods = String[]
                local data_tuples
                
                # 1. Pipeline Routing
                if PLOT_MODE[] == :lagrangian
                    local DS = 1
                    for m_name in local_methods
                        if haskey(data, m_name)
                            sim = _get_first_valid(data[m_name])
                            if !isnothing(sim); DS = length(sim.domain.mins) - (isnothing(sim.domain.time_dim) ? 0 : 1); break; end
                        end
                    end
                    
                    ax_cols = [Any[] for _ in 1:DS]
                    u_col = Any[]
                    
                    for m_name in local_methods
                        !haskey(data, m_name) && continue
                        pd = data[m_name]
                        p_idx = _build_param_indices(pd, mutated_sel_vals)
                        
                        res = extract_lagrangian_data(pd, p_idx, mutated_sel_vals, manager.plot_vars, u_sel[], target_c_int)
                        if !isnothing(res)
                            p_axes, u_flat = res
                            for d in 1:DS
                                push!(ax_cols[d], p_axes[d])
                            end
                            push!(u_col, u_flat)
                            push!(valid_methods, m_name)
                        end
                    end
                    data_tuples = Tuple([ax_cols..., u_col])
                else
                    active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
                    ax_cols = [Any[] for _ in 1:length(active_plot_axes_syms)]
                    u_col = Any[]
                    
                    active_plot_axes_strs = string.(active_plot_axes_syms)

                    for m_name in local_methods
                        !haskey(data, m_name) && continue
                        pd = data[m_name]
                        p_idx = _build_param_indices(pd, mutated_sel_vals)
                        
                        res = extract_eulerian_data(pd, p_idx, mutated_sel_vals, manager.plot_vars, active_plot_axes_strs, string(u_sel[]), target_c_int)
                        if !isnothing(res)
                            p_axes, u_flat = res
                            for d in 1:length(active_plot_axes_syms)
                                push!(ax_cols[d], p_axes[d])
                            end
                            push!(u_col, u_flat)
                            push!(valid_methods, m_name)
                        end
                    end
                    data_tuples = Tuple([ax_cols..., u_col])
                end
                
                isempty(valid_methods) && continue
                
                if !is_3d_axis
                    x_lims, y_lims = data_tuples[1], data_tuples[2]
                    
                    safe_min(arrs) = isempty(arrs) ? 1.0 : minimum(v -> isempty(v) ? 1.0 : minimum(v), arrs)
                    if axes[i].xscale[] == log10 && safe_min(x_lims) <= 0
                        axes[i].xscale[] = identity
                    end
                    if axes[i].yscale[] == log10 && safe_min(y_lims) <= 0
                        axes[i].yscale[] = identity
                    end
                    
                    set_axis_limits_manager!(axes[i], x_lims, y_lims, manager)
                end
                
                sync_data_to_cache!(caches[i], valid_methods, data_tuples, manager, Val(PLOT_DIM_MAP[T]))
                
                active_title_indices = if PLOT_MODE[] == :eulerian
                    active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
                    [findfirst(isequal(occursin("|", string(ax)) ? Symbol(split(string(ax), "|")[2]) : ax), manager.plot_vars) for ax in active_plot_axes_syms]
                else
                    spatial_axes = filter(k -> k != sim_data.domain.time_dim, sim_data.domain.dim_keys)
                    filter(!isnothing, [findfirst(isequal(ax), manager.plot_vars) for ax in spatial_axes])
                end
                
                ts = generate_dynamic_title(Tuple(active_title_indices), manager.plot_vars, mutated_sel_vals)
                default_title = is_compare ? compare_labels[i] : ts
                axes[i].title[] = manager.ui["Labels"]["title"][] == "default" ? default_title : manager.ui["Labels"]["title"][]
            end
            for ax in axes; apply_axis_limits_overrides!(ax, manager); end
        end
    end

    # =========================================================================
    # TIER 4: UI & STYLE MUTATION 
    # =========================================================================
    ui_obs = on(manager.triggers["UI_Update"]) do _
        @with_lock manager "UI" begin
            ui_app = manager.ui["Plot-Style"]
            
            for (i, ax) in enumerate(axes)
                _apply_axis_styles!(ax, manager, T)
                apply_axis_limits_overrides!(ax, manager)
                
                if !is_3d_axis && haskey(ui_app, "reference")
                    delete_plots_by_label!(ax, "Reference Lines")
                    ref_exp = ui_app["reference"][]
                    !isempty(ref_exp) && plot_reference_lines!(ax, ref_exp; label="Reference Lines")
                end
                
                if haskey(manager.caches, i)
                    for (method_name, cache) in manager.caches[i]
                        m_idx = findfirst(isequal(method_name), manager.methods[])
                        isnothing(m_idx) && continue 
                        
                        colors = get(ui_app, "colors", nothing)
                        c = !isnothing(colors) ? colors[][mod1(m_idx, length(colors[]))] : :black
                        
                        for (key, prim) in cache.primitives
                            apply_ui_style!(key, prim, ui_app, c)
                        end
                    end
                    
                    if has_colorbar
                        plot_obj = _find_first_drawable_primitive(manager.caches[i])
                        if !isnothing(plot_obj)
                            cr_obs = haskey(plot_obj.attributes, :colorrange) ? plot_obj.colorrange : Observable((0.0, 1.0))
                            create_or_update_colorbar!(plot_layout, plot_obj, manager, cr_obs, string(w["U-Axis"].selection[]), i)
                        end
                    end
                end
            end
            
            if !is_3d_axis && T in LEGEND_SUPPORTED_PLOTS
                create_or_update_legend!(plot_layout, _collect_legend_elements(manager, ui_app)..., manager)
            end
            
            resize_to_layout!(master_fig)
            _enforce_camera_lock!(axes, manager)
        end
    end
    return ObserverFunction[prim_obs; data_sync_obs; ui_obs]
end