# ==============================================================================
# --- 1. MASTER CONTROL BUILDER ---
# ==============================================================================
"""
    create_controls(layout::GridLayout)

Constructs the primary control panel inside the provided Makie `GridLayout`. 

This top-level builder orchestrates the creation of all interactive UI blocks:
1. File operations (Load CSV, drag-and-drop zones, exports, presets).
2. Execution triggers (Run Simulation, Apply Layout, Update Plot).
3. The hierarchical state editor for live parameter tuning.
4. Active method toggles.
5. Static plot configuration menus and dimensional sliders.
6. Camera locking and animation playback controls.

It finalizes construction by injecting the persistent default layout states from the `manager.state` cache.
"""
function create_controls(layout::GridLayout)
    rowgap!(layout, 15) 
    current_row = 1

    # --- 1. LOAD CONFIG / DRAG DROP ZONE ---
    manager.widgets[:load_config_button] = Button(
        layout[current_row, 1], 
        label="Load CSV from Path Below / Drag & Drop Here", 
        buttoncolor=:lightgray, 
        height=60, width=450
    )
    current_row += 1
    
    # --- 2. FILENAME / PATH TEXTBOX ---
    manager.widgets[:export_text] = Textbox(
        layout[current_row, 1], 
        placeholder="Filename for Export or Path to Load...", 
        width=nothing
    )
    current_row += 1

    # --- 3. UNIFIED FILE OPS & EXPORT (Uniform Color) ---
    file_ops = layout[current_row, 1] = GridLayout()
    uniform_color = :lightblue

    manager.widgets[:save_presets_button]  = Button(file_ops[1, 1], label="Save Presets", buttoncolor=uniform_color, width=nothing)
    manager.widgets[:clear_presets_button] = Button(file_ops[1, 2], label="Clear Presets", buttoncolor=uniform_color, width=nothing)
    manager.widgets[:export_button]        = Button(file_ops[1, 3], label="Export", buttoncolor=uniform_color, width=nothing)
    
    for i in 1:3; colsize!(file_ops, i, Relative(1/3)); end
    current_row += 1
    
    # --- 4. EXECUTION CONTROLS ---
    exec_layout = layout[current_row, 1] = GridLayout()    
    manager.widgets[:run_button]   = Button(exec_layout[1, 1], label="Run Simulation", buttoncolor=:lightgreen, width = nothing)
    manager.widgets[:layout_apply] = Button(exec_layout[1, 2], label="Apply Layout", buttoncolor=:lightgreen, width=nothing)
    manager.widgets[:plot_button]  = Button(exec_layout[1, 3], label="Update Plot", buttoncolor=:lightgreen, width=nothing)
    for i in 1:3; colsize!(exec_layout, i, Relative(1/3)); end
    current_row += 1

    # --- 5. HIERARCHICAL EDITOR ---
    param_nav_layout = layout[current_row, 1] = GridLayout()
    create_hierarchical_param_controls!(param_nav_layout)
    current_row += 1
    
    # --- 6. METHODS ---
    method_layout = layout[current_row, 1] = GridLayout()
    create_method_controls!(method_layout) 
    current_row += 1
    
    # --- 7. STATIC PLOT CONTROLS ---
    menu_area = layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = layout[current_row, 1] = GridLayout()
    current_row += 1

    build_static_plot_controls!(menu_area, slider_area)
    
    # --- 8. CAMERA & ANIMATION CONTROLS (Bottom) ---
    bottom_ops = layout[current_row, 1] = GridLayout()
    manager.widgets[:play_anim_button]   = Button(bottom_ops[1, 1], label="Play Anim", buttoncolor=:lightyellow, width=nothing)
    manager.widgets[:lock_camera_button] = Button(bottom_ops[1, 2], label="Lock Camera", buttoncolor=:lightgray, width=nothing)
    for i in 1:2; colsize!(bottom_ops, i, Relative(1/2)); end

    # Restore from the persistent cache instead of hard defaults
    apply_layout_options!(manager.state[:Layout_Cache])
    apply_plot_options!(manager.state[:Plot_Cache])
    apply_exploration_options!(manager.state[:Exploration_Cache])
