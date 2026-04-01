function smart_parse_csv_value(val_str::String)
    val_str = strip(val_str)
    
    # 1. Handle Keywords
    if val_str == "true"; return true; end
    if val_str == "false"; return false; end
    if val_str == "<empty>"; return ""; end
    
    # 2. Handle Numbers
    v_int = tryparse(Int, val_str)
    if !isnothing(v_int); return v_int; end
    v_float = tryparse(Float64, val_str)
    if !isnothing(v_float); return v_float; end
    
    # 3. Handle Julia Expressions (Symbols, Arrays, Tuples)
    # Since we stripped prefixes, everything starts with ':', '[', or '('
    if startswith(val_str, ":") || startswith(val_str, "[") || startswith(val_str, "(")
        try
            return eval(Meta.parse(val_str))
        catch e
            @warn "Failed to parse expression: $val_str"
        end
    end
    
    # 4. Fallback to clean string
    return replace(val_str, r"^\"|\"$" => "")
end

function parse_csv_to_dict(filepath::String)
    parsed = Dict{String, Dict{String, Dict{String, Any}}}()
    
    for row in CSV.Rows(filepath)
        cat, scope, param, val_str = String(row.Category), String(row.Scope), String(row.Parameter), String(row.Value)
        val = smart_parse_csv_value(val_str)
        
        if !haskey(parsed, cat); parsed[cat] = Dict{String, Dict{String, Any}}(); end
        if !haskey(parsed[cat], scope); parsed[cat][scope] = Dict{String, Any}(); end
        
        parsed[cat][scope][param] = val
    end
    
    return parsed
end
"""
    csv_to_simulation_config(parsed_csv::Dict, sim_func::Function)

Converts a parsed nested CSV dictionary into a properly formatted `SimulationConfig`.
Requires the simulation function to be passed manually since dynamic function 
loading is deferred.
"""
function csv_to_simulation_config(parsed_csv::Dict, sim_func::Function)
    # 1. Extract Shared Parameters
    shared_params = Dict{String, Any}()
    if haskey(parsed_csv, "Simulation") && haskey(parsed_csv["Simulation"], "shared")
        shared_params = parsed_csv["Simulation"]["shared"]
    end

    # 2. Extract Methods & their Specific Parameters
    methods_dict = Dict{String, Dict{String, Any}}()
    if haskey(parsed_csv, "Simulation")
        for (scope, params) in parsed_csv["Simulation"]
            if scope != "shared"
                methods_dict[scope] = params
            end
        end
    end

    # 3. Extract Varied Parameters from the new Config Category
    varied_params = Dict{String, Vector}()
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "Parameters")
        # Ensure the parsed arrays/ranges are correctly formatted
        for (k, v) in parsed_csv["Config"]["Parameters"]
            # If your CSV parser returns strings like "[0.0, 1.0, 2.0]", 
            # make sure it evals them: eval(Meta.parse(v))
            varied_params[k] = v
        end
    else
        @warn "No 'Config -> Parameters' found in CSV. Simulation will have no varied parameters."
    end

    # 4. Default Methods (All methods found in the CSV are active by default)
    default_methods = collect(keys(methods_dict))

    # Construct and return the SimulationConfig
    return SimulationConfig(
        sim_func,
        shared_params,
        methods_dict,
        default_methods,
        varied_params,
    )
end

const _SAVE_ROOT_PATH = Ref{String}(pwd())

"""
    resolve_simulation_function(parsed_dict::Dict, sim_func::Union{Function, Nothing})

If `sim_func` is a Function, it returns it immediately. 
If `sim_func` is `nothing`, it reads the function name from the parsed CSV dictionary, 
attempts to `include` the corresponding `.jl` file from the SimulationFunctions directory, 
and returns the evaluated function.
"""
function resolve_simulation_function(parsed_dict::Dict, sim_func::Union{Function, Nothing})
    if !isnothing(sim_func)
        return sim_func
    end

    try
        func_name_str = parsed_dict["Config"]["General"]["simulation_func"]
        func_file = joinpath(_SAVE_ROOT_PATH[], "SimulationFunctions", func_name_str * ".jl")
        
        if isfile(func_file)
            @info "Found simulation function file: $func_file"
            include(func_file)
        else
            @warn "Could not find $func_file. Assuming function '$func_name_str' is already loaded in current scope."
        end
        
        # Convert the string name back to a runnable Julia function
        return eval(Symbol(func_name_str))
    catch e
        @error "Failed to dynamically resolve simulation function from CSV metadata." exception=(e, catch_backtrace())
        return nothing
    end
end

