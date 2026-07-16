#!/bin/bash
# Regenerate Swift protobuf types from the Unleashed firmware .proto files.
# Run this if you bump the firmware / RPC protocol.
set -euo pipefail
cd "$(dirname "$0")/.."
PATH="/opt/homebrew/bin:$PATH"

FW="../unleashed-firmware"
PROTO="$FW/assets/protobuf"
NANOPB="$FW/lib/nanopb/generator/proto"
OUT="Sources/Proto"

protoc \
  --proto_path="$PROTO" --proto_path="$NANOPB" \
  --swift_opt=Visibility=Public --swift_out="$OUT" \
  "$PROTO"/flipper.proto "$PROTO"/storage.proto "$PROTO"/system.proto \
  "$PROTO"/application.proto "$PROTO"/gui.proto "$PROTO"/gpio.proto \
  "$PROTO"/property.proto "$PROTO"/desktop.proto

echo "Regenerated Swift protobuf in $OUT"
