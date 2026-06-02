function allMethodNames(config::SimulationConfig)
    return collect(keys(config.methods_dict))
end

function createObsDict(dict::Dict{String,Any})
    dict_obs = Dict{String,Observable}()
    for (key,val) = dict
        dict_obs[key] = Observable(val)
    end
    return dict_obs
end

function parseValue(s::String)
    try
        # Meta.parse turns a string into a Julia expression.
        # `eval` executes that expression.
        return eval(Meta.parse(s))
    catch e
        # If parsing fails, it's probably just a plain string.
        # We also strip quotes that CSV readers sometimes add.
        return s == "<empty>" ? "" : string(strip(s, '\"'))
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
    isempty(input_str) && return
    
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
            parsed = parseValue(input_str) 
            
            # THE FIX: Only check if the base structure (Tuple or Vector) matches!
            if (T <: Tuple && parsed isa Tuple) || (T <: Vector && parsed isa Vector)
                try
                    obs[] = parsed
                catch e
                    @warn "Failed to apply value. The parameter strictly expects $T, but you provided $(typeof(parsed)). If you want to change the length of this tuple dynamically, initialize it as Observable{Any}."
                end
            else
                @warn "Type mismatch for complex input. Expected a $(T <: Tuple ? "Tuple" : "Vector"), but got $(typeof(parsed))."
            end
        else
            # Fallback for any other types
            obs[] = parse(T, input_str)
        end
    catch e
        @warn "Invalid input: Could not parse '$input_str' as $T. The value remains: $current_val"
    end
end




"""
    generate_dynamic_title(x_key, y_key, dim_idx, manager, dim_names, sel_vals)

Constructs the plot title dynamically. It lists all fixed parameters and base variables,
marks the actively plotted dimension, and allows for a user-defined override via `manager.ui`.
"""
function generate_dynamic_title(
    dim_idx::Int, 
    dim_names::Vector{String}, 
    sel_vals
)
    # 2. Build the Default Dynamic Title
    title_parts = String[]
    
    for i in 1:length(dim_names)
        name = dim_names[i]
        
        if i == dim_idx
            # This is the axis we are currently plotting along (the colon ':' in the tensor slice)
            push!(title_parts, "$name = [Axis]")
        else
            val = sel_vals[i]
            # Format floats neatly to 3 decimal places to prevent title bloat
            val_str = val isa AbstractFloat ? @sprintf("%.3f", val) : string(val)
            push!(title_parts, "$name = $val_str")
        end
    end
    
    # Join all the parts together with a separator
    return join(title_parts, " | ")
end
function generate_reference_simdata(ref_func::Function, params::ParamDict)
    N = _REFERENCE_RESOLUTION[]
    
    # 1. Extract physical bounds directly from parameters (Strict requires)
    xmin = params["mins"]
    xmax = params["maxs"]
    tmax = params["tmax"]
    snapshots = params["snapshots"]
    
    # Optional parameters
    tmin = get(params, "tmin", 0.0)
    
    # Determine dimensionality based on the type of xmin
    D = length(xmin)
    
    # 2. Build the high-res spatial axes
    axes_list = ntuple(D) do d
        min_val = Float64(xmin[d])
        max_val = Float64(xmax[d])
        collect(range(min_val, max_val, length=N))
    end
    
    # 3. Build the time vector (snapshots + 1 ensures we include t=0)
    t_vec = tmax > tmin ? collect(range(tmin, tmax, length=snapshots+1)) : [Float64(tmin)]
    T = length(t_vec)
    
    # Evaluate one point to find the number of components (C)
    # --- THE FIX: Create an SVector cleanly using ntuple ---
    sample_pos = SVector{D, Float64}(ntuple(d -> axes_list[d][1], D))
    sample_val = ref_func(sample_pos, t_vec[1])
    C = length(sample_val)
    
    # 4. Allocate the dense tensor
    grid_shape = ntuple(d -> N, D)
    u_exact = zeros(Float64, C, grid_shape..., T)
    
    # 5. Evaluate the exact function on the fly
    Threads.@threads for t_idx in 1:T
        t = t_vec[t_idx]
        for idx in CartesianIndices(grid_shape)
            # --- THE FIX: Native, allocation-free SVector creation ---
            pos = SVector{D, Float64}(ntuple(d -> axes_list[d][idx[d]], D))
            exact_val = ref_func(pos, t)
            
            for c in 1:C
                u_exact[c, Tuple(idx)..., t_idx] = exact_val[c]
            end
        end
    end
    
