
function _convert_dict_keys_to_symbols(d::Dict)
    new_d = Dict{Symbol, Any}()
    for (k, v) in d
        # Clean hyphens into underscores to match UI definitions (e.g. "X-Axis" -> :X_Axis)
        clean_k = Symbol(replace(string(k), "-" => "_"))
        if v isa Dict
            new_d[clean_k] = _convert_dict_keys_to_symbols(v)
        else
            new_d[clean_k] = v
        end
    end
    return new_d
end

function load_and_apply_csv!(filepath::String)
    
    @info "Loading configuration from CSV: $filepath"
    
    parsed = parse_csv_to_dict(filepath)
    
    # Restore Grid Resolutions BEFORE loading config
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
    
    # Empty existing caches 
    for (key,cache_dict) in manager.caches
        empty!(cache_dict)
    end
    
    # 1. Update the Data Source (No longer an Observable, so no [])
    set_sim_config!(new_config)
    
    # 2. Buffer the Overwrites directly into the centralized Staged Cache using Symbols
    if haskey(parsed, "UI")
        manager.staged[:UI] = _convert_dict_keys_to_symbols(parsed["UI"])
    end
    
    if haskey(parsed, "Plot") && haskey(parsed["Plot"], "General")
        manager.staged[:Plot] = _convert_dict_keys_to_symbols(parsed["Plot"]["General"])
    end
    
    if haskey(parsed, "Layout") && haskey(parsed["Layout"], "General")
        manager.staged[:Layout] = _convert_dict_keys_to_symbols(parsed["Layout"]["General"])
    end

    if haskey(parsed, "Camera") && haskey(parsed["Camera"], "General") && !isempty(parsed["Camera"]["General"])
        manager.staged[:Camera] = _convert_dict_keys_to_symbols(parsed["Camera"]["General"])
    else
        manager.staged[:Camera] = Dict{Symbol, Any}()
    end
    
    @info "Config buffered! Press 'Run Simulation' to compute and apply."
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

    # 2. Extract Methods 
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
    default_methods = sort_methods_robust(collect(keys(methods_dict)))

    # 5. Extract Reference Name explicitly from Config
    ref_name = nothing
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "General")
        csv_ref = String(get(parsed_csv["Config"]["General"], "reference_func", :none))
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
            
            ns = nice_string(safe_ref_name)
            if !haskey(methods_dict, ns)
                methods_dict[ns] = ParamDict()
            end
            if !(ns in default_methods)
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
        ref_name,     
        shared_params,
        methods_dict,
        default_methods;
        varied_params = varied_params
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

        # --- 2. CATEGORY: Plot ---
        plot_opts = extract_plot_options()
        for (k, v) in plot_opts
            add_row("Plot", "General", k, v)
        end
        layout_opts = extract_layout_options()
        for (k, v) in layout_opts
            add_row("Layout", "General", k, v)
        end
        cam_opts = get(manager.staged, :Camera, Dict{Symbol, Any}())
        for (k, v) in cam_opts
            add_row("Camera", "General", k, v)
        end

        # --- 3. CATEGORY: UI ---
        for (scope, dict) in manager.ui
            for (k, v) in dict; add_row("UI", scope, k, v); end
        end

        # --- 4. CATEGORY: Simulation & Config ---
        config = manager.active_config

        for (k, v) in config.shared_params
            add_row("Simulation", "shared", k, v)
        end
        for m_name in manager.methods[]
            if haskey(config.methods_dict, m_name)
                for (k, v) in config.methods_dict[m_name]
                    add_row("Simulation", m_name, k, v)
                end
            end
        end

        for (k, v) in config.varied_params
            add_row("Config", "Parameters", k, v)
        end
        
        add_row("Config", "General", "simulation_func", string(config.simulation_name))
        add_row("Config", "General", "reference_func", isnothing(config.reference_name) ? "none" : string(config.reference_name))
        
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