# PDEStudio.jl

[![Build Status](https://github.com/blhackslash/PDEStudio.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/blhackslash/PDEStudio.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/blhackslash/PDEStudio.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/blhackslash/PDEStudio.jl)
[![Dev Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://blhackslash.github.io/PDEStudio.jl/dev/)

**PDEStudio.jl** is a highly interactive, Makie-driven graphical frontend engineered for the real-time visualization and exploration of Partial Differential Equation (PDE) simulations. It serves as the visual counterpart to the autonomous numerical backend, [PDEStudioCore.jl](https://github.com/blhackslash/PDEStudioCore.jl).

The studio seamlessly handles both Eulerian grids and Lagrangian particle systems, dynamically adapting its primitives to support 1D, 2D, and 3D visualization. It features a hierarchical UI editor, robust cryptographic CSV serialization for state preservation, and an independent export pipeline for publication-quality static frames and animations.

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

```julia
using PDEStudio
using GLMakie # Switch to WGLMakie for browser rendering

# 1. Define your backend physics (PDEStudioCore is reexported)
my_config = SimulationConfig(...)

# 2. Launch the interactive studio
fig = launch_plotter()

# 3. Display the interactive studio
display(fig)

# 4. Bind the physics to the UI and explore
set_sim_config!(my_config)
```