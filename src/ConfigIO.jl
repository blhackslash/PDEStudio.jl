# ==============================================================================
# --- CSV serialisation of the studio state ---
# ==============================================================================
#
# Every file is a table `Category, Scope, Parameter, Value`; values are written with `val2str` and read back
# with the safe literal parser `str2val` (no code is evaluated). Categories:
#   Metadata    General (export info, bundled sources) / Preset (description, type, mode)
#   Git, Julia  reproducibility information (full exports)
#   Scene       Plot, Layout, Camera, Labels, Exploration
#   UI          one scope per `manager.ui` scope
#   Simulation  Shared, Sweep, Config (methods, defaults, reference, postprocess), one scope per method
#   Config      Dimensions, Resolution_Base, Resolution_Ref (structure of the studio)
# Keys are the backend names (`animation_FPS`, `sim_func_name`); display labels never appear in files.

# ------------------------------------------------------------------------------
# Writing
# ------------------------------------------------------------------------------

struct _CSVRows
    cats::Vector{String}
    scopes::Vector{String}
    params::Vector{String}
    vals::Vector{String}
end
_CSVRows() = _CSVRows(String[], String[], String[], String[])

function add_row!(rows::_CSVRows, cat, scope, param, value)
    push!(rows.cats, string(cat))
    push!(rows.scopes, string(scope))
    push!(rows.params, string(param))
    push!(rows.vals, val2str(to_value(value)))
    return rows
end

function _write_rows(path::AbstractString, rows::_CSVRows)
    mkpath(dirname(abspath(path)))
    CSV.write(path, DataFrame(Category = rows.cats, Scope = rows.scopes, Parameter = rows.params, Value = rows.vals))
    return path
end

_sorted_pairs(d) = sort!(collect(d), by = p -> string(first(p)))

function _add_scene_rows!(rows::_CSVRows)
    # The persistent caches hold the state even when no window is open; open widgets take precedence.
    plot_opts = merge(copy(manager.plot_cache), extract_plot_options())
    for (k, v) in _sorted_pairs(plot_opts)
        add_row!(rows, "Scene", "Plot", k, v)
    end
    layout_opts = merge(copy(manager.layout_cache), extract_layout_options())
    for (k, v) in _sorted_pairs(layout_opts)
        add_row!(rows, "Scene", "Layout", k, v)
    end
    for (k, v) in _sorted_pairs(manager.camera_cache)
        add_row!(rows, "Scene", "Camera", k, v)
    end
    for (k, v) in _sorted_pairs(manager.labels)
        v == string(k) && continue  # skip redundant default labels
        add_row!(rows, "Scene", "Labels", k, v)
    end
    exp_opts = merge(copy(manager.exploration_cache), extract_exploration_options())
    for (k, v) in _sorted_pairs(exp_opts)
        add_row!(rows, "Scene", "Exploration", k, v)
    end
    return rows
end

function _add_ui_rows!(rows::_CSVRows)
    for (scope, dict) in _sorted_pairs(manager.ui)
        for (k, v) in _sorted_pairs(dict)
            add_row!(rows, "UI", scope, k, v)
        end
    end
    return rows
end

const _RESERVED_SIM_SCOPES = ("Shared", "Sweep", "Config")

# Text parameters that would read back as something else ("1e3", "Float64", "Nothing") are written quoted, so a
# simulation parameter keeps its type (and its data-file hash) through a CSV round trip.
_csv_text(v) = (v isa AbstractString && !isempty(v) && !isequal(_parse_csv_value(v), v)) ? repr(String(v)) : v

