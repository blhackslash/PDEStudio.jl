# PDEStudio.jl

**PDEStudio.jl** is a highly interactive, Makie-driven graphical frontend designed for the real-time visualization and exploration of Partial Differential Equation (PDE) simulations. 

Built directly on top of its core numerical dependency, **PDECore.jl**, this framework transforms strictly typed simulation data into responsive 1D, 2D, and 3D visualizations. It features a hierarchical UI editor, robust CSV-based preset management, and a flexible rendering engine capable of handling both Eulerian grids and Lagrangian particle systems on the fly.

> **Note:** This package serves exclusively as the graphical user interface and visualization engine, and relies entirely on **PDECore.jl** to run. For headless deployments, cluster computing, or purely numerical workflows, see the core simulation package: **PDECore.jl**.

---

## 🎨 Interactive Architecture

The studio is built around a centralized, reactive state manager that links your live simulation memory directly to the Makie render loop. 

*   **Eulerian & Lagrangian Support:** Automatically adapts rendering primitives—seamlessly switching from grid-based volume renders and heatmaps to point-based 3D scatter and surface plots based on the active backend data type.
*   **Hierarchical Editor:** Exposes backend parameters (physics, grid resolutions, UI styles, and export settings) in a unified, strictly typed control panel.
*   **Dynamic Layouts:** Automatically handles complex multi-column comparisons, decoupled axes, and detached legends without wiping the plot state.

---

## 💾 Serialization & Presets

**PDEStudio.jl** features a robust, two-way cryptographic serialization pipeline built on the CSV RFC 4180 standard.

| Feature | Description |
| :--- | :--- |
| **State Preservation** | Saves the exact state of your UI, camera angles, and physics parameters to highly readable CSV files. |
| **Type-Stable Parsing** | Leverages Julia's Abstract Syntax Tree (AST) to securely parse configuration files, ensuring arrays, symbols, and nested dictionaries are recreated with perfect type stability. |
| **Drag-and-Drop** | Instantly recreate complex simulation states by dropping a previously exported CSV directly into the UI text prompt. |

---

## 📽️ Exporting & Animations

The studio is built for publication-quality output. It provides a dedicated export pipeline decoupled from the active UI rendering limits.

*   **Static Frames:** Export high-DPI figures in `.png`, `.pdf`, or `.svg` formats with customizable rasterization qualities for heavy 3D plots.
*   **Animations:** Generate smooth `.mp4` videos with locked camera tracking, custom frame rates, and automated layout synchronization to prevent visual tearing between frames.

---

## 🚀 Main API Functions

*   **`launch_plotter()`:** Initializes the main Makie window, builds the unified control panel, and prepares the reactive render listeners.
*   **`set_sim_config!(config::SimulationConfig)`:** Binds a configured `PDECore.jl` simulation setup to the UI, allowing you to tweak parameters and execute headless runs directly from the studio.
*   **`reset_plotter!()`:** Safely detaches all reactive listeners, clears the cache, and destroys the active window without requiring a Julia restart.

---

## 📦 Basic Workflow

```julia
using PDECore
using PDEStudio

# 1. Define your backend physics (PDECore)
my_config = SimulationConfig(...)

# 2. Launch the interactive studio
fig = launch_plotter()

# 3. Bind the physics to the UI and explore
set_sim_config!(my_config)
```
