# ==============================================================================
# --- GLOBAL UI STATE REFERENCES ---
# ==============================================================================

const LEGEND_REF = Ref{Symbol}(:none)
const PLOTTER_UI_STATE = Ref{Dict{Symbol, Any}}(Dict(:is_open => false, :master_fig => nothing))

function extract_and_store_camera_state!(plot_layout::GridLayout)
    manager = GLOBAL_PLOT_MANAGER
    cam_opts = Dict{Symbol, Any}()
    axes = [c.content for c in plot_layout.content if c.content isa Axis || c.content isa Axis3]
    for (i, ax) in enumerate(axes)
        if ax isa Axis
            lims = ax.finallimits[]
            cam_opts[Symbol("Axis_$(i)_Limits")] = Float64[lims.origin[1], lims.origin[1] + lims.widths[1], lims.origin[2], lims.origin[2] + lims.widths[2]]
        elseif ax isa Axis3
            lims = ax.finallimits[]
            cam_opts[Symbol("Axis_$(i)_Limits3D")]  = Float64[
                lims.origin[1], lims.origin[1] + lims.widths[1], 
                lims.origin[2], lims.origin[2] + lims.widths[2], 
                lims.origin[3], lims.origin[3] + lims.widths[3]
            ]
            cam_opts[Symbol("Axis_$(i)_Azimuth")]   = Float64(ax.azimuth[])
            cam_opts[Symbol("Axis_$(i)_Elevation")] = Float64(ax.elevation[])
        end
    end
    manager.staged[:Camera] = cam_opts
end

# Your setter now cleanly mutates the encapsulated observable and buffers the methods
function set_sim_config!(config::SimulationConfig)
    manager = GLOBAL_PLOT_MANAGER
    manager.active_config = config

    manager.staged[:Flag_Sim][] = true # Stage flag for Run Sim button
    
    if !haskey(manager.staged, :Staged_Methods)
        manager.staged[:Staged_Methods] = Observable(String[])
    end
    
    default_m = isempty(config.default_methods) ? filter(k -> k != "shared", collect(keys(config.methods_dict))) : filter(k -> k != "shared", copy(config.default_methods))
    manager.staged[:Staged_Methods][] = default_m

    if haskey(manager.widgets, :Editor_Cat)
        notify(manager.widgets[:Editor_Cat].selection)
    end
end

"""
    set_sim_config!(csv_name::String)

Searches for a CSV by name in the figures, animations, and Experiments folders.
If found, it parses it, reconstructs the `SimulationConfig`, runs the simulations,
and dynamically updates the active Plotter UI.
"""
function set_sim_config!(csv_name::String)
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
    
    load_and_apply_csv!(filepath)
end

"""
    reset_plotter!()

Completely wipes the UI state, purges observables, and destroys the active window. 
Guarantees a 100% clean slate for the next @plot call.
"""
function reset_plotter!()
    manager = GLOBAL_PLOT_MANAGER
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
    manager.staged[:Layout] = get_base_layout_options()
    
    # 1. Purge all global trigger listeners to kill zombie closures
    for (k, obs) in manager.triggers
        if k != :Simulation
            empty!(obs.listeners)
        end
    end

    # Explicitly turn off UI-bound listeners safely
    for (k, listener_node) in manager.listeners
        if k != :Simulation
            if listener_node isa Vector
                for l in listener_node; off(l); end
            else
                off(listener_node)
            end
        end
    end
    
    # 2. Reset initialization flag so the next launch attaches NEW listeners
    if haskey(manager.staged, :plot_window_initialized)
        manager.staged[:plot_window_initialized][] = false
    end
    
    # 3. Clear active config data cleanly
    manager.active_config = DUMMY_CONFIG
    
    @info "Plotter state completely cleared!"
end

