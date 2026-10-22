# ==============================================================================
# --- Presets: visual (the look) and simulation (the physics) ---
# ==============================================================================
#
# Visual presets      <save path>/Presets/<name>.csv            everything except the simulation
# Simulation presets  <save path>/Presets/Simulation/<name>.csv the simulation category only
#
# Both are plain studio CSVs (see ConfigIO.jl) and can be written by hand.

# Categories applied by a visual preset; anything else in the file (simulation, structure, sources) is ignored.
const VISUAL_CSV_CATEGORIES = ("Scene", "UI")

"""
    preset_dir()

Folder of the visual presets: `<save path>/Presets`.
"""
preset_dir() = joinpath(get_save_path(), "Presets")

"""
    sim_preset_dir()

Folder of the simulation presets: `<save path>/Presets/Simulation`.
"""
sim_preset_dir() = joinpath(preset_dir(), "Simulation")

# Presets are stored under lower-case, underscore-separated names ("My Preset" -> :my_preset).
_preset_symbol(name) = Symbol(lowercase(replace(strip(string(name)), r"\s+" => "_")))

function _preset_file(dir::AbstractString, name)
    for candidate in unique([string(name), string(_preset_symbol(name))])
        path = joinpath(dir, candidate * ".csv")
        isfile(path) && return path
    end
    return nothing
end

function _preset_description(raw, default::AbstractString)
    desc = _raw_value(raw, "Metadata", "Preset", "description")
    (isnothing(desc) || isempty(strip(desc))) && return String(default)
    return String(strip(desc))
end

function _clean_description(desc::AbstractString, default::AbstractString)
    d = strip(desc)
    return (isempty(d) || d == DEFAULT_PRESET_DESC) ? String(default) : String(d)
end

function _scan_presets!(registry::Dict{Symbol, String}, dir::AbstractString)
    isdir(dir) || return registry
    for file in readdir(dir)
        endswith(lowercase(file), ".csv") || continue
        path = joinpath(dir, file)
        isfile(path) || continue
        sym = Symbol(splitext(file)[1])
        haskey(registry, sym) && continue
        registry[sym] = try
            _preset_description(last(_read_csv(path)), "Custom disk preset")
        catch
            "Custom disk preset"  # unreadable or malformed file
        end
    end
    return registry
end

"""
    _store_preset_description!(cat, name, desc)

Writes a new description into the `Metadata, Preset, description` row of an existing preset file (visual presets
for `cat === :ui`, simulation presets otherwise), so a description edited in the studio survives a restart. Built-in
presets and presets without a file keep the description in memory only. Returns `true` if a file was updated.
"""
function _store_preset_description!(cat, name, desc::AbstractString)
    dir = cat === :simulation ? sim_preset_dir() : preset_dir()
    path = _preset_file(dir, name)
    isnothing(path) && return false
    try
        rows = _CSVRows()
        found = false
        for row in CSV.Rows(path)
            vals = String[String(coalesce(getproperty(row, c), "")) for c in (:Category, :Scope, :Parameter, :Value)]
            if vals[1] == "Metadata" && vals[2] == "Preset" && vals[3] == "description"
                vals[4] = String(desc)
                found = true
            end
            push!(rows.cats, vals[1]); push!(rows.scopes, vals[2]); push!(rows.params, vals[3]); push!(rows.vals, vals[4])
        end
        if !found
            pushfirst!(rows.cats, "Metadata"); pushfirst!(rows.scopes, "Preset")
            pushfirst!(rows.params, "description"); pushfirst!(rows.vals, String(desc))
        end
        _write_rows(path, rows)
        return true
    catch e
        @warn "Could not store the description of preset '$name' in $path." exception = (e, catch_backtrace())
        return false
    end
end

"""
    refresh_preset_registries!()

Registers the visual and simulation presets found on disk (with their descriptions) in the preset lists of the editor.
"""
function refresh_preset_registries!()
    _scan_presets!(manager.presets, preset_dir())
    _scan_presets!(manager.sim_presets, sim_preset_dir())
    return nothing
end

# ------------------------------------------------------------------------------
# Visual presets
# ------------------------------------------------------------------------------

