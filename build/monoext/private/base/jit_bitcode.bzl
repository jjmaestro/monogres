"""`pg_jit_bitcode`: compile a backend source to LLVM bitcode for the JIT.

PostgreSQL's LLVM JIT loads `lib/llvmjit_types.bc` at session init: the
struct-layout type information the IR generator references when it emits code.
Upstream produces it with a normal backend compile emitted as bitcode (`clang
-emit-llvm -flto=thin`) rather than an object file.

Rather than re-run clang with its own sysroot / target wiring, reuse the
cc_toolchain (its clang, `--sysroot`, and `--target` already match every other
overlay compile) and add `-emit-llvm`, which makes the emitted object LLVM
bitcode; the object is then exposed under its `.bc` name. The PG headers reach
the compile through the `deps` compilation contexts (the same header libraries
the cc_* targets use).
"""

load(
    "@rules_cc//cc:find_cc_toolchain.bzl",
    "find_cc_toolchain",
    "use_cc_toolchain",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _pg_jit_bitcode_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    compilation_context = cc_common.merge_compilation_contexts(
        compilation_contexts = [
            d[CcInfo].compilation_context
            for d in ctx.attr.deps
        ],
    )
    _, outputs = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = ctx.label.name,
        srcs = ctx.files.src,
        compilation_contexts = [compilation_context],
        # -emit-llvm turns the emitted object into LLVM bitcode (what the JIT
        # loads); -flto=thin matches the bitcode flavor upstream emits.
        user_compile_flags = ["-emit-llvm", "-flto=thin"],
    )
    objects = outputs.pic_objects if outputs.pic_objects else outputs.objects
    if len(objects) != 1:
        fail("pg_jit_bitcode: %s produced %d objects, expected 1" % (
            ctx.label,
            len(objects),
        ))

    bitcode = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.symlink(output = bitcode, target_file = objects[0])
    return [DefaultInfo(files = depset([bitcode]))]

pg_jit_bitcode = rule(
    implementation = _pg_jit_bitcode_impl,
    doc = "Compile one backend source to an LLVM bitcode `.bc` (the JIT's " +
          "compiled-in type information), reusing the cc_toolchain.",
    attrs = {
        "deps": attr.label_list(
            providers = [CcInfo],
            doc = "Header libraries supplying the include paths the source needs.",
        ),
        "out": attr.string(
            mandatory = True,
            doc = "The bitcode output filename (e.g. `llvmjit_types.bc`).",
        ),
        "src": attr.label(
            allow_single_file = [".c"],
            mandatory = True,
            doc = "The single backend source to emit as bitcode.",
        ),
    },
    toolchains = use_cc_toolchain(),
    fragments = ["cpp"],
)
