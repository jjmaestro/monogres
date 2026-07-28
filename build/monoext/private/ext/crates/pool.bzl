"""
The shared crate pool: `Cargo.lock` in, deduplicated crate repos out.

A pgrx extension pins its whole dependency closure in a `Cargo.lock`, which
records, for every crates.io package, the exact version AND its sha256. That is
all the pool needs: the lock is read at load time and each unique (crate,
version) becomes one `crate_repo` (see `crate_repo.bzl`), created once and
shared by every extension, extension version and PG major that pins it.

A git dependency is the one thing the lock does not pin by content: it records
`git+<url>?<ref>#<rev>` and no checksum. So the catalog carries the missing half
in `cargo/<version>/git.json` (the archive URL for that revision, its sha256 and
the crates it publishes), and each revision becomes one `git_crates_repo`. The
lock stays exactly as upstream wrote it: rewriting a git source into a registry
one there would only make `--locked` reject it, since the manifests still ask
for the git repository, and rewriting the manifests too would silently swap the
fork the extension pinned for whatever crates.io publishes under the same name.

The lock is read from the catalog, NOT from the extension's source archive, so
that declaring the repos does not download the extension: the hub stays lazy,
the same way the committed introspect JSONs keep the base hub lazy. The engine
then copies the catalog lock into the source tree and builds with `--locked`, so
the pool and the build can never disagree: cargo re-derives the same lock from
the manifest and fails the build if it differs.

Parsing is line-based rather than a TOML parse. `Cargo.lock` is a generated file
with a fixed, flat shape (`[[package]]` tables of scalar keys, plus a
`dependencies` list this does not need), and Starlark has no TOML decoder.
"""

load("//monoext/private:repo_names.bzl", "repo_names")
load(":crate_repo.bzl", "crate_repo")
load(":git_crates_repo.bzl", "git_crates_repo")

# The `source` of a package that comes from crates.io. Packages with no `source`
# are path/workspace members, i.e. the extension's own crates, which come from
# its source tree.
_REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"

# The `source` of a package that comes from a git repository, as
# `git+<url>[?<ref>=<value>]#<rev>`.
_GIT = "git+"

# The refs a git source may carry, which are also the cargo config keys naming
# them in a source-replacement stanza. A source with no ref tracks the default
# branch, which is spelled by leaving all three out.
_GIT_REFS = ("branch", "tag", "rev")

# The catalog `git.json` keys pinning one revision: where its archive is, what
# it unpacks into, what it hashes to, and `{crate: subdirectory}` for the crates
# it publishes. The crate map cannot be derived from the lock, which names
# crates but not the directories they live in (the lock's `tantivy-bitpacker` is
# `bitpacker/`), and reading it out of the manifests would mean a TOML parse of
# a tree that has not been fetched yet.
_GIT_JSON_KEYS = ("url", "strip_prefix", "sha256", "crates")

# The root of a checkout, as `git.json` spells a crate that IS the repo root.
_GIT_ROOT = "."

_PACKAGE = "[[package]]"

_KEYS = ("name", "version", "source", "checksum")

def _parse_lock(content, lock_label = "Cargo.lock", git = {}, _fail = fail):
    """Parse a `Cargo.lock` into the packages it pins.

    Args:
        content: The contents of the `Cargo.lock`.
        lock_label: Where the lock came from, for error messages.
        git: `{lock source: {url, strip_prefix, sha256, crates}}`, the `sources`
            table of the catalog `git.json` beside the lock. Keyed by the source
            string verbatim, `#<rev>` included, so a lock entry is a plain
            lookup and a revision bump cannot silently reuse the old pin.
        _fail: Fail function for errors.

    Returns:
        A list of `struct(crate, version, sha256, git)`, one per dependency, in
        lock order (which cargo writes sorted by name). `git` is `None` for a
        crates.io package and `struct(source, url, strip_prefix, subdir)` for
        one that comes from a git revision.
    """
    packages = []
    package = None

    for line in content.splitlines():
        if line.startswith(_PACKAGE):
            package = {}
            packages.append(package)
            continue

        if package == None:
            # The lock preamble (comments and the lock format `version`).
            continue

        for key in _KEYS:
            prefix = '%s = "' % key

            if line.startswith(prefix) and line.endswith('"'):
                package[key] = line[len(prefix):-1]
                break

    crates = []

    for package in packages:
        source = package.get("source", "")

        if not source:
            # A path or workspace member: the extension's own crates.
            continue

        name = "%s %s" % (package.get("name", "?"), package.get("version", "?"))

        if source.startswith(_GIT):
            crate = _git_crate(package, source, git, lock_label, name, _fail)

            if type(crate) == "string":
                # `_fail` is the real `fail` in a build, and a message in a
                # test.
                return crate

            crates.append(crate)
            continue

        if source != _REGISTRY:
            msg = "{}: {}: unsupported source: {}. A dependency is pinned by "
            msg += "content either from crates.io or from a git revision the "
            msg += "catalog `git.json` names"
            return _fail(msg.format(lock_label, name, source))

        checksum = package.get("checksum", "")

        if not checksum:
            msg = "{}: {}: no checksum in the lock"
            return _fail(msg.format(lock_label, name))

        crates.append(struct(
            crate = package["name"],
            version = package["version"],
            sha256 = checksum,
            git = None,
        ))

    return crates

