function _get_template_simdata(sim_config::SimulationConfig, fixed_params::Dict)
    for (m_name, params) in sim_config.methods_dict
        if contains(safe_string(m_name), "analytic") || contains(safe_string(m_name), "reference"); continue; end
        
        base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
        ik = IRunPDESims.get_ignore_keys(sim_config.methods_dict, m_name)
        tasks, _ = generate_method_tasks(base_params, collect(keys(sim_config.varied_params)), collect(values(sim_config.varied_params)), fixed_params; ignore_keys=ik)
        
        if !isempty(tasks)
            try
                return loadSimData(tasks[1],Val(PLOT_MODE[]))
            catch
            end
        end
    end
    return nothing
end

function analyze_configuration(sim_config::SimulationConfig, fixed_params::FixedDict)
    all_varied = sim_config.varied_params
    active_keys = String[]
    active_values = Vector{Vector{Any}}()
    sorted_keys = sort(collect(keys(all_varied)))
    sim_fixes = FixedDict()

    for key in sorted_keys
        push!(active_keys, key)
        push!(active_values, all_varied[key])
    end

    for (k, v) in fixed_params
        if !(k in get_base_variables()) && !(k in sorted_keys)
            sim_fixes[k] = v
        end
    end

    return active_keys, active_values, sim_fixes
end

# ==============================================================================
# --- MAIN TENSOR CREATION ROUTINE (Unified) ---
# ==============================================================================

function create_plot_data(
    method_name::String, 
    base_params::ParamDict,
    sim_config::SimulationConfig, 
    fixed_params::FixedDict
)
    active_keys, active_values, sim_fixes = analyze_configuration(sim_config, fixed_params)
    
    ignore_keys = IRunPDESims.get_ignore_keys(sim_config.methods_dict, method_name)
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, sim_fixes; ignore_keys=ignore_keys)
    isempty(tasks) && return nothing

    grid_dims = isempty(active_values) ? (1,) : Tuple(length.(active_values))
    data_store = Array{Union{Nothing, AbstractSimData}, length(grid_dims)}(nothing, grid_dims...)

    is_reference = contains(safe_string(method_name), "analytic") || contains(safe_string(method_name), "reference")
    base_template = _get_template_simdata(sim_config, sim_fixes)

    for (k, params) in enumerate(tasks)
        _recombine_tuples!(params)
        
        sim_data = if is_reference && !isnothing(base_template)
            IRunPDESims.generate_reference_simdata(sim_config.reference_func, params, base_template)
        else
            try loadSimData(params, Val(PLOT_MODE[])) catch; nothing end
        end
        
        if !isnothing(sim_data) && validate_plot_dimensions(sim_data)
            dest_prefix = isempty(grid_indices[k]) ? (1,) : grid_indices[k]
            data_store[dest_prefix...] = sim_data
        end
    end

    return PlotSweepData{length(grid_dims)}(data_store, active_keys, active_values, fixed_params)
end

# ==============================================================================
# --- DATA EXTRACTION (On-The-Fly Cross-Plotting) ---
# ==============================================================================

