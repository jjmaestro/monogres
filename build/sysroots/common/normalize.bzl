"""
Tier-1 normalization: rewrite extracted-sysroot paths for hermetic linking.

Hermetic builds that consume a `--sysroot=` flag (e.g. via `toolchains_llvm`) or
that bind-mount the sysroot tree at an action-time path different from its
repo-cache filesystem path hit two Debian-shipped patterns that downstream
linkers don't handle:

1. Absolute-target symlinks (`usr/lib/<arch>/libpam.so ->
   /lib/<arch>/libpam.so.0`). The target `/lib/...` resolves through `/`, which
   is either empty (hermetic chroot) or the host root (non-hermetic); neither
   matches the sysroot. Bazel's `rctx.extract` pre-rewrites these targets to be
   `<sysroot_dir>/lib/...`, but that absolute path is the sysroot's repo-cache
   location, not where it ends up bind-mounted at action time. Either way
   `ld.lld` can't follow the symlink and falls back to `.a` archives whose
   static deps aren't on the link line. Rewriting each absolute target to a path
   relative to the symlink's own directory makes the symlink resolve regardless
   of where the sysroot is mounted.

2. Debian GNU-ld linker scripts (`libc.so`, `libm.so`, …) start with `/*`
   and list absolute paths inside `GROUP ( ... )`. `ld.lld` honors `=`-prefixed
   paths (= "prepend `--sysroot`") but does NOT auto-prepend `--sysroot` to
   plain absolute paths inside scripts. Rewriting each `/path` after `(` or
   whitespace to `=/path` makes the linker honor `--sysroot=` against them.
   Idempotent.

3. On a merged-/usr release (Debian 13+) those same linker scripts `GROUP` a
   `=/lib/<multiarch>/libc.so.6`, but the `.deb` payloads ship the file only
   under `/usr/lib/<multiarch>/` (a real root carries a `/lib -> usr/lib`
   symlink that a bare package-union sysroot lacks). The `=/lib/…` entries are
   redirected to `=/usr/lib/…` so the fully usr-rooted tree links without a
   top-level `/lib` (a `/lib` symlink is unrepresentable in the `glob(["**"])`
   `:sysroot` filegroup, and a materialized `/lib/gcc` would misdirect clang's
   GCC-install search). No-op on a pre-merge sysroot with a real `/lib`.

All three run as Tier-1 (always applied) because they fix a fundamental
extracted-sysroot / lld interaction, not a single buggy package.
Package-specific patches live in `apt/private/known_patches.bzl`.
"""

def _prune_bazel_unrepresentable_paths(rctx, sysroot_dir):
    """Delete files whose basename contains characters Bazel can't put in a label.

    `srcs = glob(["**"])` materializes one Bazel label per file. Bazel target
    names are restricted to `[a-zA-Z0-9._/\\-=,@~+]`, so files like
    `usr/share/man/man3/Dpkg::Arch.3perl.gz` (shipped by `dpkg-dev` to document
    Perl modules whose names contain `::`) make the filegroup analysis fail with
    `invalid target name ':Arch.3perl.gz'`. These files are documentation and
    not part of any compile/link path through the sysroot, so dropping them at
    repo-rule time is safe and keeps the `:sysroot` filegroup label-clean for
    every downstream consumer.

    Currently filters on `:` only: the one character we've observed Debian
    package payloads contain in basenames. Add more patterns here if the next
    snapshot surfaces another forbidden character.

    Args:
        rctx: A `repository_ctx`.
        sysroot_dir: Sysroot root path (workspace-relative string).
    """
    sr = str(rctx.path(sysroot_dir))
    res = rctx.execute(["find", sr, "-name", "*:*"])
    if res.return_code != 0:
        fail((
            "//sysroots: find Bazel-unrepresentable basenames under %s failed: %s"
        ) % (sr, res.stderr))

    for path in res.stdout.splitlines():
        if not path:
            continue
        rmres = rctx.execute(["rm", "-rf", path])
        if rmres.return_code != 0:
            fail("//sysroots: rm -rf %s failed: %s" % (path, rmres.stderr))

