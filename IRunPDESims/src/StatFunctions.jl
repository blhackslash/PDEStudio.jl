stat_category(::Val) = Val(:unknown)

# --- Built-in Registry ---
stat_category(::Val{:mass})          = Val(:series)
stat_category(::Val{:l1norm})        = Val(:series)
stat_category(::Val{:l2norm})        = Val(:series)
stat_category(::Val{:wave_height})   = Val(:series)
stat_category(::Val{:l1error})       = Val(:series)
stat_category(::Val{:l2error})       = Val(:series)
stat_category(::Val{:relative_mass}) = Val(:series)



# 1. Ultimate Fallback (If no matching method exists, it safely returns NaN)
calc_stat(stat::Val, D::Val, args...) = NaN 

# 2. The Router (If analytical refs are missing, drop them and try to find a 5-argument method)
calc_stat(stat::Val, D::Val, xs, u, dV, ::Nothing, ::Nothing) = calc_stat(stat, D, xs, u, dV)

# ---------------------------------------------------------
# NO-REFERENCE METRICS (5 Arguments)
# ---------------------------------------------------------
# 1. Ultimate Fallback (If no matching method exists, it safely returns NaN)
calc_stat(stat::Val, D::Val, t::Float64, args...) = NaN 

# 2. The Router (If analytical refs are missing, drop them and try to find a 6-argument method)
calc_stat(stat::Val, D::Val, t::Float64, xs, u, dV, ::Nothing, ::Nothing) = calc_stat(stat, D, t, xs, u, dV)

# ---------------------------------------------------------
# NO-REFERENCE METRICS (6 Arguments)
# ---------------------------------------------------------
calc_stat(::Val{:mass}, ::Val, t::Float64, xs, u, dV) = sum(u .* dV)

calc_stat(::Val{:l1norm}, ::Val, t::Float64, xs, u, dV) = sum(map(v -> abs.(v), u) .* dV)

# Note the sqrt.() at the end to apply element-wise square root to the resulting SVector
calc_stat(::Val{:l2norm}, ::Val, t::Float64, xs, u, dV) = sqrt.(sum(map(v -> abs2.(v), u) .* dV))

# Component-wise maximum across all particles
calc_stat(::Val{:wave_height}, ::Val, t::Float64, xs, u, dV) = reduce((a, b) -> max.(a, b), u)

function calc_stat(::Val{:wave_position}, ::Val{1}, t::Float64, xs, u, dV)
    M = length(eltype(u))
    # Find the position of the max value for each component individually
    return SVector{M, Float64}(ntuple(M) do c
        max_idx = argmax(map(v -> v[c], u))
        xs[max_idx][1] 
    end)
end

# ---------------------------------------------------------
# ERROR METRICS (8 Arguments - Strictly requires reference)
# ---------------------------------------------------------
calc_stat(::Val{:l1error}, ::Val, t::Float64, xs, u, dV, ana, err) = sum(map(v -> abs.(v), err) .* dV)

calc_stat(::Val{:l2error}, ::Val, t::Float64, xs, u, dV, ana, err) = sqrt.(sum(map(v -> abs2.(v), err) .* dV))

function calc_stat(::Val{:relative_mass}, ::Val, t::Float64, xs, u, dV, ana, err)
    sum_u = sum(u .* dV)
    sum_ana = sum(ana .* dV)
    
    # abs.() on a single SVector safely does element-wise absolute values
    m_ana = abs.(sum_ana) 

    M = length(eltype(u))
    # Return NaN only for the specific components where the analytical mass is near zero
    return SVector{M, Float64}(ntuple(M) do c
        m_ana[c] < 1e-9 ? NaN : sum_u[c] / sum_ana[c]
    end)
end