"""
    launch_plotter()

Backend-agnostic Single Dashboard entry point. 
Initializes either the dense Eulerian or unstructured Lagrangian pipeline.
"""
function launch_plotter()
    manager = GLOBAL_PLOT_MANAGER

    if PLOTTER_UI_STATE[][:is_open]
        @info "Plotter already open, bringing to front..."
        return PLOTTER_UI_STATE[][:master_fig]
    end

    master_fig = Figure()
    ctrl_layout = master_fig[1, 1] = GridLayout(width = 550)
    plot_layout = master_fig[1, 2] = GridLayout() 
    
    create_controls(ctrl_layout)
    setup_common_interactions!(master_fig, plot_layout)
    
    if PLOT_MODE[] == :eulerian
        _setup_eulerian_data_sync!()
    else
        _setup_lagrangian_data_sync!()
    end

    PLOTTER_UI_STATE[][:is_open] = true
    PLOTTER_UI_STATE[][:master_fig] = master_fig

    setup_plot_window!(master_fig, plot_layout, manager.plot_data)
    resize_to_layout!(master_fig)
    return master_fig 
end

# ==============================================================================
# --- 3. LAYOUT & RENDER HANDLERS ---
# ==============================================================================
function setup_plot_window!(master_fig::Figure, plot_layout::GridLayout, plot_data_obs::Observable)
    manager = GLOBAL_PLOT_MANAGER
    if manager.staged[:plot_window_initialized][]; return; end
    manager.staged[:plot_window_initialized][] = true

    render_observers = ObserverFunction[]

    function rebuild_plot_layout!()
        if get(manager.staged, :Camera_Locked, Observable(false))[]
            extract_and_store_camera_state!(plot_layout)
        end

        style_sel = manager.widgets[:Plot_Style].selection[]
        ptype_sym = style_sel

        if PLOT_MODE[] == :lagrangian && !isempty(plot_data_obs[])
            pd = first(values(plot_data_obs[]))
            sim_data = _get_first_valid(pd)
            if !isnothing(sim_data)
                D = length(sim_data.domain.dim_keys) - (isnothing(sim_data.domain.time_dim) ? 0 : 1)
                
                s_sym = Symbol(style_sel)
                if (s_sym == :lines || s_sym == :Lines) && D == 1
                    ptype_sym = :scatterlines
                elseif (s_sym == :colors || s_sym == :Colors) && D == 1
                    ptype_sym = :scattercolors
                elseif (s_sym == :surface2D || style_sel == "2D (Surface)") && D == 2
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
        
        switch_ui_plot_type!(ptype_sym)
        
        new_obs = setup_render_lift!(master_fig, plot_layout, plot_data_obs, Val(ptype_sym))
        if !isnothing(new_obs); append!(render_observers, new_obs); end
    end

    manager.listeners[:Layout] = on(manager.triggers[:Layout]) do _
        @with_lock :Layout begin
            # 1. Refresh Data
            curr_config = manager.active_config
            if !isnothing(curr_config) && curr_config.simulation_func != "none"
                update_plot_data_collection!(plot_data_obs[], curr_config, manager.methods[]; force_reload = false)
            end
            
            # 2. Notify plot data to populate the UI menus 
            notify(plot_data_obs)

            # 3. Consume Layout Overwrites
            if !isempty(manager.staged[:Layout])
                apply_layout_options!(manager.staged[:Layout])
                empty!(manager.staged[:Layout])
            end
            
            # 4. Consume Scene Overwrites AFTER the menus have been populated
            if !isempty(manager.staged[:Scene])
                apply_scene_options!(manager.staged[:Scene])
                empty!(manager.staged[:Scene])
            end

            # 5. Consume UI Overwrites
            if !isempty(manager.staged[:UI])
                for (scope, dict) in manager.staged[:UI]
                    if haskey(manager.ui, scope)
                        for (k, v) in dict
                            if haskey(manager.ui[scope], k)
                                if manager.ui[scope][k] isa Observable
                                    manager.ui[scope][k][] = v
                                else
                                    manager.ui[scope][k] = v
                                end
                            end
                        end
                    end
                end
                empty!(manager.staged[:UI])
            end

            # 6. Rebuild structural layout
            rebuild_plot_layout!()
        end
        GLOBAL_PLOT_MANAGER.staged[:Flag_Layout][] = false
        # After layout finishes structurally, automatically draw the initial plot
        manager.triggers[:Primitive][] += 1
    end

    manager.listeners[:Scene] = on(manager.triggers[:Scene]) do _
        @with_lock :Scene begin
            curr_config = manager.active_config
            if curr_config.simulation_func != "none" && !isnothing(curr_config.simulation_func)
                update_plot_data_collection!(plot_data_obs[], curr_config, manager.methods[]; force_reload = false)
            end
        end
        manager.staged[:Flag_Plot][] = true
    end
    
    manager.listeners[:Plot_Click_Sync] = on(manager.widgets[:Plot_Button].clicks) do _
        if manager.staged[:Flag_Sim][] || manager.staged[:Flag_Layout][]
            return # Blocked
        end
        manager.staged[:Flag_Plot][] = false
        manager.triggers[:Primitive][] += 1
    end

    manager.listeners[:Layout_Apply_Sync] = on(manager.widgets[:Layout_Apply].clicks) do _
        if manager.staged[:Flag_Sim][]
            return # Blocked
        end
        manager.staged[:Flag_Layout][] = false
        manager.triggers[:Layout][] += 1
        manager.staged[:Flag_Plot][]   = false
    end

    prev_leg_struct = Ref((false, :none, :none))
    manager.listeners[:Legend_Sync] = onany(manager.widgets[:Legend_Base].selection, manager.widgets[:Legend_Add].selection) do _...
        curr = _parse_legend_position()
        p = prev_leg_struct[]
        
        if (!curr[1] && !p[1])
            manager.triggers[:UI][] += 1
        else
            prev_leg_struct[] = curr
            manager.staged[:Flag_Layout][] = true
        end
    end
    rebuild_plot_layout!()