function create_varied_param_overwrites_figure(varied_params::Dict, active_overwrites::Dict)
    n_params = length(varied_params)
    if n_params == 0
        @warn "No varied parameters found to configure."
        return nothing
    end

    fig_height = max(150, n_params * 50 + 80)
    fig = Figure(size = (550, fig_height))
    layout = fig[1, 1] = GridLayout()
    
    Label(layout[1, 1:4], "Overwrite Varied Parameters", font=:bold, fontsize=18)
    
    for (i, (p_name, p_vals)) in enumerate(varied_params)
        row = i + 1
        Label(layout[row, 1], p_name, halign=:right, width=120)
        
        # Determine the slider range
        rng = (p_vals isa AbstractArray && length(p_vals) > 1) ? p_vals : [0.0, 1.0]
        sl = Slider(layout[row, 2], range = rng, width = 200)
        
        tg = Toggle(layout[row, 3], active = haskey(active_overwrites, p_name))
        val_label = Label(layout[row, 4], lift(v -> string(round(v, sigdigits=4)), sl.value), width=60)
        
        onany(sl.value, tg.active) do val, is_active
            if is_active
                active_overwrites[p_name] = val
            else
                delete!(active_overwrites, p_name)
            end
        end
        
        if haskey(active_overwrites, p_name)
            set_close_to!(sl, active_overwrites[p_name])
        end
    end
    return fig
end

