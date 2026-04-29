using ProgressMeter
using Random
using StaticArrays
using LinearAlgebra

# ==============================================================================
# --- SECTION 1: EULERIAN UNIFICATION (Dense Tensors with NaN Padding) ---
# ==============================================================================

"""
    calculateAllStats!(::LSimData, ...)

Interceptor for Lagrangian data. Converts to Eulerian (or loads cache) 
before calculating stats, massively simplifying the integration logic.
"""
function calculateAllStats!(
    sim_data::LSimData,
    ref_func::Union{Function, Nothing} = nothing;
    stats_to_calculate::Union{Symbol, Vector{Symbol}} = [:series],
    kwargs...
)
    N_grid = _LAGRANGE_N_GRID[]

    @info "Lagrangian data detected. Searching for Eulerian conversion (N >= $N_grid) for stats..."
    conv_data = try 
        loadBestConversion(sim_data.params, N_grid) 
    catch 
        @info "No suitable conversion found. Generating new ESimData at N=$N_grid..."
        converted = convert_to_eulerian(sim_data, N_grid)
        # THE FIX: Save as a new field in the existing file
        saveSimData(converted; data_key="sim_data_plot_$(N_grid)", overwrite=true)
        converted
    end
    
    # We no longer need to pass suffixes around! We just save it back to the specific plot key.
    target_key = "sim_data_plot_$(size(conv_data.u, 2))"
    calculateAllStats!(conv_data, ref_func; stats_to_calculate=stats_to_calculate, data_key=target_key, kwargs...)
end

# ==============================================================================
# --- SECTION 2: THE MATHEMATICAL WORKERS (Discrete Riemann Sums) ---
# ==============================================================================

function _calc_series_no_ref(::Val{D}, u_valid, axes) where {D}
    res = Dict{String, Float64}()
    
    # Calculate cell volume
    dx = ntuple(d -> length(axes[d]) > 1 ? axes[d][2] - axes[d][1] : 1.0, Val(D))
    dV = prod(dx)

    # Clean NaNs from empty Eulerian space
    u_clean = replace(u_valid, NaN => 0.0)

    # 1. Pure Discrete Integration
    res["mass"] = sum(u_clean) * dV
    res["l1norm"] = sum(abs, u_clean) * dV
    res["l2norm"] = sqrt(sum(abs2, u_clean) * dV)

    # 2. Extract Wave Height & Position natively
    h_num, linear_idx = findmax(replace(u_valid, NaN => -Inf))
    res["wave_height"] = h_num
    
    idx = CartesianIndices(u_valid)[linear_idx]
    if D == 1
        res["wave_position"] = axes[1][idx[1]]
    elseif D >= 2
        res["wave_position_x"] = axes[1][idx[1]]
        res["wave_position_y"] = axes[2][idx[2]]
        if D == 3
            res["wave_position_z"] = axes[3][idx[3]]
        end
    end

    return res
end

function _calc_series_with_ref(::Val{D}, u_valid, ana_vals, axes) where {D}
    res = Dict{String, Float64}()
    
    dx = ntuple(d -> length(axes[d]) > 1 ? axes[d][2] - axes[d][1] : 1.0, Val(D))
    dV = prod(dx)

    u_clean = replace(u_valid, NaN => 0.0)
    err_vals = u_clean .- ana_vals

    # 1. Analytical Norms
    ana_l1 = sum(abs, ana_vals) * dV
    ana_l2_sq = sum(abs2, ana_vals) * dV
    mass_ana = sum(ana_vals) * dV
    
    # 2. Error Norms
    l1_err = sum(abs, err_vals) * dV
    l2_sq_err = sum(abs2, err_vals) * dV
    
    res["l1error"] = l1_err
    res["l2error"] = sqrt(l2_sq_err)
    res["relative_l1error"] = ana_l1 > 1e-12 ? l1_err / ana_l1 : l1_err
    res["relative_l2error"] = ana_l2_sq > 1e-12 ? sqrt(l2_sq_err) / sqrt(ana_l2_sq) : sqrt(l2_sq_err)

    # 3. Mass & Supnorm
    mass_num = sum(u_clean) * dV
    res["mass"] = mass_num
    res["relative_mass"] = abs(mass_ana) > 1e-12 ? mass_num / abs(mass_ana) : NaN

    res["supnorm"] = maximum(abs, err_vals)
    sup_ana = maximum(abs, ana_vals)
    res["relative_supnorm"] = sup_ana > 1e-12 ? res["supnorm"] / sup_ana : res["supnorm"]

    return res
