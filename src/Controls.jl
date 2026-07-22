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
    # Row 1: Top Execution Controls 
    exec_layout = layout[current_row, 1] = GridLayout()    
    manager.widgets["Run_Button"]       = Button(exec_layout[1, 1], label="Run Sim", buttoncolor=:lightgreen, width = nothing)
    manager.widgets["Layout_Apply"] = Button(exec_layout[1, 2], label="Apply Layout", buttoncolor=:lightblue, width=nothing)
    colsize!(exec_layout, 1, Relative(0.5))
    colsize!(exec_layout, 2, Relative(0.5))
    current_row += 1

    # --- 2. HIERARCHICAL EDITOR ---
    param_nav_layout = layout[current_row, 1] = GridLayout()
    create_hierarchical_param_controls!(param_nav_layout, manager)
    current_row += 1
    
    # --- 3. METHODS ---
    Label(layout[current_row, 1], "Active Methods", fontsize=16, font=:bold, color=:darkred)
    current_row += 1
    method_layout = layout[current_row, 1] = GridLayout()
    create_method_controls!(method_layout, manager) 
    current_row += 1
    
    # --- 5. STATIC PLOT CONTROLS ---
    menu_area = layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = layout[current_row, 1] = GridLayout()
    current_row += 1
    export_layout = layout[current_row, 1] = GridLayout()

    build_static_plot_controls!(menu_area, slider_area, manager)
    createExportOptions!(export_layout, manager)
end

function create_method_controls!(layout::GridLayout, manager::PlotManager)
    manager.widgets["Mode_Button"]     = Button(layout[1, 1], label = "Mode: Activate", buttoncolor = :lightgreen, width=nothing)
    manager.widgets["Method_Toggle"]   = Menu(layout[1, 2:3], options = ["Methods..."], prompt = "Methods...")
    manager.widgets["Method_Apply"]    = Button(layout[1, 4], label = "Apply", buttoncolor = :lightblue, width=nothing)

    colsize!(layout, 1, Relative(0.25))
    colsize!(layout, 2, Relative(0.25))
    colsize!(layout, 3, Relative(0.25))
    colsize!(layout, 4, Relative(0.25))
