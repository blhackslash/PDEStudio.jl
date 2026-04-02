function wave_simulation(params::ParamDict)
    @info "--- Starting Wave Simulation ---"
    
    # 1. Extract Parameters (Using defaults if not found)
    n_x       = get(params, "n_x", 60)
    n_steps   = get(params, "n_steps", 40)
    L         = Float64(get(params, "L", 10.0))
    amplitude = Float64(get(params, "amplitude", 1.0))
    frequency = Float64(get(params, "frequency", 0.5))
    
    c = 1.0 # Wave speed

    # 2. Setup Spatial and Temporal Grids
    x = collect(range(0, L, length=n_x))
    t = collect(range(0, 5.0, length=n_steps)) # Simulating up to t = 5.0
    
    # Inject domain bounds into params so StatCalculation can find them easily
    params["xmin"] = x[1]
    params["xmax"] = x[end]

    # 3. Preallocate Eulerian Tensor: [Component, Space, Time]
    u = zeros(Float64, 1, n_x, n_steps)

    # 4. Define the Analytical Solution locally!
    function analytical_solution(x_val, t_val)
        return amplitude * sin(2 * π * frequency * (x_val - c * t_val))
    end

    # 5. Populate the Numerical Data
    for m in 1:n_steps
        for i in 1:n_x
            true_val = analytical_solution(x[i], t[m])
            
            # Inject a tiny, time-growing numerical error so we can actually 
            # see convergence metrics and L2 norms in the plotter!
            artificial_error = 0.05 * sin(π * x[i] / L) * (t[m] / 5.0) 
            
            u[1, i, m] = true_val + artificial_error
        end
    end

    # 6. Create the AbstractSimData container (ESimData{1} for 1D Eulerian)
    sim_data = createSimData(x, u, t, params)
    sim_data = loadSimData(params)
    # 7. INJECT: Run the Stat Calculation inline before returning!
    @info "Calculating statistics..."
    calculateAllStats!(
        sim_data, 
        analytical_solution; 
        dierckx_k = 3,
        force_overwrite = false,
    )

    return sim_data
end