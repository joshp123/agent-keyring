#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Match the pinned nixpkgs input in devenv.yaml.
exec nix shell \
  'github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#protobuf' \
  'github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#protoc-gen-go' \
  'github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#protoc-gen-swift' \
  -c sh -ec '
    protoc -I proto --go_out=gen/go --go_opt=paths=source_relative --swift_out=AgentKeyringPackage/Sources/AgentKeyringProtocol --swift_opt=Visibility=Public proto/agentkeyring/v2/*.proto
    protoc -I proto -I . --go_out=. --go_opt=module=github.com/opentrawl/agent-keyring \
      internal/clientstate/state.proto internal/browserbridge/wire.proto
  '
