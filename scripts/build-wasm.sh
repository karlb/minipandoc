#!/usr/bin/env bash
# Build minipandoc as a WASI preview1 WebAssembly module.
#
# Requirements:
#   - rustup target wasm32-wasip1 installed (`rustup target add wasm32-wasip1`)
#   - clang 20+ on PATH (the `-mllvm -wasm-use-legacy-eh=false` flag that
#     lua-src 550 passes to clang needs LLVM 20 or newer)
#   - wasi-sdk sysroot (version 25 tested). Download from
#     https://github.com/WebAssembly/wasi-sdk/releases and unpack it, then
#     point WASI_SYSROOT at the extracted directory.
#
# Usage:
#   WASI_SYSROOT=/path/to/wasi-sysroot-25.0 scripts/build-wasm.sh [release|debug]
#
# Output: target/wasm32-wasip1/{release,debug}/minipandoc.wasm
set -eu

profile="${1:-release}"
case "$profile" in
  release|debug) ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

: "${WASI_SYSROOT:?WASI_SYSROOT must point at an unpacked wasi-sdk sysroot (e.g. wasi-sysroot-25.0). See https://github.com/WebAssembly/wasi-sdk/releases}"

if [ ! -d "$WASI_SYSROOT/lib/wasm32-wasip1" ]; then
  echo "error: $WASI_SYSROOT/lib/wasm32-wasip1 not found — wrong sysroot?" >&2
  exit 2
fi

CLANG="${CLANG:-clang-20}"
if ! command -v "$CLANG" >/dev/null; then
  echo "error: $CLANG not on PATH; install LLVM 20+ or set CLANG=/path/to/clang" >&2
  exit 2
fi

AR="${LLVM_AR:-llvm-ar-20}"
if ! command -v "$AR" >/dev/null; then
  AR="llvm-ar"
fi

export CC_wasm32_wasip1="$CLANG"
export AR_wasm32_wasip1="$AR"
export CFLAGS_wasm32_wasip1="--sysroot=$WASI_SYSROOT"
export RUSTFLAGS="${RUSTFLAGS:-} -L $WASI_SYSROOT/lib/wasm32-wasip1"

if [ "$profile" = "release" ]; then
  cargo build --target wasm32-wasip1 --bin minipandoc --release
else
  cargo build --target wasm32-wasip1 --bin minipandoc
fi

out="target/wasm32-wasip1/$profile/minipandoc.wasm"
size=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")
echo "built $out ($size bytes)"
