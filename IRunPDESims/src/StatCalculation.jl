using ProgressMeter
using Random
using StaticArrays
using LinearAlgebra
using Polyester # For @batch

include("StatFunctions.jl")

# ==============================================================================
# --- MAIN PIPELINE (Entry Points) ---
# ==============================================================================

function remove_nan_stats!(stats_dict::Dict)
    keys_to_remove = String[]
    for (name, val) in stats_dict
        # Handle Nested Lagrangian Fields
        if val isa Vector{<:Vector} 
            is_all_nan = all(vec -> all(svec -> any(isnan, svec), vec), val)
        # Handle Eulerian Tensors & Lagrangian Series
        elseif val isa AbstractArray 
            is_all_nan = all(svec -> any(isnan, svec), val)
        # Handle Base Scalars
        elseif val isa SVector 
            is_all_nan = any(isnan, val)
        else
            is_all_nan = false
        end
        
        if is_all_nan
            @info "Removing statistic :$name because all values are NaN (no reference data)."
            push!(keys_to_remove, name)
        end
    end
    
    for k in keys_to_remove; delete!(stats_dict, k); end
end

function calculateAllStats!(sim_data::AbstractSimData, ref_func; kwargs...)
    # 1. Generate full analytical field upfront (NaNs or exact)
    u_ana = isnothing(ref_func) ? generate_nan_reference(sim_data) : generate_analytical_reference(sim_data, ref_func)
    
    # 2. Process all registered statistics dynamically
    for (stat_name, kept_dims) in sim_data.domain.stat_registry
        if stat_name == :Solution; continue end
        res = _calc_stat!(sim_data, u_ana, stat_name)
        if !isnothing(res)
            sim_data.stats[String(stat_name)] = res
        end
    end
    # 3. Cleanup and Save
    #remove_nan_stats!(sim_data.stats)
    saveSimData(sim_data; overwrite=true)
end

# ==============================================================================
# --- EULERIAN STATISTICAL REDUCTIONS ---
# ==============================================================================

function _calc_stat!(sim_data::ESimData{D, DS, M}, u_ana, stat_name::Symbol) where {D, DS, M}
    kept_idx = get_kept_indices(stat_name, sim_data.domain.dim_keys, sim_data.domain.stat_registry)
    
    # Base Case: Pure Scalar (Integrates ALL dimensions out)
    if isempty(kept_idx)
        return calc_stat(Val(stat_name), SVector{0,Float64}(), vec(sim_data.u), vec(u_ana), sim_data.domain)
    end
    
    # Preallocate multi-dimensional output array based on kept dimensions
    out_sz = ntuple(d -> length(sim_data.axes[kept_idx[d]]), length(kept_idx))
    res = Array{SVector{M, Float64}, length(kept_idx)}(undef, out_sz...)
    
    # Generate zero-allocation iterable slices for the dimensions being integrated out
    u_slices = eachslice(sim_data.u, dims=Tuple(kept_idx))
    ana_slices = eachslice(u_ana, dims=Tuple(kept_idx))
    
    # Process each slice over the kept multi-dimensional grid
    @batch for i in eachindex(u_slices)
        I = CartesianIndices(u_slices)[i]
        
        # Build the exact fixed coordinates for this specific slice
        fixed_coords = SVector{length(kept_idx), Float64}(ntuple(d -> sim_data.axes[kept_idx[d]][I[d]], length(kept_idx)))
        
        res[i] = calc_stat(Val(stat_name), fixed_coords, vec(u_slices[i]), vec(ana_slices[i]), sim_data.domain)
    end
    
    return res
end

# ==============================================================================
# --- LAGRANGIAN STATISTICAL REDUCTIONS ---
# ==============================================================================