function extract_eulerian_data(pd::PlotSweepData, param_indices, sel_vals, plot_vars, active_plot_axes, u_key, target_c)
    valid_sims = filter(!isnothing, pd.data)
    isempty(valid_sims) && return nothing
    ref_sim = first(valid_sims)
    
    plot_axes_data = Any[]
    ax_lengths = Int[]
    
    # 1. Build Target Axes
    for ax_str in active_plot_axes
        p_idx = findfirst(isequal(ax_str), pd.active_param_keys)
        if !isnothing(p_idx)
            push!(plot_axes_data, pd.active_param_values[p_idx])
            push!(ax_lengths, length(pd.active_param_values[p_idx]))
        else
            d_idx = findfirst(==(Symbol(ax_str)), ref_sim.domain.dim_keys)
            if !isnothing(d_idx)
                push!(plot_axes_data, ref_sim.axes[d_idx])
                push!(ax_lengths, length(ref_sim.axes[d_idx]))
            else
                push!(plot_axes_data, [0.0])
                push!(ax_lengths, 1)
            end
        end
    end
    
    u_out = Array{Float64}(undef, Tuple(ax_lengths)...)
    fill!(u_out, NaN)
    
    # 2. Populate Point-by-Point
    for I in CartesianIndices(u_out)
        curr_param_idx = Any[param_indices...]
        for (dim_out, ax_str) in enumerate(active_plot_axes)
            p_idx = findfirst(isequal(ax_str), pd.active_param_keys)
            if !isnothing(p_idx)
                curr_param_idx[p_idx] = I[dim_out]
            end
        end
        
        sim_data = pd.data[curr_param_idx...]
        isnothing(sim_data) && continue
        
        target_tensor = get(sim_data.stats, u_key, nothing)
        isnothing(target_tensor) && return nothing

        # Look up native dimensions securely using the local registry!
        tensor_dim_syms = Tuple(get_kept_dims(Symbol(u_key), sim_data.domain.dim_keys, sim_data.domain.stat_registry))
        
        tensor_indices = ntuple(ndims(tensor)) do d
            dim_str = string(tensor_dim_syms[d])
            out_idx = findfirst(isequal(dim_str), active_plot_axes)
            
            if !isnothing(out_idx)
                return I[out_idx] # Dimension is actively plotted, use loop index
            else
                var_idx = findfirst(isequal(dim_str), plot_vars)
                if isnothing(var_idx); return 1; end
                
                target_val = sel_vals[var_idx]
                axis_idx = findfirst(==(tensor_dim_syms[d]), sim_data.domain.dim_keys)
                return findmin(v -> abs(v - target_val), sim_data.axes[axis_idx])[2]
            end
        end
        
        u_raw = tensor[tensor_indices...]
        u_out[I] = target_c isa Integer ? Float64(u_raw[target_c]) : Float64(u_raw[1])
    end
    
    return Tuple(plot_axes_data), u_out
end

function extract_lagrangian_data(pd::PlotSweepData, param_indices, sel_vals, plot_vars, u_key, target_c)
    sim_data = pd.data[param_indices...]
    isnothing(sim_data) && return nothing
    
    tensor = get(sim_data.stats, u_key, nothing)
    isnothing(tensor) && return nothing
    
    time_str = string(LAGRANGIAN_TIME_DIM[])
    ui_time_idx = findfirst(isequal(time_str), plot_vars)
    
    if !isnothing(ui_time_idx) && !isempty(sim_data.t)
        target_t = sel_vals[ui_time_idx]
        t_idx = findmin(v -> abs(v - target_t), sim_data.t)[2]
    else
        t_idx = 1
    end
    
    x_step = sim_data.x[t_idx]
    u_raw = tensor isa AbstractArray && ndims(tensor) == 1 ? tensor : tensor[t_idx]
    u_flat = target_c isa Integer ? map(v -> Float64(v[target_c]), u_raw) : map(v -> Float64(v[1]), u_raw)
    
    return x_step, u_flat
end

function update_plot_data_collection!(plot_data_dict, sim_config, manager::PlotManager, active_methods; force_reload=false)
    if force_reload; empty!(plot_data_dict); end
    
    for m_name in active_methods
        if !haskey(plot_data_dict, m_name)
            base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
            if isempty(base_params); continue end
            
            shared_ui = ParamDict(k => v[] for (k, v) in manager.simulation["shared"])
            method_ui = haskey(manager.simulation, m_name) ? ParamDict(k => v[] for (k, v) in manager.simulation[m_name]) : ParamDict()
            
            fixed_params = ParamDict()
            for (k, v) in shared_ui; k == "ignore" && continue; fixed_params[k] = v; end
            for (k, v) in method_ui; k == "ignore" && continue; fixed_params[k] = v; end
            
            new_data = Base.invokelatest(create_plot_data, m_name, base_params, sim_config, fixed_params)
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    
    for k in keys(plot_data_dict)
        if !(k in active_methods)
            delete!(plot_data_dict, k)
        end
    end
    
    return plot_data_dict
end