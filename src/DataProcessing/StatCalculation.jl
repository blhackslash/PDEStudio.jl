using Dierckx
using QuadGK
using ProgressMeter
using Random

# ==============================================================================
# --- SECTION 1: EULERIAN UNIFICATION (Dense Tensors with NaN Padding) ---
# ==============================================================================

"""
    _get_dense_tensors(sim_data)

Converts any simulation data into a dense Eulerian tensor format.
For Lagrangian data, moving/ragged particles are padded into a dense grid 
where unpopulated particles are marked with `NaN`.
"""
function _get_dense_tensors(sim_data::ESimData)
    # Eulerian is already dense! 
    # x is Vector (1D) or Matrix (2D). u is [Comp, Space..., Time]
    return sim_data.x, sim_data.u
end

function _get_dense_tensors(sim_data::LSimData{1,M}) where M
    n_steps = length(sim_data.t)
    max_p = maximum(length.(sim_data.x))
    n_comps = size(sim_data.u[1][1], 1)

    # x_dense: [Particle/Space, Time]
    x_dense = fill(NaN, max_p, n_steps)
    # u_dense: [Component, Particle/Space, Time]
    u_dense = fill(NaN, n_comps, max_p, n_steps)

    for m in 1:n_steps
        n_p = length(sim_data.x[m])
        for p in 1:n_p
            x_dense[p, m] = sim_data.x[m][p][1] # Extract position from SVector
            for c in 1:n_comps
                u_dense[c, p, m] = sim_data.u[m][p][c] # Extract state
            end
        end
    end
    
    return x_dense, u_dense
end

# ==============================================================================
# --- SECTION 2: THE MATHEMATICAL WORKERS (Stateless & Safe) ---
# ==============================================================================

function _create_piecewise_spline_function(x_coords, y_values, breakpoints, dierckx_k)
    isempty(x_coords) && return x -> 0.0 
    splines = Dierckx.Spline1D[] 

    for i in 1:(length(breakpoints)-1)
        xa, xb = breakpoints[i], breakpoints[i+1]
        epsilon = 1e-9
        idx_sub = findall(x -> (xa - epsilon) <= x <= (xb + epsilon), x_coords)

        current_k = length(idx_sub) < dierckx_k + 1 ? 1 : dierckx_k
        if length(idx_sub) < 2
            val = isempty(idx_sub) ? y_values[findmin(v -> abs(v - (xa+xb)/2), x_coords)[2]] : y_values[idx_sub[1]]
            push!(splines, Dierckx.Spline1D([xa, xb], [val, val]; k=1, bc="nearest"))
            continue
        end
        
        x_p, y_p = x_coords[idx_sub], y_values[idx_sub]
        if abs(x_p[1] - xa) > epsilon; insert!(x_p, 1, xa); insert!(y_p, 1, y_p[1]); end
        if abs(x_p[end] - xb) > epsilon; push!(x_p, xb); push!(y_p, y_p[end]); end

        try
            push!(splines, Dierckx.Spline1D(x_p, y_p; k=current_k, s=0., bc="nearest"))
        catch; push!(splines, Dierckx.Spline1D([xa, xb], [0.0, 0.0]; k=1)); end
    end

    return function(x)
        idx = searchsortedlast(breakpoints, x)
        return splines[clamp(idx == 0 ? 1 : idx, 1, length(splines))](x)
    end
end

