//  Copyright © 2022 Apple Inc.

#include <ATen/ATen.h>
#include <ATen/Tensor.h>
#include <ATen/Utils.h>
#include <ATen/TensorUtils.h>
#include <ATen/mps/MPSStream.h>
#include <ATen/native/mps/OperationUtils.h>
#include <ATen/native/ReduceOpsUtils.h>
#include <ATen/native/Pool.h>
#include <torch/library.h>
#include <ATen/native/mps/MPSGraphVenturaOps.h>
#include <c10/util/irange.h>

namespace at {
namespace native {

typedef MPSGraphTensor* (^NormOpBlock)(mps::MPSBinaryCachedGraph*, MPSGraphTensor*, MPSGraphTensor*);
#define NormOpFn(graph, primary, secondary) MPSGraphTensor* (mps::MPSBinaryCachedGraph* graph, MPSGraphTensor* primary, MPSGraphTensor* secondary)

enum StdVarType {
  STANDARD_VARIANCE,
  STANDARD_DEVIATION
};

enum MPSReductionType {
  MAX,
  MIN,
  AMAX,
  AMIN,
  SUM,
  PROD,
  MEAN,
  COUNT_NONZERO,
  TRACE
};

using namespace mps;

void set_apparent_shapes(NSMutableArray<NSNumber*> * &apparent_out_shape,
                         NSMutableArray<NSNumber*> * &apparent_in_shape,
                         int64_t num_reduce_dims,
                         int64_t num_output_dims,
                         IntArrayRef& input_shape,
                         NSMutableArray<NSNumber*> * &axes) {

  if (num_reduce_dims == 0) {
    /* Output shape becomes a one
     * Input shape becomes flattened
     * Because 0 reduce dims means all dims are reduced
     */
    apparent_in_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
    int64_t num_in_elements = c10::multiply_integers(input_shape);
    apparent_in_shape[0] = [NSNumber numberWithInt:num_in_elements];

    apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
    apparent_out_shape[0] = @1;
  } else {
    // num_output_dims in this case is number of input dims
    apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_output_dims];
    for (const auto i : c10::irange(num_output_dims)) {
      int64_t current_input_dim = input_shape[i];

      // If the current dim is to be reduced
      bool is_reduce_dim = false;

      for (const auto j : c10::irange(num_reduce_dims)) {
        if (i == [axes[j] intValue]) {
          is_reduce_dim = true;
          break;
        }
      }

      apparent_out_shape[i] = is_reduce_dim ? @1 : [NSNumber numberWithInt:current_input_dim];
    }
  }
}

// Helper function to set the axes of reduction
void set_axes(NSMutableArray<NSNumber *> * &axes,
              int64_t num_reduce_dims,
              OptionalIntArrayRef opt_dim,
              int64_t num_input_dims) {
  if (num_reduce_dims == 0) {
    axes = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
    axes[0] = @0;
  } else {
    TORCH_INTERNAL_ASSERT(opt_dim.has_value());
    IntArrayRef dim = opt_dim.value();
    axes = [NSMutableArray<NSNumber*> arrayWithCapacity:num_reduce_dims];
    for (const auto i : c10::irange(num_reduce_dims)) {
      axes[i] = [NSNumber numberWithInt:maybe_wrap_dim(dim[i], num_input_dims)];
    }
  }
}

// Helper function to prepare axes and tensor shapes
void set_axes_and_shapes(const Tensor& input_t,
                         OptionalIntArrayRef opt_dims,
                         NSMutableArray<NSNumber*> * &axes,
                         NSMutableArray<NSNumber*> * &apparent_input_shape,
                         NSMutableArray<NSNumber*> * &apparent_output_shape,
                         NSMutableArray<NSNumber*> * &output_shape) {

  IntArrayRef input_shape = input_t.sizes();

  int64_t num_input_dims = input_shape.size();
  int64_t num_reduce_dims = opt_dims.has_value() ? opt_dims.value().size() : 0;
  int64_t num_output_dims;

  num_output_dims = num_reduce_dims == 0 ? 1 : num_input_dims;

  // Reduction axes
  set_axes(axes, num_reduce_dims, opt_dims, input_shape.size());

  // Shapes
  set_apparent_shapes(apparent_output_shape,
                      apparent_input_shape,
                      num_reduce_dims,
                      num_output_dims,
                      input_shape,
                      axes);

  // Squeeze dims for output shape
  output_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:0];
  for (const auto i : c10::irange(num_output_dims)) {
    if ([apparent_output_shape[i] longValue] != 1) {
      [output_shape addObject:apparent_output_shape[i]];
    }
  }
}

void reduction_out_mps(
  const Tensor& input_t,
  OptionalIntArrayRef opt_dim,
  bool keepdim,
  c10::optional<ScalarType> dtype,
  const Tensor& output_t,
  MPSReductionType reduction_type,
  const std::string& func_name) {

  IntArrayRef input_shape = input_t.sizes();

  if (opt_dim.has_value()) {
    IntArrayRef dim = opt_dim.value();
    for (const auto dim_val : dim) {
      auto wrap_dim = maybe_wrap_dim(dim_val, input_shape.size());
      TORCH_CHECK(wrap_dim < (input_shape.size() == 0 ? input_t.numel() : input_shape.size()),
      func_name+": reduction dim must be in the range of input shape")
    }
  }

  NSMutableArray<NSNumber*> *axes = nil;
  NSMutableArray<NSNumber*> *apparent_input_shape = nil;
  NSMutableArray<NSNumber*> *apparent_output_shape = nil;
  NSMutableArray<NSNumber*> *output_shape = nil;

  set_axes_and_shapes(input_t, opt_dim, axes, apparent_input_shape, apparent_output_shape, output_shape);
  NSArray<NSNumber*>* wrappedAxes = mps::getTensorAxes(input_t, opt_dim);
  auto cache_ = MPSGraphCache::getInstance();

  if (output_t.numel() == 0 || input_t.numel() == 0) {
    if (reduction_type == MPSReductionType::PROD) {
      output_t.fill_(1);
    }
    return;
  }

  auto stream = at::mps::getCurrentMPSStream();
  @autoreleasepool {
    std::string dtype_str = dtype.has_value() ? mps::getMPSTypeString(dtype.value()) : "";
    NSString* ns_key = [[wrappedAxes valueForKey:@"description"] componentsJoinedByString:@","];
    string key = func_name                                 + ":" +
                 string([ns_key UTF8String])               + ":" +
                 getTensorsStringKey(input_t)              + ":" +
                 std::to_string(keepdim)                   + ":" +
                 std::to_string(reduction_type)            + ":" +
                 getTensorsStringKey(output_t)             + ":" +
                 dtype_str;
    using CachedGraph = MPSUnaryCachedGraph;
    auto cachedGraph = cache_->LookUpAs<CachedGraph>(key);

    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {

        CachedGraph *newCachedGraph = nil;

        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);
          MPSDataType input_type = getMPSDataType(input_t.scalar_type());

          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_t);
          MPSGraphTensor* castInputTensor = inputTensor;
          MPSDataType inputCastDtype = MPSDataTypeInvalid;
          if (dtype.has_value() &&
             (dtype.value() == kFloat || dtype.value() == kHalf || dtype.value() == kInt)) {
            inputCastDtype = getMPSDataType(dtype.value());
          } else if (input_type != MPSDataTypeInt32   &&
                     input_type != MPSDataTypeFloat32) {
            inputCastDtype = MPSDataTypeFloat32;
          }

          if (inputCastDtype != MPSDataTypeInvalid) {
            castInputTensor = [mpsGraph castTensor:inputTensor
                                            toType:inputCastDtype
                                              name:@"castInputTensor"];
          }

          MPSGraphTensor* castOutputTensor = nil;

          if (reduction_type == MPSReductionType::SUM) {
            castOutputTensor = [mpsGraph reductionSumWithTensor:castInputTensor
                                                           axes:wrappedAxes
                                                           name:nil];
          } else if (reduction_type == MPSReductionType::PROD) {
            castOutputTensor = [mpsGraph reductionProductWithTensor:castInputTensor
                                                               axes:wrappedAxes
                                                               name:nil];
          } else if (reduction_type == MPSReductionType::MEAN) {
            castOutputTensor = [mpsGraph meanOfTensor:castInputTensor
                                                 axes:wrappedAxes
                                                 name:nil];
          } else if (reduction_type == MPSReductionType::COUNT_NONZERO) {
            MPSGraphTensor* zeros = [mpsGraph constantWithScalar:0
                                                        dataType:castInputTensor.dataType];

            MPSGraphTensor* nonZeros = [mpsGraph notEqualWithPrimaryTensor:castInputTensor
                                                           secondaryTensor:zeros
                                                                      name:nil];

            castOutputTensor = [mpsGraph reductionSumWithTensor:nonZeros
                                                           axes:wrappedAxes
                                                           name:nil];
          } else if (reduction_type == MPSReductionType::AMAX) {
            castOutputTensor = [mpsGraph reductionMaximumWithTensor:castInputTensor
                                                               axes:wrappedAxes
                                                               name:nil];
          } else if (reduction_type == MPSReductionType::AMIN) {
            castOutputTensor = [mpsGraph reductionMinimumWithTensor:castInputTensor
                                                               axes:wrappedAxes
                                                               name:nil];
          } else if (reduction_type == MPSReductionType::TRACE) {
            MPSGraphTensor *bandPartWithTensor = [mpsGraph bandPartWithTensor:inputTensor
                                                                     numLower:0
                                                                     numUpper:0
                                                                         name:nil];
            castOutputTensor = [mpsGraph reductionSumWithTensor:bandPartWithTensor
                                                           axes:@[@0, @1]
                                                           name:nil];
          }

          MPSGraphTensor* outputTensor = nil;

          if (output_t.scalar_type() != ScalarType::Float) {
            outputTensor = [mpsGraph castTensor:castOutputTensor
                                         toType:getMPSDataType(output_t.scalar_type())
                                           name:@"outputTensor"];
          } else {
            outputTensor = castOutputTensor;
          }

          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, apparent_output_shape);
    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData()
    };
    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

