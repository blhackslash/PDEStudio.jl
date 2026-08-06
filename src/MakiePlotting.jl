# ==============================================================================
# --- PLOT MODE DISPATCHES (Replacing if manager.mode[] == ...) ---
# ==============================================================================
_cache_type(::Val{:eulerian}) = EulerianPlotCache
_cache_type(::Val{:lagrangian}) = LagrangianPlotCache

_get_component_num_plots(::Val{:eulerian}, target_tensor) = length(eltype(target_tensor))

function _get_component_num_plots(::Val{:lagrangian}, target_tensor)
    if target_tensor isa AbstractVector && eltype(target_tensor) <: AbstractVector
        # Drill down: Timestep 1 -> Particle 1 -> SVector length
        return (isempty(target_tensor) || isempty(target_tensor[1])) ? 1 : length(target_tensor[1][1])
    elseif target_tensor isa AbstractVector
        return isempty(target_tensor) ? 1 : length(target_tensor[1])
    else
        return length(target_tensor)
    end
end

function _get_active_title_indices(::Val{:eulerian}, x_sel, y_sel, z_sel, sim_data)
    active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
    return [findfirst(isequal(occursin("|", string(ax)) ? Symbol(split(string(ax), "|")[2]) : ax), manager.plot_vars) for ax in active_plot_axes_syms]
end
function _get_active_title_indices(::Val{:lagrangian}, x_sel, y_sel, z_sel, sim_data)
    spatial_axes = isnothing(sim_data) ? Symbol[] : filter(k -> k != sim_data.domain.time_dim, sim_data.domain.dim_keys)
    return filter(!isnothing, [findfirst(isequal(ax), manager.plot_vars) for ax in spatial_axes])
end

_get_time_vals(::Val{:eulerian}, sim_data, t_dim) = isnothing(t_dim) ? [0.0] : sim_data.axes[t_dim]
_get_time_vals(::Val{:lagrangian}, sim_data, t_dim) = sim_data.t

_is_spatial_dim(::Val{:eulerian}, dim_sym, sim_data, kept_syms) = (false, !(dim_sym in kept_syms))
function _is_spatial_dim(::Val{:lagrangian}, dim_sym, sim_data, kept_syms)
    is_spatial = dim_sym != sim_data.domain.time_dim
    is_disabled = !is_spatial && !(dim_sym in kept_syms)
    return (is_spatial, is_disabled)
end

function _get_dim_vals(::Val{:eulerian}, s_data, dim_sym)
    idx = findfirst(==(dim_sym), s_data.domain.dim_keys)
    return isnothing(idx) ? nothing : s_data.axes[idx]
end
function _get_dim_vals(::Val{:lagrangian}, s_data, dim_sym)
    return dim_sym == s_data.domain.time_dim ? s_data.t : nothing
end

# ==============================================================================
# --- GENERAL HELPER FUNCTIONS ---
# ==============================================================================

function set_sim_config!(config::SimulationConfig)
    manager.active_config = config
    manager.flags[:Simulation][] = true 
    
    if haskey(manager.maps, :Labels)
        for m_sym in keys(config.methods_dict)
            if m_sym !== :shared && !haskey(manager.maps[:Labels], m_sym)
                manager.maps[:Labels][m_sym] = is_reference_method(m_sym) ? frontend_key(m_sym) : string(m_sym)
            end
        end
    end
    
    # Use active_methods
    active_m = isempty(config.active_methods) ? filter(k -> k !== :shared, collect(keys(config.methods_dict))) : filter(k -> k !== :shared, copy(config.active_methods))
    
    # Ensure the config is updated if it was empty
    config.active_methods = active_m
    manager.methods[] = copy(active_m) # Keep this observable for the layout plot loops

    # =========================================================================
    # THE FIX: Build UI mappings immediately so CSV loading and layout triggers can use them!
    # =========================================================================
    real_params = Symbol.(sort(collect(keys(config.varied_params))))
    param_map = Dict{Symbol, Symbol}()
    reverse_map = Dict{Symbol, Symbol}()
    
    i = 1
    while haskey(manager.widgets, Symbol("param_$(i)_label"))
        p_key = Symbol("param_$i")
        lbl_obs = manager.widgets[Symbol("param_$(i)_label")]
        
        if i <= length(real_params)
            real_sym = real_params[i]
            param_map[p_key] = real_sym
            reverse_map[real_sym] = p_key
            
            lbl_obs[] = frontend_key(real_sym) * ":"  
        else
            lbl_obs[] = "Unused:"
            if haskey(manager.widgets, p_key)
                manager.widgets[p_key].range[] = [0.0] 
            end
        end
        i += 1
    end
    
    for base_sym in get_base_variables()
        base_lbl_key = Symbol("$(base_sym)_label")
        if haskey(manager.widgets, base_lbl_key)
            manager.widgets[base_lbl_key][] = frontend_key(base_sym) * ":"
        end
    end
    
    manager.maps[:Param] = param_map
    manager.maps[:Reverse] = reverse_map
    manager.plot_vars = [real_params; get_base_variables()]
    # =========================================================================

    if haskey(manager.widgets, :editor_cat)
        notify(manager.widgets[:editor_cat].selection)
    end
    
    # Force the UI menu to redraw itself with the newly loaded config
    notify(manager.state[:Is_Activate_Mode])
