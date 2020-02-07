abstract type FastLayer <: Function end

paramlength(f) = 0
initial_params(f) = Float32[]
initial_params(f::Chain) = Flux.destructure(f)[1]

struct FastChain{T<:Tuple} <: FastLayer
  layers::T
  function FastChain(xs...)
    layers = getfunc.(xs)
    new{typeof(layers)}(layers)
  end
end
getfunc(x) = x
getfunc(x::Tuple) = first(x)
getparams(x) = Float32[]
getparams(x::Tuple) = last(x)

applychain(::Tuple{}, x, p) = x
applychain(fs::Tuple, x, p) = applychain(Base.tail(fs), first(fs)(x,p[1:paramlength(first(fs))]), p[(paramlength(first(fs))+1):end])
(c::FastChain)(x,p) = applychain(c.layers, x, p)
paramlength(c::FastChain) = sum(paramlength(x) for x in c.layers)
initial_params(c::FastChain) = vcat(initial_params.(c.layers)...)

struct FastDense{F,F2} <: FastLayer
  out::Int
  in::Int
  σ::F
  initial_params::F2
  function FastDense(in::Integer, out::Integer, σ = identity;
                 initW = Flux.glorot_uniform, initb = Flux.zeros)
    initial_params() = vcat(vec(initW(out, in)),initb(out))
    new{typeof(σ),typeof(initial_params)}(out,in,σ,initial_params)
  end
end
# (f::FastDense)(x,p) = f.σ.(reshape(uview(p,1:(f.out*f.in)),f.out,f.in)*x .+ uview(p,(f.out*f.in+1):lastindex(p)))
(f::FastDense)(x,p) = f.σ.(reshape(p[1:(f.out*f.in)],f.out,f.in)*x .+ p[(f.out*f.in+1):end])
ZygoteRules.@adjoint function (f::FastDense)(x,p)
  W = p[reshape(1:(f.out*f.in),f.out,f.in)] # @view after BLAS fixes
  b = p[(f.out*f.in+1):end]
  r = W*x .+ b
  y = f.σ.(r)
  function FastDense_adjoint(ȳ)
    if typeof(f.σ) <: typeof(tanh)
      σbar = 1 .- y.^2
    else
      σbar = ForwardDiff.derivative.(f.σ,r)
    end
    zbar = ȳ .* σbar
    Wbar = zbar * x'
    bbar = zbar
    xbar = W' * zbar
    nothing,xbar,vcat(vec(Wbar),bbar)
  end
  y,FastDense_adjoint
end
paramlength(f::FastDense) = f.out*(f.in + 1)
initial_params(f::FastDense) = f.initial_params()

struct StaticDense{out,in,F,F2} <: FastLayer
  σ::F
  initial_params::F2
  function StaticDense(in::Integer, out::Integer, σ = identity;
                 initW = Flux.glorot_uniform, initb = Flux.zeros)
    initial_params() = vcat(vec(initW(out, in)),initb(out))
    new{out,in,typeof(σ),typeof(initial_params)}(σ,initial_params)
  end
end

function param2Wb(f::StaticDense{out,in}, p) where {out,in}
  _W, _b = @views p[1:(out*in)], p[(out*in+1):end]
  W = @inbounds convert(SMatrix{out,in},_W)
  b = @inbounds SVector{out}(_b)
  return W, b
end
function (f::StaticDense{out,in})(x,p) where {out,in}
  W, b = param2Wb(f, p)
  f.σ.(W*x .+ p)
end
ZygoteRules.@adjoint function (f::StaticDense{out,in})(x,p) where {out,in}
  W, b = param2Wb(f, p)
  r = W*x .+ b
  y = map(f.σ,r)
  function StaticDense_adjoint(ȳ)
    if typeof(f.σ) <: typeof(tanh)
      σbar = 1 .- y.^2
    else
      σbar = ForwardDiff.derivative.(f.σ,r)
    end
    zbar = SVector{out}(ȳ) .* σbar
    Wbar = zbar * SVector{in}(x)'
    bbar = zbar
    xbar = W' * zbar
    pbar = vcat(vec(Wbar),bbar)
    xbar_out = x isa SArray ? xbar : adapt(typeof(x),xbar)
    pbar_out = p isa SArray ? pbar : adapt(typeof(p),pbar)
    nothing,xbar_out,pbar_out
  end
  y,StaticDense_adjoint
end
paramlength(f::StaticDense{out,in}) where {out,in} = out*(in + 1)
initial_params(f::StaticDense) = f.initial_params()
