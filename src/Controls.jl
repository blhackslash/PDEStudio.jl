# ==============================================================================
# --- 1. MASTER CONTROL BUILDER ---
# ==============================================================================

# Width of the control panel (pixels).
const CONTROL_WIDTH = 450

# Tabs of the control panel and their button labels. The three editor categories are tabs of their own.
const CONTROL_TABS = (:plot, :layout, :simulation, :ui, :labels, :files)
const TAB_LABELS = Dict(:plot => "Plot", :layout => "Layout", :simulation => "Simulation", :ui => "UI",
                        :labels => "Labels", :files => "Files")
const EDITOR_TABS = (:simulation, :ui, :labels)
const TAB_ROWGAP = 12   # gap between the panels of a tab

# The panels (widget groups) each tab shows, top to bottom. The editor panel is shared by the editor tabs.
const TAB_PANELS = Dict(:plot => (:plot,), :layout => (:layout,), :simulation => (:editor, :methods),
                        :ui => (:editor,), :labels => (:editor,), :files => (:files,))

"""
    create_controls(layout::GridLayout)

Constructs the primary control panel inside the provided Makie `GridLayout`, top to bottom:

1. The tab bar (`Plot`, `Layout`, `Simulation`, `UI`, `Labels`, `Files`).
2. The tab content: the panel(s) of the selected tab (see `TAB_PANELS`). Every panel is built once; the panels of
   the other tabs are parked off-screen by `show_tab!`.
3. The filename / path box shared by exports, presets and CSV loading.
4. The parameter and dimension sliders.
5. Animation playback and camera locking.
6. The execution triggers (Run Simulation, Apply Layout, Update Plot).

Widgets are created once per window and never deleted or recreated (Makie does not support recreating interactive
widgets well). It finalizes construction by injecting the persistent layout, plot and exploration caches of the
manager.
"""
function create_controls(layout::GridLayout)
    rowgap!(layout, 12)
    colsize!(layout, 1, Fixed(CONTROL_WIDTH))

    # --- 1. TAB BAR ---
    tab_bar = layout[1, 1] = GridLayout()
    for (i, tab) in enumerate(CONTROL_TABS)
        manager.widgets[Symbol("tab_", tab)] = Button(tab_bar[1, i], label = TAB_LABELS[tab], width = nothing,
                                                      fontsize = 13, padding = (4, 4, 6, 6))
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
    create_hierarchical_param_controls!(panels[:editor])

    panels[:methods] = area[2, 1] = GridLayout()
    create_method_controls!(panels[:methods])

    panels[:files] = area[1, 1] = GridLayout()
    create_file_controls!(panels[:files])

    # The editor category (driven by the tabs): a menu so that the editor logic and scripts can select it like the
    # others. No tab shows it, so it stays parked.
    panels[:editor_category] = area[1, 1] = GridLayout()
    manager.widgets[:editor_cat] = Menu(panels[:editor_category][1, 1],
                                        options=[menu_opt(:simulation), menu_opt(:ui), menu_opt(:labels)], prompt="Category")

    # Parked panels sit in a layout outside the figure, where they can neither be seen nor clicked.
    manager.panel_park = GridLayout(1, length(panels); bbox = Rect2f(-20_000, -20_000, CONTROL_WIDTH * length(panels), 1000))
    manager.active_tab[] = :plot   # every window opens on the Plot tab
    show_tab!(:plot)
    # The tab content keeps the height of the tallest tab, so the controls below it never move.
    rowsize!(layout, 2, Fixed(_max_tab_height(area)))

    # --- 3. FILENAME / PATH (exports, presets, CSV loading) ---
    manager.widgets[:export_text] = Textbox(
        layout[3, 1],
        placeholder = "Filename for Export / Preset or Path to Load...",
        width = nothing
    )

    # --- 4. SLIDERS ---
    slider_area = layout[4, 1] = GridLayout()
    build_sliders!(slider_area)

    # --- 5. CAMERA & ANIMATION CONTROLS ---
    bottom_ops = layout[5, 1] = GridLayout()
    manager.widgets[:play_anim_button]   = Button(bottom_ops[1, 1], label="Play Anim", buttoncolor=:lightyellow, width=nothing)
    manager.widgets[:lock_camera_button] = Button(bottom_ops[1, 2], label="Lock Camera", buttoncolor=:lightblue, width=nothing)
    for i in 1:2; colsize!(bottom_ops, i, Relative(1/2)); end

    # --- 6. EXECUTION CONTROLS ---
    exec_layout = layout[6, 1] = GridLayout()
    manager.widgets[:run_button]   = Button(exec_layout[1, 1], label="Run Simulation", buttoncolor=:lightgreen, width = nothing)
    manager.widgets[:layout_apply] = Button(exec_layout[1, 2], label="Apply Layout", buttoncolor=:lightgreen, width=nothing)
    manager.widgets[:plot_button]  = Button(exec_layout[1, 3], label="Update Plot", buttoncolor=:lightgreen, width=nothing)
    for i in 1:3; colsize!(exec_layout, i, Relative(1/3)); end

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
    create_method_controls!(layout::GridLayout)