function _calc_series_with_ref(::Val{1}, u_valid, ana_func, x_valid, domain, disc_pts, k, tol)
    res = Dict{String, Float64}()
    isempty(u_valid) && return res

    ana_vals = [ana_func(x) for x in x_valid]
    err_vals = u_valid .- ana_vals
    bps = unique(sort([domain.xmin; disc_pts; domain.xmax]))

    perm = sortperm(x_valid)
    x_sort = x_valid[perm]
    spl_err = _create_piecewise_spline_function(x_sort, err_vals[perm], bps, k)
    spl_u = _create_piecewise_spline_function(x_sort, u_valid[perm], bps, k)

    # 1. Calculate Norms first (these are fast and provide a scale)
    ana_l1, _ = QuadGK.quadgk(x -> abs(ana_func(x)), bps...; rtol=tol)
    ana_l2_sq, _ = QuadGK.quadgk(x -> ana_func(x)^2, bps...; rtol=tol)
    
    # 2. FIX: Use ana_l1 to set a floor for the absolute tolerance.
    # This prevents the integrator from diving into infinity if mass_ana is 0.
    mass_atol = ana_l1 * tol
    mass_ana, _ = QuadGK.quadgk(ana_func, bps...; rtol=tol, atol=mass_atol)

    l1_err, _ = QuadGK.quadgk(x -> abs(spl_err(x)), bps...; rtol=tol, atol=mass_atol)
    l2_sq_err, _ = QuadGK.quadgk(x -> spl_err(x)^2, bps...; rtol=tol, atol=mass_atol)
    
    res["l1error"] = l1_err
    res["l2error"] = sqrt(l2_sq_err)
    res["relative_l1error"] = ana_l1 > 1e-12 ? l1_err / ana_l1 : l1_err
    res["relative_l2error"] = sqrt(ana_l2_sq) > 1e-12 ? sqrt(l2_sq_err) / sqrt(ana_l2_sq) : sqrt(l2_sq_err)

    mass_num, _ = QuadGK.quadgk(spl_u, bps...; rtol=tol)
    res["mass"] = mass_num
    res["relative_mass"] = abs(mass_ana) > 1e-12 ? mass_num / abs(mass_ana) : NaN

    res["supnorm"] = maximum(abs.(err_vals))
    sup_ana = maximum(abs.(ana_vals))
    res["relative_supnorm"] = sup_ana > 1e-12 ? res["supnorm"] / sup_ana : res["supnorm"]
    return res
end

function _calc_series_no_ref(::Val{1}, u_valid, x_valid, domain, disc_pts, k, tol)
    res = Dict{String, Float64}()
    isempty(u_valid) && return res

    bps = unique(sort([domain.xmin; disc_pts; domain.xmax]))
    perm = sortperm(x_valid)
    spl_u = _create_piecewise_spline_function(x_valid[perm], u_valid[perm], bps, k)

    res["mass"], _ = QuadGK.quadgk(spl_u, bps...; rtol=tol)
    res["l1norm"], _ = QuadGK.quadgk(x -> abs(spl_u(x)), bps...; rtol=tol)
    res["l2norm"] = sqrt(QuadGK.quadgk(x -> spl_u(x)^2, bps...; rtol=tol)[1])

    h_num, idx = findmax(u_valid)
    res["wave_height"] = h_num
    res["wave_position"] = x_valid[idx]
    return res
end

# ==============================================================================
# --- SECTION 3: SYMBOL DISPATCH ARCHITECTURE ---
# ==============================================================================

"""
    _calculate_stats!(::Val{:series}, ...)

Calculates time-dependent series (Norms, Integrals, Masses).
Populates `sim_data.series` which is a `Matrix` of shape `[Time, Component]`.
"""
function _calculate_stats!(::Val{:series}, sim_data::AbstractSimData{D}, x_dense, u_dense, ref_func; 
                           discontinuity_points_func = _ -> Float64[], dierckx_k=3, quad_tol=1e-12, force_overwrite=false) where {D}
    
    n_steps = length(sim_data.t)
    n_comps = size(u_dense, 1)

    keys = isnothing(ref_func) ? 
        ["mass", "wave_height", "wave_position", "l1norm", "l2norm"] : 
        ["l1error", "l2error", "supnorm", "relative_l1error", "relative_l2error", "relative_supnorm", "mass", "relative_mass"]
    filter!(k -> !haskey(sim_data.series, k) || force_overwrite, keys)
    # Preallocate into the strictly typed series dictionary
    for k in keys
        sim_data.series[k] = fill(NaN, n_comps, n_steps)
    end
    if isempty(keys); return end

    domain = (xmin=get(sim_data.params, "xmin", 0.0), xmax=get(sim_data.params, "xmax", 1.0))
    p = Progress(n_steps; desc = "Calculating :series Stats...")
    
    Threads.@threads for m in 1:n_steps
        t = sim_data.t[m]
        x_m = x_dense isa AbstractVector ? x_dense : @view x_dense[:, m]
        disc_pts = discontinuity_points_func(t)

        # Drop the Eulerian "Unpopulated Particles" (NaNs)
        valid_idx = findall(!isnan, x_m)
        x_valid = x_m[valid_idx]

        for c in 1:n_comps
            u_valid = u_dense[c, valid_idx, m]
            
            if !isnothing(ref_func)
                ana_func = (D == 1) ? (x -> ref_func(x, t)[c]) : (pos -> ref_func(pos, t)[c])
                res = _calc_series_with_ref(Val(D), u_valid, ana_func, x_valid, domain, disc_pts, dierckx_k, quad_tol)
            else
                res = _calc_series_no_ref(Val(D), u_valid, x_valid, domain, disc_pts, dierckx_k, quad_tol)
            end
            
            for k in keys
                sim_data.series[k][c, m] = res[k]
            end
        end
        ProgressMeter.update!(p, 1)
    end