end

# ==============================================================================
# --- SECTION 3: SYMBOL DISPATCH ARCHITECTURE ---
# ==============================================================================

"""
    _calculate_stats!(::Val{:series}, ...)

Calculates time-dependent series (Norms, Integrals, Masses).
Populates `sim_data.series` which is a `Matrix` of shape `[Component, Time]`.
"""
function _calculate_stats!(::Val{:series}, sim_data::AbstractSimData{D}, x_dense, u_dense, ref_func; force_overwrite=false, kwargs...) where {D}
    n_steps = length(sim_data.t)
    n_comps = size(u_dense, 1)

    # Establish keys dynamically
    keys_list = isnothing(ref_func) ? 
        ["mass", "wave_height", "wave_position", "l1norm", "l2norm"] : 
        ["l1error", "l2error", "supnorm", "relative_l1error", "relative_l2error", "relative_supnorm", "mass", "relative_mass"]
    
    if D >= 2
        filter!(k -> k != "wave_position", keys_list)
        push!(keys_list, "wave_position_x", "wave_position_y")
        if D == 3
            push!(keys_list, "wave_position_z")
        end
    end

    filter!(k -> !haskey(sim_data.series, k) || force_overwrite, keys_list)
    
    # Preallocate output vectors
    for k in keys_list
        sim_data.series[k] = fill(NaN, n_comps, n_steps)
    end
    isempty(keys_list) && return

    axes = D == 1 ? (x_dense[1],) : x_dense
    grid_shape = size(u_dense)[2:end-1]
    
    p = Progress(n_steps; desc = "Calculating :series Stats...")
    
    Threads.@threads for m in 1:n_steps
        t = sim_data.t[m]
        
        # Allocate analytical tensor ONCE per timestep per thread!
        local_ana = isnothing(ref_func) ? nothing : zeros(Float64, grid_shape)
        
        for c in 1:n_comps
            # Dynamic slicing: extracts `[X, Y, Z]` perfectly regardless of dimension!
            u_valid = selectdim(selectdim(u_dense, ndims(u_dense), m), 1, c)
            
            if !isnothing(ref_func)
                # Evaluate analytical solution natively onto the grid
                for idx in CartesianIndices(grid_shape)
                    pos = SVector{D, Float64}(ntuple(d -> axes[d][idx[d]], Val(D)))
                    local_ana[idx] = ref_func(pos, t)[c]
                end
                res = _calc_series_with_ref(Val(D), u_valid, local_ana, axes)
            else
                res = _calc_series_no_ref(Val(D), u_valid, axes)
            end
            
            for k in keys_list
                sim_data.series[k][c, m] = res[k]
            end
        end
        ProgressMeter.next!(p)
    end
end

function _calculate_stats!(::Val{:fields}, sim_data::AbstractSimData, x_dense, u_dense, ref_func; kwargs...)
    @info "Calculating :fields stats..."
end

function _calculate_stats!(::Val{:profiles}, sim_data::AbstractSimData, x_dense, u_dense, ref_func; kwargs...)
    @info "Calculating :profiles stats..."
end

# ==============================================================================
# --- SECTION 4: MAIN API & REFERENCE GENERATORS ---
# ==============================================================================

