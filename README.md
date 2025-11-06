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

## Core Concepts

### `SimulationConfig` [cite: 1]

This struct [cite: 1] is the main input for the plotting functions. It bundles together the necessary information to run simulations and configure the plot:

* `sim_function::Function`: A function you provide that takes a single argument `params::ParamDictType` (a `Dict{String, Any}`) and runs your simulation, returning an `AbstractSimData` object (like `SimData1D` or `SimData2D`)[cite: 1].
* `shared_params::ParamDictType`: A `Dict{String, Any}` holding parameters that are common across different simulation methods or that you want to control interactively for all active methods[cite: 1]. You can mark parameters as non-interactive using the `(:const, value)` tuple convention (e.g., `"SEED" => (:const, 10)`).
* `methods_dict::MethodDictType`: A `Dict{String, ParamDictType}` where keys are method name strings (e.g., `"EulerUpwind"`, `"RK3MUSCL1"`)[cite: 1]. The corresponding value is another `ParamDictType` containing only the parameters that are specific to that method or override a value from `shared_params` for that method[cite: 1].
* `default_method::String`: A string specifying which method key from `methods_dict` should be active by default when the plot opens[cite: 1]. This key must exist in `methods_dict`[cite: 2].
* `ui_options::ParamDictType`: An optional `Dict{String, Any}` to override default UI settings used by the plotting functions (e.g., `figsize`, `colors`, plotting style toggles)[cite: 2].

### Data Handling (`Utils.jl`) [cite: 5]

The package includes utilities for managing simulation data:

* **Automatic Saving/Loading:** Simulations run via the plotting functions (if they use the `sim_function` defined in `SimulationConfig` which calls `loadOrRun`) can automatically save their results (`SimData1D` [cite: 1] or `SimData2D` [cite: 3] objects) using `Utils.saveSimData`[cite: 773]. Data is loaded using `Utils.loadSimData`[cite: 762].
* **Hashing:** Data filenames are based on a SHA256 hash of the *final merged parameters* (shared + method-specific overrides + method name) used for that specific run[cite: 773], ensuring that identical runs are not recomputed unless necessary. `Utils.calculateHash` performs this calculation[cite: 762].
* **File Structure:** Data is saved in `.jld2` format within a `data/` subdirectory relative to the path configured using `Utils.set_save_path!`[cite: 762, 765]. Figures and parameter CSVs are saved in a `figures/` subdirectory[cite: 769]. It is recommended to set a common save path for your project[cite: 764].
* **Utilities:** Functions like `Utils.doesSimDataExist`[cite: 787], `Utils.getFileName`[cite: 778], `Utils.getStats`[cite: 762], `Utils.deleteSimData`[cite: 791], `Utils.getAllSimData` [cite: 797] are provided for data management.

### Plotting Functions (`MakiePlotting.jl`) [cite: 6]

The core interactive functions provided are:

* `show1DSolutionFig_with_animation`: For `SimData1D`, plots `u` vs `x` over time with method comparison, parameter controls, animation, GIF/parameter saving, and optional max value tracking[cite: 6].
* `show2DSolutionFig`: For `SimData2D`, plots `u` vs `x, y` over time with method comparison, parameter controls, animation, GIF/parameter saving, 3D/2D view toggle, and colormap selection[cite: 8, 311, 377, 378, 379, 380, 381].
* `showConvergencePlot` (two versions): Plots user-selected statistics against a varied parameter or another statistic, often used for convergence studies[cite: 6, 488, 569, 656]. Includes time selection if statistics are time-dependent and log-scale toggles.
* `showDynamicDependence`: Plots user-selected statistics against time for different methods[cite: 6, 266].

*(Note: You might want to rename `show1DSolutionFig_with_animation` to just `show1DSolutionFig` if it's now the primary version)*.

## Documentation

*(Placeholder: Link to more detailed documentation, perhaps generated with Documenter.jl, once available. You could explain the `SimData` structures[cite: 1, 3], the `Utils` functions[cite: 762], and details of each plotting function here).*

## Contributing

*(Placeholder: Add guidelines if you expect contributions).*

## License

*(Placeholder: Specify your chosen license, e.g., MIT License).*
