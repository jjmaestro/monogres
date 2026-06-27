"""Label resolution for the per-directory cc_* Postgres overlay.

Once each target-owning directory is its own Bazel package, a reference to a
source file, a generated output, or a sibling target is only valid as a label
relative to the consuming package. These helpers turn the introspect's
overlay-root-relative paths into either a package-relative string (when the
referent belongs to the consuming package) or a `//pkg:name` label (when it
lives in another package), recording the cross-package source exports the owning
package must declare.

The `packages` argument is the active overlay package set (from
`overlay_layout`); resolution is driven entirely by it, so an empty set
collapses every reference to the root package (the single-BUILD overlay) and the
real set drives the per-directory split. `overlay_layout` (layout.bzl) is the
single source of truth for that set, shared with the repo rule's symlink spine,
so the package boundaries the labels assume and the directories that actually
exist cannot drift.
"""

load(":layout.bzl", "pkg_of")

def longest_pkg_prefix(packages, d):
    """The deepest package that owns directory `d` (or "" for the root package).

    Walks `d` from its root segment down, tracking the deepest ancestor (or `d`
    itself) present in `packages`. Returns "" when no package encloses `d`, i.e.
    the file belongs to the root package.

    Args:
        packages: the active overlay package set (a dict used as a set).
        d: an overlay-root-relative directory.

    Returns:
        The deepest package path enclosing `d`, or "" for the root package.
    """
    best = ""
    cur = ""
    for seg in d.split("/"):
        cur = seg if not cur else cur + "/" + seg
        if cur in packages:
            best = cur
    return best

def dep_label(index, name, home_pkg):
    """The dep label for a dependable target name, from a consumer in `home_pkg`.

    A `:name` reference resolves within the consumer's own package, so a target
    that renders in another package (or the root, for the header libs and
    cc_imports) must be named `//pkg:name`. Names absent from the index resolve
    to the root package.

    Args:
        index: a {target_name: package} mapping (built by the renderer).
        name: a dependable target name (an archive basename, libpq variant,
            cc_import, header lib, ...).
        home_pkg: the consuming target's package ("" for the root package).

    Returns:
        `:name` when the dep is in the consumer's package, else `//pkg:name`.
    """
    pkg = index.get(name, "")
    return ":" + name if pkg == home_pkg else "//%s:%s" % (pkg, name)

def _strip_pkg(path, pkg):
    return path[len(pkg) + 1:] if pkg else path

def _label(pkg, rel):
    return "//%s:%s" % (pkg, rel) if pkg else "//:" + rel

def src_label(packages, exports, path, home_pkg):
    """Resolve a source path to a package-relative string or a `//pkg:file` label.

    The owning package is the deepest package enclosing the file's directory.
    When it is the consumer's own package the file is referenced
    package-relative (no label); otherwise it is a cross-package label and the
    owning package is recorded in `exports` so it can `exports_files` the file.

    Args:
        packages: the active overlay package set.
        exports: a {owner_pkg: {rel: True}} accumulator, mutated for each
            cross-package reference.
        path: the overlay-root-relative source path.
        home_pkg: the consuming target's package ("" for the root package).

    Returns:
        A package-relative path string (same package) or a `//pkg:file` label.
    """
    d = path.rsplit("/", 1)[0] if "/" in path else ""
    owner = longest_pkg_prefix(packages, d)
    if owner == home_pkg:
        return _strip_pkg(path, home_pkg)
    rel = _strip_pkg(path, owner)
    exports.setdefault(owner, {})[rel] = True
    return _label(owner, rel)

def gen_label(packages, out, home_pkg):
    """Resolve a generated output to a package-relative string or a label.

    Like `src_label`, but for a genrule output: the producing genrule renders in
    the output's package, so a generated file is visible cross-package via that
    rule's visibility (no `exports_files`).

    Args:
        packages: the active overlay package set.
        out: the overlay-root-relative generated-output path.
        home_pkg: the consuming target's package ("" for the root package).

    Returns:
        A package-relative path string (same package) or a `//pkg:file` label.
    """
    d = out.rsplit("/", 1)[0] if "/" in out else ""
    genpkg = longest_pkg_prefix(packages, d)
    if genpkg == home_pkg:
        return _strip_pkg(out, home_pkg)
    return _label(genpkg, _strip_pkg(out, genpkg))

def target_home(packages, defined_in):
    """The package a target renders in, given its introspect `defined_in`.

    Args:
        packages: the active overlay package set.
        defined_in: the target's introspect `defined_in` (a meson.build path).

    Returns:
        The target's package, or "" when the split is inactive for it.
    """
    pkg = pkg_of(defined_in)
    return pkg if pkg in packages else ""
