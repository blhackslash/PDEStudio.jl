"""
    run_simulation(sim_func::Function, params::ParamDict; force_overwrite::Bool=false)

Smart wrapper for single simulations. Checks if `SimData` already exists on disk.
If it does (and `force_overwrite` is false), it skips execution and returns `NoSimData`.
Otherwise, it executes the simulation, saves the result, and returns the data.
"""
function run_simulation(sim_func::Function, params::ParamDict; force_overwrite::Bool=false)
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

function generate_method_tasks(base_params, active_keys, active_values, sim_fixes)
    # Handle the edge case of no varied parameters gracefully
    if isempty(active_values)
        param_grid = [()]
    else
        param_grid = collect(Iterators.product(active_values...))
    end
    
    tasks, grid_indices = Vector{ParamDict}(), Vector{Tuple}()

    for (linear_idx, p_vals) in enumerate(param_grid)
        task_params = copy(base_params)
        for (k, v) in sim_fixes; task_params[k] = v; end
        
        indices = isempty(active_values) ? () : Tuple(CartesianIndices(param_grid)[linear_idx])
        
        for (i, val) in enumerate(p_vals)
            task_params[active_keys[i]] = val
        end
        
        push!(tasks, task_params)
        push!(grid_indices, indices)
    end
    
    return tasks, grid_indices
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
    convert_eulerian::Bool = false, # NEW: Toggle for eager conversion
    parallel::Bool = false
)
    active_keys = collect(keys(varied_params))
    active_values = collect(values(varied_params))
    
    # 1. Generate all parameter combinations across all methods
    all_tasks = Vector{ParamDict}()
    local grid_indices
    println(active_methods)
    for method in active_methods
        base_params = assembleParams(sim_config.shared_params, sim_config.methods_dict, method)
        tasks, _ = generate_method_tasks(base_params, active_keys, active_values, fixed_params)
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
    
    # --- NEW: Helper for eager Eulerian conversion ---
    function _process_task(params)
        # 1. Run the simulation (or skip if it exists and !force_overwrite)
        run_simulation(sim_config.simulation_func, params; force_overwrite=force_overwrite)
        
        # 2. Handle eager Eulerian conversion
        if convert_eulerian
            sim_data = loadSimData(params)
            
            if sim_data isa LSimData
                N_grid = _LAGRANGE_N_GRID[]
                cache_name = "conv_$(N_grid)"
                try
                    # If the cache already exists, we skip doing the heavy math
                    loadSimData(params; suffix=cache_name)
                catch
                    # Cache missing, convert and save it eagerly
                    conv_data = convert_to_eulerian(sim_data, N_grid)
                    saveSimData(conv_data; suffix=cache_name, overwrite=true)
                end
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