# Create the lightweight ESimData that exists ONLY in RAM
    ram_data = ESimData{D}(params, axes_list, u_exact, t_vec, Dict(), Dict(), Dict(), Dict())
    
    # THE FIX: Calculate baseline stats instantly without touching the hard drive!
    IRunPDESims._calculate_stats!(Val(:series), ram_data, ram_data.x, ram_data.u, ref_func)
    
    return ram_data
end

# ==============================================================================
# 1. TASK & CONFIGURATION ANALYSIS
# ==============================================================================

function _recombine_tuples!(params::Dict)
    tuple_groups = Dict{String, Vector{Pair{Int, Any}}}()
    keys_to_remove = String[]
    
    for (k, v) in params
        if occursin("__", k)
            parts = split(k, "__")
            if length(parts) == 2
                base_name, idx_str = parts[1], parts[2]
                idx = tryparse(Int, idx_str)
                if !isnothing(idx)
                    if !haskey(tuple_groups, base_name)
                        tuple_groups[base_name] = Pair{Int, Any}[]
                    end
                    push!(tuple_groups[base_name], idx => v)
                    push!(keys_to_remove, k)
                end
            end
        end
    end
    
    for k in keys_to_remove
        delete!(params, k)
    end
    
    for (base_name, pairs) in tuple_groups
        sort!(pairs, by = x -> x[1])
        params[base_name] = Tuple(x[2] for x in pairs)
    end
    return params
end
"""
    apply_scene_options!(manager::PlotManager, scene_options::Dict)

Safely snaps UI widgets to the requested states natively through the MVC Dictionary structure.
"""
function apply_scene_options!(manager::PlotManager, scene_options::Dict)
    isempty(scene_options) && return

    # 1. Apply Structural & Axis Menus
    menu_keys = ["Plot_Type", "Compare_Target", "Compare_Columns", "Compare_Link", "Legend_Base", "Legend_Add", "Plot_Width", "Plot_Height", "Anim_Target", "c", "X-Axis", "Y-Axis", "Z-Axis", "U-Axis"]
    
    for k in menu_keys
        sel_key = "$(k)_Selection"
        if haskey(scene_options, sel_key) && haskey(manager.controls["Widget"], k)
            val = scene_options[sel_key]
            widget = manager.controls["Widget"][k][]
            opts = manager.controls["Options"][k][]
            isempty(opts) && continue
            
            valid_vals = (!isempty(opts) && opts[1] isa Tuple) ? [o[2] for o in opts] : opts
            idx = findfirst(v -> string(v) == string(val), valid_vals)
            if !isnothing(idx)
                widget.i_selected[] = idx
            end
        end
    end

    rev_map = haskey(manager.controls["State"], "Reverse_Map") ? manager.controls["State"]["Reverse_Map"][] : Dict{String, String}()
    
    for (key, desired_val) in scene_options
        if endswith(key, "_Value")
            base_name = replace(key, "_Value" => "")
            w_key = haskey(rev_map, base_name) ? rev_map[base_name] : base_name
            
            if haskey(manager.controls["Widget"], w_key)
                widget = manager.controls["Widget"][w_key][]
                if widget isa Makie.Slider
                    rng = manager.controls["Range"][w_key][]
                    isempty(rng) && continue
                    
                    val = Float64(rng[1])
                    if desired_val isa Real
                        val = clamp(Float64(desired_val), Float64(rng[1]), Float64(rng[end]))
                    end
                    set_close_to!(widget, val)
                end
            end
        end
    end
    @info "Dynamic Scene Options Successfully Applied."
end

