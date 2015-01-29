module OptimizationServices

using MathProgBase, LightXML, Compat
importall MathProgBase.SolverInterface

debug = true # (ccall(:jl_is_debugbuild, Cint, ()) == 1)
if debug
    macro assertform(x, y)
        msg = "$x expected to be $y, was "
        :($x == $y ? nothing : error($msg * repr($x)))
    end
else
    macro assertform(x, y)
    end
end

include("translations.jl")

depsjl = Pkg.dir("OptimizationServices", "deps", "deps.jl")
isfile(depsjl) ? include(depsjl) : error(
    "OptimizationServices not properly installed.\n" *
    "Please run Pkg.build(\"OptimizationServices\")")
OSSolverService = joinpath(dirname(libOS), "..", "bin", "OSSolverService")
osildir = Pkg.dir("OptimizationServices", ".osil")

export OsilSolver
immutable OsilSolver <: AbstractMathProgSolver
    solver::String
    osil::String
    osol::String
    osrl::String
    options
end
OsilSolver(;
    solver = "",
    osil = joinpath(osildir, "problem.osil"),
    osol = joinpath(osildir, "options.osol"),
    osrl = joinpath(osildir, "results.osrl"),
    options...) = OsilSolver(solver, osil, osol, osrl, options)

type OsilMathProgModel <: AbstractMathProgModel
    solver::String
    osil::String
    osol::String
    osrl::String
    options

    numberOfVariables::Int
    numberOfConstraints::Int
    xl::Vector{Float64}
    xu::Vector{Float64}
    cl::Vector{Float64}
    cu::Vector{Float64}
    objsense::Symbol
    d::AbstractNLPEvaluator

    numLinConstr::Int
    vartypes::Vector{Symbol}
    x0::Vector{Float64}

    objval::Float64
    solution::Vector{Float64}
    status::Symbol

    xdoc::XMLDocument # TODO: finalizer
    obj::XMLElement
    vars::Vector{XMLElement}
    cons::Vector{XMLElement}

    function OsilMathProgModel(solver, osil, osol, osrl; options...)
        new(solver, osil, osol, osrl, options)
    end
end

MathProgBase.model(s::OsilSolver) =
    OsilMathProgModel(s.solver, s.osil, s.osol, s.osrl; s.options...)


