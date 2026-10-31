## Deep Dive: The Editors

The editor tabs (*Methods*, *Shared*, *UI*, *Advanced*) sit at the heart of the interface. They expose the backend's data structures, so you can change solver settings, sweeps and styles without touching the REPL.

### 🎛️ The Editor Pages

The editor shows the **Shared** tab (one page: the shared parameters), the **UI** tab (an **overview** with one
button per page), the **Methods** and **Advanced** tabs (see below) and the pages of the **Files** tab (export
settings, resolution, presets). A page lists every entry as a row: the name, the value and a button. **◀ Back**
returns to the overview; pages with more entries than rows are split into pages that **◀ ▶** turn. Each tab
remembers its page while you switch tabs.

The editor is built from a fixed set of rows and buttons that are bound to the page you open, so pages appear without
rebuilding the window. From code, `PDEStudio.show_editor_page!(:ui, :hud)` opens a page (`show_editor_page!(:ui)` the
overview, `show_editor_page!(:shared)` the shared parameters).

#### Setting Values
Type a new value into a row and press Enter. Input is parsed with the safe literal parser `str2val`: numbers, symbols (`:upwind`), strings, tuples (`(64, 64)`), vectors (`[0.1, 0.2]`, `Float64[0.1, 0.2]`), dictionaries and ranges (`0.1:0.1:0.5`). **Nothing you type is ever evaluated as code.**

*   **Text stays text:** if a parameter currently holds text, whatever you type is stored as text, even if it looks like a number or a name (`1e3`, `Float64`, `sin`). Quotes are optional. `<empty>` stands for the empty string.
*   **The row button:** **on / off** toggles a Boolean; **↺** restores the default (like typing `default`, below).
*   **`default`:** typing `default` (or clicking ↺) restores the built-in value of a UI option, the value of the bound configuration for a shared or method parameter (the one *Files → Simulation → Reset* returns to), or the built-in display name of a label.
*   **Invalid input is refused:** text that is no literal (e.g. `[1, 2` or `abc` for a number) is not stored for a parameter that isn't text, and the status line says why. To make a parameter text, quote it (`"abc"`). Colours (`#1f77b4`, `red`) may be typed without quotes.
*   **Types matter for the cache:** simulation results are stored under a hash of the parameters, and the hash includes the value's type. `Any[:a, :b]` and `[:a, :b]` (a `Vector{Symbol}`) are different values, so changing one into the other computes the simulation again. Keep the displayed format if you only want to change entries.

### 📂 The Shared Tab

`config.shared`, the parameters every run uses, with the conveniences above (text stays text, ↺ restores the bound
configuration). Everything else of the configuration is edited elsewhere: the methods and their order in the
**Methods** tab, the sweep and the fields (`defaults`, `reference`, `postprocess`, `sources`) in the **Advanced**
tab, the presets in the **Files** tab.
*   **Trigger Behavior:** physics changes alter the data, so any edit here turns `Run Simulation` yellow and locks the plot until you re-run. Edits are only blocked while a simulation is running.

### 🎨 The UI Tab

The look of the renderer and the display names. The overview is fixed and lists every page:
*   **General:** *Axis General* (font sizes, legend sorting), *HUD*, *Outliers & Extrema*.
*   **Labels:** *Plot* (the title and the axis, colorbar and legend labels of the plot) and the display names of
    *Components* (`component_1`, …), *Variables* (dimensions and swept parameters) and *Methods*. *Example:* if your
    solver names a swept parameter `:rho`, the UI shows "Rho"; open *Variables* and type `Density` into the `rho`
    row: every dropdown, legend and slider label now says "Density". Display names are text; `default` restores the
    built-in name. They are stored in exports and look presets.
*   **Axes:** one page per axis variant: *X/Y Axis (1D)* for 1D plots, *X/Y Axis (2D/3D)* for 2D and 3D plots, *Z Axis (3D)*. Each variant keeps its own settings, so switching between a 1D and a 2D plot doesn't lose them.
*   **Plot styles:** one page per plot type with the options that type uses (colours, colormap, line width, markers, levels, …). The options are shared between the plot types that use them (e.g. one colormap for all colormap plots).
*   The pages of the active plot (its plot type and axis variants) are highlighted. The look presets, the export settings and the resolution are in the **Files** tab.
*   **Trigger Behavior:** changes trigger a visual update; options that change the drawn data (e.g. the method index of a comparison) redraw the plot.

### ⚙️ The Methods Tab

The **Methods** tab lists every method of the configuration (numerical methods and analytical references) in the
automatic order: references first, then alphabetical.
*   **active / off** activates or deactivates a method. This changes `config.defaults` (an activated method is
    appended to the drawing order), so the `Run Simulation` lock is set to compute it.
*   **Show: active / disabled / all** filters the list (click to cycle).
*   **Edit ›** opens the parameter overrides of the method (`config.methods[m]`) as an editor page, for inactive
    methods too; **◀ Back** returns to the list.
*   **Order ▲▼** shows the active methods in drawing order (`defaults`: legends, colours and the *Methods*
    comparison follow it), numbered from the top. **▲ / ▼** move a method; the new order is drawn after the next
    *Run Simulation* (cached results are reused). **◀ Method list** returns to the list.
*   The title shows how many methods are active; long lists get ◀ ▶ pages.

### 🧰 The Advanced Tab

The **Advanced** tab edits the `SimulationConfig` directly, bypassing every convenience of the other tabs. Its
overview has four pages: `Shared` (`config.shared`), `Sweep` (`config.varied`), `Config` (the fields `defaults`,
`reference`, `postprocess`, `sources`) and *Methods ›*, the list of every method of `config.methods`, active or not,
on full-width rows (long names fit; long lists get ◀ ▶ pages).
*   **Values are Julia literals with their type**, shown exactly as stored: `20`, `0.5`, `"upwind"` (text is
    quoted), `:symbol`, `Float64[0.2, 0.5]`, `(500,)`, `nothing`. What you type is parsed the same way and stored
    as it is: no text fallback (unquoted text is refused), no single-value sweeps (a sweep must be a vector).
*   **✕ deletes a key** from `shared`, `varied` or a method (the fields of `Config` can't be deleted).
*   **Adding a key:** the row below the entries takes the name, the **type** (`auto` reads the literal as typed;
    `Int`, `Float64`, `Bool`, `String`, `Symbol`, `Tuple` and vectors of `Float64`, `Int`, `Symbol` or `String`
    convert the text, so `[a, b]` with `Vector{Symbol}` gives `[:a, :b]`) and the value.
*   **Methods:** in the method list, **Edit ›** opens a method's parameters (◀ Back returns to the list) and **✕**
    deletes it from the configuration and from the active methods; *Add method* below the list creates an (inactive)
    method without overrides and opens it.
*   Every change sets the `Run Simulation` lock: the configuration changed, so everything is computed again (results
    with unchanged parameters are reused from the cache).

