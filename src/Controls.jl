# ==============================================================================
# --- 1. MASTER CONTROL BUILDER ---
# ==============================================================================

# Width of the control panel (pixels).
const CONTROL_WIDTH = 500

# Tabs of the control panel and their button labels. The Methods tab, the three editor categories (Simulation, UI,
# Labels) and the Advanced tab show the editor; the Methods tab edits the simulation configuration through the
# studio's views, the Advanced tab edits the `SimulationConfig` itself.
const CONTROL_TABS = (:plot, :methods, :simulation, :ui, :labels, :files, :advanced)
const TAB_LABELS = Dict(:plot => "Plot", :methods => "Methods", :simulation => "Simulation", :ui => "UI",
                        :labels => "Labels", :files => "Files", :advanced => "Advanced")
const EDITOR_TABS = (:methods, :simulation, :ui, :labels, :advanced)
const TAB_ROWGAP = 12   # gap between the panels of a tab

# The panels (widget groups) each tab shows, top to bottom. The editor panel is shared by the editor tabs.
const TAB_PANELS = Dict(:plot => (:layout, :plot), :methods => (:editor,), :simulation => (:editor,),
                        :ui => (:editor,), :labels => (:editor,), :files => (:files,), :advanced => (:editor,))
const TAB_PANEL_NAMES = (:plot, :layout, :editor, :files)

# The Files tab shows its panel, or one of its editor pages: the export settings (`EXPORT_SETTINGS`, `ui[:export]`),
# the list of the simulation or look presets (`PRESET_LIST`) or the rows of a preset file (`PRESET_FILE`). The Plot
# tab shows its options, or the page of all plot styles (`STYLE_CHOOSER`).
const EXPORT_SETTINGS = :export
const PRESET_LIST = Symbol("#presets")
const PRESET_FILE = Symbol("#preset_file")
const STYLE_CHOOSER = Symbol("#styles")
const TAB_EDITOR_PAGES = Dict(:files => (EXPORT_SETTINGS, PRESET_LIST, PRESET_FILE), :plot => (STYLE_CHOOSER,))

# Types offered when a key is added in the Advanced tab (`auto`: the literal as typed).
const RAW_VALUE_TYPES = (:auto, :Int, :Float64, :Bool, :String, :Symbol, :Tuple,
                         Symbol("Vector{Float64}"), Symbol("Vector{Int}"), Symbol("Vector{Symbol}"), Symbol("Vector{String}"))

# The Methods tab lists the methods (`nothing`), shows the drawing order (`ORDER_VIEW`) or the page of a method.
const ORDER_VIEW = Symbol("#order")
const METHOD_FILTERS = (:active, :disabled, :all)

# The editor shows an overview of the pages (scopes) of its category, or one page with a row per key. Both are
# fixed sets of widgets, bound to the selected category / scope on the fly (see `_render_editor!`).
const EDITOR_ROWS = 12        # key rows of a page; longer scopes get ◀ ▶ pages
const OVERVIEW_BUTTONS = 30   # page buttons of an overview (UI: 5 general + 5 axes + up to 17 plot styles)
const OVERVIEW_COLS = 3
const OVERVIEW_SECTIONS = 5   # titled groups of an overview (UI: General, Axes, Plot styles; plot styles: one per base plot)
const EDITOR_ROWGAP = 4
const SLIDER_ROWGAP = 5