"""
    _add_simulation_rows!(rows, config::SimulationConfig)

Writes the simulation category of a configuration: shared parameters, the parameters of the *active* methods
(`defaults`; inactive methods are left out, like they are left out of the plots), the method list, the active
methods, the reference and post-processing function names, and the sweep (`Simulation, Sweep`).
"""
function _add_simulation_rows!(rows::_CSVRows, config::SimulationConfig)
    for (k, v) in _sorted_pairs(config.shared)
        add_row!(rows, "Simulation", "Shared", k, _csv_text(v))
    end
    method_names = sort!(filter(m -> haskey(config.methods, m), unique(config.defaults)))
    for m in method_names
        if string(m) in _RESERVED_SIM_SCOPES
            @warn "Method :$m clashes with a reserved CSV scope; its parameters are not saved."
            continue
        end
        for (k, v) in _sorted_pairs(config.methods[m])
            add_row!(rows, "Simulation", m, k, _csv_text(v))
        end
    end
    add_row!(rows, "Simulation", "Config", "methods", method_names)
    add_row!(rows, "Simulation", "Config", "defaults", config.defaults)
    add_row!(rows, "Simulation", "Config", "reference", isnothing(config.reference) ? "none" : string(config.reference))
    add_row!(rows, "Simulation", "Config", "postprocess", isnothing(config.postprocess) ? "none" : string(config.postprocess))
    for (k, v) in _sorted_pairs(config.varied)
        add_row!(rows, "Simulation", "Sweep", k, v)
    end
    return rows
end

# ------------------------------------------------------------------------------
# Reading
# ------------------------------------------------------------------------------

function _parse_csv_value(s::AbstractString)
    txt = strip(String(s))
    txt == "Nothing" && return nothing  # `val2str(nothing)` writes "Nothing"
    return str2val(txt)
end

"""
    _read_csv(filepath)

Reads a studio CSV into two nested dictionaries `[Category][Scope][Parameter]`: the parsed values and the raw cell
texts (used where text must stay text, e.g. labels and string-valued UI options).
"""
function _read_csv(filepath::AbstractString)
    parsed = Dict{String, Dict{String, Dict{String, Any}}}()
    raw = Dict{String, Dict{String, Dict{String, String}}}()
    for row in CSV.Rows(filepath)
        # CSV.Rows yields lazy string types; plain `String`s are needed by the parser (and as dict keys)
        cat = String(coalesce(row.Category, ""))
        scope = String(coalesce(row.Scope, ""))
        param = String(coalesce(row.Parameter, ""))
        val_str = String(coalesce(row.Value, ""))
        (isempty(cat) || isempty(param)) && continue
        get!(Dict{String, Any}, get!(Dict{String, Dict{String, Any}}, parsed, cat), scope)[param] = _parse_csv_value(val_str)
        get!(Dict{String, String}, get!(Dict{String, Dict{String, String}}, raw, cat), scope)[param] = val_str
    end
    return parsed, raw
end

"""
    parse_csv_to_dict(filepath::AbstractString)

Reads an RFC 4180 CSV file into a nested `Dict` hierarchy `[Category][Scope][Parameter]`, parsing every value with the
safe literal parser `str2val` (vectors, tuples, symbols, numbers, …). No code is evaluated.
"""
parse_csv_to_dict(filepath::AbstractString) = first(_read_csv(filepath))

# The raw cell text of an entry ("<empty>" is the empty string), or `nothing`.
function _raw_value(raw, cat, scope, key)
    isnothing(raw) && return nothing
    r = get(get(get(raw, string(cat), Dict()), string(scope), Dict()), string(key), nothing)
    isnothing(r) && return nothing
    return r == "<empty>" ? "" : String(r)
end

# The `manager.ui` / MASTER_UI_DICT scope behind a UI scope name: `x_axis`, `y_axis` and `z_axis` stand for the axis
# variant of the active plot type (`x_axis_1d` for 1D plots, `x_axis_nd` for 2D and 3D plots, `z_axis_3d`), the
# editor pages of the plot types (`:lines_1d`, …) for the shared `plot_style` scope.
function _ui_template_scope(scope::Symbol)
    haskey(STYLE_DEPENDENCIES, scope) && return :plot_style
    scope === :z_axis && return :z_axis_3d
    scope in (:x_axis, :y_axis) || return scope
    ptype = manager.active_plot_type
    one_d = get(PLOT_DIM_MAP, ptype, 1) == 1 && !is_surface(ptype)
    return Symbol(scope, one_d ? "_1d" : "_nd")
end

