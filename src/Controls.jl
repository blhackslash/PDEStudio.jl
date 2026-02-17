module Controls

export PlotManager, create_plot_manager, create_controls

using GLMakie
using CairoMakie
using Printf
using Statistics
using LibGit2
using CSV, DataFrames
using Dates
using ..Structs
using ..Utils

# Type Alias for Scope -> Key -> Observable
const NestedObsDict = Dict{String, Dict{String, Observable}}

mutable struct PlotManager
    simulation::NestedObsDict
    ui::NestedObsDict
    scene::NestedObsDict
    methods::Observable{Vector{String}}  # NEW: Tracks active checkboxes
    last_run_params::Dict{String, Any}

    function PlotManager(sim, ui, scene, methods, last_run)
        new(sim, ui, scene, methods, last_run)
    end
end

function create_plot_manager(sim_config::SimulationConfig, ui_raw::Dict, scene_raw::Dict)
    # --- 1. Simulation Field ---
    sim_obs = NestedObsDict()
    # Add Shared
    sim_obs["shared"] = Dict(k => Observable(v) for (k, v) in sim_config.shared_params)
    # Add Methods
    for (m_name, m_params) in sim_config.methods_dict
        sim_obs[m_name] = Dict(k => Observable(v) for (k, v) in m_params)
    end

    # --- 2. UI Field ---
    ui_obs = NestedObsDict()
    for (scope, keys_dict) in ui_raw
        ui_obs[scope] = Dict(k => Observable(v) for (k, v) in keys_dict)
    end

    # 3. Initialize Active Methods from sim_config defaults
    methods_obs = Observable(copy(sim_config.default_methods))

    # --- 4. Scene Field ---
    scene_obs = NestedObsDict()
    # Scene usually has one scope, e.g., "Current"
    scene_obs["Current"] = Dict(k => Observable(v) for (k, v) in scene_raw)

    return PlotManager(sim_obs, ui_obs, scene_obs, methods_obs, copy(sim_config.shared_params))
end

include("ControlUtils.jl")

