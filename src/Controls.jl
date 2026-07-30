# ==============================================================================
# --- 1. MASTER CONTROL BUILDER ---
# ==============================================================================
"""
    create_controls(layout::GridLayout)

Purely builds the UI widgets inside the provided sub-layout.
"""
function create_controls(layout::GridLayout)
    
    rowgap!(layout, 15) 
    current_row = 1

    # --- 1. DRAG/DROP ZONE ---
    drop_layout = layout[current_row, 1] = GridLayout() 
    drop_box = Box(drop_layout[1, 1], color=:lightgray, width=450, strokecolor=:gray, strokewidth=2, cornerradius=10, height=80)
    drop_label = Label(drop_layout[1, 1], "Drag & Drop CSV Here", halign=:center, valign=:center, color=RGBAf(0.3, 0.3, 0.3, 1.0))
    manager.widgets[:drop_box]   = drop_box
    manager.widgets[:drop_label] = drop_label
    current_row += 1
    
    # --- 2. EXECUTION CONTROLS (1/3 Width) ---
    exec_layout = layout[current_row, 1] = GridLayout()    
    manager.widgets[:run_button]   = Button(exec_layout[1, 1], label="Run Simulation", buttoncolor=:lightgreen, width = nothing)
    manager.widgets[:layout_apply] = Button(exec_layout[1, 2], label="Apply Layout", buttoncolor=:lightgreen, width=nothing)
    manager.widgets[:plot_button]  = Button(exec_layout[1, 3], label="Update Plot", buttoncolor=:lightgreen, width=nothing)
    colsize!(exec_layout, 1, Relative(1/3))
    colsize!(exec_layout, 2, Relative(1/3))
    colsize!(exec_layout, 3, Relative(1/3))
    current_row += 1

    # --- 3. HIERARCHICAL EDITOR ---
    param_nav_layout = layout[current_row, 1] = GridLayout()
    create_hierarchical_param_controls!(param_nav_layout)
    current_row += 1
    
    # --- 4. METHODS ---
    method_layout = layout[current_row, 1] = GridLayout()
    create_method_controls!(method_layout) 
    current_row += 1
    
    # --- 5. STATIC PLOT CONTROLS ---
    menu_area = layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = layout[current_row, 1] = GridLayout()
    current_row += 1
    export_layout = layout[current_row, 1] = GridLayout()

    build_static_plot_controls!(menu_area, slider_area)
    createExportOptions!(export_layout)
end

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

    # --- ROW BLOCK 1: Plot, Size, and Legend (Base) ---
    Label(menu_layout[cr,1], "Base Plot", font=:bold, color=:teal)
    Label(menu_layout[cr,2], "Plot Width", font=:bold, color=:teal)
    Label(menu_layout[cr,3], "Legend Base", font=:bold, color=:darkorchid)
    push!(gaps, 2); cr += 1

    manager.widgets[:base_plot]   = Menu(menu_layout[cr,1], options = base_opts)
    manager.widgets[:plot_width]  = Menu(menu_layout[cr,2], options = size_opts)
    manager.widgets[:legend_base] = Menu(menu_layout[cr,3], options = Any[menu_opt(:none), menu_opt(:center), menu_opt(:left), menu_opt(:right), menu_opt(:top), menu_opt(:bottom)])
    push!(gaps, 10); cr += 1

    # --- ROW BLOCK 2: Plot, Size, and Legend (Modifiers) ---
    Label(menu_layout[cr,1], "Plot Style", font=:bold, color=:teal)
    Label(menu_layout[cr,2], "Plot Height", font=:bold, color=:teal)
    Label(menu_layout[cr,3], "Legend Modifier", font=:bold, color=:darkorchid)
    push!(gaps, 2); cr += 1

    manager.widgets[:plot_style]  = Menu(menu_layout[cr,1], options = Any[menu_opt(:lines_1d), menu_opt(:lines_2d), menu_opt(:lines_3d)])
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
    manager.widgets[:compare_link]    = Menu(menu_layout[cr,3], options = Any[menu_opt(:fully_coupled), menu_opt(:coupled_colorbar), menu_opt(:decoupled)])

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
    manager.widgets[:component]           = Menu(menu_layout[cr,3], options = Any[("1",1)])

    for i in 1:3; colsize!(menu_layout, i, Relative(1/3)); end
    for (i, gap) in enumerate(gaps); rowgap!(menu_layout, i, gap); end

    # =========================================================================
    # --- SLIDERS ---
    # =========================================================================
    slider_row = 0
    
    for i in 1:MAX_SUPPORTED_PARAMS[] 
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
        p_str = string(p_sym)
        Label(slider_layout[slider_row, 1], "$p_str:", halign=:right)
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
# --- 4. HIERARCHICAL EDITOR BUILDER ---
# ==============================================================================
function create_hierarchical_param_controls!(layout::GridLayout)
    
    Label(layout[1, 1:4], "Parameter & UI Editor:", fontsize=16, font=:bold, color=:royalblue)
    
    drop_gl = layout[2, 1:4] = GridLayout()
    manager.widgets[:editor_cat]   = Menu(drop_gl[1, 1], options=[menu_opt(:simulation), menu_opt(:ui)], prompt="Category")
    manager.widgets[:editor_scope] = Menu(drop_gl[1, 2], options=[menu_opt(:none)], prompt="Scope")
    manager.widgets[:editor_key]   = Menu(drop_gl[1, 3], options=[menu_opt(:none)], prompt="Parameter")
    
    manager.widgets[:editor_text]   = Textbox(layout[3, 1:3], placeholder="Val / 'default'", width=nothing) 
    manager.widgets[:editor_toggle] = Button(layout[3, 4], label="Toggle", buttoncolor=:lightgray)          
end

# ==============================================================================
# --- 6. EXPORT OPTIONS BUILDER ---
# ==============================================================================
function createExportOptions!(layout::GridLayout)
    
    manager.widgets[:save_defs_button]   = Button(layout[1, 1], label="Save Defs", buttoncolor=:lightcoral, width=nothing)
    manager.widgets[:clear_defs_button]  = Button(layout[1, 2], label="Clear Defs", buttoncolor=:mistyrose, width=nothing) 
    manager.widgets[:lock_camera_button] = Button(layout[1, 3], label="Lock Camera", buttoncolor=:lightgray, width=nothing)
    
    manager.widgets[:play_anim_button]   = Button(layout[2, 1], label="Play Anim", buttoncolor=:lightyellow, width=nothing)
    manager.widgets[:save_image_button]  = Button(layout[2, 2], label="Save Image", buttoncolor=:lightblue, width=nothing)
    manager.widgets[:save_gif_button]    = Button(layout[2, 3], label="Save GIF", buttoncolor=:lightgreen, width=nothing)

    manager.widgets[:export_text]        = Textbox(layout[3, 1:3], placeholder = "Filename...", width=nothing)

    for i in 1:3; colsize!(layout, i, Relative(1/3)); end
end