# The options of the axis `:x_axis`, `:y_axis` or `:z_axis` for the active plot type.
_axis_ui(axis::Symbol) = manager.ui[_ui_template_scope(axis)]

function _ui_template_value(scope::Symbol, key::Symbol)
    template = _ui_template_scope(scope)
    haskey(manager.ui, template) && haskey(manager.ui[template], key) && return manager.ui[template][key]
    haskey(MASTER_UI_DICT, template) && return get(MASTER_UI_DICT[template], key, nothing)
    return nothing
end

# Text-valued options stay text, even if the text looks like a number, symbol or type ("1e3", "Float64", ...).
function _coerce_ui_value(scope::Symbol, key::Symbol, value, raw_value)
    template = _ui_template_value(scope, key)
    if template isa AbstractString && !(value isa AbstractString)
        return isnothing(raw_value) ? val2str(value) : raw_value
    end
    return value
end

function _parse_dims(raw)
    raw isa Tuple && return Tuple(Symbol(d) for d in raw)
    raw isa AbstractVector && return Tuple(Symbol(d) for d in raw)
    raw isa Symbol && return (raw,)
    @warn "Ignoring invalid allowed_dims $(repr(raw)); expected a tuple of symbols such as (:x, :t)."
    return manager.allowed_dims
end

_scene_source(parsed::Dict, name::String) = get(get(parsed, "Scene", Dict()), name, nothing)

_has_visual_data(parsed::Dict) = haskey(parsed, "Scene") || haskey(parsed, "UI")

_keysyms(d) = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in d)

# ------------------------------------------------------------------------------
# Bundled source files
# ------------------------------------------------------------------------------

"""
    _include_as(mod, file, as)

Runs the code of `file` in `mod` as if it were the file `as`: `@__DIR__` and relative `include`s resolve next to
`as`. Used to run the snapshot of a source file bundled with an export at the place of its original, so it finds the
files it includes there while that folder exists. (Sets the task-local source path that `Base.include` uses.)
"""
function _include_as(mod::Module, file::AbstractString, as::AbstractString)
    tls = task_local_storage()
    previous = get(tls, :SOURCE_PATH, nothing)
    tls[:SOURCE_PATH] = as
    try
        return Base.include_string(mod, read(file, String), as)
    finally
        isnothing(previous) ? delete!(tls, :SOURCE_PATH) : (tls[:SOURCE_PATH] = previous)
    end
end

"""
    _run_bundled_sources(parsed, filepath)

Includes the source files bundled with an exported CSV into the target module (this executes their code). Each
bundled copy runs as if it were its original (relative `include`s and `@__DIR__` resolve there) while the original's
folder exists, otherwise from the bundle folder; a missing copy is replaced by its original if that still exists.

A source that fails doesn't abort the load: the error is reported (log and status line) and the parameters come
from the CSV, so the solver functions must then be defined some other way (e.g. by loading their package).
Returns `(config, bundled, origins)`: the `SimulationConfig` returned by the last file if every file ran (otherwise
`nothing`), the absolute paths of the bundled copies (`""` for missing files) and the original paths (if recorded).
"""
function _run_bundled_sources(parsed::Dict, filepath::AbstractString)
    meta = get(get(parsed, "Metadata", Dict()), "General", Dict())
    names = get(meta, "bundled_sources", nothing)
    names isa AbstractString && (names = isempty(names) ? String[] : [names])
    (names isa AbstractVector && !isempty(names)) || return nothing, String[], String[]
    origins = get(meta, "source_origins", String[])
    origins = origins isa AbstractString ? [origins] : origins
    origins = origins isa AbstractVector ? String[string(o) for o in origins] : String[]

    dir = dirname(abspath(filepath))
    bundled = String[]
    last_result = nothing
    failures = manager.source_failures
    for (i, name) in enumerate(names)
        origin = i <= length(origins) ? origins[i] : ""
        # bundled as `<export>_sources/<file>`, by earlier versions as `<export>_source_<i>.jl` next to the CSV
        candidates = unique([joinpath(dir, string(name)), joinpath(dir, basename(string(name))), string(name)])
        idx = findfirst(isfile, candidates)
        copy = isnothing(idx) ? "" : abspath(candidates[idx])
        if isempty(copy) && !(!isempty(origin) && isfile(origin))
            push!(failures, "$(basename(string(name))): missing")
            push!(bundled, "")
            continue
        end
        runs_as = !isempty(origin) && isdir(dirname(origin)) ? origin : copy
        file = isempty(copy) ? origin : copy
        @info "Executing bundled source: $(basename(file))" * (runs_as == file ? "" : " (as $runs_as)")
        try
            last_result = _include_as(get_target_module(), file, runs_as)
        catch e
            @error "Running the bundled source $(basename(file)) failed" exception = (e, catch_backtrace())
            msg = e isa LoadError ? sprint(showerror, e.error) : sprint(showerror, e)
            push!(failures, "$(basename(file)): $(_short(first(split(msg, '\n')), 70))")
            last_result = nothing
        end
        push!(bundled, copy)
    end
    if !isempty(failures)
        _status!("Source files of $(basename(filepath)) failed; the parameters come from the CSV, define the solvers " *
                 "before running. ($(join(failures, "; ")))", :warn)
    end
    config = isempty(failures) && last_result isa SimulationConfig ? last_result : nothing
    return config, bundled, origins
