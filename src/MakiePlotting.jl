# =============================
# --- PLOT MODE DISPATCHES ---
# =============================
"""
    _cache_type(::Val{Mode})

A dispatch helper that returns the appropriate `AbstractPlotCache` type based on the active visualization mode (e.g., `EulerianPlotCache` or `LagrangianPlotCache`).
"""
_cache_type(::Val{:eulerian}) = EulerianPlotCache
_cache_type(::Val{:lagrangian}) = LagrangianPlotCache

"""
    _get_component_num_plots(::Val{Mode}, target_tensor)

Dynamically analyzes a multi-component mathematical tensor and returns the number of sub-components required for plotting. 
Safely handles empty arrays and deeply nested vector-of-vector structures inherent to Lagrangian particle tracks.
"""
function _get_component_num_plots(::Val{:eulerian}, target_tensor)
    target_tensor isa SVector && return length(target_tensor)  # scalar statistic
    isempty(target_tensor) && return 1
    first_elem = first(target_tensor)
    return (first_elem isa AbstractArray || first_elem isa Tuple) ? length(first_elem) : 1
end

function _get_component_num_plots(::Val{:lagrangian}, target_tensor)
    if target_tensor isa SVector
        return length(target_tensor)
    elseif target_tensor isa AbstractVector && eltype(target_tensor) <: AbstractVector && !(eltype(target_tensor) <: SVector)
        # Drill down: Timestep 1 -> Particle 1 -> SVector length
        return (isempty(target_tensor) || isempty(target_tensor[1])) ? 1 : length(target_tensor[1][1])
    elseif target_tensor isa AbstractVector
        return isempty(target_tensor) ? 1 : length(target_tensor[1])
    else
        return length(target_tensor)
    end
end

"""
    _get_active_title_indices(::Val{Mode}, x_sel, y_sel, z_sel, sim_data)

Parses the active plot axis observables and returns a vector of indices corresponding to their physical dimensions in the `sim_data`. 
Used to generate dynamic plot titles and axis labels.
"""
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

"""
    _is_spatial_dim(::Val{Mode}, dim_sym, sim_data, kept_syms)

Evaluates whether a given dimension symbol represents a strict spatial coordinate based on the underlying `DomainInfo` and active visualization mode.
Returns a tuple `(is_spatial, is_disabled)`.
"""
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

"""
    set_sim_config!(config::SimulationConfig; snapshot = true)

The primary injection point for connecting a `PDEStudioCore` physics configuration to the `PDEStudio` interactive UI.

This function unpacks the `SimulationConfig`, maps the dynamic parameter sweeps to the available UI sliders, builds the backend-to-frontend symbolic translation dictionaries, and flags the simulation for a (re)run.
With `snapshot = true` (the default) a copy of `config` is kept as the baseline that *Reset Simulation* (see [`reset_sim_config!`](@ref)) returns to.
"""
function set_sim_config!(config::SimulationConfig; snapshot::Bool = true)
    manager.active_config = config
    manager.csv_cache = nothing  # a staged (structural) CSV is superseded by this configuration
    haskey(manager.flags, :Simulation) && (manager.flags[:Simulation][] = true)

    for m_sym in keys(config.methods)
        if m_sym !== :shared && !haskey(manager.labels, m_sym)
            set_label!(m_sym, is_reference_method(m_sym) ? frontend_key(m_sym) : string(m_sym))
        end
    end

    # Without explicit defaults, every method of the configuration is active (references first, then by name).
    active_m = sort_methods_robust(isempty(config.defaults) ? collect(keys(config.methods)) : unique(config.defaults))
    filter!(k -> k !== :shared, active_m)
    config.defaults = active_m
    snapshot && (manager.base_config = deepcopy(config))
    manager.methods[] = copy(active_m)

    # Build UI mappings immediately so CSV loading and layout triggers can use them
    _map_parameters_to_sliders!(config)

    if haskey(manager.widgets, :editor_cat)
        notify(manager.widgets[:editor_cat].selection)
    end

    # Force the UI menu to redraw itself with the newly loaded config
    notify(manager.is_activate_mode)
    return config
end

