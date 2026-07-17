using ProgressMeter
using Random
using StaticArrays
using LinearAlgebra


include("StatFunctions.jl")
# ==============================================================================
# --- MAIN PIPELINE (Entry Points) ---
# ==============================================================================
# Converts runtime symbols into compile-time Val tuples for zero-allocation hot loops
_build_stat_tuple(stats::Vector{Symbol}) = Tuple(Val(s) for s in stats)

# Extracts the string name back out of the compile-time Val type
_get_stat_name(::Val{S}) where S = String(S)

function remove_nan_stats!(res::Dict)
    for (name, val) in res
        # Check if every single element in the stat result is NaN
        # We use `any(!isnan, ...)` to find if there is at least one valid number
        is_all_nan = all(svec -> any(isnan, svec), val)
        
        if is_all_nan
            @info "Removing statistic :$name because all values are NaN (no reference data)."
            delete!(res, name)
        end
    end
end

function calculateAllStats!(sim_data, ref_func; kwargs...)
    series_stats, profile_stats, field_stats = Symbol[], Symbol[], Symbol[]
    
    for stat in keys(STAT_REGISTRY)
        cat = get(STAT_REGISTRY, stat, :unknown)
        if cat === :series; push!(series_stats, stat)
        elseif cat === :profile; push!(profile_stats, stat)
        elseif cat === :field; push!(field_stats, stat)
        end
    end
    
    # --- THE NEW LOGIC: Generate full analytical field upfront ---
    u_ana = nothing
    if !isnothing(ref_func)
        @info "Pre-computing analytical reference field..."
        u_ana = generate_analytical_reference(sim_data, ref_func)
    else
        @info "No reference function provided. Initializing analytical cache with NaNs..."
        # We generate a "NaN-tensor" that matches the shape of the simulation data
        u_ana = generate_nan_reference(sim_data)
    end
    
    if !isempty(series_stats)
        _calculate_category!(Val(:series), sim_data, u_ana; stats=series_stats, kwargs...)
    end
    if !isempty(field_stats)
        _calculate_category!(Val(:field), sim_data, u_ana; stats=field_stats, kwargs...)
    end
    if !isempty(profile_stats)
        _calculate_category!(Val(:profile), sim_data, u_ana; stats=profile_stats, kwargs...)
    end
    
    saveSimData(sim_data; overwrite=true)
end

function _calculate_category!(::Val{:series}, sim_data::AbstractSimData{D,M}, u_ana; stats, field_key="u", kwargs...) where {D,M}
    Nt = length(sim_data.t)
    stat_vals = _build_stat_tuple(stats)
    
    res = Dict{String, Vector{SVector{M, Float64}}}()
    for stat in stats
        res[String(stat)] = Vector{SVector{M, Float64}}(undef, Nt)
    end
    
    # Cleaned up call:
    _compute_series_loop!(res, stat_vals, Nt, sim_data, field_key, u_ana)

    remove_nan_stats!(res)

    merge!(sim_data.series, res)
end

function _calculate_category!(::Val{:field}, sim_data::AbstractSimData{D,M}, u_ana; stats, field_key="u", kwargs...) where {D,M}
    Nt = length(sim_data.t)
    stat_vals = _build_stat_tuple(stats)
    
    res = Dict{String, typeof(sim_data.u)}()
    for stat in stats; res[String(stat)] = similar(sim_data.u); end
    
    # Cleaned up call:
    _compute_field_loop!(res, stat_vals, Nt, sim_data, field_key, u_ana)

    remove_nan_stats!(res)

    merge!(sim_data.fields, res)
end

function _calculate_category!(::Val{:profile}, edata::ESimData{D, M}, u_ana; stats, field_key="u", kwargs...) where {D, M}
    grid_shape = ntuple(d -> length(edata.x[d]), Val(D))
    stat_vals = _build_stat_tuple(stats)
    
    res = Dict{String, Array{SVector{M, Float64}, D}}()
    for stat in stats; res[String(stat)] = fill(zero(SVector{M, Float64}), grid_shape); end
    
    # Cleaned up call:
    _compute_profile_loop!(res, stat_vals, edata, grid_shape, field_key, u_ana)

    remove_nan_stats!(res)

    merge!(edata.profiles, res)
