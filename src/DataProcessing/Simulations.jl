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
    parallel::Bool = false
)
    active_keys = collect(keys(varied_params))
    active_values = collect(values(varied_params))
    
    # 1. Generate all parameter combinations across all methods
    all_tasks = Vector{ParamDict}()
    local grid_indices
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
    
    # 2. Execute tasks using the smart `run_simulation` wrapper
    if parallel
        Threads.@threads for params in all_tasks
            try
                run_simulation(sim_config.simulation_func, params; force_overwrite=force_overwrite)
            catch e
                @error "Simulation Thread Error" exception=(e, catch_backtrace())
            end
            Threads.atomic_add!(counter, 1)
            ProgressMeter.update!(p, counter[])
        end
    else
        for params in all_tasks
            run_simulation(sim_config.simulation_func, params; force_overwrite=force_overwrite)
            counter[] += 1
            ProgressMeter.update!(p, counter[])
        end
    end
    
    @info "Batch simulation run complete!"
end