def _prune_cyclic_symlinks(rctx, sysroot_dir):
    """Delete symlinks that resolve to one of their own ancestor directories.

    Some Debian packages ship symlinks that point back to a parent directory of
    the symlink itself (e.g. `usr/lib/llvm-14/build/Debug+Asserts -> ..` from
    `libllvm14`, used to mimic an LLVM in-tree build layout). Inside an
    extracted sysroot these symlinks form a glob trap: Bazel's `glob(["**"])` on
    the `:sysroot` filegroup descends through `Debug+Asserts → ..` back into
    `build`, finds `Debug+Asserts` again, and recurses forever (`infinite
    symlink expansion detected`).

    The symlinks are dead weight in a hermetic sysroot used purely for compile +
    link; they would only matter for building llvm itself. Removing them at
    repo-rule time is safe and keeps the `:sysroot` filegroup glob-clean for
    every downstream consumer.

    Args:
        rctx: A `repository_ctx`.
        sysroot_dir: Sysroot root path (workspace-relative string).
    """
    sr = str(rctx.path(sysroot_dir))
    res = rctx.execute(["find", sr, "-type", "l"])
    if res.return_code != 0:
        fail("//sysroots: find symlinks under %s failed: %s" % (sr, res.stderr))

    for link in res.stdout.splitlines():
        if not link:
            continue

        # `readlink -f` resolves the whole chain to a canonical absolute path
        # (or to the longest existing prefix when the chain dead-ends), so we
        # detect transitive cycles too, not only direct `-> ..` self-parents.
        rl = rctx.execute(["readlink", "-f", link])
        if rl.return_code != 0:
            continue
        resolved = rl.stdout.strip()
        if not resolved:
            continue

        # The symlink is cyclic iff its own file path is inside (or equal to)
        # the resolved target (i.e. the resolved target is the symlink itself or
        # one of its ancestor directories).
        is_cyclic = link == resolved or link.startswith(resolved + "/")
        if not is_cyclic:
            continue

        rmres = rctx.execute(["rm", "-f", link])
        if rmres.return_code != 0:
            fail("//sysroots: rm -f cyclic symlink %s failed: %s" % (
                link,
                rmres.stderr,
            ))

def _dirname(path):
    """Return the directory part of an absolute POSIX path.

    Pure-Starlark equivalent of `os.path.dirname` for absolute paths. The last
    `/` separates the directory from the basename; for top-level paths (`/foo`)
    the result is the root `/`.

    Args:
        path: An absolute POSIX path (must start with `/`).

    Returns:
        The directory containing the basename. `/foo/bar/baz` → `/foo/bar`,
        `/foo` → `/`, `/` → `/`.
    """
    i = path.rfind("/")
    if i <= 0:
        return "/"
    return path[:i]

def _relpath(target, from_dir):
    """Compute the relative path from `from_dir` to `target`.

    Both inputs must be normalized absolute POSIX paths (no `.`/`..` components,
    no trailing `/`, no consecutive `/`). The result is a forward-slash path
    with `..` components for parent traversals and named components for descent.
    `target == from_dir` returns `.`.

    Args:
        target: Absolute target path.
        from_dir: Absolute directory to compute relative from.

    Returns:
        A relative path string suitable as the second argument to `ln -s`.
    """
    target_parts = [p for p in target.split("/") if p]
    from_parts = [p for p in from_dir.split("/") if p]

    common = 0
    for i in range(min(len(target_parts), len(from_parts))):
        if target_parts[i] != from_parts[i]:
            break
        common = i + 1

    up = [".."] * (len(from_parts) - common)
    down = target_parts[common:]
    parts = up + down
    return "/".join(parts) if parts else "."

