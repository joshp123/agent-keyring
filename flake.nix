{
  description = "Agent Keyring command";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df";

  outputs = { self, nixpkgs }:
  let
    forSystems = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
  in {
    packages = forSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        client = pkgs.callPackage ./nix/cli.nix { build = builtins.substring 0 12 (self.lastModifiedDate or "0"); };
      in
      {
        default = client;
        agent-keyring = client;
      }
    );
    devShells = forSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        dev = import ./devenv.nix { inherit pkgs; };
      in {
        default = pkgs.mkShell {
          inherit (dev) packages;
          shellHook = dev.enterShell;
        };
      }
    );
  };
}