end

"""
    _calculate_stats!(::Val{:fields}, ...)

Placeholder for Spatio-temporal stats (e.g. pointwise errors over time).
Populates `sim_data.fields` `[Component, Space..., Time]`.
"""
function _calculate_stats!(::Val{:fields}, sim_data::AbstractSimData, x_dense, u_dense, ref_func; kwargs...)
    @info "Calculating :fields stats..."
    # e.g., sim_data.fields["pointwise_error"] = u_dense .- analytical_tensor
end

"""
    _calculate_stats!(::Val{:profiles}, ...)

Placeholder for purely spatial stats at the final timestep.
Populates `sim_data.profiles` `[Component, Space...]`.
"""
function _calculate_stats!(::Val{:profiles}, sim_data::AbstractSimData, x_dense, u_dense, ref_func; kwargs...)
    @info "Calculating :profiles stats..."
end

# ==============================================================================
# --- SECTION 4: MAIN API & REFERENCE GENERATORS ---
# ==============================================================================

"""
    calculateAllStats!(sim_data, ref_func=nothing; stats_to_calculate=:series, ...)

The Universal Stat Orchestrator. 
Converts incoming data to dense Eulerian tensors and dispatches entirely by Symbol.
"""
function calculateAllStats!(
    sim_data::AbstractSimData,
    ref_func::Union{Function, Nothing} = nothing;
    stats_to_calculate::Union{Symbol, Vector{Symbol}} = [:series],
    kwargs...
)
    stats_list = stats_to_calculate isa Symbol ? [stats_to_calculate] : stats_to_calculate

    # 1. Unify into Dense Tensors (Auto-padding Lagrange to Euler)
    x_dense, u_dense = _get_dense_tensors(sim_data)

    # 2. Dispatch by Category Symbol!
    for stat_type in stats_list
        _calculate_stats!(Val(stat_type), sim_data, x_dense, u_dense, ref_func; kwargs...)
    end
    
    saveSimData(sim_data; overwrite = true)
end

# --- 1D Numerical Reference Generator ---
function createReferenceFunction(ref_sim_data::AbstractSimData{1}; discontinuity_points_func::Function = t -> Float64[])
    x_dense, u_dense = _get_dense_tensors(ref_sim_data)
    n_steps, n_comps = length(ref_sim_data.t), size(u_dense, 1)
    
    ref_splines = Vector{Vector{Dierckx.Spline1D}}(undef, n_steps)
    
    for m in 1:n_steps
        t = ref_sim_data.t[m]
        x_m = x_dense isa AbstractVector ? x_dense : @view x_dense[:, m]
        valid_idx = findall(!isnan, x_m)
        x_valid = x_m[valid_idx]
        
        bps = unique(sort([x_valid[1]; discontinuity_points_func(t); x_valid[end]]))
        
        comp_splines = Dierckx.Spline1D[]
        for c in 1:n_comps
            u_valid = u_dense[c, valid_idx, m]
            push!(comp_splines, _create_piecewise_spline_function(x_valid, u_valid, bps, 1))
        end
        ref_splines[m] = comp_splines
    end

    return function ref_func(x, t)
        _, t_idx = findmin(abs.(ref_sim_data.t .- t))
        return Tuple(ref_splines[t_idx][c](x) for c in 1:n_comps)
    end
end

function calculateAllStats!(sim_data::AbstractSimData, ref_params::ParamDict; kwargs...)
    @info "Loading reference solution for stats calculation..."
    ref_sim_data = try loadSimData(ref_params) catch e; @warn "Failed" exception=e; nothing end
    if isnothing(ref_sim_data); return; end
    calculateAllStats!(sim_data, createReferenceFunction(ref_sim_data); kwargs...)
end