TORCH_IMPL_FUNC(sum_out_mps)(
  const Tensor& input_t,
  OptionalIntArrayRef opt_dim,
  bool keepdim,
  c10::optional<ScalarType> dtype,
  const Tensor& output_t) {

  reduction_out_mps(input_t, opt_dim, keepdim, dtype, output_t, MPSReductionType::SUM, "sum_out_mps");
}

Tensor trace_mps_out(const Tensor& self) {
  Tensor output_t = at::native::empty_mps(
                    {},
                    self.scalar_type(),
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);

  std::vector<int64_t> dims(self.dim());
  std::iota(dims.begin(), dims.end(), 0);

  reduction_out_mps(self, IntArrayRef(dims), false, c10::nullopt, const_cast<Tensor&>(output_t), MPSReductionType::TRACE, "trace_mps_out");

  return output_t;
}

TORCH_IMPL_FUNC(prod_out_mps)
   (const Tensor& input_t,
    int64_t dim,
    bool keepdim,
    c10::optional<ScalarType> dtype,
    const Tensor& output_t) {
  int64_t dims[1] = {dim};
  reduction_out_mps(input_t, IntArrayRef(dims, 1), keepdim, dtype, output_t, MPSReductionType::PROD, "prod_out_mps");
}

// Taken from ReduceOps.cpp
inline ScalarType get_dtype_from_self(
    const Tensor& self,
    const c10::optional<ScalarType>& dtype,
    bool promote_integers) {
  if (dtype.has_value()) {
    return dtype.value();
  }

  ScalarType src_type = self.scalar_type();
  if (promote_integers && at::isIntegralType(src_type, /*includeBool=*/true)) {
    return kLong;
  }
  return src_type;
}

TORCH_IMPL_FUNC(amax_out_mps)(
  const Tensor& input_t,
  IntArrayRef dim,
  bool keepdim,
  const Tensor& output_t) {

  reduction_out_mps(input_t, dim, keepdim, c10::nullopt, output_t, MPSReductionType::AMAX, "amax_out_mps");
}

TORCH_IMPL_FUNC(amin_out_mps)(
  const Tensor& input_t,
  IntArrayRef dim,
  bool keepdim,
  const Tensor& output_t) {

  reduction_out_mps(input_t, dim, keepdim, c10::nullopt, output_t, MPSReductionType::AMIN, "amin_out_mps");
}

Tensor prod_mps(const Tensor &self, c10::optional<ScalarType> opt_dtype) {
  std::vector<int64_t> dims(self.dim());
  std::iota(dims.begin(), dims.end(), 0);

  Tensor output_t = at::native::empty_mps(
                      {},
                      get_dtype_from_self(self, opt_dtype, true),
                      c10::nullopt,
                      kMPS,
                      c10::nullopt,
                      c10::nullopt);

  reduction_out_mps(self, IntArrayRef(dims), false, opt_dtype, const_cast<Tensor&>(output_t), MPSReductionType::PROD, "prod_mps");

  return output_t;
}

Tensor count_nonzero_mps(const Tensor& self, IntArrayRef dims){
  int64_t shape_size = dims.size() == 0 ? 0 : self.sizes().size() - dims.size();
  int64_t out_shape = std::max(shape_size, 0LL);
  std::vector<int64_t> output_shape(out_shape);
  std::vector<int64_t> dims_vec = dims.vec();
  std::for_each(dims_vec.begin(), dims_vec.end(), [&](int64_t &n){ n = maybe_wrap_dim(n, self); });

  if (out_shape != 0) {
    int out_dim = 0;
    for (const auto self_dim: c10::irange((self.sizes().size()))) {
      if (std::find(dims_vec.begin(), dims_vec.end(), self_dim) == dims_vec.end()) {
        output_shape[out_dim++] = (self.sizes()[self_dim]);
      }
    }
  }

  Tensor output_t = at::native::empty_mps(
                      IntArrayRef(output_shape),
                      ScalarType::Long,
                      c10::nullopt,
                      kMPS,
                      c10::nullopt,
                      c10::nullopt);
  reduction_out_mps(self, dims, false, self.scalar_type(), const_cast<Tensor&>(output_t), MPSReductionType::COUNT_NONZERO, "count_nonzero_mps");

  return output_t;
}

TORCH_IMPL_FUNC(mean_out_mps)(
  const Tensor& input_t,
  OptionalIntArrayRef opt_dim,
  bool keepdim,
  c10::optional<ScalarType> dtype,
  const Tensor& output_t) {

  reduction_out_mps(input_t, opt_dim, keepdim, dtype, output_t, MPSReductionType::MEAN, "mean_out_mps");
}

