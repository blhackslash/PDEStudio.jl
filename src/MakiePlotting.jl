# ==============================================================================
# --- PLOT MODE DISPATCHES (Replacing if manager.mode[] == ...) ---
# ==============================================================================
_cache_type(::Val{:eulerian}) = EulerianPlotCache
_cache_type(::Val{:lagrangian}) = LagrangianPlotCache

_get_component_num_plots(::Val{:eulerian}, target_tensor) = length(eltype(target_tensor))
function _get_component_num_plots(::Val{:lagrangian}, target_tensor)
    target_tensor_arr = (target_tensor isa AbstractArray && ndims(target_tensor) == 1) ? target_tensor : target_tensor[1]
    return length(target_tensor_arr[1])
end

function _get_active_title_indices(::Val{:eulerian}, x_sel, y_sel, z_sel, sim_data)
    active_plot_axes_syms = filter(s -> !isnothing(s) && s != :None, [x_sel[], y_sel[], z_sel[]])
    return [findfirst(isequal(occursin("|", string(ax)) ? Symbol(split(string(ax), "|")[2]) : ax), manager.plot_vars) for ax in active_plot_axes_syms]
end
function _get_active_title_indices(::Val{:lagrangian}, x_sel, y_sel, z_sel, sim_data)
    spatial_axes = isnothing(sim_data) ? Symbol[] : filter(k -> k != sim_data.domain.time_dim, sim_data.domain.dim_keys)
    return filter(!isnothing, [findfirst(isequal(ax), manager.plot_vars) for ax in spatial_axes])
end

_resolve_plot_type(::Val{:eulerian}, style_sel, sim_data) = Symbol(style_sel)
function _resolve_plot_type(::Val{:lagrangian}, style_sel, sim_data)
    ptype_sym = Symbol(style_sel)
    isnothing(sim_data) && return ptype_sym
    D = length(sim_data.domain.dim_keys) - (isnothing(sim_data.domain.time_dim) ? 0 : 1)
    
    if (ptype_sym == :lines || ptype_sym == :Lines) && D == 1
        return :scatterlines
    elseif (ptype_sym == :colors || ptype_sym == :Colors) && D == 1
        return :scattercolors
    elseif (ptype_sym == :surface2D || style_sel == "2D (Surface)") && D == 2
        return :scatter2d_surface
    else
        return D == 1 ? :scatter1d : (D == 2 ? :scatter2d : :scatter3d)
    end
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
    manager.staged[:Flag_Sim][] = true 
    
    if !haskey(manager.staged, :Staged_Methods)
        manager.staged[:Staged_Methods] = Observable(String[])
    end
    
    default_m = isempty(config.default_methods) ? filter(k -> k != "shared", collect(keys(config.methods_dict))) : filter(k -> k != "shared", copy(config.default_methods))
    manager.staged[:Staged_Methods][] = default_m

    if haskey(manager.widgets, :Editor_Cat)
        notify(manager.widgets[:Editor_Cat].selection)
    end
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
    manager.staged[:Layout] = get_base_layout_options()
    
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
    
    if haskey(manager.staged, :plot_window_initialized)
        manager.staged[:plot_window_initialized][] = false
    end
    
    manager.active_config = DUMMY_CONFIG
    @info "Plotter state completely cleared!"
end

function launch_plotter()
    if manager.ui_state[:is_open]
        @info "Plotter already open, bringing to front..."
        return manager.ui_state[:master_fig]
    end

    master_fig = Figure()
    ctrl_layout = master_fig[1, 1] = GridLayout(width = 550)
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
    if manager.staged[:plot_window_initialized][]; return; end
    manager.staged[:plot_window_initialized][] = true

    render_observers = ObserverFunction[]

    function rebuild_plot_layout!()
        if get(manager.staged, :Camera_Locked, Observable(false))[]
            extract_and_store_camera_state!(plot_layout)
        end

        style_sel = manager.widgets[:Plot_Style].selection[]
        
        sim_data = nothing
        if !isempty(manager.plot_data[])
            sim_data = _get_first_valid(first(values(manager.plot_data[])))
        end
        
        ptype_sym = _resolve_plot_type(Val(manager.mode[]), style_sel, sim_data)

        for obs in render_observers; off(obs); end
        empty!(render_observers)
        empty!(manager.caches)
        
        for c in copy(plot_layout.content)
            if c.content isa Makie.Block; delete!(c.content); end
        end
        trim!(plot_layout)
        
        switch_ui_plot_type!(ptype_sym)
        
        new_obs = setup_render_lift!(master_fig, plot_layout, Val(ptype_sym))
        if !isnothing(new_obs); append!(render_observers, new_obs); end
    end

    manager.listeners[:Layout] = on(manager.triggers[:Layout]) do _
        @with_lock :Layout begin
            _handle_layout_trigger!(rebuild_plot_layout!)
        end
        manager.staged[:Flag_Layout][] = false
        manager.triggers[:Primitive][] += 1
    end

    manager.listeners[:Scene] = on(manager.triggers[:Scene]) do _
        @with_lock :Scene begin
            _handle_scene_trigger!()
        end
        manager.staged[:Flag_Plot][] = true
    end
    
    manager.listeners[:Plot_Click_Sync] = on(manager.widgets[:Plot_Button].clicks) do _
        if manager.staged[:Flag_Sim][] || manager.staged[:Flag_Layout][]
            return 
        end
        manager.staged[:Flag_Plot][] = false
        manager.triggers[:Primitive][] += 1
    end

    manager.listeners[:Layout_Apply_Sync] = on(manager.widgets[:Layout_Apply].clicks) do _
        if manager.staged[:Flag_Sim][]
            return 
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

# ==============================================================================
# --- MAIN TOP-LEVEL RENDER LIFT ---
# ==============================================================================

function setup_render_lift!(master_fig::Figure, plot_layout::GridLayout, ::Val{T}) where T
    
    # 1. Initialize complete layout structure and unpack necessary state handles
    axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, has_colorbar = _initialize_render_layout!(plot_layout, Val(T))

    # 2. Wire up the top-level trigger pipelines
    manager.listeners[:Primitive] = on(manager.triggers[:Primitive]) do _
        @with_lock :Primitive begin
            _handle_primitive_trigger!(Val(T), plot_layout, axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, _build_param_indices, _mutate_compare_vals)
        end
        manager.staged[:Flag_Plot][] = false
        manager.triggers[:Slider][] += 1
        manager.triggers[:UI][] += 1
    end

    manager.listeners[:Slider] = on(manager.triggers[:Slider]) do _
        @with_lock :Slider begin
            _handle_slider_trigger!(u_sel)
        end
        manager.triggers[:Data][] += 1
    end

    manager.listeners[:Data_Sync_Widget] = onany(c_sel, selector_obs...) do _...
        if manager.staged[:Flag_Plot][] || manager.staged[:Flag_Layout][] || manager.staged[:Flag_Sim][]
            return
        end
        manager.triggers[:Data][] += 1
    end

    manager.listeners[:Data] = on(manager.triggers[:Data]) do _
        @with_lock :Data begin
            _handle_data_trigger!(Val(T), axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, _build_param_indices, _mutate_compare_vals)
        end
    end

    manager.listeners[:UI] = on(manager.triggers[:UI]) do _
        @with_lock :UI begin
            _handle_ui_trigger!(Val(T), master_fig, plot_layout, axes, has_colorbar, u_sel)
        end
    end
    
    return vcat(manager.listeners[:Primitive], manager.listeners[:Slider], manager.listeners[:Data_Sync_Widget], manager.listeners[:Data], manager.listeners[:UI])
end