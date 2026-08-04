mutable struct Instance
    J::Int64
    T::Int64
    Omega::Int64
    s_max::Float64
    s_min::Float64
    delta::Float64
    e_c::Float64
    e_d::Float64
    s_I::Float64
    f_under::Float64
    f_bar::Float64
    mu::Float64
    beta::Float64
    nu::Array{Float64,2}
    c_pv::Array{Float64,2}
    pv_det::Array{Float64,1}
    d::Array{Float64,3}
    d_det::Array{Float64,2}
    rho::Vector{Float64}
    id::String
    timeStamp::Array{String,1}

    function Instance()
        return new()
    end
end

mutable struct Solution
    id::String
    s::Array{Float64,2}
    I::Array{Float64,3}
    G::Array{Float64,3}
    x::Array{Float64,3}
    w::Array{Float64,3}
    z::Array{Float64,3}
    y::Array{Float64,3}
    p::Array{Float64,3}
    lambda::Array{Float64,2}
    costs::Array{Float64,1}
    status::Bool
    time::Float64

    function Solution()
        return new()
    end

    function Solution(
        sTot::Array{Float64,2},
        I::Array{Float64,3},
        G::Array{Float64,3},
        x::Array{Float64,3},
        w::Array{Float64,3},
        z::Array{Float64,3},
        y::Array{Float64,3},
        p::Array{Float64,3},
        lambda::Array{Float64,2},
        costs::Array{Float64,1},
        status::Bool,
        solTime::Float64,
        id::String="none"
    )
        this = Solution()
        this.id = id
        this.s = sTot
        this.I = I
        this.G = G
        this.x = x
        this.w = w
        this.z = z
        this.y = y
        this.p = p
        this.lambda = lambda
        this.costs = costs
        this.status = status
        this.time = solTime
        return this
    end
end
