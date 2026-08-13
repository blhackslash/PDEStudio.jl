function _apply_backend_keys(d::Dict)
    new_d = Dict{Symbol, Any}()
    for (k, v) in d
        clean_k = backend_key(string(k))
        if v isa Dict
            new_d[clean_k] = _apply_backend_keys(v)
        else
            new_d[clean_k] = v
        end
    end
    return new_d
end

function load_and_apply_csv!(filepath::String)
    @info "Loading configuration from CSV: $filepath"
    parsed = parse_csv_to_dict(filepath)
    
    is_structural_change = false
    new_dims = manager.allowed_dims
    new_max = manager.max_params
    
    if haskey(parsed, "Config") && haskey(parsed["Config"], "Dimensions")
        dims = parsed["Config"]["Dimensions"]
        if haskey(dims, "allowed_dims")
            new_dims = dims["allowed_dims"]
        end
        if haskey(dims, "max_params")
            new_max = Int(dims["max_params"])
        end
        
        if new_dims != manager.allowed_dims || new_max != manager.max_params
            is_structural_change = true
        end
    end
    
    if is_structural_change
        # THE FIX: Stage the parsed dict AND the new limits so the button knows exactly what to do!
        manager.state[:CSV_Cache] = (new_dims, new_max, parsed)
        @info "Structural limits changed! Configuration staged."
    else
        load_and_apply_csv!(parsed)
    end
    
    return is_structural_change
end

function load_and_apply_csv!(parsed::Dict)
    @info "Applying parsed CSV configuration..."
    
    # --- 1. FULL PROJECT DATA ---
    if haskey(parsed, "Config")
        cfg = parsed["Config"]
        
        # Load Dimensions (Acts as a failsafe if triggered directly)
        if haskey(cfg, "Dimensions")
            dims = cfg["Dimensions"]
            if haskey(dims, "allowed_dims")
                raw_dims = dims["allowed_dims"]
                if raw_dims isa Tuple
                    manager.allowed_dims = Tuple(Symbol.(raw_dims))
                elseif raw_dims isa Vector
                    manager.allowed_dims = Tuple(Symbol.(raw_dims))
                elseif raw_dims isa AbstractString
                    clean_str = replace(raw_dims, r"[\(\): ]" => "")
                    manager.allowed_dims = Tuple(Symbol.(split(clean_str, ",")))
                end
            end
            if haskey(dims, "max_params")
                manager.max_params = Int(dims["max_params"])
            end
        end
        
        # Load Resolutions
        if haskey(cfg, "Resolution_Base")
            for (k, v) in cfg["Resolution_Base"]
                manager.state[:Resolution_Base][Symbol(k)] = Int(v)
            end
        end
        
        if haskey(cfg, "Resolution_Ref")
            for (k, v) in cfg["Resolution_Ref"]
                manager.state[:Resolution_Ref][Symbol(k)] = Int(v)
            end
        end

        sim_func_str = get(parsed["Config"]["General"], "simulation_func", "none")
        resolved_func = resolve_simulation_function(sim_func_str, nothing)
        if isnothing(resolved_func)
            @error "Aborting: Could not resolve simulation function '$sim_func_str'"
            return
        end
        
        new_config = csv_to_simulation_config(parsed, resolved_func)
        
        for (key,cache_dict) in manager.caches
            empty!(cache_dict)
        end
        
        set_sim_config!(new_config)
        @info "Project configuration buffered! Press 'Run Simulation' to compute and apply."
    else
        @info "No simulation data found. Loading as a visual preset."
    end
    
    # --- 2. VISUAL PRESETS & STAGING ---
    if haskey(parsed, "UI")
        ui_overrides = _apply_backend_keys(parsed["UI"])
        for (scope, dict) in ui_overrides
            for (k, v) in dict
                set_ui_opt!(scope, k, v)
            end
        end
    end
    
    # --- LOAD SCENE: LAYOUT ---
    if haskey(parsed, "Scene") && haskey(parsed["Scene"], "Layout")
        apply_layout_options!(_apply_backend_keys(parsed["Scene"]["Layout"]))
    elseif haskey(parsed, "Layout") && haskey(parsed["Layout"], "General") 
        apply_layout_options!(_apply_backend_keys(parsed["Layout"]["General"]))
    end

    # --- LOAD SCENE: PLOT ---
    plot_source = if haskey(parsed, "Scene") && haskey(parsed["Scene"], "Plot")
        parsed["Scene"]["Plot"]
    elseif haskey(parsed, "Plot") && haskey(parsed["Plot"], "General") 
        parsed["Plot"]["General"]
    else
        nothing
    end

    if !isnothing(plot_source)
        plot_dict = Dict{Symbol, Any}()
        for (k, v) in plot_source
            bk = backend_key(k)
            if bk in (:x_axis, :y_axis, :z_axis, :u_axis, :c)
                plot_dict[bk] = v
            else
                plot_dict[Symbol(k)] = v 
            end
        end
        apply_plot_options!(plot_dict)
    end

    # --- LOAD SCENE: CAMERA ---
    cam_source = if haskey(parsed, "Scene") && haskey(parsed["Scene"], "Camera")
        parsed["Scene"]["Camera"]
    elseif haskey(parsed, "Camera") && haskey(parsed["Camera"], "General") 
        parsed["Camera"]["General"]
    else
        nothing
    end

    if !isnothing(cam_source) && !isempty(cam_source)
        manager.state[:Camera_Cache] = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in cam_source)
        
        manager.state[:Camera_Locked][] = true
        manager.state[:Skip_Next_Camera_Extract] = true
    else
        manager.state[:Camera_Cache] = Dict{Symbol, Any}()
        manager.state[:Camera_Locked][] = false
    end
    
    # --- LOAD SCENE: LABELS ---
    labels_source = if haskey(parsed, "Scene") && haskey(parsed["Scene"], "Labels")
        parsed["Scene"]["Labels"]
    else
        nothing
    end

    if !isnothing(labels_source)
        for (k, v) in labels_source
            set_label!(Symbol(k), string(v))
        end
    end
    
    # --- LOAD SCENE: EXPLORATION ---
    exp_source = if haskey(parsed, "Scene") && haskey(parsed["Scene"], "Exploration")
        parsed["Scene"]["Exploration"]
    elseif haskey(parsed, "Exploration") && haskey(parsed["Exploration"], "General") 
        parsed["Exploration"]["General"]
    else
        nothing
    end

    if !isnothing(exp_source)
        apply_exploration_options!(_apply_backend_keys(exp_source))
    end
