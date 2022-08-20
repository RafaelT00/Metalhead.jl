"""
    dwsep_conv_bn(kernel_size::Dims{2}, inplanes::Integer, outplanes::Integer,
                  activation = relu; eps::Float32 = 1.0f-5, revnorm::Bool = false, 
                  stride::Integer = 1, use_norm::NTuple{2, Bool} = (true, true),
                  pad::Integer = 0, [bias, weight, init])

Create a depthwise separable convolution chain as used in MobileNetv1.
This is sequence of layers:

  - a `kernel_size` depthwise convolution from `inplanes => inplanes`
  - a (batch) normalisation layer + `activation` (if `use_norm[1] == true`; otherwise
    `activation` is applied to the convolution output)
  - a `kernel_size` convolution from `inplanes => outplanes`
  - a (batch) normalisation layer + `activation` (if `use_norm[2] == true`; otherwise
    `activation` is applied to the convolution output)

See Fig. 3 in [reference](https://arxiv.org/abs/1704.04861v1).

# Arguments

  - `kernel_size`: size of the convolution kernel (tuple)
  - `inplanes`: number of input feature maps
  - `outplanes`: number of output feature maps
  - `activation`: the activation function for the final layer
  - `revnorm`: set to `true` to place the batch norm before the convolution
  - `use_norm`: a tuple of two booleans to specify whether to use normalization for the first and
    second convolution
  - `bias`: a tuple of two booleans to specify whether to use bias for the first and second
    convolution. This is set to `(false, false)` by default if `use_norm[0] == true` and
    `use_norm[1] == true`.
  - `stride`: stride of the first convolution kernel
  - `pad`: padding of the first convolution kernel
  - `dilation`: dilation of the first convolution kernel
  - `weight`, `init`: initialization for the convolution kernel (see [`Flux.Conv`](#))
"""
function dwsep_conv_bn(kernel_size::Dims{2}, inplanes::Integer, outplanes::Integer,
                       activation = relu; eps::Float32 = 1.0f-5, revnorm::Bool = false,
                       stride::Integer = 1, use_norm::NTuple{2, Bool} = (true, true),
                       bias::NTuple{2, Bool} = (!use_norm[1], !use_norm[2]), kwargs...)
    return vcat(conv_norm(kernel_size, inplanes, inplanes, activation; eps,
                          revnorm, use_norm = use_norm[1], stride, bias = bias[1],
                          groups = inplanes, kwargs...),
                conv_norm((1, 1), inplanes, outplanes, activation; eps,
                          revnorm, use_norm = use_norm[2], bias = bias[2]))
end

# TODO add support for stochastic depth to mbconv and fused_mbconv
"""
    mbconv(kernel_size, inplanes::Integer, explanes::Integer,
                     outplanes::Integer, activation = relu; stride::Integer,
                     reduction::Union{Nothing, Integer} = nothing)

Create a basic inverted residual block for MobileNet variants
([reference](https://arxiv.org/abs/1905.02244)).

# Arguments

  - `kernel_size`: kernel size of the convolutional layers
  - `inplanes`: number of input feature maps
  - `explanes`: The number of feature maps in the hidden layer
  - `outplanes`: The number of output feature maps
  - `activation`: The activation function for the first two convolution layer
  - `stride`: The stride of the convolutional kernel, has to be either 1 or 2
  - `reduction`: The reduction factor for the number of hidden feature maps
    in a squeeze and excite layer (see [`squeeze_excite`](#))
"""
function mbconv(kernel_size::Dims{2}, inplanes::Integer, explanes::Integer,
                outplanes::Integer, activation = relu; stride::Integer,
                dilation::Integer = 1, reduction::Union{Nothing, Integer} = nothing,
                norm_layer = BatchNorm, momentum::Union{Nothing, Number} = nothing,
                se_from_explanes::Bool = false, divisor::Integer = 8, no_skip::Bool = false)
    @assert stride in [1, 2] "`stride` has to be 1 or 2 for `mbconv`"
    # handle momentum for BatchNorm
    if !isnothing(momentum)
        @assert norm_layer==BatchNorm "`momentum` is only supported for `BatchNorm`"
        norm_layer = (args...; kwargs...) -> BatchNorm(args...; momentum, kwargs...)
    end
    layers = []
    # expand
    if inplanes != explanes
        append!(layers,
                conv_norm((1, 1), inplanes, explanes, activation; norm_layer))
    end
    # depthwise
    append!(layers,
            conv_norm(kernel_size, explanes, explanes, activation; norm_layer,
                      stride, dilation, pad = SamePad(), groups = explanes))
    # squeeze-excite layer
    if !isnothing(reduction)
        squeeze_planes = _round_channels((se_from_explanes ? explanes : inplanes) ÷
                                         reduction, divisor)
        push!(layers,
              squeeze_excite(explanes, squeeze_planes; activation, gate_activation = hardσ))
    end
    # project
    append!(layers, conv_norm((1, 1), explanes, outplanes, identity))
    use_skip = stride == 1 && inplanes == outplanes && !no_skip
    return use_skip ? SkipConnection(Chain(layers...), +) : Chain(layers...)
end

function fused_mbconv(kernel_size::Dims{2}, inplanes::Integer,
                      explanes::Integer, outplanes::Integer, activation = relu;
                      stride::Integer, norm_layer = BatchNorm, no_skip::Bool = false)
    @assert stride in [1, 2] "`stride` has to be 1 or 2 for `fused_mbconv`"
    layers = []
    # fused expand
    explanes = explanes == inplanes ? outplanes : explanes
    append!(layers,
            conv_norm(kernel_size, inplanes, explanes, activation; norm_layer, stride,
                      pad = SamePad()))
    if explanes != inplanes
        # project
        append!(layers, conv_norm((1, 1), explanes, outplanes, identity; norm_layer))
    end
    use_skip = stride == 1 && inplanes == outplanes && !no_skip
    return use_skip ? SkipConnection(Chain(layers...), +) : Chain(layers...)
end
