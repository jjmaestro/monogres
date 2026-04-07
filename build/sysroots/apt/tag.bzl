"""
The `sysroots.apt(...)` tag class.

A tag describes one sysroot hub repo by name. Required fields (`distro`,
`version`, `packages`, `snapshot`) may be set as explicit tag attrs, as fields
in the optional `manifest` JSON, or a mix. Explicit tag attrs win on conflict.
`archs` defaults to `//common:archs.bzl::ARCHS` when both tag and manifest leave
it empty.

`lock` is optional; when absent (or stale) the extension warns and live-resolves
against `snapshot`.

`extra_files` is a `label_keyed_string_dict` mapping source labels to the
in-sysroot paths where their content should be injected. The path may contain a
`{arch}` placeholder which is substituted at write time.
"""

apt = tag_class(
    attrs = dict(
        name = attr.string(
            mandatory = True,
            doc = "Hub repo name (e.g. `\"llvm_sysroot\"`).",
        ),
        distro = attr.string(
            doc = (
                "Distro id (`\"debian\"`). Required at the tag site or in " +
                "the manifest. Tag attr wins on conflict."
            ),
        ),
        version = attr.string(
            doc = (
                "Distro version (e.g. `\"12\"`). Required at the tag site " +
                "or in the manifest. Tag attr wins on conflict."
            ),
        ),
        archs = attr.string_list(
            doc = (
                "Debian arches to resolve (e.g. `[\"amd64\", \"arm64\"]`). " +
                "Defaults to `//sysroots/common:archs.bzl::ARCHS` if " +
                "neither tag nor manifest provides a value."
            ),
        ),
        packages = attr.string_list(
            doc = (
                "Debian package constraints to resolve. Required at the " +
                "tag site or in the manifest. Tag attr wins on conflict."
            ),
        ),
        manifest = attr.label(
            doc = (
                "Optional JSON manifest providing any of {distro, " +
                "distro_version, archs, packages, snapshot}. See " +
                "`//apt/private:manifest.bzl` for the schema."
            ),
        ),
        snapshot = attr.string(
            doc = (
                "Debian snapshot timestamp (e.g. `\"20250113T000000Z\"`). " +
                "Required at the tag site or in the manifest. Tag attr " +
                "wins on conflict."
            ),
        ),
        lock = attr.label(
            doc = (
                "Optional lockfile. When absent or stale, the extension " +
                "warns and live-resolves against `snapshot`."
            ),
        ),
        extra_files = attr.label_keyed_string_dict(
            doc = (
                "Tier-2 file injection map: `{source_label: " +
                "in_sysroot_path}`. The path may contain a `{arch}` " +
                "placeholder substituted at write time. Applied after the " +
                "Tier-1 normalizations."
            ),
        ),
        exports = attr.string_list(
            doc = (
                "Additional in-sysroot paths to `exports_files`-expose on " +
                "each per-arch package, so consumers can take a label-typed " +
                "dep on each specific file (e.g. `\"usr/bin/perl\"` makes " +
                "`@<hub>//<distro>/<version>/<arch>:usr/bin/perl` a valid " +
                "label, addressable analogously to `@bison//bin:bison`). " +
                "Paths must NOT include a `{arch}` placeholder; they refer " +
                "to files already present in every per-arch tree after " +
                "extraction. The `sysroot.tar` artifact is always exported; " +
                "this list is additive."
            ),
        ),
        deduped = attr.bool(
            default = True,
            doc = (
                "Share a single materialized hub with any other tag that " +
                "has identical configuration (every attr except `name`). " +
                "When True (the default), one canonical hub is materialized " +
                "per content key; the remaining tags become symlink aliases " +
                "pointing at the canonical's per-arch directories. Set " +
                "False to keep each tag's hub fully independent. Useful " +
                "when extraction order matters or when deliberately " +
                "materializing the same content twice for test isolation."
            ),
        ),
    ),
)
