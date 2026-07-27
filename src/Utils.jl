# ==============================================================================
# --- Utils.jl ---
# ==============================================================================

function allMethodNames(config::SimulationConfig)
    return sort_methods_robust(collect(keys(config.methods_dict)))
end

function is_reference_method(m_name::String)
    lm = lowercase(m_name)
    return any(k -> occursin(k, lm), ["analytic", "reference", "exact", "baseline", "true"])
end

function _get_first_valid(pd)
    isempty(pd.data) && return nothing
    valid_data = filter(!isnothing, pd.data)
    return isempty(valid_data) ? nothing : first(valid_data)
end

# ==============================================================================
# --- VALIDATION & SLIDER MAPPING ---
# ==============================================================================

"""
    validate_plot_dimensions(sim_data::AbstractSimData)

Checks if the dimension keys of the loaded simulation data are a subset of 
the currently allowed UI dimensions.
"""
function validate_plot_dimensions(sim_data::AbstractSimData)
    allowed = ALLOWED_PLOT_DIMS[]
    actual = sim_data.domain.dim_keys
    
    if !issubset(actual, allowed)
        @warn "Incompatible data loaded. Data dimensions $actual are not a subset of the configured UI dimensions $allowed. Dropping data."
        return false
    end
    return true
end

"""
    get_active_slider_indices(sim_data::AbstractSimData)

Returns a boolean array indicating which of the fixed UI sliders should be enabled 
for the loaded data.
"""
function get_active_slider_indices(sim_data::AbstractSimData)
    allowed = ALLOWED_PLOT_DIMS[]
    actual = sim_data.domain.dim_keys
    return [dim in actual for dim in allowed]
end

"""
    map_sliders_to_tensor(sim_data::AbstractSimData)

Maps the fixed UI slider indices to the dynamic dimension indices of the underlying tensor.
"""
function map_sliders_to_tensor(sim_data::AbstractSimData)
    allowed = ALLOWED_PLOT_DIMS[]
    actual = sim_data.domain.dim_keys
    return ntuple(d -> findfirst(==(actual[d]), allowed), length(actual))
end

# =============================================================================
# THE FIX: Robust Priority Sorting
# =============================================================================
function sort_methods_robust(methods::Vector{String})
    priority_keys = ["analytic", "reference", "exact", "baseline", "true"]
    
    function method_rank(m::String)
        lm = lowercase(m)
        rank = any(k -> occursin(k, lm), priority_keys) ? 0 : 1
        return (rank, m)
    end
    
    return sort(methods, by=method_rank)
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
        return eval(Meta.parse(s))
    catch e
        return s == "<empty>" ? "" : string(strip(s, '\"'))
    end
end

"""
    update_menu_safe!(menu_widget, new_options; fallbacks=Any[], force_notify=false)

Safely updates a Makie Menu's options, forces a WebGL buffer sync to prevent crashes,
and preserves the current selection or falls back to a prioritized list.
"""
function update_menu_safe!(menu_widget, new_options; fallbacks=Any[], force_notify=false)
    curr = menu_widget.selection[]
    new_arr = isempty(new_options) ? Any[("-", :None)] : new_options
    
    old_arr = menu_widget.options[]
    options_changed = false
    
    is_eq = length(old_arr) == length(new_arr)
    if is_eq
        for (o, n) in zip(old_arr, new_arr)
            o_val = hasproperty(o, :value) ? o.value : (o isa Tuple ? o[2] : o)
            n_val = n isa Tuple ? n[2] : n
            if o_val != n_val
                is_eq = false
                break
            end
        end
    end
    
    if !is_eq
        menu_widget.options[] = new_arr
        menu_widget.is_open[] = true
        menu_widget.is_open[] = false
        options_changed = true
    end

    opt_values = (!isempty(new_options) && new_options[1] isa Tuple) ? [opt[2] for opt in new_options] : new_options

    target_idx = 1
    if curr == "-" || curr == :None || isnothing(curr) || curr ∉ opt_values
        if !isempty(new_options)
            idx = nothing
            for f in fallbacks
                idx = findfirst(isequal(f), opt_values)
                !isnothing(idx) && break
            end
            target_idx = isnothing(idx) ? 1 : idx
        end
    else
        target_idx = findfirst(isequal(curr), opt_values)
    end
    
    selection_changed = menu_widget.i_selected[] != target_idx
    if selection_changed
        menu_widget.i_selected[] = target_idx
    end
    
    if (options_changed && !selection_changed) || force_notify
        notify(menu_widget.selection)
    end