end

"""
    create_method_controls!(layout::GridLayout)

Builds the localized UI block responsible for toggling active simulation methods.
Provides a mode button and a dropdown menu dynamically populated by the active `SimulationConfig`.
"""
function create_method_controls!(layout::GridLayout)
    manager.widgets[:mode_button]   = Button(layout[1, 1], label = "Mode: Activate", buttoncolor = :lightgreen, width=nothing)
    manager.widgets[:method_toggle] = Menu(layout[1, 2:3], options = [menu_opt(:methods)], prompt = "Methods...")

    colsize!(layout, 1, Relative(1/3))
    colsize!(layout, 2, Relative(1/3))
    colsize!(layout, 3, Relative(1/3))
end

# ==============================================================================
# --- 2. STATIC PLOT CONTROLS BUILDER ---
# ==============================================================================
"""
    build_static_plot_controls!(menu_layout::GridLayout, slider_layout::GridLayout)

Constructs the dense grid of dropdown menus and interactive sliders used to configure the visualization.

# Structure
- **Layout Options:** Controls structural layout features requiring a manual apply step (e.g., base plot style, sizing, legend positioning, and multi-column comparison modes). The available plot styles dynamically adjust based on whether the `PlotManager` is in `:eulerian` or `:lagrangian` mode.
- **Plot Options:** Independent axis selectors, animation targets, and vector component selectors that automatically trigger data synchronization loops.
- **Sliders:** Dynamically generates a scalable array of Makie `Slider` widgets bound directly to the active simulation's `varied_params` and domain dimensions.
"""
function build_static_plot_controls!(menu_layout::GridLayout, slider_layout::GridLayout)
    
    cr = 1
    gaps = Int[]
    
    # =========================================================================
    # SECTION 1: LAYOUT OPTIONS (Requires Apply Button)
    # =========================================================================
    Label(menu_layout[cr, 1:3], "Layout Options", fontsize=16, font=:bold, color=:darkred)
    push!(gaps, 5); cr += 1
    
    compare_opts = Any[menu_opt(:none), menu_opt(:methods), menu_opt(:component)]
    size_opts = Any[("$i", i) for i in 100:100:1000]
    
    base_opts = manager.mode[] == :eulerian ? Any[menu_opt(:lines), menu_opt(:scatter), menu_opt(:contour), menu_opt(:heatmap), menu_opt(:volume)] : Any[menu_opt(:scatter)]
    
    # THE FIX: Dynamically set the initial plot style options based on mode!
    style_opts = manager.mode[] == :eulerian ? Any[menu_opt(:lines_1d), menu_opt(:lines_2d), menu_opt(:lines_3d)] : Any[menu_opt(:scatter_1d), menu_opt(:scatter_2d), menu_opt(:scatter_surface), menu_opt(:scatter_3d), menu_opt(:scatter_lines), menu_opt(:scatter_colors)]

    # --- ROW BLOCK 1: Plot, Size, and Legend (Base) ---
    Label(menu_layout[cr,1], "Base Plot", font=:bold, color=:teal)
    Label(menu_layout[cr,2], "Plot Width", font=:bold, color=:teal)
    Label(menu_layout[cr,3], "Legend Base", font=:bold, color=:darkorchid)
    push!(gaps, 2); cr += 1

    # THE FIX: Explicitly set the starting selection!
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

    push!(gaps, 25); cr += 1

    # =========================================================================
    # SECTION 2: SCENE OPTIONS (Automatic Sync)
    # =========================================================================
    Label(menu_layout[cr, 1:3], "Plot Options", fontsize=16, font=:bold, color=:darkred)
    push!(gaps, 5); cr += 1

    # --- ROW BLOCK 5: Independent Axes ---
    Label(menu_layout[cr,1], "X-Axis", font=:bold)
    Label(menu_layout[cr,2], "Y-Axis", font=:bold)
    Label(menu_layout[cr,3], "Z-Axis", font=:bold)
    push!(gaps, 2); cr += 1

    manager.widgets[:x_axis] = Menu(menu_layout[cr,1], options = Any[menu_opt(:none)])
    manager.widgets[:y_axis] = Menu(menu_layout[cr,2], options = Any[menu_opt(:none)])
    manager.widgets[:z_axis] = Menu(menu_layout[cr,3], options = Any[menu_opt(:none)])
    push!(gaps, 10); cr += 1

    # --- ROW BLOCK 6: Rest ---
    Label(menu_layout[cr,1], "U-Axis (Dep)", font=:bold)
    Label(menu_layout[cr,2], "Anim Target", font=:bold, color=:darkorange)
    Label(menu_layout[cr,3], "Component", font=:bold)
    push!(gaps, 2); cr += 1

    manager.widgets[:u_axis]      = Menu(menu_layout[cr,1], options = Any[menu_opt(:none)])
    manager.widgets[:anim_target] = Menu(menu_layout[cr,2], options = Any[menu_opt(:none)])
    manager.widgets[:component]   = Menu(menu_layout[cr,3], options = Any[(frontend_key(:component_1), 1)])

    for i in 1:3; colsize!(menu_layout, i, Relative(1/3)); end
    for (i, gap) in enumerate(gaps); rowgap!(menu_layout, i, gap); end

    # =========================================================================
    # --- SLIDERS ---
    # =========================================================================
    slider_row = 0
    
    for i in 1:manager.max_params 
        p_key = Symbol("param_$i")
        lbl_text = Observable("Param $i:")
        manager.widgets[Symbol("param_$(i)_label")] = lbl_text
        
        Label(slider_layout[slider_row, 1], lbl_text, halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[p_key] = sl
        
        Label(slider_layout[slider_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), sl.value), halign=:left)
        slider_row += 1
    end

    for p_sym in get_base_variables()
        # THE FIX: Make the base labels dynamic Observables and store them!
        lbl_key = Symbol("$(p_sym)_label")
        lbl_text = Observable("$(frontend_key(p_sym)):")
        manager.widgets[lbl_key] = lbl_text
        
        Label(slider_layout[slider_row, 1], lbl_text, halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[p_sym] = sl
        
        Label(slider_layout[slider_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), sl.value), halign=:left)
        slider_row += 1
    end
    
    colsize!(slider_layout, 1, Fixed(80))    
    colsize!(slider_layout, 2, Relative(0.7)) 
    colsize!(slider_layout, 3, Fixed(60))
    for r in 1:(slider_row-1); rowgap!(slider_layout, r, 5); end