end

# Points the sources of a configuration at existing files, using the bundled copies for missing originals.
function _relocate_sources(sources::AbstractVector, bundled::Vector{String}, origins::Vector{String})
    out = String[]
    for src in sources
        if isfile(src)
            push!(out, abspath(src))
            continue
        end
        i = findfirst(==(abspath(src)), origins)
        if !isnothing(i) && i <= length(bundled) && !isempty(bundled[i])
            push!(out, bundled[i])
        else
            @warn "Source file $src not found; it is removed from the configuration."
        end
    end
    return out
end

# ------------------------------------------------------------------------------
# Loading
# ------------------------------------------------------------------------------

"""
    load_config_file!(path::AbstractString) -> Bool

Runs a Julia configuration file and binds the configuration it returns: its last expression is a `SimulationConfig`,
or a function without arguments that returns one. The file runs in the target module (`set_target_module!`) and is
added to the configuration's `sources`, so exports bundle it. Returns `true` if the configuration needs more
parameter sliders than the open window has (the change is staged until *Run Simulation*), `false` otherwise.

!!! warning
    This **executes the file's code**: only load files you trust. A CSV without bundled sources only holds values
    and never runs code.

A file that loads reliably, also from the snapshot bundled with an export, includes its helpers relative to
`@__DIR__` (or loads them as packages) and uses no absolute paths; see the documentation (*File Operations*).
"""
function load_config_file!(path::AbstractString)
    file = abspath(path)
    empty!(manager.source_failures)
    @warn "Executing $(basename(file)): loading a .jl file runs its code. Only load files you trust (CSV files without bundled sources never run code)."
    result = Base.include(get_target_module(), file)
    result isa Function && (result = Base.invokelatest(result))
    result isa SimulationConfig ||
        throw(ArgumentError("$(basename(file)) must end with a SimulationConfig (or a function without arguments " *
                            "that returns one); it returned $(result === nothing ? "nothing" : "a $(typeof(result))")."))
    any(src -> isfile(src) && samefile(src, file), result.sources) || (result.sources = String[result.sources...; file])

    new_max = max(manager.max_params, length(result.varied))
    if new_max != manager.max_params
        if !manager.is_open
            manager.max_params = new_max
        else
            manager.csv_cache = (dims = manager.allowed_dims, max_params = new_max, parsed = Dict{String, Any}(),
                                 raw = nothing, config = result, sources = result.sources)
            @info "More parameter sliders needed! Configuration staged; press 'Run Simulation' to rebuild the studio."
            return true
        end
    end
    manager.csv_cache = nothing
    _bind_loaded_config!(result)
    return false
end

