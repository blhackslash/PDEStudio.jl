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
    
    # Returns an array like [true, true, false, true] if data is (:x, :y, :t)
    return [dim in actual for dim in allowed]
end

"""
    map_sliders_to_tensor(sim_data::AbstractSimData)

Maps the fixed UI slider indices to the dynamic dimension indices of the underlying tensor.
Returns a Tuple of the same length as the tensor's dimensions, where each element 
corresponds to the ID of the UI slider that controls it.
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
        # Rank 0 if it contains a priority keyword (forces it to the top), Rank 1 otherwise.
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
    update_menu_safe!(menu_widget, new_options; fallbacks=Any[], force_notify=false)

Safely updates a Makie Menu's options, forces a WebGL buffer sync to prevent crashes,
and preserves the current selection or falls back to a prioritized list.
"""
function update_menu_safe!(menu_widget, new_options; fallbacks=Any[], force_notify=false)
    curr = menu_widget.selection[]
    
    new_arr = isempty(new_options) ? Any[("-", :None)] : new_options
    
    # 1. Robust Equality Check (Bypasses Makie's internal MenuOption struct casting)
    old_arr = menu_widget.options[]
    options_changed = false
    
    is_eq = length(old_arr) == length(new_arr)
    if is_eq
        for (o, n) in zip(old_arr, new_arr)
            # Depending on Makie version, elements are raw Tuples or MenuOption objects
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
        # Safely rebuild the WebGL buffer to prevent JS crashes
        menu_widget.is_open[] = true
        menu_widget.is_open[] = false
        options_changed = true
    end

    opt_values = (!isempty(new_options) && new_options[1] isa Tuple) ? [opt[2] for opt in new_options] : new_options

    # 2. Maintain Selection or Apply Fallbacks
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
    
    # 3. Only assign if the index genuinely changed (prevents triggering redundant UI updates)
    selection_changed = menu_widget.i_selected[] != target_idx
    if selection_changed
        menu_widget.i_selected[] = target_idx
    end
    
    # Manually re-notify the pipeline if options shifted underneath a static selection
    if (options_changed && !selection_changed) || force_notify
        notify(menu_widget.selection)
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
    generate_dynamic_title(plot_dims::Tuple, dim_names::Vector{String}, sel_vals)

