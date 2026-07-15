using ProgressMeter
using Random
using StaticArrays
using LinearAlgebra


include("StatFunctions.jl")
# ==============================================================================
# --- MAIN PIPELINE (Entry Points) ---
# ==============================================================================

function calculateAllStats!(sim_data, ref_func; stats_to_calculate, kwargs...)
    # 1. Initialize buckets for our different categories
    series_stats  = Symbol[]
    profile_stats = Symbol[]
    field_stats   = Symbol[]
    
    # 2. Sort the requested stats using the Trait
    for stat in stats_to_calculate
        cat = stat_category(Val(stat))
        
        if cat === Val(:series)
            push!(series_stats, stat)
        elseif cat === Val(:profile)
            push!(profile_stats, stat)
        elseif cat === Val(:field)
            push!(field_stats, stat)
        else
            @warn "Statistic :$stat is not registered or has an unknown category. Skipping."
        end
    end
    
    # 3. Pre-allocate the master stats dictionary if it doesn't exist
    if isnothing(sim_data.stats)
        sim_data.stats = Dict{String, Any}()
    end
    
    # 4. Dispatch to the specific loopers ONLY if they have work to do
    if !isempty(series_stats)
        _calculate_category!(Val(:series), sim_data, ref_func; stats=series_stats, kwargs...)
    end
    
    if !isempty(profile_stats)
        _calculate_category!(Val(:profile), sim_data, ref_func; stats=profile_stats, kwargs...)
    end
    
    saveSimData(sim_data; overwrite=true)
end

function _calculate_category!(::Val{:series}, sim_data, ref_func; stats, field_key="u", ana_cache=nothing, kwargs...)
    D = Val(IRunPDESims._get_D(sim_data)) 
    Nt = length(sim_data.t)
    
    # Dynamically infer M from the SVector element type of the main data array
    M = length(eltype(sim_data.u)) 
    
    stat_vals = _build_stat_tuple(stats)
    
    # Pre-allocate SVector time-series locally
    res = Dict{String, Vector{SVector{M, Float64}}}()
    for stat in stats
        res[String(stat)] = Vector{SVector{M, Float64}}(undef, Nt)
    end
    
    _compute_series_loop!(res, stat_vals, D, Val(M), Nt, sim_data, field_key, ref_func, ana_cache)
    
    merge!(sim_data.stats, res)
end
function _calculate_category!(::Val{:field}, sim_data, ref_func; stats, field_key="u", ana_cache=nothing, kwargs...)
    D = Val(IRunPDESims._get_D(sim_data)) 
    Nt = length(sim_data.t)
    
    stat_vals = _build_stat_tuple(stats)
    
    res = Dict{String, typeof(sim_data.u)}()
    for stat in stats
        res[String(stat)] = similar(sim_data.u)
    end
    
    _compute_field_loop!(res, stat_vals, D, Nt, sim_data, field_key, ref_func, ana_cache)
    
    merge!(sim_data.fields, res)
end

function _compute_field_loop!(res, stat_vals::Tuple, D, Nt, sim_data, field_key, ref_func, ana_cache)
    @batch for t_idx in 1:Nt
        xs, u_raw, dV = extract_point_cloud(sim_data, field_key, t_idx)
        t_current = sim_data.t[t_idx]
        
        ana_vals, err_vals = nothing, nothing
        if !isnothing(ref_func)
            ana_vals = _get_analytical_for_timestep(ref_func, sim_data, t_idx, ana_cache) 
            if !isnothing(ana_vals)
                err_vals = u_raw .- ana_vals
            end
        end
        
        for stat_val in stat_vals
            stat_name = _get_stat_name(stat_val)
            # For a field category, calc_stat returns an Array of SVectors representing this timestep
            field_slice = calc_stat(stat_val, D, t_current, xs, u_raw, dV, ana_vals, err_vals)
            
            _insert_field_slice!(res[stat_name], field_slice, t_idx)
        end
    end
end

_insert_field_slice!(target::Array, slice, t_idx) = selectdim(target, ndims(target), t_idx) .= slice
_insert_field_slice!(target::Vector{Vector}, slice, t_idx) = target[t_idx] = slice

# 1. Lagrangian Interceptor
function _calculate_category!(::Val{:profile}, ldata::LSimData{D, M}, ref_func; stats, kwargs...) where {D, M}
    @info "Profile stats requested on Lagrangian data. Loading/generating Eulerian grid..."
    plot_key = "sim_data_plot_$(_N_GRID[])_$(_T_GRID[])"
    
    # MAGIC: This triggers conversion automatically if it's missing!
    edata = loadSimData(ldata.params; data_key=plot_key) 
    
    # Send it to the Eulerian profile calculator
    _calculate_category!(Val(:profile), edata, ref_func; stats=stats, kwargs...)
    
    # Push the computed profiles back into the Lagrangian struct so the user has them
    merge!(ldata.profiles, edata.profiles)
end

# 2. Eulerian Setup
function _calculate_category!(::Val{:profile}, edata::ESimData{D, M}, ref_func; stats, field_key="u", ana_cache=nothing, kwargs...) where {D, M}
    grid_shape = ntuple(d -> length(edata.x[d]), Val(D))
    stat_vals = _build_stat_tuple(stats)
    
    res = Dict{String, Array{SVector{M, Float64}, D}}()
    for stat in stats
        res[String(stat)] = fill(zero(SVector{M, Float64}), grid_shape)
    end
    
    _compute_profile_loop!(res, stat_vals, edata, grid_shape, field_key)
    
    merge!(edata.profiles, res)
    # Save the Eulerian data so the profiles persist on disk
    saveSimData(edata; data_key="sim_data_plot_$(_N_GRID[])_$(_T_GRID[])", overwrite=true) 
end

