"""An empty CC toolchain, with no compiler behind it.

monobot is pure Java and compiles no C++, but `java_binary` still depends on the
C++ toolchain *type* for its optional native launcher: rules_java declares it
`use_cc_toolchain(mandatory = False)`, so toolchain resolution has to find
something even though nothing is ever compiled with it. With no registered
toolchain, analysis fails with "Unable to find a CC toolchain".

The alternatives are worse. Letting Bazel autodetect one picks up whatever host
gcc happens to be installed, which is not hermetic. Registering a real
downloaded toolchain such as toolchains_llvm costs roughly a gigabyte to satisfy
a launcher that is never built. This stub satisfies resolution and nothing else:
anything that genuinely tries to compile or link C++ fails loudly rather than
silently reaching for a host compiler.

`BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1` in .bazelrc suppresses the autodetection
that would otherwise probe for a host compiler. Under that flag Bazel registers
no CC toolchain at all, which is what makes this stub necessary.

The rule mirrors what Bazel generates for local_config_cc under that env var
(tools/cpp/BUILD.empty.tpl). Bazel 7 exposed it as
@bazel_tools//tools/cpp:empty_cc_toolchain_config.bzl; Bazel 8 no longer does,
so this module carries its own copy.

See https://github.com/bazelbuild/stardoc/pull/313 for the same approach in a
pure-Starlark repository, including why avoiding the CC toolchain is preferable
to satisfying it with a real compiler.
"""

load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

def _impl(ctx):
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "empty",
        target_system_name = "empty",
        target_cpu = "empty",
        target_libc = "empty",
        compiler = "empty",
    )

cc_toolchain_config = rule(
    implementation = _impl,
    attrs = {},
    provides = [CcToolchainConfigInfo],
)

def empty_cc_toolchain(name):
    """Declares the empty CC toolchain and every target it needs.

    Register the result from MODULE.bazel:

        register_toolchains("//toolchains:empty_cc")

    Args:
        name: Name of the `toolchain` target to register. The `cc_toolchain`,
            its config and its (empty) file group are derived from it.
    """
    native.filegroup(
        name = name + "_files",
        srcs = [],
    )

    cc_toolchain_config(
        name = name + "_config",
    )

    # Every file group is the same empty one: there are no tools to offer.
    cc_toolchain(
        name = name + "_toolchain",
        all_files = ":" + name + "_files",
        ar_files = ":" + name + "_files",
        as_files = ":" + name + "_files",
        compiler_files = ":" + name + "_files",
        dwp_files = ":" + name + "_files",
        linker_files = ":" + name + "_files",
        objcopy_files = ":" + name + "_files",
        strip_files = ":" + name + "_files",
        toolchain_config = ":" + name + "_config",
        toolchain_identifier = "empty",
    )

    # The registration that platform-based resolution actually looks for.
    native.toolchain(
        name = name,
        toolchain = ":" + name + "_toolchain",
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    )