end

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

function reset_plotter!()
    fig = manager.ui_state[:master_fig]
    
    if !isnothing(fig)
        try
            screen = Makie.getscreen(fig.scene)
            if !isnothing(screen); close(screen); end
        catch
        end
        empty!(fig)
    end
    
    manager.ui_state[:is_open] = false
    manager.ui_state[:master_fig] = nothing
    manager.state[:Camera_Locked][] = false
    
    for (k, obs) in manager.triggers
        if k != :Simulation
            empty!(obs.listeners)
        end
    end

    for (k, listener_node) in manager.listeners
        if k != :Simulation
            if listener_node isa Vector
                for l in listener_node; off(l); end
            else
                off(listener_node)
            end
        end
    end
    
    manager.state[:plot_window_initialized][] = false
    
    @info "Plotter state completely cleared!"
end

function launch_plotter()

    reset_plotter!()

    master_fig = Figure()
    ctrl_layout = master_fig[1, 1] = GridLayout()
    plot_layout = master_fig[1, 2] = GridLayout() 
    
    create_controls(ctrl_layout)
    setup_ui_interactions!(master_fig, plot_layout, Val(manager.mode[]))

    manager.ui_state[:is_open] = true
    manager.ui_state[:master_fig] = master_fig

    setup_plot_window!(master_fig, plot_layout)
    resize_to_layout!(master_fig)
    return master_fig 
end

# ==============================================================================
# --- 3. LAYOUT & RENDER HANDLERS ---
# ==============================================================================
function setup_plot_window!(master_fig::Figure, plot_layout::GridLayout)
    if manager.state[:plot_window_initialized][]; return; end
    manager.state[:plot_window_initialized][] = true

    # THE FIX: Store observers globally so we can pause them during export
    manager.state[:Main_Render_Observers] = ObserverFunction[]

    function rebuild_plot_layout!()
        if get(manager.state, :Camera_Locked, Observable(false))[]
            # THE FIX: Don't extract the dying axes if we just loaded a perfect CSV cache!
            if get(manager.state, :Skip_Next_Camera_Extract, false)
                manager.state[:Skip_Next_Camera_Extract] = false
            else
                extract_and_store_camera_state!(plot_layout)
            end
        end

        ptype_sym = manager.widgets[:plot_style].selection[]
        
        sim_data = nothing
        if !isempty(manager.plot_data[])
            sim_data = _get_first_valid(first(values(manager.plot_data[])))
        end

        # THE FIX: Safely clear old observers
        if haskey(manager.state, :Main_Render_Observers)
            for obs in manager.state[:Main_Render_Observers]; off(obs); end
            empty!(manager.state[:Main_Render_Observers])
        end
        empty!(manager.caches)
        
        for c in copy(plot_layout.content)
            if c.content isa Makie.Block; delete!(c.content); end
        end
        trim!(plot_layout)
        
        switch_ui_plot_type!(ptype_sym)
        
        new_obs = setup_render_lift!(master_fig, plot_layout, Val(ptype_sym))
        if !isnothing(new_obs); append!(manager.state[:Main_Render_Observers], new_obs); end
    end

    manager.listeners[:Data] = on(manager.triggers[:Data]) do _
        @with_lock :Data begin
            _handle_data_fetch_trigger!()
        end
        manager.flags[:Layout][] = false
        manager.triggers[:Layout][] += 1
    end

    manager.listeners[:Layout] = on(manager.triggers[:Layout]) do _
        @with_lock :Layout begin
            _handle_layout_trigger!(rebuild_plot_layout!)
        end
        manager.flags[:Plot][] = false
        manager.triggers[:Plot][] += 1
    end
    
    manager.listeners[:Plot_Click_Sync] = on(manager.widgets[:plot_button].clicks) do _
        if manager.flags[:Simulation][] || manager.flags[:Layout][]
            return 
        end
        manager.flags[:Plot][] = false
        manager.triggers[:Plot][] += 1
    end

    manager.listeners[:Layout_Apply_Sync] = on(manager.widgets[:layout_apply].clicks) do _
        if manager.flags[:Simulation][]
            return 
        end
        manager.flags[:Layout][] = false
        manager.triggers[:Layout][] += 1
    end

    prev_leg_struct = Ref((false, :none, :none))
    manager.listeners[:Legend_Sync] = onany(manager.widgets[:legend_base].selection, manager.widgets[:legend_add].selection) do _...
        curr = _parse_legend_position()
        p = prev_leg_struct[]
        
        if (!curr[1] && !p[1])
            manager.triggers[:UI][] += 1
        else
            prev_leg_struct[] = curr
            manager.flags[:Layout][] = true
        end
    end

    manager.triggers[:Layout][] += 1
