using GLMakie
using Test
path = "../src/"
# Include your modules (adjust paths if necessary)
include(path * "Structs.jl")
include(path * "Utils.jl")
include(path * "DataProcessing.jl")

using .Structs
using .Utils
using .DataProcessing

"""
    create_plot_controls!(fig, plot_data_dict::Dict{String, UnifiedPlotData})

Creates a control panel with:
1. X/Y/Axis Selection Menus.
2. Permanent Sliders/Menus for [Component, P1..., Space, Time].

Instead of hiding controls, it "disables" the control for the active plot axis 
by setting its range to `[0]` (or options to `["-"]`) and updating the label.
"""
function create_plot_controls!(fig::Figure, plot_data_dict::Dict{String, UnifiedPlotData{S}}) where S
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

    # --- 2. Create Layout & Return Observables ---
    menu_layout = fig[1, 1] = GridLayout()
    slider_layout = fig[2, 1] = GridLayout()
    
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
    menu_y = Menu(menu_layout[1,4], options = String["TMP"])
    
    Label(menu_layout[1,5], "Plot Along:")
    menu_axis = Menu(menu_layout[1,6], options = String["TMP"])

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

# ==============================================================================
# 1. SETUP DUMMY DATA
# ==============================================================================
println("--- Generating Dummy UnifiedPlotData ---")

# Dimensions: [Component, Param1, Space, Time]
# Sizes:      [1,         3,      10,    5]

n_c = 1
n_p1 = 3
n_x = 10
n_t = 5

# Create Tensors
# 1. Field 'u' (Full 4D)
u_tensor = rand(n_c, n_p1, n_x, n_t)

# 2. Time Series 'u_max' (Space = 1)
# Shape: [C, P1, 1, T]
u_max_tensor = rand(n_c, n_p1, 1, n_t)

# 3. Spatial Grid 'x' (Time = 5, Space = 10)
# Shape: [1, P1, X, T] (C=1)
x_tensor = zeros(1, n_p1, n_x, n_t)
# Fill x: just linear 1..10
for p in 1:n_p1, t in 1:n_t
    x_tensor[1, p, :, t] = 1:n_x
end

data_store = Dict(
    "u" => u_tensor,
    "u_max" => u_max_tensor,
    "x" => x_tensor
)

# Create Object
dummy_pd = UnifiedPlotData{4}(
    data_store,
    ["amplitude"],       # active_param_keys
    [[1.0, 5.0, 10.0]],  # active_param_values
    collect(0.1:0.1:0.5),# t_vals
    Dict{String,Any}()   # fixed_params
)

plot_data_dict = Dict("Test_Method" => dummy_pd)

# ==============================================================================
# 2. CREATE FIGURE & CONTROLS
# ==============================================================================
println("--- Creating Plot Controls ---")

fig = Figure(size = (800, 300))

# Call your function
# Returns: x_key_obs, y_key_obs, plot_dim_idx_obs, selector_values
x_obs, y_obs, dim_obs, selectors = create_plot_controls!(fig, plot_data_dict)

# ==============================================================================
# 3. ATTACH LISTENERS (THE "PRINT" TEST)
# ==============================================================================

on(x_obs) do val
    println("[EVENT] X-Axis Selection: '$val'")
end

on(y_obs) do val
    println("[EVENT] Y-Axis Selection: '$val'")
end

on(dim_obs) do idx
    # Map index back to name for clarity
    # 1=Comp, 2=Amp, 3=Space, 4=Time
    names = Dict(1=>"Comp", 2=>"Amplitude", 3=>"Space", 4=>"Time")
    name = get(names, idx, "Unknown($idx)")
    println("[EVENT] Plot Axis Changed to: $name (Index $idx)")
end

# Listeners for Sliders/Menus values
param_names = ["Component", "Amplitude", "Space", "Time"]
for (i, obs) in enumerate(selectors)
    on(obs) do val
        println("   -> Selector '$(param_names[i])' updated to: $val")
    end
end

# ==============================================================================
# 4. RUN AUTOMATED SIMULATION
# ==============================================================================
display(GLMakie.Screen(), fig)
println("\n--- Starting Automated Interaction Test ---\n")

menus = [c for c in fig.content if c isa Menu]

if length(menus) < 3
    @warn "Could not find all menus automatically. Please interact manually."
else
    menu_x = menus[1]
    menu_y = menus[2]
    menu_axis = menus[3]

    # TEST SCENARIO 1: Plot Field vs Space
    println("1. Selecting X = 'x' (Grid)...")
    menu_x.selection[] = "x"
    sleep(0.2)

    println("\n2. Selecting Y = 'u' (Field)...")
    menu_y.selection[] = "u"
    sleep(0.2) 
    # Logic should populate Axis menu with Space(3) and Time(4)

    println("\n3. Selecting Plot Axis = Space (Index 3)...")
    # We find the option corresponding to Space (usually index 3 in our list)
    # The menu stores options as ("Label", Value)
    space_opt = first(filter(opt -> opt[2] == 3, menu_axis.options[]))
    menu_axis.selection[] = space_opt[2] 
    sleep(0.5)

    # TEST SCENARIO 2: Plot Time Series
    println("\n4. Selecting Y = 'u_max' (Time Series)...")
    menu_y.selection[] = "u_max" 
    sleep(0.2)
    # Intersection of 'x' (Space,Time) and 'u_max' (Time) is only Time(4).
    # Logic should auto-select Time.
    
    # Check if logic auto-selected Time (Index 4)
    if dim_obs[] == 4
        println("   [SUCCESS] System auto-selected Time axis!")
    else
        println("   [FAIL] System did not auto-select Time. Current: $(dim_obs[])")
    end

    # TEST SCENARIO 3: Change Slider
    println("\n5. Changing Amplitude Slider...")
    # Find slider layout at fig[2,1]
    slider_layout = fig.content[2]
    # Amplitude is index 2.
    # We need to find the specific slider. 
    # Note: create_plot_controls! creates them in order.
    # Let's just update the observable directly to simulate a drag.
    selectors[2][] = 5.0 # Set Amplitude to 5.0
    sleep(0.2)
    
end

println("\n--- Test Complete. Window remains open for manual testing. ---")