function is_reference_method(m_name::Symbol)
    lm = lowercase(String(m_name))
    return any(k -> occursin(k, lm), ["analytic", "reference", "exact", "baseline", "true"])
end

"""
    run_smart_simulation(sim_func::Function, params::ParamDict; force_overwrite::Bool=false)

Smart wrapper for single simulations. Checks if `SimData` already exists on disk.
If it does (and `force_overwrite` is false), it skips execution and returns `NoSimData`.
Otherwise, it executes the simulation, saves the result, and returns the data.
"""
function run_smart_simulation(sim_func::Function, params::ParamDict; force_overwrite::Bool=false)
    if !force_overwrite && does_sim_data_exist(params)
        return NoSimData()
    end
    # Run the actual simulation
    sim_data = sim_func(params)
    
    if !isnothing(sim_data)
        save_sim_data(sim_data; overwrite=true)
    end
    
    return sim_data
end

"""
    generate_method_tasks(base_params, active_keys, active_values; ignore_keys=Symbol[])

Generates the parameter grid for a simulation sweep. Dynamically reconstructs 
dimensional identifiers (e.g., Ns__x, Ns__1) back into their base Tuple (e.g., Ns = (val1, val2)).
"""
function generate_method_tasks(base_params::ParamDict, active_keys::Vector{Symbol}, active_values::Vector; ignore_keys::Vector{Symbol}=Symbol[])
    
    processed_base = copy(base_params)

    # --- 1. Pre-parse Varied Parameters (Active Keys) ---
    # Regex parsing is slow! We only do it once here instead of N times in the grid.
    varied_std = Tuple{Int, Symbol}[]       # Stores: (index_in_pvals, key)
    varied_tup = Tuple{Int, Symbol, Int}[]  # Stores: (index_in_pvals, base_name, tuple_idx)
    
    for (i, k) in enumerate(active_keys)
        k in ignore_keys && continue
        
        # Convert Symbol to String strictly for the Regex match
        m = match(r"^(.+)__([a-zA-Z0-9]+)$", String(k))
        if !isnothing(m)
            base = Symbol(m.captures[1])
            base in ignore_keys && continue
            idx_str = m.captures[2]
            idx = (idx_str == "x" || idx_str == "1") ? 1 :
                  (idx_str == "y" || idx_str == "2") ? 2 :
                  (idx_str == "z" || idx_str == "3") ? 3 : tryparse(Int, idx_str)
            
            if !isnothing(idx)
                push!(varied_tup, (i, base, idx))
                continue
            end
        end
        push!(varied_std, (i, k))
    end

    # --- 2. Grid Generation ---
    if isempty(active_values)
        param_grid = [()]
    else
        param_grid = collect(Iterators.product(active_values...))
    end
    
    tasks, grid_indices = Vector{ParamDict}(), Vector{Tuple}()

    for (linear_idx, p_vals) in enumerate(param_grid)
        task_params = copy(processed_base)
        
        # Apply Standard Varied Parameters
        for (i, k) in varied_std
            # User's Safety Skip: Only update if it exists in base
            !haskey(task_params, k) && continue 
            task_params[k] = p_vals[i]
        end
        
        # Apply Tuple Varied Parameters
        if !isempty(varied_tup)
            tup_updates = Dict{Symbol, Vector{Any}}()
            
            for (i, base, idx) in varied_tup
                # User's Safety Skip applied directly to the resolved base tuple
                !haskey(task_params, base) && continue 
                
                if !haskey(tup_updates, base)
                    tup_updates[base] = collect(Any, task_params[base])
                end
                
                arr = tup_updates[base]
                while length(arr) < idx; push!(arr, 0.0); end
                arr[idx] = p_vals[i]
            end
            
            for (base, arr) in tup_updates
                task_params[base] = all(x -> x isa Integer, arr) ? Tuple(Int.(arr)) : Tuple(arr)
            end
        end
        
        indices = isempty(active_values) ? () : Tuple(CartesianIndices(param_grid)[linear_idx])
        push!(tasks, task_params)
        push!(grid_indices, indices)
    end
    
    return tasks, grid_indices
end

"""
    get_ignore_keys(method_collection::MethodDict, method_name::Symbol)

Safely extracts the list of keys a specific method wishes to ignore.
"""
function get_ignore_keys(method_collection::MethodDict, method_name::Symbol)
    method_dict = get(method_collection, method_name, ParamDict())
    raw_ignore = get(method_dict, :ignore, Symbol[])
    
    if raw_ignore isa AbstractVector || raw_ignore isa Tuple
        return Symbol.(raw_ignore)
    elseif raw_ignore isa AbstractString || raw_ignore isa Symbol
        return [Symbol(raw_ignore)]
    else
        return Symbol[]
    end
end