def _relativize_target(sysroot_dir, symlink_path, target):
    """Rewrite an absolute symlink target to a path relative to the symlink's directory.

    Truly relative targets (`../../lib/<arch>/libpam.so.0`) survive the sysroot
    being bind-mounted at any path: `/cache/.../sysroot/` for repo-rule output,
    `/execroot/_main/sysroot/` for a Bazel action, elsewhere for downstream
    consumers. Absolute targets (whether the original Debian `/lib/<arch>/…` or
    the `rctx.extract`-prefixed `<sysroot_dir>/lib/<arch>/…`) only resolve at
    one specific mount path and dangle everywhere else.

    Bazel's `rctx.extract` (used to unpack a `.deb`'s `data.tar.*`) pre-rewrites
    absolute symlink targets to be rooted in the extraction dir, so a Debian
    symlink with target `/lib/<arch>/libc.so.6` comes out of `rctx.extract` with
    target `<sysroot_dir>/lib/<arch>/libc.so.6`. The canonicalization step below
    handles both forms (pre-prefix and post-prefix), and the relative-path
    computation does the rest.

    Args:
        sysroot_dir: Sysroot root (e.g. `/path/to/@hub/debian/12/amd64`).
        symlink_path: Absolute path of the symlink itself (must be under
            `sysroot_dir`).
        target: The current symlink target (`readlink` output).

    Returns:
        A relative path (e.g. `../../lib/x86_64-linux-gnu/libpam.so.0`) when the
        target is absolute; `None` when the target is already relative (no
        rewrite needed).
    """
    if not target.startswith("/"):
        return None

    # Canonicalize the target to be sysroot-rooted absolute. `rctx.extract`
    # usually does this for us, but pre-extract targets (the original Debian
    # `/lib/…`) come through unprefixed and need it explicitly.
    if target == sysroot_dir or target.startswith(sysroot_dir + "/"):
        absolute_target = target
    else:
        absolute_target = sysroot_dir + target

    return _relpath(absolute_target, _dirname(symlink_path))

def _is_ld_script_text(content_head):
    """Is the first two bytes of a file the GNU-ld linker-script magic `/*`?

    Args:
        content_head: First two bytes of the candidate `.so` file, as a string.

    Returns:
        `True` if `content_head == "/*"`; the file is a GNU-ld linker script.
        ELF `.so` binaries start with `\\x7fELF`, never `/*`.
    """
    return content_head == "/*"

def _relativize_symlinks(rctx, sysroot_dir):
    """Rewrite every absolute-target symlink under `sysroot_dir` to be relative.

    Truly relative targets (`../../lib/<arch>/libfoo.so.0`) resolve correctly
    regardless of where the sysroot ends up bind-mounted: at its filesystem path
    inside the repo cache, at `/execroot/_main/sysroot/` inside a Bazel action
    sandbox, anywhere a downstream consumer relocates the tree. Absolute targets
    (whether the original Debian `/lib/<arch>/libfoo.so.0` or the
    `<sysroot_dir>/lib/<arch>/libfoo.so.0` `rctx.extract` rewrites them to) only
    resolve at one specific path and dangle everywhere else.

    `sysroot_dir` is passed as a workspace-relative path; canonicalize it to its
    absolute form (via `rctx.path`) so the relative-path computation in
    `_relativize_target` operates on a stable, absolute base.

    Args:
        rctx: A `repository_ctx`.
        sysroot_dir: Sysroot root path (workspace-relative string).
    """
    sr = str(rctx.path(sysroot_dir))
    res = rctx.execute(["find", sr, "-type", "l"])
    if res.return_code != 0:
        fail("//sysroots: find symlinks under %s failed: %s" % (sr, res.stderr))

    for link in res.stdout.splitlines():
        if not link:
            continue
        rl = rctx.execute(["readlink", link])
        if rl.return_code != 0:
            continue
        new_target = _relativize_target(sr, link, rl.stdout.strip())
        if new_target == None:
            continue

        # `ln -sfn` overwrites an existing symlink atomically (`-f` forces, `-n`
        # treats the destination as a regular file even if it is a symlink to a
        # dir). Coreutils ships this on every platform we target.
        lnres = rctx.execute(["ln", "-sfn", new_target, link])
        if lnres.return_code != 0:
            fail("//sysroots: ln -sfn %s %s failed: %s" % (
                new_target,
                link,
                lnres.stderr,
            ))

_REWRITE_LD_SCRIPT_BASH = """\
set -eu
find "$1" -name '*.so' -type f | while read -r f; do
    head -c 2 "$f" 2>/dev/null | grep -q '^/\\*' || continue
    sed -E -i 's|([( ])(/[^ )]+)|\\1=\\2|g' "$f"
done
"""

def _rewrite_ld_scripts(rctx, sysroot_dir):
    """Apply the `=`-prefix rewrite to every GNU-ld linker script under `sysroot_dir`.

    Implemented as a single `bash -c` invocation rather than a Starlark loop
    plus per-file `rctx.read`/`rctx.file` for speed: a typical sysroot has ~5
    linker scripts out of ~30k files, and the find+head fast-path skips binaries
    cheaply. `sed -E -i` is idempotent (the `=`-prefixed form no longer matches
    the pattern), so re-running the rewrite is safe.

    Args:
        rctx: A `repository_ctx`.
        sysroot_dir: Sysroot root path (string).
    """
    res = rctx.execute([
        "bash",
        "-c",
        _REWRITE_LD_SCRIPT_BASH,
        "_",
        str(sysroot_dir),
    ])
    if res.return_code != 0:
        fail("//sysroots: rewrite_ld_scripts(%s) failed: %s" % (
            sysroot_dir,
            res.stderr,
        ))

