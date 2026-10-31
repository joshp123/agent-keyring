{ pkgs, ... }:
{
  packages = with pkgs; [ go protobuf protoc-gen-go protoc-gen-swift ];
}
