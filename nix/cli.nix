# Written by AI on 2026.11.01 by model gpt-6.1-sol.
{ lib, buildGoModule }:

buildGoModule {
  pname = "agent-keyring";
  version = "0.3.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../go.mod
      ../go.sum
      ../cmd/agent-keyring
      ../internal
      ../gen/go
      ../AgentSkill/agent-keyring
      ../BrowserExtension
    ];
  };
  vendorHash = "sha256-510qdC6JRC9BpamW8fYW0Ad3if0czT962FQYbaZEjVc=";
  subPackages = [ "cmd/agent-keyring" ];
  env.CGO_ENABLED = "0";
  doCheck = false;

  postInstall = ''
    mkdir -p "$out/share/agent-keyring/skills"
    cp -R AgentSkill/agent-keyring "$out/share/agent-keyring/skills/agent-keyring"
    cp -R BrowserExtension "$out/share/agent-keyring/BrowserExtension"
  '';

  meta = {
    description = "Request approved logins and fill local browsers through Agent Keyring";
    license = lib.licenses.mit;
    mainProgram = "agent-keyring";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
