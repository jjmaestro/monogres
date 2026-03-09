# AGENTS.md

## Development environment

NixOS project. `flake.nix` + `.envrc` (direnv) provide the dev shell.

<!-- markdownlint-capture -->
<!-- markdownlint-disable MD013 -->
- **Git**: always inside `nix develop`, hooks need nix tools
  `nix develop --command bash -c 'git commit ...'`
- **Bazel**: always inside Docker as `postgres`.
  `docker exec -u postgres bzlsndbx-monogres_x86_64 bazel ...`
- **Docker**: start container (if not running)
  `nix develop --command bash -c 'make -C build/docker run-image USE_CACHE=true DETACHED=true'`
  Container: `bzlsndbx-<project>_<arch>` (ask user if arch != x86_64)
- **Download proxy**: opt-in, Docker only. Copy `.bazel_downloader.cfg.user.tmpl` to
  `.bazel_downloader.cfg.user` and uncomment `--downloader_config` in `.bazelrc.user`.
  Every workspace that opts in needs its own copy, or Bazel refuses to parse the config.
  The container reaches the proxy at `host.docker.internal`, which does not resolve on
  the host, so wiring it there breaks host-side `bazel query`/`mod`.
<!-- markdownlint-restore -->

## Validation

Fast checks first. Remind user to run the full build (last step).

<!-- markdownlint-capture -->
<!-- markdownlint-disable MD013 -->
1. Pre-commit (seconds, in host):
   `nix develop --command bash -c 'prek run --all-files'`
     - Single hook: `prek run <hook> --all-files`.
2. Integration tests (minutes, Docker):
   `docker exec -u postgres -w /src/workspace/examples bzlsndbx-monogres_x86_64 bazel test //...`
     - Invariants only (faster): append `--test_size_filters=small,medium`
3. Full build (1h+, ask the user): Never build all targets. Remind user to run.
<!-- markdownlint-restore -->