function get_base_scene_options()
    return Dict{String, Any}(
        "X-Axis_Selection"          => "x",      
        "U-Axis_Selection"          => "u",      
        "Plot_Type_Selection"       => "Lines",  
        "c_Selection"               => 1,        
        "t_Value"                   => 0.0,      
        "x_Value"                   => 0.0,
        "Compare_Target_Selection"  => "None", 
        "Compare_Columns_Selection" => "2",     
        "Compare_Link_Selection"    => "Fully Coupled",
        "Legend_Base_Selection"     => "right",
        "Legend_Add_Selection"      => "detached",
        "Plot_Width_Selection"      => "600",
        "Plot_Height_Selection"     => "400",
    )
end

function extract_scene_options(manager::PlotManager)
    opts = Dict{String, Any}()
    
    # Matches the exact MVC keys defined in Controls.jl
    for k in ["X-Axis", "Y-Axis", "Z-Axis", "U-Axis", "Plot_Type", "c", "Compare_Target", 
              "Compare_Columns", "Compare_Link", "Legend_Base", "Legend_Add", "Plot_Width", "Plot_Height", "Anim_Target"]
        if haskey(manager.controls["Selection"], k)
            opts["$(k)_Selection"] = to_value(manager.controls["Selection"][k])
        end
    end
    
    # --- THE FIX: Map physical names back to widget aliases for extraction ---
    rev_map = haskey(manager.controls["State"], "Reverse_Map") ? manager.controls["State"]["Reverse_Map"][] : Dict{String, String}()
    for k in manager.plot_vars
        w_key = haskey(rev_map, k) ? rev_map[k] : k
        if haskey(manager.controls["Value"], w_key)
            opts["$(k)_Value"] = to_value(manager.controls["Value"][w_key])
        end
    end
    
    return opts
end
"""
    csv_to_simulation_config(parsed_csv::Dict, sim_func::Function)

Converts a parsed nested CSV dictionary into a properly formatted `SimulationConfig`.
"""
function csv_to_simulation_config(parsed_csv::Dict, sim_func::Function)
    # 1. Extract Shared Parameters
    shared_params = Dict{String, Any}()
    if haskey(parsed_csv, "Simulation") && haskey(parsed_csv["Simulation"], "shared")
        shared_params = parsed_csv["Simulation"]["shared"]
    end

    # 2. Extract Methods (No longer hijacks "analytical" methods!)
    methods_dict = Dict{String, Dict{String, Any}}()
    if haskey(parsed_csv, "Simulation")
        for (scope, params) in parsed_csv["Simulation"]
            if scope != "shared"
                methods_dict[scope] = params
            end
        end
    end

    # 3. Extract Varied Parameters from the Config Category
    varied_params = Dict{String, Vector}()
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "Parameters")
        for (k, v) in parsed_csv["Config"]["Parameters"]
            varied_params[k] = v
        end
    else
        @warn "No 'Config -> Parameters' found in CSV. Simulation will have no varied parameters."
    end

    # 4. Default Methods
    default_methods = collect(keys(methods_dict))

    # 5. Extract Reference Name explicitly from Config
    ref_name = nothing
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "General")
        csv_ref = get(parsed_csv["Config"]["General"], "reference_func", "none")
        if csv_ref != "none" && !isempty(csv_ref)
            ref_name = csv_ref
        end
    end

    # 6. Resolve the Analytical Solution Factory
    ref_func = nothing
    if !isnothing(ref_name)
        # Convert the UI string back to a safe function name
        safe_ref_name = lowercase(replace(strip(ref_name), r"[\s-]+" => "_"))
        
        ref_factory = try
            resolve_reference_function(safe_ref_name)
        catch
            nothing
        end
        
        # Instantiate the exact mathematical closure using the loaded shared parameters
        if !isnothing(ref_factory)
            ref_func = Base.invokelatest(ref_factory, shared_params)
            
            # --- THE FIX: Auto-Inject the Reference Method! ---
            # Because reference methods often have empty parameter dicts, they don't 
            # get saved as rows in the CSV. We must explicitly rebuild their presence here.
            ns = nice_string(safe_ref_name)
            if !haskey(methods_dict, ns)
                methods_dict[ns] = ParamDict()
            end
            if !(ns in default_methods)
                push!(default_methods, ns)
            end
            
        else
            @warn "Failed to resolve reference function: $safe_ref_name"
        end
    end

    # 7. Construct and return the SimulationConfig
    sim_name_str = parsed_csv["Config"]["General"]["simulation_func"]
    
    return SimulationConfig(
        sim_func,
        sim_name_str, # THE FIX
        ref_func,
        ref_name,
        shared_params,
        methods_dict,
        default_methods,
        varied_params
    )
