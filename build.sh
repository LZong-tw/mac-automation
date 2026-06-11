#!/bin/bash
# 編譯 src/*.swift → bin/(編譯產物不進 git)
set -euo pipefail
cd "$(dirname "$0")"

command -v swiftc >/dev/null || { echo "swiftc not found — install Xcode Command Line Tools"; exit 1; }

build() {
    local src="$1" out="$2"; shift 2
    echo "swiftc $src → bin/$out"
    swiftc -O -o "bin/$out" "src/$src" "$@"
}

build capslock-monitor.swift       capslock-monitor       -framework AppKit -framework CoreGraphics
build input-tap.swift              input-tap              -framework AppKit -framework Carbon -framework CoreGraphics
build input-source-restorer.swift  input-source-restorer  -framework AppKit -framework Carbon

echo "done."