"""
    create_controls(layout::GridLayout)

Constructs the primary control panel inside the provided Makie `GridLayout`, top to bottom:

1. The tab bar (`Plot`, `Methods`, `Simulation`, `UI`, `Labels`, `Files`, `Advanced`).
2. The tab content: the panel(s) of the selected tab (see `TAB_PANELS`). Every panel is built once; the panels of
   the other tabs are parked off-screen by `show_tab!`.
3. The status line (see `_status!`).
4. Animation playback and camera locking.
5. The execution triggers (Run Simulation, Apply Layout, Update Plot).
6. The parameter and dimension sliders (rows without a choice to make are parked, see `_sync_slider_rows!`).

Widgets are created once per window and never deleted or recreated (Makie does not support recreating interactive
widgets well). It finalizes construction by injecting the persistent layout, plot and exploration caches of the
manager.
"""
function create_controls(layout::GridLayout)
    rowgap!(layout, 12)
    colsize!(layout, 1, Fixed(CONTROL_WIDTH))

    # --- 1. TAB BAR ---
    # each tab is as wide as its label (plus padding), the rest of the row is shared evenly
    tab_bar = layout[1, 1] = GridLayout()
    label_widths = [Makie.widths(Makie.text_bb(TAB_LABELS[t], Makie.to_font("TeX Gyre Heros Makie"), 13))[1] for t in CONTROL_TABS]
    spare = (CONTROL_WIDTH - 3 * (length(CONTROL_TABS) - 1) - sum(label_widths)) / length(CONTROL_TABS)
    for (i, tab) in enumerate(CONTROL_TABS)
        manager.widgets[Symbol("tab_", tab)] = Button(tab_bar[1, i], label = TAB_LABELS[tab], width = nothing,
                                                      fontsize = 13, padding = (2, 2, 6, 6))
        colsize!(tab_bar, i, Fixed(floor(label_widths[i] + spare)))
    end
    colgap!(tab_bar, 3)

    # --- 2. TAB CONTENT: every panel is built here, then all but the selected tab's are parked ---
    area = layout[2, 1] = GridLayout(valign = :top, tellheight = false)
    manager.tab_area = area
    panels = manager.panels
    empty!(panels)

    panels[:plot] = area[1, 1] = GridLayout()
    build_plot_options!(panels[:plot])

    panels[:layout] = area[1, 1] = GridLayout()
    build_layout_options!(panels[:layout])

    panels[:editor] = area[1, 1] = GridLayout()
    create_editor_controls!(panels[:editor])

    panels[:files] = area[1, 1] = GridLayout()
    create_file_controls!(panels[:files])

    # Parked panels sit in a layout outside the figure, where they can neither be seen nor clicked.
    manager.panel_park = GridLayout(1, 1; bbox = Rect2f(-200_000, -200_000, 100_000, 2000))
    manager.active_tab[] = :plot   # every window opens on the Plot tab
    show_tab!(:plot)
    # The tab content keeps the height of the tallest tab, so the controls below it never move.
    rowsize!(layout, 2, Fixed(_max_tab_height(area)))

    # --- 3. STATUS LINE: the result of the last action (edits, method changes, presets, runs, loads, exports) ---
    manager.widgets[:status] = Observable("Ready.")
    manager.widgets[:status_color] = Observable{Any}(STATUS_COLORS[:info])
    Label(layout[3, 1], manager.widgets[:status], color = manager.widgets[:status_color], fontsize = 12,
          halign = :left, valign = :top, justification = :left, tellwidth = false)
    rowsize!(layout, 3, Fixed(30))

    # --- 4. CAMERA & ANIMATION CONTROLS ---
    bottom_ops = layout[4, 1] = GridLayout()
    manager.widgets[:play_anim_button]   = Button(bottom_ops[1, 1], label="Play Anim", buttoncolor=:lightyellow, width=nothing)
    manager.widgets[:lock_camera_button] = Button(bottom_ops[1, 2], label="Lock Camera", buttoncolor=:lightblue, width=nothing)
    for i in 1:2; colsize!(bottom_ops, i, Relative(1/2)); end

    # --- 5. EXECUTION CONTROLS ---
    exec_layout = layout[5, 1] = GridLayout()
    manager.widgets[:run_button]   = Button(exec_layout[1, 1], label="Run Simulation", buttoncolor=:lightgreen, width = nothing)
    manager.widgets[:layout_apply] = Button(exec_layout[1, 2], label="Apply Layout", buttoncolor=:lightgreen, width=nothing)
    manager.widgets[:plot_button]  = Button(exec_layout[1, 3], label="Update Plot", buttoncolor=:lightgreen, width=nothing)
    for i in 1:3; colsize!(exec_layout, i, Relative(1/3)); end

    # --- 6. SLIDERS (last: only the rows with a choice to make are shown; the area keeps the height of all rows) ---
    slider_area = layout[6, 1] = GridLayout(valign = :top, tellheight = false)
    build_sliders!(slider_area)
    rowsize!(layout, 6, Fixed(ceil(Int, something(Makie.GridLayoutBase.determinedirsize(slider_area, Makie.GridLayoutBase.Row()), 0f0))))
    _sync_slider_rows!()

    # Restore from the persistent cache instead of hard defaults
    apply_layout_options!(manager.layout_cache)
    apply_plot_options!(manager.plot_cache)
    apply_exploration_options!(manager.exploration_cache)
