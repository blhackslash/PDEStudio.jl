# ==============================================================================
# --- 1. MASTER CONTROL BUILDER ---
# ==============================================================================
"""
    create_controls(layout::GridLayout, manager::PlotManager)

Purely builds the UI widgets inside the provided sub-layout.
"""
function create_controls(layout::GridLayout, manager::PlotManager)
    rowgap!(layout, 15) 
    current_row = 1

    # --- 1. DRAG/DROP ZONE ---
    drop_layout = layout[current_row, 1] = GridLayout() 
    drop_box = Box(drop_layout[1, 1], color=:lightgray, width=450, strokecolor=:gray, strokewidth=2, cornerradius=10, height=80)
    drop_label = Label(drop_layout[1, 1], "Drag & Drop CSV Here", halign=:center, valign=:center, color=RGBAf(0.3, 0.3, 0.3, 1.0))
    
    manager.widgets["Drop_Box"]   = drop_box
    manager.widgets["Drop_Label"] = drop_label
    current_row += 1

    # --- 2. HIERARCHICAL EDITOR ---
    Label(layout[current_row, 1], "Parameter & UI Editor:", fontsize=16, font=:bold, color=:royalblue)
    current_row += 1
    param_nav_layout = layout[current_row, 1] = GridLayout()
    create_hierarchical_param_controls!(param_nav_layout, manager)
    current_row += 1
    
    # --- 3. OVERWRITES & METHODS ---
    Label(layout[current_row, 1], "Dimension Overwrites & Methods", fontsize=16, font=:bold, color=:darkred)
    current_row += 1
    lock_layout = layout[current_row, 1] = GridLayout()
    create_base_overwrite_controls!(lock_layout, manager) 
    current_row += 1
    
    # --- 4. STATIC PLOT CONTROLS ---
    menu_area = layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = layout[current_row, 1] = GridLayout()
    current_row += 1
    export_layout = layout[current_row, 1] = GridLayout()

    build_static_plot_controls!(menu_area, slider_area, manager)
    createExportOptions!(export_layout, manager)
end

