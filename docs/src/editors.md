## Deep Dive: Advanced Editors

The "Parameter & UI Editor" and the "Method Controls" sit at the heart of the interface. They expose the backend's data structures, so you can change solver settings, sweeps and styles without touching the REPL.

### 🎛️ The Editor Pages

The editor is shown in the **Simulation**, **UI** and **Labels** tabs; the tab is the category. Each tab opens on an
**overview** with one button per page (scope), e.g. *Presets (2)*, *Shared (14)*, *Sweep (1)*, *Config (5)* and one
per active method; the number is the number of entries. A page lists every entry of its scope as a row: the name, the
value and a button. **◀ Back** returns to the overview; scopes with more entries than rows (and overviews with more
pages than buttons) are split into pages that **◀ ▶** turn. Each tab remembers its page while you switch tabs.

The editor is built from a fixed set of rows and buttons that are bound to the page you open, so pages appear without
rebuilding the window. From code, `PDEStudio.show_editor_page!(:simulation, :shared)` opens a page
(`show_editor_page!(:ui)` the overview of a tab).

#### Setting Values
Type a new value into a row and press Enter. Input is parsed with the safe literal parser `str2val`: numbers, symbols (`:upwind`), strings, tuples (`(64, 64)`), vectors (`[0.1, 0.2]`, `Float64[0.1, 0.2]`), dictionaries and ranges (`0.1:0.1:0.5`). **Nothing you type is ever evaluated as code.**

*   **Text stays text:** if a parameter currently holds text, whatever you type is stored as text, even if it looks like a number or a name (`1e3`, `Float64`, `sin`). Quotes are optional. `<empty>` stands for the empty string.
*   **The row button:** **on / off** toggles a Boolean; **↺** restores the default (like typing `default`, below); **Apply** applies a preset.
*   **`default`:** typing `default` (or clicking ↺) restores the built-in value of a UI option, the value of the bound configuration for a simulation entry (the one *Reset Simulation* returns to), or the built-in display name of a label.
*   **Types matter for the cache:** simulation results are stored under a hash of the parameters, and the hash includes the value's type. `Any[:a, :b]` and `[:a, :b]` (a `Vector{Symbol}`) are different values, so changing one into the other computes the simulation again. Keep the displayed format if you only want to change entries.

### 📂 The Categories

The tab selects which part of the studio you edit.

#### 1. Simulation
The `PDEStudioCore` configuration. Scopes:

| Scope | Edits |
| :--- | :--- |
| **Presets** | Simulation presets: one row per preset (its description, editable) with an **Apply** button; type the description of the next preset you save into the `create_new` row (see [Presets](presets.md)). |
| **Shared** | `config.shared`, the parameters every run uses. |
| **Sweep** | `config.varied`, the swept values. A single value becomes a one-value sweep; in a sweep of text values, unquoted items stay text (`[upwind, lax_friedrichs]`). The sliders are remapped immediately. (A swept key only takes effect if it exists in the shared or method parameters.) |
| **Config** | `defaults` (the active methods, in the order they are drawn: legends, colours and the *Methods* comparison follow it, so reorder the list here to override the automatic order), `permutation` (the same order as indices, see below; both rows are on the same page), `reference` and `postprocess` (function names; `none` clears one), `sources`. |
| *each method* | The parameter overrides of that method (`config.methods[m]`). Only the active methods are listed; activate a method to edit it. |

*   **Reordering methods with `permutation`:** long method names make `defaults` tedious to reorder (`Symbol[Symbol("SSPRK3MUSCL2(EPD2)"), …]`). `permutation` shows the same order as indices into the automatic order of the active methods, i.e. references first, then alphabetical, the order in which the method dropdown and the overview list them. With the active methods `analytic`, `lax_friedrichs` and `upwind`, the permutation `[3, 2, 1]` stands for `[:upwind, :lax_friedrichs, :analytic]`. Type a new permutation (`[1, 3, 2]` or `(1, 3, 2)`) to reorder `defaults`; it needs one index per active method. `default` restores the order of the bound configuration (or the automatic order if the active methods differ from it). Only `defaults` is stored in CSV files and presets.
*   **Trigger Behavior:** physics changes alter the data, so any edit here turns `Run Simulation` yellow and locks the plot until you re-run. Edits are only blocked while a simulation is running.
*   **Context-sensitive buttons:** in this tab, the preset buttons read **Save Sim Preset** and **Reset Simulation**.

#### 2. UI
The visual styles, layout templates and export settings of the renderer, plus **Presets** (the visual presets, applied with **Apply**). The *Plot Style* page lists only the options of the selected plot style.
*   **Trigger Behavior:** changes trigger a visual update; options that change the drawn data (e.g. the method index of a comparison) redraw the plot.
*   **Titles and axis labels** are set here under **UI → Labels**.

#### 3. Labels (Display Names)
A dictionary that renames backend keys for the frontend: components (`component_1`, …), variables (dimensions and swept parameters) and methods.
*   *Example:* if your solver names a swept parameter `:rho`, the UI shows "Rho". Open *Labels → Variables*, type `Density` into the `rho` row: every dropdown, legend and slider label now says "Density". Labels are text; `default` restores the built-in name. Labels are stored in exports and visual presets.

### ⚙️ Method Controls

In the **Simulation** tab, below the editor, is the method toggle, which hot-swaps the active numerical methods and analytical references.
*   Click the **Mode** button to switch between `Activate` (add a method) and `Deactivate` (remove one).
*   Select the method in the dropdown. This changes `config.defaults` (an activated method is appended), so the `Run Simulation` lock is set to compute the new method. (The same list is editable as *Simulation → Config → defaults*, which is also where you change the order.)