def _redirect_usrmerge_ld_paths(rctx, sr, content):
    """Rewrite each `=/PATH` in an ld script to `=/usr/PATH` when merged-/usr.

    A GROUP / AS_NEEDED entry is redirected only when its literal location
    (`<sr>/PATH`) is absent but the merged-/usr location (`<sr>/usr/PATH`)
    exists. Existence-driven rather than a fixed `/lib -> /usr/lib` swap so it
    also covers `/lib64/ld-linux-*.so` (→ `/usr/lib64/…`) and leaves
    already-correct `=/usr/…` entries untouched (idempotent).
    """
    lines = []
    for line in content.split("\n"):
        toks = []
        for tok in line.split(" "):
            if tok.startswith("=/"):
                path = tok[1:]
                literal = rctx.path(sr + path)
                merged = rctx.path("%s/usr%s" % (sr, path))
                if not literal.exists and merged.exists:
                    tok = "=/usr" + path
            toks.append(tok)
        lines.append(" ".join(toks))
    return "\n".join(lines)

def _redirect_ld_scripts_usrmerge(rctx, sysroot_dir):
    """Redirect ld-script `/lib` paths to their `/usr/lib` home on merged-/usr.

    An extracted sysroot is a bare union of `.deb` payloads, not a debootstrap
    root, so it has no `base-files` `/lib -> usr/lib` compat symlink. On a
    merged-/usr release (Debian 13+) the payloads live only under `/usr`, so a
    GNU-ld linker script that `GROUP`s an absolute `=/lib/<multiarch>/libc.so.6`
    resolves under `--sysroot` to `<sysroot>/lib/<multiarch>/libc.so.6`, which
    does not exist, and `ld.lld` fails to open it. A top-level `/lib -> usr/lib`
    symlink would fix this on a real filesystem, but Bazel's `:sysroot`
    `glob(["**"])` filegroup dereferences directory symlinks, materializing a
    real `/lib` tree in the sandbox; that `/lib/gcc` then wins clang's
    GCC-install search and its relative `../../../../include/c++` escapes to the
    (nonexistent) `<sysroot>/include/c++` instead of `<sysroot>/usr/include/
    c++`, breaking every C++ compile. Rewriting the script paths keeps the tree
    fully usr-rooted: linking resolves against the real `/usr/lib` files and
    clang's GCC detection cleanly selects `<sysroot>/usr/lib/gcc`.

    No-op on a pre-merge sysroot (Debian 12 ships a real `/lib`), which keeps
    those sysroots byte-identical.

    Args:
        rctx: A `repository_ctx`.
        sysroot_dir: Sysroot root path (string).
    """
    sr = str(rctx.path(sysroot_dir))

    # Merged-/usr iff the top-level `/lib` is absent (see above). A pre-merge
    # sysroot ships a real `/lib`, so every `=/lib/…` already resolves.
    if rctx.path(sr + "/lib").exists:
        return

    res = rctx.execute(["find", sr, "-name", "*.so", "-type", "f"])
    if res.return_code != 0:
        fail("//sysroots: find ld scripts under %s failed: %s" % (
            sr,
            res.stderr,
        ))

    for path in res.stdout.splitlines():
        if not path:
            continue
        content = rctx.read(path)
        if not _is_ld_script_text(content[:2]):
            continue
        rewritten = _redirect_usrmerge_ld_paths(rctx, sr, content)
        if rewritten != content:
            rctx.file(path, rewritten, executable = False)

normalize = struct(
    relativize_target = _relativize_target,
    is_ld_script_text = _is_ld_script_text,
    prune_bazel_unrepresentable_paths = _prune_bazel_unrepresentable_paths,
    prune_cyclic_symlinks = _prune_cyclic_symlinks,
    relativize_symlinks = _relativize_symlinks,
    rewrite_ld_scripts = _rewrite_ld_scripts,
    redirect_ld_scripts_usrmerge = _redirect_ld_scripts_usrmerge,
)
