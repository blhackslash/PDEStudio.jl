using IPlotPDESols
using GLMakie

# --- Define the Simulation Function ---
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

function run_final_test()
    println("--- Preparing Test Configuration ---")

    # 1. Config
    shared = Dict{String, Any}("L" => 10.0, "n_steps" => 40, "n_x" => 60)
    methods = Dict(
        "Euler_Wave" => Dict{String, Any}("type" => "euler", "amplitude" => 1.0),
        "Lagrange_Wave" => Dict{String, Any}("type" => "lagrange", "amplitude" => 1.0),
        "Analytic_Wave" => Dict{String, Any}("type" => "analytic", "amplitude" => 1.0), # Added another for size testing
        "Static_Wave" => Dict{String, Any}("type" => "euler", "amplitude" => 0.5), # Added for size testing
    )
    # Define explicitly all possible methods here
    possible_methods = ["Euler_Wave", "Lagrange_Wave", "Analytic_Wave", "Static_Wave"]
    # Varied parameter: frequency
    varied = Dict{String, Vector{Any}}("frequency" => [0.5, 1.0, 2.0])

    sim_config = SimulationConfig(wave_simulation, shared, methods, ["Euler_Wave", "Lagrange_Wave"]; varied_params=varied)

    # 2. Launch Orchestrator
    println("--- Launching Orchestrator ---")
    plot_fig, ctrl_fig, manager = Base.invokelatest(show_unified_fig,
        sim_config; 
        ui_options = :default,
        scene_options = Dict("base_types" => Any[:menu,:slider,:slider,:slider,:slider])
    )

    # 3. --- UI DEBUG INJECTION ---
    println("--- Attaching UI Debug Listeners ---")
    # Loop through every widget on the control figure and log its state changes
    for widget in ctrl_fig.content
        if widget isa Makie.Slider
            on(widget.value) do val
                @info "[UI EVENT] Slider moved to index/value: $val"
            end
        elseif widget isa Makie.Menu
            on(widget.selection) do val
                @info "[UI EVENT] Menu selection changed to: $val"
            end
        elseif widget isa Makie.Button
            on(widget.clicks) do val
                @info "[UI EVENT] Button clicked! (Total clicks: $val)"
            end
        elseif widget isa Makie.Textbox
            on(widget.stored_string) do val
                @info "[UI EVENT] Textbox input registered: $val"
            end
        elseif widget isa Makie.Checkbox
            on(widget.checked) do val
                @info "[UI EVENT] Checkbox toggled: $val"
            end
        end
    end

    # Test listener for Type-Safe parser
    on(manager.simulation["shared"]["L"]) do val
        @info "[MGR EVENT] Property 'L' updated in PlotManager to: $val"
    end

    println("\nSUCCESS: Windows should be open.")
    println("Try interacting with the UI and watch the REPL for logs!")
    
    return plot_fig, ctrl_fig, manager
end

# Execute
p_fig, c_fig, mgr = run_final_test()