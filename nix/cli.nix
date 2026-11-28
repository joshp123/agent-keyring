# Written by AI on 2026.11.01 by model gpt-6.1-sol.
{ lib, buildGoModule, build ? "0" }:

# version: the VERSION file. build: the commit's time, from the flake. Together
# the same pair as the Mac and iPhone apps of this commit (script/version.sh).
buildGoModule rec {
  pname = "agent-keyring";
  version = lib.removeSuffix "\n" (builtins.readFile ../VERSION);
  ldflags = [ "-X 'main.stamp=${version} (${build})'" ];

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../go.mod
      ../go.sum
      ../cmd/agent-keyring
      ../internal
      ../gen/go
      ../AgentSkill/skill.go
      ../AgentSkill/agent-keyring
      ../BrowserExtension
    ];
  };
  vendorHash = "sha256-7yPVHqjOhQdxTRJV8uLl7XFAy64Q/BHHZT7wlmjSm+A=";
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