end

function _calculate_category!(::Val{:profile}, ldata::LSimData{D, M}, u_ana; stats, field_key="u", kwargs...) where {D, M}
    edata = loadSimData(ldata.params,Val(:conv))
    grid_shape = ntuple(d -> length(edata.x[d]), Val(D))
    stat_vals = _build_stat_tuple(stats)
    
    res = Dict{String, Array{SVector{M, Float64}, D}}()
    for stat in stats; res[String(stat)] = fill(zero(SVector{M, Float64}), grid_shape); end
    
    # Cleaned up call:
    _compute_profile_loop!(res, stat_vals, edata, grid_shape, field_key, u_ana)
    
    remove_nan_stats!(res)
    
    merge!(edata.profiles, res)

    saveSimData(edata)
end

# ------------------------------------------------------------------------------
# 1. SERIES LOOP
# ------------------------------------------------------------------------------
function _compute_series_loop!(res, stat_vals::Tuple, Nt, sim_data::AbstractSimData{D, M}, field_key, u_ana) where {D,M}
    @batch for t_idx in 1:Nt
        xs, u_raw, dV = extract_point_cloud(sim_data, field_key, t_idx)
        t_current = sim_data.t[t_idx] 
        
        ana_vals = nothing
        if !isnothing(u_ana)
            _, ana_vals, _ = extract_point_cloud(sim_data, u_ana, t_idx) 
        end
        
        for stat_val in stat_vals
            stat_name = _get_stat_name(stat_val)
            # Note the Val(D) injection here
            res[stat_name][t_idx] = calc_stat(stat_val, Val(D), t_current, xs, u_raw, dV, ana_vals)
        end
    end
end

# ------------------------------------------------------------------------------
# 2. FIELD LOOP
# ------------------------------------------------------------------------------
function _compute_field_loop!(res, stat_vals::Tuple, Nt, sim_data::AbstractSimData{D, M}, field_key, u_ana) where {D, M}
    @batch for t_idx in 1:Nt
        xs, u_raw, dV = extract_point_cloud(sim_data, field_key, t_idx)
        t_current = sim_data.t[t_idx]
        
        ana_slice = nothing
        if !isnothing(u_ana)
            _, ana_slice, _ = extract_point_cloud(sim_data, u_ana, t_idx) 
        end
        
        for stat_val in stat_vals
            stat_name = _get_stat_name(stat_val)
            
            if sim_data isa ESimData
                out_slice = selectdim(res[stat_name], ndims(res[stat_name]), t_idx)
            else
                out_slice = Vector{eltype(u_raw)}(undef, length(xs))
                res[stat_name][t_idx] = out_slice
            end
            
            for i in eachindex(xs)
                x_i = xs[i]
                u_i = u_raw[i]
                ana_i = isnothing(ana_slice) ? nothing : ana_slice[i]
                
                # Note the Val(D) injection here
                out_slice[i] = calc_stat(stat_val, Val(D), t_current, x_i, u_i, dV, ana_i)
            end
        end
    end
end

# ------------------------------------------------------------------------------
# 3. PROFILE LOOP 
# ------------------------------------------------------------------------------
function _compute_profile_loop!(res, stat_vals::Tuple, edata::ESimData{D, M}, grid_shape, field_key, u_ana) where {D, M}
    Nt = length(edata.t)
    u_tensor = field_key == "u" ? edata.u : edata.fields[field_key]
    
    @batch for idx in CartesianIndices(grid_shape)
        point_series = @views [u_tensor[idx, t] for t in 1:Nt] 
        ana_series   = isnothing(u_ana) ? nothing : @views [u_ana[idx, t] for t in 1:Nt]
        
        for stat_val in stat_vals
            stat_name = _get_stat_name(stat_val)
            # Note the Val(D) injection here, and removed the trailing u_ana!
            res[stat_name][idx] = calc_stat(stat_val, Val(D), edata.t, point_series, ana_series)
        end
    end
