"""The format and lint gate.

Three tools hold monobot's Java to a standard, and only two of them are here.

Error Prone is the first and is invisible: rules_java runs it inside every javac
action, so `bazel build` already fails on the bug patterns Google ships at ERROR
severity, and there is nothing to declare. It is the only one of the three that
reasons about types, so it is the only one that catches a wrong argument type
reaching a generic method or a discarded return value.

google-java-format decides layout. It is a formatter, not a checker: there is no
configuration and no disagreement to arbitrate, which is the point of choosing
it. `bazel run //tools/lint:format` rewrites files in place and `format.check`
fails instead, so the same tool serves the editor and the gate. It also sorts
imports and drops unused ones.

checkstyle holds what is left, the rules a formatter cannot decide for you:
naming, declaration order, and the structural conventions in Google's Java style
guide. It runs as an aspect over java_library, so a lint failure is a test
failure and lands in the same cache as everything else.

Two details in that last part are worth knowing.

The ruleset is not checked in. `google_checks.xml` ships inside the checkstyle
jar, and the genrule below extracts it from whichever jar MODULE.bazel pins.
Upgrading checkstyle therefore brings its rule changes along unmodified, and
there is no copy in this repository to drift from upstream.

Its two knobs are set as system properties rather than a properties file,
because the aspect fixes checkstyle's argv and leaves no room for `-p`.
Checkstyle falls back to System.getProperties() when no properties file is
given, so `-D` reaches the same expander. `severity` has to move off its
`warning` default or the CLI exits zero no matter what it found, which would
leave the gate reporting and never failing.
"""

load("@aspect_rules_lint//format:defs.bzl", "format_multirun")
load("@aspect_rules_lint//lint:checkstyle.bzl", "lint_checkstyle_aspect")
load("@aspect_rules_lint//lint:lint_test.bzl", "lint_test")
load("@rules_java//java:java_binary.bzl", "java_binary")

_GOOGLE_CHECKS = "google_checks.xml"

_SUPPRESSIONS = "//:.checkstyle-suppressions.xml"

# Both tools parse Java with javac's own parser, which has not been exported
# since the module system landed.
_JAVAC_INTERNALS = [
    "--add-exports jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
    "--add-exports jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED",
    "--add-exports jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED",
    "--add-exports jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED",
    "--add-exports jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED",
]

def lint_tools(name = "format"):
    """Declares the format and lint tooling.

    Call once, from //tools/lint.

    Args:
      name: the formatter target, and with `.check` appended the same tool in
          reporting mode. Everything else this declares is named for the aspect
          below, which binds to those labels.
    """
    java_binary(
        name = "google-java-format",
        jvm_flags = _JAVAC_INTERNALS,
        main_class = "com.google.googlejavaformat.java.Main",
        runtime_deps = ["@google_java_format//jar"],
    )

    format_multirun(
        name = name,
        java = ":google-java-format",
        visibility = ["//visibility:public"],
    )

    # zipper rather than unzip: it is a Bazel-supplied tool, so the extraction
    # does not depend on what the host has installed.
    native.genrule(
        name = "google_checks",
        srcs = ["@checkstyle//jar:file"],
        outs = [_GOOGLE_CHECKS],
        cmd = "$(execpath @bazel_tools//tools/zip:zipper) x $< -d $(RULEDIR) " + _GOOGLE_CHECKS,
        tools = ["@bazel_tools//tools/zip:zipper"],
    )

    java_binary(
        name = "checkstyle",
        data = [_SUPPRESSIONS],
        jvm_flags = _JAVAC_INTERNALS + [
            "-Dorg.checkstyle.google.severity=error",
            "-Dorg.checkstyle.google.suppressionfilter.config=.checkstyle-suppressions.xml",
        ],
        main_class = "com.puppycrawl.tools.checkstyle.Main",
        runtime_deps = ["@checkstyle//jar"],
    )

checkstyle = lint_checkstyle_aspect(
    binary = Label("//tools/lint:checkstyle"),
    config = Label("//tools/lint:" + _GOOGLE_CHECKS),
    data = [Label(_SUPPRESSIONS)],
)

checkstyle_test = lint_test(aspect = checkstyle)
