"""
`//sysroots`: package-manager-agnostic sysroot module.

Each `sysroots.<pkg_manager>(name = "...", ...)` tag materializes a single hub
repo `@<name>` exposing `@<name>/<distro>/<version>/<arch>:sysroot` filegroups,
ready for `llvm.sysroot(label = ...)` and `pg_build(sysroot = ...)` consumers.

Today only `sysroots.apt(...)` is wired up; `sysroots.rpm(...)` and
`sysroots.apk(...)` are reserved for future package managers and would be added
as additional tag classes on this same extension.
"""

load("//apt:tag.bzl", _apt_tag = "apt")

# buildifier: disable=bzl-visibility
load("//apt/private:alias_hub.bzl", "alias_hub")

# buildifier: disable=bzl-visibility
load("//apt/private:manifest.bzl", _manifest = "manifest")

# buildifier: disable=bzl-visibility
load("//apt/private:repo.bzl", "hub_repo")

# buildifier: disable=bzl-visibility
load("//apt/private:resolve.bzl", _resolve = "resolve")
load("//common:lock.bzl", _Lock = "lock")
load("//common:tag_key.bzl", "tag_key")

def _dedup_key(tag):
    """Content key for `deduped` tags: every attr except `name`.

    Two tags with the same `_dedup_key` share a single materialized hub (the
    first one becomes the canonical, the rest become `alias_hub` instances). The
    `lock` attr is part of the key, so tags meant to dedup should share the same
    `lock` label.
    """
    return tag_key(tag, exclude = ["name"])

def _lock_path(tag, name):
    """Workspace-relative path where the lockfile lives in the source tree.

    Default (`apt/locks/<name>.lock`) assumes the consumer's workspace is the
    `//sysroots` module itself (testing / standalone). Real callers always pass
    `lock = ...` explicitly so the path matches their own repo layout.
    """
    if tag.lock:
        return "%s/%s" % (tag.lock.package, tag.lock.name)
    return "apt/locks/%s.lock" % name

def _lock_filename(tag, name):
    """Lockfile basename inside the hub's `<distro>/<version>/lock/` package."""
    if tag.lock:
        return tag.lock.name
    return "%s.lock" % name

def _read_lock(ctx, tag, merged):
    """Return a validated `Lock`, or `None` when absent/stale (warn)."""
    name = merged.name
    distro = merged.distro
    version = merged.version

    if not tag.lock:
        # buildifier: disable=print
        print((
            "WARNING: no sysroots.apt(%s) lockfile - resolving live. " +
            "Generate one with: bazel run @%s//%s/%s/lock:update, " +
            "then set lock = ... on the sysroots.apt tag."
        ) % (name, name, distro, version))
        return None

    lock_json = ctx.read(tag.lock)
    if not lock_json.strip():
        # buildifier: disable=print
        print((
            "WARNING: sysroots.apt(%s) lockfile is empty - resolving live. " +
            "Regenerate with: bazel run @%s//%s/%s/lock:update"
        ) % (name, name, distro, version))
        return None

    lock = _Lock.decode(lock_json)
    error = _Lock.validate(
        lock,
        snapshot = merged.snapshot,
        archs = merged.archs,
        requested_packages = merged.packages,
    )
    if error:
        # buildifier: disable=print
        print((
            "WARNING: sysroots.apt(%s) lockfile is stale (%s). " +
            "Resolving live. Regenerate with: " +
            "bazel run @%s//%s/%s/lock:update"
        ) % (name, error, name, distro, version))
        return None

    return lock

def _materialize_tag(ctx, tag):
    """Resolve one `sysroots.apt(...)` tag to its hub-repo `info` dict."""
    parsed_manifest = None
    if tag.manifest:
        parsed_manifest = _manifest.parse(ctx.read(tag.manifest))

    merged = _manifest.resolve_attrs(
        name = tag.name,
        distro = tag.distro,
        version = tag.version,
        archs = list(tag.archs),
        packages = list(tag.packages),
        snapshot = tag.snapshot,
        manifest = parsed_manifest,
    )

    lock = _read_lock(ctx, tag, merged)
    if not lock:
        lockf, package_name_map = _resolve.sysroot(
            ctx,
            "_sysroots_apt_%s" % tag.name,
            merged,
            merged.snapshot,
        )
        lock = _Lock.new(
            snapshot = merged.snapshot,
            archs = merged.archs,
            packages = lockf.packages(),
            package_name_map = package_name_map,
        )

    archs_dict = {
        arch: [p for p in lock.packages if p["arch"] == arch]
        for arch in merged.archs
    }

    return merged.distro, merged.version, dict(
        archs = archs_dict,
        lock_json = _Lock.encode(lock),
        lock_path = _lock_path(tag, tag.name),
        lock_filename = _lock_filename(tag, tag.name),
    )

def _impl(ctx):
    # Collect apt tags by name, detecting real conflicts. Track which root-
    # module tags are dev-only so the returned extension_metadata can split them
    # into root_module_direct_deps vs root_module_direct_dev_deps; Bazel errors
    # if a non-dev root module reports a tag under dev, or vice-versa.
    seen = {}
    queue = []
    root_dev = {}
    root_nondev = {}
    for module in ctx.modules:
        for tag in module.tags.apt:
            key = tag_key(tag, exclude = ["lock"])
            prev = seen.get(tag.name)
            if prev:
                if prev.key != key:
                    fail((
                        "sysroots.apt(name=%r) declared with different " +
                        "configurations: in module %r and module %r. " +
                        "Pick one definition or rename the tag."
                    ) % (tag.name, prev.module, module.name))
                continue
            seen[tag.name] = struct(key = key, module = module.name)
            queue.append(tag)
            if module.is_root:
                if ctx.is_dev_dependency(tag):
                    root_dev[tag.name] = True
                else:
                    root_nondev[tag.name] = True

    # Dedup tracking: `_dedup_key(tag)` to canonical `tag.name`. The first tag
    # in each dedup group materializes a full `hub_repo`; subsequent tags with
    # the same key become `alias_hub` instances symlinking the canonical's
    # per-arch directories. See `//apt/private:alias_hub.bzl` for the
    # why-symlinks rationale (filegroup-mode consumers need real files at the
    # label's on-disk path, which `alias()` BUILD targets can't provide).
    canonical_for_dedup_key = {}

    for tag in queue:
        distro, version, info = _materialize_tag(ctx, tag)
        distros_json = json.encode({distro: {version: info}})

        if tag.deduped:
            dedup_key = _dedup_key(tag)
            canonical_name = canonical_for_dedup_key.get(dedup_key)
            if canonical_name:
                alias_hub(
                    name = tag.name,
                    canonical_build = "@%s//:BUILD.bazel" % canonical_name,
                    distros_json = distros_json,
                )
                continue
            canonical_for_dedup_key[dedup_key] = tag.name

        hub_repo(
            name = tag.name,
            distros_json = distros_json,
            extra_files = tag.extra_files,
            exports = tag.exports,
        )

    return ctx.extension_metadata(
        reproducible = True,
        root_module_direct_deps = sorted(root_nondev.keys()),
        root_module_direct_dev_deps = sorted(root_dev.keys()),
    )

sysroots = module_extension(
    implementation = _impl,
    tag_classes = dict(
        apt = _apt_tag,
    ),
)
