"""
`.deb` extraction helper for the `//sysroots/apt` repository rule.

Bazel's `repository_ctx.download_and_extract(type="deb")` unpacks the outer `ar`
archive but leaves the inner `data.tar.*` on disk as a still-compressed blob;
the same `ArFunction.INSTANCE` Java class handles `.ar` and `.deb` identically
and never recurses into the inner tar. This module runs the two-stage extract
(ar layer via `download_and_extract`, tar layer via a second `rctx.extract`
call), producing the actual sysroot tree under `out_dir`, and removes the
intermediate `debian-binary` / `control.tar.*` / `data.tar.*` files. No
`dpkg-deb`, no host `ar`, no host `tar` invocations needed; both layers go
through Bazel's bundled Apache Commons Compress / zstd-jni decompressors.

## Compression coverage

`_DATA_TAR_CANDIDATES` lists the `data.tar.*` variants we probe for after the
outer-ar unpack. The set is what Bazel's `rctx.extract` natively decompresses
(per the `CompressedTarFunction` subclasses routed in `DecompressorValue.java`)
intersected with what `deb(5)` allows, ordered most-common-first for fast-path
probing:

  - `data.tar.xz`:  Debian default in every supported release (10/11/12/13).
  - `data.tar.zst`: Ubuntu default since 21.10 (Impish); used by Jammy/Noble.
  - `data.tar.gz`:  Legacy / third-party / pre-Squeeze era.
  - `data.tar.bz2`: Pre-2016 snapshot.debian.org content; build-obsoleted by
                    dpkg 1.18.11 (Oct 2016), unpack still supported.
  - `data.tar`:     Uncompressed (`-Znone`); rare custom/embedded builds.

`control.tar.*` never supported `.bz2` or `.lzma` per `deb(5)`, so the
control-side `_CLEANUP` list is narrower than the data-side candidates.

## Known gap: `data.tar.lzma`

Bazel's `DecompressorValue.java` has no `.tar.lzma` route, so a `.deb` shipping
`data.tar.lzma` (legitimate per `deb(5)`) would fail here with the
candidate-not-found error. In practice this is a non-issue: dpkg-deb has emitted
a hard error on `-Zlzma` builds since dpkg 1.18.11 (Oct 2016), so the only place
such packages exist is `snapshot.debian.org` historical content older than that.
The fix path would be to route extraction through a Bazel-managed `bsdtar`
(libarchive supports `.tar.lzma` natively); tracked separately.

## Bazel source references (at the 7.1.0 floor)

  - `ArFunction.java`: outer-ar-only behavior; both `.ar` and `.deb`
    extensions route here. The Javadoc itself notes the no-recursion design:
    https://github.com/bazelbuild/bazel/blob/8f2fb63ebe5d3e2da90d6bf06725263441fcef33/src/main/java/com/google/devtools/build/lib/bazel/repository/ArFunction.java
  - `DecompressorValue.java`: the extension→decompressor routing table.
    Lines 99-126 enumerate every supported extension; lines 116-117 route
    `.ar`/`.deb` to `ArFunction.INSTANCE`:
    https://github.com/bazelbuild/bazel/blob/8f2fb63ebe5d3e2da90d6bf06725263441fcef33/src/main/java/com/google/devtools/build/lib/bazel/repository/DecompressorValue.java#L99-L126

## Tests

Unit-testing this module would require mocking `rctx.download_and_extract` and
`rctx.extract`, which the test fixtures do not support. The function is
exercised end-to-end by:

  - The examples workspace under `examples/`: real apt resolution against
    Debian 12 (covers `data.tar.xz`).
  - The per-compression integration tests under `tests/apt/compression/`:
    pinned snapshot URLs covering `data.tar.{xz,zst,gz,bz2}`.
"""

_DATA_TAR_CANDIDATES = [
    "data.tar.xz",
    "data.tar.zst",
    "data.tar.gz",
    "data.tar.bz2",
    "data.tar",
]

_CLEANUP = [
    "debian-binary",
    "control.tar.xz",
    "control.tar.zst",
    "control.tar.gz",
    "control.tar",
] + _DATA_TAR_CANDIDATES

def _download_and_extract(rctx, urls, sha256, out_dir):
    """Download a `.deb` and unpack its sysroot files into `out_dir`.

    Args:
        rctx: A `repository_ctx`.
        urls: List of mirror URLs for the `.deb` file.
        sha256: Expected sha256 of the `.deb` file.
        out_dir: Output directory inside the repo. Will be created by Bazel
            during extraction if absent.
    """
    rctx.download_and_extract(
        url = urls,
        sha256 = sha256,
        output = out_dir,
        type = "deb",
    )

    data_tar = None
    for candidate in _DATA_TAR_CANDIDATES:
        path = "%s/%s" % (out_dir, candidate)
        if rctx.path(path).exists:
            data_tar = path
            break
    if data_tar == None:
        fail((
            "//sysroots/apt: no data.tar.* candidate (%s) found after deb " +
            "extract of %s. Did the `.deb` ship with an unsupported " +
            "compression (e.g. `data.tar.lzma`)?"
        ) % (", ".join(_DATA_TAR_CANDIDATES), urls))

    rctx.extract(
        archive = data_tar,
        output = out_dir,
    )

    rctx.execute(
        ["rm", "-f"] + ["%s/%s" % (out_dir, f) for f in _CLEANUP],
    )

deb = struct(
    download_and_extract = _download_and_extract,
)