# 3. Eulerian Worker Loop
function _compute_profile_loop!(res, stat_vals::Tuple, edata::ESimData{D, M}, grid_shape, field_key) where {D, M}
    Nt = length(edata.t)
    u_tensor = field_key == "u" ? edata.u : edata.fields[field_key]
    
    @batch for idx in CartesianIndices(grid_shape)
        # Extract the time-history for this exact spatial point
        point_series = [u_tensor[idx, t] for t in 1:Nt] # USE VIEWS!!!!!!
        
        for stat_val in stat_vals
            stat_name = _get_stat_name(stat_val)
            # For a profile category, calc_stat collapses the time vector into a single SVector
            res[stat_name][idx] = calc_stat(stat_val, D, edata.t, point_series)
        end
    end
end

function _compute_series_loop!(res, stat_vals::Tuple, D, ::Val{M}, Nt, sim_data, field_key, ref_func, ana_cache) where M
    @batch for t_idx in 1:Nt
        # 1. Extract the full SVector array for this timestep
        xs, u_raw, dV = extract_point_cloud(sim_data, field_key, t_idx)
        
        ana_vals, err_vals = nothing, nothing
        if !isnothing(ref_func)
            ana_vals = _get_analytical_for_timestep(ref_func, sim_data, t_idx, ana_cache) 
            if !isnothing(ana_vals)
                # Native array-of-SVectors broadcasting!
                err_vals = u_raw .- ana_vals 
            end
        end
        
        t_current = sim_data.t[t_idx] # <-- Get the current time
        
        for stat_val in stat_vals
            stat_name = _get_stat_name(stat_val)
            res[stat_name][t_idx] = calc_stat(stat_val, D, t_current, xs, u_raw, dV, ana_vals, err_vals)
        end
    end
end
# ==============================================================================
# --- DATA NORMALIZATION (Time-Aware Point Cloud Extractors) ---
# ==============================================================================

function extract_point_cloud(data::ESimData{N, M}, field_key, t_idx) where {N, M}
    dx = ntuple(d -> length(data.x[d]) > 1 ? data.x[d][2] - data.x[d][1] : 1.0, Val(N))
    dV = prod(dx)
    
    xs = vec([SVector{N, Float64}(Tuple(I.I)...) for I in CartesianIndices(ntuple(d -> length(data.x[d]), Val(N)))])
    
    # Returns an array of SVector{M, Float64}
    u_raw = field_key == "u" ? selectdim(data.u, N+1, t_idx) : selectdim(data.fields[field_key], N+1, t_idx)
    
    return xs, u_raw, dV
end

function extract_point_cloud(data::LSimData{N, M}, field_key, t_idx) where {N, M}
    xs = data.x[t_idx] 
    dV = data.dV[t_idx] 
    
    # Returns an array of SVector{M, Float64}
    u_raw = field_key == "u" ? data.u[t_idx] : data.fields[field_key][t_idx]
    
    return xs, u_raw, dV
end


# ==============================================================================
# --- ANALYTICAL CACHE GENERATOR ---
# ==============================================================================

function _get_analytical_for_timestep(ref_func, sim_data, t_idx, ana_cache)
    t_val = sim_data.t[t_idx]
    
    if !isnothing(ana_cache) && haskey(ana_cache, t_val)
        return ana_cache[t_val]
    end
    
    ana_vals = Base.invokelatest(ref_func, sim_data, t_idx)
    
    if !isnothing(ana_cache) && !isnothing(ana_vals)
        ana_cache[t_val] = ana_vals
    end
    
    return ana_vals
end
# ==============================================================================
# --- SECTION 3: MAIN API & REFERENCE GENERATORS ---
# ==============================================================================
calculateAllStats!(::NoSimData, kwargs...) = return

"""
    calculateAllStats!(sim_config::SimulationConfig; kwargs...)

Batch calculates statistics for all simulations defined in a `SimulationConfig`.
Executes sequentially to avoid I/O bottlenecks and allow internal mathematical threading.
"""
function calculateAllStats!(
    sim_config::SimulationConfig;
    active_methods::Vector{String} = sim_config.default_methods,
    varied_params::VariedDict = sim_config.varied_params,
    fixed_params::ParamDict = ParamDict(),
    stats_to_calculate::Vector{Symbol} = [:mass, :l2error, :l2norm], # Default stats if none provided
    kwargs...
)
    active_keys = collect(keys(varied_params))
    active_values = collect(values(varied_params))
    all_tasks = Vector{ParamDict}()
    
    # 1. Generate all task parameters
    for method in active_methods
        if contains(safe_string(method), "analytic") || contains(safe_string(method), "reference"); continue end
        base_params = IRunPDESims.assembleParams(sim_config.shared_params, sim_config.methods_dict, method)
        ignore_keys = IRunPDESims.get_ignore_keys(sim_config.methods_dict, method)
        tasks, _ = generate_method_tasks(base_params, active_keys, active_values, fixed_params; ignore_keys=ignore_keys)
        append!(all_tasks, tasks)
    end
    
    num_tasks = length(all_tasks)
    if num_tasks == 0
        @info "No simulations found to calculate stats for."
        return
    end
    
    @info "Calculating stats sequentially for $num_tasks simulations..."
    
    ref_func = sim_config.reference_func
    
    # 2. Sequential Processing Loop (Internal Math can be threaded!)
    @showprogress "Calculating Stats..." for params in all_tasks
        # Safely try to load the data (fails silently if file is missing)
        sim_data = try loadSimData(params) catch; nothing end
        
        if !isnothing(sim_data)
            # Route directly into the new StatCalculation architecture
            calculateAllStats!(
                sim_data, 
                ref_func; 
                stats_to_calculate = stats_to_calculate, 
                kwargs...
            )
        end
    end
end