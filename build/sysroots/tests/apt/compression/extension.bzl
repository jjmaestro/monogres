"""
Test module extension: one `compression_test_repo` per `data.tar.*` type.

Pinned to immutable hosts (`snapshot.debian.org` timestamps,
`launchpadlibrarian.net` blob IDs) so the recorded SHA-256s stay valid.

Covers every `data.tar.*` compression Bazel's bundled decompressors handle that
`deb(5)` allows. Two intentional omissions:

  - `data.tar` (uncompressed, `-Znone`): no small, publicly-mirrored fixture
    found in time-bounded search; official Debian and Ubuntu archives use
    compression unconditionally. Maintaining a locally-built `.deb` is overkill:
    tooling support is identical to the other candidates (same `rctx.extract`
    code path) and a missing candidate in `_DATA_TAR_CANDIDATES` would be caught
    by code review.
  - `data.tar.lzma`: Bazel cannot decompress it. See `//apt/private:deb.bzl`
    for the gap and the bsdtar-based fix path.
"""

load(":compression.bzl", "compression_test_repo")

_CASES = [
    dict(
        name = "compression_xz",
        url = "https://snapshot.debian.org/archive/debian/20250416T143525Z/pool/main/h/hello/hello_2.10-5_amd64.deb",
        sha256 = "4536aabbb75ec21ffe161099ee4b97274945770bdb0682e25ec322421211ca5e",
    ),
    dict(
        name = "compression_zstd",
        url = "https://launchpadlibrarian.net/723755938/hello_2.10-3build1_amd64.deb",
        sha256 = "e68cf4365b7aa9c4e2af4af6eee1710d6f967059b7b4af62786e8870d7366333",
    ),
    dict(
        name = "compression_gzip",
        url = "https://snapshot.debian.org/archive/debian/20100807T032909Z/pool/main/h/hello/hello_2.6-1_amd64.deb",
        sha256 = "60d9cfa89713dba79da21c955f745e6ecec0926c9b37cf974698cb76fbcf44af",
    ),
    dict(
        # bsd-finger source package, fingerd binary. data.tar.bz2 +
        # control.tar.gz; deb(5) never allowed control.tar.bz2.
        name = "compression_bzip2",
        url = "https://snapshot.debian.org/archive/debian/20120618T101001Z/pool/main/b/bsd-finger/fingerd_0.17-15_i386.deb",
        sha256 = "8430c8b151c53eb589975153a155131a71e723259e0cceca2e8337acf2dab446",
    ),
]

def _impl(_ctx):
    for case in _CASES:
        compression_test_repo(
            name = case["name"],
            url = case["url"],
            sha256 = case["sha256"],
        )

compression_tests = module_extension(implementation = _impl)
