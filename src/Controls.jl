module Controls

export PlotManager, create_controls, attach_plot_controls!

using GLMakie
using CairoMakie
using Printf
using Statistics
using LibGit2
using CSV, DataFrames
using Dates
using ..Structs
using ..Utils

include("ControlUtils.jl")

"""
    create_controls(...)

Creates the static UI window. The Menus and Sliders are generated once based 
on the maximum dimensionality of the simulation.
"""
function create_controls(
    plot_fig::Makie.Figure, 
    manager::PlotManager{D}, 
    plot_data_obs::Observable, 
) where {D}
    GLMakie.activate!()
    plot_screen = GLMakie.Screen(title = "Makie Plot")
    # 2. FIX: Attach the Figure to the Screen immediately
    display(plot_screen, plot_fig)
    
    base_controls_fig = Figure(size = (350, 850)) 
    fig_layout = base_controls_fig.layout[1,1] = GridLayout(tellheight=false)
    rowgap!(fig_layout, 15) 
    current_row = 1

    n_params = length(active_params)
    total_len = n_params + 1 + D + 1
    
    if !haskey(manager.controls, "var_types")
        # Default symbols from VariableControls
        defaults = vcat(fill(:slider, n_params), :menu, fill(:slider, D), :slider)
        manager.controls["var_types"] = Observable(defaults)
    end

    # 1. HEADER & REFRESH
    header_layout = fig_layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Simulation Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1
    
    update_layout = fig_layout[current_row, 1] = GridLayout()
    update_button = Button(update_layout[1,1], label="Refresh / Run Simulation", 
                           halign=:center, width=250, buttoncolor=:lightblue)
    
    update_notifier = Observable(0)
    manager.controls["Simulation_Update"] = update_notifier
    on(update_button.clicks) do _
        update_notifier[] += 1
        if !GLMakie.isopen(plot_screen)
            display(plot_fig)
        end
