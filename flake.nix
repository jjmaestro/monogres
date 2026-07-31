{
  description = "monogres development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Pinned solely for libxml2. The prebuilt LLVM that monobot's native image
    # build downloads links `libxml2.so.2`, and libxml2 2.15 renamed the
    # soname to `libxml2.so.16`, so unstable cannot satisfy it. 24.11 carries
    # 2.13.8, the last series with the old soname. Drop this once the pinned
    # LLVM links the new one.
    nixpkgs-libxml2.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { nixpkgs, nixpkgs-libxml2, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          build = import ./bazel.nix {
            inherit pkgs;
            libxml2 = nixpkgs-libxml2.legacyPackages.${system}.libxml2;
          };
        in
        {
          default = pkgs.mkShell {
            packages = build.packages ++ (with pkgs; [
              prek
              python314
              hadolint
              jsonnet
              uv
            ]);

            env = build.env;

            shellHook = ''
              export UV_PYTHON="$(command -v python3)"
              export UV_NO_MANAGED_PYTHON=1
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              prek install --prepare-hooks --quiet
            '';
          };
        }
      );
    };
}
