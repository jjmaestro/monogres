{ pkgs, libxml2 }:
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
        # Shared libraries that downloaded, non-nix binaries link against and
        # would otherwise not find:
        #   zlib:    the bazelisk-downloaded bazel binary (embedded JDK)
        #   zstd:    clang from toolchains_llvm (monobot's native image build)
        #   libxml2: ld.lld from the same toolchain. Comes from its own pin,
        #            see flake.nix: it is the one soname unstable cannot serve.
        targetPkgs = _: bazelDeps ++ [
          libxml2
          pkgs.bazelisk
          pkgs.zlib
          pkgs.zstd
        ];
        runScript = "bazelisk";
      }
    else
      pkgs.bazelisk;

  # Some actions call ctx.actions.run_shell WITHOUT use_default_shell_env (e.g.
  # protobuf's ProtocAuthenticityCheck): Bazel runs them with an empty env (no
  # PATH), so bare grep/cat in the script aren't found on NixOS, and
  # --action_env can't reach them precisely because they opt out of the default
  # shell env. Point Bazel's run_shell shell at a wrapper that puts our tools on
  # PATH before exec'ing real bash. (Same idea as the FHS env above, aimed at
  # the shell instead of the launchers.)
  bashShell = pkgs.writeShellScriptBin "bash" ''
    export PATH="${bazelPath}''${PATH:+:$PATH}"
    exec ${pkgs.bash}/bin/bash "$@"
  '';

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
          --shell_executable="${bashShell}/bin/bash" \
          --action_env=PATH="${bazelPath}" \
          --host_action_env=PATH="${bazelPath}" \
          --test_env=PATH="${bazelPath}"
        ;;
      build|run)
        exec ${bazelisk}/bin/bazelisk "$@" \
          --shell_executable="${bashShell}/bin/bash" \
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
