function wave_simulation(params::Dict{String, Any})
    # DEBUG: Prove the simulation is being called by the orchestrator
    @info "[SIMULATION] Running wave_simulation | Type: $(get(params, "type", "unknown")) | Freq: $(get(params, "frequency", "unknown"))"
    
    # Extract Params
    A = get(params, "amplitude", 1.0)
    f = get(params, "frequency", 1.0)
    L = get(params, "L", 10.0)
    nx = get(params, "n_x", 100)
    nt = get(params, "n_steps", 50)
    type = get(params, "type", "euler")

    t = collect(range(0.0, 2.0, length=nt))
    x_base = collect(range(0.0, L, length=nx))
    
    # Placeholder for buckets
    stats = Dict{String, Any}()

    if type == "euler"
        # Eulerian: Fixed Grid
        u = zeros(1, nx, nt) # [Component, Space, Time]
        for i in 1:nt, j in 1:nx
            u[1, j, i] = A * sin(f * x_base[j] - 2π * t[i])
        end
        return createSimData(repeat(x_base, 1, nt), u, t, params)
    else
        # Lagrangian: Moving Particles
        x_data = [x_base .+ (0.1 * A * sin(2π * ti)) for ti in t]
        u_data = [reshape(A * sin.(f .* x_data[i] .- 2π * t[i]), 1, :) for i in 1:nt]
        return createSimData(x_data, u_data, t, params)
    end
end