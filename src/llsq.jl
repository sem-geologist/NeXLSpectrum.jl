using MultivariateStats: cov_whitening
using NeXLUncertainties

"""
    olssvd(y::AbstractVector{N}, a::AbstractMatrix{N}, sigma::N, xLabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues where N <: AbstractFloat

Solves the ordinary least squares problem a⋅x = y for x using singular value decomposition for AbstractFloat-based types.
"""
function olssvd(
    y::AbstractVector{N},
    a::AbstractMatrix{N},
    sigma::N,
    xLabels::Vector{<:Label},
    tol::N = convert(N, 1.0e-10)
) where {N<:AbstractFloat}
    f = svd(a)
    mins = tol * maximum(f.S)
    fs = [s > mins ? one(N) / s : zero(N) for s in f.S]
    # Note: w*a = f.U * Diagonal(f.S) * f.Vt
    genInv = f.V * Diagonal(fs) * transpose(f.U)
    #cov = sigma^2*f.V*(Diagonal(fs)*Diagonal(fs))*Transpose(f.V)
    cov = sigma^2 * genInv * transpose(genInv)
    return uvs(xLabels, genInv * y, cov)
end

"""
    olspinv(y::AbstractVector{N}, a::AbstractMatrix{N}, v::Matrix{N}, xlabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues

Solves the ordinary least squares problem a⋅x = y for x using the pseudo-inverse for AbstractFloat-based types.
"""
function olspinv(
    y::AbstractVector{N},
    a::AbstractMatrix{N},
    sigma::N,
    xLabels::Vector{<:Label},
    ::N = convert(N, 1.0e-10),
) where {N<:AbstractFloat}
    genInv = pinv(a, rtol = 1.0e-6)
    return uvs(xLabels, genInv * y, sigma * genInv * transpose(genInv))
end

"""
    glspinv(y::AbstractVector{N}, a::AbstractMatrix{N}, v::Matrix{N}, xlabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues

Solve the generalized least squares problem y = x β + ϵ for β where ϵ ~ v σ using the pseudo-inverse.

β = (xᵀv⁻¹x)⁻¹xᵀv⁻¹y where a⁻¹ => pinv(a)

cov[β] = (xᵀv⁻¹x)⁻¹
"""
function glspinv(
    y::AbstractVector{N},
    x::AbstractMatrix{N},
    v::AbstractMatrix{N},
    xLabels::Vector{<:Label},
    ::N = convert(N, 1.0e-10),
) where {N<:AbstractFloat}
    txiv = transpose(x) * pinv(v)
    yp, ixp = txiv * y, pinv(txiv * x)
    return uvs(xLabels, ixp * yp, ixp)
end

"""
    glsinv(y::AbstractVector{N}, a::AbstractMatrix{N}, v::Matrix{N}, xlabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues

Solve the generalized least squares problem y = x β + ϵ for β where ϵ ~ v σ using the inverse.
"""
function glsinv(
    y::AbstractVector{N},
    x::AbstractMatrix{N},
    v::AbstractMatrix{N},
    xLabels::Vector{<:Label},
    ::N = convert(N, 1.0e-10),
) where {N<:AbstractFloat}
    txiv = transpose(x) * inv(v)
    yp, ixp = txiv * y, inv(txiv * x)
    return uvs(xLabels, ixp * yp, ixp)
end


"""
    glssvd(y::AbstractVector{N}, a::AbstractMatrix{N}, cov::Matrix{N}, xlabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues

Solves the generalized least squares problem y = x β + ϵ for β using covariance whitening and the ordinary least squares pseudo-inverse.
"""
function glssvd(
    y::AbstractVector{N},
    x::AbstractMatrix{N},
    cov::AbstractMatrix{N},
    xLabels::Vector{<:Label},
    tol::N = convert(N, 1.0e-10),
) where {N<:AbstractFloat}
    checkcovariance!(cov)
    w = cov_whitening(Matrix(cov))
    #olssvd(w*y, w*a, one(N), xLabels, tol)
    return olspinv(w * y, w * x, one(N), xLabels, tol)
end

