#!/bin/sh
# Standalone C-preprocessor shim for the hermetic sysroot toolchain.
#
# The hermetic sandbox ships no standalone `cpp` binary, only the clang driver.
# A build step that invokes `cpp` by name to preprocess non-C inputs finds none
# on PATH; this shim stands in for it, routing such calls to the toolchain
# clang's preprocessor.
#
# The clang to use comes from `$CPP_CLANG`: the consumer exports the same
# sysroot-baked clang the compile uses, so the preprocessor honors the build's
# `--sysroot`. Reading it from the environment (rather than baking a path)
# keeps the shim location-independent, so it works whether it is invoked by
# absolute path or resolved by name off PATH.
#
# `-E` runs the preprocessor only; `-x c` forces the C language for the non-`.c`
# inputs (clang emits nothing for an unrecognized suffix otherwise).
exec "${CPP_CLANG:?cpp_wrapper: CPP_CLANG must point at the toolchain clang}" \
    -E -x c "$@"