void impl_func_norm_mps(
  const Tensor& input_tensor,
  const Tensor& other_tensor,
  const OptionalScalarRef& opt_p,
  IntArrayRef dim,
  bool keepdim,
  c10::optional<ScalarType> opt_dtype,
  const Tensor& output_t,
  bool cdist = false,
  c10::optional<IntArrayRef> input_broadcasted_shape = c10::nullopt,
  NormOpBlock normOpBlock = nullptr
  ) {

  if (input_tensor.numel() == 0) {
    return;
  }

  auto input_t = (input_tensor.sizes().size() == 0) ? input_tensor.view({1}) : input_tensor;
  auto in_dtype = opt_dtype.value_or(input_tensor.scalar_type());
  auto mps_input_dtype = getMPSDataType(in_dtype);

  IntArrayRef input_shape = cdist ? input_broadcasted_shape.value() : input_t.sizes();

  for (const auto dim_val: dim) {
    auto wrap_dim = maybe_wrap_dim(dim_val, input_shape.size());
    TORCH_CHECK(wrap_dim < input_shape.size(), "norm_out_mps: reduction dim must be in the range of input shape")
  }

  auto cache_ = MPSGraphCache::getInstance();

  auto p = opt_p.has_value() ? opt_p.get().to<double>() : Scalar(2.0).to<double>();
  auto reciprocal_p = 1 / p;
  bool pIsZero = (p == 0.0);
  bool pIsPosInf = (p == numeric_limits<double>::infinity());
  bool pIsNegInf = (p == -numeric_limits<double>::infinity());

  int64_t num_input_dims = input_shape.size();
  int64_t num_reduce_dims = dim.size();
  int64_t num_output_dims;

  // For output shape calculation, assume that keepdim is true
  num_output_dims = num_input_dims;
  NSMutableArray<NSNumber*> *apparent_output_shape = nil;
  NSMutableArray<NSNumber*> *apparent_input_shape = nil;

  // Reduction axes
  NSMutableArray<NSNumber *> *axes;
  set_axes(axes, num_reduce_dims, dim, input_shape.size());

  set_apparent_shapes(apparent_output_shape,
                      apparent_input_shape,
                      num_reduce_dims,
                      num_output_dims,
                      input_shape,
                      axes);

  NSArray<NSNumber*>* wrappedAxes = mps::getTensorAxes(input_t, dim);
  if (cdist) {
    apparent_input_shape  = [mps::getMPSShape(input_tensor.sizes()) mutableCopy];
    apparent_output_shape = [mps::getMPSShape(output_t.sizes()) mutableCopy];
  }

  if (output_t.numel() == 0) {
    return;
  }

  auto stream = at::mps::getCurrentMPSStream();
  @autoreleasepool {
    NSString* ns_key = [[axes valueForKey:@"description"] componentsJoinedByString:@","];
      string keepdim_info = (keepdim) ? "keepdim=1" : "keepdim=0";
      string tensor_key = cdist ? getTensorsStringKey({input_tensor, other_tensor}) : getTensorsStringKey({input_t});
      string key =  string("norm_out_mps:") + [ns_key UTF8String] + ":" + tensor_key + ":p" + to_string(p) + ":" + keepdim_info;

    auto cachedGraph = cache_->LookUpAs<MPSBinaryCachedGraph>(key);

    if(!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<MPSBinaryCachedGraph>(key, ^ MPSCachedGraph * () {

        MPSBinaryCachedGraph *newCachedGraph = nil;

        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new MPSBinaryCachedGraph(mpsGraph);
          newCachedGraph->inputTensor_ = mpsGraphRankedPlaceHolder(mpsGraph, input_tensor);

          if (cdist) {
            newCachedGraph->otherTensor_ = mpsGraphRankedPlaceHolder(mpsGraph, other_tensor);
          }

          MPSGraphTensor* inputTensor = cdist ? normOpBlock(newCachedGraph, newCachedGraph->inputTensor_, newCachedGraph->otherTensor_) :
                                                newCachedGraph->inputTensor_;
          if (opt_dtype.has_value()) {
            inputTensor = [mpsGraph castTensor:inputTensor
                                        toType:mps_input_dtype
                                          name:@"castInputTensor"];
          }

          MPSGraphTensor *outputTensor;

          if (pIsZero) {
              MPSGraphTensor *absoluteTensor = [mpsGraph absoluteWithTensor:inputTensor
                                                                       name:nil];
              MPSGraphTensor *powerValTensor = [mpsGraph constantWithScalar:p
                                                                   dataType:mps_input_dtype];
              MPSGraphTensor *powerTensor = [mpsGraph powerWithPrimaryTensor:absoluteTensor
                                                             secondaryTensor:powerValTensor
                                                                        name:nil];
              outputTensor = [mpsGraph reductionSumWithTensor:powerTensor
                                                         axes:wrappedAxes
                                                         name:nil];
          }
          else if (pIsPosInf) {
              MPSGraphTensor *absoluteTensor = [mpsGraph absoluteWithTensor:inputTensor
                                                                       name:nil];
              outputTensor = [mpsGraph reductionMaximumWithTensor:absoluteTensor
                                                             axes:wrappedAxes
                                                             name:nil];
          }
          else if (pIsNegInf) {
              MPSGraphTensor *absoluteTensor = [mpsGraph absoluteWithTensor:inputTensor
                                                                       name:nil];
              outputTensor = [mpsGraph reductionMinimumWithTensor:absoluteTensor
                                                             axes:wrappedAxes
                                                             name:nil];
          } else {
              MPSGraphTensor *absoluteTensor = [mpsGraph absoluteWithTensor:inputTensor
                                                                       name:nil];

              MPSGraphTensor *powerValTensor = [mpsGraph constantWithScalar:p
                                                                   dataType:mps_input_dtype];

              MPSGraphTensor *reciprocalPowerValTensor = [mpsGraph constantWithScalar:reciprocal_p
                                                                             dataType:mps_input_dtype];

              MPSGraphTensor *powerTensor = [mpsGraph powerWithPrimaryTensor:absoluteTensor
                                                             secondaryTensor:powerValTensor
                                                                        name:nil];

              MPSGraphTensor *reductionSumTensor = [mpsGraph reductionSumWithTensor:powerTensor
                                                                         axes:wrappedAxes
                                                                         name:nil];

              outputTensor = [mpsGraph powerWithPrimaryTensor:reductionSumTensor
                                              secondaryTensor:reciprocalPowerValTensor
                                                         name:nil];
          }

          if (cdist) {
            outputTensor= [mpsGraph reshapeTensor:outputTensor withShape:mps::getMPSShape(output_t) name: nil];
          }

          newCachedGraph->outputTensor_ = outputTensor;
        }
        return newCachedGraph;
      });
    }

    auto otherPlaceholder = Placeholder();
    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, apparent_output_shape);

    NSMutableDictionary<MPSGraphTensor*, MPSGraphTensorData*>* feeds =[NSMutableDictionary dictionary];
    feeds[inputPlaceholder.getMPSGraphTensor()]   = inputPlaceholder.getMPSGraphTensorData();

    if (cdist) {
      otherPlaceholder = Placeholder(cachedGraph->otherTensor_, other_tensor);
      feeds[otherPlaceholder.getMPSGraphTensor()] = otherPlaceholder.getMPSGraphTensorData();
    }

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData()
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

TORCH_IMPL_FUNC(norm_out_mps)
(const Tensor& self,
 const OptionalScalarRef opt_p,
 IntArrayRef dim,
 bool keepdim,
 const Tensor& result) {
  impl_func_norm_mps(self, self, opt_p, dim, keepdim, c10::nullopt, result, /*cdist=*/false);
}

TORCH_IMPL_FUNC(norm_dtype_out_mps)
(const Tensor& self,
 const OptionalScalarRef opt_p,
 IntArrayRef dim,
 bool keepdim,
 ScalarType dtype,
 const Tensor& result) {
  impl_func_norm_mps(self, self, opt_p, dim, keepdim, dtype, result, /*cdist=*/false);
}

Tensor _cdist_forward_mps(const Tensor& x1, const Tensor& x2, const double p, c10::optional<int64_t> compute_mode) {
  using namespace mps;
  TORCH_CHECK(x1.dim() >= 2, "cdist only supports at least 2D tensors, X1 got: ", x1.dim(), "D");
  TORCH_CHECK(x2.dim() >= 2, "cdist only supports at least 2D tensors, X2 got: ", x2.dim(), "D");
  TORCH_CHECK(x1.size(-1) == x2.size(-1), "X1 and X2 must have the same number of columns. X1: ", x1.size(-1), " X2: ", x2.size(-1));
  TORCH_CHECK(at::isFloatingType(x1.scalar_type()), "cdist only supports floating-point dtypes, X1 got: ", x1.scalar_type());
  auto device1 = x1.device().type();
  TORCH_CHECK(at::isFloatingType(x2.scalar_type()), "cdist only supports floating-point dtypes, X2 got: ", x2.scalar_type());
  auto device2 = x2.device().type();
  TORCH_CHECK(p >= 0, "cdist only supports non-negative p values");
  TORCH_CHECK(device1 == device2, "X1 and X2 must have the same device type. X1: ", device1, " X2: ", device2);
  TORCH_CHECK(x1.is_mps() && (x1.get_device() == x2.get_device()), "device of X1 (", x1.get_device(), ") must match device of X2 (", x2.get_device(), ")");

  int64_t c1 = x1.size(-1);
  int64_t c2 = x2.size(-1);

  auto dim1 = x1.dim();
  auto dim2 = x2.dim();
  int64_t mode = compute_mode.value_or(0);
  TORCH_CHECK(mode >= 0 && mode <= 2, "possible modes: 0, 1, 2, but was: ", mode);

  int64_t r1 = x1.size(-2);
  int64_t r2 = x2.size(-2);

  //For batch calculation we expand all dimensions(except the last two) to one, with size that equals to product of them.
  //The last two dimensions will stay the same
  IntArrayRef batch_tensor1(x1.sizes().data(), dim1 - 2);
  IntArrayRef batch_tensor2(x2.sizes().data(), dim2 - 2);
  std::vector<int64_t> expand_batch_portion = infer_size(batch_tensor1, batch_tensor2);
  std::vector<int64_t> tensor1_expand_size(expand_batch_portion);
  tensor1_expand_size.insert(tensor1_expand_size.end(), {r1, c1});
  std::vector<int64_t> tensor2_expand_size(expand_batch_portion);
  tensor2_expand_size.insert(tensor2_expand_size.end(), {r2, c2});

  const int64_t expand_batch_product = c10::multiply_integers(expand_batch_portion);
  std::vector<int64_t> tensor1_view{expand_batch_product, r1, c1};
  std::vector<int64_t> tensor2_view{expand_batch_product, r2, c2};

  std::vector<int64_t> output_shape(expand_batch_portion);
  output_shape.insert(output_shape.end(), {r1, r2});
  Tensor result = at::empty(output_shape, x1.options());

  NormOpBlock norm_op_block = ^NormOpFn(cachedGraph, x1Tensor, x2Tensor) {
    MPSGraph* mpsGraph = cachedGraph->graph();

    MPSGraphTensor* inputBroadcast = [mpsGraph broadcastTensor:x1Tensor toShape:getMPSShape(tensor1_expand_size) name:nil];
    MPSGraphTensor* inputBroadcastReshape = [mpsGraph reshapeTensor:inputBroadcast withShape:getMPSShape(tensor1_view) name:nil];

    MPSGraphTensor* otherBroadcast = [mpsGraph broadcastTensor:x2Tensor toShape:getMPSShape(tensor2_expand_size) name:nil];
    MPSGraphTensor* otherBroadcastReshape = [mpsGraph reshapeTensor:otherBroadcast withShape:getMPSShape(tensor2_view) name:nil];

    NSMutableArray<MPSGraphTensor*> *inputArray = [NSMutableArray arrayWithCapacity:tensor1_view[1]];
    NSMutableArray<MPSGraphTensor*> *otherArray = [NSMutableArray arrayWithCapacity:tensor2_view[1]];

    for (const auto i : c10::irange(tensor2_view[1])) {
      inputArray[i] = inputBroadcastReshape;
    }

    for (const auto i : c10::irange(tensor1_view[1])) {
      otherArray[i] = otherBroadcastReshape;
    }

    MPSGraphTensor *inputTensorReshaped = [mpsGraph concatTensors:inputArray dimension:1 interleave:YES name:nil];
    MPSGraphTensor *otherTensorReshaped = [mpsGraph concatTensors:otherArray dimension:1 interleave:NO name:nil];


    MPSGraphTensor *inputTensorPNorm = [mpsGraph subtractionWithPrimaryTensor: inputTensorReshaped
                                                              secondaryTensor: otherTensorReshaped
                                                                         name: nil];
    return inputTensorPNorm;
  };

  c10::optional<IntArrayRef> inputBroadcastSize = c10::make_optional(makeArrayRef(tensor1_view.data(), tensor1_view.size()));
  impl_func_norm_mps(x1, x2, OptionalScalarRef(p), makeArrayRef<int64_t>(2), false, c10::nullopt, result, /*cdist=*/true, inputBroadcastSize, norm_op_block);
  return result;
}

