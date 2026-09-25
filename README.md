# PDEStudio.jl

[![DOI](https://zenodo.org/badge/1374801372.svg)](https://doi.org/10.5281/zenodo.22962032)
[![Build Status](https://github.com/blhackslash/PDEStudio.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/blhackslash/PDEStudio.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/blhackslash/PDEStudio.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/blhackslash/PDEStudio.jl)
[![Stable Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://blhackslash.github.io/PDEStudio.jl/)

**PDEStudio.jl** is a highly interactive, Makie-driven graphical frontend engineered for the real-time visualization and exploration of Partial Differential Equation (PDE) simulations. It serves as the visual counterpart to the autonomous numerical backend, [PDEStudioCore.jl](https://github.com/blhackslash/PDEStudioCore.jl).

The studio seamlessly handles both Eulerian grids and Lagrangian particle systems, dynamically adapting its primitives to support 1D, 2D, and 3D visualization. It features a hierarchical UI editor, robust CSV serialization for state preservation, and an independent export pipeline for publication-quality static frames and animations.

Because PDE simulations often require dedicated compute servers, `PDEStudio.jl` supports two primary deployment strategies:
*   **Local Exploration (`GLMakie`):** Run the autonomous `PDEStudioCore` backend headlessly on a server, transfer the resulting serialized data, and explore it locally with maximum performance.
*   **Remote Web Server (`WGLMakie`):** Serve interactive plots directly from the compute node to your web browser via `Bonito`, trading a slight latency increase for massive reductions in data transfer overhead.

## Installation

```julia
using Pkg
Pkg.add("PDEStudio")
```

*Note: For the full interactive experience, you must also install a Makie backend of your choice (e.g., `GLMakie` or `WGLMakie`).*

## Documentation

For comprehensive guides on the reactive UI architecture, layout synchronization, parameter sweeping, and advanced server deployment macros, please refer to the **[Official Documentation](https://blhackslash.github.io/PDEStudio.jl/dev/)**.

## Basic Workflow

### 1. Create a Simulation Config with the backend **PDEStudioCore**:

```julia
# examples/advection_1d.jl
using PDEStudio # Reexports PDEStudioCore automatically
using StaticArrays

# 1. Define the 1D Linear Advection solver
function advection_1d(params::ParamDict)
    # Extract shared physics and grid settings
    N   = params[:N]
    c   = params[:c]
    T   = params[:T]
    cfl = params[:cfl]
    scheme = params[:scheme]

    # Calculate step sizes based on the CFL condition
    x = collect(range(0.0, 1.0, length=N))
    dx = x[2] - x[1]
    dt = cfl * dx / abs(c)
    t = collect(0.0:dt:T)

    # Allocate the 2D Spacetime Tensor (Space x Time)
    u = zeros(SVector{1, Float64}, N, length(t))
    
    # Initial Condition: Sine wave
    for i in 1:N
        u[i, 1] = SVector{1, Float64}(sin(2 * pi * x[i]))
    end

    # Time integration loop with periodic boundary conditions
    for j in 1:(length(t)-1)
        for i in 1:N
            # Periodic index wrapping
            i_prev = i == 1 ? N : i - 1
            i_next = i == N ? 1 : i + 1

            u_curr = u[i, j][1]
            u_prev = u[i_prev, j][1]
            u_next = u[i_next, j][1]

            # Route to the specific numerical scheme
            if scheme == "upwind"
                # Standard first-order upwind (assuming c > 0)
                val = u_curr - cfl * (u_curr - u_prev)
            elseif scheme == "lax_friedrichs"
                # Lax-Friedrichs central difference
                val = 0.5 * (u_next + u_prev) - 0.5 * cfl * (u_next - u_prev)
            else
                error("Unknown scheme: $scheme")
            end

            u[i, j+1] = SVector{1, Float64}(val)
        end
    end

    return create_sim_data(x, u, t, params; time_dim=:t)
end

# 2. Setup Dictionaries
shared_params = create_param_dict(
    :N => 100,
    :c => 1.0,
    :T => 2.0,
    :cfl => .5, # Define the default to be overwritten by the varied parameters
)

# Define the methods (these inject the :scheme parameter into the solver)
methods = create_method_dict(
    :upwind => create_param_dict(:scheme => "upwind"),
    :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs")
)

# Parameter sweeps: Test both methods across different CFL limits
varied_params = create_varied_dict(
    :cfl => [0.3, 0.5, 0.8, 1.0]
)

# 3. Create the Configuration
config = SimulationConfig(
    :advection_1d,            # Pass the function name
    shared_params,
    methods,
    [:upwind, :lax_friedrichs];
    varied_params = varied_params
)

# 4. Run the Pipeline (optional, is run by the Studio automatically)
set_save_path!(joinpath(@__DIR__, "results"))
run_all_simulations(config, parallel=true, calculate_stats=true)
```

### 2. Start the preferred backend and launch the Studio:

```julia
using GLMakie # Switch to WGLMakie for browser rendering

# Launch the interactive studio
fig = launch_plotter()

# Display the interactive studio
display(fig)
```

### 3. Attach your created config to the Studio and run the simulation

```julia
# Bind the physics to the UI
set_sim_config!(config)

# Force the initial calculation (optional, can also be done in the GUI)
force_simulation() 
```

### 4. Explore your simulation data in the Studio!

---

Portions of this codebase and documentation were drafted with the assistance of large language models (LLMs). All code has been human-reviewed, verified, and tested. If you notice any inaccuracies or unexpected behavior, please open an issue.