Constructs the plot title dynamically. It lists all fixed parameters and base variables,
marks the actively plotted dimensions (e.g., X and Y for a surface plot), and allows 
for a user-defined override via `manager.ui`.
"""
function generate_dynamic_title(
    plot_dims::Tuple, 
    dim_names::Vector{Symbol}, 
    sel_vals
)
    # Build the Default Dynamic Title
    title_parts = String[]
    
    for i in 1:length(dim_names)
        name = String(dim_names[i])
        
        if i in plot_dims
            # This is an axis we are currently plotting along
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
function apply_layout_options!(manager::PlotManager, layout_options::Dict)
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
    if !manager.state["Config_Just_Loaded"][]
        manager.triggers["Layout_Update"][] += 1
    end
end

function apply_scene_options!(manager::PlotManager, scene_options::Dict)
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
                # THE FIX: Force inject the option so it survives the reactive cascade!
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
    rev_map = haskey(manager.state, "Reverse_Map") ? manager.state["Reverse_Map"][] : Dict{String, String}()
    for (key, desired_val) in scene_options
        if endswith(key, "_Value")
            base_name = replace(key, "_Value" => "")
            w_key = haskey(rev_map, base_name) ? rev_map[base_name] : base_name
            
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
    if !manager.state["Config_Just_Loaded"][]
        manager.triggers["Primitive_Rebuild"][] += 1
    end
end

function extract_layout_options(manager::PlotManager)
    opts = Dict{String, Any}()
    for k in ["Base_Plot", "Plot_Style", "Compare_Target", "Compare_Columns", "Compare_Link", "Legend_Base", "Legend_Add", "Plot_Width", "Plot_Height", "Anim_Target"]
        if haskey(manager.widgets, k)
            opts["$(k)_Selection"] = manager.widgets[k].selection[]
        end
    end
    return opts
end

function extract_scene_options(manager::PlotManager)
    opts = Dict{String, Any}()
    for k in ["X-Axis", "Y-Axis", "Z-Axis", "U-Axis", "c"]
        if haskey(manager.widgets, k)
            opts["$(k)_Selection"] = manager.widgets[k].selection[]
        end
    end
    
    rev_map = haskey(manager.state, "Reverse_Map") ? manager.state["Reverse_Map"][] : Dict{String, String}()
    for k in manager.plot_vars
        w_key = haskey(rev_map, k) ? rev_map[k] : k
        if haskey(manager.widgets, w_key)
            widget = manager.widgets[w_key]
            # THE FIX: Explicitly check for Makie.Slider!
            if widget isa Makie.Slider
                opts["$(k)_Value"] = widget.value[]
            end
        end
    end
    return opts
end
function load_and_apply_csv!(manager::PlotManager, filepath::String)
    @info "Loading configuration from CSV: $filepath"
    
    parsed = parse_csv_to_dict(filepath)
    
    # Restore Grid Resolutions BEFORE running simulations
    if haskey(parsed, "Config") && haskey(parsed["Config"], "Resolutions")
        res = parsed["Config"]["Resolutions"]
        haskey(res, "N")   && (set_space_resolution!(res["N"]))
        haskey(res, "T")   && (set_time_resolution!(res["T"]))
        haskey(res, "Ref")   && (set_ref_resolution!(res["Ref"]))
        @info "Restored grid resolutions: N=$(res["N"]), T=$(res["T"]), REF=$(res["Ref"])"
    end

    sim_func_str = parsed["Config"]["General"]["simulation_func"]
    resolved_func = resolve_simulation_function(sim_func_str, nothing)
    if isnothing(resolved_func)
        @error "Aborting: Could not resolve simulation function '$sim_func_str'"
        return
    end
    
    new_config = csv_to_simulation_config(parsed, resolved_func)
    
    @info "CSV Loaded: Running all defined simulations for exact recreation..."
    runAllSimulations(new_config; calculate_stats=true, convert_eulerian=true)
    
    empty!(manager.last_run_params)
    for cache_dict in manager.caches
        empty!(cache_dict)
    end
    
    if haskey(parsed, "UI")
        GLOBAL_UI_OVERWRITE[] = parsed["UI"]
    end
    
    if haskey(parsed, "Scene") && haskey(parsed["Scene"], "General")
        scene_opts = Dict{String,Any}()
        for (k, v) in parsed["Scene"]["General"]
            scene_opts[k] = v
        end
        GLOBAL_SCENE_OPTIONS[] = scene_opts
    end
    
    if haskey(parsed, "Layout") && haskey(parsed["Layout"], "General")
        layout_opts = get_base_layout_options()
        for (k, v) in parsed["Layout"]["General"]
            layout_opts[k] = v
        end
        GLOBAL_LAYOUT_OPTIONS[] = layout_opts
    end

    # --- THE FIX (Part 2): Apply and Lock the Camera ---
    if haskey(parsed, "Camera") && haskey(parsed["Camera"], "General") && !isempty(parsed["Camera"]["General"])
        GLOBAL_CAMERA_OPTIONS[] = parsed["Camera"]["General"]
        
        # Turn the lock ON so _enforce_camera_lock! actually applies these limits!
        manager.state["Camera_Locked"][] = true
        if haskey(manager.widgets, "Lock_Camera_Button")
            btn = manager.widgets["Lock_Camera_Button"]
            btn.label[] = "Unlock Camera"
            btn.buttoncolor[] = :lightgreen # Match your "locked" UI color
        end
    else
        GLOBAL_CAMERA_OPTIONS[] = Dict{String, Any}()
        
        # Turn the lock OFF if the CSV didn't have camera settings
        if get(manager.state, "Camera_Locked", Observable(false))[]
            manager.state["Camera_Locked"][] = false
            if haskey(manager.widgets, "Lock_Camera_Button")
                btn = manager.widgets["Lock_Camera_Button"]
                btn.label[] = "Lock Camera"
                btn.buttoncolor[] = :lightgray
            end
        end
    end
    
    ACTIVE_SIM_CONFIG[] = new_config
    @info "Successfully applied CSV config to UI!"
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
        # Convert the UI string back to a safe function name string
        safe_ref_name = lowercase(replace(strip(ref_name), r"[\s-]+" => "_"))
        
        ref_factory = try
            resolve_reference_function(safe_ref_name)
        catch
            nothing
        end
        
        if !isnothing(ref_factory)
            # THE FIX: Pure execution! The function is already known to the compiler.
            ref_func = ref_factory(shared_params)
            
            # --- Auto-Inject the Reference Method! ---
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
    
    # We pass strings here; the SimulationConfig constructor will cast them to Symbols natively.
    return SimulationConfig(
        sim_func_str, # Passes the string name
        ref_name,     # Passes the string name (or nothing)
        shared_params,
        methods_dict,
        default_methods;
        varied_params = varied_params
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
        layout_opts = extract_layout_options(manager)
        for (k, v) in layout_opts
            add_row("Layout", "General", k, v)
        end
        for (k, v) in GLOBAL_CAMERA_OPTIONS[]
            add_row("Camera", "General", k, v)
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