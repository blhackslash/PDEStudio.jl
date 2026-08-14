function _get_template_domain(sim_config::SimulationConfig)
    for m_name in sim_config.active_methods
        if is_reference_method(m_name); continue; end
        
        base_params = IRunPDESims.assemble_params(sim_config.shared_params, sim_config.methods_dict, m_name)
        ik = IRunPDESims.get_ignore_keys(sim_config.methods_dict, m_name)
        
        tasks, _ = generate_method_tasks(base_params, collect(keys(sim_config.varied_params)), collect(values(sim_config.varied_params)); ignore_keys=ik)
        
        if !isempty(tasks)
            try
                # Load via :raw to bypass any resolution requirements
                raw_data = load_sim_data(tasks[1], Val(:raw))
                return raw_data.domain
            catch e
                # THE FIX: Stop failing silently!
                @warn "Failed to load template domain for $m_name." exception=(e, catch_backtrace())
                continue
            end
        end
    end
    
    return nothing
end

function analyze_configuration(sim_config::SimulationConfig)
    all_varied = sim_config.varied_params
    active_keys = Symbol[]
    active_values = Vector{Vector{Any}}()
    for key in sort(collect(keys(all_varied)))
        push!(active_keys, key)
        push!(active_values, all_varied[key])
    end
    return active_keys, active_values
end

"""
    validate_plot_dimensions(sim_data::AbstractSimData)

Checks if the dimension keys of the loaded simulation data are a subset of 
the currently allowed UI dimensions.
"""
function validate_plot_dimensions(sim_data::AbstractSimData)
    allowed = manager.allowed_dims
    actual = sim_data.domain.dim_keys
    
    if !issubset(actual, allowed)
        @warn "Incompatible data loaded. Data dimensions $actual are not a subset of the configured UI dimensions $allowed. Dropping data."
        return false
    end
    return true
end

"""
    get_active_slider_indices(sim_data::AbstractSimData)

Returns a boolean array indicating which of the fixed UI sliders should be enabled 
for the loaded data.
"""
function get_active_slider_indices(sim_data::AbstractSimData)
    allowed = manager.allowed_dims
    actual = sim_data.domain.dim_keys
    return [dim in actual for dim in allowed]
end

"""
    map_sliders_to_tensor(sim_data::AbstractSimData)

Maps the fixed UI slider indices to the dynamic dimension indices of the underlying tensor.
"""
function map_sliders_to_tensor(sim_data::AbstractSimData)
    allowed = manager.allowed_dims
    actual = sim_data.domain.dim_keys
    return ntuple(d -> findfirst(==(actual[d]), allowed), length(actual))
end

function _get_first_valid(pd)
    isempty(pd.data) && return nothing
    valid_data = filter(!isnothing, pd.data)
    return isempty(valid_data) ? nothing : first(valid_data)
end

function _recombine_tuples!(params::Dict)
    tuple_groups = Dict{Symbol, Vector{Pair{Int, Any}}}()
    keys_to_remove = Symbol[]
    
    for (k, v) in params
        k_str = string(k)
        if occursin("__", k_str)
            parts = split(k_str, "__")
            if length(parts) == 2
                base_name = Symbol(parts[1])
                idx_str = parts[2]
                idx = tryparse(Int, idx_str)
                if !isnothing(idx)
                    if !haskey(tuple_groups, base_name)
                        tuple_groups[base_name] = Pair{Int, Any}[]
                    end
                    push!(tuple_groups[base_name], idx => v)
                    push!(keys_to_remove, k)
                end
            end
        end
    end
    
    for k in keys_to_remove
        delete!(params, k)
    end
    
    for (base_name, pairs) in tuple_groups
        sort!(pairs, by = x -> x[1])
        params[base_name] = Tuple(x[2] for x in pairs)
    end
    return params
end

# ==============================================================================
# --- MAIN TENSOR CREATION ROUTINE (Unified) ---
# ==============================================================================

