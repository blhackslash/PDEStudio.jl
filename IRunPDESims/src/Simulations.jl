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
    if !force_overwrite && doesSimDataExist(params)
        return NoSimData()
    end
    # Run the actual simulation
    sim_data = sim_func(params)
    
    if !isnothing(sim_data)
        saveSimData(sim_data; overwrite=true)
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
                task_params[base] = all(x -> x isa Integer, arr) ? Tuple(Int.(arr)) : 
                                    all(x -> x isa Real, arr) ? Tuple(Float64.(arr)) : Tuple(arr)
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
    assembleParams(shared_params::ParamDict, method_collection::MethodDict, method_name::Symbol)

Backend version: Constructs a flat parameter dictionary for a simulation run by combining
shared parameters and method-specific parameters.
"""
function assembleParams(
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
    runAllSimulations(sim_config::SimulationConfig; kwargs...)

Executes all simulations defined in a `SimulationConfig`. 
Perfect for headless execution without UI overhead.
"""
function runAllSimulations(
    sim_config::SimulationConfig;
    active_methods::Vector{Symbol} = sim_config.default_methods,
    varied_params::VariedDict = sim_config.varied_params,
    force_overwrite::Bool = false,
    calculate_stats::Bool = false,
    parallel::Bool = false
)
    _GRID_LOCK[] = true
    @info "Started Simulation Pipeline. Grid Lock is enabled!"
    active_keys = collect(keys(varied_params))
    active_values = collect(values(varied_params))
    
    # 1. Generate all parameter combinations across all methods
    all_tasks = Vector{ParamDict}()
    for method in active_methods
        if is_reference_method(method); continue; end
        base_params = assembleParams(sim_config.shared_params, sim_config.methods_dict, method)
        ignore_keys = get_ignore_keys(sim_config.methods_dict, method)
        tasks, _ = generate_method_tasks(base_params, active_keys, active_values; ignore_keys=ignore_keys)
        append!(all_tasks, tasks)
    end
    
    num_tasks = length(all_tasks)
    if num_tasks == 0
        @info "No numerical simulations generated to run."
        return Float64[]
    end
    
    @info "Pass 1: Executing $num_tasks simulations (Parallel: $parallel)..."
    p = Progress(num_tasks; desc="Running Simulations...")
    counter = Threads.Atomic{Int}(0)
    
    t_vectors = Vector{Vector{Float64}}(undef, num_tasks)
    
    function _run_task(i, params)
        run_smart_simulation(sim_config.simulation_func, params; force_overwrite=force_overwrite)
        sim_data = loadSimData(params)
        t_vectors[i] = !isnothing(sim_data) ? sim_data.t : Float64[]
    end

    if parallel
        Threads.@threads for i in 1:num_tasks
            try
                _run_task(i, all_tasks[i])
            catch e
                @error "Simulation Thread Error" exception=(e, catch_backtrace())
            end
            Threads.atomic_add!(counter, 1)
            ProgressMeter.update!(p, counter[])
        end
    else
        for i in 1:num_tasks
            _run_task(i, all_tasks[i])
            counter[] += 1
            ProgressMeter.update!(p, counter[])
        end
    end
    
    if calculate_stats
        @info "Pass 2: Calculating Stats"
        p2 = Progress(num_tasks; desc="Post-processing...")
        counter2 = Threads.Atomic{Int}(0)
        
        function _post_task(params)
            sim_data = loadSimData(params, Val(:raw))
            if !isnothing(sim_data)  
                if calculate_stats
                    calculateAllStats!(
                        sim_data, 
                        sim_config.reference_func; 
                        force_overwrite=force_overwrite,
                    )
                end
            end
        end
        for i in 1:num_tasks
            _post_task(all_tasks[i])
            counter2[] += 1
            ProgressMeter.update!(p2, counter2[])
        end
    end
    
    @info "Batch simulation run complete! Disabling Grid Lock!"
    _GRID_LOCK[] = false
    return 
end