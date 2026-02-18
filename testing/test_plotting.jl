using GLMakie, Statistics, Dates, DataFrames, CSV

# --- Define the Simulation Function ---
function wave_simulation(params::Dict{String, Any})
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
        # createSimData handles Matrix x -> Vector x conversion
        return createSimData(repeat(x_base, 1, nt), u, t, params, stats)
    else
        # Lagrangian: Moving Particles
        x_data = [x_base .+ (0.1 * A * sin(2π * ti)) for ti in t]
        u_data = [reshape(A * sin.(f .* x_data[i] .- 2π * t[i]), 1, :) for i in 1:nt]
        return createSimData(x_data, u_data, t, params, stats)
    end
end

path = "../src/"
# test_full_orchestrator.jl

include(path*"Structs.jl")
include(path*"Utils.jl")
include(path*"Controls.jl")
include(path*"DataProcessing.jl") # Assuming orchestrator/tensor logic is here
include(path*"MakiePlotting.jl")
using .Structs, .Utils, .MakiePlotting, .Controls

function run_final_test()
    println("--- Preparing Test Configuration ---")

    # 1. Config
    shared = Dict{String, Any}("L" => 10.0, "n_steps" => 40, "n_x" => 60)
    methods = Dict(
        "Euler_Wave" => Dict{String, Any}("type" => "euler", "amplitude" => 1.0),
        "Lagrange_Wave" => Dict{String, Any}("type" => "lagrange", "amplitude" => 1.0)
    )
    # Varied parameter: frequency
    varied = Dict{String, Vector{Any}}("frequency" => [0.5, 1.0, 2.0])

    sim_config = SimulationConfig(wave_simulation, shared, methods, ["Euler_Wave", "Lagrange_Wave"]; varied_params=varied)

    # 2. Launch Orchestrator
    println("--- Launching Orchestrator ---")
    # This calls create_controls, sets up the PlotManager, and runs the data/render lifts
    plot_fig, ctrl_fig, manager = show_unified_fig(
        sim_config; 
        ui_options = :default,
        scene_options = Dict("component" => 1)
    )

    # 3. Add a test listener to verify the Type-Safe Parser
    on(manager.simulation["shared"]["L"]) do val
        @info "Property 'L' updated in PlotManager to: $val"
    end

    println("\nSUCCESS: Windows should be open.")
    println("Try the following:")
    println("1. Move the 'frequency' slider - the plot should update instantly.")
    println("2. Change 'amplitude' for Euler_Wave in the Hierarchical Menu, then click REFRESH.")
    println("3. Change 'xlabel' in UI -> Axis - notice the 'Loaded' placeholder vs 'Value' textbox.")
    
    return plot_fig, ctrl_fig, manager
end

# Execute
p_fig, c_fig, mgr = run_final_test()