"""
    _load_runs_code(path) -> Bool

Whether loading the file executes code: a Julia file, or a CSV with bundled source files.
"""
function _load_runs_code(path::AbstractString)
    endswith(lowercase(path), ".jl") && return true
    names = try
        get(get(get(first(_read_csv(path)), "Metadata", Dict()), "General", Dict()), "bundled_sources", nothing)
    catch
        nothing
    end
    return !(isnothing(names) || isempty(names))
end

"""
    load_and_apply_csv!(filepath::AbstractString)

Reads a configuration CSV from disk and applies it.

It executes any bundled Julia source files (which may define solvers and return a `SimulationConfig`), checks whether
the file needs different structural UI limits (allowed dimensions, number of parameter sliders) and stages the data
until *Run Simulation* if the open window has to be rebuilt. Returns `true` if such a structural rebuild is pending.
"""
function load_and_apply_csv!(filepath::AbstractString)
    @info "Loading configuration from CSV: $filepath"
    manager.csv_cache = nothing  # a newer file replaces a staged one
    empty!(manager.source_failures)
    parsed, raw = _read_csv(filepath)
    bundled_config, bundled, origins = _run_bundled_sources(parsed, filepath)
    sources = isnothing(bundled_config) ? filter(!isempty, bundled) :
              _relocate_sources(bundled_config.sources, bundled, origins)

    new_dims, new_max = manager.allowed_dims, manager.max_params
    dims = get(get(parsed, "Config", Dict()), "Dimensions", nothing)
    if !isnothing(dims)
        haskey(dims, "allowed_dims") && (new_dims = _parse_dims(dims["allowed_dims"]))
        get(dims, "max_params", nothing) isa Real && (new_max = Int(dims["max_params"]))
    end
    # Make room for every swept parameter of the loaded configuration.
    n_varied = isnothing(bundled_config) ? length(get(get(parsed, "Simulation", Dict()), "Sweep", Dict())) :
               length(bundled_config.varied)
    new_max = max(new_max, n_varied)

    if new_dims != manager.allowed_dims || new_max != manager.max_params
        if !manager.is_open
            # No window yet: the limits can be applied directly.
            manager.allowed_dims = new_dims
            manager.max_params = new_max
            _sync_resolution_dims!()
        else
            manager.csv_cache = (dims = new_dims, max_params = new_max, parsed = parsed, raw = raw,
                                         config = bundled_config, sources = sources)
            @info "Structural limits changed! Configuration staged; press 'Run Simulation' to rebuild the studio."
            return true
        end
    end

    load_and_apply_csv!(parsed, raw; config = bundled_config, sources = sources)
    return false
end

function _bind_loaded_config!(config::SimulationConfig)
    for (_, cache_dict) in manager.caches
        empty!(cache_dict)
    end
    set_sim_config!(config)
    @info "Project configuration buffered! Press 'Run Simulation' to compute and apply."
    return config
end

