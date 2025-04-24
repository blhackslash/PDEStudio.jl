# IPlotPDESols.jl

**I**nteractive **Plot**ting for **PDE Sol**utions using Makie.jl

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)](#) [![Code Coverage](https://img.shields.io/badge/coverage-??%25-lightgrey)](#) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](#) ## Overview

`IPlotPDESols.jl` provides interactive plotting tools built on [Makie.jl](https://makie.org/) specifically designed for visualizing and comparing results from numerical Partial Differential Equation (PDE) solvers, particularly those arising from meshfree methods or simulations generating time-series data.

It allows users to easily generate plots with interactive controls for exploring different simulation methods, varying parameters, stepping through time, comparing statistics, and saving results.

**Key Features:**

* Interactive visualization of 1D (`u` vs `x` over `t`) and 2D (`u` vs `x,y` over `t`) simulation data[cite: 5].
* Support for animations with playback controls and GIF saving[cite: 6].
* Convergence plots showing statistics against a varied parameter or another statistic[cite: 6, 488, 569].
* Dynamic plots showing the evolution of selected statistics over time[cite: 6, 266].
* Automatic generation of UI controls (sliders, textboxes, toggles/checkboxes) based on simulation parameters defined in a `SimulationConfig`[cite: 6].
* Separation of shared and method-specific parameters with UI interactivity[cite: 10, 55].
* Option to mark specific parameters as non-interactive constants using a `(:const, value)` convention [implicit from previous discussion].
* Automatic saving/loading of simulation data (`SimData1D`, `SimData2D`) based on parameter hashes using JLD2[cite: 5, 762, 773, 787].
* Functions to manage save paths and query/modify saved data[cite: 5, 762].

## Installation

Currently, `IPlotPDESols` is likely a local package. To use it in another project (e.g., your `Meshfree4ScalarEq` testing environment):

1.  **Navigate** to your other project's directory in the Julia REPL.
2.  **Activate** that project's environment: `] activate .`
3.  **Add `IPlotPDESols` locally:** Use `dev` with the *relative path* to your `IPlotPDESols` folder.
    ```julia
    # In Pkg mode (press ])
    pkg> dev path/to/IPlotPDESols
    ```
    (Replace `path/to/IPlotPDESols` accordingly, e.g., `../IPlotPDESols` if it's in the parent directory).
4.  **Ensure Dependencies:** Make sure the necessary backend (`GLMakie`) and other dependencies (`CSV`, `DataFrames`, etc.) are added to the environment you are working in.
    ```julia
    # In Pkg mode
    pkg> add GLMakie CSV DataFrames Dates StatsBase FileIO SHA JLD2
    ```

## Quick Start

Here's a basic example assuming you have defined a `sim_function` that takes `ParamDictType` and returns `SimData1D`, and defined your `Structs` (including `SimulationConfig`, `ParamDictType`, `MethodDictType`, `SimData1D`).

```julia
using IPlotPDESols
using GLMakie # Or another Makie backend

# 1. Define your simulation function (must match signature)
# Example dummy function:
function my_dummy_1d_runner(params::ParamDictType)
    t = 0.0:0.1:params["tmax"]
    x = [collect(0:0.1:1.0) for _ in t]
    u = [sin.(xi .* pi) .* cos(ti * params["rate"]) for (xi, ti) in zip(x, t)]
    # Use createSimData defined in IPlotPDESols.Structs
    return createSimData(params, t, x, u, ParamDict()) # Added params argument
end

# 2. Define the Simulation Configuration
sim_config = SimulationConfig(
    my_dummy_1d_runner,        # Your function
    ParamDictType(             # Shared Parameters
        "tmax" => 2.0,
        "rate" => (:const, 5.0) # Example constant parameter
    ),
    MethodDictType(            # Method-specific parameters/overrides
        "MethodA" => ParamDictType(),
        "MethodB" => ParamDictType("rate" => 10.0) # Override shared param
    ),
    "MethodA"                  # Default method to run/show
    # ui_options = ParamDict(...) # Optional UI settings
)

# 3. Generate the interactive plot
fig, control_fig = show1DSolutionFig_with_animation(sim_config)

# 4. Display (in interactive session)
# display(GLMakie.Screen(), control_fig)
# display(GLMakie.Screen(), fig)

# Keep Julia running to interact with the plot
println("Figures created. Close windows or Ctrl+C to exit.")
# wait() # Or use other methods to keep the session alive if needed