Tensor std_var_common_impl_mps(
  const Tensor & input_t,
  at::OptionalIntArrayRef dim,
  c10::optional<int64_t> correction,
  bool keepdim,
  StdVarType stdVarType) {
  using CachedGraph = MPSUnaryCachedGraph;

  IntArrayRef input_shape = input_t.sizes();
  int64_t num_input_dims = input_shape.size();

  bool use_dim = dim.has_value();
  IntArrayRef dim_value = use_dim ? dim.value() : NULL;

  if (use_dim) {
    string errMessage = (stdVarType == STANDARD_DEVIATION) ? "std_mps" : "var_mps";
    errMessage += ": reduction dim must be in the range of input shape";
    for (const auto dim : dim_value) {
      auto wrap_dim = maybe_wrap_dim(dim, input_shape.size());
      TORCH_CHECK(wrap_dim < input_shape.size(), errMessage.c_str())
    }
  }

  bool use_correction = !(correction.has_value() && correction.value() == 0);
  const auto correction_value = correction.value_or(1);
  int64_t correction_n = 1;

  MPSGraphCache* cache_ = MPSGraphCache::getInstance();
  NSArray<NSNumber*>* wrappedAxes = getTensorAxes(input_t, dim);

  int64_t num_output_dims = 0;
  NSMutableArray<NSNumber *> *axes = nil;
  NSMutableArray<NSNumber*> *apparent_output_shape = nil;
  NSMutableArray<NSNumber*> *apparent_input_shape = nil;
  std::vector<int64_t> output_shape;

  if ((!keepdim && !use_dim) || (!keepdim && use_dim && dim_value.size() <= 0)) {
    // Flatten the input tensor to reduce it to one value
    apparent_input_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
    int64_t num_in_elements = c10::multiply_integers(input_shape);
    apparent_input_shape[0] = [NSNumber numberWithInt:num_in_elements];

    // Output is a single value
    apparent_output_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
    apparent_output_shape[0] = @1;

    num_output_dims = 0;

    correction_n = num_in_elements;

    // Reduction axes
    axes = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
    axes[0] = @0;
  } else if (!keepdim && use_dim && dim_value.size() > 0) {
    int64_t num_reduce_dims = dim_value.size();
    num_output_dims = num_input_dims;

    set_axes(axes, num_reduce_dims, dim_value, num_input_dims);
    set_apparent_shapes(apparent_output_shape,
                         apparent_input_shape,
                         num_reduce_dims,
                         num_output_dims,
                         input_shape,
                         axes);

    num_output_dims = (num_input_dims >= num_reduce_dims) ? (num_input_dims - num_reduce_dims) : 0; //num_input_dims;

    unsigned int curr_i = 0;
    for (const auto i: c10::irange(num_input_dims)) {
      bool found = false;
      for (const auto j: c10::irange(num_reduce_dims)) {
        if (i == dim_value[j]) {
          found = true;
          break;
        }
      }
      if (found) {
        continue;
      }
      output_shape.push_back(input_shape[i]);
      curr_i += 1;
      // End loop when output shape is filled
      if (curr_i == num_output_dims) {
        break;
      }
    }

    for (const auto dim : dim_value) {
      auto wrap_dim = maybe_wrap_dim(dim, input_shape.size());
      correction_n *= input_shape[wrap_dim];
    }
    // (3, 4, 5) --> (3, 5)
  } else if ((keepdim && !use_dim) || (keepdim && use_dim && dim_value.size() <= 0)) {
    num_output_dims = 0;
    int64_t num_reduce_dims = 0;
    set_axes(axes, num_reduce_dims, dim_value, input_shape.size());
    set_apparent_shapes(apparent_output_shape,
                        apparent_input_shape,
                        num_reduce_dims,
                        num_output_dims,
                        input_shape,
                        axes);
    num_output_dims = num_input_dims;
    for (const auto i: c10::irange(num_input_dims)) {
      output_shape.push_back((int64_t) 1);
      correction_n *= input_shape[i];
    }
    // scalar --> vector case [[1.0034567]]
  } else if (keepdim && use_dim && dim_value.size() > 0) {
    int64_t num_reduce_dims = dim_value.size();
    num_output_dims = num_input_dims;

    set_axes(axes, num_reduce_dims, dim_value, num_input_dims);
    set_apparent_shapes(apparent_output_shape,
                        apparent_input_shape,
                        num_reduce_dims,
                        num_output_dims,
                        input_shape,
                        axes);

    num_output_dims = num_input_dims;//(num_input_dims >= num_reduce_dims) ? (num_input_dims - num_reduce_dims) : 0;

    for(const int i : c10::irange(num_reduce_dims)) {
      auto wrap_dim = maybe_wrap_dim(dim_value[i], input_shape.size());
      correction_n *= input_shape[wrap_dim];
    }

    for (const int i : c10::irange(num_input_dims)) {
      output_shape.push_back([apparent_output_shape[i] longValue]);
    }
  }

  Tensor output_t = at::native::empty_mps(
                      IntArrayRef(output_shape.data(), num_output_dims),
                      input_t.scalar_type(),
                      c10::nullopt,
                      kMPS,
                      c10::nullopt,
                      c10::nullopt);

  if (output_t.numel() == 0 || input_t.numel() == 0) {
    return output_t;
  }

  double bessel_correction = static_cast<double>(correction_n) / static_cast<double>(correction_n - correction_value);
  auto stream = at::mps::getCurrentMPSStream();

  @autoreleasepool {
    string op_key = (stdVarType == STANDARD_DEVIATION) ? "std_mps" : "var_mps";
    NSString* ns_key = [[wrappedAxes valueForKey:@"description"] componentsJoinedByString:@","];
    string bessel_corrected = (use_correction && correction_value) ? "unbiased " : "biased ";
    string use_dim_info = (use_dim) ? "use_dim=1:" + to_string(dim_value.size()) : "use_dim=0";
    string keepdim_info = (keepdim) ? "keepdim=1" : "keepdim=0";
    string key = op_key                                   + ":" +
                 getTensorsStringKey(input_t) + ":" +
                 use_dim_info                             + ":" +
                 keepdim_info                             + ":" +
                 string([ns_key UTF8String])              + ":" +
                 bessel_corrected                         + ":" +
                 std::to_string(correction_value);

    auto cachedGraph = cache_->LookUpAs<CachedGraph>(key);
    // Initialize once if configuration not found in cache
    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;

        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor *inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_t);
          MPSGraphTensor *outputVarTensor = [mpsGraph varianceOfTensor:inputTensor
                                                                  axes:wrappedAxes
                                                                  name:nil];
          MPSGraphTensor *outputTensor = nil;

          if (use_correction && correction_value) {
              MPSGraphTensor *besselTensor= [mpsGraph constantWithScalar:bessel_correction
                                                                dataType:getMPSDataType(input_t.scalar_type())];
              MPSGraphTensor *correctedTensor = [mpsGraph multiplicationWithPrimaryTensor:outputVarTensor
                                                                          secondaryTensor:besselTensor
                                                                                     name:nil];
              outputTensor = (stdVarType == STANDARD_DEVIATION) ?
                    [mpsGraph squareRootWithTensor:correctedTensor name:nil] : correctedTensor;
          } else {
              outputTensor = (stdVarType == STANDARD_DEVIATION) ?
                    [mpsGraph squareRootWithTensor:outputVarTensor name:nil] : outputVarTensor;
          }
          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
        }
        return newCachedGraph;
      });
  }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, apparent_output_shape);

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
        inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
        outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData()
    };
    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }

  return output_t;
}

