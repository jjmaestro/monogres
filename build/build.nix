{ pkgs }:
let
  # Bazel's test runner and build actions need these tools on PATH
  bazelDeps = with pkgs; [
    bash
    coreutils
    gnused
    findutils
    gnugrep
    diffutils
    gawk
    gcc
  ];
  bazelPath = pkgs.lib.makeBinPath bazelDeps;

  bazel = pkgs.writeShellScriptBin "bazel" ''
    case "''${1:-}" in
      test)
        exec ${pkgs.bazelisk}/bin/bazelisk "$@" --test_env=PATH="${bazelPath}"
        ;;
      build|run)
        exec ${pkgs.bazelisk}/bin/bazelisk "$@" --action_env=PATH="${bazelPath}"
        ;;
      *)
        exec ${pkgs.bazelisk}/bin/bazelisk "$@"
        ;;
    esac
  '';
in
{
  packages = with pkgs; [
    gnumake
    bazel
    bazelisk
    buildifier
  ];

  env = {
    BAZEL_SH = "${pkgs.bash}/bin/bash";
  };
}