"""
    assemble_params(shared_params::ParamDict, method_collection::MethodDict, method_name::Symbol)

Backend version: Constructs a flat parameter dictionary for a simulation run by combining
shared parameters and method-specific parameters.
"""
function assemble_params(
    shared_params::ParamDict,
    method_collection::MethodDict,
    method_name::Symbol
)::ParamDict

    method_dict = get(method_collection, method_name, ParamDict())
    ignore_keys = get_ignore_keys(method_collection, method_name)
    
    current_params = ParamDict()
    
    # 1. Add shared parameters (skipping ignored ones)
    for (key, val) in shared_params
        key in ignore_keys && continue
        
        if val isa Tuple && length(val) == 2 && val[1] === :const
            current_params[key] = val[2]
        else
            current_params[key] = val
        end
    end

    # 2. Add/Override with method-specific parameters
    for (key, val) in method_dict
        key === :ignore && continue 
        if val isa Tuple && length(val) == 2 && val[1] === :const
            current_params[key] = val[2]
        else
            current_params[key] = val
        end
    end
    return current_params
end

"""
    run_all_simulations(sim_config::SimulationConfig; kwargs...)

Executes all simulations defined in a `SimulationConfig`. 
Perfect for headless execution without UI overhead.
"""
function run_all_simulations(
    sim_config::SimulationConfig;
    force_overwrite::Bool = false,
    calculate_stats::Bool = false,
    post_process::Bool = true,
    parallel::Bool = false
)
    @info "Started Simulation Pipeline."
    varied_params = sim_config.varied_params
    active_methods = sim_config.active_methods

    active_keys = collect(keys(varied_params))
    active_values = collect(values(varied_params))
    
    # 1. Generate all parameter combinations
    all_tasks = Vector{ParamDict}()
    for method in active_methods
        if is_reference_method(method); continue; end
        base_params = assemble_params(sim_config.shared_params, sim_config.methods_dict, method)
        ignore_keys = get_ignore_keys(sim_config.methods_dict, method)
        tasks, _ = generate_method_tasks(base_params, active_keys, active_values; ignore_keys=ignore_keys)
        append!(all_tasks, tasks)
    end
    
    num_tasks = length(all_tasks)
    if num_tasks == 0
        @info "No numerical simulations generated to run."
        return 
    end
    
    @info "Pass 1: Executing $num_tasks simulations (Parallel: $parallel)..."
    p = Progress(num_tasks; desc="Running Simulations...")
    counter = Threads.Atomic{Int}(0)
    
    # Run loop strictly iterating over the parameters
    if parallel
        Threads.@threads for params in all_tasks
            try
                run_smart_simulation(sim_config.simulation_func, params; force_overwrite=force_overwrite)
            catch e
                @error "Simulation Thread Error" exception=(e, catch_backtrace())
            end
            Threads.atomic_add!(counter, 1)
            ProgressMeter.update!(p, counter[])
        end
    else
        for params in all_tasks
            run_smart_simulation(sim_config.simulation_func, params; force_overwrite=force_overwrite)
            counter[] += 1
            ProgressMeter.update!(p, counter[])
        end
    end
    
    # Pass 2: Calculate Statistics
    if calculate_stats
        @info "Pass 2: Calculating Stats"
        p2 = Progress(num_tasks; desc="Calculating Stats...")
        counter2 = Threads.Atomic{Int}(0)
        
        # Standard required stats (ignores derived stats and :Solution)
        standard_req_stats = filter(k -> k !== :Solution, collect(keys(STAT_REGISTRY)))
        
        for params in all_tasks
            # --- FAST METADATA CHECK ---
            if !force_overwrite
                file_path = try get_file_name(params) catch; "" end
                if !isempty(file_path)
                    needs_stats = jldopen(file_path, "r") do f
                        if haskey(f, "stat_keys")
                            saved_keys = f["stat_keys"]
                            # Returns true if ANY required stat is missing
                            return any(k -> !(k in saved_keys), standard_req_stats)
                        end
                        return true # Fallback if metadata is missing
                    end
                    
                    # If all standard stats are present, instantly skip to the next file!
                    if !needs_stats
                        counter2[] += 1
                        ProgressMeter.update!(p2, counter2[])
                        continue
                    end
                end
            end
            
            # --- SLOW PATH: Only loads if stats are actually missing ---
            sim_data = load_sim_data(params, Val(:raw))
            if !(sim_data isa NoSimData)  
                calculate_all_stats!(sim_data, sim_config.reference_func; force_overwrite=force_overwrite)
            end
            counter2[] += 1
            ProgressMeter.update!(p2, counter2[])
        end
    end
    
    # Pass 3: Custom Post-Processing
    if post_process
        @info "Pass 3: Custom Post-Processing"
        p3 = Progress(num_tasks; desc="Post-processing...")
        counter3 = Threads.Atomic{Int}(0)
        
        for params in all_tasks
            sim_data = load_sim_data(params, Val(:raw))
            if !(sim_data isa NoSimData)
                
                # Execute the custom function 
                changed = sim_config.post_process_func(sim_data)
                
                # Overwrite on disk only if the user function returns true
                if changed
                    save_sim_data(sim_data; overwrite=true)
                end
                
            end
            counter3[] += 1
            ProgressMeter.update!(p3, counter3[])
        end
    end
    
    @info "Batch simulation run complete!"
    return