Tensor var_mps(
  const Tensor & input_t,
  at::OptionalIntArrayRef dim,
  c10::optional<int64_t> correction,
  bool keepdim)
{
  return std_var_common_impl_mps(input_t, dim, correction, keepdim, STANDARD_VARIANCE);
}

Tensor std_mps(
   const Tensor & input_t,
   at::OptionalIntArrayRef dim,
   c10::optional<int64_t> correction,
   bool keepdim)
{
  return std_var_common_impl_mps(input_t, dim, correction, keepdim, STANDARD_DEVIATION);
}

TORCH_IMPL_FUNC(any_out_mps)
  (const Tensor& input_t,
   int64_t dim,
   bool keepdim,
   const Tensor& output_t)
{
  using CachedGraph = MPSUnaryCachedGraph;

  if (output_t.numel() == 0 || input_t.numel() == 0) {
    return;
  }

  MPSGraphCache* cache_ = MPSGraphCache::getInstance();
  int64_t dim_ = maybe_wrap_dim(dim, input_t.dim());
  native::zero_numel_check_dims(input_t, dim_, "any()");

  // Calculate the output shape according to keepdim=True
  // If there is no dim argument, the input shape is flattened
  IntArrayRef input_shape = input_t.sizes();
  int64_t num_input_dims = input_shape.size();
  NSMutableArray<NSNumber*> *apparent_out_shape = nil;
  apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_input_dims];
  for (const auto i: c10::irange(num_input_dims)) {
    apparent_out_shape[i] = dim_ == i ? @1 : [NSNumber numberWithInt:input_shape[i]];
  }

  auto stream = at::mps::getCurrentMPSStream();

  @autoreleasepool {
    MPSShape* input_t_shape = getMPSShape(input_t);
    string key = string("any_out_mps:") + getMPSShapeString(input_t_shape) + ":" + to_string(dim_) + ":" + getMPSTypeString(input_t.scalar_type());
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);

    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;
        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* outputTensor;
          MPSDataType input_type = getMPSDataType(input_t.scalar_type());
          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_type, input_t_shape);

          if (input_type != MPSDataTypeInt32 &&
              input_type != MPSDataTypeFloat32 &&
              input_type != MPSDataTypeFloat16) {
            MPSGraphTensor* inputCastedTensor = [mpsGraph castTensor:inputTensor
                                                              toType:MPSDataTypeInt32
                                                                name:@"any_all"];
            MPSGraphTensor* outputCastedTensor = [mpsGraph reductionOrWithTensor:inputCastedTensor
                                                                              axis:dim_
                                                                              name:nil];
            outputTensor = [mpsGraph castTensor:outputCastedTensor
                                          toType:MPSDataTypeBool
                                            name:@"any"];
          } else {
            MPSGraphTensor* outputUncastedTensor = [mpsGraph reductionOrWithTensor:inputTensor
                                                                                axis:dim_
                                                                                name:nil];
            outputTensor = [mpsGraph castTensor:outputUncastedTensor
                                          toType:MPSDataTypeBool
                                            name:@"any"];
          }
          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, apparent_out_shape);
    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData(),
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

TORCH_IMPL_FUNC(any_all_out_mps)(const Tensor& input_t, const Tensor& output_t) {
  using CachedGraph = MPSUnaryCachedGraph;
  if (output_t.numel() == 0 || input_t.numel() == 0) {
    return;
  }

  auto cache_ = MPSGraphCache::getInstance();
  auto stream = at::mps::getCurrentMPSStream();

  @autoreleasepool {
    MPSShape* input_t_shape = getMPSShape(input_t);
    string key = string("any_all_out_mps:") + getMPSShapeString(input_t_shape) +":" + getMPSTypeString(input_t.scalar_type());
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);

    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {

        CachedGraph *newCachedGraph = nil;

        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* outputTensor;
          MPSDataType input_type = getMPSDataType(input_t.scalar_type());
          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_type, input_t_shape);

          if (input_type != MPSDataTypeInt32 &&
              input_type != MPSDataTypeFloat32 &&
              input_type != MPSDataTypeFloat16) {
              MPSGraphTensor* inputCastedTensor = [mpsGraph castTensor:inputTensor
                                                                toType:MPSDataTypeInt32
                                                                  name:@"any_all"];
              MPSGraphTensor* outputCastedTensor = [mpsGraph reductionOrWithTensor:inputCastedTensor
                                                                                axes:nil
                                                                                name:nil];
              outputTensor = [mpsGraph castTensor:outputCastedTensor
                                            toType:MPSDataTypeBool
                                              name:@"any_all"];
          } else {
              MPSGraphTensor* outputUncastedTensor = [mpsGraph reductionOrWithTensor:inputTensor
                                                                                  axes:nil
                                                                                  name:nil];
              outputTensor = [mpsGraph castTensor:outputUncastedTensor
                                            toType:MPSDataTypeBool
                                              name:@"any_all"];
          }
          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;

        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t);
    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData(),
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

TORCH_IMPL_FUNC(all_out_mps)
  (const Tensor& input_t,
   int64_t dim,
   bool keepdim,
   const Tensor& output_t)
{
  using CachedGraph = MPSUnaryCachedGraph;

  if (output_t.numel() == 0 || input_t.numel() == 0) {
    return;
  }

  MPSGraphCache* cache_ = MPSGraphCache::getInstance();
  int64_t dim_ = maybe_wrap_dim(dim, input_t.dim());
  native::zero_numel_check_dims(input_t, dim_, "all()");

  // Calculate the output shape according to keepdim=True
  // If there is no dim argument, the input shape is flattened
  IntArrayRef input_shape = input_t.sizes();
  int64_t num_input_dims = input_shape.size();
  NSMutableArray<NSNumber*> *apparent_out_shape = nil;
  apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_input_dims];
  for (const auto i : c10::irange(num_input_dims)) {
      apparent_out_shape[i] = dim_ == i ? @1 : [NSNumber numberWithInt:input_shape[i]];
  }

  auto stream = at::mps::getCurrentMPSStream();

  @autoreleasepool {
    MPSShape* input_t_shape = getMPSShape(input_t);
    string key = string("all_out_mps:") + getMPSShapeString(input_t_shape) + ":" + to_string(dim_) + ":" + getMPSTypeString(input_t.scalar_type());
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);

    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;
        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* outputTensor;
          MPSDataType input_type = getMPSDataType(input_t.scalar_type());
          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_type, input_t_shape);

          if (input_type != MPSDataTypeInt32 &&
              input_type != MPSDataTypeFloat32 &&
              input_type != MPSDataTypeFloat16 )
          {
              MPSGraphTensor* inputCastedTensor = [mpsGraph castTensor:inputTensor
                                                                toType:MPSDataTypeInt32
                                                                  name:@"all_all"];
              MPSGraphTensor* outputCastedTensor = [mpsGraph reductionAndWithTensor:inputCastedTensor
                                                                               axis:dim_
                                                                               name:nil];
              outputTensor = [mpsGraph castTensor:outputCastedTensor
                                           toType:MPSDataTypeBool
                                             name:@"all"];
          } else {
              MPSGraphTensor* outputUncastedTensor = [mpsGraph reductionAndWithTensor:inputTensor
                                                                                 axis:dim_
                                                                                 name:nil];
              outputTensor = [mpsGraph castTensor:outputUncastedTensor
                                           toType:MPSDataTypeBool
                                             name:@"all"];
          }
          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, apparent_out_shape);
    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData(),
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