# ==============================================================================
# --- 2. STATIC PLOT CONTROLS BUILDER ---
# ==============================================================================
function build_static_plot_controls!(menu_layout::GridLayout, slider_layout::GridLayout, manager::PlotManager)
    
    # =========================================================================
    # SECTION 1: LAYOUT OPTIONS (Requires Apply Button)
    # =========================================================================
    Label(menu_layout[1, 1:3], "Layout Options", fontsize=16, font=:bold, color=:darkred)
    
    # Row 1 Labels
    Label(menu_layout[2,1], "Plot Width", font=:bold, color=:teal)
    Label(menu_layout[2,2], "Plot Height", font=:bold, color=:teal)
    Label(menu_layout[2,3], "Plot Type", font=:bold)

    # Dynamically build Compare Targets
    compare_opts = String["None", "Methods"]
    for p in manager.plot_vars
        if p == "c"
            push!(compare_opts, "Component")
        elseif p == "t"
            push!(compare_opts, "Time")
        elseif !(p in ("x", "y", "z"))
            push!(compare_opts, p)
        end
    end

    # Row 1 Menus
    size_opts = [string(i) for i in 100:100:1000]
    plot_opts = [("Lines", :lines), ("Heatmap", :heatmap), ("Contour", :contour), ("Contourf", :contourf), ("Volume", :volume), ("Surface", :surface), ("Scatter 2D", :scatter2d), ("Scatter 3D", :scatter3d)]

    manager.widgets["Plot_Width"]  = Menu(menu_layout[3,1], options = size_opts)
    manager.widgets["Plot_Height"] = Menu(menu_layout[3,2], options = size_opts)
    manager.widgets["Plot_Type"]   = Menu(menu_layout[3,3], options = plot_opts)

    # Row 2 Labels
    Label(menu_layout[4,1], "Compare Target", font=:bold, color=:darkorange)
    Label(menu_layout[4,2], "Grid Columns", font=:bold, color=:darkorange)
    Label(menu_layout[4,3], "Compare Link", font=:bold, color=:darkorange)

    # Row 2 Menus
    manager.widgets["Compare_Target"]  = Menu(menu_layout[5,1], options = compare_opts)
    manager.widgets["Compare_Columns"] = Menu(menu_layout[5,2], options = ["1", "2", "3", "4", "5"])
    manager.widgets["Compare_Link"]    = Menu(menu_layout[5,3], options = ["Fully Coupled", "Coupled Colorbar", "Decoupled"])

    # Row 3 Labels (Column 3 is intentionally left empty so the Apply Button can fill the space below it)
    Label(menu_layout[6,1], "Legend Base", font=:bold, color=:darkorchid)
    Label(menu_layout[6,2], "Legend Modifier", font=:bold, color=:darkorchid)

    # Row 3 Menus & Apply Button
    manager.widgets["Legend_Base"]  = Menu(menu_layout[7,1], options = ["none", "center", "left", "right", "top", "bottom"])
    manager.widgets["Legend_Add"]   = Menu(menu_layout[7,2], options = ["none", "detached", "left", "right", "top", "bottom"])
    manager.widgets["Layout_Apply"] = Button(menu_layout[7,3], label="Apply Layout", buttoncolor=:lightblue, width=nothing)

    # =========================================================================
    # SECTION 2: SCENE OPTIONS (Automatic Sync)
    # =========================================================================
    Label(menu_layout[8, 1:3], "Scene Options", fontsize=16, font=:bold, color=:darkred)

    # Row 4 Labels (Independent Axes)
    Label(menu_layout[9,1], "X-Axis", font=:bold)
    Label(menu_layout[9,2], "Y-Axis", font=:bold)
    Label(menu_layout[9,3], "Z-Axis", font=:bold)

    # Row 4 Menus
    manager.widgets["X-Axis"] = Menu(menu_layout[10,1], options = ["-"])
    manager.widgets["Y-Axis"] = Menu(menu_layout[10,2], options = ["disabled"])
    manager.widgets["Z-Axis"] = Menu(menu_layout[10,3], options = ["disabled"])

    # Row 5 Labels (Rest)
    Label(menu_layout[11,1], "U-Axis (Dep)", font=:bold)
    Label(menu_layout[11,2], "Anim Target", font=:bold, color=:darkorange)
    Label(menu_layout[11,3], "Component", font=:bold)

    # Row 5 Menus
    manager.widgets["U-Axis"]      = Menu(menu_layout[12,1], options = ["-"])
    manager.widgets["Anim_Target"] = Menu(menu_layout[12,2], options = [("None", "None")])
    manager.widgets["c"]           = Menu(menu_layout[12,3], options = ["1"])

    # --- 3-COLUMN EQUAL SPACING ---
    for i in 1:3; colsize!(menu_layout, i, Relative(1/3)); end

    # --- PERFECTED ROW GAPS ---
    rowgap!(menu_layout, 1, 5)   # Header 1 to Row 1 Labels
    rowgap!(menu_layout, 2, 2)   # Row 1 Labels to Menus (Tight)
    rowgap!(menu_layout, 3, 10)  # Row 1 Menus to Row 2 Labels
    rowgap!(menu_layout, 4, 2)   # Row 2 Labels to Menus (Tight)
    rowgap!(menu_layout, 5, 10)  # Row 2 Menus to Row 3 Labels
    rowgap!(menu_layout, 6, 2)   # Row 3 Labels to Menus & Button (Tight)
    rowgap!(menu_layout, 7, 25)  # Layout Section to Header 2 (Large Divider Gap)
    rowgap!(menu_layout, 8, 5)   # Header 2 to Row 4 Labels
    rowgap!(menu_layout, 9, 2)   # Row 4 Labels to Menus (Tight)
    rowgap!(menu_layout, 10, 10) # Row 4 Menus to Row 5 Labels
    rowgap!(menu_layout, 11, 2)  # Row 5 Labels to Menus (Tight)

    # =========================================================================
    # --- SLIDERS ---
    # =========================================================================
    slider_row = 1
    
    for i in 1:3 
        p_key = "param_$i"
        lbl_text = Observable("Param $i:")
        manager.widgets["$(p_key)_Label"] = lbl_text
        
        Label(slider_layout[slider_row, 1], lbl_text, halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[p_key] = sl
        
        Label(slider_layout[slider_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), sl.value), halign=:left)
        slider_row += 1
    end

    for p in ["x", "y", "z", "t"]
        Label(slider_layout[slider_row, 1], "$p:", halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[p] = sl
        
        Label(slider_layout[slider_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), sl.value), halign=:left)
        slider_row += 1
    end
    
    colsize!(slider_layout, 1, Fixed(80))    
    colsize!(slider_layout, 2, Relative(0.7)) 
    colsize!(slider_layout, 3, Fixed(60))
    for r in 1:6; rowgap!(slider_layout, r, 5); end