end

# ==============================================================================
# --- MAIN TOP-LEVEL RENDER LIFT ---
# ==============================================================================

function setup_render_lift!(master_fig::Figure, plot_layout::GridLayout, ::Val{T}) where T
    
    # 1. Initialize complete layout structure and unpack necessary state handles
    axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, has_colorbar = _initialize_render_layout!(plot_layout, Val(T))

    # 2. Wire up the top-level trigger pipelines
    manager.listeners[:Plot] = on(manager.triggers[:Plot]) do _
        local success = false
        @with_lock :Plot begin
            success = _handle_plot_trigger!(Val(T), plot_layout, axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, _build_param_indices, _mutate_compare_vals)
        end
        if success
            manager.triggers[:Slider][] += 1
        end
    end

    manager.listeners[:Slider] = on(manager.triggers[:Slider]) do _
        local success = false
        @with_lock :Slider begin
            success = _handle_slider_trigger!(u_sel)
        end
        if success
            manager.triggers[:PlotData][] += 1
        end
    end

    manager.listeners[:PlotData_Sync_Widget] = onany(c_sel, selector_obs...) do _...
        
        # ====================================================================
        # THE FIX: Sync manual slider drags into the persistent caches!
        # ====================================================================
        rev_map = get(manager.maps, :Reverse, Dict{Symbol, Symbol}())
        for k in manager.plot_vars
            w_key = haskey(rev_map, k) ? rev_map[k] : k 
            if haskey(manager.widgets, w_key)
                widget = manager.widgets[w_key]
                if widget isa Makie.Slider
                    val = widget.value[]
                    manager.state[:Slider_Cache][w_key] = Float64(val)
                    manager.state[:Plot_Cache][k] = val # Assign by the pure variable symbol
                end
            end
        end
        # ====================================================================

        if manager.flags[:Plot][] || manager.flags[:Layout][] || manager.flags[:Simulation][]
            return
        end
        manager.triggers[:PlotData][] += 1
    end

    manager.listeners[:PlotData] = on(manager.triggers[:PlotData]) do _
        local success = false
        @with_lock :PlotData begin
            success = _handle_data_trigger!(Val(T), axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, _build_param_indices, _mutate_compare_vals)
        end
        if success
            manager.triggers[:UI][] += 1
        end
    end

    manager.listeners[:UI] = on(manager.triggers[:UI]) do _
        @with_lock :UI begin
            _handle_ui_trigger!(Val(T), master_fig, plot_layout, axes, has_colorbar, u_sel)
        end
    end
    
    return vcat(manager.listeners[:Plot], manager.listeners[:Slider], manager.listeners[:PlotData_Sync_Widget], manager.listeners[:PlotData], manager.listeners[:UI])
end