end
# ==============================================================================
# --- 2. STATIC PLOT CONTROLS BUILDER ---
# ==============================================================================
function build_static_plot_controls!(menu_layout::GridLayout, slider_layout::GridLayout, manager::PlotManager)
    
    # Track the row dynamically and collect gaps to apply safely at the end!
    cr = 1
    gaps = Int[]
    
    # =========================================================================
    # SECTION 1: LAYOUT OPTIONS (Requires Apply Button)
    # =========================================================================
    Label(menu_layout[cr, 1:3], "Layout Options", fontsize=16, font=:bold, color=:darkred)
    push!(gaps, 5); cr += 1
    
    compare_opts = Any[("None", :None), ("Methods", :Methods), ("Component", :Component)]
    size_opts = Any[("$i", i) for i in 100:100:1000]
    
    base_opts = PLOT_MODE[] == :eulerian ? Any[("Lines", :lines), ("Scatter", :scatter), ("Contour", :contour), ("Heatmap", :heatmap), ("Volume", :volume)] : Any[("Scatter", :scatter)]

    # --- ROW BLOCK 1: Plot, Size, and Legend (Base) ---
    Label(menu_layout[cr,1], "Base Plot", font=:bold, color=:teal)
    Label(menu_layout[cr,2], "Plot Width", font=:bold, color=:teal)
    Label(menu_layout[cr,3], "Legend Base", font=:bold, color=:darkorchid)
    push!(gaps, 2); cr += 1

    manager.widgets["Base_Plot"]   = Menu(menu_layout[cr,1], options = base_opts)
    manager.widgets["Plot_Width"]  = Menu(menu_layout[cr,2], options = size_opts)
    manager.widgets["Legend_Base"] = Menu(menu_layout[cr,3], options = Any[("none", :none), ("center", :center), ("left", :left), ("right", :right), ("top", :top), ("bottom", :bottom)])
    push!(gaps, 10); cr += 1

    # --- ROW BLOCK 2: Plot, Size, and Legend (Modifiers) ---
    Label(menu_layout[cr,1], "Plot Style", font=:bold, color=:teal)
    Label(menu_layout[cr,2], "Plot Height", font=:bold, color=:teal)
    Label(menu_layout[cr,3], "Legend Modifier", font=:bold, color=:darkorchid)
    push!(gaps, 2); cr += 1

    manager.widgets["Plot_Style"]  = Menu(menu_layout[cr,1], options = Any[("1D", :one_d), ("2D", :two_d), ("3D", :three_d)])
    manager.widgets["Plot_Height"] = Menu(menu_layout[cr,2], options = size_opts)
    manager.widgets["Legend_Add"]  = Menu(menu_layout[cr,3], options = Any[("none", :none), ("detached", :detached), ("left", :left), ("right", :right), ("top", :top), ("bottom", :bottom)])
    push!(gaps, 15); cr += 1

    # --- ROW BLOCK 3: Comparisons ---
    Label(menu_layout[cr,1], "Compare Target", font=:bold, color=:darkorange)
    Label(menu_layout[cr,2], "Grid Columns", font=:bold, color=:darkorange)
    Label(menu_layout[cr,3], "Compare Link", font=:bold, color=:darkorange)
    push!(gaps, 2); cr += 1

    manager.widgets["Compare_Target"]  = Menu(menu_layout[cr,1], options = compare_opts)
    manager.widgets["Compare_Columns"] = Menu(menu_layout[cr,2], options = Any[("$i", i) for i in 1:5])
    manager.widgets["Compare_Link"]    = Menu(menu_layout[cr,3], options = Any[("Fully Coupled", :fully_coupled), ("Coupled Colorbar", :coupled_colorbar), ("Decoupled", :decoupled)])

    push!(gaps, 25); cr += 1

    # =========================================================================
    # SECTION 2: SCENE OPTIONS (Automatic Sync)
    # =========================================================================
    Label(menu_layout[cr, 1:3], "Scene Options", fontsize=16, font=:bold, color=:darkred)
    push!(gaps, 5); cr += 1

    # --- ROW BLOCK 5: Independent Axes ---
    Label(menu_layout[cr,1], "X-Axis", font=:bold)
    Label(menu_layout[cr,2], "Y-Axis", font=:bold)
    Label(menu_layout[cr,3], "Z-Axis", font=:bold)
    push!(gaps, 2); cr += 1

    manager.widgets["X-Axis"] = Menu(menu_layout[cr,1], options = Any[("-", :None)])
    manager.widgets["Y-Axis"] = Menu(menu_layout[cr,2], options = Any[("disabled", :None)])
    manager.widgets["Z-Axis"] = Menu(menu_layout[cr,3], options = Any[("disabled", :None)])
    push!(gaps, 10); cr += 1

    # --- ROW BLOCK 6: Rest ---
    Label(menu_layout[cr,1], "U-Axis (Dep)", font=:bold)
    Label(menu_layout[cr,2], "Anim Target", font=:bold, color=:darkorange)
    Label(menu_layout[cr,3], "Component", font=:bold)
    push!(gaps, 2); cr += 1

    manager.widgets["U-Axis"]      = Menu(menu_layout[cr,1], options = Any[("-", :None)])
    manager.widgets["Anim_Target"] = Menu(menu_layout[cr,2], options = Any[("None", :None)])
    manager.widgets["c"]           = Menu(menu_layout[cr,3], options = Any[("1", 1)])

    # --- APPLY GAPS & SPACING ---
    for i in 1:3; colsize!(menu_layout, i, Relative(1/3)); end
    for (i, gap) in enumerate(gaps)
        rowgap!(menu_layout, i, gap)
    end

    # =========================================================================
    # --- SLIDERS ---
    # =========================================================================
    slider_row = 0
    
    for i in 1:MAX_SUPPORTED_PARAMS[] 
        p_key = "param_$i"
        lbl_text = Observable("Param $i:")
        manager.widgets["$(p_key)_Label"] = lbl_text
        
        Label(slider_layout[slider_row, 1], lbl_text, halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[p_key] = sl
        
        Label(slider_layout[slider_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), sl.value), halign=:left)
        slider_row += 1
    end

    for p_sym in get_base_variables()
        p_str = string(p_sym)
        Label(slider_layout[slider_row, 1], "$p_str:", halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        manager.widgets[p_str] = sl
        
        Label(slider_layout[slider_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), sl.value), halign=:left)
        slider_row += 1
    end
    
    colsize!(slider_layout, 1, Fixed(80))    
    colsize!(slider_layout, 2, Relative(0.7)) 
    colsize!(slider_layout, 3, Fixed(60))
    for r in 1:(slider_row-1); rowgap!(slider_layout, r, 5); end