"""
    save_plot_preset(name; description = "")

Saves the current look of the studio—layout, axes and slider positions, camera, labels, exploration options and all UI
styles—as the visual preset `<save path>/Presets/<name>.csv`. Simulation parameters are not included, so the preset
can be applied to any simulation with [`set_plot_preset!`](@ref). Returns `true` on success.
"""
function save_plot_preset(name; description::AbstractString = "")
    sym = _preset_symbol(name)
    if sym === :create_new || isempty(string(sym))
        @warn "Please choose a different preset name."
        return false
    end
    haskey(PRESET_DESCRIPTIONS, sym) && @warn "'$sym' is also the name of a built-in preset, which takes precedence when applying it."
    manager.presets[sym] = _clean_description(description, "User custom preset: $sym")
    saved = save_preset_to_csv(sym, preset_dir())
    _refresh_preset_menu!()
    return saved
end

# ------------------------------------------------------------------------------
# Simulation presets
# ------------------------------------------------------------------------------

"""
    save_sim_preset(name; description = "")

Saves the simulation category of the bound configuration—shared parameters, the active methods and their parameters, the parameter sweep and the reference / post-processing functions—as the simulation preset
`<save path>/Presets/Simulation/<name>.csv`. Nothing visual is stored. Returns `true` on success.

Apply it later with [`set_sim_preset!`](@ref).
"""
function save_sim_preset(name; description::AbstractString = "")
    config = manager.active_config
    if isnothing(config)
        @warn "No simulation configuration is bound (see `set_sim_config!`); nothing to save."
        return false
    end
    sym = _preset_symbol(name)
    if sym === :create_new || isempty(string(sym))
        @warn "Please choose a different preset name."
        return false
    end
    desc = _clean_description(description, "Simulation preset: $sym")
    path = joinpath(sim_preset_dir(), "$(sym).csv")
    try
        rows = _CSVRows()
        add_row!(rows, "Metadata", "Preset", "description", desc)
        add_row!(rows, "Metadata", "Preset", "type", "simulation")
        add_row!(rows, "Metadata", "Preset", "mode", "replace")
        _add_simulation_rows!(rows, config)
        _write_rows(path, rows)
    catch e
        @error "Simulation preset save failed" exception = (e, catch_backtrace())
        return false
    end
    manager.sim_presets[sym] = desc
    _refresh_preset_menu!()
    @info "Simulation preset saved to $path"
    return true
end

"""
    set_sim_preset!(name; mode = nothing)

Applies the simulation preset `<save path>/Presets/Simulation/<name>.csv` to the studio and flags the simulation for
a re-run. Two modes exist:

- `:replace`: the preset defines the whole simulation (shared parameters, methods, active methods, sweep, functions).
  Presets saved with [`save_sim_preset`](@ref) (or the *Save Sim Preset* button) use this mode.
- `:patch`: only the entries in the file change; everything else of the bound configuration is kept. This is the
  default for hand-written files without a `Metadata, Preset, mode` row, e.g. a two-line "high resolution" preset.

`mode` overrides the mode stored in the file. The source files of the bound configuration are always kept.
Returns the new `SimulationConfig` (or `nothing` if the preset was not found).
"""
function set_sim_preset!(name; mode::Union{Nothing, Symbol} = nothing)
    path = _preset_file(sim_preset_dir(), name)
    if isnothing(path)
        @warn "Simulation preset '$name' not found in $(sim_preset_dir())."
        return nothing
    end
    parsed, raw = _read_csv(path)
    if !haskey(parsed, "Simulation")
        @warn "The preset '$name' contains no simulation parameters."
        return nothing
    end

    file_mode = Symbol(lowercase(something(_raw_value(raw, "Metadata", "Preset", "mode"), "patch")))
    apply_mode = something(mode, file_mode)
    apply_mode in (:replace, :patch) || (apply_mode = :patch)

    current = manager.active_config
    config = csv_to_simulation_config(parsed; base = (apply_mode === :patch ? current : nothing))
    isnothing(current) || (config.sources = copy(current.sources))  # the code (solvers) stays as it is
    set_sim_config!(config; snapshot = false)

    manager.sim_presets[Symbol(splitext(basename(path))[1])] = _preset_description(raw, "Custom simulation preset")
    _refresh_preset_menu!()
    @info "Applied simulation preset '$name' ($apply_mode). Press 'Run Simulation' to compute it."
    return config
end

"""
    reset_sim_config!()

Restores the simulation configuration that was last bound with [`set_sim_config!`](@ref) (or loaded from a project
CSV), discarding simulation presets and editor changes applied since. Flags the simulation for a re-run.
"""
function reset_sim_config!()
    base = manager.base_config
    if isnothing(base)
        @warn "There is no baseline simulation configuration to reset to."
        return nothing
    end
    @info "Simulation configuration reset to its baseline. Press 'Run Simulation' to compute it."
    return set_sim_config!(deepcopy(base); snapshot = false)
end