end

"""
    smart_parse_and_update!(obs::Observable, input_str::String)

Attempts to parse `input_str` into the same type as the current value of `obs`.
"""
function smart_parse_and_update!(obs::Observable, input_str::String)
    isempty(input_str) && return
    
    current_val = to_value(obs)
    T = typeof(current_val)

    try
        if T == String
            obs[] = input_str
        elseif T == Symbol
            obs[] = Symbol(input_str)
        elseif T == Bool
            s = lowercase(strip(input_str))
            obs[] = (s == "true" || s == "1" || s == "yes")
        elseif T <: Int
            obs[] = parse(Int, input_str)
        elseif T <: AbstractFloat
            obs[] = parse(Float64, input_str)
        elseif T <: Tuple || T <: Vector
            parsed = parseValue(input_str) 
            
            if (T <: Tuple && parsed isa Tuple) || (T <: Vector && parsed isa Vector)
                try
                    obs[] = parsed
                catch e
                    @warn "Failed to apply value. The parameter strictly expects $T, but you provided $(typeof(parsed))."
                end
            else
                @warn "Type mismatch for complex input. Expected a $(T <: Tuple ? "Tuple" : "Vector"), but got $(typeof(parsed))."
            end
        else
            obs[] = parse(T, input_str)
        end
    catch e
        @warn "Invalid input: Could not parse '$input_str' as $T. The value remains: $current_val"
    end
end

"""
    generate_dynamic_title(plot_dims::Tuple, dim_names::Vector{String}, sel_vals)
"""
function generate_dynamic_title(
    plot_dims::Tuple, 
    dim_names::Vector{Symbol}, 
    sel_vals
)
    title_parts = String[]
    
    for i in 1:length(dim_names)
        name = String(dim_names[i])
        
        if i in plot_dims
            push!(title_parts, "$name = [Axis]")
        else
            val = sel_vals[i]
            val_str = val isa AbstractFloat ? @sprintf("%.3f", val) : string(val)
            push!(title_parts, "$name = $val_str")
        end
    end
    
    return join(title_parts, " | ")
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

function apply_layout_options!(layout_options::Dict)
    manager = GLOBAL_PLOT_MANAGER
    isempty(layout_options) && return

    for k in ["Base_Plot", "Plot_Style", "Compare_Target", "Compare_Columns", "Compare_Link", "Legend_Base", "Legend_Add", "Plot_Width", "Plot_Height", "Anim_Target"]
        sel_key = "$(k)_Selection"
        if haskey(layout_options, sel_key) && haskey(manager.widgets, k)
            val = layout_options[sel_key]
            widget = manager.widgets[k]
            
            opts = widget.options[]
            isempty(opts) && continue
            
            valid_vals = (!isempty(opts) && opts[1] isa Tuple) ? [o[2] for o in opts] : opts
            idx = findfirst(v -> string(v) == string(val), valid_vals)
            
            if isnothing(idx) && val isa String
                idx = findfirst(v -> startswith(string(v), val), valid_vals)
            end
            
            if !isnothing(idx)
                widget.i_selected[] = idx 
            end
        end
    end
end

