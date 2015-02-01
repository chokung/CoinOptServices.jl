#export jl2osnl_varargs, jl2osnl_binary, jl2osnl_unary, jl2osil_vartypes,
#    addLinElem!, expr2osnl!

jl2osnl_varargs = @compat Dict(
    :+     => "sum",
    :*     => "product")

jl2osnl_binary = @compat Dict(
    :+     => "plus",
    :.+    => "plus",
    :-     => "minus",
    :.-    => "minus",
    :*     => "times",
    :.*    => "times",
    :/     => "divide",
    :./    => "divide",
    :div   => "quotient",
    :÷     => "quotient",
    #:.÷    => "quotient", # 0.4 only?
    :rem   => "rem",
    :^     => "power",
    :.^    => "power",
    :log   => "log")

jl2osnl_unary = @compat Dict(
    :-     => "negate",
    :√     => "sqrt",
    :abs2  => "square",
    :ceil  => "ceiling",
    :log   => "ln",
    :log10 => "log10",
    :asin  => "arcsin",
    :asinh => "arcsinh",
    :acos  => "arccos",
    :acosh => "arccosh",
    :atan  => "arctan",
    :atanh => "arctanh",
    :acot  => "arccot",
    :acoth => "arccoth",
    :asec  => "arcsec",
    :asech => "arcsech",
    :acsc  => "arccsc",
    :acsch => "arccsch")

for op in [:abs, :sqrt, :floor, :factorial, :exp, :sign, :erf,
           :sin, :sinh, :cos, :cosh, :tan, :tanh,
           :cot, :coth, :sec, :sech, :csc, :csch]
    jl2osnl_unary[op] = string(op)
end

# ternary :ifelse => "if" ?
# comparison ops

jl2osil_vartypes = @compat Dict(:Cont => "C", :Int => "I", :Bin => "B",
    :SemiCont => "D", :SemiInt => "J", :Fixed => "C")
# assuming lb == ub for all occurrences of :Fixed vars

osrl2jl_status = @compat Dict(
    "unbounded" => :Unbounded,
    "globallyOptimal" => :Optimal,
    "locallyOptimal" => :Optimal,
    "optimal" => :Optimal,
    "bestSoFar" => :Error, # be conservative for now
    "feasible" => :Error, # not sure when this happens - maybe with no objective?
    "infeasible" => :Infeasible,
    "unsure" => :Error,
    "error" => :Error,
    "other" => :Error, # OSBonminSolver and OSCouenneSolver use this for LIMIT_EXCEEDED
    "stoppedByLimit" => :UserLimit,
    "stoppedByBounds" => :Error, # does this ever happen?
    "IpoptAccetable" => :Optimal, # this (with typo) only occurs in OSIpoptSolver
    "BonminAccetable" => :Optimal, # this (with typo) only occurs in a
    "BonminAcceptable" => :Optimal, # possibly-obsolete version of OSBonminSolver
    "IpoptAcceptable" => :Optimal) # the typos may get fixed at some point

function addLinElem!(indicator, densevals, elem::Expr)
    # convert Expr of the form :(val * x[idx]) to (idx, val)
    # then set indicator[idx] = true; densevals[idx] += val
    @assertequal(elem.head, :call)
    elemargs = elem.args
    @assertequal(elemargs[1], :*)
    @assertequal(length(elemargs), 3)
    elemarg3 = elemargs[3]
    @assertequal(elemarg3.head, :ref)
    elemarg3args = elemarg3.args
    @assertequal(elemarg3args[1], :x)
    @assertequal(length(elemarg3args), 2)
    idx::Int = elemarg3args[2]
    indicator[idx] = true
    densevals[idx] += elemargs[2]
    return 0.0
end
function addLinElem!(indicator, densevals, elem)
    # for elem not an Expr, assume it's a constant term and return it
    return elem
end

#=
function constr2bounds(ex::Expr, sense::Symbol, rhs::Float64)
    # return (lb, ub) for a 3-term constraint expression
    if sense == :(<=)
        return (-Inf, rhs)
    elseif sense == :(>=)
        return (rhs, Inf)
    elseif sense == :(==)
        return (rhs, rhs)
    else
        error("Unknown constraint sense $sense")
    end
end
function constr2bounds(lhs::Float64, lsense::Symbol, ex::Expr,
        rsense::Symbol, rhs::Float64)
    # return (lb, ub) for a 5-term range constraint expression
    if lsense == :(<=) && rsense == :(<=)
        return (lhs, rhs)
    else
        error("Unknown constraint sense $lhs $lsense $ex $rsense $rhs")
    end
