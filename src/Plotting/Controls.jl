# ==============================================================================
# --- HELPER: ENSURE DICTIONARY STRUCTURE ---
# ==============================================================================
function ensure_control_dicts!(manager::PlotManager)
    # Define the supertypes for our UI state
    supertypes = ["Widget", "Options", "Selection", "Value", "Range", "String", "Button", "State"]
    for k in supertypes
        if !haskey(manager.controls, k)
            manager.controls[k] = Dict{String, Observable}()
        end
    end
end

# ==============================================================================
# --- 1. MASTER CONTROL BUILDER ---
# ==============================================================================
"""
    create_controls(layout::GridLayout, manager::PlotManager)

Purely builds the UI widgets inside the provided sub-layout.
"""
function create_controls(layout::GridLayout, manager::PlotManager)
    ensure_control_dicts!(manager)
    
    rowgap!(layout, 15) 
    current_row = 1

    # --- 1. HEADER & DRAG/DROP ZONE ---
    header_layout = layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Simulation Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1

    drop_layout = layout[current_row, 1] = GridLayout() # Native width filling!
    drop_box = Box(drop_layout[1, 1], color=:lightgray, width=450, strokecolor=:gray, strokewidth=2, cornerradius=10, height=80)
    drop_label = Label(drop_layout[1, 1], "Drag & Drop CSV Here", halign=:center, valign=:center, color=RGBAf(0.3, 0.3, 0.3, 1.0))
    
    manager.controls["Widget"]["Drop_Box"] = Observable{Any}(drop_box)
    manager.controls["Widget"]["Drop_Label"] = Observable{Any}(drop_label)
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
    Label(layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
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
    
    # Quick registration helpers
    function _reg_menu(k, m)
        manager.controls["Widget"][k]    = Observable{Any}(m)
        manager.controls["Selection"][k] = m.selection
        manager.controls["Options"][k]   = m.options
    end
    function _reg_slider(k, s)
        manager.controls["Widget"][k] = Observable{Any}(s)
        manager.controls["Value"][k]  = s.value
        manager.controls["Range"][k]  = s.range
    end

    # --- MENUS ---
    Label(menu_layout[1,1], "X-Axis", font=:bold); Label(menu_layout[1,2], "Y-Axis", font=:bold)
    Label(menu_layout[1,3], "Z-Axis", font=:bold); Label(menu_layout[1,4], "U-Axis (Dep)", font=:bold)
    
    menu_x = Menu(menu_layout[2,1], options = ["-"]); _reg_menu("X-Axis", menu_x)
    menu_y = Menu(menu_layout[2,2], options = ["disabled"]); _reg_menu("Y-Axis", menu_y)
    menu_z = Menu(menu_layout[2,3], options = ["disabled"]); _reg_menu("Z-Axis", menu_z)
    menu_u = Menu(menu_layout[2,4], options = ["-"]); _reg_menu("U-Axis", menu_u)

    Label(menu_layout[3,1], "Compare Target", font=:bold, color=:darkorange)
    Label(menu_layout[3,2], "Grid Columns", font=:bold, color=:darkorange)
    Label(menu_layout[3,3], "Compare Link", font=:bold, color=:darkorange)
    Label(menu_layout[3,4], "Anim Target", font=:bold, color=:darkorange)

    compare_opts = String["None", "Methods"]
    anim_opts = Any[("-", 0)]

    for (i, p) in enumerate(manager.plot_vars)
        if p == "c"
            push!(compare_opts, "Component")
            # Exclude 'c' from anim_opts
        elseif p == "t"
            push!(compare_opts, "Time")
            push!(anim_opts, ("Time", i))
        elseif p in ("x", "y", "z")
            # Exclude 'x', 'y', 'z' from compare_opts
            push!(anim_opts, (p, i))
        else
            push!(compare_opts, p)
            push!(anim_opts, (p, i))
        end
    end

    menu_tgt  = Menu(menu_layout[4,1], options = compare_opts); _reg_menu("Compare_Target", menu_tgt)
    menu_cols = Menu(menu_layout[4,2], options = ["1", "2", "3", "4", "5"]); _reg_menu("Compare_Columns", menu_cols)
    menu_link = Menu(menu_layout[4,3], options = ["Fully Coupled", "Coupled Colorbar", "Decoupled"]); _reg_menu("Compare_Link", menu_link)
    menu_anim = Menu(menu_layout[4,4], options = anim_opts); _reg_menu("Anim_Target", menu_anim)
    # ----------------------------------------------------------------------------

    Label(menu_layout[5,1], "Legend Base", font=:bold, color=:darkorchid)
    Label(menu_layout[5,2], "Legend Modifier", font=:bold, color=:darkorchid)
    Label(menu_layout[5,3], "Plot Type", font=:bold)
    Label(menu_layout[5,4], "Component", font=:bold)

    leg_base_opts = ["none", "center", "left", "right", "top", "bottom"]
    leg_add_opts  = ["none", "detached", "left", "right", "top", "bottom"]
    plot_opts = [("Lines", :lines), ("Heatmap", :heatmap), ("Contour", :contour), ("Contourf", :contourf), ("Volume", :volume), ("Surface", :surface), ("Scatter 2D", :scatter2d), ("Scatter 3D", :scatter3d)]
    
    menu_lbase = Menu(menu_layout[6,1], options = leg_base_opts); _reg_menu("Legend_Base", menu_lbase)
    menu_ladd  = Menu(menu_layout[6,2], options = leg_add_opts); _reg_menu("Legend_Add", menu_ladd)
    menu_type  = Menu(menu_layout[6,3], options = plot_opts); _reg_menu("Plot_Type", menu_type)
    menu_comp  = Menu(menu_layout[6,4], options = ["1"]); _reg_menu("c", menu_comp)

    Label(menu_layout[7,1], "Plot Width", font=:bold, color=:teal)
    Label(menu_layout[7,2], "Plot Height", font=:bold, color=:teal)
    
    size_opts = [string(i) for i in 100:100:1000]
    menu_w = Menu(menu_layout[8,1], options = size_opts); _reg_menu("Plot_Width", menu_w)
    menu_h = Menu(menu_layout[8,2], options = size_opts); _reg_menu("Plot_Height", menu_h)

    for i in 1:4; colsize!(menu_layout, i, Relative(0.25)); end

    # THE FIX: Visually fuse labels to their respective dropdowns!
    rowgap!(menu_layout, 1, 2)  # Tiny gap between Axis Labels & Axis Menus
    rowgap!(menu_layout, 2, 15) # Standard gap to the next section
    rowgap!(menu_layout, 3, 2)  # Compare Labels & Menus
    rowgap!(menu_layout, 4, 15) 
    rowgap!(menu_layout, 5, 2)  # Legend Labels & Menus
    rowgap!(menu_layout, 6, 15) 
    rowgap!(menu_layout, 7, 2)  # Plot Size Labels & Menus

    # --- SLIDERS (Static Pre-allocation Architecture) ---
    slider_row = 1
    
    # 1. Abstract Parameter Sliders (Pool of 3)
    for i in 1:3 
        p_key = "param_$i"
        lbl_text = Observable("Param $i:")
        manager.controls["String"]["$(p_key)_Label"] = Observable{Any}(lbl_text)
        
        Label(slider_layout[slider_row, 1], lbl_text, halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        _reg_slider(p_key, sl)
        
        val_lbl = Label(slider_layout[slider_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), sl.value), halign=:left)
        slider_row += 1
    end

    # 2. Base Spatial/Time Sliders
    for p in ["x", "y", "z", "t"]
        Label(slider_layout[slider_row, 1], "$p:", halign=:right)
        sl = Slider(slider_layout[slider_row, 2], range=[0.0], startvalue=0.0, width=nothing)
        _reg_slider(p, sl)
        
        val_lbl = Label(slider_layout[slider_row, 3], lift(v -> v isa AbstractFloat ? @sprintf("%.3f", v) : string(v), sl.value), halign=:left)
        slider_row += 1
    end
    
    colsize!(slider_layout, 1, Fixed(80))    
    colsize!(slider_layout, 2, Relative(0.7)) 
    colsize!(slider_layout, 3, Fixed(60))
    for r in 1:6; rowgap!(slider_layout, r, 5); end
    
    manager.controls["State"]["Active_Axes"] = Observable{Vector{Int}}(Int[])
end

# ==============================================================================
# --- 3. DIMENSION OVERWRITES BUILDER ---
# ==============================================================================
function create_base_overwrite_controls!(layout::GridLayout, manager::PlotManager)
    menu_var = Menu(layout[1, 1], options = ["-"], prompt = "Select...")
    tb_val   = Textbox(layout[1, 2], placeholder = "Val / 'default'", width = nothing) 
    mode_btn = Button(layout[1, 3], label = "Mode: Activate", buttoncolor = :lightgreen)
    menu_mth = Menu(layout[1, 4], options = ["-"], prompt = "Methods...")

    colsize!(layout, 1, Relative(0.25)); colsize!(layout, 2, Relative(0.25))
    colsize!(layout, 3, Relative(0.25)); colsize!(layout, 4, Relative(0.25))

    manager.controls["Widget"]["Overwrite_Var"]   = Observable{Any}(menu_var)
    manager.controls["Selection"]["Overwrite_Var"]= menu_var.selection
    manager.controls["Options"]["Overwrite_Var"]  = menu_var.options
    
    manager.controls["Widget"]["Overwrite_Text"]  = Observable{Any}(tb_val)
    manager.controls["String"]["Overwrite_Text"]  = tb_val.stored_string

    manager.controls["Widget"]["Mode_Button"]     = Observable{Any}(mode_btn)
    manager.controls["Button"]["Mode_Clicks"]     = mode_btn.clicks

    manager.controls["Widget"]["Method_Toggle"]   = Observable{Any}(menu_mth)
    manager.controls["Selection"]["Method_Toggle"]= menu_mth.selection
    manager.controls["Options"]["Method_Toggle"]  = menu_mth.options
    
    manager.controls["State"]["Is_Activate_Mode"] = Observable(true)
end

# ==============================================================================
# --- 4. HIERARCHICAL EDITOR BUILDER ---
# ==============================================================================
function create_hierarchical_param_controls!(layout::GridLayout, manager::PlotManager)
    menu_cat   = Menu(layout[1, 1], options = ["Simulation", "UI"], prompt = "Category...", width=nothing)
    menu_scope = Menu(layout[1, 2], options = ["-"], default = "-", prompt = "Scope...", width=nothing)
    menu_key   = Menu(layout[1, 3], options = ["-"], default = "-", prompt = "Key...", width=nothing)
    
    colsize!(layout, 1, Relative(1/3)); colsize!(layout, 2, Relative(1/3)); colsize!(layout, 3, Relative(1/3))
    
    btn_layout = layout[2, 1:3] = GridLayout()
    btn_bool   = Button(btn_layout[1, 1], label="Toggle", buttoncolor=:lightgray, width=nothing)
    btn_reset  = Button(btn_layout[1, 2], label="Reset", buttoncolor=:lightcoral, width=nothing)
    btn_run    = Button(btn_layout[1, 3], label="Run Sim", buttoncolor=:lightgray, width=nothing) # THE NEW BUTTON
    
    # THE FIX: Split the buttons into thirds perfectly!
    colsize!(btn_layout, 1, Relative(1/3)); colsize!(btn_layout, 2, Relative(1/3)); colsize!(btn_layout, 3, Relative(1/3))
    
    tb = Textbox(layout[3, 1:3], placeholder = "Select key...", reset_on_defocus = false, width = nothing)

    manager.controls["Widget"]["Editor_Cat"]    = Observable{Any}(menu_cat)
    manager.controls["Selection"]["Editor_Cat"] = menu_cat.selection
    manager.controls["Options"]["Editor_Cat"]   = menu_cat.options

    manager.controls["Widget"]["Editor_Scope"]    = Observable{Any}(menu_scope)
    manager.controls["Selection"]["Editor_Scope"] = menu_scope.selection
    manager.controls["Options"]["Editor_Scope"]   = menu_scope.options

    manager.controls["Widget"]["Editor_Key"]    = Observable{Any}(menu_key)
    manager.controls["Selection"]["Editor_Key"] = menu_key.selection
    manager.controls["Options"]["Editor_Key"]   = menu_key.options

    manager.controls["Widget"]["Editor_Toggle"] = Observable{Any}(btn_bool)
    manager.controls["Button"]["Editor_Toggle"] = btn_bool.clicks

    manager.controls["Widget"]["Editor_Reset"] = Observable{Any}(btn_reset)
    manager.controls["Button"]["Editor_Reset"] = btn_reset.clicks

    # THE FIX: Register the newly moved Run button so the Brain can find it!
    manager.controls["Widget"]["Run_Button"] = Observable{Any}(btn_run)
    manager.controls["Button"]["Run_Clicks"] = btn_run.clicks

    manager.controls["Widget"]["Editor_Text"] = Observable{Any}(tb)
    manager.controls["String"]["Editor_Text"] = tb.stored_string
    manager.controls["String"]["Editor_Display"] = tb.displayed_string 
    
    manager.controls["State"]["Active_Target_Obs"] = Observable{Any}(nothing)
end

# ==============================================================================
# --- 6. EXPORT OPTIONS BUILDER (Add to Controls.jl) ---
# ==============================================================================
"""
    createExportOptions!(layout::GridLayout, manager::PlotManager)

Purely builds the Export UI (Textbox + Buttons) and registers them into manager.controls.
"""
function createExportOptions!(layout::GridLayout, manager::PlotManager)
    # Span the textbox across all 5 columns now
    saveBox = Textbox(layout[2, 1:5], placeholder = "Filename...", width=nothing)
    
    btn_save_def = Button(layout[1, 1], label="Save Defs", buttoncolor=:lightcoral)
    btn_clr_def  = Button(layout[1, 2], label="Clear Defs", buttoncolor=:mistyrose) # THE NEW BUTTON
    btn_play     = Button(layout[1, 3], label="Play Anim", buttoncolor=:lightyellow)
    btn_img      = Button(layout[1, 4], label="Save Image", buttoncolor=:lightblue)
    btn_gif      = Button(layout[1, 5], label="Save GIF", buttoncolor=:lightgreen)

    for i in 1:5
        colsize!(layout, i, Relative(0.20))
    end

    # Register Widgets
    manager.controls["Widget"]["Export_Text"] = Observable{Any}(saveBox)
    manager.controls["String"]["Export_Text"] = saveBox.stored_string
    
    manager.controls["Widget"]["Save_Defs_Button"] = Observable{Any}(btn_save_def)
    manager.controls["Button"]["Save_Defs_Clicks"] = btn_save_def.clicks
    
    # Register the new Clear button
    manager.controls["Widget"]["Clear_Defs_Button"] = Observable{Any}(btn_clr_def)
    manager.controls["Button"]["Clear_Defs_Clicks"] = btn_clr_def.clicks
    
    manager.controls["Widget"]["Play_Anim_Button"] = Observable{Any}(btn_play)
    manager.controls["Button"]["Play_Anim_Clicks"] = btn_play.clicks
    
    manager.controls["Widget"]["Save_Image_Button"] = Observable{Any}(btn_img)
    manager.controls["Button"]["Save_Image_Clicks"] = btn_img.clicks
    
    manager.controls["Widget"]["Save_GIF_Button"] = Observable{Any}(btn_gif)
    manager.controls["Button"]["Save_GIF_Clicks"] = btn_gif.clicks

    # Register Animation States
    manager.controls["State"]["Is_Animating"] = Observable(false)
    manager.controls["Misc"]["Animation_Timer"] = Observable{Any}(nothing)
end