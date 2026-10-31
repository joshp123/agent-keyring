<!-- Written by AI on 2026.10.31 by model gpt-6.1-terra. -->
# Protocol generation

Run `./script/generate_protos.sh` from a checkout with Nix installed. Commit the generated Go and Swift files with changes to the protocol. The script pins nixpkgs to the same revision as `devenv.yaml`: protoc 36.2, protoc-gen-go 1.36.12, and protoc-gen-swift 1.38.1. SwiftProtobuf is pinned to 1.38.1 in the Swift package; the Go protobuf runtime is pinned in `go.mod`.

Go imports `github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1`. Swift clients depend on the `AgentKeyringProtocol` product and import the module of the same name. These are message types; RPC transport implementation is separate.
