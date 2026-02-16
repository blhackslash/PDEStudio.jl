module Controls

include("ControlUtils.jl")

"""
    createBaseControlsFigure(...)

Creates the static control window containing:
1. Parameter Configuration (Textboxes via a popup).
2. Method Selection (Checkboxes).
3. "Refresh Data" Button (Triggers re-simulation).
4. Save Controls.
5. A placeholder slot for the dynamic plot controls.

Returns:
- `base_controls_fig`: The Makie Figure.
- `update_notifier`: Observable triggered by the "Refresh" button (Signal: Force Reload).
- `methods_obs`: Observable for active methods (Signal: Add/Remove Method).
- `plot_controls_slot`: A GridLayout where the dynamic sliders should be attached.
"""
function createBaseControlsFigure(
    plot_fig_ref::Makie.Figure,
    shared_params_obs::Dict{String, Observable},
    method_params_collection_obs::Dict{String, Dict{String, Observable}},
    methods_obs::Observable{Vector{String}},
    all_method_names::Vector{String},
    ui_options_obs::Dict{String, Observable},
    scene_obs::Dict{String, Observable}
)
    GLMakie.activate!()

    # --- Windows Setup ---
    plot_screen = GLMakie.Screen(title = "Makie Plot")
    params_screen = GLMakie.Screen(title = "Makie Parameters")
    params_fig = Figure() 
    
    # Main Control Figure
    base_controls_fig = Figure(size = (300, 800)) 
    fig_layout = base_controls_fig.layout[1,1] = GridLayout(tellheight=false)
    rowgap!(fig_layout, 15) 

    current_row = 1

    # ==============================================================================
    # 1. HEADER & REFRESH (Force Reload)
    # ==============================================================================
    header_layout = fig_layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Simulation Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1
    
    update_layout = fig_layout[current_row, 1] = GridLayout()
    update_button = Button(update_layout[1,1], label="Refresh / Run Simulation", halign=:center, width=220, buttoncolor=:lightblue)
    
    # The signal for "Case 1": Re-run simulations with current fixed params
    update_notifier = Observable(0)
    on(update_button.clicks) do _
        update_notifier[] += 1
        # Bring plot window to front if needed
        if !GLMakie.isopen(plot_screen)
            plot_screen = GLMakie.Screen(title = "Makie Plot")
            display(plot_screen, plot_fig_ref)
        end
    end
    current_row += 1

    # ==============================================================================
    # 2. PARAMETER POPUP (The Textboxes)
    # ==============================================================================
    Label(fig_layout[current_row, 1], "Edit Fixed Parameters:", fontsize=16, halign=:left)
    current_row += 1
    
    all_method_sorted = sort!(all_method_names)
    menu_options = ["UI Options"; "Shared Parameters"; all_method_sorted]

    param_view_menu = Menu(fig_layout[current_row, 1], options = menu_options)
    selected_param_key_obs = param_view_menu.selection 
    current_row += 1

    # Logic to populate the popup window based on menu selection
    on(selected_param_key_obs) do selected_key
        if selected_key == "Shared Parameters"
            populate_parameter_figure!("Shared Parameters", shared_params_obs, 2, params_fig)
        elseif selected_key == "UI Options"
            populate_parameter_figure!("UI Style Options", ui_options_obs, 2, params_fig)
        elseif haskey(method_params_collection_obs, selected_key)
            populate_parameter_figure!("$selected_key Parameters", method_params_collection_obs[selected_key], 2, params_fig)
        else
            empty!(params_fig)
            Label(params_fig[1,1], "Select a parameter set.", halign=:center)
        end
        
        if !GLMakie.isopen(params_screen)
            params_screen = GLMakie.Screen(title = "Makie Parameters")
            display(params_screen, params_fig)
        end
    end

    # ==============================================================================
    # 3. METHOD SELECTION (Case 2: Add/Remove)
    # ==============================================================================
    Label(fig_layout[current_row, 1], "Active Methods:", fontsize=16, font=:bold, halign=:center)
    current_row += 1
    
    method_checkbox_layout = fig_layout[current_row, 1] = GridLayout()
    # This function (from your Utils) attaches listeners to methods_obs directly
    createMethodCheckboxes(method_checkbox_layout, methods_obs, all_method_sorted) 
    current_row += 1

    # ==============================================================================
    # 4. SAVE CONTROLS
    # ==============================================================================
    Label(fig_layout[current_row, 1], "Export:", fontsize=16, font=:bold, halign=:center)
    current_row += 1
    
    save_box_layout = fig_layout[current_row, 1] = GridLayout()
    createSaveFigBox(save_box_layout, plot_fig_ref, shared_params_obs, method_params_collection_obs, methods_obs, ui_options_obs, scene_obs)
    current_row += 1

    # ==============================================================================
    # 5. DYNAMIC PLOT CONTROLS SLOT
    # ==============================================================================
    # We add a visual separator
    Label(fig_layout[current_row, 1], "__________________________", color=:gray)
    current_row += 1
    
    Label(fig_layout[current_row, 1], "Plot Controls", fontsize=18, font=:bold, halign=:center, color=:royalblue)
    current_row += 1
    
    # This is the empty slot we return. The main script will fill it.
    plot_controls_slot = fig_layout[current_row, 1] = GridLayout()
    
    # Initial Display
    display(params_screen, params_fig)
    display(plot_screen, plot_fig_ref)
    display(GLMakie.Screen(title="Makie Controls"), base_controls_fig)

    return base_controls_fig, update_notifier, methods_obs, plot_controls_slot
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
    dim_names[1] = "Component"
    for (i, p) in enumerate(active_params); dim_names[1+i] = p; end
    dim_names[1+n_params+1] = "Space"
    dim_names[1+n_params+2] = "Time"
    
    total_dims = length(dim_names)
    
    # The outputs
    x_key_obs = Observable{Union{String, Nothing}}(nothing)
    y_key_obs = Observable{Union{String, Nothing}}(nothing)
    plot_dim_idx_obs = Observable{Int}(0) # 0 means "Not selected yet"
    
    # Holds the current selected values (Physical Float for Params/Time, Int for Component)
    # If a dimension is disabled (plot axis), this might hold a dummy value.
    selector_values = Vector{Observable}(undef, total_dims)
    for i in 1:total_dims
        val_type = i == 1 ? Int : Float64
        selector_values[i] = Observable{val_type}(val_type(1)) 
    end

    # --- 3. Build Selection Menus ---
    all_keys = Set{String}()
    for pd in values(plot_data_dict); union!(all_keys, keys(pd.data)); end
    sorted_keys = sort(collect(all_keys))

    Label(menu_layout[1,1], "X-Axis:")
    menu_x = Menu(menu_layout[1,2], options = sorted_keys)
    
    Label(menu_layout[1,3], "Y-Axis:")
    menu_y = Menu(menu_layout[1,4], options = String[])
    
    Label(menu_layout[1,5], "Plot Along:")
    menu_axis = Menu(menu_layout[1,6], options = String[])

    # --- 4. Build Static Controls (Sliders/Menus) ---
    # We create them once. We will manipulate their 'range'/'options' observables later.
    
    # Store references to update them later
    control_objects = Vector{Any}(undef, total_dims) 

    for dim_i in 1:total_dims
        d_name = dim_names[dim_i]
        
        Label(slider_layout[dim_i, 1], "$d_name:", halign=:right)
        
        if dim_i == 1
            # --- COMPONENT (Menu) ---
            # Default options (will be overwritten)
            c_menu = Menu(slider_layout[dim_i, 2], options = ["1"])
            control_objects[dim_i] = c_menu
            
            # Label for Component (Display selection)
            Label(slider_layout[dim_i, 3], lift(s -> "C = $s", c_menu.selection))
            
            # Connect to Output
            on(c_menu.selection) do v
                if v != "-" && !isnothing(v)
                    selector_values[dim_i][] = parse(Int, v)
                end
            end
            
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
        menu_y.selection[] = nothing
    end

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

    # Axis -> Disable/Enable Sliders
    on(menu_axis.selection) do axis_idx
        if isnothing(axis_idx); return; end
        plot_dim_idx_obs[] = axis_idx
        
        # Loop through all controls and update their state
        for dim_i in 1:total_dims
            ctrl = control_objects[dim_i]
            
            # Is this the plot axis?
            is_axis = (dim_i == axis_idx)
            
            if dim_i == 1
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
                    if dim_i <= 1 + n_params 
                        p_idx = dim_i - 1
                        vals = pd.active_param_values[p_idx]
                    elseif dim_i == 1 + n_params + 1 # Space
                        if haskey(pd.data, "x"); vals = pd.data["x"]; end
                    elseif dim_i == 1 + n_params + 2 # Time
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
    attach_plot_controls!(target_layout::GridLayout, plot_data_dict)

Generates the dynamic plotting controls using `create_plot_controls!` and 
attaches them to the provided `target_layout`.
"""
function attach_plot_controls!(target_layout::GridLayout, plot_data_dict)
    # Clear any previous controls in this slot
    for c in reverse(contents(target_layout))
        delete!(c)
    end
    
    # Create a dummy figure just to use the existing function's logic?
    # No, create_plot_controls! takes a Figure to attach to fig[1,1] and fig[2,1].
    # We should refactor create_plot_controls! slightly to accept a Layout, 
    # OR we can just nest the layouts here.
    
    # Let's adapt create_plot_controls! slightly (see below) OR use this wrapper:
    
    # We create a sub-grid in the target
    menu_area = target_layout[1, 1] = GridLayout()
    slider_area = target_layout[2, 1] = GridLayout()
    
    # Call the logic (assuming we updated create_plot_controls! to take these grids 
    # instead of a Figure, or we overload it).
    return create_plot_controls!(menu_area, slider_area, plot_data_dict)
end

end