end

# ==============================================================================
# --- 4. HIERARCHICAL EDITOR BUILDER ---
# ==============================================================================
function create_hierarchical_param_controls!(layout::GridLayout, manager::PlotManager)
    
    # Row 2: The Header (Positioned perfectly between the execution controls and the dropdowns)
    Label(layout[1, 1:4], "Parameter & UI Editor:", fontsize=16, font=:bold, color=:royalblue)
    
    # Row 3: The 3 Dropdowns (Nested to divide 3 items evenly across the row)
    drop_gl = layout[2, 1:4] = GridLayout()
    manager.widgets["Editor_Cat"]   = Menu(drop_gl[1, 1], options=["Simulation", "UI"], prompt="Category")
    manager.widgets["Editor_Scope"] = Menu(drop_gl[1, 2], options=["-"], prompt="Scope")
    manager.widgets["Editor_Key"]   = Menu(drop_gl[1, 3], options=["-"], prompt="Parameter")
    
    # Row 4: The 3:1 Textbox/Toggle Layout
    manager.widgets["Editor_Text"]   = Textbox(layout[3, 1:3], placeholder="Val / 'default'", width=nothing) # Spans 3 columns
    manager.widgets["Editor_Toggle"] = Button(layout[3, 4], label="Toggle", buttoncolor=:lightgray)          # Spans 1 column
end

# ==============================================================================
# --- 6. EXPORT OPTIONS BUILDER ---
# ==============================================================================
function createExportOptions!(layout::GridLayout, manager::PlotManager)
    # Row 1: Configurations & Camera
    manager.widgets["Save_Defs_Button"]  = Button(layout[1, 1], label="Save Defs", buttoncolor=:lightcoral, width=nothing)
    manager.widgets["Clear_Defs_Button"] = Button(layout[1, 2], label="Clear Defs", buttoncolor=:mistyrose, width=nothing) 
    manager.widgets["Lock_Camera_Button"]= Button(layout[1, 3], label="Lock Camera", buttoncolor=:lightgray, width=nothing)
    
    # Row 2: Actions
    manager.widgets["Play_Anim_Button"]  = Button(layout[2, 1], label="Play Anim", buttoncolor=:lightyellow, width=nothing)
    manager.widgets["Save_Image_Button"] = Button(layout[2, 2], label="Save Image", buttoncolor=:lightblue, width=nothing)
    manager.widgets["Save_GIF_Button"]   = Button(layout[2, 3], label="Save GIF", buttoncolor=:lightgreen, width=nothing)

    # Row 3: Textbox
    manager.widgets["Export_Text"]       = Textbox(layout[3, 1:3], placeholder = "Filename...", width=nothing)

    for i in 1:3
        colsize!(layout, i, Relative(1/3))
    end
end