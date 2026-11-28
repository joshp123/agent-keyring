{ pkgs, ... }:
{
  packages = with pkgs; [ go golangci-lint protobuf protoc-gen-go protoc-gen-swift python3 ]
    ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.swiftlint ];

  enterShell = ''
    if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] &&
       [ "$(git config --local --get core.hooksPath)" != .githooks ]; then
      git config core.hooksPath .githooks
    fi
  '';
}
