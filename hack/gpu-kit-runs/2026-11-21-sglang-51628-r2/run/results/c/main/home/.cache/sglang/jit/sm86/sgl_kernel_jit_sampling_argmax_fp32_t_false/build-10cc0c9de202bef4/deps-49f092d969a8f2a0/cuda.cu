#include <tvm/ffi/container/tensor.h>
#include <tvm/ffi/dtype.h>
#include <tvm/ffi/error.h>
#include <tvm/ffi/extra/c_env_api.h>
#include <tvm/ffi/function.h>
#include "/sgl-workspace/sglang/python/sglang/kernels/jit/csrc/sampling/argmax.cuh"
namespace sglang {
TVM_FFI_DLL_EXPORT_TYPED_FUNC(argmax, (ArgmaxKernel<fp32_t, false>::run));
}  // namespace sglang