function create_plot_data(method_name::Symbol, base_params::ParamDict, sim_config::SimulationConfig)
    active_keys, active_values = analyze_configuration(sim_config)
    ignore_keys = IRunPDESims.get_ignore_keys(sim_config.methods_dict, method_name)
    
    tasks, grid_indices = generate_method_tasks(base_params, active_keys, active_values; ignore_keys=ignore_keys)
    isempty(tasks) && return nothing

    grid_dims = isempty(active_values) ? (1,) : Tuple(length.(active_values))
    data_store = Array{Union{Nothing, AbstractSimData}, length(grid_dims)}(nothing, grid_dims...)

    is_reference = is_reference_method(method_name)
    domain = _get_template_domain(sim_config)
    mode = Val(manager.mode[])

    for (k, params) in enumerate(tasks)
        _recombine_tuples!(params)
        
        sim_data = if is_reference && !isnothing(domain)
            IRunPDESims.generate_reference_simdata(sim_config.reference_func, params, domain, build_res_tuple(domain.dim_keys; is_ref=true), mode)
        
        elseif !isnothing(domain) # THE FIX: Explicitly protect domain.dim_keys
            try 
                if mode === Val(:eulerian)
                    load_sim_data(params, mode, build_res_tuple(domain.dim_keys; is_ref=false)) 
                else
                    load_sim_data(params, mode)
                end
            catch
                # Silently catch disk misses (perfectly normal if simulation hasn't run yet)
                nothing 
            end
        else
            nothing
        end
        
        if !isnothing(sim_data) && validate_plot_dimensions(sim_data)
            dest_prefix = isempty(grid_indices[k]) ? (1,) : grid_indices[k]
            data_store[dest_prefix...] = sim_data
        end
    end

    return PlotSweepData{length(grid_dims)}(data_store, active_keys, active_values)
end

# ==============================================================================
# --- DATA EXTRACTION (On-The-Fly Cross-Plotting) ---
# ==============================================================================
function extract_eulerian_data(pd::PlotSweepData, param_indices, sel_vals, plot_vars, active_plot_axes::Vector{Symbol}, u_key::Symbol, target_c)
    valid_sims = filter(!isnothing, pd.data)
    isempty(valid_sims) && return nothing
    ref_sim = first(valid_sims)
    
    active_loop_dims = Symbol[]
    plot_axes_data = Any[]
    ax_lengths = Int[]
    
    # 1. Parse Substitutes and Build Target Axes
    for ax_sym in active_plot_axes
        ax_str = string(ax_sym)
        stat_name, loop_dim_str = occursin("|", ax_str) ? String.(split(ax_str, "|")) : (ax_str, ax_str)
        loop_dim = Symbol(loop_dim_str)
        push!(active_loop_dims, loop_dim)
        
        if stat_name == loop_dim_str
            # Standard Parameter or Physical Dimension lookup
            p_idx = findfirst(isequal(loop_dim), pd.active_param_keys)
            if !isnothing(p_idx)
                push!(plot_axes_data, pd.active_param_values[p_idx])
                push!(ax_lengths, length(pd.active_param_values[p_idx]))
            else
                d_idx = findfirst(==(loop_dim), ref_sim.domain.dim_keys)
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
        
        tensor = get(sim_data.stats, u_key, nothing)
        isnothing(tensor) && continue
        
        tensor_dim_syms = Tuple(IRunPDESims.get_kept_dims(u_key, sim_data.domain))
        
        in_bounds = true
        
        # THE FIX: If there are no spatial dimensions, it's a pure scalar stat. 
        # Bypass spatial unpacking completely!
        if isempty(tensor_dim_syms)
            u_raw = tensor isa AbstractArray ? first(tensor) : tensor
        else
            tensor_indices = ntuple(length(tensor_dim_syms)) do d
                dim_sym = tensor_dim_syms[d]
                out_idx = findfirst(isequal(dim_sym), active_loop_dims) 
                
                if !isnothing(out_idx)
                    idx = I[out_idx]
                    if idx > size(tensor, d); in_bounds = false; return 1; end
                    return idx
                else
                    # Direct Symbol-to-Symbol lookup!
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
            end
        end
        
        if in_bounds
            u_out[I] = target_c isa Integer ? Float64(u_raw[target_c]) : Float64(u_raw[1])
        end
    end
    
    return Tuple(plot_axes_data), u_out