"""
    load_and_apply_csv!(parsed::Dict, raw = nothing; config = nothing, sources = String[])

Applies a parsed (and structurally verified) configuration to the studio: display resolutions, the simulation
configuration (`config` if given, e.g. returned by a bundled source, otherwise built from the `Simulation` category),
the plot style, UI overrides, layout, axes and slider positions, camera, labels and exploration options.
`raw` holds the raw cell texts (see `_read_csv`); `sources` replaces the configuration's source files.
"""
function load_and_apply_csv!(parsed::Dict, raw = nothing; config = nothing, sources = String[])
    @info "Applying parsed CSV configuration..."
    cfg = get(parsed, "Config", Dict())
    for (scope, target) in (("Resolution_Base", manager.resolution_base), ("Resolution_Ref", manager.resolution_ref))
        for (k, v) in get(cfg, scope, Dict())
            v isa Real && (target[Symbol(k)] = Int(v))
        end
    end

    # --- 1. SIMULATION ---
    if !isnothing(config)
        isempty(sources) || (config.sources = sources)
        _bind_loaded_config!(config)
    elseif haskey(parsed, "Simulation")
        new_config = csv_to_simulation_config(parsed)
        isempty(sources) || (new_config.sources = sources)
        _bind_loaded_config!(new_config)
    else
        @info "No simulation data found. Loading as a visual preset."
    end

    _has_visual_data(parsed) || return nothing

    # --- 2. PLOT STYLE FIRST (builds the matching UI templates) ---
    layout_source = _scene_source(parsed, "Layout")
    if !isnothing(layout_source)
        for (k, v) in layout_source
            if k == "plot_style" && v isa Union{Symbol, AbstractString}
                switch_ui_plot_type!(Symbol(v))
                break
            end
        end
    end

    # --- 3. UI OVERRIDES ---
    for (scope_str, dict) in get(parsed, "UI", Dict())
        scope = Symbol(scope_str)
        for (k_str, v) in dict
            key = Symbol(k_str)
            set_ui_opt!(scope, key, _coerce_ui_value(scope, key, v, _raw_value(raw, "UI", scope_str, k_str)))
        end
    end

    # --- 4. LAYOUT ---
    if !isnothing(layout_source)
        apply_layout_options!(_keysyms(layout_source))
    end

    # --- 5. PLOT (axes, field, component and slider positions) ---
    plot_source = _scene_source(parsed, "Plot")
    if !isnothing(plot_source)
        apply_plot_options!(_keysyms(plot_source))
    end

    # --- 6. CAMERA ---
    cam_source = _scene_source(parsed, "Camera")
    if !isnothing(cam_source) && !isempty(cam_source)
        manager.camera_cache = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in cam_source)
        manager.camera_locked[] = true
        manager.skip_next_camera_extract = true
    else
        manager.camera_cache = Dict{Symbol, Any}()
        manager.camera_locked[] = false
    end

    # --- 7. LABELS (kept as text) ---
    labels_source = _scene_source(parsed, "Labels")
    if !isnothing(labels_source)
        for (k, v) in labels_source
            set_label!(Symbol(k), something(_raw_value(raw, "Scene", "Labels", k), string(v)))
        end
    end

    # --- 8. EXPLORATION ---
    exp_source = _scene_source(parsed, "Exploration")
    if !isnothing(exp_source)
        apply_exploration_options!(_keysyms(exp_source))
    end
    return nothing
end

# ------------------------------------------------------------------------------
# Simulation category <-> SimulationConfig
# ------------------------------------------------------------------------------

_function_name(::Nothing) = nothing
_function_name(v::Symbol) = v === :none ? nothing : v
_function_name(v::Function) = nameof(v)
function _function_name(v::AbstractString)
    s = strip(v)
    return (isempty(s) || lowercase(s) == "none") ? nothing : Symbol(s)
end
_function_name(v) = Symbol(string(v))

"""
    csv_to_simulation_config(parsed_csv::Dict; base = nothing)

Converts the simulation category of a parsed CSV into a `PDEStudioCore.SimulationConfig`: shared parameters, methods,
active methods (`defaults`), the sweep (`Simulation, Sweep`) and the reference / post-processing function names.

With a `base` configuration, the CSV is applied as a patch: only the entries present in the file change, everything else
(including the source files) is taken from `base`.
"""
function csv_to_simulation_config(parsed_csv::Dict; base::Union{Nothing, SimulationConfig} = nothing)
    sim = get(parsed_csv, "Simulation", Dict{String, Any}())
    cfg = get(sim, "Config", Dict{String, Any}())

    shared      = isnothing(base) ? ParamDict() : copy(base.shared)
    methods     = isnothing(base) ? MethodDict() : MethodDict(k => copy(v) for (k, v) in base.methods)
    varied      = isnothing(base) ? VariedDict() : copy(base.varied)
    defaults    = isnothing(base) ? Symbol[] : copy(base.defaults)
    reference   = isnothing(base) ? nothing : base.reference
    postprocess = isnothing(base) ? nothing : base.postprocess
    sources     = isnothing(base) ? String[] : copy(base.sources)

    # 1. Shared parameters and method overrides
    for (k, v) in get(sim, "Shared", Dict{String, Any}())
        shared[Symbol(k)] = v
    end
    for (scope, params) in sim
        scope in _RESERVED_SIM_SCOPES && continue
        method = get!(ParamDict, methods, Symbol(scope))
        for (k, v) in params
            method[Symbol(k)] = v
        end
    end
    method_names = get(cfg, "methods", nothing)
    if method_names isa AbstractVector
        for m in method_names
            get!(ParamDict, methods, Symbol(m))  # methods without parameters have no rows of their own
        end
    end

    # 2. The sweep
    for (k, v) in get(sim, "Sweep", Dict{String, Any}())
        varied[Symbol(k)] = v isa AbstractVector ? collect(v) : Any[v]
    end

    # 3. Active methods and function names
    raw_defaults = get(cfg, "defaults", nothing)
    if raw_defaults isa AbstractVector
        defaults = Symbol[Symbol(m) for m in raw_defaults]
    elseif raw_defaults isa Union{Symbol, AbstractString}
        defaults = [Symbol(raw_defaults)]
    end
    haskey(cfg, "reference") && (reference = _function_name(cfg["reference"]))
    haskey(cfg, "postprocess") && (postprocess = _function_name(cfg["postprocess"]))
    for m in defaults
        get!(ParamDict, methods, m)
    end
    isempty(defaults) && (defaults = sort_methods_robust(collect(keys(methods))))   # an explicit list keeps its order

    return SimulationConfig(shared, methods, defaults;
                            varied = varied, reference = reference, postprocess = postprocess, sources = sources)