end

# Height of the tallest tab: the sum of the natural heights of its panels.
function _max_tab_height(area::GridLayout)
    gap = Float32(TAB_ROWGAP)
    heights = map(collect(keys(TAB_PANELS))) do tab
        hs = [something(Makie.GridLayoutBase.determinedirsize(manager.panels[p], Makie.GridLayoutBase.Row()), 0f0) for p in TAB_PANELS[tab]]
        sum(hs) + gap * (length(hs) - 1)
    end
    return ceil(Int, maximum(heights))
end

"""
    create_file_controls!(layout::GridLayout)

Builds the `Files` tab: the name / path box (exports, presets, CSV loading) and the description of a new preset;
loading a CSV (or drop a file anywhere on the window), export and its settings (an editor page of `ui[:export]`); and
the presets: save / reset the simulation (the physics) and the look (the visual settings), and *Presets ›*, the list
of the saved presets with *Apply* and *Edit ›* (the rows of the preset file). Results are shown in the status line.
"""
function create_file_controls!(layout::GridLayout)
    w = manager.widgets
    Label(layout[1, 1], "Name / path", halign = :left, fontsize = 13)
    w[:export_text] = Textbox(layout[1, 2:4], placeholder = "file name, preset name or CSV path", width = nothing)
    Label(layout[2, 1], "Description", halign = :left, fontsize = 13)
    w[:preset_desc_text] = Textbox(layout[2, 2:4], placeholder = "of a preset you save (optional)", width = nothing)

    Label(layout[3, 1], "File", halign = :left, fontsize = 13)
    w[:load_config_button]     = Button(layout[3, 2], label = "Load CSV", buttoncolor = :lightgray, width = nothing)
    w[:export_button]          = Button(layout[3, 3], label = "Export", buttoncolor = :lightblue, width = nothing)
    w[:export_settings_button] = Button(layout[3, 4], label = "Settings ›", width = nothing)
    Label(layout[4, 1:4], "CSV files can also be dropped anywhere on the window.", halign = :left, fontsize = 11,
          color = :gray40)

    Label(layout[5, 1:4], "Presets", halign = :left, font = :bold, color = :darkred)
    neutral = RGBf(0.92, 0.92, 0.92)
    Label(layout[6, 1], "Simulation", halign = :left, fontsize = 13)
    w[:save_sim_preset_button] = Button(layout[6, 2], label = "Save", buttoncolor = :lightblue, width = nothing)
    w[:reset_sim_button]       = Button(layout[6, 3], label = "Reset", buttoncolor = neutral, width = nothing)
    w[:sim_presets_button]     = Button(layout[6, 4], label = "Presets ›", width = nothing)
    Label(layout[7, 1], "Look", halign = :left, fontsize = 13)
    w[:save_presets_button]  = Button(layout[7, 2], label = "Save", buttoncolor = :lightblue, width = nothing)
    w[:clear_presets_button] = Button(layout[7, 3], label = "Reset", buttoncolor = neutral, width = nothing)
    w[:look_presets_button]  = Button(layout[7, 4], label = "Presets ›", width = nothing)

    colsize!(layout, 1, Fixed(100))
    rowgap!(layout, 3, 2)    # the hint belongs to the buttons above it
    rowgap!(layout, 4, 14)   # space before the presets
end

# ==============================================================================
# --- 2. STATIC PLOT CONTROLS BUILDERS ---
# ==============================================================================
"""
    NumberBox

A text box for a whole number (plot width and height, grid columns) that stands in for the dropdowns it replaced:
`selection` holds the value and changes only on valid input between `lo` and `hi`, so the layout watcher, the option
caches, presets and CSV files treat it like a menu. Invalid input is refused with a status message.
"""
struct NumberBox
    box::Textbox
    selection::Observable{Int}
    lo::Int
    hi::Int
