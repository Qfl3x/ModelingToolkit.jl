using Base: RefValue


isintermediate(eq::Equation) = !(isa(eq.lhs, Operation) && isa(eq.lhs.op, Differential))

struct DiffEq  # D(x) = t
    D::Differential  # D
    var::Variable    # x
    rhs::Expression  # t
end
function Base.convert(::Type{DiffEq}, eq::Equation)
    isintermediate(eq) && throw(ArgumentError("intermediate equation received"))
    return DiffEq(eq.lhs.op, eq.lhs.args[1], eq.rhs)
end
Base.:(==)(a::DiffEq, b::DiffEq) = (a.D, a.var, a.rhs) == (b.D, b.var, b.rhs)
get_args(eq::DiffEq) = Expression[eq.var, eq.rhs]

struct DiffEqSystem <: AbstractSystem
    eqs::Vector{DiffEq}
    iv::Variable
    dvs::Vector{Variable}
    ps::Vector{Variable}
    jac::RefValue{Matrix{Expression}}
    function DiffEqSystem(eqs, iv, dvs, ps)
        jac = RefValue(Matrix{Expression}(undef, 0, 0))
        new(eqs, iv, dvs, ps, jac)
    end
end

function DiffEqSystem(eqs)
    dvs, = extract_elements(eqs, [_is_dependent])
    ivs = unique(vcat((dv.dependents for dv ∈ dvs)...))
    length(ivs) == 1 || throw(ArgumentError("one independent variable currently supported"))
    iv = first(ivs)
    ps, = extract_elements(eqs, [_is_parameter(iv)])
    DiffEqSystem(eqs, iv, dvs, ps)
end

function DiffEqSystem(eqs, iv)
    dvs, ps = extract_elements(eqs, [_is_dependent, _is_parameter(iv)])
    DiffEqSystem(eqs, iv, dvs, ps)
end


function generate_ode_function(sys::DiffEqSystem; version::FunctionVersion = ArrayFunction)
    var_pairs   = [(u.name, :(u[$i])) for (i, u) ∈ enumerate(sys.dvs)]
    param_pairs = [(p.name, :(p[$i])) for (i, p) ∈ enumerate(sys.ps )]
    (ls, rs) = collect(zip(var_pairs..., param_pairs...))

    var_eqs = Expr(:(=), build_expr(:tuple, ls), build_expr(:tuple, rs))
    sys_exprs = build_expr(:tuple, [convert(Expr, eq.rhs) for eq ∈ sys.eqs])
    let_expr = Expr(:let, var_eqs, sys_exprs)

    if version === ArrayFunction
        :((du,u,p,t) -> du .= $let_expr)
    elseif version === SArrayFunction
        :((u,p,t) -> begin
            du = $let_expr
            T = StaticArrays.similar_type(typeof(u), eltype(du))
            T(du)
        end)
    end
end

function calculate_jacobian(sys::DiffEqSystem, simplify=true)
    isempty(sys.jac[]) || return sys.jac[]  # use cached Jacobian, if possible
    rhs = [eq.rhs for eq in sys.eqs]

    jac = expand_derivatives.(calculate_jacobian(rhs, sys.dvs))
    sys.jac[] = jac  # cache Jacobian
    return jac
end

system_vars(sys::DiffEqSystem) = sys.dvs
system_params(sys::DiffEqSystem) = sys.ps


function generate_ode_iW(sys::DiffEqSystem, simplify=true)
    var_exprs = [:($(sys.dvs[i].name) = u[$i]) for i in eachindex(sys.dvs)]
    param_exprs = [:($(sys.ps[i].name) = p[$i]) for i in eachindex(sys.ps)]
    jac = calculate_jacobian(sys, simplify)

    gam = Parameter(:gam)

    W = LinearAlgebra.I - gam*jac
    W = SMatrix{size(W,1),size(W,2)}(W)
    iW = inv(W)

    if simplify
        iW = simplify_constants.(iW)
    end

    W = inv(LinearAlgebra.I/gam - jac)
    W = SMatrix{size(W,1),size(W,2)}(W)
    iW_t = inv(W)
    if simplify
        iW_t = simplify_constants.(iW_t)
    end

    iW_exprs = [:(iW[$i,$j] = $(convert(Expr, iW[i,j]))) for i in 1:size(iW,1), j in 1:size(iW,2)]
    exprs = vcat(var_exprs,param_exprs,vec(iW_exprs))
    block = expr_arr_to_block(exprs)

    iW_t_exprs = [:(iW[$i,$j] = $(convert(Expr, iW_t[i,j]))) for i in 1:size(iW_t,1), j in 1:size(iW_t,2)]
    exprs = vcat(var_exprs,param_exprs,vec(iW_t_exprs))
    block2 = expr_arr_to_block(exprs)
    :((iW,u,p,gam,t)->$(block)),:((iW,u,p,gam,t)->$(block2))
end

function DiffEqBase.ODEFunction(sys::DiffEqSystem; version::FunctionVersion = ArrayFunction)
    expr = generate_ode_function(sys; version = version)
    if version === ArrayFunction
        ODEFunction{true}(eval(expr))
    elseif version === SArrayFunction
        ODEFunction{false}(eval(expr))
    end
end


export DiffEqSystem, ODEFunction
export generate_ode_function
