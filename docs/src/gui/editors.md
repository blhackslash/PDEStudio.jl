## Deep Dive: Advanced Editors

The "Parameter & UI Editor" and the "Method Controls" sit at the heart of the interface. This region exposes the raw power of the underlying Julia backend, allowing you to manipulate complex data structures and solver states without ever touching the REPL or writing a line of code.

### 🎛️ The Hierarchical Editor

This editor uses a cascading three-tier dropdown system (**Category** $\rightarrow$ **Scope** $\rightarrow$ **Parameter**). Selecting a specific parameter binds its current memory value to the text box below it.

#### Setting Values & Strict Typing
Because PDEStudio acts as a direct bridge to a highly-typed numerical backend, the text box uses Julia's native abstract syntax tree (AST) to safely parse your inputs. 
*   **Simple Values:** For basic numbers or strings, simply type the new value (e.g., `100` or `0.05`) and hit Enter. If the value is a boolean (`true`/`false`), you can just click the gray **Toggle** button next to the text box.
*   **Advanced Structures (Vectors & Dicts):** You can edit complex arrays and dictionaries directly, but **you must maintain the exact Julia type signature** displayed in the box. The frontend and backend rely on a strict type bijection to communicate. 
    *   *Example:* If a parameter array is displayed as `Any[:a, :b]`, you must type your changes maintaining the `Any` wrapper (e.g., `Any[:a, :c]`). Typing `[:a, :c]` will create a strictly typed `Vector{Symbol}`, which may crash the backend or break the UI's ability to map the parameter to a slider. Always copy the exact formatting provided!

### 📂 Understanding the Categories

The first dropdown dictates which part of the studio's memory you are editing. The behavior of the UI changes drastically depending on your selection:

#### 1. Simulation
This category exposes your `PDEStudioCore` physics parameters. You can edit the `Shared` parameter pool or drill down into specific method overrides. 
*   **Trigger Behavior:** Because changing physics alters the mathematical truth of the data, modifying anything in this category will immediately lock the plot and turn the `Run Simulation` button yellow. You must re-run the simulation to see your changes.

#### 2. UI
This category controls the visual aesthetics, layout templates, and export settings of the Makie rendering engine.
*   **Trigger Behavior:** Changing values here (like line widths, colormaps, or paddings) will automatically trigger a visual update, turning either `Update Plot` or `Apply Layout` yellow depending on whether the change requires the grid to be rebuilt.
*   **A Note on Titles:** If you want to change the actual text of the Plot Title, X-Axis Label, or Y-Axis Label, you do so here under **UI $\rightarrow$ labels**. 

#### 3. Labels (The Backend Dictionary)
*Crucial Distinction:* This category is often confused with the plot titles mentioned above. The `Labels` category is strictly a dictionary for **renaming backend keys for the frontend**.
*   *Example:* If your backend code names a variable `:rho`, the UI will naturally display it as "Rho". By going to the `Labels` category, selecting the variable, and typing `"Density"`, every dropdown menu, legend, and slider in the GUI will instantly update to say "Density" instead of "Rho". It maps internal code logic to human-readable strings.

### ⚙️ Method Controls

Directly below the text box is the Method Toggle. This allows you to hot-swap which numerical solvers or analytical baselines are actively running.
*   Click the **Mode** button to switch between `Activate` (add a method to the simulation) and `Deactivate` (remove a method). 
*   Select the method from the dropdown. This inherently modifies the `SimulationConfig`, so it will automatically trigger the `Run Simulation` lock to ensure the new method is calculated.
