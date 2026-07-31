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
    
    # Restore Grid Resolutions BEFORE loading config[cite: 16]
    if haskey(parsed, "Config") && haskey(parsed["Config"], "Resolutions")
        res = parsed["Config"]["Resolutions"]
        haskey(res, "N")   && (set_space_resolution!(res["N"]))
        haskey(res, "T")   && (set_time_resolution!(res["T"]))
        haskey(res, "Ref") && (set_ref_resolution!(res["Ref"]))
        @info "Restored grid resolutions: N=$(res["N"]), T=$(res["T"]), REF=$(res["Ref"])"
    end

    sim_func_str = parsed["Config"]["General"]["simulation_func"]
    resolved_func = resolve_simulation_function(sim_func_str, nothing)
    if isnothing(resolved_func)
        @error "Aborting: Could not resolve simulation function '$sim_func_str'"
        return
    end
    
    new_config = csv_to_simulation_config(parsed, resolved_func)
    
    # Empty existing caches[cite: 16]
    for (key,cache_dict) in manager.caches
        empty!(cache_dict)
    end
    
    # 1. Update the Data Source
    set_sim_config!(new_config)
    
    # 2. Buffer the Overwrites directly into the centralized Staged Cache using Symbols
    if haskey(parsed, "UI")
        manager.staged[:UI] = _apply_backend_keys(parsed["UI"])
    end
    
    # --- LOAD SCENE: LAYOUT ---
    if haskey(parsed, "Scene") && haskey(parsed["Scene"], "Layout")
        manager.staged[:Layout] = _apply_backend_keys(parsed["Scene"]["Layout"])
    elseif haskey(parsed, "Layout") && haskey(parsed["Layout"], "General") # Legacy Fallback
        manager.staged[:Layout] = _apply_backend_keys(parsed["Layout"]["General"])
    end

    # --- LOAD SCENE: PLOT ---
    plot_source = if haskey(parsed, "Scene") && haskey(parsed["Scene"], "Plot")
        parsed["Scene"]["Plot"]
    elseif haskey(parsed, "Plot") && haskey(parsed["Plot"], "General") # Legacy Fallback
        parsed["Plot"]["General"]
    else
        nothing
    end

    if !isnothing(plot_source)
        plot_dict = Dict{Symbol, Any}()
        for (k, v) in plot_source
            bk = backend_key(k)
            # Differentiate UI selections from strictly-cased Parameter Sliders[cite: 16]
            if bk in (:x_axis, :y_axis, :z_axis, :u_axis, :c)
                plot_dict[bk] = v
            else
                plot_dict[Symbol(k)] = v 
            end
        end
        manager.staged[:Plot] = plot_dict
    end

    # --- LOAD SCENE: CAMERA ---
    cam_source = if haskey(parsed, "Scene") && haskey(parsed["Scene"], "Camera")
        parsed["Scene"]["Camera"]
    elseif haskey(parsed, "Camera") && haskey(parsed["Camera"], "General") # Legacy Fallback
        parsed["Camera"]["General"]
    else
        nothing
    end

    if !isnothing(cam_source) && !isempty(cam_source)
        manager.staged[:Camera] = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in cam_source)
    else
        manager.staged[:Camera] = Dict{Symbol, Any}()
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
    
    @info "Config buffered! Press 'Run Simulation' to compute and apply."
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
        @warn "No 'Config -> Parameters' found in CSV. Simulation will have no varied parameters."
    end

    # 4. Default Methods (Explicit override if available!)
    default_methods = Symbol[]
    has_explicit_active = false
    
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "General") && haskey(parsed_csv["Config"]["General"], "active_methods")
        raw_active = parsed_csv["Config"]["General"]["active_methods"]
        if raw_active isa AbstractVector
            default_methods = Symbol.(raw_active)
            has_explicit_active = true
            
            # Ensure every explicitly active method has at least an empty dict to prevent backend crashes
            for m in default_methods
                if !haskey(methods_dict, m)
                    methods_dict[m] = Dict{Symbol, Any}()
                end
            end
        end
    end
    
    # Fallback for older CSVs without the explicitly saved active methods
    if isempty(default_methods)
        default_methods = collect(keys(methods_dict))
    end
    default_methods = sort_methods_robust(default_methods)

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
            if !(ns in default_methods) && !has_explicit_active
                push!(default_methods, ns)
                default_methods = sort_methods_robust(default_methods)
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
        default_methods;
        varied_params = varied_params, ref_func_name = ref_name
    )
end

function smart_parse_csv_value(val_str::String)
    val_str = strip(val_str)
    
    if val_str == "true"; return true; end
    if val_str == "false"; return false; end
    if val_str == "<empty>"; return ""; end
    
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

function saveParametersToCSV(
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
        
        cam_opts = get(manager.staged, :Camera, Dict{Symbol, Any}())
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

        add_row("Config", "Resolutions", "N", get_space_resolution())
        add_row("Config", "Resolutions", "T", get_time_resolution())
        add_row("Config", "Resolutions", "Ref", get_ref_resolution())

        CSV.write(csv_filename, DataFrame(Category=cats, Scope=scopes, Parameter=params, Value=vals))
        @info "Metadata and Parameters saved to $csv_filename"
        return true
    catch e
        @error "CSV Save Failed" exception=(e, catch_backtrace())
        return false
    end
end