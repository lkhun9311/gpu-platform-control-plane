#include <tvm/ffi/container/tensor.h>
#include <tvm/ffi/dtype.h>
#include <tvm/ffi/error.h>
#include <tvm/ffi/extra/c_env_api.h>
#include <tvm/ffi/function.h>
#include "/src/sglang/python/sglang/kernels/jit/csrc/elementwise/clamp_position.cuh"
namespace sglang {
TVM_FFI_DLL_EXPORT_TYPED_FUNC(clamp_position, (ClampPosition<int64_t>::run));
}  // namespace sglang