Builds the localized UI block responsible for toggling active simulation methods (shown in the `Simulation` tab).
Provides a mode button and a dropdown menu dynamically populated by the active `SimulationConfig`.
"""
function create_method_controls!(layout::GridLayout)
    manager.widgets[:mode_button]   = Button(layout[1, 1], label = "Mode: Activate", buttoncolor = :lightgreen, width=nothing)
    manager.widgets[:method_toggle] = Menu(layout[1, 2:3], options = [menu_opt(:methods)], prompt = "Methods...")

    colsize!(layout, 1, Relative(1/3))
    colsize!(layout, 2, Relative(1/3))
    colsize!(layout, 3, Relative(1/3))
end

"""
    create_file_controls!(layout::GridLayout)

Builds the `Files` tab: the CSV load button (which also reports the result of a load; CSV files can be dropped
anywhere on the window) and the export button. Both use the filename box below the tabs.
"""
function create_file_controls!(layout::GridLayout)
    manager.widgets[:load_config_button] = Button(
        layout[1, 1:2],
        label="Load CSV from Path Below / Drag & Drop Here",
        buttoncolor=:lightgray,
        height=60, width=nothing
    )
    manager.widgets[:export_button] = Button(layout[2, 1], label="Export", buttoncolor=:lightblue, width=nothing)
    Label(layout[2, 2], "Formats and size: UI → export", halign = :left, color = :gray40)
    for i in 1:2; colsize!(layout, i, Relative(1/2)); end
end

# ==============================================================================
# --- 2. STATIC PLOT CONTROLS BUILDERS ---
# ==============================================================================
"""
    build_layout_options!(menu_layout::GridLayout)