"""
    create_controls(plot_fig, manager::PlotManager)

Creates the unified interactive control window using the PlotManager hierarchy.
This window manages:
1. Re-simulation (Refresh Button).
2. Method comparison (Checkboxes).
3. Parameter/UI editing (Hierarchical Menus + Smart Textbox).
4. Save/Export controls.
5. A slot for dynamic plot-specific controls (Sliders/Axis Menus).

Returns:
- `base_controls_fig`: The Makie Figure for the controls.
- `update_notifier`: Observable triggered by the "Refresh" button.
- `methods_obs`: Observable tracking which simulation methods are active.
- `plot_controls_slot`: The GridLayout to be populated by `attach_plot_controls!`.
"""
function create_controls(plot_fig::Makie.Figure, manager::PlotManager)
    GLMakie.activate!()

    # --- Windows Setup ---
    # We maintain references to the screens to allow the Refresh button 
    # to bring the plot window to the foreground.
    plot_screen = GLMakie.Screen(title = "Makie Plot")
    
    # Main Control Figure
    base_controls_fig = Figure(size = (350, 850)) 
    fig_layout = base_controls_fig.layout[1,1] = GridLayout(tellheight=false)
    rowgap!(fig_layout, 15) 

    current_row = 1

    # ==============================================================================
    # 1. HEADER & REFRESH (Force Re-simulation)
    # ==============================================================================
    header_layout = fig_layout[current_row, 1] = GridLayout()
    Label(header_layout[1,1], "Simulation Controls", fontsize=20, font=:bold, halign=:center)
    current_row += 1
    
    update_layout = fig_layout[current_row, 1] = GridLayout()
    update_button = Button(update_layout[1,1], label="Refresh / Run Simulation", 
                           halign=:center, width=250, buttoncolor=:lightblue)
    
    # Trigger for re-calculating the UnifiedPlotData
    update_notifier = Observable(0)
    on(update_button.clicks) do _
        update_notifier[] += 1
        if !GLMakie.isopen(plot_screen)
            display(plot_fig)
        end
    end
    current_row += 1

    # ==============================================================================
    # 2. METHOD SELECTION (Add/Remove Methods from Comparison)
    # ==============================================================================
    Label(fig_layout[current_row, 1], "Active Comparison Methods:", fontsize=16, font=:bold, halign=:center)
    current_row += 1
    
    method_checkbox_layout = fig_layout[current_row, 1] = GridLayout()
    # Initialize with all methods active. This observable controls soft updates.
    all_methods = filter(k -> k != "shared", collect(keys(manager.simulation)))
    methods_obs = Observable(all_methods)
    
    createMethodCheckboxes!(method_checkbox_layout, methods_obs, manager) 
    current_row += 1

    # ==============================================================================
    # 3. HIERARCHICAL PARAMETER NAVIGATOR
    # ==============================================================================
    Label(fig_layout[current_row, 1], "Parameter & UI Editor:", fontsize=16, font=:bold, halign=:center, color=:royalblue)
    current_row += 1
    
    param_nav_layout = fig_layout[current_row, 1] = GridLayout()
    create_hierarchical_param_controls!(param_nav_layout, manager)
    current_row += 1

    # ==============================================================================
    # 4. SAVE CONTROLS
    # ==============================================================================
    Label(fig_layout[current_row, 1], "Export Options:", fontsize=16, font=:bold, halign=:center)
    current_row += 1
    
    save_box_layout = fig_layout[current_row, 1] = GridLayout()
    # We pass the flattened versions of the manager data for the old save logic
    # or adapt createSaveFigBox to accept the PlotManager directly.
    createSaveFigBox(save_box_layout, plot_fig, manager)
    current_row += 1

    # ==============================================================================
    # 5. DYNAMIC PLOT CONTROLS SLOT
    # ==============================================================================
    # Visual Separator
    Label(fig_layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
    
    Label(fig_layout[current_row, 1], "Data Exploration (Axes & Sliders)", 
          fontsize=16, font=:bold, halign=:center, color=:darkgreen)
    current_row += 1
    
    # This slot is returned to the main show function, which will populate it
    # by calling attach_plot_controls! every time the data structure changes.
    plot_controls_slot = fig_layout[current_row, 1] = GridLayout()
    
    # Display the final control suite
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

"""
    create_hierarchical_param_controls!(layout, manager::PlotManager)

Creates a 3-menu + 1-textbox interface to navigate and edit all parameters.
"""
function create_hierarchical_param_controls!(layout::GridLayout, mgr::PlotManager)
    # 1. Menus
    # Categories are fixed strings matching the field names (capitalized for UI)
    cat_mapping = Dict("Simulation" => :simulation, "UI" => :ui, "Scene" => :scene)
    menu_cat = Menu(layout[1, 1], options = sort(collect(keys(cat_mapping))), prompt = "Category...")
    
    menu_scope = Menu(layout[1, 2], options = ["-"], prompt = "Scope...")
    menu_key = Menu(layout[1, 3], options = ["-"], prompt = "Key...")
    
    active_target_obs = Observable{Any}(nothing)

    # 2. Category -> Scope (Accessing fields directly)
    on(menu_cat.selection) do cat
        isnothing(cat) && return
        # Access mgr.simulation, mgr.ui, or mgr.scene
        field_data = getproperty(mgr, cat_mapping[cat])
        menu_scope.options[] = sort(collect(keys(field_data)))
        menu_scope.selection[] = nothing
    end

    # 3. Scope -> Key
    on(menu_scope.selection) do scope
        isnothing(scope) && return
        cat = menu_cat.selection[]
        field_data = getproperty(mgr, cat_mapping[cat])
        
        menu_key.options[] = sort(collect(keys(field_data[scope])))
        menu_key.selection[] = nothing
    end

    # 4. Textbox with Live Placeholder
    Label(layout[2, 1], "Edit Value:", halign=:right)
    
    # Show what is currently loaded in the plot
    placeholder_text = lift(menu_key.selection) do k
        isnothing(k) && return "Select key..."
        val = get(mgr.last_run_params, k, "default")
        return "Loaded: $val"
    end

    tb = Textbox(layout[2, 2:3], placeholder = placeholder_text, reset_on_defocus = true)

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
    end
end

function createMethodCheckboxes!(layout, methods_obs::Observable, mgr::PlotManager)
    # Get all scopes in simulation except 'shared'
    all_method_names = filter(k -> k != "shared", collect(keys(mgr.simulation)))
    sort!(all_method_names)
    
    # Call your existing checkbox creation logic
    # (assuming createMethodCheckboxes is the function from your PlottingUtils.jl)
    createMethodCheckboxes(layout, methods_obs, all_method_names)
end

function createSaveFigBox(
    target_layout,
    plot_fig::Makie.Figure,
    manager::PlotManager;
    context_info = Dict{String, Any}()
)
    gb = target_layout[1, 1:2] = GridLayout()
    Label(gb[1, 1], "Save Image+CSV:", halign=:right).padding=(0,5,0,0)
    saveBox = Textbox(gb[1, 2], placeholder = "Type name (no ext)", width=200)

    get_save_dir() = joinpath(Utils.get_save_path(), "figures")

    on(saveBox.stored_string) do s
        base_name = string(strip(s))
        if isempty(base_name); return; end

        # Access UI options via the nested "Various" scope
        ui_various = manager.ui["Various"]
        save_figures_path = get_save_dir()
        
        if ui_various["create_savefolder"][]; save_figures_path = joinpath(save_figures_path, base_name) end
        mkpath(save_figures_path)

        formats = ui_various["save_formats"][]
        
        for format in formats
            fmt = lowercase(strip(format))
            full_filename = joinpath(save_figures_path, base_name * ".$fmt")

            try
                if fmt in ["pdf", "svg"]
                    # Use CairoMakie for vector export
                    # Note: You must have 'using CairoMakie' in your scope
                    CairoMakie.activate!()
                    CairoMakie.save(full_filename, plot_fig)
                else
                    GLMakie.save(full_filename, plot_fig)
                end
                @info "Saved: $full_filename"
            catch e
                @error "Save failed for $fmt" exception=(e, catch_backtrace())
            finally
                GLMakie.activate!()
            end
        end

        # Metadata gathering
        context_info["Save Type"] = "Static Frame"
        context_info["Timestamp"] = string(Dates.now())
        
        git_info = Utils.get_git_info(Utils.get_save_path())
        if !isnothing(git_info); merge!(context_info, git_info) end

        # Call parameter saver
        saveParametersToCSV(base_name, save_figures_path, manager, context_info)
    end
end

function saveParametersToCSV(
    base_filename::String,
    save_dir::String,
    manager::PlotManager,
    optional_info::Dict
)::Bool
    csv_filename = joinpath(save_dir, base_filename * "_params.csv")
    
    sections = String[]
    method_names = Union{String, Missing}[]
    parameters = String[]
    values = String[]

    function add_row(sec, meth, param, val)
        push!(sections, sec); push!(method_names, meth)
        push!(parameters, string(param))
        # _value_to_string_for_csv should handle conversion of colors/symbols
        push!(values, Utils._value_to_string_for_csv(to_value(val)))
    end

    # 1. Context Info
    for k in sort(collect(keys(optional_info)))
        add_row("Context", missing, k, optional_info[k])
    end

    # 2. Simulation - Shared
    for k in sort(collect(keys(manager.simulation["shared"])))
        add_row("Shared", missing, k, manager.simulation["shared"][k])
    end

    # 3. Simulation - Active Methods
    # We only save the parameters for methods that are currently checked (active)
    for m_name in sort(manager.methods[])
        if haskey(manager.simulation, m_name)
            for k in sort(collect(keys(manager.simulation[m_name])))
                add_row("Method", m_name, k, manager.simulation[m_name][k])
            end
        end
    end

    # 4. UI Options (Iterate through Scopes: Axis, Appearance, etc.)
    for (scope, dict) in manager.ui
        for k in sort(collect(keys(dict)))
            # We prefix the parameter with the scope for clarity in the CSV
            add_row("UI", missing, "$scope:$k", dict[k])
        end
    end

    # 5. Scene State
    for k in sort(collect(keys(manager.scene["Current"])))
        add_row("Scene", missing, k, manager.scene["Current"][k])
    end

    try
        df = DataFrame(Section=sections, MethodName=method_names, Parameter=parameters, Value=values)
        CSV.write(csv_filename, df)
        @info "Parameters saved to $csv_filename"
        return true
    catch e
        @error "CSV write failed" exception=(e, catch_backtrace())
        return false
    end
end



function createMethodCheckboxes(cb_layout::GridLayout, methods_obs::Observable{Vector{String}}, methods::Vector{String}; n = 20)
    
    toLayout = cb_layout[end,1:div(length(methods),n)+1] = GridLayout() # n hard coded atm can be added to ui_dict

    for (i,method) = enumerate(methods)
        j = div(i-1,n) + 1
        Label(toLayout[mod1(i,n),j*2-1], method)
        init_methods = methods_obs[]
        if method in init_methods
            tmp = Checkbox(toLayout[mod1(i,n),j*2], checked = true)
        else
            tmp = Checkbox(toLayout[mod1(i,n),j*2], checked = false)
        end
        on(tmp.checked) do checked 
            if to_value(checked) & !(methods[i] in methods_obs[])
                push!(methods_obs[], methods[i])
            elseif !to_value(checked) & (methods[i] in methods_obs[])
                deleteat!(methods_obs[],findfirst(isequal(methods[i]),to_value(methods_obs)))
            end
            notify(methods_obs)
        end
    end
end


"""
    smart_parse_and_update!(obs::Observable, input_str::String)

Attempts to parse `input_str` into the same type as the current value of `obs`.
If parsing fails or types are incompatible, it prints a warning and leaves the 
observable unchanged.
"""
function smart_parse_and_update!(obs::Observable, input_str::String)
    # Ignore empty inputs (usually handled by the placeholder logic)
    (isempty(input_str) || input_str == "default") && return
    
    current_val = to_value(obs)
    T = typeof(current_val)

    try
        if T == String
            obs[] = input_str
        elseif T == Symbol
            obs[] = Symbol(input_str)
        elseif T == Bool
            # Handle true/false, 1/0, yes/no
            s = lowercase(strip(input_str))
            obs[] = (s == "true" || s == "1" || s == "yes")
        elseif T <: Int
            obs[] = parse(Int, input_str)
        elseif T <: AbstractFloat
            obs[] = parse(Float64, input_str)
        elseif T <: Tuple || T <: Vector
            # For complex types, we use the general parser but check the result type
            parsed = parseValue(input_str) 
            if typeof(parsed) == T
                obs[] = parsed
            else
                @warn "Type mismatch for complex input. Expected $T, but got $(typeof(parsed))."
            end
        else
            # Fallback for any other types
            obs[] = parse(T, input_str)
        end
    catch e
        @warn "Invalid input: Could not parse '$input_str' as $T. The value remains: $current_val"
    end
end



end