end

# ==============================================================================
# --- 3. DIMENSION OVERWRITES BUILDER ---
# ==============================================================================
function create_base_overwrite_controls!(layout::GridLayout, manager::PlotManager)
    # Row 1: Overwrites
    manager.widgets["Overwrite_Var"]   = Menu(layout[1, 1], options = ["-"], prompt = "Select...")
    manager.widgets["Overwrite_Text"]  = Textbox(layout[1, 2:3], placeholder = "Val / 'default'", width = nothing) 
    manager.widgets["Overwrite_Apply"] = Button(layout[1, 4], label = "Apply", buttoncolor = :lightblue, width = nothing)

    # Row 2: Methods
    manager.widgets["Mode_Button"]     = Button(layout[2, 1], label = "Mode: Activate", buttoncolor = :lightgreen, width=nothing)
    manager.widgets["Method_Toggle"]   = Menu(layout[2, 2:3], options = ["Methods..."], prompt = "Methods...")
    manager.widgets["Method_Apply"]    = Button(layout[2, 4], label = "Apply", buttoncolor = :lightblue, width=nothing)

    colsize!(layout, 1, Relative(0.25))
    colsize!(layout, 2, Relative(0.25))
    colsize!(layout, 3, Relative(0.25))
    colsize!(layout, 4, Relative(0.25))
end

# ==============================================================================
# --- 4. HIERARCHICAL EDITOR BUILDER ---
# ==============================================================================
function create_hierarchical_param_controls!(layout::GridLayout, manager::PlotManager)
    manager.widgets["Editor_Cat"]   = Menu(layout[1, 1], options = ["Simulation", "UI"], prompt = "Category...", width=nothing)
    manager.widgets["Editor_Scope"] = Menu(layout[1, 2], options = ["-"], default = "-", prompt = "Scope...", width=nothing)
    manager.widgets["Editor_Key"]   = Menu(layout[1, 3], options = ["-"], default = "-", prompt = "Key...", width=nothing)
    
    colsize!(layout, 1, Relative(1/3)); colsize!(layout, 2, Relative(1/3)); colsize!(layout, 3, Relative(1/3))
    
    btn_layout = layout[2, 1:3] = GridLayout()
    manager.widgets["Editor_Toggle"] = Button(btn_layout[1, 1], label="Toggle", buttoncolor=:lightgray, width=nothing)
    manager.widgets["Editor_Reset"]  = Button(btn_layout[1, 2], label="Reset", buttoncolor=:lightcoral, width=nothing)
    manager.widgets["Run_Button"]    = Button(btn_layout[1, 3], label="Run Sim", buttoncolor=:lightgray, width=nothing) 
    
    colsize!(btn_layout, 1, Relative(1/3)); colsize!(btn_layout, 2, Relative(1/3)); colsize!(btn_layout, 3, Relative(1/3))
    
    manager.widgets["Editor_Text"] = Textbox(layout[3, 1:3], placeholder = "Select key...", reset_on_defocus = false, width = nothing)
end

# ==============================================================================
# --- 6. EXPORT OPTIONS BUILDER ---
# ==============================================================================
function createExportOptions!(layout::GridLayout, manager::PlotManager)
    manager.widgets["Export_Text"]       = Textbox(layout[2, 1:5], placeholder = "Filename...", width=nothing)
    manager.widgets["Save_Defs_Button"]  = Button(layout[1, 1], label="Save Defs", buttoncolor=:lightcoral)
    manager.widgets["Clear_Defs_Button"] = Button(layout[1, 2], label="Clear Defs", buttoncolor=:mistyrose) 
    manager.widgets["Play_Anim_Button"]  = Button(layout[1, 3], label="Play Anim", buttoncolor=:lightyellow)
    manager.widgets["Save_Image_Button"] = Button(layout[1, 4], label="Save Image", buttoncolor=:lightblue)
    manager.widgets["Save_GIF_Button"]   = Button(layout[1, 5], label="Save GIF", buttoncolor=:lightgreen)

    for i in 1:5
        colsize!(layout, i, Relative(0.20))
    end
end