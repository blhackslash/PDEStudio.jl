using ProgressMeter
using Random
using StaticArrays
using LinearAlgebra

# ==============================================================================
# --- MAIN PIPELINE (Entry Points) ---
# ==============================================================================

function calculateAllStats!(sim_data, ref_func; stats_to_calculate, kwargs...)
    calculate_stats!(Val(:series), sim_data, ref_func; stats_to_calculate=stats_to_calculate, kwargs...)
    
    saveSimData(sim_data; overwrite=true)
end

function calculate_stats!(::Val{:series}, sim_data, ref_func; stats_to_calculate, field_key="u", comp_idx=1, ana_cache=nothing, kwargs...)
    D = Val(IRunPDESims._get_D(sim_data)) 
    Nt = length(sim_data.t)
    
    res = Dict{String, Vector{Float64}}()
    for stat in stats_to_calculate
        res[String(stat)] = zeros(Float64, Nt)
    end
    
    @batch for t_idx in 1:Nt
        xs, u_clean, dV = extract_point_cloud(sim_data, field_key, comp_idx, t_idx)
        
        ana_vals, err_vals = nothing, nothing
        if !isnothing(ref_func)
            ana_vals = _get_analytical_for_timestep(ref_func, sim_data, t_idx, ana_cache) 
            if !isnothing(ana_vals)
                ana_clean = _isolate_component(ana_vals, comp_idx)
                err_vals = u_clean .- ana_clean
            end
        end
        
        for stat in stats_to_calculate
            res[String(stat)][t_idx] = calc_stat(Val(Symbol(stat)), D, xs, u_clean, dV, ana_vals, err_vals)
        end
    end
    
    # --- THE FIX: NaN Cleanup Filter ---
    # Remove any statistic that failed to calculate across the entire time series (e.g., missing analytical ref)
    for (stat_name, stat_array) in collect(res)
        if all(isnan, stat_array)
            delete!(res, stat_name)
        end
    end
    
    if isnothing(sim_data.stats)
        sim_data.stats = res
    else
        merge!(sim_data.stats, res)
    end
end


# ==============================================================================
# --- DATA NORMALIZATION (Time-Aware Point Cloud Extractors) ---
# ==============================================================================

function extract_point_cloud(data::ESimData{N}, field_key, comp_idx, t_idx) where N
    dx = ntuple(d -> length(data.axes[d]) > 1 ? data.axes[d][2] - data.axes[d][1] : 1.0, Val(N))
    dV = prod(dx)
    
    xs = vec([SVector{N, Float64}(Tuple(I.I)...) for I in CartesianIndices(data.axes)])
    
    u_raw = field_key == "u" ? data.u[t_idx] : data.fields[field_key][t_idx]
    u_clean = _isolate_component(u_raw, comp_idx)
    
    return xs, u_clean, dV
end

function extract_point_cloud(data::LSimData{N}, field_key, comp_idx, t_idx) where N
    xs = data.x[t_idx] 
    dV = data.dV[t_idx] 
    
    u_raw = field_key == "u" ? data.u[t_idx] : data.fields[field_key][t_idx]
    u_clean = _isolate_component(u_raw, comp_idx)
    
    return xs, u_clean, dV
end

function _isolate_component(u_raw, comp_idx::Int)
    u_flat = eltype(u_raw) <: AbstractArray ? [v[comp_idx] for v in vec(u_raw)] : vec(u_raw)
    return replace(u_flat, NaN => 0.0)
end


# ==============================================================================
# --- MATH DISPATCH (Using the 'Nothing' router!) ---
# ==============================================================================

# 1. Ultimate Fallback (If no matching method exists, it safely returns NaN)
calc_stat(stat::Val, D::Val, args...) = NaN 

# 2. The Router (If analytical refs are missing, drop them and try to find a 5-argument method)
calc_stat(stat::Val, D::Val, xs, u, dV, ::Nothing, ::Nothing) = calc_stat(stat, D, xs, u, dV)

# ---------------------------------------------------------
# NO-REFERENCE METRICS (5 Arguments)
# ---------------------------------------------------------
calc_stat(::Val{:mass},   ::Val, xs, u, dV) = sum(u .* dV)
calc_stat(::Val{:l1norm}, ::Val, xs, u, dV) = sum(abs.(u) .* dV)
calc_stat(::Val{:l2norm}, ::Val, xs, u, dV) = sqrt(sum(abs2.(u) .* dV))
calc_stat(::Val{:wave_height}, ::Val, xs, u, dV) = maximum(u)

function calc_stat(::Val{:wave_position}, ::Val{1}, xs, u, dV)
    _, max_idx = findmax(u)
    return xs[max_idx][1] 
end

# ---------------------------------------------------------
# ERROR METRICS (7 Arguments - Strictly requires reference)
# ---------------------------------------------------------
calc_stat(::Val{:l1error}, ::Val, xs, u, dV, ana, err) = sum(abs.(err) .* dV)
calc_stat(::Val{:l2error}, ::Val, xs, u, dV, ana, err) = sqrt(sum(abs2.(err) .* dV))
function calc_stat(::Val{:relative_mass}, ::Val, xs, u ,dV, ana, err)
    m_ana = abs(sum(ana .* dV)) 
    res = m_ana < 10^-9 ? NaN : sum(u .* dV)/sum(ana .* dV)
    return res
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