"""Extract the source tree of a `cc_library` as a tree artifact.

Use case: make-based downstream consumers (e.g. the `babelfishpg_tsql` cmake
codegen step in `pg_build_make`) need to compile `antlr4-cpp-runtime` from its
upstream source — NOT against the Bazel-built `cc_library` artifact, which the
BCR module compiles with `ANTLR4CPP_USING_ABSEIL` and links against Abseil.
Linking that .so into a PGXS extension would drag Abseil symbols into the
extension's runtime, which we want to avoid.

By extracting the raw source files (`srcs`, `hdrs`, `textual_hdrs`) from the
`cc_library` and replaying upstream's stock cmake build in our genrule, we get a
clean libantlr4-runtime.so with only standard-library symbols. Same source,
different build config.

The rule walks the cc_library's `srcs` / `hdrs` / `textual_hdrs` attrs via an
aspect (the values are not exposed on `CcInfo`; they're only visible inside the
rule's attrs). For external repos, `File.short_path` is shaped `../<repo>/<rel>`
(Bazel 8+); we strip the leading `../<repo>/` so the output preserves the
repo-relative layout — `runtime/src/antlr4-runtime.h` lands at
`runtime/src/antlr4-runtime.h` under the output tree.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _collect_cc_srcs_aspect_impl(_target, ctx):
    files = []
    for attr_name in ("srcs", "hdrs", "textual_hdrs"):
        for label in getattr(ctx.rule.attr, attr_name, []):
            for f in label.files.to_list():
                files.append(f)
    return [OutputGroupInfo(cc_lib_sources = depset(files))]

collect_cc_srcs_aspect = aspect(
    implementation = _collect_cc_srcs_aspect_impl,
)

def _strip_repo_prefix(short_path):
    # Bazel 8+ external repo paths look like `../<repo>/<rel>`. Older layouts
    # used `external/<repo>/<rel>`. Strip whichever prefix is present so the
    # output tree mirrors the source-of-truth repo layout.
    if short_path.startswith("../"):
        parts = short_path.split("/", 2)
        return parts[2] if len(parts) >= 3 else short_path
    if short_path.startswith("external/"):
        parts = short_path.split("/", 2)
        return parts[2] if len(parts) >= 3 else short_path
    return short_path

def _cc_lib_sources_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name)
    files = ctx.attr.lib[OutputGroupInfo].cc_lib_sources.to_list()

    # Also pick up any explicitly-listed extra files (e.g. CMakeLists.txt at the
    # repo root, which isn't part of the cc_library's attrs but is needed to
    # drive a downstream cmake build).
    files = files + [
        f
        for label in ctx.attr.extra_files
        for f in label.files.to_list()
    ]

    cmds = ['rm -rf "{out}" && mkdir -p "{out}"'.format(out = out_dir.path)]
    for f in files:
        rel = _strip_repo_prefix(f.short_path)
        cmds.append(
            'mkdir -p "{out}/$(dirname "{rel}")" && cp -f "{src}" "{out}/{rel}"'.format(
                out = out_dir.path,
                rel = rel,
                src = f.path,
            ),
        )

    ctx.actions.run_shell(
        inputs = files,
        outputs = [out_dir],
        use_default_shell_env = True,
        command = "\n".join(cmds),
        mnemonic = "ExtractCcLibSources",
        progress_message = "Extracting cc_library sources from %{label}",
    )

    return [DefaultInfo(files = depset([out_dir]))]

cc_lib_sources = rule(
    implementation = _cc_lib_sources_impl,
    attrs = {
        "extra_files": attr.label_list(
            allow_files = True,
            doc = (
                "Extra files to include alongside the cc_library's srcs/hdrs" +
                " (e.g. `CMakeLists.txt` at the repo root, which isn't a" +
                " cc_library attr but is needed by downstream cmake-based" +
                " consumers)."
            ),
        ),
        "lib": attr.label(
            mandatory = True,
            providers = [CcInfo],
            aspects = [collect_cc_srcs_aspect],
            doc = "cc_library whose source files to extract.",
        ),
    },
    doc = "Extracts a cc_library's source tree (srcs + hdrs + textual_hdrs + extra_files) into a tree artifact, preserving the original repo layout.",
)