"""
    calculateAllStats!(sim_data, ref_func=nothing; stats_to_calculate=:series, ...)

The Universal Stat Orchestrator.
"""
function calculateAllStats!(
    sim_data::AbstractSimData,
    ref_func::Union{Function, Nothing} = nothing;
    stats_to_calculate::Union{Symbol, Vector{Symbol}} = [:series],
    kwargs...
)
    stats_list = stats_to_calculate isa Symbol ? [stats_to_calculate] : stats_to_calculate

    for stat_type in stats_list
        _calculate_stats!(Val(stat_type), sim_data, sim_data.x, sim_data.u, ref_func; kwargs...)
    end
    
    saveSimData(sim_data; data_key=kwargs[:data_key], overwrite = true)
end

# --- N-Dimensional Native Nearest Neighbor Reference Generator ---
function createReferenceFunction(ref_sim_data::AbstractSimData{D}) where {D}
    x_dense, u_dense = ref_sim_data.x, ref_sim_data.u
    axes = D == 1 ? (x_dense[1],) : x_dense
    n_comps = size(u_dense, 1)

    return function ref_func(pos::SVector{D, Float64}, t::Float64)
        _, t_idx = findmin(abs.(ref_sim_data.t .- t))
        
        # 1. Find the nearest grid indices dynamically
        idx = CartesianIndex(ntuple(Val(D)) do d
            findmin(abs.(axes[d] .- pos[d]))[2]
        end)
        
        # 2. Isolate the Space Grid for the correct timestep
        u_space = selectdim(u_dense, ndims(u_dense), t_idx)
        
        # 3. Extract components natively
        return SVector{n_comps, Float64}(Tuple(u_space[c, idx] for c in 1:n_comps))
    end
end

function calculateAllStats!(sim_data::AbstractSimData, ref_params::ParamDict; kwargs...)
    @info "Loading numerical reference solution for stats calculation..."
    ref_sim_data = try loadSimData(ref_params) catch e; @warn "Failed" exception=e; nothing end
    if isnothing(ref_sim_data); return; end
    
    calculateAllStats!(sim_data, createReferenceFunction(ref_sim_data); kwargs...)
end

"""
    calculateAllStats!(sim_config::SimulationConfig; kwargs...)

Batch calculates statistics for all simulations defined in a `SimulationConfig`.
"""
function calculateAllStats!(
    sim_config::SimulationConfig;
    active_methods::Vector{String} = sim_config.default_methods,
    varied_params::VariedDict = sim_config.varied_params,
    fixed_params::ParamDict = ParamDict(),
    stats_to_calculate::Union{Symbol, Vector{Symbol}} = [:series],
    parallel::Bool = false,
    kwargs...
)
    active_keys = collect(keys(varied_params))
    active_values = collect(values(varied_params))
    all_tasks = Vector{ParamDict}()
    
    for method in active_methods
        base_params = assembleParams(sim_config.shared_params, sim_config.methods_dict, method)
        ignore_keys = get_ignore_keys(sim_config.methods_dict, method)
        tasks, _ = generate_method_tasks(base_params, active_keys, active_values, fixed_params; ignore_keys=ignore_keys)
        append!(all_tasks, tasks)
    end
    
    num_tasks = length(all_tasks)
    if num_tasks == 0
        @info "No simulations found to calculate stats for."
        return
    end
    
    @info "Calculating stats for $num_tasks simulations (Parallel: $parallel)..."
    p = Progress(num_tasks; desc="Calculating Stats...")
    counter = Threads.Atomic{Int}(0)
    
    ref_func = sim_config.reference_func
    
    function _process_stats(params)
        sim_data = try loadSimData(params) catch; nothing end
        if !isnothing(sim_data)
            calculateAllStats!(sim_data, ref_func; stats_to_calculate=stats_to_calculate, kwargs...)
        end
    end
    
    if parallel
        Threads.@threads for params in all_tasks
            _process_stats(params)
            Threads.atomic_add!(counter, 1)
            ProgressMeter.update!(p, counter[])
        end
    else
        for params in all_tasks
            _process_stats(params)
            counter[] += 1
            ProgressMeter.update!(p, counter[])
        end
    end
end