end

function NumberBox(pos, value::Int; lo::Int, hi::Int, name::AbstractString)
    tb = Textbox(pos, placeholder = string(value), stored_string = string(value), displayed_string = string(value),
                 width = nothing)
    nb = NumberBox(tb, Observable(value), lo, hi)
    manager.listeners[Symbol("NumberBox_", name)] = on(tb.stored_string) do s
        s isa AbstractString || return
        v = tryparse(Int, strip(s))
        if isnothing(v) || !(lo <= v <= hi)
            _report(:warn, "$name: '$(strip(s))' is not a whole number between $lo and $hi.")
            _show_editor_text!(tb, string(nb.selection[]))
            return
        end
        v == nb.selection[] || (nb.selection[] = v)
    end
    return nb
end

"""
    StyleChoice

The plot style of the Plot tab: a button showing the current plot type, which opens the page of all plot styles
(`STYLE_CHOOSER`, see `_choose_plot_style!`). `selection` holds the plot type, so the layout watcher, presets and
CSV files treat it like the menus it replaced (there is no separate base plot any more).
"""
struct StyleChoice
    button::Button
    selection::Observable{Symbol}
end

function StyleChoice(pos, style::Symbol)
    sc = StyleChoice(Button(pos, label = _style_label(style) * "  ›", width = nothing), Observable(style))
    manager.listeners[:StyleChoice_Label] = on(s -> (sc.button.label[] = _style_label(s) * "  ›"), sc.selection)
    manager.listeners[:StyleChoice_Click] = on(_ -> show_editor_page!(:plot, STYLE_CHOOSER), sc.button.clicks)
    return sc
end

# Sets the plot style from code (presets, CSV files, the option caches); unknown or unavailable styles are ignored.
function _set_style!(sc::StyleChoice, val)
    s = Symbol(val)
    (haskey(PLOT_DIM_MAP, s) && (isempty(manager.allowed_styles) || s in manager.allowed_styles)) || return nothing
    s == sc.selection[] || (sc.selection[] = s)
    return nothing
end

# Sets the value of a `NumberBox` from code (presets, CSV files, the option caches).
function _set_number!(nb::NumberBox, val)
    v = val isa Integer ? Int(val) : tryparse(Int, string(val))
    isnothing(v) && return nothing
    v = clamp(v, nb.lo, nb.hi)
    v == nb.selection[] || (nb.selection[] = v)
    _show_editor_text!(nb.box, string(v))
    return nothing
end

# A row of a single-column options panel: the name on the left; returns the position of the widget on the right.
function _option_row!(gl::GridLayout, row::Int, name::AbstractString)
    Label(gl[row, 1], name, halign = :left, fontsize = 13)
    return gl[row, 2]
end

# Column widths and gaps of the options panels.
function _finish_option_panel!(gl::GridLayout)
    colsize!(gl, 1, Fixed(140))
    rowgap!(gl, 4)
    rowgap!(gl, 1, 8)   # below the section title
    return nothing
end

