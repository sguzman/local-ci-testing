{
  description = "Small Rust application with one Nix environment for local and GitHub CI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      rustTools = pkgs: with pkgs; [
        cargo
        rustc
        rustfmt
        clippy
        fish
      ];
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in {
          # Tools used by the workflow, including fish syntax validation.
          ci = pkgs.mkShell {
            packages = rustTools pkgs;
          };

          # Developer shell includes the local CI runner and GitHub publisher.
          default = pkgs.mkShell {
            packages = (rustTools pkgs) ++ [
              pkgs.wrkflw
              pkgs.gh
              pkgs.jq
              pkgs.openssl
              pkgs.coreutils
              pkgs.gnused
            ];
          };
        });

      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.rustPlatform.buildRustPackage {
            pname = "local-ci-testing";
            version = "0.1.0";
            src = ./.;
            cargoLock.lockFile = ./Cargo.lock;
            meta.mainProgram = "local-ci-testing";
          };
        });

      checks = forAllSystems (system: {
        package = self.packages.${system}.default;
      });
    };
}
