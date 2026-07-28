"""
The shared crate pool: `Cargo.lock` in, deduplicated crate repos out.

A pgrx extension pins its whole dependency closure in a `Cargo.lock`, which
records, for every crates.io package, the exact version AND its sha256. That is
all the pool needs: the lock is read at load time and each unique (crate,
version) becomes one `crate_repo` (see `crate_repo.bzl`), created once and
shared by every extension, extension version and PG major that pins it.

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

# The `source` of a package that comes from crates.io. Packages with no `source`
# are path/workspace members, i.e. the extension's own crates, which come from
# its source tree. Anything else is a git or alternate-registry dependency,
# which has no checksum in the lock and so cannot be pinned by content here.
_REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"

_PACKAGE = "[[package]]"

_KEYS = ("name", "version", "source", "checksum")

def _parse_lock(content, lock_label = "Cargo.lock", _fail = fail):
    """Parse a `Cargo.lock` into the crates.io packages it pins.

    Args:
        content: The contents of the `Cargo.lock`.
        lock_label: Where the lock came from, for error messages.
        _fail: Fail function for errors.

    Returns:
        A list of `struct(crate, version, sha256)`, one per crates.io package,
        in lock order (which cargo writes sorted by name).
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

        if source != _REGISTRY:
            msg = "{}: {}: unsupported source: {}. Only crates.io packages "
            msg += "are pinned by content in the lock"
            return _fail(msg.format(lock_label, name, source))

        checksum = package.get("checksum", "")

        if not checksum:
            msg = "{}: {}: no checksum in the lock"
            return _fail(msg.format(lock_label, name))

        crates.append(struct(
            crate = package["name"],
            version = package["version"],
            sha256 = checksum,
        ))

    return crates

def _repo_name(crate):
    return repo_names.crate(crate.crate, crate.version)

def _declare(crates, declared, _crate_repo = crate_repo):
    """Create the pool repos for `crates` that are not declared yet.

    Args:
        crates: `struct(crate, version, sha256)` list, from `parse_lock`.
        declared: `{repo_name: sha256}` of the repos already created, mutated in
            place. Callers keep ONE of these per module extension evaluation:
            that is what makes the pool shared, across extensions AND across
            hubs.
        _crate_repo: The repo rule, injectable for testing.

    Returns:
        `{repo_name: dir_name}` for `crates`, in the order given, where
        `dir_name` is the `<crate>-<version>` a vendor tree files the crate
        under. The two differ whenever a version carries `+` build metadata.
    """
    names = {}

    for crate in crates:
        name = _repo_name(crate)
        names[name] = "%s-%s" % (crate.crate, crate.version)

        sha256 = declared.get(name, "")

        if sha256:
            if sha256 != crate.sha256:
                # Same crate release, two different archives: one of the locks
                # is wrong, and silently keeping the first would build against
                # something a lock does not describe.
                msg = "{}: checksum conflict between locks: {} != {}"
                fail(msg.format(name, sha256, crate.sha256))

            continue

        declared[name] = crate.sha256

        _crate_repo(
            name = name,
            crate = crate.crate,
            version = crate.version,
            sha256 = crate.sha256,
        )

    return names

pool = struct(
    parse_lock = _parse_lock,
    declare = _declare,
    repo_name = _repo_name,
    __test__ = struct(
        _REGISTRY = _REGISTRY,
    ),
)
