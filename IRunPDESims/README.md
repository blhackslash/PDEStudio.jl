# IRunPDESims

**IRunPDESims** is a robust, headless-safe Julia backend for executing, managing, and statistically analyzing Partial Differential Equation (PDE) simulations. It provides a unified framework for generating strictly typed, precision-agnostic Eulerian and Lagrangian datasets, computing automatic statistics, and seamlessly handling multi-dimensional parameter sweeps.

---

## 🏗️ Core Data Structures

### The Simulation Data (`AbstractSimData`)
All simulation outputs are wrapped in strongly typed structs that map the mathematical truth of your data.
*   **`ESimData{D, DS, M, T}`:** Represents Eulerian grid data (fields on a static mesh).
*   **`LSimData{D, DS, M, T}`:** Represents Lagrangian particle data (scattered points moving through space).

*Note: `D` is total spacetime dimensions, `DS` is spatial dimensions, `M` is the number of field components, and `T` is the numeric precision (e.g., `Float64` or `Float32`).*

### The Simulation Configuration (`SimulationConfig`)
The `SimulationConfig` is the blueprint for your simulation runs. It binds your core simulation function together with the parameters, default baseline variables, and the parameter sweeps you want to execute. 

---

## 📖 The Configuration Dictionaries

To manage complex parameter sweeps cleanly, the package uses three distinct dictionary types:

*   **`ParamDict` (`Dict{Symbol, Any}`):** The fundamental parameter dictionary. This is the exact object passed into your custom simulation function. It holds the flat, resolved list of parameters for a single run (e.g., `:N => 100`, `:dt => 0.01`).
*   **`MethodDict` (`Dict{Symbol, ParamDict}`):** Contains method-specific overrides. It allows you to define a shared baseline `ParamDict`, and then swap out specific parameters for different numerical methods or solvers (e.g., overriding `:solver_type` for an `:implicit` method vs. an `:explicit` method). 
*   **`VariedDict` (`Dict{Symbol, Vector}`):** Defines the parameter grid you want to iterate over. The backend will automatically generate the Cartesian product of all vectors defined here and run simulations for every combination.

---

## ⚙️ Main API Functions

*   **`run_all_simulations(config::SimulationConfig; kwargs...)`:** The main workhorse. It automatically unpacks the `VariedDict`, applies the specific overrides from the `MethodDict`, and handles disk-caching. If a simulation with the exact parameters already exists on disk, it will skip it automatically to save computation time.
*   **`calculate_all_stats!(sim_data, ref_func)`:** Evaluates registered statistics (like Mass, L1/L2 errors, etc.) dynamically. It uses the `ref_func` to generate a perfect pointwise analytical cache to evaluate exact error metrics across both uniform Eulerian grids and scattered Lagrangian particles.

---

## 📊 Custom Statistics

The package allows you to easily inject and calculate custom statistics. 

### 1. Integrated-Out Statistics (via `calc_stat` overload)
If you want the backend to automatically map and integrate your statistic across the correct dimensions (e.g., evaluating a spatial metric at every time step), overload the `calc_stat` function:

```julia
# Overload for your custom metric
function IRunPDESims.calc_stat(::Val{:my_custom_error}, fixed_coords, u, ana, domain::DomainInfo)
    # fixed_coords: An SVector containing the exact coordinates of the dimensions being kept.
    # u / ana: The sliced simulation and analytical data arrays (the dimensions being integrated out).
    
    measure = IRunPDESims.get_integration_measure(:my_custom_error, domain)
    return sum(abs.(u .- ana) .* measure)
end

# Register the statistic and tell the backend which dimensions it keeps!
register_stat!(:my_custom_error, :time)
```
When registering, you can explicitly define a vector of dimension symbols to keep (e.g., `[:x, :y]`), or use these built-in convenience aliases:
*   `:all` — Keeps everything (evaluates as a full tensor/field).
*   `:space` — Keeps spatial dimensions, integrates out time.
*   `:time` — Keeps the time dimension, integrates out space.

### 2. Complete Custom Statistics
If you have a statistic that completely bypasses standard integration and you just want to append a pre-calculated value/array directly to the file, use `add_stat!`:

```julia
# Bypasses calc_stat and directly inserts the stat into the dictionary and registry
add_stat!(sim_data, :custom_metric, my_value_array, :time)
```

---

## 🛠️ Technical Details & Dimension Keys (`dim_keys`)

A core part of the architecture is the `dim_keys` field inside `DomainInfo`. 
*   **Identification:** The `dim_keys` tuple acts as the *sole identifier* for your axes. Both the value (e.g., `:x`, `:t`) and the order matter greatly for interpolation, statistical slicing, and plotting.
*   **Consistency:** While you can set these keys freely to match whatever physical problem you are modeling (e.g., `(:r, :theta, :t)`), you should **never** change the layout of a tuple for a specific model paradigm once data has been saved, as this will break backwards compatibility for reading and processing.
*   **Defaults:** The prebuilt `create_sim_data` constructors automatically assign `(:x, :y, :z)` for spatial dimensions (up to `DS`) and `:t` for the time dimension (unless you pass a custom `time_dim` keyword argument).

---

## 🚀 Quick Start Example

Here is a minimal example demonstrating how to set up a shared parameter pool, define a method, sweep over time-step sizes, and run the pipeline.

```julia
using IRunPDESims
using StaticArrays

# 1. Define a simple user simulation function
# This function MUST accept a ParamDict and return an ESimData or LSimData
function my_wave_sim(params::ParamDict)
    # Extract parameters
    N  = params[:N]
    dt = params[:dt]
    c  = params[:wave_speed]
    
    # Simple 1D Space + 1D Time Grid
    x = collect(range(0.0, 1.0, length=N))
    t = collect(range(0.0, 2.0, step=dt))
    
    # Generate mock data (e.g., u(x,t) = sin(x - c*t))
    u = zeros(SVector{1, Float64}, length(x), length(t))
    for (j, t_val) in enumerate(t)
        for (i, x_val) in enumerate(x)
            u[i, j] = SVector{1, Float64}(sin(x_val - c * t_val))
        end
    end
    
    # Wrap and return the managed SimData object
    return create_sim_data(x, u, t, params; time_dim=:t)
end

# 2. Setup Dictionaries
# Base parameters shared across all runs
shared_params = create_param_dict(
    :N => 100, 
    :wave_speed => 1.5,
    :dt => 0.1 # This will act as the fallback if not varied
)

# Method specific overrides (Optional)
methods = create_method_dict(
    :upwind => create_param_dict(:solver => "upwind"),
    :lax_wendroff => create_param_dict(:solver => "lax_wendroff")
)
default_methods = [:upwind, :lax_wendroff]

# Parameters to sweep over (Generates 2 tasks per method = 4 simulations total)
varied_params = create_varied_dict(
    :dt => [0.1, 0.05]
)

# 3. Create the Configuration
config = SimulationConfig(
    :my_wave_sim,        # Name of your simulation function
    shared_params, 
    methods, 
    default_methods;
    varied_params = varied_params
)

# 4. Run the Pipeline!
# Set where you want the JLD2 files to be saved
set_save_path!("./my_simulation_results")

# Run all parameter combinations (uses caching automatically!)
run_all_simulations(config, parallel=true, calculate_stats=true)
```