end

# ------------------------------------------------------------------------------
# Reproducibility information
# ------------------------------------------------------------------------------

function _find_git_repos!(out::Vector{String}, dir::String, depth::Int, max_depth::Int)
    isdir(joinpath(dir, ".git")) && push!(out, dir)
    depth >= max_depth && return out
    entries = try
        readdir(dir)
    catch
        return out
    end
    for name in entries
        (startswith(name, ".") || name in ("build", "node_modules", "docs")) && continue
        path = joinpath(dir, name)
        (isdir(path) && !islink(path)) && _find_git_repos!(out, path, depth + 1, max_depth)
    end
    return out
end

"""
    get_all_git_infos(start_path::String = "."; max_depth = 3)

Searches the filesystem below `start_path` (at most `max_depth` levels, skipping hidden, `build`, `node_modules` and
`docs` folders) for local Git repositories. Returns the commit hash, summary, and total commit count of each for
research reproducibility tracking.
"""
function get_all_git_infos(start_path::String = "."; max_depth::Int = 3)
    git_infos = Dict{String, Dict{String, Any}}()
    for root in _find_git_repos!(String[], abspath(start_path), 0, max_depth)
        try
            repo = LibGit2.GitRepo(root)
            commit = LibGit2.peel(LibGit2.GitCommit, LibGit2.head(repo))
            git_infos[basename(root)] = Dict{String, Any}(
                "git_commit_hash" => string(LibGit2.GitHash(commit)),
                "git_commit_summary" => LibGit2.summary(commit),
                "git_commit_count" => try parse(Int, readchomp(`git -C $root rev-list --count HEAD`)) catch; -1 end
            )
        catch
            # Not a valid repository (or no commits yet): skipped.
        end
    end
    return git_infos
end

"""
    get_julia_info(git_repo_names::Vector{String})

Queries the active Julia `Pkg` environment to log the exact system version and track dependencies.
It focuses specifically on top-level project dependencies and the sub-dependencies of tracked local Git repositories to guarantee exact environmental matching upon reload.
"""
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

# ------------------------------------------------------------------------------
# Full exports and visual presets
# ------------------------------------------------------------------------------

