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
    get_julia_info()
Returns a dictionary containing the Julia version and the versions of 
loaded/project packages.
"""
function get_julia_info()
    info = Dict{String, Any}("Julia" => string(VERSION))
    
    # Get versions of all dependencies in the current project
    for (uuid, pkg) in Pkg.dependencies()
        if pkg.is_direct_dep
            info[pkg.name] = string(pkg.version)
        end
    end
    return info
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

# This function can be added to your plotting_helpers.jl or a similar utility file.


"""
    get_git_info(start_path=".") -> Union{Dict{String, Any}, Nothing}

Inspects the Git repository containing the given path and returns key information
about the current state (HEAD commit). It robustly finds the repository root by
searching upwards from the `start_path`.
"""
function get_git_info(start_path::String = ".")
    try
        # --- Robust Repo Discovery Logic ---
        current_path = abspath(start_path)
        repo_root_path = nothing

        while true
            if isdir(joinpath(current_path, ".git"))
                repo_root_path = current_path
                break
            end
            parent_path = dirname(current_path)
            if parent_path == current_path; break; end
            current_path = parent_path
        end

        if isnothing(repo_root_path)
            @warn "Could not find a .git repository in or above the path: $(abspath(start_path))"
            return nothing
        end
        
        repo = LibGit2.GitRepo(repo_root_path)
        
        # --- Extract Information ---
        head_ref = LibGit2.head(repo)
        commit = LibGit2.peel(LibGit2.GitCommit, head_ref)
        
        # --- THIS IS THE FINAL FIX ---
        # The most robust, idiomatic way to get the hash is to construct a
        # `GitHash` object from the commit, then convert it to a string.
        commit_hash = string(LibGit2.GitHash(commit))
        # --- END OF FIX ---

        commit_summary = LibGit2.summary(commit)
        
        commit_count = try
            parse(Int, readchomp(`git -C $repo_root_path rev-list --count HEAD`))
        catch
            -1 # Indicate count could not be determined
        end

        return Dict{String, Any}(
            "git_commit_hash" => commit_hash,
            "git_commit_count" => commit_count,
            "git_commit_summary" => commit_summary,
            "julia_version" => string(VERSION)
        )
        
    catch e
        @warn "Could not retrieve Git information." exception=(e, catch_backtrace())
        return nothing
    end
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
        
        git_info = get_git_info(pwd())
        if !isnothing(git_info)
            for (k, v) in git_info; add_row("Metadata", "Git", k, v); end
        end

        julia_info = get_julia_info()
        for (k, v) in julia_info; add_row("Metadata", "Julia", k, v); end

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