end

# ==============================================================================
# --- REFERENCE GENERATORS ---
# ==============================================================================

function generate_reference_simdata(
    ref_func::Function, 
    params::ParamDict, 
    template_domain::DomainInfo{D, T},
    res::NTuple{D, Int},
    ::Val{:eulerian}
) where {D, T}
    
    # Dynamically infer Spatial Dimensions (DS)
    DS = isnothing(template_domain.time_dim) ? D : D - 1
    
    # 1. Build axes dynamically from the explicit res tuple
    axes_list = ntuple(Val(D)) do d
        collect(range(template_domain.mins[d], template_domain.maxs[d], length=res[d]))
    end
    
    # 2. Evaluate one spacetime point to find the number of components (M_ref)
    sample_st = SVector{D, T}(ntuple(d -> axes_list[d][1], Val(D)))
    M_ref = length(ref_func(sample_st))
    
    # 3. Allocate the generalized Spacetime tensor
    u_exact = Array{SVector{M_ref, T}, D}(undef, res...)
    
    # 4. Evaluate the exact function on the fly using multithreading
    Threads.@threads for idx in CartesianIndices(res)
        st = SVector{D, T}(ntuple(d -> axes_list[d][idx[d]], Val(D)))
        u_exact[idx] = SVector{M_ref, T}(ref_func(st))
    end
    
    # Safely compute spacings using the explicit resolution
    spacing = SVector{D, T}(ntuple(d -> res[d] > 1 ? (template_domain.maxs[d] - template_domain.mins[d]) / T(res[d] - 1) : one(T), Val(D)))
    
    ref_domain = DomainInfo{D, T}(template_domain.dim_keys, template_domain.mins, template_domain.maxs, spacing, template_domain.time_dim, template_domain.stat_registry)
    
    ram_data = ESimData{D, DS, M_ref, T}(params, ref_domain, axes_list, u_exact, StatDict{M_ref, T}(:Solution => u_exact))
    
    return ram_data
end
function generate_reference_simdata(
    ref_func::Function, 
    params::ParamDict, 
    template_domain::DomainInfo{D, T},
    res::NTuple{D, Int},
    ::Val{:lagrangian}
) where {D, T}
    
    t_dim_idx = get_time_dim(template_domain)
    DS = isnothing(t_dim_idx) ? D : D - 1
    
    # 1. Extract spatial and temporal resolutions from the unified res tuple
    s_shape = isnothing(t_dim_idx) ? res : ntuple(d -> res[d < t_dim_idx ? d : d+1], Val(DS))
    T_len = isnothing(t_dim_idx) ? 1 : res[t_dim_idx]
    
    # 2. Build spatial axes and static particles
    s_axes = ntuple(d -> collect(range(template_domain.mins[d], template_domain.maxs[d], length=s_shape[d])), Val(DS))
    
    static_particles = vec([SVector{DS, T}(ntuple(d -> s_axes[d][idx[d]], Val(DS))) 
                            for idx in CartesianIndices(s_shape)])
    
    # Temporal constraints
    t_vec = D > DS ? collect(range(template_domain.mins[t_dim_idx], template_domain.maxs[t_dim_idx], length=T_len)) : T[0.0]
    
    x_ref = [copy(static_particles) for _ in 1:T_len]
    
    # 3. Pack a sample point to infer M_ref
    sample_st = D > DS ? SVector{D, T}(static_particles[1]..., t_vec[1]) : SVector{D, T}(static_particles[1])
    M_ref = length(ref_func(sample_st))
    
    u_ref = Vector{Vector{SVector{M_ref, T}}}(undef, T_len)
    
    # 4. Evaluate using multithreading
    Threads.@threads for t_idx in 1:T_len
        t_val = t_vec[t_idx]
        if D > DS
            u_ref[t_idx] = [SVector{M_ref, T}(ref_func(SVector{D, T}(pos..., t_val))) for pos in static_particles]
        else
            u_ref[t_idx] = [SVector{M_ref, T}(ref_func(SVector{D, T}(pos))) for pos in static_particles]
        end
    end
    
    # Safely compute spacings using the unified tuple
    spacing = SVector{D, T}(ntuple(d -> res[d] > 1 ? (template_domain.maxs[d] - template_domain.mins[d]) / T(res[d] - 1) : one(T), Val(D)))
    
    ref_domain = DomainInfo{D, T}(template_domain.dim_keys, template_domain.mins, template_domain.maxs, spacing, template_domain.time_dim, template_domain.stat_registry)
    
    return LSimData{D, DS, M_ref, T}(params, ref_domain, t_vec, x_ref, u_ref, StatDict{M_ref, T}(:Solution => u_ref))
end