"""
    save_params_to_csv(base_filename::AbstractString, save_dir::AbstractString, metadata_general::Dict)

The primary serialization engine. It writes the full state of the studio—the `SimulationConfig`, scene (axes,
sliders, layout, camera, labels, exploration), UI styles, structural limits and display resolutions—plus Git and
Julia environment information to `<save_dir>/<base_filename>.csv`. The configuration's source files are copied next
to the CSV (`<name>_source_<i>.jl`) so the export can be reloaded elsewhere.

Returns `true` on a successful write.
"""
function save_params_to_csv(base_filename::AbstractString, save_dir::AbstractString, metadata_general::Dict)::Bool
    csv_filename = joinpath(save_dir, base_filename * ".csv")
    csv_dir = dirname(abspath(csv_filename))

    try
        rows = _CSVRows()

        # --- 1. CATEGORY: Metadata ---
        for (k, v) in _sorted_pairs(metadata_general)
            add_row!(rows, "Metadata", "General", k, v)
        end

        config = manager.active_config
        if !isnothing(config) && !isempty(config.sources)
            # The sources are copied into `<name>_sources/` under their own file names, so a bundled file that
            # includes another bundled one (`include("solvers.jl")`) still finds it when the originals are gone.
            bundled_names, origins = String[], String[]
            bundle_dir = "$(basename(base_filename))_sources"
            for src_path in config.sources
                if isfile(src_path)
                    name = basename(src_path)
                    while joinpath(bundle_dir, name) in bundled_names   # two sources with the same file name
                        name = "$(length(bundled_names) + 1)_$name"
                    end
                    bundled_name = joinpath(bundle_dir, name)
                    dst_path = joinpath(csv_dir, bundled_name)
                    mkpath(dirname(dst_path))
                    abspath(src_path) == abspath(dst_path) || cp(src_path, dst_path; force = true)
                    push!(bundled_names, bundled_name)
                    push!(origins, abspath(src_path))
                else
                    @warn "Source file not found and skipped: $src_path"
                end
            end
            if !isempty(bundled_names)
                add_row!(rows, "Metadata", "General", "bundled_sources", bundled_names)
                add_row!(rows, "Metadata", "General", "source_origins", origins)
            end
        end

        # --- 2. Git (Scope = Repo Name) & Julia (Scope = Main Project or Local Sub-Package) ---
        git_infos = get_all_git_infos(pwd())
        for (repo_name, info) in _sorted_pairs(git_infos)
            for (k, v) in _sorted_pairs(info); add_row!(rows, "Git", repo_name, k, v); end
        end
        for (scope, info) in _sorted_pairs(get_julia_info(collect(keys(git_infos))))
            for (k, v) in _sorted_pairs(info); add_row!(rows, "Julia", scope, k, v); end
        end

        # --- 3. Scene & UI ---
        _add_scene_rows!(rows)
        _add_ui_rows!(rows)

        # --- 4. Simulation & Config ---
        isnothing(config) || _add_simulation_rows!(rows, config)
        add_row!(rows, "Config", "Dimensions", "allowed_dims", manager.allowed_dims)
        add_row!(rows, "Config", "Dimensions", "max_params", manager.max_params)
        for (dim, res) in _sorted_pairs(manager.resolution_base)
            add_row!(rows, "Config", "Resolution_Base", dim, res)
        end
        for (dim, res) in _sorted_pairs(manager.resolution_ref)
            add_row!(rows, "Config", "Resolution_Ref", dim, res)
        end

        _write_rows(csv_filename, rows)
        @info "Metadata and Parameters saved to $csv_filename"
        return true
    catch e
        @error "CSV Save Failed" exception=(e, catch_backtrace())
        return false
    end
end

"""
    save_preset_to_csv(preset_name::Symbol, save_dir::AbstractString)

A lightweight serialization pipeline that exclusively writes the visual state (scene, camera, labels, exploration
and UI styles) without any simulation parameters. Used to generate reusable aesthetic templates; see `save_plot_preset`.
"""
function save_preset_to_csv(preset_name::Symbol, save_dir::AbstractString)
    csv_filename = joinpath(save_dir, string(preset_name) * ".csv")

    try
        rows = _CSVRows()
        desc = get(manager.presets, preset_name, "User custom preset")
        add_row!(rows, "Metadata", "Preset", "description", desc)
        add_row!(rows, "Metadata", "Preset", "type", "visual")
        _add_scene_rows!(rows)
        _add_ui_rows!(rows)
        _write_rows(csv_filename, rows)
        @info "Preset saved to $csv_filename"
        return true
    catch e
        @error "Preset Save Failed" exception=(e, catch_backtrace())
        return false
    end
end