function apply_scene_options!(scene_options::Dict)
    manager = GLOBAL_PLOT_MANAGER
    isempty(scene_options) && return

    # 1. Apply Axis Dropdowns
    for k in ["X-Axis", "Y-Axis", "Z-Axis", "U-Axis", "c"]
        sel_key = "$(k)_Selection"
        if haskey(scene_options, sel_key) && haskey(manager.widgets, k)
            val = scene_options[sel_key]
            widget = manager.widgets[k]
            
            opts = widget.options[]
            isempty(opts) && continue
            
            valid_vals = (!isempty(opts) && opts[1] isa Tuple) ? [o[2] for o in opts] : opts
            idx = findfirst(v -> string(v) == string(val), valid_vals)
            
            if isnothing(idx) && val isa String
                idx = findfirst(v -> startswith(string(v), val), valid_vals)
            end
            
            if !isnothing(idx)
                widget.i_selected[] = idx
                notify(widget.selection)
            else
                if opts isa Vector && !isempty(opts) && opts[1] isa Tuple
                    new_opts = copy(opts)
                    push!(new_opts, (string(val), val))
                    widget.options[] = new_opts
                else
                    new_opts = copy(opts)
                    push!(new_opts, val)
                    widget.options[] = new_opts
                end
                widget.i_selected[] = length(widget.options[])
                notify(widget.selection)
            end
        end
    end

    # 2. Apply Slider Values
    # THE FIX: Dict signature updated to handle Symbol keys
    rev_map = haskey(manager.state, "Reverse_Map") ? manager.state["Reverse_Map"] : Dict{Symbol, String}()
    for (key, desired_val) in scene_options
        if endswith(key, "_Value")
            base_name = replace(key, "_Value" => "")
            # THE FIX: Cast string to Symbol for dictionary lookup
            base_sym = Symbol(base_name)
            w_key = haskey(rev_map, base_sym) ? rev_map[base_sym] : base_name
            
            if haskey(manager.widgets, w_key)
                widget = manager.widgets[w_key]
                if widget isa Makie.Slider
                    rng = widget.range[]
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
end

function extract_layout_options()
    manager = GLOBAL_PLOT_MANAGER
    opts = Dict{String, Any}()
    for k in ["Base_Plot", "Plot_Style", "Compare_Target", "Compare_Columns", "Compare_Link", "Legend_Base", "Legend_Add", "Plot_Width", "Plot_Height", "Anim_Target"]
        if haskey(manager.widgets, k)
            opts["$(k)_Selection"] = manager.widgets[k].selection[]
        end
    end
    return opts
end

function extract_scene_options()
    manager = GLOBAL_PLOT_MANAGER
    opts = Dict{String, Any}()
    for k in ["X-Axis", "Y-Axis", "Z-Axis", "U-Axis", "c"]
        if haskey(manager.widgets, k)
            opts["$(k)_Selection"] = manager.widgets[k].selection[]
        end
    end
    
    rev_map = haskey(manager.state, "Reverse_Map") ? manager.state["Reverse_Map"] : Dict{String, String}()
    for k in manager.plot_vars
        w_key = haskey(rev_map, k) ? rev_map[k] : k
        if haskey(manager.widgets, w_key)
            widget = manager.widgets[w_key]
            if widget isa Makie.Slider
                opts["$(k)_Value"] = widget.value[]
            end
        end
    end
    return opts
end

function load_and_apply_csv!(filepath::String)
    manager = GLOBAL_PLOT_MANAGER
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
    
    # 2. Buffer the Overwrites for the cascade to consume later
    if haskey(parsed, "UI")
        GLOBAL_UI_OVERWRITE[] = parsed["UI"]
    end
    
    if haskey(parsed, "Scene") && haskey(parsed["Scene"], "General")
        GLOBAL_SCENE_OPTIONS[] = parsed["Scene"]["General"]
    end
    
    if haskey(parsed, "Layout") && haskey(parsed["Layout"], "General")
        GLOBAL_LAYOUT_OPTIONS[] = parsed["Layout"]["General"]
    end

    if haskey(parsed, "Camera") && haskey(parsed["Camera"], "General") && !isempty(parsed["Camera"]["General"])
        GLOBAL_CAMERA_OPTIONS[] = parsed["Camera"]["General"]
    else
        GLOBAL_CAMERA_OPTIONS[] = Dict{String, Any}()
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
    manager = GLOBAL_PLOT_MANAGER
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
        scene_opts = extract_scene_options()
        for (k, v) in scene_opts
            add_row("Scene", "General", k, v)
        end
        layout_opts = extract_layout_options()
        for (k, v) in layout_opts
            add_row("Layout", "General", k, v)
        end
        for (k, v) in GLOBAL_CAMERA_OPTIONS[]
            add_row("Camera", "General", k, v)
        end

        # --- 3. CATEGORY: UI ---
        for (scope, dict) in manager.ui
            for (k, v) in dict; add_row("UI", scope, k, v); end
        end

        # --- 4. CATEGORY: Simulation & Config (THE FIX) ---
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