"""
    build_layout_options!(menu_layout::GridLayout)

Builds the upper half of the `Plot` tab, one option per row: the structural layout features applied with *Apply
Layout*: the plot style (chosen on a page of all styles, `StyleChoice`), plot width and height (`NumberBox`),
legend placement and the multi-plot comparison (target, grid columns, coupling).
"""
function build_layout_options!(menu_layout::GridLayout)
    w = manager.widgets
    Label(menu_layout[1, 1:2], "Layout options  (Apply Layout)", font = :bold, color = :darkred, halign = :left)

    w[:plot_style]  = StyleChoice(_option_row!(menu_layout, 2, "Plot Style"), manager.mode[] == :eulerian ? :lines_1d : :scatter_1d)
    w[:plot_width]  = NumberBox(_option_row!(menu_layout, 3, "Plot Width (px)"), 500; lo = 50, hi = 5000, name = "Plot Width")
    w[:plot_height] = NumberBox(_option_row!(menu_layout, 4, "Plot Height (px)"), 400; lo = 50, hi = 5000, name = "Plot Height")
    w[:legend_base] = Menu(_option_row!(menu_layout, 5, "Legend"),
                           options = Any[menu_opt(:none), menu_opt(:center), menu_opt(:left), menu_opt(:right), menu_opt(:top), menu_opt(:bottom)])
    w[:legend_add]  = Menu(_option_row!(menu_layout, 6, "Legend Placement"),
                           options = Any[menu_opt(:detached), menu_opt(:left), menu_opt(:right), menu_opt(:top), menu_opt(:bottom)])
    w[:compare_target]  = Menu(_option_row!(menu_layout, 7, "Compare"),
                               options = Any[menu_opt(:none), menu_opt(:methods), menu_opt(:component)])
    w[:compare_columns] = NumberBox(_option_row!(menu_layout, 8, "Grid Columns"), 2; lo = 1, hi = MAX_COMPARE_PLOTS, name = "Grid Columns")
    w[:compare_link]    = Menu(_option_row!(menu_layout, 9, "Compare Link"),
                               options = Any[menu_opt(:fully_coupled), menu_opt(:colorbar_only), menu_opt(:axes_only), menu_opt(:decoupled)])
    _finish_option_panel!(menu_layout)
end

"""
    build_plot_options!(menu_layout::GridLayout)

Builds the lower half of the `Plot` tab, one option per row: the independent axes, the dependent field, its
component and the animation target, which update the data without rebuilding the plot grid (*Update Plot*).
"""
function build_plot_options!(menu_layout::GridLayout)
    w = manager.widgets
    Label(menu_layout[1, 1:2], "Plot options  (Update Plot)", font = :bold, color = :darkred, halign = :left)

    w[:x_axis]      = Menu(_option_row!(menu_layout, 2, "X-Axis"), options = Any[menu_opt(:none)])
    w[:y_axis]      = Menu(_option_row!(menu_layout, 3, "Y-Axis"), options = Any[menu_opt(:none)])
    w[:z_axis]      = Menu(_option_row!(menu_layout, 4, "Z-Axis"), options = Any[menu_opt(:none)])
    w[:u_axis]      = Menu(_option_row!(menu_layout, 5, "U-Axis (Dep)"), options = Any[menu_opt(:none)])
    w[:component]   = Menu(_option_row!(menu_layout, 6, "Component"), options = Any[(frontend_key(:component_1), 1)])
    w[:anim_target] = Menu(_option_row!(menu_layout, 7, "Anim Target"), options = Any[menu_opt(:none)])
    _finish_option_panel!(menu_layout)
end