TORCH_IMPL_FUNC(all_all_out_mps)(const Tensor& input_t, const Tensor& output_t) {
  using CachedGraph = MPSUnaryCachedGraph;
  if (output_t.numel() == 0 || input_t.numel() == 0) {
    return;
  }

  MPSGraphCache* cache_ = MPSGraphCache::getInstance();

  auto stream = at::mps::getCurrentMPSStream();

  @autoreleasepool {
    MPSShape* input_t_shape = getMPSShape(input_t);
    string key = string("all_all_out_mps:") + getMPSShapeString(input_t_shape) +":" + getMPSTypeString(input_t.scalar_type());
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);

    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;
        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* outputTensor;
          MPSDataType input_type = getMPSDataType(input_t.scalar_type());
          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_type, input_t_shape);

          if (input_type != MPSDataTypeInt32 &&
              input_type != MPSDataTypeFloat32 &&
              input_type != MPSDataTypeFloat16) {
              MPSGraphTensor* inputCastedTensor = [mpsGraph castTensor:inputTensor
                                                                toType:MPSDataTypeInt32
                                                                  name:@"all_all"];
              MPSGraphTensor* outputCastedTensor = [mpsGraph reductionAndWithTensor:inputCastedTensor
                                                                               axes:nil
                                                                               name:nil];
              outputTensor = [mpsGraph castTensor:outputCastedTensor
                                           toType:MPSDataTypeBool
                                             name:@"all_all"];
          } else {
              MPSGraphTensor* outputUncastedTensor = [mpsGraph reductionAndWithTensor:inputTensor
                                                                                 axes:nil
                                                                                 name:nil];
              outputTensor = [mpsGraph castTensor:outputUncastedTensor
                                           toType:MPSDataTypeBool
                                             name:@"all_all"];
          }
          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;

        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t);
    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData(),
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

//-----------------------------------------------------------------------
// Min and max functions

Tensor min_max_mps
  (const Tensor& input_t,
   MPSReductionType reduction_type,
   const std::string& func_name) {
  TORCH_CHECK(input_t.scalar_type() != ScalarType::Long, "MPS does not support min/max ops with int64 input");

  using CachedGraph = MPSUnaryCachedGraph;

  MPSGraphCache* cache_ = MPSGraphCache::getInstance();
  IntArrayRef input_shape = input_t.sizes();
  int64_t num_in_elements = c10::multiply_integers(input_shape);

  Tensor output_t = at::native::empty_mps({}, input_t.scalar_type(), c10::nullopt, kMPS, c10::nullopt, c10::nullopt);

  if (output_t.numel() == 0 || num_in_elements == 0) {
    return output_t;
  }

  @autoreleasepool {
    string key = func_name + mps::getTensorsStringKey(input_t);
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);
    // Initialize once if configuration not found in cache
    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;
        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_t);

          MPSGraphTensor* outputTensor = nil;
          MPSGraphTensor* castInputTensor = nil;

          if (input_t.scalar_type() != ScalarType::Float &&
              input_t.scalar_type() != ScalarType::Int   &&
              input_t.scalar_type() != ScalarType::Half) {
            castInputTensor =  [mpsGraph castTensor:inputTensor
                                             toType:MPSDataTypeInt32
                                               name:@"castInputTensor"];
          } else {
            castInputTensor = inputTensor;
          }

          NSArray<NSNumber*>* axes = getTensorAxes(input_t);
          if (reduction_type == MPSReductionType::MAX) {
            outputTensor = [mpsGraph reductionMaximumWithTensor:castInputTensor
                                                           axes:axes
                                                           name:nil];
          } else if(reduction_type == MPSReductionType::MIN) {
            outputTensor = [mpsGraph reductionMinimumWithTensor:castInputTensor
                                                           axes:axes
                                                           name:nil];
          }

          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, @[@1]);

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData()
    };

    runMPSGraph(getCurrentMPSStream(), cachedGraph->graph(), feeds, results);
  }

  return output_t;
}

// Max entire tensor into scalar result
Tensor max_mps(const Tensor& input_t) {

  return min_max_mps(input_t, MPSReductionType::MAX, "max_mps");
}

// Min entire tensor into scalar result
Tensor min_mps(const Tensor& input_t) {

  return min_max_mps(input_t, MPSReductionType::MIN, "min_mps");
}

void min_max_out_mps
  (const Tensor& input_t,
  int64_t dim,
  bool keepdim,
  const Tensor& output_t,
  const Tensor& indices_t,
  MPSReductionType reduction_type,
  const std::string& func_name) {
  TORCH_CHECK(input_t.scalar_type() != ScalarType::Long, "MPS does not support min/max ops with int64 input");

  if (output_t.numel() == 0) {
    return;
  }
  if (input_t.numel() == 1 && input_t.dim() == 0) {
    output_t.fill_(input_t);
    indices_t.fill_(0);
    return;
  }

  // Derive from MPSCachedGraph
  struct CachedGraph : public MPSCachedGraph
  {
    CachedGraph(MPSGraph *graph) : MPSCachedGraph(graph) {}
    MPSGraphTensor *inputTensor_ = nil;
    MPSGraphTensor *outputTensor_ = nil;
    MPSGraphTensor *indicesTensor_ = nil;
  };

  MPSGraphCache* cache_ = MPSGraphCache::getInstance();

  int64_t dim_ = maybe_wrap_dim(dim, input_t.dim());

  // Calculate the output shape according to keepdim=True
  // If there is no dim argument, the input shape is flattened
  IntArrayRef input_shape = input_t.sizes();
  int64_t num_input_dims = input_shape.size();
  NSMutableArray<NSNumber*> *apparent_out_shape = nil;

  apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_input_dims];
  for (const auto i: c10::irange(num_input_dims)) {
    apparent_out_shape[i] = dim_ == i ? @1: [NSNumber numberWithInt:input_shape[i]];
  }

  auto stream = at::mps::getCurrentMPSStream();

  @autoreleasepool {
    string key = func_name + getTensorsStringKey({input_t, indices_t}) + ":" + to_string(dim_);
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);

    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;
        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_t);
          MPSGraphTensor* outputTensor = nil;
          if (reduction_type == MPSReductionType::MAX) {
            outputTensor = [mpsGraph reductionMaximumWithTensor:inputTensor
                                                           axis:(NSInteger)dim_
                                                           name:nil];
          } else if (reduction_type == MPSReductionType::MIN) {
            outputTensor = [mpsGraph reductionMinimumWithTensor:inputTensor
                                                           axis:(NSInteger)dim_
                                                           name:nil];
          }

          MPSGraphTensor* castInputTensor = nil;

          if (input_t.scalar_type() != ScalarType::Float &&
              input_t.scalar_type() != ScalarType::Int   &&
              input_t.scalar_type() != ScalarType::Half) {
            castInputTensor =  [mpsGraph castTensor:inputTensor
                                             toType:MPSDataTypeInt32
                                               name:@"castInputTensor"];
          } else {
            castInputTensor = inputTensor;
          }

          MPSGraphTensor* argreduceOutTensor = nil;
          if (reduction_type == MPSReductionType::MAX) {
            argreduceOutTensor = [mpsGraph reductionArgMaximumWithTensor: castInputTensor
                                                                    axis: (NSInteger)dim_
                                                                    name: @"argmax_out"];
          } else if (reduction_type == MPSReductionType::MIN) {
            argreduceOutTensor = [mpsGraph reductionArgMinimumWithTensor: castInputTensor
                                                                    axis: (NSInteger)dim_
                                                                    name: @"argmax_out"];
          }
          MPSGraphTensor *indicesTensor = [mpsGraph castTensor: argreduceOutTensor
                                                        toType: MPSDataTypeInt64
                                                          name: @"cast_out"];

          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
          newCachedGraph->indicesTensor_ = indicesTensor;
        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, apparent_out_shape);
    auto indicesPlaceholder = Placeholder(cachedGraph->indicesTensor_, indices_t, apparent_out_shape);

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData(),
      indicesPlaceholder.getMPSGraphTensor() : indicesPlaceholder.getMPSGraphTensorData()
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

// Max out with dim
TORCH_IMPL_FUNC(max_out_mps)
  (const Tensor& input_t,
   int64_t dim,
   bool keepdim,
   const Tensor& output_t,
   const Tensor& indices_t) {

    int64_t dim_ = maybe_wrap_dim(dim, input_t.dim());
    native::zero_numel_check_dims(input_t, dim_,  "max()");

    min_max_out_mps(input_t, dim, keepdim, output_t, indices_t, MPSReductionType::MAX, "max_out_mps");
}

