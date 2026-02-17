using GLMakie
using Test
using Dates
path = "../src/"
# 1. Include the necessary modules
include(path*"Structs.jl")
include(path*"Utils.jl")
include(path*"Controls.jl")

using .Structs
using .Utils
using .Controls


function run_unified_test()
    println("--- Setting up Simulation Configuration ---")

    # A. Define Simulation Setup
    # Using the Wave function logic from earlier
    dummy_sim(params) = println("Simulating with: ", params) 
    
    shared_params = ParamDict(
        "dt" => 0.01, 
        "L" => 10.0, 
        "viscosity" => 0.1
    )
    
    methods_dict = MethodDict(
        "RK4_Solver" => ParamDict("order" => 4, "step_type" => "explicit"),
        "Euler_Solver" => ParamDict("order" => 1, "step_type" => "explicit")
    )
    
    # Define what we vary (The Grid)
    varied_params = Dict{String, Vector{Any}}(
        "amplitude" => [1.0, 2.0, 5.0],
        "frequency" => [0.1, 0.5, 1.0]
    )

    sim_config = SimulationConfig(
        dummy_sim, 
        shared_params, 
        methods_dict, 
        ["RK4_Solver"]; # Default active method
        varied_params = varied_params
    )

    # B. Define UI Options (Nested Structure)
    # This matches your new 4-scope requirement
    ui_nested = Dict(
        "Axis" => Dict{String, Any}(
            "xlabel" => "Position x", 
            "ylabel" => "Value u", 
            "title" => "Wave Simulation"
        ),
        "Appearance" => Dict{String, Any}(
            "linewidth" => 4, 
            "linestyle" => :solid, 
            "markersize" => 12
        ),
        "Legend" => Dict{String, Any}(
            "visible" => true, 
            "legend_pos" => "righttop"
        ),
        "Various" => Dict{String, Any}(
            "save_formats" => ["png", "pdf"],
            "create_savefolder" => true
        )
    )

    # C. Define Scene
    scene_raw = Dict("t" => 0.0, "component" => 1)

    println("--- Initializing PlotManager ---")
    # This handles the conversion to Observables and organizes the hierarchy
    manager = create_plot_manager(sim_config, ui_nested, scene_raw)

    # D. Setup Figures
    plot_fig = Figure(size = (800, 600))
    ax = Axis(plot_fig[1,1], title = "Simulation View")
    
    println("--- Launching Control Figure ---")
    # This is your new simplified function
    fig_ctrl, refresh_obs, methods_obs, plot_slot = create_controls(plot_fig, manager)

    # E. Add feedback listeners for testing
    on(refresh_obs) do count
        @info "REFRESH: Re-simulating with current parameters..."
        # In a real app, you'd call create_unified_plot_data here
    end

    on(methods_obs) do active
        @info "METHODS: Currently active for comparison: $active"
    end

    # Watch for any change in the 'Appearance' scope
    for (key, obs) in manager.ui["Appearance"]
        on(obs) do val
            @info "UI CHANGE: Appearance -> $key is now $val"
        end
    end

    println("\nREADY TO TEST:")
    println("1. Change 'dt' in Simulation -> shared.")
    println("2. Toggle 'visible' in UI -> Legend.")
    println("3. Change 'linewidth' in UI -> Appearance.")
    println("4. Observe the console for updates.")

    return fig_ctrl, plot_fig, manager
end

# Run the test
fig_ctrl, plot_fig, manager = run_unified_test()