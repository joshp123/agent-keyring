#!/bin/sh
# Written by AI on 2026.10.31 by model gpt-6.1-sol.
set -eu
cd "$(dirname "$0")/.."
exec nix shell \
 'github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#protobuf' \
 'github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#protoc-gen-go' \
 -c protoc -I proto -I . --go_out=. --go_opt=paths=source_relative internal/clientstate/state.proto
