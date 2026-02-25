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
    manager::PlotManager, 
    plot_data_obs::Observable, 
    active_params::Vector{String}
)
    GLMakie.activate!()
    plot_screen = GLMakie.Screen(title = "Makie Plot")
    # 2. FIX: Attach the Figure to the Screen immediately
    display(plot_screen, plot_fig)
    
    base_controls_fig = Figure(size = (350, 850)) 
    fig_layout = base_controls_fig.layout[1,1] = GridLayout(tellheight=false)
    rowgap!(fig_layout, 15) 
    current_row = 1

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
    
    # ... after current_row += 1 ...
    Label(fig_layout[current_row, 1], "Animation Control", fontsize=16, font=:bold)
    current_row += 1
    anim_layout = fig_layout[current_row, 1] = GridLayout()

    # Note: build_static_plot_controls! should now return the WIDGETS too
    x_obs, y_obs, dim_obs, selectors, widgets = build_static_plot_controls!(menu_area, slider_area, plot_data_obs, active_params)

   # 4. SAVE CONTROLS
    Label(fig_layout[current_row, 1], "Export Options:", fontsize=16, font=:bold)
    current_row += 1
    save_box_layout = fig_layout[current_row, 1] = GridLayout()
    createSaveFigBox(save_box_layout, plot_fig, manager)
    current_row += 1

    createAnimationControls!(anim_layout, plot_fig, manager, dim_obs, widgets, active_params)
    

    display(GLMakie.Screen(title="Makie Controls"), base_controls_fig)

    return base_controls_fig, update_notifier, ui_update, methods_obs, x_obs, y_obs, dim_obs, selectors
end

"""
    build_static_plot_controls!(...)

Builds the Menus and Sliders once. They react internally to `plot_data_obs` to 
update their ranges and options without destroying the UI.
"""
function build_static_plot_controls!(
    menu_layout::GridLayout, 
    slider_layout::GridLayout, 
    plot_data_obs::Observable,
    active_params::Vector{String},
    manager::PlotManager # Pass manager to register observables
)
    n_params = length(active_params)
    
    # Define Dimension Metadata
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"
    total_dims = length(dim_names)
    
    x_key_obs = Observable{String}("-")
    y_key_obs = Observable{String}("-")
    plot_dim_idx_obs = Observable{Int}(0)
    
    selector_values = Vector{Observable}(undef, total_dims)
    for i in 1:total_dims
        val_type = i == n_params+1 ? Int : Float64
        selector_values[i] = Observable{val_type}(val_type(1)) 
    end

    # --- Build UI Widgets Once ---
    Label(menu_layout[1,1], "X-Axis:")
    Label(menu_layout[2,1], "Y-Axis:")
    Label(menu_layout[3,1], "Plot Along:")