function _calc_stat!(sim_data::LSimData{D, DS, M}, u_ana, stat_name::Symbol) where {D, DS, M}
    kept_dims = kept_dims = get_kept_dims(stat_name, sim_data.domain.dim_keys, sim_data.domain.stat_registry)
    
    is_series = kept_dims == [:t] || (D == DS && isempty(kept_dims))
    is_field = length(kept_dims) == D
    
    Nt = length(sim_data.t)
    
    if is_series
        res = Vector{SVector{M, Float64}}(undef, Nt)
        @batch for t_idx in 1:Nt
            # Pass 1D time vector if transient, empty vector if static
            fixed = D > DS ? SVector{1, Float64}(sim_data.t[t_idx]) : SVector{0, Float64}()
            
            res[t_idx] = calc_stat(Val(stat_name), fixed, sim_data.u[t_idx], u_ana[t_idx], sim_data.domain)
        end
        return res
        
    elseif is_field
        # Fields keep all space dimensions. calc_stat expects an iterable to integrate,
        # so we pass 1-element tuples `(u,)` which avoids memory allocations while naturally resolving to the point.
        res = Vector{Vector{SVector{M, Float64}}}(undef, Nt)
        @batch for t_idx in 1:Nt
            Np = length(sim_data.x[t_idx])
            res_t = Vector{SVector{M, Float64}}(undef, Np)
            for p_idx in 1:Np
                # Reconstruct full Spacetime position
                fixed = D > DS ? SVector{D, Float64}(sim_data.x[t_idx][p_idx]..., sim_data.t[t_idx]) : SVector{D, Float64}(sim_data.x[t_idx][p_idx]...)
                
                res_t[p_idx] = calc_stat(Val(stat_name), fixed, (sim_data.u[t_idx][p_idx],), (u_ana[t_idx][p_idx],), sim_data.domain)
            end
            res[t_idx] = res_t
        end
        return res
        
    else
        @warn "Statistic :$stat_name requires keeping $kept_dims. Partial spatial integrations are physically undefined for scattered Lagrangian data. Skipping."
        return nothing
    end
end

# ==============================================================================
# --- ANALYTICAL CACHE GENERATOR ---
# ==============================================================================

function generate_nan_reference(data::LSimData{D, DS, M}) where {D, DS, M}
    return [fill(SVector{M, Float64}(NaN), length(x)) for x in data.x]
end

function generate_nan_reference(data::ESimData{D, DS, M}) where {D, DS, M}
    return fill(SVector{M, Float64}(NaN), size(data.u))
end

function generate_analytical_reference(ldata::LSimData{D, DS, M}, ref_func) where {D, DS, M}
    Nt = length(ldata.t)
    u_ana = Vector{Vector{SVector{M, Float64}}}(undef, Nt)
    _ref = ref_func 
    
    @batch for t_idx in 1:Nt
        t_val = ldata.t[t_idx]
        xs = ldata.x[t_idx]
        
        # Conditionally construct pure spatial or spacetime vectors
        if D > DS
            u_ana[t_idx] = [_ref(SVector{D, Float64}(x..., t_val)) for x in xs]
        else
            u_ana[t_idx] = [_ref(SVector{D, Float64}(x...)) for x in xs]
        end
    end
    
    return u_ana
end

function generate_analytical_reference(edata::ESimData{D, DS, M}, ref_func) where {D, DS, M}
    u_ana = similar(edata.u)
    _ref = ref_func
    
    # Directly iterate over the entire Spacetime tensor to build the reference mapping
    @batch for i in eachindex(edata.u)
        I = CartesianIndices(edata.u)[i]
        st = SVector{D, Float64}(ntuple(d -> edata.axes[d][I[d]], Val(D)))
        u_ana[i] = _ref(st)
    end
    
    return u_ana
end

# ==============================================================================
# --- BATCH PROCESSOR ---
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
    
    @showprogress "Calculating Stats..." for params in all_tasks
        sim_data = try loadSimData(params) catch; nothing end
        if !isnothing(sim_data)
            calculateAllStats!(sim_data, ref_func; kwargs...)
        end
    end
end