"""
    glschol(y::AbstractVector{N}, a::AbstractMatrix{N}, cov::Matrix{N}, xlabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues

Solves the generalized least squares problem y = x β + ϵ for β using covariance whitening and the ordinary least squares pseudo-inverse.
"""
function glschol(
    y::AbstractVector{N},
    x::AbstractMatrix{N},
    cov::AbstractMatrix{N},
    xLabels::Vector{<:Label},
    tol::N = convert(N, 1.0e-10),
) where {N<:AbstractFloat}
    checkcovariance!(cov)
    w = inv(cholesky(cov).L)
    return olspinv(w * y, w * x, one(N), xLabels, tol)
end


"""
    wlssvd(y::AbstractVector{N}, a::AbstractMatrix{N}, cov::AbstractVector{N}, xlabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues

Solves the weighted least squares problem y = x β + ϵ  for β using singular value decomposition for AbstractFloat-based types.
"""
function wlssvd(
    y::AbstractVector{N},
    x::AbstractMatrix{N},
    cov::AbstractVector{N},
    xLabels::Vector{<:Label},
    tol::N = convert(N, 1.0e-10),
) where {N<:AbstractFloat}
    w = Diagonal([sqrt(one(N) / cv) for cv in cov])
    return olssvd(w * y, w * x, one(N), xLabels, tol)
end

"""
    wlspinv(y::AbstractVector{N}, a::AbstractMatrix{N}, cov::AbstractVector{N}, xlabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues

Solves the weighted least squares problem a⋅x = y for x using singular value decomposition for AbstractFloat-based types.
"""
function wlspinv(
    y::AbstractVector{N},
    a::AbstractMatrix{N},
    cov::AbstractVector{N},
    xLabels::Vector{<:Label},
    tol::N = convert(N, 1.0e-10),
) where {N<:AbstractFloat}
    w = Diagonal([sqrt(one(N) / cv) for cv in cov])
    return olspinv(w * y, w * a, one(N), xLabels, tol)
end

"""
    wlspinv2(y::AbstractVector{N}, a::AbstractMatrix{N}, cov::AbstractVector{N}, covscales::AbstractVector{N}, xLabels::Vector{<:Label}, tol::N=convert(N,1.0e-10))::UncertainValues where N <: AbstractFloat

Solves the weighted least squares problem a⋅x = y for x using singular value decomposition for AbstractFloat-based types.  Rescales the rescaleCovariances
according to `covscales`.
"""
function wlspinv2(
    y::AbstractVector{N},
    a::AbstractMatrix{N},
    cov::AbstractVector{N},
    covscales::AbstractVector{N},
    xLabels::Vector{<:Label},
    tol::N = convert(N, 1.0e-10),
) where {N<:AbstractFloat}
    function rescaleCovariances(
        uvs::UncertainValues,
        covscales::AbstractVector{N},
    )::UncertainValues
        cov = copy(uvs.covariance)
        # rwgts = map(sqrt,wgts)
        a = Base.axes(cov)
        for r in a[1], c in a[2]
            cov[r, c] *= covscales[r] * covscales[c]
        end
        return UncertainValues(uvs.labels, uvs.values, cov)
    end
    w = Diagonal([sqrt(one(N) / cv) for cv in cov])
    return rescaleCovariances(olspinv(w * y, w * a, one(N), xLabels, tol), covscales)
end

"""
    simple_linear_regression(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})::Tuple{Real, Real}

Peforms simple linear regression. Returns the `( slope, intercept, r, t )` of the unweighted best fit line through
the data `x` and `y`.  ( y = slope*x + intercept ), r is the correlation coefficient and t is the t-statistic.
"""
function simple_linear_regression(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    sx, sy, n = sum(x), sum(y), length(x)
    ssxy, ssxx, ssyy = (dot(x, y) - sx*sy/n), (dot(x, x) - sx*sx/n), (dot(y, y) - sy*sy/n)
    slope, r = ssxy / ssxx, ssxy/sqrt(ssxx*ssyy)
    return ( slope, (sy - slope*sx)/n, r, r/sqrt((1.0-r^2)/(n-2)) )
end