def _git_crate(package, source, git, lock_label, name, _fail):
    """One git-sourced package, resolved against the catalog `git.json`."""
    pin = git.get(source)

    if not pin:
        msg = "{}: {}: no `git.json` pin for source: {}. A git dependency "
        msg += "carries no checksum in the lock, so the catalog pins the "
        msg += "revision's archive instead"
        return _fail(msg.format(lock_label, name, source))

    missing = [key for key in _GIT_JSON_KEYS if not pin.get(key)]

    if missing:
        msg = "{}: {}: `git.json` pin for {} is missing: {}"
        return _fail(msg.format(lock_label, name, source, ", ".join(missing)))

    subdir = pin["crates"].get(package["name"], "")

    if not subdir:
        msg = "{}: {}: `git.json` maps no subdirectory for `{}` in {}. Every "
        msg += "crate the lock takes from a revision needs one, `{}` for a "
        msg += "crate that is the repo root"
        return _fail(msg.format(
            lock_label,
            name,
            package["name"],
            source,
            _GIT_ROOT,
        ))

    return struct(
        crate = package["name"],
        version = package["version"],
        sha256 = pin["sha256"],
        git = struct(
            source = source,
            url = pin["url"],
            strip_prefix = pin["strip_prefix"],
            subdir = subdir,
        ),
    )

def _git_sources(crates, lock_label = "Cargo.lock", _fail = fail):
    """The cargo source-replacement stanzas a lock's git dependencies need.

    Cargo resolves a git dependency by cloning it, which an offline sandbox
    cannot do, so each git source is replaced by the vendor tree the pool
    already assembles. Cargo matches a stanza to a dependency by the `git` and
    ref fields it declares, not by the section name, and it ignores the `#<rev>`
    a lock source ends with, so the name here is the source string up to that
    point: what `cargo vendor` itself would have written.

    Args:
        crates: `struct(crate, version, sha256, git)` list, from `parse_lock`.
        lock_label: Where the lock came from, for error messages.
        _fail: Fail function for errors.

    Returns:
        `{source: {key: value}}`, one entry per distinct git source, each with a
        `git` key and at most one of `branch` / `tag` / `rev`.
    """
    sources = {}

    for crate in crates:
        if not crate.git:
            continue

        source = crate.git.source
        rev = source.find("#")

        if rev >= 0:
            source = source[:rev]

        if source in sources:
            continue

        url, query = source[len(_GIT):], ""
        sep = url.find("?")

        if sep >= 0:
            url, query = url[:sep], url[sep + 1:]

        entry = {"git": url}

        for ref in _GIT_REFS:
            if query.startswith(ref + "="):
                entry[ref] = query[len(ref) + 1:]
                break

        if query and len(entry) == 1:
            msg = "{}: unsupported git source ref: {}. A source names at most "
            msg += "one of: {}"
            return _fail(msg.format(lock_label, query, ", ".join(_GIT_REFS)))

        sources[source] = entry

    return sources

def _repo_name(crate):
    return repo_names.crate(crate.crate, crate.version)

