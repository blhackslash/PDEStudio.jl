# test_dummy_data.jl

using Dates
using Test
path = "../src/"

# Include your modules (adjust paths if necessary)
include(path * "Structs.jl")
include(path * "Utils.jl")
include(path * "DataProcessing.jl")

using .Structs
using .Utils
using .DataProcessing

# --- 1. Define Dummy Simulation Function ---

function dummy_simulation_func(params::ParamDictType)
    # Extract settings
    sim_type = get(params, "type", "euler")
    n_steps = get(params, "n_steps", 5)
    
    t = collect(range(0.0, 1.0, length=n_steps))
    
    # We pass this empty dict to satisfy the function signature, 
    # but the constructor will initialize specific buckets.
    stats_placeholder = ParamDictType() 

    if sim_type == "euler"
        # --- EULERIAN DATA GENERATION ---
        n_x = 10
        n_c = 2
        
        # Grid: x is usually passed as Matrix [Space, Time] in your old format
        x_vec = collect(range(0.0, 10.0, length=n_x))
        x_mat = repeat(x_vec, 1, n_steps) # Create [X, T] matrix
        
        # U: [Component, Space, Time]
        u = zeros(n_c, n_x, n_steps)
        for ti in 1:n_steps
            for xi in 1:n_x
                for c in 1:n_c
                    u[c, xi, ti] = c * x_vec[xi] * (1 + t[ti])
                end
            end
        end
        
        return createSimData(x_mat, u, t, params, stats_placeholder)

    elseif sim_type == "lagrange"
        # --- LAGRANGIAN DATA GENERATION ---
        
        x_data = Vector{Vector{Float64}}(undef, n_steps)
        u_data = Vector{Matrix{Float64}}(undef, n_steps)
        
        for ti in 1:n_steps
            current_n_p = 5 + ti 
            x_data[ti] = collect(range(0.0, 10.0 + ti, length=current_n_p))
            
            # u(t) data [Component, Particles]
            current_u = zeros(2, current_n_p)
            for p in 1:current_n_p
                current_u[1, p] = x_data[ti][p] * t[ti]
                current_u[2, p] = x_data[ti][p] * t[ti] * 0.5
            end
            u_data[ti] = current_u
        end
        
        return createSimData(x_data, u_data, t, params, stats_placeholder)
    else
        error("Unknown simulation type: $sim_type")
    end
end

# --- 2. Main Test Routine ---

function run_tests()
    # Set save path to current directory for testing
    set_save_path!(pwd()) 
    println("Save path set to: $(get_save_path())")

    @testset "Simulation Data Tests" begin
        
        # Test 1: Eulerian Data
        println("\n--- Testing Eulerian Data ---")
        params_e = ParamDict("type" => "euler", "id" => 1, "var_param" => 10.0)
        
        sim_data_e = dummy_simulation_func(params_e)
        
        @test sim_data_e isa ESimData1D
        @test isempty(sim_data_e.scalars) # Verify buckets are initialized empty
        @test sim_data_e.x isa Vector{Float64} # Verify Matrix->Vector conversion
        println("Generated ESimData. Grid size: $(length(sim_data_e.x))")
        
        saveSimData(sim_data_e; overwrite=true)
        @test doesSimDataExist(params_e)
        
        loaded_e = loadSimData(params_e)
        @test loaded_e.params == params_e
        @test loaded_e.u == sim_data_e.u
        println("Eulerian data saved and loaded successfully.")

        # Test 2: Lagrangian Data
        println("\n--- Testing Lagrangian Data ---")
        params_l = ParamDict("type" => "lagrange", "id" => 2, "var_param" => 20.0)
        
        sim_data_l = dummy_simulation_func(params_l)
        
        @test sim_data_l isa LSimData1D
        @test isempty(sim_data_l.fields)
        @test sim_data_l.u[1] isa Matrix{Float64} # Verify u standardization
        println("Generated LSimData. T-steps: $(length(sim_data_l.t))")
        
        saveSimData(sim_data_l; overwrite=true)
        @test doesSimDataExist(params_l)
        
        loaded_l = loadSimData(params_l)
        @test loaded_l.params == params_l
        @test loaded_l.x[end] == sim_data_l.x[end]
        println("Lagrangian data saved and loaded successfully.")
    end    
end

run_tests()

# test_config_setup.jl

# Ensure you have your modules loaded
# include("Structs.jl")
# include("Utils.jl")
# include("DataProcessing.jl")
# using .Structs, .Utils, .DataProcessing

# --- 1. Define a Parameter-Dependent Simulation Function ---

