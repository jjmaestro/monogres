{
  description = "monogres development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { nixpkgs, ... }:
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
          build = import ./bazel.nix { inherit pkgs; };
        in
        {
          default = pkgs.mkShell {
            packages = build.packages ++ (with pkgs; [
              prek
              python314
              hadolint
              jsonnet
            ]);

            env = build.env;

            shellHook = ''
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              prek install --prepare-hooks --quiet
            '';
          };
        }
      );
    };
}