Builds the `Layout` tab: structural layout features requiring a manual apply step (base plot style, sizing, legend
positioning and multi-column comparison modes). The available plot styles depend on whether the `PlotManager` is in
`:eulerian` or `:lagrangian` mode.
"""
function build_layout_options!(menu_layout::GridLayout)
    cr = 1
    gaps = Int[]

    compare_opts = Any[menu_opt(:none), menu_opt(:methods), menu_opt(:component)]
    size_opts = Any[("$i", i) for i in 100:100:1000]
    
    base_opts = manager.mode[] == :eulerian ? Any[menu_opt(:lines), menu_opt(:scatter), menu_opt(:contour), menu_opt(:heatmap), menu_opt(:volume)] : Any[menu_opt(:scatter)]
    
    style_opts = manager.mode[] == :eulerian ? Any[menu_opt(:lines_1d), menu_opt(:lines_2d), menu_opt(:lines_3d)] : Any[menu_opt(:scatter_1d), menu_opt(:scatter_2d), menu_opt(:scatter_surface), menu_opt(:scatter_3d), menu_opt(:scatter_lines), menu_opt(:scatter_colors)]

    # --- ROW BLOCK 1: Plot, Size, and Legend (Base) ---
    Label(menu_layout[cr,1], "Base Plot", font=:bold, color=:teal)
    Label(menu_layout[cr,2], "Plot Width", font=:bold, color=:teal)
    Label(menu_layout[cr,3], "Legend Base", font=:bold, color=:darkorchid)
    push!(gaps, 2); cr += 1

    start_base = manager.mode[] == :eulerian ? :lines : :scatter
    manager.widgets[:base_plot]   = Menu(menu_layout[cr,1], options = base_opts, default = frontend_key(start_base))
    
    manager.widgets[:plot_width]  = Menu(menu_layout[cr,2], options = size_opts)
    manager.widgets[:legend_base] = Menu(menu_layout[cr,3], options = Any[menu_opt(:none), menu_opt(:center), menu_opt(:left), menu_opt(:right), menu_opt(:top), menu_opt(:bottom)])
    push!(gaps, 10); cr += 1

    # --- ROW BLOCK 2: Plot, Size, and Legend (Modifiers) ---
    Label(menu_layout[cr,1], "Plot Style", font=:bold, color=:teal)
    Label(menu_layout[cr,2], "Plot Height", font=:bold, color=:teal)
    Label(menu_layout[cr,3], "Legend Modifier", font=:bold, color=:darkorchid)
    push!(gaps, 2); cr += 1

    start_style = manager.mode[] == :eulerian ? :lines_1d : :scatter_1d
    manager.widgets[:plot_style]  = Menu(menu_layout[cr,1], options = style_opts, default = frontend_key(start_style))
    manager.widgets[:plot_height] = Menu(menu_layout[cr,2], options = size_opts)
    manager.widgets[:legend_add]  = Menu(menu_layout[cr,3], options = Any[menu_opt(:detached), menu_opt(:left), menu_opt(:right), menu_opt(:top), menu_opt(:bottom)])
    push!(gaps, 15); cr += 1

    # --- ROW BLOCK 3: Comparisons ---
    Label(menu_layout[cr,1], "Compare Target", font=:bold, color=:darkorange)
    Label(menu_layout[cr,2], "Grid Columns", font=:bold, color=:darkorange)
    Label(menu_layout[cr,3], "Compare Link", font=:bold, color=:darkorange)
    push!(gaps, 2); cr += 1

    manager.widgets[:compare_target]  = Menu(menu_layout[cr,1], options = compare_opts)
    manager.widgets[:compare_columns] = Menu(menu_layout[cr,2], options = Any[("$i", i) for i in 1:5])
    manager.widgets[:compare_link]    = Menu(menu_layout[cr,3], options = Any[menu_opt(:fully_coupled), menu_opt(:colorbar_only), menu_opt(:axes_only), menu_opt(:decoupled)])

    cr += 1

    for i in 1:3; colsize!(menu_layout, i, Relative(1/3)); end
    for (i, gap) in enumerate(gaps); rowgap!(menu_layout, i, gap); end
end

"""
    build_plot_options!(menu_layout::GridLayout)

Builds the `Plot` tab: independent axis selectors, the dependent field, the animation target and the vector
component selector, which update the data without rebuilding the plot grid.
"""
function build_plot_options!(menu_layout::GridLayout)
    cr = 1
    gaps = Int[]

    # --- ROW BLOCK 4: Independent Axes ---
    Label(menu_layout[cr,1], "X-Axis", font=:bold)
    Label(menu_layout[cr,2], "Y-Axis", font=:bold)
    Label(menu_layout[cr,3], "Z-Axis", font=:bold)
    push!(gaps, 2); cr += 1

    manager.widgets[:x_axis] = Menu(menu_layout[cr,1], options = Any[menu_opt(:none)])
    manager.widgets[:y_axis] = Menu(menu_layout[cr,2], options = Any[menu_opt(:none)])
    manager.widgets[:z_axis] = Menu(menu_layout[cr,3], options = Any[menu_opt(:none)])
    push!(gaps, 10); cr += 1

    # --- ROW BLOCK 5: Rest ---
    Label(menu_layout[cr,1], "U-Axis (Dep)", font=:bold)
    Label(menu_layout[cr,2], "Anim Target", font=:bold, color=:darkorange)
    Label(menu_layout[cr,3], "Component", font=:bold)
    push!(gaps, 2); cr += 1

    manager.widgets[:u_axis]      = Menu(menu_layout[cr,1], options = Any[menu_opt(:none)])
    manager.widgets[:anim_target] = Menu(menu_layout[cr,2], options = Any[menu_opt(:none)])
    manager.widgets[:component]   = Menu(menu_layout[cr,3], options = Any[(frontend_key(:component_1), 1)])

    for i in 1:3; colsize!(menu_layout, i, Relative(1/3)); end
    for (i, gap) in enumerate(gaps); rowgap!(menu_layout, i, gap); end
end

"""
    build_sliders!(slider_layout::GridLayout)