end

# Helper: Eulerian Extraction Dispatch
function fetch_pipeline_tuples(::Val{:eulerian}, data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
    manager = GLOBAL_PLOT_MANAGER
    active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
    ax_cols = [Any[] for _ in 1:length(active_plot_axes_syms)]
    u_col = Any[]
    valid_methods = String[]
    
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
    return Tuple([ax_cols..., u_col]), valid_methods
end

# Helper: Lagrangian Extraction Dispatch
function fetch_pipeline_tuples(::Val{:lagrangian}, data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
    manager = GLOBAL_PLOT_MANAGER
    local DS = 1
    for m_name in local_methods
        if haskey(data, m_name)
            sim = _get_first_valid(data[m_name])
            if !isnothing(sim); DS = length(sim.domain.mins) - (isnothing(sim.domain.time_dim) ? 0 : 1); break; end
        end
    end
    
    ax_cols = [Any[] for _ in 1:DS]
    u_col = Any[]
    valid_methods = String[]
    
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
    return Tuple([ax_cols..., u_col]), valid_methods
end

function setup_render_lift!(master_fig::Figure, plot_layout::GridLayout, plot_data_obs::Observable, ::Val{T}) where T
    manager = GLOBAL_PLOT_MANAGER
    is_3d_axis = PLOT_DIM_MAP[T] == 3 || is_surface(T)
    w = manager.widgets
    rev_map = haskey(manager.staged, :Reverse_Map) ? manager.staged[:Reverse_Map] : Dict{Symbol, Symbol}()
    CT = PLOT_MODE[] == :eulerian ? EulerianPlotCache : LagrangianPlotCache
    
    # Read the data dimensions dynamically using Symbol widget keys
    selector_obs = map(manager.plot_vars) do n
        w_key = haskey(rev_map, n) ? rev_map[n] : n
        w[w_key].value
    end

    x_sel, y_sel = w[:X_Axis].selection, w[:Y_Axis].selection
    z_sel, u_sel = w[:Z_Axis].selection, w[:U_Axis].selection
    c_sel = w[:c].selection
    
    target = w[:Compare_Target].selection[]
    cols = w[:Compare_Columns].selection[]
    link_mode = w[:Compare_Link].selection[]
    
    num_plots, compare_labels, compare_vals = 1, String[], Any[]

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
                
                # --- FIX: Mirror the mode-aware logic from _setup_common_chain_c! ---
                if PLOT_MODE[] == :lagrangian
                    target_tensor_arr = target_tensor isa AbstractArray && ndims(target_tensor) == 1 ? target_tensor : target_tensor[1]
                    num_plots = length(target_tensor_arr[1])
                else
                    num_plots = length(eltype(target_tensor))
                end
                # ---------------------------------------------------------------------
                
                comp_names_tuple = manager.ui[:Labels][:comp_names]
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
                t_dim = findfirst(==(sim_data.domain.time_dim),sim_data.domain.dim_keys) 
                t_vals = PLOT_MODE[] == :lagrangian ? sim_data.t : (isnothing(t_dim) ? [0.0] : sim_data.axes[t_dim])
                
                num_plots = length(t_vals)
                compare_labels = ["t = $(round(t, sigdigits=4))" for t in t_vals]
                compare_vals = t_vals
            elseif target in manager.plot_vars
                idx = findfirst(isequal(target), manager.plot_vars)
                vals = pd_first.active_param_values[idx]
                num_plots = length(vals)
                compare_labels = ["$(string(target)) = $(v isa Int ? v : round(v, sigdigits=4))" for v in vals]
                compare_vals = vals
            end
        end
    end
    
    if target == :None || num_plots == 0; num_plots = 1; target = :None; end
    
    is_compare = target != :None
    is_det, halign, valign = _parse_legend_position()
    
    has_legend = T in LEGEND_SUPPORTED_PLOTS && target != :Methods
    has_colorbar = T in COLORBAR_SUPPORTED_PLOTS

    layout_dict = calculate_layout_dictionary(num_plots, cols, link_mode, has_legend, is_det, halign, valign, has_colorbar)
    manager.staged[:Layout_Dict][] = layout_dict
    
    axes = []
    for i in 1:num_plots
        r, c_idx = layout_dict[:Plots][i]
        ax = is_3d_axis ? Axis3(plot_layout[r, c_idx], perspectiveness=0.5) : Axis(plot_layout[r, c_idx])
        push!(axes, ax)
    end
    
    p_w = w[:Plot_Width].selection[]
    p_h = w[:Plot_Height].selection[]
    for i in 1:plot_layout.size[1]; rowsize!(plot_layout, i, Auto()); end
    for i in 1:plot_layout.size[2]; colsize!(plot_layout, i, Auto()); end
    
    for i in 1:num_plots
        r, c_idx = layout_dict[:Plots][i]
        rowsize!(plot_layout, r, Fixed(p_h))
        colsize!(plot_layout, c_idx, Fixed(p_w))
    end
    
    if !is_3d_axis && link_mode in (:fully_coupled, :axes_only)
        linkaxes!(axes...)
    end
    
    target_idx = target == :Time ? (isnothing(sim_data) ? nothing : findfirst(isequal(sim_data.domain.time_dim), manager.plot_vars)) : 
                 findfirst(isequal(target), manager.plot_vars)

    # --- 1. SAVE COMPARE STATE TO MANAGER ---
    manager.staged[:Compare_State] = (target, target_idx, compare_labels, compare_vals)

    function _mutate_compare_vals(current_sels, idx)
        t_val, t_idx, c_labels, c_vals = manager.staged[:Compare_State]
        mutated = collect(current_sels)
        if !isnothing(t_idx) && !isempty(c_vals) && idx <= length(c_vals)
            mutated[t_idx] = c_vals[idx]
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
    manager.listeners[:Primitive] = on(manager.triggers[:Primitive]) do _
        @with_lock :Primitive begin
            (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == :None || u_sel[] == :None) && return
            if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == :None) && return; end
            if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == :None) && return; end
            
            data = plot_data_obs[]
            isempty(data) && return

            target, _, _, _ = manager.staged[:Compare_State]
            is_compare = target != :None

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
                    
                    # Clean Val Dispatch Helper Call
                    data_tuples, valid_methods = fetch_pipeline_tuples(Val(PLOT_MODE[]), data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
                    isempty(valid_methods) && continue
                    
                    active_title_indices = if PLOT_MODE[] == :eulerian
                        active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
                        [findfirst(isequal(occursin("|", string(ax)) ? Symbol(split(string(ax), "|")[2]) : ax), manager.plot_vars) for ax in active_plot_axes_syms]
                    else
                        spatial_axes = isnothing(sim_data) ? Symbol[] : filter(k -> k != sim_data.domain.time_dim, sim_data.domain.dim_keys)
                        filter(!isnothing, [findfirst(isequal(ax), manager.plot_vars) for ax in spatial_axes])
                    end
                    
                    # --- TIER 2: PRIMITIVE REBUILD (Inside the loop) ---
                    ts = generate_dynamic_title(Tuple(active_title_indices), manager.plot_vars, mutated_sel_vals)
                    
                    # FIX 2: Combine the compare label with the dynamic title
                    default_title = is_compare ? "$(compare_labels[i]) | $ts" : ts 
                    
                    x_str = x_sel[] == :None ? "disabled" : string(x_sel[])
                    y_str = y_sel[] == :None ? "disabled" : string(y_sel[])
                    z_str = z_sel[] == :None ? "disabled" : string(z_sel[])
                    u_str = string(u_sel[])

                    initialize_base_plot!(plot_layout, axes[i], valid_methods, data_tuples, x_str, y_str, z_str, u_str, ts, Val(T), i)
                    axes[i].title[] = manager.ui[:Labels][:title] == "default" ? default_title : manager.ui[:Labels][:title]
                    
                    if !is_3d_axis
                        x_lims, y_lims = data_tuples[1], data_tuples[2]
                        safe_min(arrs) = isempty(arrs) ? 1.0 : minimum(v -> isempty(v) ? 1.0 : minimum(v), arrs)
                        if axes[i].xscale[] == log10 && safe_min(x_lims) <= 0; axes[i].xscale[] = identity; end
                        if axes[i].yscale[] == log10 && safe_min(y_lims) <= 0; axes[i].yscale[] = identity; end
                        
                        set_axis_limits_manager!(axes[i], x_lims, y_lims)
                    end
                    _enforce_camera_lock!(axes)
                end
            end
        end
        manager.staged[:Flag_Plot][] = false
        manager.triggers[:Slider][] += 1
        manager.triggers[:UI][] += 1
    end
    # =========================================================================
    # NEW TIER 2.5: SLIDER SYNC
    # =========================================================================
    manager.listeners[:Slider] = on(manager.triggers[:Slider]) do _
        @with_lock :Slider begin
            data = plot_data_obs[]
            isempty(data) && return
            
            active_axes = manager.staged[:Active_Axes][]
            u_val = u_sel[]
            comp_val = w[:Compare_Target].selection[]
            anim_val = w[:Anim_Target].selection[]

            target, target_idx, _, _ = manager.staged[:Compare_State]
            
            pd_first, sim_data = _get_active_sim_data(data)
            isnothing(sim_data) && return

            dim_names = manager.plot_vars
            total_dims = length(dim_names)
            n_params = total_dims - length(get_base_variables())
            
            target_field = (isnothing(u_val) || u_val == :None) ? :Solution : u_val
            base_stat = occursin("|", string(target_field)) ? Symbol(split(string(target_field), "|")[1]) : target_field
            kept_syms = base_stat == :Solution ? Tuple(sim_data.domain.dim_keys) : Tuple(IRunPDESims.get_kept_dims(base_stat, sim_data.domain))

            # Block the Data trigger while modifying widgets to prevent trampling 
            manager.locks[:Data] = true
            try
                for i in 1:total_dims
                    dim_sym = dim_names[i]
                    dim_str = String(dim_sym)
                    
                    is_axis = i in active_axes
                    is_compare = (target_idx == i) 
                    is_anim = dim_sym == anim_val
                    
                    is_spatial = false
                    is_physically_disabled = false
                    
                    if i > n_params
                        if PLOT_MODE[] == :lagrangian
                            is_spatial = dim_sym != sim_data.domain.time_dim
                            is_physically_disabled = !is_spatial && !(dim_sym in kept_syms)
                        else
                            is_physically_disabled = !(dim_sym in kept_syms)
                        end
                    end
                    
                    widget_key = i > n_params ? Symbol(dim_str) : get(manager.staged[:Reverse_Map], dim_sym, Symbol("param_$i"))
                    haskey(w, widget_key) || continue
                    ctrl = w[widget_key]
                    
                    slider_cache = get!(manager.staged, :Slider_Cache, Dict{Symbol, Float64}())
                    if length(ctrl.range[]) > 1
                        slider_cache[widget_key] = Float64(ctrl.value[])
                    end
                    
                    if is_axis || is_spatial || is_physically_disabled || is_compare || is_anim
                        if ctrl.range[] != [0.0]
                            ctrl.range[] = [0.0] 
                        end
                        continue
                    end
                    
                    g_min, g_max = Inf, -Inf
                    for pd in values(data)
                        vals = nothing
                        if i <= n_params 
                            vals = pd.active_param_values[i]
                        else
                            s_data = isempty(pd.data) ? nothing : first(filter(!isnothing, pd.data))
                            isnothing(s_data) && continue
                            
                            if PLOT_MODE[] == :lagrangian
                                if dim_sym == s_data.domain.time_dim
                                    vals = s_data.t
                                end
                            else
                                idx = findfirst(==(dim_sym), s_data.domain.dim_keys)
                                if !isnothing(idx)
                                    vals = s_data.axes[idx]
                                end
                            end
                        end
                    
                        if !isnothing(vals) && !isempty(vals)
                            l, h = extrema(vals)
                            g_min = min(l, g_min)  
                            g_max = max(h, g_max)
                        end
                    end
                    
                    if isinf(g_min); g_min = 0.0; g_max = 1.0; end
                    
                    old_val = get(slider_cache, widget_key, Float64(ctrl.value[]))
                    
                    new_range = [0.0]
                    if i <= n_params
                        all_vals = Any[]
                        for pd in values(data)
                            append!(all_vals, pd.active_param_values[i])
                        end
                        new_range = isempty(all_vals) ? [0.0] : sort(unique(identity.(all_vals)))
                    else
                        new_range = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
                    end
                    
                    if ctrl.range[] != new_range
                        ctrl.range[] = new_range
                        set_close_to!(ctrl, old_val)
                    end
                end
            finally
                manager.locks[:Data] = false
            end
        end
        # Now trigger the Data phase safely
        manager.triggers[:Data][] += 1
    end
    # =========================================================================
    # TIER 3: DATA SYNC
    # =========================================================================
    manager.listeners[:Data_Sync_Widget] = onany(c_sel, selector_obs...) do _...
        # --- THE FIX: Block fast data syncs if the user changed a structural axis ---
        if manager.staged[:Flag_Plot][] || manager.staged[:Flag_Layout][] || manager.staged[:Flag_Sim][]
            return
        end
        manager.triggers[:Data][] += 1
    end

    # 2. Main Logic listens ONLY to the Data trigger
    manager.listeners[:Data] = on(manager.triggers[:Data]) do _
        @with_lock :Data begin
            (isnothing(x_sel[]) || isnothing(u_sel[]) || x_sel[] == :None || u_sel[] == :None) && return
            if PLOT_DIM_MAP[T] >= 2; (isnothing(y_sel[]) || y_sel[] == :None) && return; end
            if PLOT_DIM_MAP[T] >= 3; (isnothing(z_sel[]) || z_sel[] == :None) && return; end
            
            caches = manager.caches
            data = plot_data_obs[]

            (isempty(data) || isempty(caches) || isempty(manager.methods[])) && return

            target, _, _, _ = manager.staged[:Compare_State]
            is_compare = target != :None
            
            # Re-extract the values inside the trigger scope
            sel_vals = [to_value(obs) for obs in selector_obs]
            
            for i in 1:num_plots
                mutated_sel_vals = is_compare ? _mutate_compare_vals(sel_vals, i) : sel_vals
                target_c_int = (is_compare && target == :Component) ? i : c_sel[]
                local_methods = is_compare && target == :Methods ? [manager.methods[][i]] : manager.methods[]
                
                data_tuples, valid_methods = fetch_pipeline_tuples(Val(PLOT_MODE[]), data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
                isempty(valid_methods) && continue
                
                if !is_3d_axis
                    x_lims, y_lims = data_tuples[1], data_tuples[2]
                    safe_min(arrs) = isempty(arrs) ? 1.0 : minimum(v -> isempty(v) ? 1.0 : minimum(v), arrs)
                    if axes[i].xscale[] == log10 && safe_min(x_lims) <= 0; axes[i].xscale[] = identity; end
                    if axes[i].yscale[] == log10 && safe_min(y_lims) <= 0; axes[i].yscale[] = identity; end
                    
                    set_axis_limits_manager!(axes[i], x_lims, y_lims)
                end
                
                sync_data_to_cache!(caches[i], valid_methods, data_tuples, Val(PLOT_DIM_MAP[T]))
                
                active_title_indices = if PLOT_MODE[] == :eulerian
                    active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
                    [findfirst(isequal(occursin("|", string(ax)) ? Symbol(split(string(ax), "|")[2]) : ax), manager.plot_vars) for ax in active_plot_axes_syms]
                else
                    spatial_axes = isnothing(sim_data) ? Symbol[] : filter(k -> k != sim_data.domain.time_dim, sim_data.domain.dim_keys)
                    filter(!isnothing, [findfirst(isequal(ax), manager.plot_vars) for ax in spatial_axes])
                end
                
                ts = generate_dynamic_title(Tuple(active_title_indices), manager.plot_vars, mutated_sel_vals)
                default_title = is_compare ? compare_labels[i] : ts
                axes[i].title[] = manager.ui[:Labels][:title] == "default" ? default_title : manager.ui[:Labels][:title]
            end
            for ax in axes; apply_axis_limits_overrides!(ax); end
            _enforce_camera_lock!(axes)
        end
    end

    # =========================================================================
    # TIER 4: UI & STYLE MUTATION 
    # =========================================================================
    manager.listeners[:UI] = on(manager.triggers[:UI]) do _
        @with_lock :UI begin
            if !isempty(manager.staged[:Camera])
                manager.staged[:Camera_Locked][] = true
                if haskey(manager.widgets, :Lock_Camera_Button)
                    btn = manager.widgets[:Lock_Camera_Button]
                    btn.label[] = "Unlock Camera"
                    btn.buttoncolor[] = :lightgreen
                end
            else
                if get(manager.staged, :Camera_Locked, Observable(false))[]
                    manager.staged[:Camera_Locked][] = false
                    if haskey(manager.widgets, :Lock_Camera_Button)
                        btn = manager.widgets[:Lock_Camera_Button]
                        btn.label[] = "Lock Camera"
                        btn.buttoncolor[] = :lightgray
                    end
                end
            end

            # 2. Paint Primitives
            ui_app = manager.ui[:Plot_Style]
            
            for (i, ax) in enumerate(axes)
                _apply_axis_styles!(ax, T)
                apply_axis_limits_overrides!(ax)
                
                if !is_3d_axis && haskey(ui_app, :reference)
                    delete_plots_by_label!(ax, "Reference Lines")
                    ref_exp = ui_app[:reference]
                    !isempty(ref_exp) && plot_reference_lines!(ax, ref_exp; label="Reference Lines")
                end
                
                if haskey(manager.caches, i)
                    for (method_name, cache) in manager.caches[i]
                        m_idx = findfirst(isequal(method_name), manager.methods[])
                        isnothing(m_idx) && continue 
                        
                        colors = get(ui_app, :colors, nothing)
                        c = !isnothing(colors) ? colors[mod1(m_idx, length(colors))] : :black
                        
                        for (key, prim) in cache.primitives
                            apply_ui_style!(key, prim, ui_app, c)
                        end
                    end
                    
                    if has_colorbar
                        plot_obj = _find_first_drawable_primitive(manager.caches[i])
                        if !isnothing(plot_obj)
                            cr_obs = haskey(plot_obj.attributes, :colorrange) ? plot_obj.colorrange : Observable((0.0, 1.0))
                            create_or_update_colorbar!(plot_layout, plot_obj, cr_obs, string(w[:U_Axis].selection[]), i)
                        end
                    end
                end
            end
            
            if !is_3d_axis && T in LEGEND_SUPPORTED_PLOTS
                create_or_update_legend!(plot_layout, _collect_legend_elements(ui_app)...)
            end
            
            resize_to_layout!(master_fig)
            _enforce_camera_lock!(axes)
        end
    end
    
    # Store dynamic UI listeners internally 
    return vcat(manager.listeners[:Primitive], manager.listeners[:Slider], manager.listeners[:Data_Sync_Widget], manager.listeners[:Data], manager.listeners[:UI])
end