end
function extract_lagrangian_data(pd::PlotSweepData, param_indices, sel_vals, plot_vars, u_key::Symbol, target_c)
    sim_data = pd.data[param_indices...]
    isnothing(sim_data) && return nothing
    
    tensor = get(sim_data.stats, u_key, nothing)
    isnothing(tensor) && return nothing
    
    time_dim = sim_data.domain.time_dim
    ui_time_idx = findfirst(isequal(time_dim), plot_vars) 
    
    if !isnothing(ui_time_idx) && !isempty(sim_data.t)
        target_t = sel_vals[ui_time_idx]
        t_idx = findmin(v -> abs(v - target_t), sim_data.t)[2]
    else
        t_idx = 1
    end
    
    if tensor isa AbstractVector && eltype(tensor) <: AbstractVector
        u_raw = tensor[t_idx]
    elseif tensor isa AbstractVector && eltype(tensor) <: SVector
        u_raw = tensor
    else
        u_raw = tensor
    end
    
    u_flat = target_c isa Integer ? map(v -> Float64(v[target_c]), u_raw) : map(v -> Float64(v[1]), u_raw)
    
    # THE FIX: Map natively to Makie Point types!
    x_step = sim_data.x[t_idx]
    DS = length(x_step[1])
    
    if DS == 1
        pts = Float64[Float64(p[1]) for p in x_step]
    elseif DS == 2
        pts = Point2f[Point2f(p[1], p[2]) for p in x_step]
    else
        pts = Point3f[Point3f(p[1], p[2], p[3]) for p in x_step]
    end
    
    return pts, u_flat
end

function update_plot_data_collection!(plot_data_dict, sim_config, active_methods; force_reload=false)
    if force_reload; empty!(plot_data_dict); end
    for m_name in active_methods
        if !haskey(plot_data_dict, m_name)
            base_params = IRunPDESims.assemble_params(sim_config.shared_params, sim_config.methods_dict, m_name)
            new_data = create_plot_data(m_name, base_params, sim_config)
            if !isnothing(new_data); plot_data_dict[m_name] = new_data; end
        end
    end
    # Ensure keys to delete are cast to String to match the internal Plot Data Dict Keys
    for k in keys(plot_data_dict)
        if !(Symbol(k) in active_methods); delete!(plot_data_dict, k); end
    end
    return plot_data_dict
end
function fetch_pipeline_tuples(::Val{:eulerian}, data, local_methods, _build_param_indices, mutated_sel_vals, x_sel, y_sel, z_sel, u_sel, target_c_int)
    active_plot_axes_syms = filter(s -> !isnothing(s) && s !== :none, [x_sel[], y_sel[], z_sel[]])
    ax_cols = [Any[] for _ in 1:length(active_plot_axes_syms)]
    u_col = Any[]
    
    # FIX: Initialize as a Symbol array
    valid_methods = Symbol[] 

    for m_name in local_methods
        # FIX: Check the data dictionary natively using the Symbol
        !haskey(data, m_name) && continue
        pd = data[m_name]
        p_idx = _build_param_indices(pd, mutated_sel_vals)
        
        res = extract_eulerian_data(pd, p_idx, mutated_sel_vals, manager.plot_vars, active_plot_axes_syms, u_sel[], target_c_int)
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
    
    pts_col = Any[]
    u_col = Any[]
    valid_methods = Symbol[]
    
    for m_name in local_methods
        !haskey(data, m_name) && continue
        pd = data[m_name]
        p_idx = _build_param_indices(pd, mutated_sel_vals)
        
        res = extract_lagrangian_data(pd, p_idx, mutated_sel_vals, manager.plot_vars, u_sel[], target_c_int)
        if !isnothing(res)
            pts, u_flat = res
            push!(pts_col, pts)
            push!(u_col, u_flat)
            push!(valid_methods, m_name)
        end
    end
    # Lagrangian is ALWAYS length 2: (Points, U)
    return (pts_col, u_col), valid_methods
end