end

# ==============================================================================
# --- 3. HIERARCHICAL EDITOR BUILDER ---
# ==============================================================================
"""
    create_hierarchical_param_controls!(layout::GridLayout)

Builds the interactive UI for the hierarchical parameter editor.

This component allows users to dynamically traverse the active nested dictionary state (Categories -> Scopes -> Parameters). It connects a cascaded set of dropdown menus to a Makie `Textbox`, enabling two-way editing of simulation parameters, axis labels, and underlying UI properties via the `val2str` and `str2val` compilation bridge.
"""
function create_hierarchical_param_controls!(layout::GridLayout)
    
    Label(layout[1, 1:4], "Parameter & UI Editor:", fontsize=16, font=:bold, color=:royalblue)
    
    drop_gl = layout[2, 1:4] = GridLayout()
    manager.widgets[:editor_cat]   = Menu(drop_gl[1, 1], options=[menu_opt(:simulation), menu_opt(:ui), menu_opt(:labels)], prompt="Category")
    manager.widgets[:editor_scope] = Menu(drop_gl[1, 2], options=[menu_opt(:none)], prompt="Scope")
    manager.widgets[:editor_key]   = Menu(drop_gl[1, 3], options=[menu_opt(:none)], prompt="Parameter")
    
    manager.widgets[:editor_text]   = Textbox(layout[3, 1:3], placeholder="Val / 'default'", width=nothing) 
    manager.widgets[:editor_toggle] = Button(layout[3, 4], label="Toggle", buttoncolor=:lightgray)          
end