function MathProgBase.loadnonlinearproblem!(m::OsilMathProgModel,
        numberOfVariables, numberOfConstraints, xl, xu, cl, cu, objsense,
        d::MathProgBase.AbstractNLPEvaluator)

    @assert numberOfVariables == length(xl) == length(xu)
    @assert numberOfConstraints == length(cl) == length(cu)

    m.numberOfVariables = numberOfVariables
    m.numberOfConstraints = numberOfConstraints
    m.xl = xl
    m.xu = xu
    m.cl = cl
    m.cu = cu
    m.objsense = objsense
    m.d = d

    MathProgBase.initialize(d, [:ExprGraph])

    # clear existing problem, if defined
    if isdefined(m, :xdoc)
        free(m.xdoc)
    end
    m.xdoc = XMLDocument()
    m.vars = Array(XMLElement, numberOfVariables)
    m.cons = Array(XMLElement, numberOfConstraints)

    xroot = create_root(m.xdoc, "osil")
    set_attribute(xroot, "xmlns", "os.optimizationservices.org")
    set_attribute(xroot, "xmlns:xsi",
        "http://www.w3.org/2001/XMLSchema-instance")
    set_attribute(xroot, "xsi:schemaLocation",
        "os.optimizationservices.org " *
        "http://www.optimizationservices.org/schemas/2.0/OSiL.xsd")

    instanceHeader = new_child(xroot, "instanceHeader")
    description = new_child(instanceHeader, "description")
    add_text(description, "generated by OptimizationServices.jl on " *
        strftime("%Y/%m/%d at %H:%M:%S", time()))

    instanceData = new_child(xroot, "instanceData")

    variables = new_child(instanceData, "variables")
    set_attribute(variables, "numberOfVariables", numberOfVariables)
    for i = 1:numberOfVariables
        vari = new_child(variables, "var")
        set_attribute(vari, "lb", xl[i]) # lb defaults to 0 if not specified!
        if isfinite(xu[i])
            set_attribute(vari, "ub", xu[i])
        end
        m.vars[i] = vari
    end

    objectives = new_child(instanceData, "objectives")
    # can MathProgBase do multi-objective problems?
    set_attribute(objectives, "numberOfObjectives", "1")
    m.obj = new_child(objectives, "obj")
    set_attribute(m.obj, "maxOrMin", lowercase(string(objsense)))

    # TODO: compare BitArray vs. Array{Bool} here
    indicator = falses(numberOfVariables)
    densevals = zeros(numberOfVariables)

    objexpr = MathProgBase.obj_expr(d)
    nlobj = false
    if MathProgBase.isobjlinear(d)
        @assertform objexpr.head :call
        objexprargs = objexpr.args
        @assertform objexprargs[1] :+
        constant = 0.0
        for i = 2:length(objexprargs)
            constant += addLinElem!(indicator, densevals, objexprargs[i])
        end
        if constant != 0.0
            set_attribute(m.obj, "constant", constant)
        end
        numberOfObjCoef = 0
        idx = findnext(indicator, 1)
        while idx != 0
            numberOfObjCoef += 1
            coef = new_child(m.obj, "coef")
            set_attribute(coef, "idx", idx - 1) # OSiL is 0-based
            add_text(coef, string(densevals[idx]))

            densevals[idx] = 0.0 # reset for later use in linear constraints
            idx = findnext(indicator, idx + 1)
        end
        fill!(indicator, false) # for Array{Bool}, set to false one element at a time?
        set_attribute(m.obj, "numberOfObjCoef", numberOfObjCoef)
    else
        nlobj = true
        set_attribute(m.obj, "numberOfObjCoef", "0")
        # nonlinear objective goes in nonlinearExpressions, <nl idx="-1">
    end

    constraints = new_child(instanceData, "constraints")
    set_attribute(constraints, "numberOfConstraints", numberOfConstraints)
    for i = 1:numberOfConstraints
        coni = new_child(constraints, "con")
        # assume no constant attributes on constraints
        if isfinite(cl[i])
            set_attribute(coni, "lb", cl[i])
        end
        if isfinite(cu[i])
            set_attribute(coni, "ub", cu[i])
        end
        # save for possible constraint bound modification?
        m.cons[i] = coni
    end

    # assume linear constraints are all at start
    row = 1
    nextrowlinear = MathProgBase.isconstrlinear(d, row)
    if nextrowlinear
        # has at least 1 linear constraint
        linearConstraintCoefficients = new_child(instanceData,
            "linearConstraintCoefficients")
        numberOfValues = 0
        rowstarts = new_child(linearConstraintCoefficients, "start")
        add_text(new_child(rowstarts, "el"), "0")
        colIdx = new_child(linearConstraintCoefficients, "colIdx")
        values = new_child(linearConstraintCoefficients, "value")
    end
    while nextrowlinear
        constrexpr = MathProgBase.constr_expr(d, row)
        @assertform constrexpr.head :comparison
        #(lhs, rhs) = constr2bounds(constrexpr.args...)
        constrlinpart = constrexpr.args[end - 2]
        @assertform constrlinpart.head :call
        constrlinargs = constrlinpart.args
        @assertform constrlinargs[1] :+
        for i = 2:length(constrlinargs)
            addLinElem!(indicator, densevals, constrlinargs[i]) == 0.0 ||
                error("Unexpected constant term in linear constraint")
        end
        idx = findnext(indicator, 1)
        while idx != 0
            numberOfValues += 1
            add_text(new_child(colIdx, "el"), string(idx - 1)) # OSiL is 0-based
            add_text(new_child(values, "el"), string(densevals[idx]))

            densevals[idx] = 0.0 # reset for next row
            idx = findnext(indicator, idx + 1)
        end
        fill!(indicator, false) # for Array{Bool}, set to false one element at a time?
        add_text(new_child(rowstarts, "el"), string(numberOfValues))
        row += 1
        nextrowlinear = MathProgBase.isconstrlinear(d, row)
    end
    m.numLinConstr = row - 1
    if m.numLinConstr > 0
        set_attribute(linearConstraintCoefficients, "numberOfValues",
            numberOfValues)
    end

    numberOfNonlinearExpressions = numberOfConstraints - m.numLinConstr +
        (nlobj ? 1 : 0)
    if numberOfNonlinearExpressions > 0
        # has nonlinear objective or at least 1 nonlinear constraint
        nonlinearExpressions = new_child(instanceData, "nonlinearExpressions")
        set_attribute(nonlinearExpressions, "numberOfNonlinearExpressions",
            numberOfNonlinearExpressions)
        if nlobj
            nl = new_child(nonlinearExpressions, "nl")
            set_attribute(nl, "idx", "-1")
            expr2osnl!(nl, MathProgBase.obj_expr(d))
        end
        for row = m.numLinConstr + 1 : numberOfConstraints
            nl = new_child(nonlinearExpressions, "nl")
            set_attribute(nl, "idx", row - 1) # OSiL is 0-based
            constrexpr = MathProgBase.constr_expr(d, row)
            @assertform constrexpr.head :comparison
            #(lhs, rhs) = constr2bounds(constrexpr.args...)
            expr2osnl!(nl, constrexpr.args[end - 2])
        end
    end

    return m
