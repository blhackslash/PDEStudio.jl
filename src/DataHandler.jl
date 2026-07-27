function _get_template_simdata(sim_config::SimulationConfig)
    for (m_name, params) in sim_config.methods_dict
        if is_reference_method(m_name); continue; end
        base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
        ik = IRunPDESims.get_ignore_keys(sim_config.methods_dict, m_name)
        
        # Backend still requires an empty ParamDict for sim_fixes[cite: 18]
        tasks, _ = generate_method_tasks(base_params, collect(keys(sim_config.varied_params)), collect(values(sim_config.varied_params)), ParamDict(); ignore_keys=ik)
        
        if !isempty(tasks)
            try
                return loadSimData(tasks[1],Val(PLOT_MODE[]))
            catch
            end
        end
    end
    return nothing
end

function analyze_configuration(sim_config::SimulationConfig)
    all_varied = sim_config.varied_params
    active_keys = String[]
    active_values = Vector{Vector{Any}}()
    for key in sort(collect(keys(all_varied)))
        push!(active_keys, key)
        push!(active_values, all_varied[key])
    end
    return active_keys, active_values
end

# ==============================================================================
# --- MAIN TENSOR CREATION ROUTINE (Unified) ---
# ==============================================================================

function create_plot_data(method_name::String, base_params::ParamDict, sim_config::SimulationConfig)
    active_keys, active_values = analyze_configuration(sim_config)
    ignore_keys = IRunPDESims.get_ignore_keys(sim_config.methods_dict, method_name)
    
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values, ParamDict(); ignore_keys=ignore_keys)
    isempty(tasks) && return nothing

    grid_dims = isempty(active_values) ? (1,) : Tuple(length.(active_values))
    data_store = Array{Union{Nothing, AbstractSimData}, length(grid_dims)}(nothing, grid_dims...)

    is_reference = is_reference_method(method_name)
    base_template = _get_template_simdata(sim_config)

    for (k, params) in enumerate(tasks)
        _recombine_tuples!(params)
        
        sim_data = if is_reference && !isnothing(base_template)
            IRunPDESims.generate_reference_simdata(sim_config.reference_func, params, base_template)
        else
            try loadSimData(params, Val(PLOT_MODE[])) catch e; nothing end
        end
        
        if !isnothing(sim_data) && validate_plot_dimensions(sim_data)
            dest_prefix = isempty(grid_indices[k]) ? (1,) : grid_indices[k]
            data_store[dest_prefix...] = sim_data
        end
    end

    # Return PlotSweepData without fixed_params[cite: 18]
    return PlotSweepData{length(grid_dims)}(data_store, active_keys, active_values)
end