# 1. Register Axis Menus
    menu_x = Menu(menu_layout[1,2], options = ["-"])
    menu_y = Menu(menu_layout[2,2], options = ["-"])
    menu_axis = Menu(menu_layout[3,2], options = [("-", 1)])
    
    manager.controls["X-Axis_Selection"] = menu_x.selection
    manager.controls["X-Axis_Options"]   = menu_x.options
    manager.controls["Y-Axis_Selection"] = menu_y.selection
    manager.controls["Y-Axis_Options"]   = menu_y.options
    manager.controls["Plot-Along_Selection"] = menu_axis.selection
    manager.controls["Plot-Along_Options"]   = menu_axis.options

    # ... Build UI Widgets Loop ...
    for dim_i in 1:total_dims
        name = dim_names[dim_i]
        if dim_i == n_params + 1 # Component
            c_menu = Menu(slider_layout[dim_i, 2], options = ["1"])
            manager.controls["$(name)_Selection"] = c_menu.selection
            manager.controls["$(name)_Options"]   = c_menu.options
        else
            sl = Slider(slider_layout[dim_i, 2], range = 0:1)
            manager.controls["$(name)_Value"] = sl.value
            manager.controls["$(name)_Range"] = sl.range
        end
    end

    # --- Reactive Logic (Triggers when data refreshes) ---
    on(plot_data_obs) do plot_data_dict
        isempty(plot_data_dict) && return
        
        # 1. Update X Options
        all_keys = Set{String}()
        for pd in values(plot_data_dict); union!(all_keys, keys(pd.data)); end
        sorted_keys = sort(collect(all_keys))
        
        menu_x.options[] = sorted_keys
        if menu_x.selection[] == "-" || isnothing(menu_x.selection[])
            menu_x.selection[] = sorted_keys[1]
        end
        notify(menu_x.selection) # Cascade updates
    end

    on(menu_x.selection) do x_val
        (isnothing(x_val) || x_val == "-") && return
        plot_data_dict = plot_data_obs[]
        
        # 2. Update Y Options
        varied_dims = Set{Int}()
        for pd in values(plot_data_dict)
            if haskey(pd.data, x_val); union!(varied_dims, findall(s -> s > 1, size(pd.data[x_val]))); end
        end
        
        valid_y = String[]
        for y_can in menu_x.options[]
            y_varied = Set{Int}()
            for pd in values(plot_data_dict)
                if haskey(pd.data, y_can); union!(y_varied, findall(s -> s > 1, size(pd.data[y_can]))); end
            end
            if !isempty(intersect(varied_dims, y_varied)); push!(valid_y, y_can); end
        end
        
        menu_y.options[] = valid_y
        x_key_obs[] = x_val
        if menu_y.selection[] ∉ valid_y
            menu_y.selection[] = isempty(valid_y) ? "-" : valid_y[1]
        end
        notify(menu_y.selection)
    end

    on(menu_y.selection) do y_val
        (isnothing(y_val) || y_val == "-") && return
        x_val = menu_x.selection[]
        plot_data_dict = plot_data_obs[]

        # 3. Update Axis Options
        x_varied, y_varied = Set{Int}(), Set{Int}()
        for pd in values(plot_data_dict)
            if haskey(pd.data, x_val); union!(x_varied, findall(s -> s > 1, size(pd.data[x_val]))); end
            if haskey(pd.data, y_val); union!(y_varied, findall(s -> s > 1, size(pd.data[y_val]))); end
        end
        
        common = sort(collect(intersect(x_varied, y_varied)))
        menu_axis.options[] = isempty(common) ? [("-", 1)] : [(dim_names[d], d) for d in common]
        y_key_obs[] = y_val
        
        if menu_axis.selection[] ∉ common
            menu_axis.selection[] = isempty(common) ? 1 : common[end]
        else
            notify(menu_axis.selection)
        end
    end

    on(menu_axis.selection) do axis_idx
        (isnothing(axis_idx) || axis_idx == "-") && return
        plot_dim_idx_obs[] = axis_idx
        plot_data_dict = plot_data_obs[]
        
        # 4. Update Sliders Ranges
        for dim_i in 1:total_dims
            ctrl = control_objects[dim_i]
            is_axis = (dim_i == axis_idx)
            
            if dim_i == n_params+1 # Component
                max_c = 1
                for pd in values(plot_data_dict)
                    if haskey(pd.data, "u"); max_c = max(max_c, size(pd.data["u"], n_params + 1)); end
                end
                
                if is_axis
                    ctrl.options[] = ["-"]
                else
                    ctrl.options[] = string.(1:max_c)
                    if ctrl.selection[] == "-" || parse(Int, ctrl.selection[]) > max_c
                        ctrl.selection[] = "1"
                    end
                end
            else # Continuous Sliders
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
    create_plot_controls!(fig, plot_data_dict::Dict{String, UnifiedPlotData})

Creates a control panel with:
1. X/Y/Axis Selection Menus.
2. Permanent Sliders/Menus for [Component, P1..., Space, Time].

