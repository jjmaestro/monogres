{ pkgs }:
let
  # Bazel's test runner and build actions need these tools on PATH:
  # test-setup.sh needs sed/find, and the docs diff test needs diff/sed/awk.
  bazelDeps = with pkgs; [
    bash
    coreutils
    diffutils
    findutils
    gawk
    gnugrep
    gnused
  ];
  bazelPath = pkgs.lib.makeBinPath bazelDeps;

  # On NixOS run bazelisk inside an FHS environment so that the tool launchers
  # Bazel generates can find bash (e.g. java_binary's `#!/usr/bin/env bash`
  # stub scripts). Those actions run with an empty environment, so
  # --action_env/--host_action_env can't reach them: `env` falls back to
  # /bin:/usr/bin, which on NixOS has no bash.
  bazelisk =
    if pkgs.stdenv.isLinux then
      pkgs.buildFHSEnv {
        name = "bazelisk";
        # zlib: needed by the bazelisk-downloaded bazel binary (embedded JDK)
        targetPkgs = _: bazelDeps ++ [
          pkgs.bazelisk
          pkgs.zlib
        ];
        runScript = "bazelisk";
      }
    else
      pkgs.bazelisk;

  # --host_action_env is needed in addition to --action_env: actions that run
  # in the exec configuration ("[for tool]") don't inherit --action_env.
  bazel = pkgs.writeShellScriptBin "bazel" ''
    # The Bazel server outlives the (ephemeral) nix-shell TMPDIR it was
    # started with, and linux-sandbox fails to bind-mount a deleted TMPDIR.
    # Pin a stable one.
    export TMPDIR=/tmp

    case "''${1:-}" in
      test)
        exec ${bazelisk}/bin/bazelisk "$@" \
          --action_env=PATH="${bazelPath}" \
          --host_action_env=PATH="${bazelPath}" \
          --test_env=PATH="${bazelPath}"
        ;;
      build|run)
        exec ${bazelisk}/bin/bazelisk "$@" \
          --action_env=PATH="${bazelPath}" \
          --host_action_env=PATH="${bazelPath}"
        ;;
      *)
        exec ${bazelisk}/bin/bazelisk "$@"
        ;;
    esac
  '';
in
{
  packages = [
    bazel
    bazelisk
    pkgs.buildifier
  ];

  env = {
    BAZEL_SH = "${pkgs.bash}/bin/bash";
  };
}
