{ lib, buildGoModule }:

buildGoModule {
  pname = "agent-keyring-relay";
  version = "0.3.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../go.mod
      ../go.sum
      ../cmd/agent-keyring-relay
      ../internal/authority
      ../internal/relay
      ../internal/relaycrypto
      ../gen/go
    ];
  };
  vendorHash = "sha256-+FPkm39xz8zhXhU8MWCSejNmi8VfYKHKCO1Z8sAM5E0=";
  subPackages = [ "cmd/agent-keyring-relay" ];
  env.CGO_ENABLED = "0";
  doCheck = false;

  meta = {
    description = "Tailnet relay for approved, sealed Agent Keyring logins";
    license = lib.licenses.mit;
    mainProgram = "agent-keyring-relay";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