function test_sim_func(params::ParamDictType)
    # Extract Parameters
    sim_type = get(params, "type", "euler")
    
    # Grid Settings
    n_t = get(params, "n_steps", 20)
    t = collect(range(0.0, 10.0, length=n_t))
    
    # Varied Parameters (Defaults provided for safety)
    A = get(params, "amplitude", 1.0)
    f = get(params, "frequency", 0.5)
    decay = get(params, "decay", 0.0) # Shared param
    
    # Helper to calculate wave: u = A * sin(x * f - t) * exp(-decay * t)
    function calc_wave(x, t, A, f, decay)
        return A * sin(x * f - t) * exp(-decay * t)
    end

    # Placeholder for buckets (as per new SimData structure)
    stats_placeholder = ParamDictType() 

    if sim_type == "euler"
        # --- EULERIAN (Fixed Grid) ---
        n_x = get(params, "n_x", 50)
        x_vec = collect(range(0.0, 2π, length=n_x))
        
        # Create [Space, Time] matrix for createSimData input (optional, or just pass vector)
        x_input = repeat(x_vec, 1, n_t) 
        
        # U: [Component, Space, Time] (Let's simulate 2 components: u and u^2)
        n_c = 2
        u = zeros(n_c, n_x, n_t)
        
        for ti in 1:n_t, xi in 1:n_x
            val = calc_wave(x_vec[xi], t[ti], A, f, decay)
            u[1, xi, ti] = val
            u[2, xi, ti] = val^2 # Component 2
        end
        
        return createSimData(x_input, u, t, params, stats_placeholder)

    elseif sim_type == "lagrange"
        # --- LAGRANGIAN (Moving Particles) ---
        # Particles start at grid points but move over time
        n_p = get(params, "n_x", 20)
        
        x_data = Vector{Vector{Float64}}(undef, n_t)
        u_data = Vector{Matrix{Float64}}(undef, n_t)
        
        x0 = collect(range(0.0, 2π, length=n_p))
        
        for ti in 1:n_t
            # Particles drift: x(t) = x0 + 0.1 * A * t
            x_current = x0 .+ (0.1 * A * t[ti])
            x_data[ti] = x_current
            
            # Values on particles
            u_current = zeros(2, n_p)
            for i in 1:n_p
                val = calc_wave(x_current[i], t[ti], A, f, decay)
                u_current[1, i] = val
                u_current[2, i] = val^2
            end
            u_data[ti] = u_current
        end
        
        return createSimData(x_data, u_data, t, params, stats_placeholder)
    end
end

# --- 2. Create the Configuration ---

# A. Varied Parameters (The Grid)
# We vary Amplitude and Frequency
varied_params = Dict{String, Vector{Any}}(
    "amplitude" => [1.0, 2.0, 5.0],
    "frequency" => [0.5, 1.0]
)

# B. Methods (Compare Euler vs Lagrange)
methods_dict = MethodDict(
    "Euler_Simulation" => ParamDict(
        "type" => "euler", 
        "n_x" => 50 # Higher resolution for Euler
    ),
    "Lagrange_Simulation" => ParamDict(
        "type" => "lagrange",
        "n_x" => 20 # Fewer particles
    )
)

# C. Shared Parameters (Constant for all runs)
shared_params = ParamDict(
    "n_steps" => 30,
    "decay" => 0.05
)

# D. Instantiate Config
test_config = SimulationConfig(
    test_sim_func,
    shared_params,
    methods_dict,
    "all"; # Run all methods by default
    varied_params = varied_params
)

println("SimulationConfig created successfully.")
println("Varied Params: ", keys(test_config.varied_params))
println("Methods: ", test_config.default_methods)

# --- 3. (Optional) Run the Data Generation Test ---

fixed_params = Dict{String, Any}() # We fix nothing, so we get the full grid
plot_data_dict = Dict{String, UnifiedPlotData}()

# Ensure data exists (Run Simulations)
# We need to generate the task list first (handled internally by update_plot_data_collection! usually?)
# Or use Utils.ensure_sim_data_exists! manually if you want to test run first.
# But update_plot_data_collection! does NOT run simulations, it just loads. 
# So you usually run ensure_sim_data_exists! on the generated tasks first.

#using .DataProcessing: generate_method_tasks, update_plot_data_collection!

# 1. Generate Tasks for Euler to ensure they exist
active_keys, active_vals, sim_fixes, base_fixes = DataProcessing.analyze_configuration(test_config, fixed_params)
tasks, _ = DataProcessing.generate_method_tasks(
    Utils.assembleParams(test_config.shared_params, test_config.methods_dict, "Euler_Simulation"),
    active_keys, active_vals, sim_fixes
)

println("Running $(length(tasks)) simulations for Euler...")
Utils.ensure_sim_data_exists!(tasks, test_config; force_overwrite=false)

# 2. Create Unified Plot Data
update_plot_data_collection!(plot_data_dict, test_config, ["Euler_Simulation"], fixed_params)

if haskey(plot_data_dict, "Euler_Simulation")
    pd = plot_data_dict["Euler_Simulation"]
    println("Unified Data Created!")
    println("Tensor Shape: ", size(pd.data["u"]))
    # Expected: [Component(2), Amp(3), Freq(2), Space(50), Time(30)]
end