Builds the always visible sliders: one per swept parameter (`max_params` of them, bound to `config.varied` by
`_map_parameters_to_sliders!`) and one per base dimension.
"""
function build_sliders!(slider_layout::GridLayout)
    slider_row = 1
    
    for i in 1:manager.max_params 
        p_key = Symbol("param_$i")
        lbl_text = Observable("Param $i:")
        manager.widgets[Symbol("param_$(i)_label")] = lbl_text
        
        Label(slider_layout[slider_row, 1], lbl_text, halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[p_key] = sl
        
        # Non-numeric sweeps use index sliders; the label shows the selected value instead of the index.
        Label(slider_layout[slider_row, 3], lift(v -> _slider_value_text(p_key, v), sl.value), halign=:left)
        slider_row += 1
    end

    for p_sym in get_base_variables()
        lbl_key = Symbol("$(p_sym)_label")
        lbl_text = Observable("$(frontend_key(p_sym)):")
        manager.widgets[lbl_key] = lbl_text
        
        Label(slider_layout[slider_row, 1], lbl_text, halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[p_sym] = sl
        
        Label(slider_layout[slider_row, 3], lift(_fmt_value, sl.value), halign=:left)
        slider_row += 1
    end
    
    colsize!(slider_layout, 1, Fixed(80))    
    colsize!(slider_layout, 2, Relative(0.7)) 
    colsize!(slider_layout, 3, Fixed(60))
    rowgap!(slider_layout, 5)
end

# ==============================================================================
# --- 3. HIERARCHICAL EDITOR BUILDER ---
# ==============================================================================
"""
    create_hierarchical_param_controls!(layout::GridLayout)

Builds the editor panel shared by the `Simulation`, `UI` and `Labels` tabs.

The tab selects the category; the panel traverses the active nested dictionary state (Scopes -> Parameters) with
two dropdown menus connected to a Makie `Textbox`, enabling two-way editing of simulation parameters, axis labels and
UI properties via `val2str` and `str2val`. The preset buttons below act on the presets of the category.

The category itself is kept in the `:editor_cat` menu (built by `create_controls`), which is never shown: the tabs
select it (and selecting it switches to its tab), so the editor logic keeps a single source for the category.
"""
function create_hierarchical_param_controls!(layout::GridLayout)
    drop_gl = layout[1, 1:4] = GridLayout()
    manager.widgets[:editor_scope] = Menu(drop_gl[1, 1], options=[menu_opt(:none)], prompt="Scope")
    manager.widgets[:editor_key]   = Menu(drop_gl[1, 2], options=[menu_opt(:none)], prompt="Parameter")

    manager.widgets[:editor_text]   = Textbox(layout[2, 1:3], placeholder="Val / 'default'", width=nothing)
    manager.widgets[:editor_toggle] = Button(layout[2, 4], label="Toggle", buttoncolor=:lightgray)

    preset_ops = layout[3, 1:4] = GridLayout()
    manager.widgets[:save_presets_button]  = Button(preset_ops[1, 1], label="Save Presets", buttoncolor=:lightblue, width=nothing)
    manager.widgets[:clear_presets_button] = Button(preset_ops[1, 2], label="Clear Presets", buttoncolor=:lightblue, width=nothing)
    for i in 1:2; colsize!(preset_ops, i, Relative(1/2)); end

end