// Min out with dim
TORCH_IMPL_FUNC(min_out_mps)
  (const Tensor& input_t,
   int64_t dim,
   bool keepdim,
   const Tensor& output_t,
   const Tensor& indices_t) {

    int64_t dim_ = maybe_wrap_dim(dim, input_t.dim());
    native::zero_numel_check_dims(input_t, dim_, "min()");

    min_max_out_mps(input_t, dim, keepdim, output_t, indices_t, MPSReductionType::MIN, "min_out_mps");
}

void argmax_argmin_out_mps
   (const Tensor& input_t,
    c10::optional<int64_t> dim,
    bool keepdim,
    const Tensor& output_t,
    MPSReductionType reduction_type,
    const std::string& func_name) {
  using CachedGraph = MPSUnaryCachedGraph;
  auto cache_ = MPSGraphCache::getInstance();

  int64_t dim_ = -1;

  if (dim.has_value()) {
      dim_ = maybe_wrap_dim(dim.value(), input_t.dim());
      zero_numel_check_dims(input_t, dim_, reduction_type == MPSReductionType::MAX ? "argmax()" : "argmin()");
  } else {
      TORCH_CHECK_INDEX(
      input_t.numel() != 0,
      reduction_type == MPSReductionType::MAX ? "argmax()" : "argmin()" , ": Expected reduction dim to be specified for input.numel() == 0.");
      // Since input will be flattened, take argmax or argmin along 0'th dimension
      dim_ = 0;
  }

  // Calculate the output shape according to keepdim=True
  // If there is no dim argument, the input shape is flattened
  IntArrayRef input_shape = input_t.sizes();
  int64_t num_input_dims = input_shape.size();
  NSMutableArray<NSNumber*> *apparent_in_shape = nil;
  NSMutableArray<NSNumber*> *apparent_out_shape = nil;

  if (dim.has_value()) {
    apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_input_dims];
    for (const auto i : c10::irange(num_input_dims)) {
      apparent_out_shape[i] = dim_ == i ? @1 : [NSNumber numberWithInt:input_shape[i]];
    }
  } else {
    apparent_in_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
    int64_t num_in_elements = c10::multiply_integers(input_shape);
    apparent_in_shape[0] = [NSNumber numberWithInt:num_in_elements];

    apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
    apparent_out_shape[0] = @1;
  }

  if (output_t.numel() == 0) {
      return;
  }

  if (!apparent_in_shape) {
    apparent_in_shape = [getMPSShape(input_t.sizes()) mutableCopy];
  }

  auto stream = at::mps::getCurrentMPSStream();
  @autoreleasepool {
    NSString* ns_key = [[apparent_in_shape valueForKey:@"description"] componentsJoinedByString:@","];
    string key = func_name                                + ":" +
                 to_string(dim_)                          + ":" +
                 getTensorsStringKey(input_t) + ":" +
                 string([ns_key UTF8String]);
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);

    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;
        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, getMPSDataType(input_t.scalar_type()), apparent_in_shape);

          MPSGraphTensor* castInputTensor = inputTensor;
          MPSGraphTensor* argreduceOutTensor = nil;

          if (input_t.scalar_type() != ScalarType::Float &&
              input_t.scalar_type() != ScalarType::Int   &&
              input_t.scalar_type() != ScalarType::Half) {
            castInputTensor =  [mpsGraph castTensor: inputTensor
                                             toType: MPSDataTypeFloat32
                                               name: @"castInputTensor"];
          }

          if (reduction_type == MPSReductionType::MAX) {
            argreduceOutTensor = [mpsGraph reductionArgMaximumWithTensor: castInputTensor
                                                                    axis: (NSInteger)dim_
                                                                    name: nil];
          } else {
            argreduceOutTensor = [mpsGraph reductionArgMinimumWithTensor: castInputTensor
                                                                    axis: (NSInteger)dim_
                                                                    name: nil];
          }
          MPSGraphTensor* outputTensor = [mpsGraph castTensor: argreduceOutTensor
                                                       toType: MPSDataTypeInt64
                                                         name: @"castOutputTensor"];

          MPSGraphTensor* outputClampedTensor = [mpsGraph clampWithTensor: outputTensor
                                                           minValueTensor: [mpsGraph constantWithScalar:0 dataType:MPSDataTypeInt64]
                                                           maxValueTensor: [mpsGraph constantWithScalar:LLONG_MAX dataType:MPSDataTypeInt64]
                                                                     name: nil];

          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputClampedTensor;
        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t, apparent_in_shape);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, apparent_out_shape);

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData()
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

TORCH_IMPL_FUNC(argmax_out_mps)
   (const Tensor& input_t,
    c10::optional<int64_t> dim,
    bool keepdim,
    const Tensor& output_t) {

    argmax_argmin_out_mps(input_t, dim, keepdim, output_t, MPSReductionType::MAX, "argmax_out_mps");
}

TORCH_IMPL_FUNC(argmin_out_mps)
   (const Tensor& input_t,
    c10::optional<int64_t> dim,
    bool keepdim,
    const Tensor& output_t) {

    argmax_argmin_out_mps(input_t, dim, keepdim, output_t, MPSReductionType::MIN, "argmin_out_mps");
}

// Min/Max with dim
std::tuple<Tensor, Tensor> min_max_mps(
  const Tensor& input_t,
  int64_t dim,
  bool keepdim,
  MPSReductionType reduction_type,
  const std::string& func_name) {
  int64_t dim_ = maybe_wrap_dim(dim, input_t.dim());
  native::zero_numel_check_dims(input_t, dim_, "max()");

  // Calculate the output shape according to keepdim=True
  // If there is no dim argument, the input shape is flattened
  IntArrayRef input_shape = input_t.sizes();
  int64_t num_input_dims = input_shape.size();
  NSMutableArray<NSNumber*> *apparent_out_shape = nil;
  // Use this if keepdim is false
  int64_t num_output_dims = num_input_dims - 1;

  std::vector<int64_t> vec_apparent_out_shape(num_input_dims);
  std::vector<int64_t> vec_out_shape(num_output_dims);

  apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_input_dims];
  // Counter for shape when keepdim is false
  int out_i = 0;
  for (const auto i: c10::irange(num_input_dims)) {
    if (dim_ == i) {
      apparent_out_shape[i] = @1;
      vec_apparent_out_shape[i] = 1;
    } else {
      apparent_out_shape[i] = [NSNumber numberWithInt:input_shape[i]];
      vec_apparent_out_shape[i] = input_shape[i];
      vec_out_shape[out_i] = input_shape[i];
      out_i++;
    }
  }

  Tensor output_t;
  Tensor indices_t;
  if (!keepdim) {
    output_t = at::native::empty_mps(
                    IntArrayRef(vec_out_shape),
                    input_t.scalar_type(),
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);
    indices_t = at::native::empty_mps(
                    IntArrayRef(vec_out_shape),
                    ScalarType::Long,
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);
  } else {
    output_t = at::native::empty_mps(
                    IntArrayRef(vec_apparent_out_shape),
                    input_t.scalar_type(),
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);
    indices_t = at::native::empty_mps(
                    IntArrayRef(vec_apparent_out_shape),
                    ScalarType::Long,
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);
  }

  if (output_t.numel() == 0 || input_t.numel() == 0) {
      return std::tuple<Tensor, Tensor>{output_t, indices_t};
  }

  min_max_out_mps(input_t, dim, keepdim, output_t, indices_t, reduction_type, func_name);

  return std::tuple<Tensor, Tensor>{output_t, indices_t};
}

// Max with dim
std::tuple<Tensor, Tensor> max_mps(const Tensor& input_t, int64_t dim, bool keepdim) {
  return min_max_mps(input_t, dim, keepdim, MPSReductionType::MAX, "max_mps");
}

// Min with dim
std::tuple<Tensor, Tensor> min_mps(const Tensor& input_t, int64_t dim, bool keepdim) {
  return min_max_mps(input_t, dim, keepdim, MPSReductionType::MIN, "min_mps");
}