"""
    _map_parameters_to_sliders!(config::SimulationConfig)

Binds the swept parameters of `config` (sorted by name) to the parameter sliders `param_1, param_2, …`,
updates the slider labels and rebuilds `manager.plot_vars`. Parameters without a free slider keep
their first value (a warning suggests `set_max_params!`).
"""
function _map_parameters_to_sliders!(config::SimulationConfig)
    real_params = sort!(collect(keys(config.varied)))
    if length(real_params) > manager.max_params
        @warn "The configuration sweeps $(length(real_params)) parameters, but the studio has only $(manager.max_params) parameter sliders. " *
              "Call `set_max_params!($(length(real_params)))` before `launch_plotter()`; parameters without a slider stay at their first value."
    end

    param_map = Dict{Symbol, Symbol}()
    reverse_map = Dict{Symbol, Symbol}()
    for i in 1:manager.max_params
        p_key = Symbol("param_$i")
        lbl_obs = get(manager.widgets, Symbol("param_$(i)_label"), nothing)
        if i <= length(real_params)
            param_map[p_key] = real_params[i]
            reverse_map[real_params[i]] = p_key
            isnothing(lbl_obs) || (lbl_obs[] = frontend_key(real_params[i]) * ":")
        else
            isnothing(lbl_obs) || (lbl_obs[] = "Unused:")
            haskey(manager.widgets, p_key) && (manager.widgets[p_key].range[] = [0.0])
        end
    end

    for base_sym in get_base_variables()
        base_lbl_key = Symbol("$(base_sym)_label")
        haskey(manager.widgets, base_lbl_key) && (manager.widgets[base_lbl_key][] = frontend_key(base_sym) * ":")
    end

    manager.param_map = param_map
    manager.reverse_map = reverse_map
    manager.plot_vars = Symbol[real_params; get_base_variables()]
    return nothing
end

"""
    find_config_csv(name::AbstractString)

Locates a configuration CSV by file name: an existing path is returned as is; otherwise the working directory,
`<save path>/figures`, `<save path>/animations`, the preset folders and `./Experiments` (one level of subfolders each) are searched.
Returns the path or `nothing`.
"""
function find_config_csv(name::AbstractString)
    candidate = strip(name)
    isfile(candidate) && return String(candidate)
    filename = endswith(lowercase(candidate), ".csv") ? String(candidate) : candidate * ".csv"
    isfile(filename) && return filename

    save_root = get_save_path()
    search_dirs = [
        pwd(),
        joinpath(save_root, "figures"),
        joinpath(save_root, "animations"),
        preset_dir(),
        sim_preset_dir(),
        joinpath(pwd(), "Experiments"),
    ]
    for dir in search_dirs
        isdir(dir) || continue
        test_path = joinpath(dir, filename)
        isfile(test_path) && return test_path
        for subdir in readdir(dir; join = true)
            isdir(subdir) || continue
            test_path = joinpath(subdir, filename)
            isfile(test_path) && return test_path
        end
    end
    return nothing
end

"""
    set_sim_config!(csv_name::AbstractString)

A convenience wrapper that locates a CSV (a path, or a file name searched for with `find_config_csv`) and applies it via `load_and_apply_csv!`.
Returns `true` if the file changes structural UI limits (the change is staged until *Run Simulation*), `false` otherwise, and `nothing` if no file was found.
"""
function set_sim_config!(csv_name::AbstractString)
    filepath = find_config_csv(csv_name)
    if isnothing(filepath)
        @warn "CSV file '$csv_name' not found."
        return nothing
    end
    return load_and_apply_csv!(filepath)
end

"""
    reset_plotter!()

Safely resets the Makie rendering engine. 
It systematically closes the active display screen, clears the `Figure` cache, and explicitly detaches all reactive `ObserverFunction` listeners to prevent memory leaks and ghost updates during hot reloads.
"""
function reset_plotter!()
    fig = manager.master_fig
    
    if !isnothing(fig)
        try
            screen = Makie.getscreen(fig.scene)
            if !isnothing(screen); close(screen); end
        catch
        end
        empty!(fig)
    end
    
    manager.is_open = false
    manager.master_fig = nothing
    manager.camera_locked[] = false

    # Stop a running animation (its timer would keep driving the sliders of the closed window)
    timer = manager.animation_timer[]
    isnothing(timer) || close(timer)
    manager.animation_timer[] = nothing
    manager.is_animating[] = false
    
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
    
    for k in collect(keys(manager.listeners))
        k === :Simulation || delete!(manager.listeners, k)  # switched off above
    end
    empty!(manager.widgets)  # widgets of the closed window; the caches keep their state
    manager.plot_window_initialized[] = false

    @info "Plotter state completely cleared!"
end

