{
  description = "Agent Keyring client and relay";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df";

  outputs = { self, nixpkgs }: {
    packages = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ] (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        relay = pkgs.callPackage ./nix/relay.nix { };
        client = pkgs.callPackage ./nix/cli.nix { };
      in
      {
        default = relay;
        agent-keyring-relay = relay;
        agent-keyring = client;
      }
    );
  };
}