// Median of entire tensor into scalar result
Tensor median_mps(const Tensor& input_t) {
  if (!is_macos_13_or_newer()){
    TORCH_WARN_ONCE("MPS: median op is supported natively starting from macOS 13.0. ",
                "Falling back on CPU. This may have performace implications.");
    return at::median(input_t.to("cpu"));
  }

  TORCH_CHECK(input_t.scalar_type() != ScalarType::Long, "MPS does not support median op with int64 input");

  using CachedGraph = MPSUnaryCachedGraph;

  MPSGraphCache* cache_ = MPSGraphCache::getInstance();

  IntArrayRef input_shape = input_t.sizes();

  // calculate total no. of elements in the input tensor to reduce it to one dimension
  NSMutableArray<NSNumber*> *apparent_input_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:1];
  int64_t num_in_elements = c10::multiply_integers(input_shape);

  apparent_input_shape[0] = [NSNumber numberWithInt:num_in_elements];

  Tensor output_t = at::native::empty_mps({}, input_t.scalar_type(), c10::nullopt, kMPS, c10::nullopt, c10::nullopt);

  if (output_t.numel() == 0 || num_in_elements == 0) {
    return output_t;
  }

  @autoreleasepool {
    string key = "median_mps:"+ mps::getMPSTypeString(input_t.scalar_type())  + mps::getTensorsStringKey(input_t);
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);
    // Initialize once if configuration not found in cache
    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;
        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          auto inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_t);
          auto reshapedTensor = [mpsGraph reshapeTensor: inputTensor
                                              withShape: @[@-1]
                                                   name: nil];
          auto sortedTensor = [mpsGraph sortWithTensor: reshapedTensor
                                                  axis: ((NSUInteger) (int)0)
                                                  name: nil];
          auto outputTensor = [mpsGraph sliceTensor: sortedTensor
                                          dimension: 0
                                              start: ((NSUInteger) (int)((num_in_elements+1)/2 ) - 1)
                                             length: 1
                                               name: nil];

          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, @[@1]);

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData()
    };

    runMPSGraph(getCurrentMPSStream(), cachedGraph->graph(), feeds, results);
  }

  return output_t;
}


void median_out_mps(
  const Tensor& input_t,
  int64_t dim,
  bool keepdim,
  const Tensor& output_t,
  const Tensor& indices_t,
  const std::string& func_name) {
  if (output_t.numel() == 0) {
    return;
  }

  if (input_t.numel() == 1 && input_t.dim() == 0) {
    output_t.fill_(input_t);
    indices_t.fill_(0);
    return;
  }

  // Derive from MPSCachedGraph
  struct CachedGraph : public MPSCachedGraph
  {
    CachedGraph(MPSGraph *graph) : MPSCachedGraph(graph) {}
    MPSGraphTensor *inputTensor_ = nil;
    MPSGraphTensor *outputTensor_ = nil;
    MPSGraphTensor *indicesTensor_ = nil;
  };

  auto cache_ = MPSGraphCache::getInstance();

  int64_t dim_ = maybe_wrap_dim(dim, input_t.dim());

  // Calculate the output shape according to keepdim=True
  // If there is no dim argument, the input shape is flattened
  IntArrayRef input_shape = input_t.sizes();
  int64_t num_input_dims = input_shape.size();
  NSMutableArray<NSNumber*> *apparent_out_shape = nil;

  apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_input_dims];
  for (const int i : c10::irange(num_input_dims)) {
    apparent_out_shape[i] = dim_ == i ? @1 : [NSNumber numberWithInt:input_shape[i]];
  }
  int dim_total_elements = input_shape[dim_];

  auto stream = at::mps::getCurrentMPSStream();

  @autoreleasepool {
    string key = func_name + ":" + to_string(dim_) + ":" + getTensorsStringKey(input_t);
    CachedGraph* cachedGraph = cache_->LookUpAs<CachedGraph>(key);

    if (!cachedGraph) {
      cachedGraph = cache_->CreateCachedGraphAs<CachedGraph>(key, ^ MPSCachedGraph * () {

        CachedGraph *newCachedGraph = nil;

        @autoreleasepool {
          auto mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, input_t);
          auto sortedTensor = [mpsGraph sortWithTensor: inputTensor
                                                  axis: (NSUInteger)dim_
                                                  name: nil];
          const NSUInteger midpoint = (dim_total_elements + 1) / 2 - 1;
          auto outputTensor = [mpsGraph sliceTensor:sortedTensor
                                          dimension:dim_
                                              start:midpoint
                                             length:1
                                               name:nil];
          auto argreduceOutTensor = [mpsGraph argSortWithTensor:inputTensor
                                                           axis:(NSInteger)dim_
                                                           name:@"argmax_out"];
          auto argOutputTensor = [mpsGraph sliceTensor:argreduceOutTensor
                                             dimension:dim_
                                                 start:midpoint
                                                length:1
                                                  name:nil];

          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
          newCachedGraph->indicesTensor_ = argOutputTensor;
        }
        return newCachedGraph;
      });
    }

    auto inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input_t);
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output_t, apparent_out_shape);
    auto indicesPlaceholder = Placeholder(cachedGraph->indicesTensor_, indices_t, apparent_out_shape);

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *feeds = @{
      inputPlaceholder.getMPSGraphTensor() : inputPlaceholder.getMPSGraphTensorData(),
    };

    NSDictionary<MPSGraphTensor *, MPSGraphTensorData *> *results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData(),
      indicesPlaceholder.getMPSGraphTensor() : indicesPlaceholder.getMPSGraphTensorData()
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }
}

// in case mps sortWithTensor do not supported on macOS
std::tuple<Tensor&, Tensor&> median_from_cpu(
  const Tensor& self,
  int64_t dim,
  bool keepdim,
  Tensor& valuesI,
  Tensor& indicesI,
  IntArrayRef vec_out_shape,
  IntArrayRef vec_apparent_out_shape) {
  Tensor values;
  Tensor indices;
  if (!keepdim) {
    values = at::empty({vec_out_shape}, self.options());
    indices = at::empty({vec_out_shape}, self.options().dtype(kLong));
  } else {
    values = at::empty({vec_apparent_out_shape}, self.options());
    indices = at::empty({vec_apparent_out_shape}, self.options().dtype(kLong));
  }
  at::median_out(values, indices, self, dim, keepdim);

  valuesI.copy_(values);
  indicesI.copy_(indices);
  return std::forward_as_tuple(valuesI, indicesI);
}

TORCH_API ::std::tuple<at::Tensor &,at::Tensor &> median_out_mps(
  const at::Tensor & input_t,
  int64_t dim,
  bool keepdim,
  at::Tensor & values,
  at::Tensor & indices){

  TORCH_CHECK(input_t.scalar_type() != ScalarType::Long, "MPS does not support median ops with int64 input");

  int64_t dim_ = maybe_wrap_dim(dim, input_t.dim());
  native::zero_numel_check_dims(input_t, dim_, "max()");

  // Calculate the output shape according to keepdim=True
  // If there is no dim argument, the input shape is flattened
  IntArrayRef input_shape = input_t.sizes();
  int64_t num_input_dims = input_shape.size();
  NSMutableArray<NSNumber*> *apparent_out_shape = nil;
  // Use this if keepdim is false
  int64_t num_output_dims = num_input_dims - 1;

  std::vector<int64_t> vec_apparent_out_shape(num_input_dims);
  std::vector<int64_t> vec_out_shape(num_output_dims);

  apparent_out_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_input_dims];
  // Counter for shape when keepdim is false
  int out_i = 0;
  for (const auto i: c10::irange(num_input_dims)) {
    if (dim_ == i) {
      apparent_out_shape[i] = @1;
      vec_apparent_out_shape[i] = 1;
    } else {
      apparent_out_shape[i] = [NSNumber numberWithInt:input_shape[i]];
      vec_apparent_out_shape[i] = input_shape[i];
      vec_out_shape[out_i] = input_shape[i];
      out_i++;
    }
  }

  if (!keepdim) {
    values = at::native::empty_mps(
                    IntArrayRef(vec_out_shape),
                    input_t.scalar_type(),
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);
    indices = at::native::empty_mps(
                    IntArrayRef(vec_out_shape),
                    ScalarType::Long,
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);
  } else {
    values = at::native::empty_mps(
                    IntArrayRef(vec_apparent_out_shape),
                    input_t.scalar_type(),
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);
    indices = at::native::empty_mps(
                    IntArrayRef(vec_apparent_out_shape),
                    ScalarType::Long,
                    c10::nullopt,
                    kMPS,
                    c10::nullopt,
                    c10::nullopt);
  }

  if (values.numel() == 0 || input_t.numel() == 0) {
      return std::tuple<Tensor&, Tensor&>{values, indices};
  }

  if (!is_macos_13_or_newer()) {
    TORCH_WARN_ONCE("MPS: median op is supported natively starting from macOS 13.0.",
                   "Falling back on CPU. This may have performace implications.");
    return median_from_cpu(input_t.to("cpu"), dim, keepdim, values, indices, IntArrayRef(vec_out_shape),IntArrayRef(vec_apparent_out_shape));
  }

  median_out_mps(input_t, dim, keepdim, values, indices, "median_out_mps");

  return std::tuple<Tensor&, Tensor&>{values, indices};
}

} // native
} // at
