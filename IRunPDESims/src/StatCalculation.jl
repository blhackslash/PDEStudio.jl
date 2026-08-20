using ProgressMeter
using Random
using StaticArrays
using LinearAlgebra
using Polyester # For @batch

include("StatFunctions.jl")

# ==============================================================================
# --- MAIN PIPELINE (Entry Points) ---
# ==============================================================================

function remove_nan_stats!(stats_dict::StatDict)
    keys_to_remove = Symbol[]
    for (name, val) in stats_dict
        if is_all_nan(val)
            @info "Removing statistic :$name because all values are NaN (no reference data)."
            push!(keys_to_remove, name)
        end
    end
    
    for k in keys_to_remove; delete!(stats_dict, k); end
end
function is_all_nan(val)
    # Handle Nested Lagrangian Fields
    if val isa Vector{<:Vector} 
        return all(vec -> all(svec -> any(isnan, svec), vec), val)
    # Handle Eulerian Tensors & Lagrangian Series
    elseif val isa AbstractArray 
        return all(svec -> any(isnan, svec), val)
    # Handle Base Scalars
    elseif val isa SVector 
        return any(isnan, val)
    else
        return false
    end
end

function calculate_all_stats!(sim_data::AbstractSimData, ref_func; force_overwrite = false, kwargs...)
    # 1. Generate full analytical field upfront (NaNs or exact)
    u_ana = isnothing(ref_func) ? generate_pointwise_nan(sim_data) : generate_pointwise_reference(sim_data, ref_func)
    
    # 2. Process all registered statistics dynamically
    stat_change = false
    for (stat_name, kept_dims) in sim_data.domain.stat_registry
        if stat_name == :Solution; continue end
        if haskey(sim_data.stats, stat_name) && !force_overwrite; continue end
        
        res = _calc_stat!(sim_data, u_ana, stat_name)
        
        if !isnothing(res)
            if !is_all_nan(res)
                # Valid stat calculated
                sim_data.stats[stat_name] = res
                stat_change = true
            else
                # If it evaluates to NaNs but previously existed (force_overwrite),
                # we delete it to maintain consistency and flag the change.
                if haskey(sim_data.stats, stat_name)
                    delete!(sim_data.stats, stat_name)
                    stat_change = true
                end
            end
        end
    end
    
    # 3. Cleanup and Save
    remove_nan_stats!(sim_data.stats)
    save_sim_data(sim_data; overwrite=stat_change)
end

# ==============================================================================
# --- EULERIAN STATISTICAL REDUCTIONS ---
# ==============================================================================

function _calc_stat!(sim_data::ESimData{D, DS, M, T}, u_ana, stat_name::Symbol) where {D, DS, M, T}
    kept_idx = get_kept_indices(stat_name, sim_data.domain)
    
    if isempty(kept_idx)
        return calc_stat(Val(stat_name), SVector{0, T}(), vec(sim_data.u), vec(u_ana), sim_data.domain)
    end
    
    out_sz = ntuple(d -> length(sim_data.axes[kept_idx[d]]), length(kept_idx))
    res = Array{SVector{M, T}, length(kept_idx)}(undef, out_sz...)
    
    u_slices = eachslice(sim_data.u, dims=Tuple(kept_idx))
    ana_slices = eachslice(u_ana, dims=Tuple(kept_idx))
    
    @batch for i in eachindex(u_slices)
        I = CartesianIndices(u_slices)[i]
        fixed_coords = SVector{length(kept_idx), T}(ntuple(d -> sim_data.axes[kept_idx[d]][I[d]], length(kept_idx)))
        res[i] = calc_stat(Val(stat_name), fixed_coords, vec(u_slices[i]), vec(ana_slices[i]), sim_data.domain)
    end
    
    return res
end

# ==============================================================================
# --- LAGRANGIAN STATISTICAL REDUCTIONS ---
# ==============================================================================