function launch_csv_interface(sim_func::Union{Function, Nothing} = nothing)
    GLMakie.activate!()
    
    fig = Figure(size = (500, 750))
    layout = fig[1, 1] = GridLayout(tellheight=false)
    rowgap!(layout, 15)
    current_row = 1
    
    # --- RAM STATE ---
    parsed_csv_ref = Ref{Dict{String, Dict{String, Dict{String, Any}}}}()
    active_varied_overwrites = Dict{String, Float64}()
    active_methods_obs = Observable{Vector{String}}(String[])
    csv_loaded = Observable{Bool}(false)
    run_parallel = Observable{Bool}(false)
    base_tbs = Vector{Textbox}(undef, 5)

    # --- 1. HEADER & DRAG/DROP ---
    Label(layout[current_row, 1], "Simulation CSV Launcher", fontsize=22, font=:bold, color=:royalblue)
    current_row += 1
    
    drop_layout = layout[current_row, 1] = GridLayout()
    drop_box = Box(drop_layout[1, 1], color=:lightgray, strokecolor=:gray, strokewidth=2, cornerradius=10, width=350, height=120)
    drop_label = Label(drop_layout[1, 1], "Drag & Drop CSV Here\nor type path below", halign=:center, valign=:center, color=RGBAf(0.3, 0.3, 0.3, 1.0))
    
    path_tb = Textbox(layout[current_row+1, 1], placeholder="Path to CSV...", width=350)
    current_row += 2
    
    on(events(fig.scene).dropped_files) do files
        if !isempty(files) && endswith(lowercase(files[1]), ".csv")
            path_tb.stored_string[] = files[1]
        end
    end
    
    on(path_tb.stored_string) do path
        if isfile(path) && endswith(lowercase(path), ".csv")
            try
                parsed_csv_ref[] = parse_csv_to_dict(path)
                
                # Pre-populate active methods automatically
                if haskey(parsed_csv_ref[], "Simulation")
                    methods = filter(k -> k != "shared", collect(keys(parsed_csv_ref[]["Simulation"])))
                    active_methods_obs[] = sort(methods)
                end
                
                drop_label.text[] = "Loaded:\n" * basename(path)
                drop_label.color[] = RGBAf(0.0, 0.5, 0.0, 1.0)
                drop_box.color[] = RGBAf(0.8, 1.0, 0.8, 1.0)
                csv_loaded[] = true
            catch e
                @error "Failed to parse CSV" exception=(e, catch_backtrace())
            end
        else
            drop_label.text[] = "File not found!"
            drop_label.color[] = RGBAf(0.8, 0.0, 0.0, 1.0)
            csv_loaded[] = false
        end
    end

    # --- 2. BASE PARAMETER OVERWRITES ---
    Label(layout[current_row, 1], "Base Parameter Overwrites", fontsize=16, font=:bold)
    current_row += 1
    
    base_layout = layout[current_row, 1] = GridLayout()
    base_names = ["Component (c)", "Space (X)", "Space (Y)", "Space (Z)", "Time (t)"]
    
    for i in 1:5
        Label(base_layout[i, 1], base_names[i], halign=:right)
        base_tbs[i] = Textbox(base_layout[i, 2], placeholder="val / 'default'", width=150)
        base_tbs[i].stored_string = "default"
        base_tbs[i].displayed_string = "default"
    end
    current_row += 1
    
    # --- 3. SUB-MENU CONFIGURATION ---
    Label(layout[current_row, 1], "Configuration", fontsize=16, font=:bold)
    current_row += 1
    
    config_layout = layout[current_row, 1] = GridLayout()
    btn_varied = Button(config_layout[1, 1], label="Varied Params Override", buttoncolor=:lightgray, width=180)
    btn_methods = Button(config_layout[1, 2], label="Select Methods", buttoncolor=:lightgray, width=150)
    current_row += 1
    
    on(csv_loaded) do loaded
        color = loaded ? RGBAf(0.8, 0.9, 1.0, 1.0) : :lightgray
        btn_varied.buttoncolor[] = color
        btn_methods.buttoncolor[] = color
    end
    
    on(btn_varied.clicks) do _
        !csv_loaded[] && return
        v_params = get(get(parsed_csv_ref[], "Config", Dict()), "Parameters", Dict())
        v_fig = create_varied_param_overwrites_figure(v_params, active_varied_overwrites)
        if !isnothing(v_fig); display(GLMakie.Screen(title="Varied Parameters"), v_fig); end
    end
    
    on(btn_methods.clicks) do _
        !csv_loaded[] && return
        all_methods = filter(k -> k != "shared", collect(keys(parsed_csv_ref[]["Simulation"])))
        m_fig, _ = create_method_checkboxes_figure(all_methods, active_methods_obs)
        if !isnothing(m_fig); display(GLMakie.Screen(title="Select Methods"), m_fig); end
    end

    # --- 4. LAUNCHER ---
    Label(layout[current_row, 1], "______________________________________", color=:gray)
    current_row += 1
    
    run_layout = layout[current_row, 1] = GridLayout()
    Label(run_layout[1, 1], "Run Parallel (`ensure_sim_data_exists`)", halign=:right)
    tg_parallel = Toggle(run_layout[1, 2], active=false)
    on(tg_parallel.active) do val; run_parallel[] = val; end
    current_row += 1
    
    btn_launch = Button(layout[current_row, 1], label="Start Simulation & Plotter", buttoncolor=:lightgray, height=50, width=300)
    on(csv_loaded) do loaded; btn_launch.buttoncolor[] = loaded ? RGBAf(0.5, 0.9, 0.5, 1.0) : :lightgray; end
    
    on(btn_launch.clicks) do _
    !csv_loaded[] && return
        parsed_dict = parsed_csv_ref[]
        
        # --- A. RESOLVE SIMULATION FUNCTION ---
        resolved_func = resolve_simulation_function(parsed_dict, sim_func)
        if isnothing(resolved_func)
            return # Stop launch if we couldn't resolve the function
        end

        # --- B. CONFIG GENERATION ---
        sim_config = csv_to_simulation_config(parsed_dict, resolved_func)
        
        for (p_name, p_val) in active_varied_overwrites
            sim_config.varied_params[p_name] = [p_val] 
        end
        sim_config.default_methods = active_methods_obs[]
        
        # --- C. RESOLVE OVERWRITES ---
        default_bases = [:menu, :slider, :slider, :slider, :slider]
        var_overwrite = Vector{Any}(undef, 5)
        base_keys = ["c", "x", "y", "z", "t"]
        
        active_plot_axes = String[]
        if haskey(parsed_dict, "Scene") && haskey(parsed_dict["Scene"], "Menu")
            for ax_key in ["X-Axis", "Y-Axis", "Z-Axis"]
                val = get(parsed_dict["Scene"]["Menu"], ax_key, "-")
                if val != "-" && val != "disabled"; push!(active_plot_axes, val); end
            end
        end
        
        for i in 1:5
            input_str = strip(base_tbs[i].stored_string[])
            if isempty(input_str) || lowercase(input_str) == "default"
                var_overwrite[i] = default_bases[i]
            else
                val = tryparse(Float64, input_str)
                if isnothing(val)
                    var_overwrite[i] = default_bases[i]
                elseif base_keys[i] in active_plot_axes
                    @warn "Cannot overwrite $(base_keys[i]) because it is a plotting axis. Using default."
                    var_overwrite[i] = default_bases[i]
                else
                    var_overwrite[i] = val
                end
            end
        end

        @info "Launching Plotter Pipeline..."
        
        # --- D. LAUNCH PLOTTER ---
        ui_overwrite = get(parsed_dict, "UI", Dict{String, Any}())
        scene_options = get(parsed_dict, "Scene", Dict{String, Any}())
        
        show_unified_fig(
            sim_config;
            ui_style = :default, 
            ui_overwrite = ui_overwrite,
            var_overwrite = var_overwrite,
            scene_options = scene_options,
            parallel = run_parallel[]
        )
    end

    display(GLMakie.Screen(title="CSV Launcher"), fig)
    return fig
end