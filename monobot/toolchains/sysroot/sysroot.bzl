"""A sysroot, assembled from pinned archives.

A downloaded LLVM release ships clang, lld and libc++, but no libc: no stdio.h,
no crt1.o, no libc.so. Without a sysroot clang looks for those under /usr, which
means linking against whatever the build machine happens to have, or, on a
distribution that has no /usr/include at all, finding nothing.

One repository per target architecture, each named by the CPU it is for. What
goes in differs by architecture, because what native-image can produce does:

  - amd64 links statically, which native-image allows only against musl, so its
    sysroot comes from Alpine. It has to carry a static zlib as well as musl
    itself, because GraalVM links -lz and a glibc zlib cannot go into a musl
    binary. Alpine is the source because both arrive already built against musl
    and in one layout, and because .apk files are gzipped tarballs, so no
    Alpine-specific tooling is needed to unpack them.

Whatever the source, it is the same operation, extracting a pinned set of
archives into one directory, so one rule covers it.
"""

_BUILD_FILE = """\
filegroup(
    name = "sysroot",
    srcs = ["."],
    visibility = ["//visibility:public"],
)
"""

def _sysroot_impl(rctx):
    # Written before extracting so Bazel creates the directory for us.
    rctx.file("sysroot/BUILD.bazel", _BUILD_FILE)

    for url, sha256 in rctx.attr.archives.items():
        rctx.download_and_extract(
            output = "sysroot",
            sha256 = sha256,
            # Stated, because Bazel cannot infer it here: a URL ending in .apk,
            # which is a gzipped tarball under a name Bazel does not recognise.
            type = "tar.gz",
            url = url,
        )

sysroot = repository_rule(
    implementation = _sysroot_impl,
    attrs = {
        "archives": attr.string_dict(
            doc = "URL to sha256, all extracted into the same sysroot.",
            mandatory = True,
        ),
    },
    doc = "Materializes a sysroot from a set of pinned archives.",
)