end

"""
    csv_to_simulation_config(parsed_csv::Dict, sim_func::Function)

Converts a parsed nested CSV dictionary into a properly formatted `SimulationConfig`,
ensuring all backend keys are strongly typed as Symbols.
"""
function csv_to_simulation_config(parsed_csv::Dict, sim_func::Function)
    # 1. Extract Shared Parameters (Cast to Symbol keys)
    shared_params = Dict{Symbol, Any}()
    if haskey(parsed_csv, "Simulation") && haskey(parsed_csv["Simulation"], "shared")
        for (k, v) in parsed_csv["Simulation"]["shared"]
            shared_params[Symbol(k)] = v
        end
    end

    # 2. Extract Methods (Cast to Symbol keys)
    methods_dict = Dict{Symbol, Dict{Symbol, Any}}()
    if haskey(parsed_csv, "Simulation")
        for (scope, params) in parsed_csv["Simulation"]
            if scope != "shared"
                m_sym = Symbol(scope)
                methods_dict[m_sym] = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in params)
            end
        end
    end

    # 3. Extract Varied Parameters from the Config Category (Cast to Symbol keys)
    varied_params = Dict{Symbol, Vector{Any}}()
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "Parameters")
        for (k, v) in parsed_csv["Config"]["Parameters"]
            varied_params[Symbol(k)] = v
        end
    else
        @info "No 'Config -> Parameters' found in CSV. Simulation will have no varied parameters."
    end

    # 4. Default Methods (Explicit override if available!)
    active_methods = Symbol[]
    has_explicit_active = false
    
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "General") && haskey(parsed_csv["Config"]["General"], "active_methods")
        raw_active = parsed_csv["Config"]["General"]["active_methods"]
        if raw_active isa AbstractVector
            active_methods = Symbol.(raw_active)
            has_explicit_active = true
            
            # Ensure every explicitly active method has at least an empty dict to prevent backend crashes
            for m in active_methods
                if !haskey(methods_dict, m)
                    methods_dict[m] = Dict{Symbol, Any}()
                end
            end
        end
    end
    
    # Fallback for older CSVs without the explicitly saved active methods
    if isempty(active_methods)
        active_methods = collect(keys(methods_dict))
    end
    active_methods = sort_methods_robust(active_methods)

    # 5. Extract Reference Name explicitly from Config
    ref_name = nothing
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "General")
        csv_ref = String(get(parsed_csv["Config"]["General"], "reference_func", "none"))
        if csv_ref != "none" && !isempty(csv_ref)
            ref_name = csv_ref
        end
    end

    # 6. Resolve the Analytical Solution Factory
    ref_func = nothing
    if !isnothing(ref_name)
        safe_ref_name = lowercase(replace(strip(ref_name), r"[\s-]+" => "_"))
        
        ref_factory = try
            resolve_reference_function(safe_ref_name)
        catch
            nothing
        end
        
        if !isnothing(ref_factory)
            ref_func = ref_factory(shared_params)
            ns = Symbol(ref_name)
            
            if !haskey(methods_dict, ns)
                methods_dict[ns] = Dict{Symbol, Any}()
            end
            
            # Only force the reference method to be active if we didn't get an explicit list from the CSV
            if !(ns in active_methods) && !has_explicit_active
                push!(active_methods, ns)
                active_methods = sort_methods_robust(active_methods)
            end
        else
            @warn "Failed to resolve reference function: $safe_ref_name"
        end
    end

    # 7. Construct and return the SimulationConfig
    sim_func_str = String(parsed_csv["Config"]["General"]["simulation_func"])
    
    return SimulationConfig(
        sim_func_str, 
        shared_params,
        methods_dict,
        active_methods;
        varied_params = varied_params, ref_func_name = ref_name
    )