end
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
    load_and_apply_csv!(manager::PlotManager, filepath::String)

Unified pipeline for loading a CSV config, executing the simulations, 
and syncing the results back to the PlotManager UI and Scene options.
"""
function load_and_apply_csv!(manager::PlotManager, filepath::String)
    @info "Loading configuration from CSV: $filepath"
    
    parsed = parse_csv_to_dict(filepath)
    sim_func_str = parsed["Config"]["General"]["simulation_func"]
    
    resolved_func = resolve_simulation_function(sim_func_str, nothing)
    if isnothing(resolved_func)
        @error "Aborting: Could not resolve simulation function '$sim_func_str'"
        return
    end
    
    new_config = csv_to_simulation_config(parsed, resolved_func)
    
    # 1. Check Structural Compatibility
    new_vars = [collect(keys(new_config.varied_params)); BaseVariables]
    if manager.plot_vars != new_vars
        @warn "CSV contains different spatial/varied parameters. Please restart plotter to rebuild UI."
        return
    end

    # 2. Execute Simulations
    @info "CSV Loaded: Running all defined simulations for exact recreation..."
    runAllSimulations(new_config; calculate_stats=true, convert_eulerian=true)
    
    # 3. Load Options FIRST so they are ready in Global State
    if haskey(parsed, "UI")
        for (scope, keys_dict) in parsed["UI"]
            if haskey(manager.ui, scope)
                for (k, v) in keys_dict
                    if haskey(manager.ui[scope], k)
                        manager.ui[scope][k][] = v
                    end
                end
            end
        end
    end
    
    if haskey(parsed, "Scene") && haskey(parsed["Scene"], "General")
        scene_opts = get_base_scene_options()
        for (k, v) in parsed["Scene"]["General"]
            scene_opts[k] = v
        end
        GLOBAL_SCENE_OPTIONS[] = scene_opts
    end

    # 4. Update Global Brain LAST (Triggers the render cascade)
    ACTIVE_SIM_CONFIG[] = new_config
    
    # 5. Trigger UI Update
    manager.controls["State"]["Simulation_Update"][] += 1
    @info "Successfully applied CSV config to UI!"
end

"""
    _value_to_string_for_csv(v)

