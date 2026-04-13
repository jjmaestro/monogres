"""
Lockfile schema for `monoext`'s apt package resolution.

Provides encode/decode/validate helpers for the `.lock` JSON file that caches
resolved Debian package state, eliminating network downloads on cold
module-extension evaluations.
"""

load("//monoext/private/apt:snapshot.bzl", _SNAPSHOT = "SNAPSHOT")

LOCK_VERSION = 1
SNAPSHOT = _SNAPSHOT

def _lock_new(snapshot, archs, packages, package_name_map):
    """Constructs an `AptLock` struct.

    Args:
        snapshot: The Debian snapshot timestamp used during resolution.
        archs: List of architecture strings resolved.
        packages: List of package dicts from `lockf.packages()`.
        package_name_map: `{requested: resolved}` virtual package substitutions.

    Returns:
        An `AptLock` struct.
    """
    return struct(
        version = LOCK_VERSION,
        snapshot = snapshot,
        archs = sorted(archs),
        packages = packages,
        package_name_map = package_name_map,
    )

def _lock_encode(lock):
    """Serializes an `AptLock` struct to a JSON string.

    Args:
        lock: A lock data struct from `lock_new`.

    Returns:
        A JSON string.
    """
    return json.encode_indent({
        "archs": lock.archs,
        "package_name_map": lock.package_name_map,
        "packages": lock.packages,
        "snapshot": lock.snapshot,
        "version": lock.version,
    }, indent = "  ")

def _lock_decode(lock_json):
    """Deserializes a JSON string into an `AptLock` struct.

    Args:
        lock_json: A JSON string produced by `lock_encode`.

    Returns:
        An `AptLock` struct.
    """
    d = json.decode(lock_json)

    version = d.get("version", 0)
    if version != LOCK_VERSION:
        msg = "AptLock version %d, expected %d. "
        msg += "Regenerate with: bazel run @<pkgs>//deb/lock:update"
        fail(msg % (version, LOCK_VERSION))

    return _lock_new(
        snapshot = d["snapshot"],
        archs = d["archs"],
        packages = d["packages"],
        package_name_map = d.get("package_name_map", {}),
    )

def _lock_validate(lock, snapshot, archs, requested_packages):
    """Validates an `AptLock` struct against current inputs.

    Returns an error string describing the mismatch, or `None` if valid.

    Args:
        lock: An `AptLock` struct.
        snapshot: Expected Debian snapshot timestamp.
        archs: Expected architecture list.
        requested_packages: List of all requested package names.

    Returns:
        An error string, or `None` if the lockfile is valid.
    """
    if lock.snapshot != snapshot:
        return "snapshot mismatch: lock has %s, expected %s" % (
            lock.snapshot,
            snapshot,
        )

    if sorted(archs) != lock.archs:
        return "archs mismatch: lock has %s, expected %s" % (
            lock.archs,
            sorted(archs),
        )

    pnm = lock.package_name_map
    locked_names = {p["name"]: True for p in lock.packages}

    missing = [
        pkg
        for pkg in requested_packages
        if pnm.get(pkg, pkg) not in locked_names
    ]

    if missing:
        return "missing packages: %s" % ", ".join(sorted(missing))

    return None

apt_lock = struct(
    LOCK_VERSION = LOCK_VERSION,
    new = _lock_new,
    encode = _lock_encode,
    decode = _lock_decode,
    validate = _lock_validate,
)