function _calc_stat!(sim_data::LSimData{D, DS, M, T}, u_ana, stat_name::Symbol) where {D, DS, M, T}
    kept_dims = get_kept_dims(stat_name, sim_data.domain)
    
    is_series = kept_dims == [sim_data.domain.time_dim] || (D == DS && isempty(kept_dims))
    is_field = length(kept_dims) == D
    Nt = length(sim_data.t)
    
    if is_series
        res = Vector{SVector{M, T}}(undef, Nt)
        @batch for t_idx in 1:Nt
            fixed = D > DS ? SVector{1, T}(sim_data.t[t_idx]) : SVector{0, T}()
            res[t_idx] = calc_stat(Val(stat_name), fixed, sim_data.u[t_idx], u_ana[t_idx], sim_data.domain)
        end
        return res
        
    elseif is_field
        res = Vector{Vector{SVector{M, T}}}(undef, Nt)
        @batch for t_idx in 1:Nt
            Np = length(sim_data.x[t_idx])
            res_t = Vector{SVector{M, T}}(undef, Np)
            for p_idx in 1:Np
                fixed = D > DS ? SVector{D, T}(sim_data.x[t_idx][p_idx]..., sim_data.t[t_idx]) : SVector{D, T}(sim_data.x[t_idx][p_idx]...)
                res_t[p_idx] = calc_stat(Val(stat_name), fixed, (sim_data.u[t_idx][p_idx],), (u_ana[t_idx][p_idx],), sim_data.domain)
            end
            res[t_idx] = res_t
        end
        return res
    end
end

# ==============================================================================
# --- ANALYTICAL CACHE GENERATOR ---
# ==============================================================================

function generate_pointwise_nan(data::LSimData{D, DS, M, T}) where {D, DS, M, T}
    return [fill(SVector{M, T}(ntuple(_ -> T(NaN), M)), length(x)) for x in data.x]
end

function generate_pointwise_nan(data::ESimData{D, DS, M, T}) where {D, DS, M, T}
    return fill(SVector{M, T}(ntuple(_ -> T(NaN), M)), size(data.u))
end

function generate_pointwise_reference(ldata::LSimData{D, DS, M, T}, ref_func) where {D, DS, M, T}
    Nt = length(ldata.t)
    u_ana = Vector{Vector{SVector{M, T}}}(undef, Nt)
    _ref = ref_func 
    
    @batch for t_idx in 1:Nt
        t_val = ldata.t[t_idx]
        xs = ldata.x[t_idx]
        if D > DS
            u_ana[t_idx] = [_ref(SVector{D, T}(x..., t_val)) for x in xs]
        else
            u_ana[t_idx] = [_ref(SVector{D, T}(x...)) for x in xs]
        end
    end
    return u_ana
end

function generate_pointwise_reference(edata::ESimData{D, DS, M, T}, ref_func) where {D, DS, M, T}
    u_ana = similar(edata.u)
    _ref = ref_func
    
    @batch for i in eachindex(edata.u)
        I = CartesianIndices(edata.u)[i]
        st = SVector{D, T}(ntuple(d -> edata.axes[d][I[d]], Val(D)))
        u_ana[i] = _ref(st)
    end
    return u_ana
end


# ==============================================================================
# --- BATCH PROCESSOR ---
# ==============================================================================

calculate_all_stats!(::NoSimData, kwargs...) = return

"""
    calculate_all_stats!(sim_config::SimulationConfig; kwargs...)

Batch calculates statistics for all simulations defined in a `SimulationConfig`.
Executes sequentially to avoid I/O bottlenecks and allow internal mathematical threading.
"""
function calculate_all_stats!(
    sim_config::SimulationConfig;
    varied_params::VariedDict = sim_config.varied_params,
    fixed_params::ParamDict = ParamDict(),
    kwargs...
)
    active_keys = collect(keys(varied_params))
    active_values = collect(values(varied_params))
    all_tasks = Vector{ParamDict}()
    
    for method in sim_config.active_methods
        if is_reference_method(method); continue end
        base_params = IRunPDESims.assemble_params(sim_config.shared_params, sim_config.methods_dict, method)
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
    
    @showprogress "Calculating Stats..." for params in all_tasks
        sim_data = try load_sim_data(params) catch; nothing end
        if !isnothing(sim_data)
            calculate_all_stats!(sim_data, ref_func; kwargs...)
        end
    end
end