end

function MathProgBase.setvartype!(m::OsilMathProgModel, vartypes::Vector{Symbol})
    m.vartypes = vartypes
    vars = m.vars
    @assert length(vars) == length(vartypes)
    for i = 1:length(vartypes)
        if haskey(jl2osil_vartypes, vartypes[i])
            set_attribute(vars[i], "type", jl2osil_vartypes[vartypes[i]])
        else
            error("Unrecognized vartype $(vartypes[i])")
        end
    end
end

function MathProgBase.setsense!(m::OsilMathProgModel, objsense::Symbol)
    m.objsense = sense
    set_attribute(m.obj, "maxOrMin", lowercase(string(objsense)))
end

function MathProgBase.setwarmstart!(m::OsilMathProgModel, x0::Vector{Float64})
    @assert length(x0) == m.numberOfVariables
    m.x0 = x0
end

function write_osol_file(osol, x0, options)
    xdoc = XMLDocument()
    # fill in osol file here
    save_file(xdoc, osol)
    free(xdoc)
end

function MathProgBase.optimize!(m::OsilMathProgModel)
    save_file(m.xdoc, m.osil)
    write_osol_file(m.osol, m.x0, options)
    if isempty(m.solver)
        solvercmd = `` # use default
    else
        solvercmd = `-solver $(m.solver)`
    end
    run(`$OSSolverService -osil $(m.osil) -osol $(m.osol) -osrl $(m.osrl)
        $solvercmd`)

    xdoc = parse_file(m.osrl)
    # read from osrl file here
    println(xdoc)
    free(xdoc)

    return m.status
end

MathProgBase.status(m::OsilMathProgModel) = m.status
MathProgBase.numvar(m::OsilMathProgModel) = m.numberOfVariables
MathProgBase.numconstr(m::OsilMathProgModel) = m.numberOfConstraints
MathProgBase.numlinconstr(m::OsilMathProgModel) = m.numLinConstr
MathProgBase.numquadconstr(m::OsilMathProgModel) = 0 # TODO: quadratic problems
MathProgBase.getsolution(m::OsilMathProgModel) = m.solution
MathProgBase.getobjval(m::OsilMathProgModel) = m.objval
MathProgBase.getsense(m::OsilMathProgModel) = m.objsense
MathProgBase.getvartype(m::OsilMathProgModel) = m.vartypes



# writeproblem for nonlinear?



end # module