"""
    build_sliders!(slider_layout::GridLayout)

Builds the always visible sliders: one per swept parameter (`max_params` of them, bound to `config.varied` by
`_map_parameters_to_sliders!`) and one per base dimension.
"""
function build_sliders!(slider_layout::GridLayout)
    manager.panels[:sliders] = slider_layout
    for (i, key) in enumerate(_slider_keys())
        row = manager.panels[Symbol("slider_row_", key)] = slider_layout[i, 1] = GridLayout()
        is_param = i <= manager.max_params
        lbl_text = Observable(is_param ? "Param $i:" : "$(frontend_key(key)):")
        manager.widgets[Symbol("$(key)_label")] = lbl_text

        Label(row[1, 1], lbl_text, halign=:right)
        sl = Slider(row[1, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[key] = sl
        # Non-numeric sweeps use index sliders; the label shows the selected value instead of the index.
        Label(row[1, 3], lift(v -> is_param ? _slider_value_text(key, v) : _fmt_value(v), sl.value), halign=:left)

        colsize!(row, 1, Fixed(90))
        colsize!(row, 3, Fixed(60))
    end
    rowgap!(slider_layout, SLIDER_ROWGAP)
end

# Widget keys of the slider rows, top to bottom: the parameter sliders, then one per base dimension.
_slider_keys() = Symbol[[Symbol("param_$i") for i in 1:manager.max_params]; get_base_variables()]

# ==============================================================================
# --- 3. EDITOR BUILDER ---
# ==============================================================================
"""
    create_editor_controls!(layout::GridLayout)

Builds the editor panel shared by the `Methods`, `Simulation`, `UI` and `Labels` tabs (the tab is the category; the
Methods tab edits the simulation configuration, the Advanced tab the `SimulationConfig` itself) and by the pages of
the `Files` tab (export settings, presets):

- a header with a back button (to the overview), the title of the page and ◀ ▶ for scopes with more keys than rows;
- the tools of the Methods tab: which methods are listed (active / disabled / all) and the drawing order view;
- the overview: one button per page (scope) of the category, `OVERVIEW_BUTTONS` of them, in titled sections;
- a page: `EDITOR_ROWS` rows of key name, value box and an action button (on/off for `Bool` values, ↺ to restore
  the default, *Apply* for presets);
- the item rows: `EDITOR_ROWS` rows of name and two buttons (Methods tab: active/off and Edit, or ▲ ▼; Files tab:
  Apply and Edit of a preset);
- rows that add an entry: to a preset file (category and scope, key, value), to a configuration scope in the
  Advanced tab (key, type, value; plus deleting a method) and a method (Advanced overview).

All of it is built once; `_render_editor!` binds the widgets to the selected page and parks the unused ones.
"""
function create_editor_controls!(layout::GridLayout)
    w = manager.widgets
    p = manager.panels

    # --- Header ---
    header = p[:editor_header] = layout[1, 1] = GridLayout()
    p[:editor_back] = header[1, 1] = GridLayout()
    w[:editor_back] = Button(p[:editor_back][1, 1], label = "◀ Back", width = nothing, fontsize = 12)
    w[:editor_title] = Observable("")
    Label(header[1, 2], w[:editor_title], font = :bold, halign = :left, tellwidth = false)
    p[:editor_pager] = header[1, 3] = GridLayout()
    w[:editor_prev] = Button(p[:editor_pager][1, 1], label = "◀", width = 32)
    w[:editor_next] = Button(p[:editor_pager][1, 2], label = "▶", width = 32)
    colsize!(header, 1, Fixed(80))
    colsize!(header, 3, Fixed(72))

    # --- Tools of the Methods tab: which methods are listed, and the drawing order ---
    tools = p[:editor_tools] = layout[2, 1] = GridLayout()
    w[:method_filter] = Button(tools[1, 1], label = "Show: active", width = nothing, fontsize = 12)
    w[:method_order]  = Button(tools[1, 2], label = "Order ▲▼", width = nothing, fontsize = 12)
    for i in 1:2; colsize!(tools, i, Relative(1/2)); end

    # --- Body: the overview, the rows of a page and the method rows share the cell; all but one are parked ---
    body = p[:editor_body] = layout[3, 1] = GridLayout()
    overview = p[:editor_overview] = body[1, 1] = GridLayout()
    for j in 1:OVERVIEW_BUTTONS
        w[Symbol("editor_page_", j)] = Button(overview[(j - 1) ÷ OVERVIEW_COLS + 1, (j - 1) % OVERVIEW_COLS + 1],
                                              label = " ", width = nothing, fontsize = 12, buttoncolor = RGBf(0.88, 0.92, 1.0))
    end
    # Section titles; built below the buttons (three rows: no overview needs more rows in total) so the measured
    # height of the panel includes them
    for k in 1:OVERVIEW_SECTIONS
        w[Symbol("editor_section_", k)] = Label(overview[cld(OVERVIEW_BUTTONS, OVERVIEW_COLS) + min(k, 3), 1:OVERVIEW_COLS], " ",
                                                halign = :left, font = :bold, color = :darkred, fontsize = 13)
    end
    for c in 1:OVERVIEW_COLS; colsize!(overview, c, Relative(1 / OVERVIEW_COLS)); end
    rowgap!(overview, EDITOR_ROWGAP)

    rows = p[:editor_rows] = body[1, 1] = GridLayout()
    for i in 1:EDITOR_ROWS
        row = p[Symbol("editor_row_", i)] = rows[i, 1] = GridLayout()
        w[Symbol("editor_row_", i, "_label")] = Observable("")
        Label(row[1, 1], w[Symbol("editor_row_", i, "_label")], halign = :left, fontsize = 12, tellwidth = false)
        w[Symbol("editor_row_", i, "_text")] = Textbox(row[1, 2], placeholder = "", width = nothing, height = 26, fontsize = 13)
        w[Symbol("editor_row_", i, "_button")] = Button(row[1, 3], label = " ", width = nothing, height = 26, fontsize = 12)
        colsize!(row, 1, Fixed(150))
        colsize!(row, 3, Fixed(46))
        colgap!(row, 6)
    end
    rowgap!(rows, EDITOR_ROWGAP)

    # Methods tab: name with an active/off toggle and Edit (list), or position with ▲ ▼ (drawing order)
    method_rows = p[:method_rows] = body[1, 1] = GridLayout()
    for i in 1:EDITOR_ROWS
        row = p[Symbol("method_row_", i)] = method_rows[i, 1] = GridLayout()
        w[Symbol("method_row_", i, "_label")] = Observable("")
        Label(row[1, 1], w[Symbol("method_row_", i, "_label")], halign = :left, fontsize = 13, tellwidth = false)
        w[Symbol("method_row_", i, "_a")] = Button(row[1, 2], label = " ", width = nothing, height = 26, fontsize = 12)
        w[Symbol("method_row_", i, "_b")] = Button(row[1, 3], label = " ", width = nothing, height = 26, fontsize = 12)
        colsize!(row, 2, Fixed(70))
        colsize!(row, 3, Fixed(70))
        colgap!(row, 6)
    end
    rowgap!(method_rows, EDITOR_ROWGAP)

    # --- Rows that add entries; all built in one row (at most one is shown), parked unless their page is open ---
    neutral = RGBf(0.92, 0.92, 0.92)
    # a row of a preset file
    preset_add = p[:preset_add] = layout[4, 1] = GridLayout()
    w[:preset_add_scope] = Textbox(preset_add[1, 1], placeholder = "Category, Scope", width = nothing, fontsize = 12)
    w[:preset_add_key]   = Textbox(preset_add[1, 2], placeholder = "key", width = nothing, fontsize = 12)
    w[:preset_add_value] = Textbox(preset_add[1, 3], placeholder = "value", width = nothing, fontsize = 12)
    w[:preset_add_button] = Button(preset_add[1, 4], label = "Add", buttoncolor = :lightblue, width = nothing)
    colsize!(preset_add, 1, Relative(0.32)); colsize!(preset_add, 4, Fixed(46))
    # a key of a raw configuration scope (Advanced), with its type; and deleting a method
    raw_add = p[:raw_add] = layout[4, 1] = GridLayout()
    raw_add_row = p[:raw_add_row] = raw_add[1, 1] = GridLayout()
    w[:raw_add_key]   = Textbox(raw_add_row[1, 1], placeholder = "new key", width = nothing, fontsize = 12)
    w[:raw_add_type]  = Menu(raw_add_row[1, 2], options = Any[(string(t), t) for t in RAW_VALUE_TYPES], fontsize = 12)
    w[:raw_add_value] = Textbox(raw_add_row[1, 3], placeholder = "value", width = nothing, fontsize = 12)
    w[:raw_add_button] = Button(raw_add_row[1, 4], label = "Add", buttoncolor = :lightblue, width = nothing)
    colsize!(raw_add_row, 1, Relative(0.28)); colsize!(raw_add_row, 2, Fixed(120)); colsize!(raw_add_row, 4, Fixed(46))
    p[:raw_delete_method] = raw_add[2, 1] = GridLayout()
    w[:raw_delete_method] = Button(p[:raw_delete_method][1, 1], label = "Delete this method", buttoncolor = RGBf(1.0, 0.8, 0.8),
                                   width = nothing)
    # a method (Advanced overview)
    method_add = p[:method_add] = layout[4, 1] = GridLayout()
    w[:method_add_name]   = Textbox(method_add[1, 1], placeholder = "name of a new method", width = nothing, fontsize = 12)
    w[:method_add_button] = Button(method_add[1, 2], label = "Add method", buttoncolor = neutral, width = nothing)
    colsize!(method_add, 2, Fixed(110))
    rowgap!(layout, 8)
end