end
# ==============================================================================
# --- DATA NORMALIZATION (Time-Aware Point Cloud Extractors) ---
# ==============================================================================

# ------------------------------------------------------------------
# Standard Extractors (Using field_key)
# ------------------------------------------------------------------
function extract_point_cloud(data::ESimData{N, M}, field_key::String, t_idx) where {N, M}
    target_tensor = field_key == "u" ? data.u : data.fields[field_key]
    return extract_point_cloud(data, target_tensor, t_idx)
end

function extract_point_cloud(data::LSimData{N, M}, field_key::String, t_idx) where {N, M}
    target_tensor = field_key == "u" ? data.u : data.fields[field_key]
    return extract_point_cloud(data, target_tensor, t_idx)
end

# ------------------------------------------------------------------
# Direct Tensor Extractors (Used for both Sim Data AND Analytical Data!)
# ------------------------------------------------------------------
function extract_point_cloud(data::ESimData{N, M}, target_tensor::AbstractArray, t_idx) where {N, M}
    dx = ntuple(d -> length(data.x[d]) > 1 ? data.x[d][2] - data.x[d][1] : 1.0, Val(N))
    dV = prod(dx)
    
    # BUG FIX: Map Cartesian index 'I' to the actual physical coordinates in data.x
    xs = vec([SVector{N, Float64}(ntuple(dim -> data.x[dim][I[dim]], Val(N))) 
              for I in CartesianIndices(ntuple(d -> length(data.x[d]), Val(N)))])
    
    u_raw = selectdim(target_tensor, N+1, t_idx)
    return xs, u_raw, dV
end

function extract_point_cloud(data::LSimData{N, M}, target_tensor::AbstractArray, t_idx) where {N, M}
    xs = data.x[t_idx] 
    
    N_particles = length(xs)
    if N_particles > 0
        V_total = prod(ntuple(d -> data.xmaxs[d] - data.xmins[d], Val(N)))
        dV = V_total / N_particles
    else
        dV = 0.0
    end
    
    u_raw = target_tensor[t_idx]
    return xs, u_raw, dV
end
# ==============================================================================
# --- ANALYTICAL CACHE GENERATOR ---
# ==============================================================================
function generate_nan_reference(data::LSimData{D, M}) where {D, M}
    # Create a vector of vectors filled with NaN SVectors
    return [fill(SVector{M, Float64}(NaN), length(x)) for x in data.x]
end

function generate_nan_reference(data::ESimData{D, M}) where {D, M}
    # Create an array of the same shape as data.u filled with NaN SVectors
    return fill(SVector{M, Float64}(NaN), size(data.u))
end
function generate_analytical_reference(ldata::LSimData{D, M}, ref_func) where {D, M}
    Nt = length(ldata.t)
    u_ana = Vector{Vector{SVector{M, Float64}}}(undef, Nt)
    
    # FIX: Alias the function to guarantee Polyester captures it safely
    _ref = ref_func 
    
    @batch for t_idx in 1:Nt
        t_val = ldata.t[t_idx]
        xs = ldata.x[t_idx]
        
        # FIX: Use list comprehension instead of map() inside @batch
        u_ana[t_idx] = [_ref(x, t_val) for x in xs]
    end
    
    return u_ana
end

function generate_analytical_reference(edata::ESimData{D, M}, ref_func) where {D, M}
    Nt = length(edata.t)
    grid_shape = ntuple(d -> length(edata.x[d]), Val(D))
    u_ana = similar(edata.u)
    
    xs = vec([SVector{D, Float64}(ntuple(dim -> edata.x[dim][I[dim]], Val(D))) 
              for I in CartesianIndices(grid_shape)])
              
    # FIX: Alias the function
    _ref = ref_func
    
    @batch for t_idx in 1:Nt
        t_val = edata.t[t_idx]
        
        # FIX: Use list comprehension instead of map() inside @batch
        ana_slice = [_ref(x, t_val) for x in xs]
        
        selectdim(u_ana, D+1, t_idx) .= reshape(ana_slice, grid_shape)
    end
    
    return u_ana
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
                kwargs...
            )
        end
    end
end