Instead of hiding controls, it "disables" the control for the active plot axis 
by setting its range to `[0]` (or options to `["-"]`) and updating the label.
"""
function create_plot_controls!(
    menu_layout::GridLayout, 
    slider_layout::GridLayout, 
    plot_data_dict::Dict{String, UnifiedPlotData}
)
    if isempty(plot_data_dict)
        error("No plot data available to generate controls.")
    end
    
    # --- 1. Metadata Setup ---
    # Use the first dataset to determine the dimension structure
    template_data = first(values(plot_data_dict))
    
    active_params = template_data.active_param_keys
    n_params = length(active_params)
    
    # Map Index -> Name
    # 1=Comp, 2..N+1=Params, N+2=Space, N+3=Time
    dim_names = Dict{Int, String}()
    
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"
    
    total_dims = length(dim_names)
    
    # The outputs
    x_key_obs = Observable{String}("-")
    y_key_obs = Observable{String}("-")
    plot_dim_idx_obs = Observable{Int}(0) # 0 means "Not selected yet"
    
    # Holds the current selected values (Physical Float for Params/Time, Int for Component)
    # If a dimension is disabled (plot axis), this might hold a dummy value.
    selector_values = Vector{Observable}(undef, total_dims)
    for i in 1:total_dims
        val_type = i == n_params+1 ? Int : Float64
        selector_values[i] = Observable{val_type}(val_type(1)) 
    end

    # --- 3. Build Selection Menus ---
    all_keys = Set{String}()
    for pd in values(plot_data_dict); union!(all_keys, keys(pd.data)); end
    sorted_keys = sort(collect(all_keys))

    Label(menu_layout[1,1], "X-Axis:")
    menu_x = Menu(menu_layout[1,2], options = sorted_keys, default = sorted_keys[1])
    
    Label(menu_layout[2,1], "Y-Axis:")
    menu_y = Menu(menu_layout[2,2], options = ["-"], default = "-")
    
    Label(menu_layout[3,1], "Plot Along:")
    menu_axis = Menu(menu_layout[3,2], options = [("-",1)], default = 1)

    # --- 4. Build Static Controls (Sliders/Menus) ---
    # We create them once. We will manipulate their 'range'/'options' observables later.
    
    # Store references to update them later
    control_objects = Vector{Any}(undef, total_dims) 

    for dim_i in 1:total_dims
        d_name = dim_names[dim_i]
        
        Label(slider_layout[dim_i, 1], "$d_name:", halign=:right)
        
        if dim_i == n_params+1
            # --- COMPONENT (Menu) ---
            # Default options (will be overwritten)
            c_menu = Menu(slider_layout[dim_i, 2], options = ["1"], default = "1")
            control_objects[dim_i] = c_menu
            
            # Label for Component (Display selection)
            Label(slider_layout[dim_i, 3], lift(s -> "C = $s", c_menu.selection))
            
            # Connect to Output
            on(c_menu.selection) do v
                if v != "-" && !isnothing(v)
                    selector_values[dim_i][] = parse(Int, v)
                end
            end
            notify(c_menu.selection)
            
        else
            # --- CONTINUOUS (Slider) ---
            # Default range (will be overwritten)
            sl = Slider(slider_layout[dim_i, 2], range = 0:1:10)
            control_objects[dim_i] = sl
            
            # Label with "N/A" Logic
            # Note: Makie sliders usually have a vector/abstract range as 'range'
            lab_text = lift(sl.value, sl.range) do val, r
                if r == [0] # The "Disabled" flag
                    "Axis"
                else
                    string(round(val, digits=3))
                end
            end
            Label(slider_layout[dim_i, 3], lab_text, width=60, halign=:left)
            
            # Connect to Output
            on(sl.value) do v
                # Only update if valid (not the dummy 0 from disable)
                # However, usually we just update anyway. 
                # The plotting lift checks `plot_dim_idx` and ignores this value if it's the axis.
                selector_values[dim_i][] = v
            end
        end
    end

    # --- 5. Menu Logic (Filters) ---
    
    # X -> Y
    on(menu_x.selection) do x_val
        if isnothing(x_val); return; end
        
        # Identify varied dimensions
        varied_dims = Set{Int}()
        for pd in values(plot_data_dict)
            if haskey(pd.data, x_val)
                union!(varied_dims, findall(s -> s > 1, size(pd.data[x_val])))
            end
        end
        
        # Filter Y
        valid_y = String[]
        for y_can in sorted_keys
            y_varied = Set{Int}()
            for pd in values(plot_data_dict)
                if haskey(pd.data, y_can)
                    union!(y_varied, findall(s -> s > 1, size(pd.data[y_can])))
                end
            end
            if !isempty(intersect(varied_dims, y_varied)); push!(valid_y, y_can); end
        end
        
        menu_y.options[] = valid_y
        x_key_obs[] = x_val
        menu_y.selection[] = isempty(valid_y) ? "Not Plottable" : valid_y[1]
    end
    notify(menu_x.selection)

    # Y -> Axis
    on(menu_y.selection) do y_val
        if isnothing(y_val); return; end
        x_val = menu_x.selection[]
        
        # Intersect varied dims
        x_varied, y_varied = Set{Int}(), Set{Int}()
        for pd in values(plot_data_dict)
            if haskey(pd.data, x_val); union!(x_varied, findall(s -> s > 1, size(pd.data[x_val]))); end
            if haskey(pd.data, y_val); union!(y_varied, findall(s -> s > 1, size(pd.data[y_val]))); end
        end
        
        common = sort(collect(intersect(x_varied, y_varied)))
        menu_axis.options[] = [(dim_names[d], d) for d in common]
        
        y_key_obs[] = y_val
        if !isempty(common); menu_axis.selection[] = common[end]; end
    end
    notify(menu_y.selection)

    # Axis -> Disable/Enable Sliders
    on(menu_axis.selection) do axis_idx
        if isnothing(axis_idx); return; end
        plot_dim_idx_obs[] = axis_idx
        
        # Loop through all controls and update their state
        for dim_i in 1:total_dims
            ctrl = control_objects[dim_i]
            
            # Is this the plot axis?
            is_axis = (dim_i == axis_idx)
            
            if dim_i == n_params+1
                # --- Update Component Menu ---
                # Find max components
                max_c = maximum(size(pd.data["u"], 1) for pd in values(plot_data_dict))
                
                if is_axis
                    ctrl.options[] = ["-"] # Disable
                    ctrl.selection[] = "-"
                else
                    ctrl.options[] = string.(1:max_c)
                    # Try to keep selection or reset to 1
                    if ctrl.selection[] == "-"; ctrl.selection[] = "1"; end
                end
                
            else
                # --- Update Continuous Slider ---
                # 1. Determine Global Range
                g_min, g_max = Inf, -Inf
                
                # Check data
                for pd in values(plot_data_dict)
                    vals = nothing
                    if dim_i <= n_params 
                        p_idx = dim_i
                        vals = pd.active_param_values[p_idx]
                    elseif dim_i == n_params + 2 # Space
                        if haskey(pd.data, "x"); vals = pd.data["x"]; end
                    elseif dim_i == n_params + 3 # Time
                        vals = pd.t_vals
                    end
                    
                    if !isnothing(vals) && !isempty(vals)
                        l, h = extrema(vals)
                        if l < g_min; g_min = l; end
                        if h > g_max; g_max = h; end
                    end
                end
                if isinf(g_min); g_min=0.0; g_max=1.0; end
                
                # 2. Update Slider Range
                if is_axis
                    ctrl.range[] = [0] # Disable!
                    # Value automatically jumps to 0
                else
                    # Construct range (approx 100 steps for smooth slider)
                    ctrl.range[] = range(g_min, g_max, length=100)
                end
            end
        end
    end
    notify(menu_axis.selection)

    return x_key_obs, y_key_obs, plot_dim_idx_obs, selector_values
end

# Backward compatibility (if you use it elsewhere)
function create_plot_controls!(fig::Figure, plot_data_dict)
    menu_layout = fig[1,1] = GridLayout()
    slider_layout = fig[2,1] = GridLayout()
    return create_plot_controls!(
        menu_layout, 
        slider_layout, 
        plot_data_dict
    )
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