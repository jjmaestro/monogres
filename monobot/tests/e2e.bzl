"""End-to-end tests that run a built monobot rather than its classes.

`quarkus_test` covers the pipeline on the JVM with the network calls replaced.
What it cannot cover is the packaged application: `//:monobot_native` is an
image, and native-image keeps only the members it can prove are reachable. Every
type monobot exchanges as JSON is constructed reflectively by Jackson, so
nothing in the source references those constructors and the image drops them.
The result builds, starts, and then fails on the first `monobot.json` it reads.
Only running the artifact catches that.

Both `//:monobot` and `//:monobot_native` are executable targets that read the
same three settings from the environment, so one macro drives either, and
running the pair says which of the two layers a failure is in.

Two shapes, because they answer different questions:

  - offline: tagged `block-network`, so the sandbox gives the run loopback and
    nothing else and the tag listing cannot reach a forge. Everything before the
    fetch still has to work, which is exactly where the reflection defect lands,
    so this belongs in the default gate and costs a second.
  - golden: a real scan of one small extension, compared byte for byte. It needs
    the network, so it is tagged out of the default gate; it is what catches a
    change in the serialized shape or in a digest.
  - check: the same scan in the mode that writes nothing, over a tree that
    already holds the answer. It has to exit 0, which is the gate the whole
    catalog is run through and this is its rehearsal.
"""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

def monobot_e2e_test(
        name,
        app,
        config,
        expect = None,
        expect_status = None,
        golden = None,
        gate = None,
        mode = None,
        **kwargs):
    """Runs a built monobot against a catalog tree and checks what it produced.

    Args:
        name: Target name.
        app: The application to run, `//:monobot` or `//:monobot_native`.
        config: Filegroup holding a catalog tree, laid out as
            `extensions/<name>/monobot.json`. `catalogDir` is derived from it,
            so the tree's own directory names are what the run sees. The tree is
            copied before the run, because monobot writes into the directory it
            read and runfiles are symlinks into the source.
        expect: Optional string the output has to contain. Give it a value that
            only a deserialized config can produce, such as a URL that appears
            nowhere but inside the JSON.
        expect_status: Optional exit status the run has to end with. 0 means
            every extension completed, 1 that some completed and some failed, 2
            that none completed. Defaults to 0.
        golden: Optional `repo.json` the run has to reproduce exactly. Its
            absence selects the offline shape, which checks how far the run got
            rather than what it wrote.
        gate: Optional target whose files have to build before this test can
            run. Used to put the JVM run ahead of the native one.
        mode: Optional run mode, `generate` by default. `check` writes nothing
            and exits non-zero when what it would write differs from what the
            tree already holds.
        **kwargs: Passed to the underlying `sh_test` (`tags`, `size`, ...).
    """
    args = ["--app", "$(rootpath {})".format(app)]
    data = [app, config]

    if expect_status != None:
        args += ["--expect-status", str(expect_status)]

    if expect:
        args += ["--expect", expect]

    if mode:
        args += ["--mode", mode]

    if golden:
        args += ["--golden", "$(rootpath {})".format(golden)]
        data.append(golden)

    if gate:
        # Named only so its files have to build. A failing gate fails this
        # target's inputs, and the default --nokeep_going then abandons the
        # native image rather than spending minutes on one that cannot be
        # trusted anyway.
        args += ["--gate", "$(rootpaths {})".format(gate)]
        data.append(gate)

    # Last, because it expands to one path per file in the tree and the script
    # takes whatever follows it.
    args += ["--config-files", "$(rootpaths {})".format(config)]

    sh_test(
        name = name,
        srcs = ["//tests:e2e_test.sh"],
        args = args,
        data = data,
        **kwargs
    )
