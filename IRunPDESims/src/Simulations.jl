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
    sim_data = Base.invokelatest(sim_func, params)
    
    if !isnothing(sim_data)
        saveSimData(sim_data; overwrite=true)
    end
    
    return sim_data
end
"""
    reconstruct_tuple_parameters!(params::ParamDict)

Finds parameters with dimensional identifiers (e.g., Ns__x, Ns__1) and reconstructs
them into their base Tuple (e.g., Ns = (val1, val2)).
"""
function generate_method_tasks(base_params, active_keys, active_values, sim_fixes; ignore_keys::Vector{String}=String[])
    
    # --- 1. Pre-bake the Base Parameters with UI Fixes ---
    # We apply sim_fixes OUTSIDE the grid loop so we only parse them once.
    processed_base = copy(base_params)
    tup_fixes = Dict{String, Vector{Any}}()
    
    for (k, v) in sim_fixes
        k in ignore_keys && continue
        
        m = match(r"^(.+)__([a-zA-Z0-9]+)$", k)
        if !isnothing(m)
            base = String(m.captures[1])
            idx_str = m.captures[2]
            idx = (idx_str == "x" || idx_str == "1") ? 1 :
                  (idx_str == "y" || idx_str == "2") ? 2 :
                  (idx_str == "z" || idx_str == "3") ? 3 : tryparse(Int, idx_str)
            
            if !isnothing(idx)
                if !haskey(tup_fixes, base)
                    tup_fixes[base] = haskey(processed_base, base) ? collect(Any, processed_base[base]) : Any[]
                end
                arr = tup_fixes[base]
                while length(arr) < idx; push!(arr, 0.0); end
                arr[idx] = v
                continue
            end
        end
        # Standard parameter
        processed_base[k] = v
    end
    
    # Reconstruct Fixed Tuples
    for (base, arr) in tup_fixes
        processed_base[base] = all(x -> x isa Integer, arr) ? Tuple(Int.(arr)) : 
                               all(x -> x isa Real, arr) ? Tuple(Float64.(arr)) : Tuple(arr)
    end

    # --- 2. Pre-parse Varied Parameters (Active Keys) ---
    # Regex parsing is slow! We only do it once here instead of N times in the grid.
    varied_std = Tuple{Int, String}[]       # Stores: (index_in_pvals, key)
    varied_tup = Tuple{Int, String, Int}[]  # Stores: (index_in_pvals, base_name, tuple_idx)
    
    for (i, k) in enumerate(active_keys)
        k in ignore_keys && continue
        
        m = match(r"^(.+)__([a-zA-Z0-9]+)$", k)
        if !isnothing(m)
            base = String(m.captures[1])
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

    # --- 3. Grid Generation ---
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
            tup_updates = Dict{String, Vector{Any}}()
            
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
    get_ignore_keys(method_collection::MethodDict, method_name::String)

Safely extracts the list of keys a specific method wishes to ignore.
"""
function get_ignore_keys(method_collection::MethodDict, method_name::String)
    method_dict = get(method_collection, method_name, ParamDict())
    raw_ignore = get(method_dict, "ignore", String[])
    
    if raw_ignore isa AbstractVector || raw_ignore isa Tuple
        return String.(raw_ignore)
    elseif raw_ignore isa AbstractString
        return [String(raw_ignore)]
    else
        return String[]
    end
end

"""
    assembleParams(shared_params::ParamDict, method_collection::MethodDict, method_name::String)

Backend version: Constructs a flat parameter dictionary for a simulation run by combining
shared parameters and method-specific parameters.
"""
function assembleParams(
    shared_params::ParamDict,
    method_collection::MethodDict,
    method_name::String
)::ParamDict

    method_dict = get(method_collection, method_name, ParamDict())
    
    # Use the new helper!
    ignore_keys = get_ignore_keys(method_collection, method_name)
    
    current_params = ParamDict()
    
    # 1. Add shared parameters (skipping ignored ones)
    for (key, val) in shared_params
        key in ignore_keys && continue
        
        if val isa Tuple && length(val) == 2 && val[1] == :const
            current_params[key] = val[2]
        else
            current_params[key] = val
        end
    end

    # 2. Add/Override with method-specific parameters
    for (key, val) in method_dict
        key == "ignore" && continue 
        if val isa Tuple && length(val) == 2 && val[1] == :const
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
    active_methods::Vector{String} = sim_config.default_methods,
    varied_params::VariedDict = sim_config.varied_params,
    fixed_params::ParamDict = ParamDict(),
    force_overwrite::Bool = false,
    convert_eulerian::Bool = false, 
    calculate_stats::Bool = false,     # NEW: Toggle for eager stats calculation
    stats_to_calculate::Union{Symbol, Vector{Symbol}} = [:series],
    parallel::Bool = false
)
    active_keys = collect(keys(varied_params))
    active_values = collect(values(varied_params))
    
    # 1. Generate all parameter combinations across all methods
    all_tasks = Vector{ParamDict}()
    local grid_indices
    for method in active_methods
        if contains(safe_string(method), "analytic") || contains(safe_string(method), "reference"); continue; end
        base_params = assembleParams(sim_config.shared_params, sim_config.methods_dict, method)
        ignore_keys = get_ignore_keys(sim_config.methods_dict, method)
        tasks, _ = generate_method_tasks(base_params, active_keys, active_values, fixed_params; ignore_keys=ignore_keys)
        append!(all_tasks, tasks)
    end
    
    num_tasks = length(all_tasks)
    if num_tasks == 0
        @info "No simulations generated to run."
        return
    end
    
    @info "Starting batch execution of $num_tasks simulations (Parallel: $parallel)..."
    p = Progress(num_tasks; desc="Running Simulations...")
    counter = Threads.Atomic{Int}(0)
    ana_cache = Dict{Float64, Array{Float64}}()
    # --- Helper for eager Eulerian conversion & Stat Calculation ---
    function _process_task(params)
        # 1. Run the simulation
        run_smart_simulation(sim_config.simulation_func, params; force_overwrite=force_overwrite)
        
        # 2. Handle eager post-processing
        if convert_eulerian || calculate_stats
            sim_data = loadSimData(params)
            
            # if convert_eulerian && sim_data isa LSimData
            #     N_grid = _LAGRANGE_N_GRID[]
            #     try
            #         if force_overwrite; error("Overwrite Forced!") end
            #         sim_data = loadBestConversion(params, N_grid)
            #     catch
            #         conv_data = convert_to_eulerian(sim_data, N_grid)
            #         saveSimData(conv_data; data_key="sim_data_plot_$(N_grid)", overwrite=true)
            #         sim_data = conv_data 
            #     end
            # end
            
            if calculate_stats && !isnothing(sim_data)
                # Determine which key we are calculating stats for based on the data type
                
                calculateAllStats!(
                    sim_data, 
                    sim_config.reference_func; 
                    stats_to_calculate=stats_to_calculate, 
                    data_key="sim_data_raw",
                    force_overwrite=force_overwrite,
                    ana_cache=ana_cache
                )
            end
        end
    end

    # 2. Execute tasks using the smart wrapper
    if parallel
        Threads.@threads for params in all_tasks
            try
                _process_task(params)
            catch e
                @error "Simulation Thread Error" exception=(e, catch_backtrace())
            end
            Threads.atomic_add!(counter, 1)
            ProgressMeter.update!(p, counter[])
        end
    else
        for params in all_tasks
            _process_task(params)
            counter[] += 1
            ProgressMeter.update!(p, counter[])
        end
    end
    
    @info "Batch simulation run complete!"
end