# ==============================================================================
# --- DATA EXTRACTION (On-The-Fly Cross-Plotting) ---
# ==============================================================================
function extract_eulerian_data(pd::PlotSweepData, param_indices, sel_vals, plot_vars, active_plot_axes, u_key, target_c)
    valid_sims = filter(!isnothing, pd.data)
    isempty(valid_sims) && return nothing
    ref_sim = first(valid_sims)
    
    active_loop_dims = String[]
    plot_axes_data = Any[]
    ax_lengths = Int[]
    
    # 1. Parse Substitutes and Build Target Axes
    for ax_str in active_plot_axes
        stat_name, loop_dim = occursin("|", ax_str) ? String.(split(ax_str, "|")) : (ax_str, ax_str)
        push!(active_loop_dims, loop_dim)
        
        if stat_name == loop_dim
            # Standard Parameter or Physical Dimension lookup
            p_idx = findfirst(isequal(loop_dim), pd.active_param_keys)
            if !isnothing(p_idx)
                push!(plot_axes_data, pd.active_param_values[p_idx])
                push!(ax_lengths, length(pd.active_param_values[p_idx]))
            else
                d_idx = findfirst(==(Symbol(loop_dim)), ref_sim.domain.dim_keys)
                if !isnothing(d_idx)
                    push!(plot_axes_data, ref_sim.axes[d_idx])
                    push!(ax_lengths, length(ref_sim.axes[d_idx]))
                else
                    push!(plot_axes_data, [0.0]); push!(ax_lengths, 1)
                end
            end
        else
            # Substitute Statistic Lookup (e.g. Runtime over N)
            stat_vec = Float64[]
            p_idx = findfirst(isequal(loop_dim), pd.active_param_keys)
            
            # THE FIX: Cast the string to a Symbol for dictionary lookups
            sym_stat = Symbol(stat_name)
            
            if !isnothing(p_idx)
                for i in 1:length(pd.active_param_values[p_idx])
                    curr_p = Any[param_indices...]
                    curr_p[p_idx] = i
                    sim = pd.data[curr_p...]
                    val = isnothing(sim) || !haskey(sim.stats, sym_stat) ? NaN : Float64(sim.stats[sym_stat][1])
                    push!(stat_vec, val)
                end
            else
                sim = pd.data[param_indices...]
                if isnothing(sim) || !haskey(sim.stats, sym_stat)
                    push!(stat_vec, NaN)
                else
                    append!(stat_vec, map(v -> Float64(v[1]), sim.stats[sym_stat]))
                end
            end
            push!(plot_axes_data, stat_vec)
            push!(ax_lengths, length(stat_vec))
        end
    end
    
    u_out = Array{Float64}(undef, Tuple(ax_lengths)...)
    fill!(u_out, NaN)
    
    # 2. Populate Point-by-Point mapping against `active_loop_dims`
    for I in CartesianIndices(u_out)
        curr_param_idx = Any[param_indices...]
        for (dim_out, loop_dim) in enumerate(active_loop_dims)
            p_idx = findfirst(isequal(loop_dim), pd.active_param_keys)
            if !isnothing(p_idx)
                curr_param_idx[p_idx] = I[dim_out]
            end
        end
        
        sim_data = pd.data[curr_param_idx...]
        isnothing(sim_data) && continue
        
        sym_u_key = Symbol(u_key)
        
        tensor = get(sim_data.stats, sym_u_key, nothing)
        isnothing(tensor) && continue
        
        tensor_dim_syms = Tuple(IRunPDESims.get_kept_dims(sym_u_key, sim_data.domain))
        
        in_bounds = true
        # Inside extract_eulerian_data:
        tensor_indices = ntuple(ndims(tensor)) do d
            dim_sym = tensor_dim_syms[d]
            out_idx = findfirst(isequal(String(dim_sym)), active_loop_dims) # active_loop_dims is String[]
            
            if !isnothing(out_idx)
                idx = I[out_idx]
                if idx > size(tensor, d); in_bounds = false; return 1; end
                return idx
            else
                # --- THE FIX: Direct Symbol-to-Symbol lookup! ---
                var_idx = findfirst(isequal(dim_sym), plot_vars) 
                if isnothing(var_idx); in_bounds = false; return 1; end
                
                target_val = sel_vals[var_idx]
                axis_idx = findfirst(==(dim_sym), sim_data.domain.dim_keys)
                idx = findmin(v -> abs(v - target_val), sim_data.axes[axis_idx])[2]
                if idx > size(tensor, d); in_bounds = false; return 1; end
                return idx
            end
        end
        
        if in_bounds
            u_raw = tensor[tensor_indices...]
            u_out[I] = target_c isa Integer ? Float64(u_raw[target_c]) : Float64(u_raw[1])
        end
    end
    
    return Tuple(plot_axes_data), u_out
end

function extract_lagrangian_data(pd::PlotSweepData, param_indices, sel_vals, plot_vars, u_key, target_c)
    sim_data = pd.data[param_indices...]
    isnothing(sim_data) && return nothing
    
    tensor = get(sim_data.stats, Symbol(u_key), nothing)
    isnothing(tensor) && return nothing
    
    time_dim = sim_data.domain.time_dim
    
    # Direct Symbol-to-Symbol lookup
    ui_time_idx = findfirst(isequal(time_dim), plot_vars) 
    
    if !isnothing(ui_time_idx) && !isempty(sim_data.t)
        target_t = sel_vals[ui_time_idx]
        t_idx = findmin(v -> abs(v - target_t), sim_data.t)[2]
    else
        t_idx = 1
    end
    
    # THE FIX: Differentiate Nested Transient vs Flat Static Arrays
    if tensor isa AbstractVector && eltype(tensor) <: AbstractVector
        u_raw = tensor[t_idx]
    elseif tensor isa AbstractVector && eltype(tensor) <: SVector
        u_raw = tensor
    else
        u_raw = tensor
    end
    
    u_flat = target_c isa Integer ? map(v -> Float64(v[target_c]), u_raw) : map(v -> Float64(v[1]), u_raw)
    
    # THE FIX: Map SVector coordinates to a clean Tuple of Float64 Vectors
    x_step = sim_data.x[t_idx]
    DS = length(x_step[1])
    p_axes = ntuple(d -> map(p -> Float64(p[d]), x_step), Val(DS))
    
    return p_axes, u_flat
end
function update_plot_data_collection!(plot_data_dict, sim_config, active_methods; force_reload=false)
    if force_reload; empty!(plot_data_dict); end
    for m_name in active_methods
        if !haskey(plot_data_dict, m_name)
            base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, m_name)
            new_data = create_plot_data(m_name, base_params, sim_config)
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    for k in keys(plot_data_dict)
        if !(k in active_methods); delete!(plot_data_dict, k); end
    end
    return plot_data_dict
end