def _pinned_version(crates, crate_name, lock_label = "Cargo.lock", _fail = fail):
    """The version `crates` pins for one crate.

    Used to read a pgrx extension's `pgrx` pin, which decides which SQL
    generator can read the `.pgrxsc` section it will emit. Taken from the lock
    rather than from catalog metadata so the two cannot disagree: the lock is
    also what the build is held to with `--locked`.

    Args:
        crates: `struct(crate, version, sha256, git)` list, from `parse_lock`.
        crate_name: The crate to look up.
        lock_label: Where the lock came from, for error messages.
        _fail: Fail function for errors.

    Returns:
        The pinned version string.
    """
    for crate in crates:
        if crate.crate == crate_name:
            return crate.version

    msg = "{}: no `{}` in the lock"
    return _fail(msg.format(lock_label, crate_name))

def _package(repo, subdir = _GIT_ROOT):
    """The Bazel package holding one crate, as a label prefix."""
    return "@%s//%s" % (repo, "" if subdir == _GIT_ROOT else subdir)

def _declare(
        crates,
        declared,
        _crate_repo = crate_repo,
        _git_crates_repo = git_crates_repo):
    """Create the pool repos for `crates` that are not declared yet.

    Args:
        crates: `struct(crate, version, sha256, git)` list, from `parse_lock`.
        declared: `{repo_name: struct(sha256, crates)}` of the repos already
            created, mutated in place. Callers keep ONE of these per module
            extension evaluation: that is what makes the pool shared, across
            extensions AND across hubs.
        _crate_repo: The crates.io repo rule, injectable for testing.
        _git_crates_repo: The git revision repo rule, injectable for testing.

    Returns:
        `{package: dir_name}` for `crates`, in the order given, where `package`
        is the Bazel package holding the crate, as a label prefix, and
        `dir_name` is the `<crate>-<version>` a vendor tree files it under. The
        two differ whenever a version carries `+` build metadata, and a package
        names a subdirectory whenever a git revision publishes several crates.
    """
    packages = {}
    dir_names = {}
    git_repos = {}

    for crate in crates:
        dir_name = "%s-%s" % (crate.crate, crate.version)

        if crate.git:
            repo = repo_names.git_crates(crate.git.strip_prefix)
            package = _package(repo, crate.git.subdir)

            git_repos.setdefault(repo, {
                "crates": {},
                "sha256": crate.sha256,
                "strip_prefix": crate.git.strip_prefix,
                "url": crate.git.url,
            })["crates"][crate.crate] = crate.git.subdir
        else:
            repo = _repo_name(crate)
            package = _package(repo)

            _declare_repo(declared, repo, crate.sha256, {}, lambda: _crate_repo(
                name = repo,
                crate = crate.crate,
                version = crate.version,
                sha256 = crate.sha256,
            ))

        if dir_name in dir_names and dir_names[dir_name] != package:
            # Two crate releases claiming one vendor directory: cargo resolves a
            # crate by the manifest it finds there, so one of them would build
            # against the other's source.
            msg = "{}: vendor directory claimed by both {} and {}"
            fail(msg.format(dir_name, dir_names[dir_name], package))

        dir_names[dir_name] = package
        packages[package] = dir_name

    for repo in sorted(git_repos):
        git_repo = git_repos[repo]

        _declare_repo(
            declared,
            repo,
            git_repo["sha256"],
            git_repo["crates"],
            lambda: _git_crates_repo(name = repo, **git_repo),
        )

    return packages

def _declare_repo(declared, repo, sha256, crates, create):
    """Create one pool repo, unless an earlier lock already did."""
    prev = declared.get(repo)

    if prev:
        if prev.sha256 != sha256:
            # Same crate release, two different archives: one of the locks is
            # wrong, and silently keeping the first would build against
            # something a lock does not describe.
            msg = "{}: checksum conflict between locks: {} != {}"
            fail(msg.format(repo, prev.sha256, sha256))

        if prev.crates != crates:
            # A revision's crates decide which of its subdirectories become
            # Bazel packages, so two locks taking different crates out of the
            # same revision have to agree on the union rather than race for it.
            msg = "{}: crate conflict between locks: {} != {}. Both `git.json` "
            msg += "pins for this revision need the same crates"
            fail(msg.format(repo, prev.crates, crates))

        return

    declared[repo] = struct(sha256 = sha256, crates = crates)
    create()

pool = struct(
    parse_lock = _parse_lock,
    declare = _declare,
    git_sources = _git_sources,
    pinned_version = _pinned_version,
    repo_name = _repo_name,
    __test__ = struct(
        _GIT_ROOT = _GIT_ROOT,
        _REGISTRY = _REGISTRY,
    ),
)