"""
    launch_plotter()

Initializes the main `PDEStudio` interactive interface. 
It constructs the foundational Makie `Figure`, partitions the layout into a control panel and a plot area, wires up the core reactive listeners, and displays the window. Returns the active `Makie.Figure` object.
"""
function launch_plotter()

    reset_plotter!()

    master_fig = Figure()
    ctrl_layout = master_fig[1, 1] = GridLayout()
    plot_layout = master_fig[1, 2] = GridLayout() 
    
    create_controls(ctrl_layout)
    # A configuration bound before launching needs its slider labels and mapping on the new widgets.
    isnothing(manager.active_config) || _map_parameters_to_sliders!(manager.active_config)
    setup_ui_interactions!(master_fig, plot_layout, Val(manager.mode[]))

    manager.is_open = true
    manager.master_fig = master_fig

    setup_plot_window!(master_fig, plot_layout)
    resize_to_layout!(master_fig)
    return master_fig 
end

# =================================
# --- LAYOUT & RENDER HANDLERS ---
# =================================
"""
    setup_plot_window!(master_fig::Figure, plot_layout::GridLayout)

Bootstraps the top-level trigger listeners responsible for layout management. 

This function establishes the core reactive loop that detects when structural changes are needed (e.g., adding comparison columns or changing base plot styles). It handles safely destroying the old sub-layout, preserving the user's camera angles, and injecting the new plot primitives.
"""
function setup_plot_window!(master_fig::Figure, plot_layout::GridLayout)
    if manager.plot_window_initialized[]; return; end
    manager.plot_window_initialized[] = true

    # Store observers globally
    manager.main_render_observers = ObserverFunction[]

    function rebuild_plot_layout!()
        if manager.camera_locked[]
            if manager.skip_next_camera_extract
                manager.skip_next_camera_extract = false
            else
                extract_and_store_camera_state!(plot_layout)
            end
        end

        ptype_sym = manager.widgets[:plot_style].selection[]
        
        sim_data = nothing
        if !isempty(manager.plot_data[])
            sim_data = _get_first_valid(first(values(manager.plot_data[])))
        end

        # Safely clear old observers
        for obs in manager.main_render_observers; off(obs); end
        empty!(manager.main_render_observers)
        empty!(manager.caches)
        
        for c in copy(plot_layout.content)
            if c.content isa Makie.Block; delete!(c.content); end
        end
        trim!(plot_layout)
        
        switch_ui_plot_type!(ptype_sym)
        
        new_obs = setup_render_lift!(master_fig, plot_layout, Val(ptype_sym))
        if !isnothing(new_obs); append!(manager.main_render_observers, new_obs); end
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

"""
    setup_render_lift!(master_fig::Figure, plot_layout::GridLayout, ::Val{T}) where T

The highly orchestrated reactive pipeline that binds UI slider movements directly to the Makie rendering primitives.

# Pipeline Architecture
1. **Initialize Layout:** Constructs the specific axes, sub-plots, and colorbars required by the active plot style `T`.
2. **The Waterfall:** Establishes a strict cascade of hierarchical locks (`:Plot` -> `:Slider` -> `:PlotData` -> `:UI`) to ensure that heavy data-fetching routines only execute once per frame, preventing race conditions and UI stuttering during rapid user interaction.
3. **Cache Synchronization:** Ensures that any manual adjustments made by the user are persistently synced to the global state cache for robust serialization.
"""
function setup_render_lift!(master_fig::Figure, plot_layout::GridLayout, ::Val{T}) where T
    
    # 1. Initialize complete layout structure and unpack necessary state handles
    axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, has_colorbar = _initialize_render_layout!(plot_layout, Val(T))

    # 2. Wire up the top-level trigger pipelines
    manager.listeners[:Plot] = on(manager.triggers[:Plot]) do _
        local success = false
        @with_lock :Plot begin
            try
                success = _handle_plot_trigger!(Val(T), plot_layout, axes, num_plots, compare_labels, x_sel, y_sel, z_sel, u_sel, c_sel, selector_obs, _build_param_indices, _mutate_compare_vals)
            catch e
                # Keep the studio usable: the user can change the style or option that failed and update again.
                @error "Updating the plot failed; the current plot style or options could not be drawn for this data. " *
                       "Change them (e.g. the plot style, colours or levels) and click 'Update Plot' again." exception = (e, catch_backtrace())
                success = false
            end
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
        
        # Sync manual slider drags into the persistent caches
        rev_map = manager.reverse_map
        for k in manager.plot_vars
            w_key = haskey(rev_map, k) ? rev_map[k] : k 
            if haskey(manager.widgets, w_key)
                widget = manager.widgets[w_key]
                # Disabled sliders (range [0.0]: axis or compare target) keep their last real position
                if widget isa Makie.Slider && length(widget.range[]) > 1
                    val = widget.value[]
                    manager.slider_cache[w_key] = Float64(val)
                    manager.plot_cache[k] = val
                end
            end
        end

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