#!/usr/bin/env python3
"""Dependency-free FP16 Tensor Core microbenchmark using the CUDA Driver API.

The PTX kernel contains eight independent `mma.sync.aligned.m16n8k16` chains
per warp.  It is deliberately loaded through libcuda so the target does not
need a CUDA toolkit, cuBLAS, or PyTorch installation.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import statistics
import sys
from pathlib import Path


PTX = r"""
.version 7.0
.target sm_80
.address_size 64

.visible .entry mma_bench(
    .param .u64 out_ptr,
    .param .u32 iters
)
{
    .reg .pred %p<2>;
    .reg .b32 %r<16>;
    .reg .b64 %rd<4>;
    .reg .f16 %a<4>, %b<2>;
    .reg .f32 %c<32>;

    ld.param.u64 %rd0, [out_ptr];
    ld.param.u32 %r0, [iters];
    mov.b16 %a0, 0x3c00;
    mov.b16 %a1, 0x3c00;
    mov.b16 %a2, 0x3c00;
    mov.b16 %a3, 0x3c00;
    mov.b16 %b0, 0x3c00;
    mov.b16 %b1, 0x3c00;
    mov.f32 %c0, 0f00000000;
    mov.f32 %c1, 0f00000000;
    mov.f32 %c2, 0f00000000;
    mov.f32 %c3, 0f00000000;
    mov.f32 %c4, 0f00000000;
    mov.f32 %c5, 0f00000000;
    mov.f32 %c6, 0f00000000;
    mov.f32 %c7, 0f00000000;
    mov.f32 %c8, 0f00000000;
    mov.f32 %c9, 0f00000000;
    mov.f32 %c10, 0f00000000;
    mov.f32 %c11, 0f00000000;
    mov.f32 %c12, 0f00000000;
    mov.f32 %c13, 0f00000000;
    mov.f32 %c14, 0f00000000;
    mov.f32 %c15, 0f00000000;
    mov.f32 %c16, 0f00000000;
    mov.f32 %c17, 0f00000000;
    mov.f32 %c18, 0f00000000;
    mov.f32 %c19, 0f00000000;
    mov.f32 %c20, 0f00000000;
    mov.f32 %c21, 0f00000000;
    mov.f32 %c22, 0f00000000;
    mov.f32 %c23, 0f00000000;
    mov.f32 %c24, 0f00000000;
    mov.f32 %c25, 0f00000000;
    mov.f32 %c26, 0f00000000;
    mov.f32 %c27, 0f00000000;
    mov.f32 %c28, 0f00000000;
    mov.f32 %c29, 0f00000000;
    mov.f32 %c30, 0f00000000;
    mov.f32 %c31, 0f00000000;
    mov.u32 %r1, 0;

$loop:
    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
        {%c0, %c1, %c2, %c3}, {%a0, %a1, %a2, %a3}, {%b0, %b1},
        {%c0, %c1, %c2, %c3};
    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
        {%c4, %c5, %c6, %c7}, {%a0, %a1, %a2, %a3}, {%b0, %b1},
        {%c4, %c5, %c6, %c7};
    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
        {%c8, %c9, %c10, %c11}, {%a0, %a1, %a2, %a3}, {%b0, %b1},
        {%c8, %c9, %c10, %c11};
    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
        {%c12, %c13, %c14, %c15}, {%a0, %a1, %a2, %a3}, {%b0, %b1},
        {%c12, %c13, %c14, %c15};
    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
        {%c16, %c17, %c18, %c19}, {%a0, %a1, %a2, %a3}, {%b0, %b1},
        {%c16, %c17, %c18, %c19};
    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
        {%c20, %c21, %c22, %c23}, {%a0, %a1, %a2, %a3}, {%b0, %b1},
        {%c20, %c21, %c22, %c23};
    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
        {%c24, %c25, %c26, %c27}, {%a0, %a1, %a2, %a3}, {%b0, %b1},
        {%c24, %c25, %c26, %c27};
    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
        {%c28, %c29, %c30, %c31}, {%a0, %a1, %a2, %a3}, {%b0, %b1},
        {%c28, %c29, %c30, %c31};
    add.u32 %r1, %r1, 1;
    setp.lt.u32 %p0, %r1, %r0;
    @%p0 bra $loop;

    setp.ne.u32 %p1, %tid.x, 0;
    @%p1 bra $done;
    mov.b32 %r2, %c0;
    mov.b32 %r3, %c4;
    add.u32 %r2, %r2, %r3;
    mov.b32 %r3, %c8;
    add.u32 %r2, %r2, %r3;
    mov.b32 %r3, %c12;
    add.u32 %r2, %r2, %r3;
    mov.b32 %r3, %c16;
    add.u32 %r2, %r2, %r3;
    mov.b32 %r3, %c20;
    add.u32 %r2, %r2, %r3;
    mov.b32 %r3, %c24;
    add.u32 %r2, %r2, %r3;
    mov.b32 %r3, %c28;
    add.u32 %r2, %r2, %r3;
    mul.wide.u32 %rd1, %ctaid.x, 4;
    add.s64 %rd2, %rd0, %rd1;
    st.global.u32 [%rd2], %r2;

$done:
    ret;
}
"""

CUDA_SUCCESS = 0
CUDA_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT = 16
MMA_FLOPS_PER_WARP_INSTRUCTION = 16 * 8 * 16 * 2
MMA_CHAINS = 8


def bind(library: ctypes.CDLL, name: str, restype: object, *argtypes: object):
    function = getattr(library, name)
    function.restype = restype
    function.argtypes = list(argtypes)
    return function


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=16384)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.iterations <= 0 or args.repetitions <= 0:
        raise ValueError("iterations and repetitions must be positive")

    cuda = ctypes.CDLL("libcuda.so.1")
    c_int = ctypes.c_int
    c_uint = ctypes.c_uint
    c_uint64 = ctypes.c_uint64
    c_size_t = ctypes.c_size_t
    c_float = ctypes.c_float
    c_void_p = ctypes.c_void_p
    c_char_p = ctypes.c_char_p

    cu_init = bind(cuda, "cuInit", c_int, c_uint)
    cu_device_get = bind(cuda, "cuDeviceGet", c_int, ctypes.POINTER(c_int), c_int)
    cu_device_get_name = bind(
        cuda, "cuDeviceGetName", c_int, ctypes.POINTER(ctypes.c_char), c_int, c_int
    )
    cu_device_get_attribute = bind(
        cuda, "cuDeviceGetAttribute", c_int, ctypes.POINTER(c_int), c_int, c_int
    )
    cu_ctx_create = bind(cuda, "cuCtxCreate_v2", c_int, ctypes.POINTER(c_void_p), c_uint, c_int)
    cu_ctx_destroy = bind(cuda, "cuCtxDestroy_v2", c_int, c_void_p)
    cu_module_load = bind(
        cuda,
        "cuModuleLoadDataEx",
        c_int,
        ctypes.POINTER(c_void_p),
        c_void_p,
        c_uint,
        ctypes.POINTER(c_int),
        ctypes.POINTER(c_void_p),
    )
    cu_module_unload = bind(cuda, "cuModuleUnload", c_int, c_void_p)
    cu_module_get_function = bind(
        cuda, "cuModuleGetFunction", c_int, ctypes.POINTER(c_void_p), c_void_p, c_char_p
    )
    cu_mem_alloc = bind(cuda, "cuMemAlloc_v2", c_int, ctypes.POINTER(c_uint64), c_size_t)
    cu_mem_free = bind(cuda, "cuMemFree_v2", c_int, c_uint64)
    cu_memcpy_dtoh = bind(cuda, "cuMemcpyDtoH_v2", c_int, c_void_p, c_uint64, c_size_t)
    cu_event_create = bind(cuda, "cuEventCreate", c_int, ctypes.POINTER(c_void_p), c_uint)
    cu_event_destroy = bind(cuda, "cuEventDestroy_v2", c_int, c_void_p)
    cu_event_record = bind(cuda, "cuEventRecord", c_int, c_void_p, c_void_p)
    cu_event_synchronize = bind(cuda, "cuEventSynchronize", c_int, c_void_p)
    cu_event_elapsed = bind(cuda, "cuEventElapsedTime", c_int, ctypes.POINTER(c_float), c_void_p, c_void_p)
    cu_launch = bind(
        cuda,
        "cuLaunchKernel",
        c_int,
        c_void_p,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_void_p,
        ctypes.POINTER(c_void_p),
        c_void_p,
    )
    cu_ctx_synchronize = bind(cuda, "cuCtxSynchronize", c_int)

    def check(status: int, operation: str) -> None:
        if status != CUDA_SUCCESS:
            raise RuntimeError(f"{operation} failed with CUDA driver status {status}")

    def stage(name: str) -> None:
        print(f"tensor-mma-driver-bench stage={name}", file=sys.stderr, flush=True)

    context = c_void_p()
    module = c_void_p()
    output = c_uint64()
    start = c_void_p()
    stop = c_void_p()
    try:
        stage("cuInit")
        check(cu_init(0), "cuInit")
        device = c_int()
        check(cu_device_get(ctypes.byref(device), 0), "cuDeviceGet")
        name_buffer = ctypes.create_string_buffer(256)
        check(cu_device_get_name(name_buffer, len(name_buffer), device), "cuDeviceGetName")
        sm_count = c_int()
        check(
            cu_device_get_attribute(
                ctypes.byref(sm_count), CUDA_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, device
            ),
            "cuDeviceGetAttribute(MULTIPROCESSOR_COUNT)",
        )
        stage("cuCtxCreate")
        check(cu_ctx_create(ctypes.byref(context), 0, device), "cuCtxCreate")

        ptx = ctypes.create_string_buffer(PTX.encode("ascii"))
        jit_info = ctypes.create_string_buffer(8192)
        jit_error = ctypes.create_string_buffer(8192)
        jit_info_size = c_size_t(len(jit_info))
        jit_error_size = c_size_t(len(jit_error))
        jit_options = (c_int * 4)(3, 4, 5, 6)
        jit_option_values = (c_void_p * 4)(
            ctypes.cast(jit_info, c_void_p),
            ctypes.cast(ctypes.byref(jit_info_size), c_void_p),
            ctypes.cast(jit_error, c_void_p),
            ctypes.cast(ctypes.byref(jit_error_size), c_void_p),
        )
        stage("cuModuleLoadDataEx")
        module_status = cu_module_load(
            ctypes.byref(module),
            ctypes.cast(ptx, c_void_p),
            len(jit_options),
            jit_options,
            jit_option_values,
        )
        if module_status != CUDA_SUCCESS:
            error_text = jit_error.value.decode("utf-8", errors="replace").strip()
            raise RuntimeError(
                f"cuModuleLoadDataEx failed with CUDA driver status {module_status}: {error_text}"
            )
        jit_info_text = jit_info.value.decode("utf-8", errors="replace").strip()
        stage("cuModuleLoaded")
        function = c_void_p()
        check(cu_module_get_function(ctypes.byref(function), module, b"mma_bench"), "cuModuleGetFunction")

        block_threads = 256
        warps_per_block = block_threads // 32
        blocks = sm_count.value * 16
        output_bytes = blocks * ctypes.sizeof(ctypes.c_uint32)
        check(cu_mem_alloc(ctypes.byref(output), output_bytes), "cuMemAlloc")
        check(cu_event_create(ctypes.byref(start), 0), "cuEventCreate(start)")
        check(cu_event_create(ctypes.byref(stop), 0), "cuEventCreate(stop)")

        output_arg = c_uint64(output.value)
        iteration_arg = c_uint(args.iterations)
        kernel_params = (c_void_p * 2)(
            ctypes.cast(ctypes.byref(output_arg), c_void_p),
            ctypes.cast(ctypes.byref(iteration_arg), c_void_p),
        )

        def launch_and_time() -> float:
            check(cu_event_record(start, None), "cuEventRecord(start)")
            check(
                cu_launch(
                    function,
                    blocks,
                    1,
                    1,
                    block_threads,
                    1,
                    1,
                    0,
                    None,
                    kernel_params,
                    None,
                ),
                "cuLaunchKernel",
            )
            check(cu_event_record(stop, None), "cuEventRecord(stop)")
            check(cu_event_synchronize(stop), "cuEventSynchronize(stop)")
            elapsed = c_float()
            check(cu_event_elapsed(ctypes.byref(elapsed), start, stop), "cuEventElapsedTime")
            return float(elapsed.value)

        stage("warmup")
        launch_and_time()
        check(cu_ctx_synchronize(), "cuCtxSynchronize(warmup)")
        stage("timed-runs")
        elapsed_ms = [launch_and_time() for _ in range(args.repetitions)]
        host_output = (ctypes.c_uint32 * blocks)()
        check(
            cu_memcpy_dtoh(c_void_p(ctypes.addressof(host_output)), output, output_bytes),
            "cuMemcpyDtoH",
        )
        if not any(host_output):
            raise RuntimeError("mma benchmark produced an all-zero output")

        work_flops = blocks * warps_per_block * args.iterations * MMA_CHAINS * MMA_FLOPS_PER_WARP_INSTRUCTION
        tflops = [work_flops / (ms * 1_000_000_000.0) for ms in elapsed_ms]
        report = {
            "result": "PASS_TENSOR_MMA_DRIVER_BENCH",
            "kernel": "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32",
            "target": "sm_80 PTX JIT",
            "jit_info": jit_info_text,
            "gpu": name_buffer.value.decode("utf-8", errors="replace"),
            "sm_count": sm_count.value,
            "blocks": blocks,
            "threads_per_block": block_threads,
            "warps_per_block": warps_per_block,
            "iterations": args.iterations,
            "independent_mma_chains": MMA_CHAINS,
            "flops_per_mma_instruction_per_warp": MMA_FLOPS_PER_WARP_INSTRUCTION,
            "work_flops_per_trial": work_flops,
            "elapsed_ms": elapsed_ms,
            "tflops": tflops,
            "median_tflops": statistics.median(tflops),
            "sample_output_nonzero": int(next(value for value in host_output if value)),
        }
        rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(rendered, encoding="utf-8")
        print(rendered, end="")
        return 0
    finally:
        if stop.value:
            cu_event_destroy(stop)
        if start.value:
            cu_event_destroy(start)
        if output.value:
            cu_mem_free(output)
        if module.value:
            cu_module_unload(module)
        if context.value:
            cu_ctx_destroy(context)


if __name__ == "__main__":
    raise SystemExit(main())
