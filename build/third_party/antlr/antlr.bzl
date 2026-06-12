"""Module extension that fetches the ANTLR4 Java tool jar.

Pinned to a specific version + sha256 for reproducibility. Updating the ANTLR4
version means bumping `_ANTLR_VERSION` and `_ANTLR_JAR_SHA256` here.

Downstream consumers reference the jar via the public alias `@antlr_jar//:jar`
(defined in `BUILD.bazel`).
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

_ANTLR_VERSION = "4.13.2"
_ANTLR_JAR_SHA256 = "eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76"

def _antlr_jar_impl(_module_ctx):
    http_file(
        name = "antlr_jar_complete",
        urls = [
            "https://www.antlr.org/download/antlr-{}-complete.jar".format(_ANTLR_VERSION),
            "https://github.com/antlr/website-antlr4/raw/gh-pages/download/antlr-{}-complete.jar".format(_ANTLR_VERSION),
        ],
        sha256 = _ANTLR_JAR_SHA256,
        downloaded_file_path = "antlr-{}-complete.jar".format(_ANTLR_VERSION),
    )

antlr_jar = module_extension(
    implementation = _antlr_jar_impl,
)
