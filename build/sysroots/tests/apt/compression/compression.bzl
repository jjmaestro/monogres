"""
Test repository rule: materialize one `.deb` through `//apt/private:deb.bzl`.

Used by `extension.bzl` to instantiate one repo per compression type. A
downstream `build_test` over `:sysroot` forces extraction to run; if the
candidate compression isn't in `_DATA_TAR_CANDIDATES` or Bazel can't decompress
it, the materialization fails with a precise location.
"""

# buildifier: disable=bzl-visibility
load("//apt/private:deb.bzl", _deb = "deb")

_BUILD = """\
filegroup(
    name = "sysroot",
    srcs = glob(["extracted/**"], allow_empty = False),
    visibility = ["//visibility:public"],
)
"""

def _impl(rctx):
    _deb.download_and_extract(
        rctx,
        urls = [rctx.attr.url],
        sha256 = rctx.attr.sha256,
        out_dir = "extracted",
    )
    rctx.file("BUILD.bazel", _BUILD)

compression_test_repo = repository_rule(
    implementation = _impl,
    attrs = dict(
        url = attr.string(mandatory = True),
        sha256 = attr.string(mandatory = True),
    ),
)