A robust helper to convert a Julia object to a string for CSV saving.
Explicitly strips type prefixes (like 'Any' or 'Vector{Float64}') from 
containers to ensure they are saved as clean, parsable Julia expressions.
"""
function _value_to_string_for_csv(v)
    # 1. Handle Symbols (Prepend colon so they parse back as Symbols)
    if isa(v, Symbol)
        return ":" * string(v)
    end

    # 2. Handle empty strings
    if v == ""
        return "<empty>"
    end

    # 3. Handle Arrays/Vectors (Strip type prefix: Any[...] -> [...])
    if isa(v, AbstractArray)
        s = string(v)
        # Replaces any alphanumeric + curly brace prefix before the first '['
        return replace(s, r"^[a-zA-Z0-9_{}, ]*\[" => "[")
    end
    
    # 4. Handle Tuples (Strip type prefix: NamedTuple(...) -> (...))
    if isa(v, Tuple)
        s = string(v)
        return replace(s, r"^[a-zA-Z0-9_{}, ]*\(" => "(")
    end

    # 5. Fallback for Numbers and basic Strings
    return string(v)
end

function get_all_git_infos(start_path::String = ".")
    git_infos = Dict{String, Dict{String, Any}}()
    
    for (root, dirs, files) in walkdir(abspath(start_path))
        if ".git" in dirs
            try
                repo = LibGit2.GitRepo(root)
                commit = LibGit2.peel(LibGit2.GitCommit, LibGit2.head(repo))
                
                repo_name = basename(root)
                git_infos[repo_name] = Dict{String, Any}(
                    "git_commit_hash" => string(LibGit2.GitHash(commit)),
                    "git_commit_summary" => LibGit2.summary(commit),
                    "git_commit_count" => try parse(Int, readchomp(`git -C $root rev-list --count HEAD`)) catch; -1 end
                )
            catch e
                # Ignore invalid or empty repositories silently
            end
        end
        
        # Prune the walk algorithm to prevent freezing!
        filter!(d -> !(d in [".git", "build", "node_modules", ".vscode", "docs"]), dirs)
    end
    
    return git_infos
end

function get_julia_info(git_repo_names::Vector{String})
    info = Dict{String, Dict{String, Any}}()
    info["System"] = Dict{String, Any}("Julia_Version" => string(VERSION))
    
    deps = Pkg.dependencies()
    
    # 1. Main Project Direct Dependencies
    top_deps = Dict{String, Any}()
    for (uuid, pkg) in deps
        if pkg.is_direct_dep
            top_deps[pkg.name] = string(pkg.version)
        end
    end
    info["Main_Project"] = top_deps
    
    # 2. Local Sub-Packages (Match git repo names)
    for (uuid, pkg) in deps
        if pkg.name in git_repo_names
            sub_deps = Dict{String, Any}()
            for (dep_name, dep_uuid) in pkg.dependencies
                if haskey(deps, dep_uuid)
                    sub_deps[dep_name] = string(deps[dep_uuid].version)
                end
            end
            if !isempty(sub_deps)
                info[pkg.name] = sub_deps
            end
        end
    end
    return info
end


function saveParametersToCSV(
    base_filename::String,
    save_dir::String,
    manager::PlotManager,
    metadata_general::Dict
)::Bool
    csv_filename = joinpath(save_dir, base_filename * ".csv")
    
    try
        cats, scopes, params, vals = String[], String[], String[], String[]

        function add_row(cat, scope, p, v)
            push!(cats, string(cat))
            push!(scopes, string(scope))
            push!(params, string(p))
            push!(vals, _value_to_string_for_csv(to_value(v)))
        end

        # --- 1. CATEGORY: Metadata ---
        for (k, v) in metadata_general; add_row("Metadata", "General", k, v); end
        
        # --- NEW CATEGORY: Git (Scope = Repo Name) ---
        git_infos = get_all_git_infos(pwd())
        for (repo_name, info) in git_infos
            for (k, v) in info; add_row("Git", repo_name, k, v); end
        end

        # --- NEW CATEGORY: Julia (Scope = Main Project or Local Sub-Package) ---
        repo_names = collect(keys(git_infos))
        julia_infos = get_julia_info(repo_names)
        for (scope, info) in julia_infos
            for (k, v) in info; add_row("Julia", scope, k, v); end
        end

        # --- 2. CATEGORY: Scene (THE FIX) ---
        # Safely uses your existing extraction function instead of digging through nested controls
        scene_opts = extract_scene_options(manager)
        for (k, v) in scene_opts
            add_row("Scene", "General", k, v)
        end

        # --- 3. CATEGORY: Simulation ---
        for (k, v) in manager.simulation["shared"]
            add_row("Simulation", "shared", k, v)
        end
        for m_name in manager.methods[]
            if haskey(manager.simulation, m_name)
                for (k, v) in manager.simulation[m_name]
                    add_row("Simulation", m_name, k, v)
                end
            end
        end

        # --- 4. CATEGORY: UI ---
        for (scope, dict) in manager.ui
            for (k, v) in dict; add_row("UI", scope, k, v); end
        end

        # --- 5. CATEGORY: Config ---
        for (scope, dict) in manager.config
            for (k, v) in dict; add_row("Config", scope, k, v); end
        end

        CSV.write(csv_filename, DataFrame(Category=cats, Scope=scopes, Parameter=params, Value=vals))
        @info "Metadata and Parameters saved to $csv_filename"
        return true
    catch e
        @error "CSV Save Failed" exception=(e, catch_backtrace())
        return false
    end
end