end
=#

function expr2osnl!(parent, ex::Expr)
    # convert nonlinear expression from Expr to OSnL,
    # adding any new child xml elements to parent
    head = ex.head
    args = ex.args
    numargs = length(args)
    if head == :call
        if numargs < 2
            error("Do not know how to handle :call expression ", ex,
                " with fewer than 2 args")
        elseif numargs == 2
            if haskey(jl2osnl_unary, args[1])
                child = new_child(parent, jl2osnl_unary[args[1]])
                expr2osnl!(child, args[2])
            else
                error("Do not know how to convert unary $(args[1]) to osnl")
            end
        elseif numargs == 3
            if haskey(jl2osnl_binary, args[1])
                # handle some special cases, see below
                child = binary2osnl!(parent, args...)
            else
                error("Do not know how to convert binary $(args[1]) to osnl")
            end
        else
            if haskey(jl2osnl_varargs, args[1])
                child = new_child(parent, jl2osnl_varargs[args[1]])
                for i = 2:numargs
                    expr2osnl!(child, args[i])
                end
            else
                error("Do not know how to convert varargs $(args[1]) to osnl")
            end
        end
    elseif head == :ref
        child = var2osnl!(parent, args)
    else
        error("Do not know how to handle expression $ex with head $head")
    end
    return child
end
function expr2osnl!(parent, ex)
    # for anything not an Expr, assume it's a constant number
    child = new_child(parent, "number")
    set_attribute(child, "value", ex)
    return child
end

function var2osnl!(parent, args)
    # convert :(x[idx]) to osnl, adding <variable> xml element to parent
    @assertequal(args[1], :x)
    @assertequal(length(args), 2)
    idx::Int = args[2]
    child = new_child(parent, "variable")
    set_attribute(child, "idx", idx - 1) # OSiL is 0-based
    return child
end

function binary2osnl_generic!(parent, op::Symbol, ex1, ex2)
    # convert generic binary operation from Expr(:call, op, ex1, ex1)
    # to OSnL, adding any new child xml elements to parent
    child = new_child(parent, jl2osnl_binary[op])
    expr2osnl!(child, ex1)
    expr2osnl!(child, ex2)
    return child
end
function binary2osnl!(parent, op::Symbol, ex1::Expr, ex2::Number)
    # special cases for square, variable * coef, variable / coef
    if ex2 == 2 && (op == :^ || op == :.^)
        child = new_child(parent, "square")
        expr2osnl!(child, ex1)
    # do same thing for sqrt here?
    elseif ex1.head == :ref && (op == :* || op == :.*)
        child = var2osnl!(parent, ex1.args)
        set_attribute(child, "coef", ex2)
    elseif ex1.head == :ref && (op == :/ || op == :./)
        child = var2osnl!(parent, ex1.args)
        set_attribute(child, "coef", 1 / ex2)
    else
        child = binary2osnl_generic!(parent, op, ex1, ex2)
    end
    return child
end
function binary2osnl!(parent, op::Symbol, ex1::Number, ex2::Expr)
    # special case for coef * variable
    if ex2.head == :ref && (op == :* || op == :.*)
        child = var2osnl!(parent, ex2.args)
        set_attribute(child, "coef", ex1)
    else
        child = binary2osnl_generic!(parent, op, ex1, ex2)
    end
    return child
end
function binary2osnl!(parent, op::Symbol, ex1, ex2)
    return binary2osnl_generic!(parent, op, ex1, ex2)
end

function xml2vec(el::XMLElement, n::Integer, defaultval=NaN)
    # convert osrl/osil list of variable values, bound or constraint
    # dual values, or objective coefficients to dense vector
    x = fill(defaultval, n)
    indicator = fill(false, n)
    for child in child_elements(el)
        idx = int(attribute(child, "idx")) + 1 # OSiL is 0-based
        if indicator[idx] # combine duplicates
            x[idx] += float64(content(child))
        else
            indicator[idx] = true
            x[idx] = float64(content(child))
        end
    end
    return x
end

# TODO: move this to LightXML
function parse_file(filename::String, encoding, options::Integer)
    p = ccall(dlsym(LightXML.libxml2, "xmlReadFile"), Ptr{Void},
        (Ptr{Cchar}, Ptr{Cchar}, Cint), filename, encoding, options)
    p != C_NULL || throw(LightXML.XMLParseError("Failure in parsing an XML file."))
    XMLDocument(p)
end

# TODO: other direction for reading osil => jump model