# 3. FIX: Safely recreate and display if the user accidentally closed the window
        if !GLMakie.isopen(plot_screen)
            plot_screen = GLMakie.Screen(title = "Makie Plot")
            display(plot_screen, plot_fig)
        end
    end
    current_row += 1

    # 2. METHOD SELECTION 
    Label(fig_layout[current_row, 1], "Active Comparison Methods:", fontsize=16, font=:bold)
    current_row += 1
    
    method_checkbox_layout = fig_layout[current_row, 1] = GridLayout()
    all_methods = filter(k -> k != "shared", collect(keys(manager.simulation)))
    methods_obs = Observable(all_methods)
    createMethodCheckboxes!(method_checkbox_layout, methods_obs, manager) 
    current_row += 1

    # 3. HIERARCHICAL PARAMETER NAVIGATOR
    Label(fig_layout[current_row, 1], "Parameter & UI Editor:", fontsize=16, font=:bold, color=:royalblue)
    current_row += 1
    param_nav_layout = fig_layout[current_row, 1] = GridLayout()
    create_hierarchical_param_controls!(param_nav_layout, manager)
    current_row += 1

    # 5. STATIC PLOT CONTROLS SLOT
    Label(fig_layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
    Label(fig_layout[current_row, 1], "Data Exploration (Axes & Sliders)", 
          fontsize=16, font=:bold, color=:darkgreen)
    current_row += 1
    
    # We build the controls ONCE here.
    menu_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1
    
    # STATIC PLOT CONTROLS SLOT
    menu_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1
    slider_area = fig_layout[current_row, 1] = GridLayout()
    current_row += 1

    x_obs, y_obs, dim_obs, selectors, widgets = build_static_plot_controls!(
        menu_area, slider_area, plot_data_obs, active_params, manager
    )

   # 4. SAVE CONTROLS
    Label(fig_layout[current_row, 1], "Export Options:", fontsize=16, font=:bold)
    current_row += 1
    save_box_layout = fig_layout[current_row, 1] = GridLayout()
    createSaveFigBox(save_box_layout, plot_fig, manager)
    current_row += 1

    createAnimationControls!(anim_layout, plot_fig, manager, dim_obs, widgets, active_params)
    

    display(GLMakie.Screen(title="Makie Controls"), base_controls_fig)

    return base_controls_fig
end

function build_static_plot_controls!(
    menu_layout::GridLayout, 
    slider_layout::GridLayout, 
    plot_data_obs::Observable,
    active_params::Vector{String},
    manager::PlotManager{D}
) where {D}
    # 1. Metadata & Initialization
    n_params = length(active_params)
    
    # Names for labels
    dim_names = vcat(active_params, Structs.VariableNames[1], Structs.VariableNames[2:1+D], Structs.VariableNames[5])
    total_dims = length(dim_names)
    
    x_key_obs = Observable{String}("-")
    y_key_obs = Observable{String}("-")
    plot_dim_idx_obs = Observable{Int}(0)
    
    # Store widget objects to update them reactively
    control_objects = Vector{Any}(undef, total_dims)
    selector_values = Vector{Observable}(undef, total_dims)

    # 2. Setup Axis Menus
    menu_x = Menu(menu_layout[1,2], options = ["-"])
    menu_y = Menu(menu_layout[2,2], options = ["-"])
    menu_axis = Menu(menu_layout[3,2], options = [("-", 1)])
    
    # Register in manager for Zen-state
    manager.controls["X-Axis_Selection"] = menu_x.selection
    manager.controls["Y-Axis_Selection"] = menu_y.selection
    manager.controls["Plot-Along_Selection"] = menu_axis.selection

    # 3. Create Param Sliders (1..n_params)
    for i in 1:n_params
        Label(slider_layout[i, 1], "$(dim_names[i]):", halign=:right)
        sl = Slider(slider_layout[i, 2], range = 0:0.1:1)
        control_objects[i] = sl
        selector_values[i] = sl.value
        
        manager.controls["$(dim_names[i])_Value"] = sl.value
        manager.controls["$(dim_names[i])_Range"] = sl.range
        
        Label(slider_layout[i, 3], lift(v -> @sprintf("%.3f", v), sl.value), width=50)
    end

    # 4. Create Base Variable Widgets (Component, Space, Time)
    # Mapping VariableControls indices to our grid row
    for b_idx in 1:length(VariableControls)
        # Skip spatial dimensions not present in the simulation
        # b_idx: 1=c, 2=x, 3=y, 4=z, 5=t
        if b_idx > 1 && b_idx < 5 && (b_idx - 1) > D
            continue
        end

        # Calculate absolute dimension index in the selector_values vector
        # Params... -> C -> Space(D) -> Time
        abs_idx = (b_idx == 5) ? total_dims : (n_params + b_idx)
        
        Label(slider_layout[abs_idx, 1], "$(dim_names[abs_idx]):", halign=:right)
        
        if VariableControls[b_idx] == :menu
            m = Menu(slider_layout[abs_idx, 2], options = ["1"])
            control_objects[abs_idx] = m
            # Handle menu selection strings vs numeric data
            selector_values[abs_idx] = Observable{Int}(1)
            on(m.selection) do s
                if !isnothing(s) && s != "-"; selector_values[abs_idx][] = parse(Int, s); end
            end
            manager.controls["$(dim_names[abs_idx])_Selection"] = m.selection
        else
            sl = Slider(slider_layout[abs_idx, 2], range = 0:0.1:1)
            control_objects[abs_idx] = sl
            selector_values[abs_idx] = sl.value
            manager.controls["$(dim_names[abs_idx])_Value"] = sl.value
            manager.controls["$(dim_names[abs_idx])_Range"] = sl.range
        end
        
        Label(slider_layout[abs_idx, 3], lift(v -> string(v), selector_values[abs_idx]), width=50)
    end

    # 5. Reactive Logic: Handle Overwrites/Skip via var_types
    # This reacts to manager.controls["var_types"] and disables widgets
    on(manager.controls["Simulation_Update"]) do vt
        for i in 1:total_dims
            ctrl = control_objects[i]
            val = vt[i]
            
            # If a number is provided, we disable the widget visually
            if val isa Number
                if ctrl isa Slider
                    ctrl.range[] = [val] # Fixed range
                elseif ctrl isa Menu
                    ctrl.options[] = [string(val)]
                    ctrl.selection[] = string(val)
                end
            end
        end
    end

    # 6. Reactive Logic: Update Ranges from Data
    # (Same logic as before, but using the generalized control_objects vector)
    on(menu_axis.selection) do axis_idx
        (isnothing(axis_idx) || axis_idx == "-") && return
        plot_dim_idx_obs[] = axis_idx
        data = plot_data_obs[]
        vt = manager.controls["var_types"][]

        for i in 1:total_dims
            # Skip if this dimension is currently overwritten by a number
            vt[i] isa Number && continue
            
            ctrl = control_objects[i]
            is_axis = (i == axis_idx)
            
            if is_axis
                if ctrl isa Slider; ctrl.range[] = [0]; else; ctrl.options[] = ["-"]; end
            else
                g_min, g_max = Inf, -Inf
                for pd in values(plot_data_dict)
                    vals = nothing
                    if dim_i <= n_params 
                        vals = pd.active_param_values[dim_i]
                    elseif dim_i == n_params + 2; vals = get(pd.data, "x", nothing)
                    elseif dim_i == n_params + 3; vals = pd.t_vals
                    end
                    if !isnothing(vals) && !isempty(vals)
                        l, h = extrema(vals)
                        if l < g_min; g_min = l; end
                        if h > g_max; g_max = h; end
                    end
                end
                if isinf(g_min); g_min=0.0; g_max=1.0; end
                
                if is_axis
                    ctrl.range[] = [0] # Marks as disabled
                else
                    ctrl.range[] = g_min == g_max ? [g_min] : range(g_min, g_max, length=100)
                end
            end
        end
    end

    return x_key_obs, y_key_obs, plot_dim_idx_obs, selector_values, control_objects
end

"""
    create_hierarchical_param_controls!(layout, manager::PlotManager)

Creates a 3-menu + 1-textbox interface to navigate and edit all parameters.
"""
function create_hierarchical_param_controls!(layout::GridLayout, mgr::PlotManager)
    # 1. Menus
    # Categories are fixed strings matching the field names (capitalized for UI)
    cat_mapping = Dict("Simulation" => :simulation, "UI" => :ui, "Controls" => :controls)
    sorted_cat = sort(collect(keys(cat_mapping)))
    menu_cat = Menu(layout[1, 1:2], options = sorted_cat, default = "UI", prompt = "Category...")
    
    menu_scope = Menu(layout[2, 1:2], options = ["-"], default = "-", prompt = "Scope...")
    menu_key = Menu(layout[3, 1:2], options = ["-"], default = "-", prompt = "Key...")
    
    active_target_obs = Observable{Any}(nothing)
    ui_update = Observable{Int}(0)
    # 2. Category -> Scope (Accessing fields directly)
    on(menu_cat.selection) do cat
        isnothing(cat) && return
        field_name = cat_mapping[cat]
        data = getproperty(mgr, field_name)
        
        if field_name == :controls
            menu_scope.options[] = ["Live"] # Flat dict has one virtual scope
        else
            menu_scope.options[] = sort(collect(keys(data)))
        end
        menu_scope.selection[] = nothing
    end

    # 3. Scope -> Key
    on(menu_scope.selection) do scope
        isnothing(scope) && return
        cat = menu_cat.selection[]
        field_name = cat_mapping[cat]
        data = getproperty(mgr, field_name)
        
        if field_name == :controls
            menu_key.options[] = sort(collect(keys(data)))
        else
            menu_key.options[] = sort(collect(keys(data[scope])))
        end
    end

    # 4. Textbox with Live Placeholder
    Label(layout[4, 1], "Edit Value:", halign=:right)
    
    # Show what is currently loaded in the plot
    placeholder_text = lift(menu_key.selection) do k
        isnothing(k) && return "Select key..."
        val = get(mgr.last_run_params, k, "default")
        return "Loaded: $val"
    end

    tb = Textbox(layout[4, 2], placeholder = placeholder_text, reset_on_defocus = true)

# When a key is selected, we update the Textbox
    on(menu_key.selection) do key
        isnothing(key) && return
        cat, scope = menu_cat.selection[], menu_scope.selection[]
        
        field_data = getproperty(mgr, cat_mapping[cat])
        obs = field_data[scope][key]
        
        active_target_obs[] = obs
        # Show the actual value as a string for editing
        tb.stored_string[] = string(to_value(obs))
    end

    # Handle Textbox Submission with the NEW Smart Parser
    on(tb.stored_string) do s
        obs = active_target_obs[]
        isnothing(obs) && return
        
        # This replaces the old 'parsed = parseValue(s)' logic
        smart_parse_and_update!(obs, s)
        if menu_cat.selection[] == "UI"; ui_update[] += 1 end
    end
    mgr.controls["UI_Update"] = ui_update
    return
end

end