end

function smart_parse_csv_value(val_str::AbstractString)
    val_str = strip(val_str)
    
    if val_str == "true"; return true; end
    if val_str == "false"; return false; end
    if val_str == "<empty>"; return ""; end
    
    # THE FIX: Safely parse standard Julia Types back into DataType objects
    type_map = Dict{String, DataType}(
        "Float16" => Float16, "Float32" => Float32, "Float64" => Float64, "BigFloat" => BigFloat,
        "Int8" => Int8, "Int16" => Int16, "Int32" => Int32, "Int64" => Int64, "Int128" => Int128,
        "ComplexF32" => ComplexF32, "ComplexF64" => ComplexF64, "Bool" => Bool
    )
    if haskey(type_map, val_str)
        return type_map[val_str]
    end
    
    v_int = tryparse(Int, val_str)
    if !isnothing(v_int); return v_int; end
    v_float = tryparse(Float64, val_str)
    if !isnothing(v_float); return v_float; end
    
    if startswith(val_str, ":") || startswith(val_str, "[") || startswith(val_str, "(")
        try
            return eval(Meta.parse(val_str))
        catch e
            @warn "Failed to parse expression: $val_str"
        end
    end
    
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
    _value_to_string_for_csv(v)

A robust helper to convert a Julia object to a string for CSV saving.
Explicitly strips type prefixes (like 'Any' or 'Vector{Float64}') from 
containers to ensure they are saved as clean, parsable Julia expressions.
"""
function _value_to_string_for_csv(v)
    if isa(v, Symbol)
        return ":" * string(v)
    end

    if v == ""
        return "<empty>"
    end

    if isa(v, AbstractArray)
        s = string(v)
        return replace(s, r"^[a-zA-Z0-9_{}, ]*\[" => "[")
    end
    
    if isa(v, Tuple)
        s = string(v)
        return replace(s, r"^[a-zA-Z0-9_{}, ]*\(" => "(")
    end

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
            end
        end
        
        filter!(d -> !(d in [".git", "build", "node_modules", ".vscode", "docs"]), dirs)
    end
    
    return git_infos
end

function get_julia_info(git_repo_names::Vector{String})
    info = Dict{String, Dict{String, Any}}()
    info["System"] = Dict{String, Any}("Julia_Version" => string(VERSION))
    
    deps = Pkg.dependencies()
    
    top_deps = Dict{String, Any}()
    for (uuid, pkg) in deps
        if pkg.is_direct_dep
            top_deps[pkg.name] = string(pkg.version)
        end
    end
    info["Main_Project"] = top_deps
    
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

function save_params_to_csv(
    base_filename::String,
    save_dir::String,
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

        # --- 2. CATEGORY: Scene ---
        plot_opts = extract_plot_options()
        for (k, v) in plot_opts
            if k in (:x_axis, :y_axis, :z_axis, :u_axis, :c)
                add_row("Scene", "Plot", frontend_key(k), v)
            else
                add_row("Scene", "Plot", string(k), v) # Preserve exact parameter names
            end
        end
        
        layout_opts = extract_layout_options()
        for (k, v) in layout_opts
            add_row("Scene", "Layout", frontend_key(k), v)
        end
        
        cam_opts = get(manager.state, :Camera_Cache, Dict{Symbol, Any}())
        for (k, v) in cam_opts
            add_row("Scene", "Camera", string(k), v)
        end

        if haskey(manager.maps, :Labels)
            for (k, v) in manager.maps[:Labels]
                # Save the raw backend key as the parameter, and the user's label as the value
                add_row("Scene", "Labels", string(k), v)
            end
        end

        # --- 3. CATEGORY: UI ---
        for (scope, dict) in manager.ui
            f_scope = frontend_key(scope)
            for (k, v) in dict
                add_row("UI", f_scope, frontend_key(k), v)
            end
        end

        # --- 4. CATEGORY: Simulation & Config ---
        config = manager.active_config

        for (k, v) in config.shared_params
            add_row("Simulation", "shared", string(k), v)
        end
        for m_name in manager.methods[]
            m_sym = Symbol(m_name)
            if haskey(config.methods_dict, m_sym)
                for (k, v) in config.methods_dict[m_sym]
                    add_row("Simulation", m_name, string(k), v)
                end
            end
        end

        for (k, v) in config.varied_params
            add_row("Config", "Parameters", string(k), v)
        end
        
        add_row("Config", "General", "simulation_func", string(config.simulation_name))
        add_row("Config", "General", "reference_func", isnothing(config.reference_name) ? "none" : string(config.reference_name))
        add_row("Config", "General", "active_methods", manager.methods[])

        # NEW: Dimensions Scope
        add_row("Config", "Dimensions", "allowed_dims", manager.allowed_dims)
        add_row("Config", "Dimensions", "max_params", manager.max_params)

        # NEW: Dynamic Resolutions
        for (dim, res) in manager.state[:Resolution_Base]
            add_row("Config", "Resolution_Base", string(dim), res)
        end
        for (dim, res) in manager.state[:Resolution_Ref]
            add_row("Config", "Resolution_Ref", string(dim), res)
        end

        CSV.write(csv_filename, DataFrame(Category=cats, Scope=scopes, Parameter=params, Value=vals))
        @info "Metadata and Parameters saved to $csv_filename"
        return true
    catch e
        @error "CSV Save Failed" exception=(e, catch_backtrace())
        return false
    end
end

# In ConfigIO.jl
function save_preset_to_csv(preset_name::Symbol, save_dir::String)
    csv_filename = joinpath(save_dir, string(preset_name) * ".csv")
    
    try
        cats, scopes, params, vals = String[], String[], String[], String[]

        function add_row(cat, scope, p, v)
            push!(cats, string(cat))
            push!(scopes, string(scope))
            push!(params, string(p))
            push!(vals, _value_to_string_for_csv(to_value(v)))
        end

        # --- 1. PRESET METADATA ---
        desc = get(manager.maps[:Presets], preset_name, "User custom preset")
        add_row("Metadata", "Preset", "description", desc)

        # --- 2. SCENE ---
        plot_opts = extract_plot_options()
        for (k, v) in plot_opts
            if k in (:x_axis, :y_axis, :z_axis, :u_axis, :c)
                add_row("Scene", "Plot", frontend_key(k), v)
            else
                add_row("Scene", "Plot", string(k), v) 
            end
        end
        
        layout_opts = extract_layout_options()
        for (k, v) in layout_opts
            add_row("Scene", "Layout", frontend_key(k), v)
        end
        
        cam_opts = get(manager.state, :Camera_Cache, Dict{Symbol, Any}())
        for (k, v) in cam_opts
            add_row("Scene", "Camera", string(k), v)
        end

        if haskey(manager.maps, :Labels)
            for (k, v) in manager.maps[:Labels]
                add_row("Scene", "Labels", string(k), v)
            end
        end
        
        exp_opts = extract_exploration_options()
        for (k, v) in exp_opts
            add_row("Scene", "Exploration", frontend_key(k), v)
        end
        # --- 3. UI ---
        for (scope, dict) in manager.ui
            f_scope = frontend_key(scope)
            for (k, v) in dict
                add_row("UI", f_scope, frontend_key(k), v)
            end
        end

        CSV.write(csv_filename, DataFrame(Category=cats, Scope=scopes, Parameter=params, Value=vals))
        @info "Preset saved to $csv_filename"
        return true
    catch e
        @error "Preset Save Failed" exception=(e, catch_backtrace())
        return false
    end
end