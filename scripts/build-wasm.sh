#!/usr/bin/env bash
# Build minipandoc as a WASI preview1 WebAssembly module.
#
# Zero-setup path:
#   scripts/build-wasm.sh [release|debug]
#
# The script auto-downloads a pinned wasi-sdk (clang + sysroot + llvm-ar)
# on first run, caches it under $XDG_CACHE_HOME (default ~/.cache) for
# reuse across checkouts, and adds the `wasm32-wasip1` rustup target if
# missing. No system clang or sysroot needed.
#
# Overrides (all optional):
#   WASI_SDK_VERSION   wasi-sdk major version to fetch (default: 26)
#   WASI_SDK_ROOT      cache dir for an unpacked wasi-sdk install
#   WASI_SYSROOT       path to an unpacked wasi-sysroot (skips download)
#   CLANG, LLVM_AR     override the clang/llvm-ar used for C code
#
# Output: target/wasm32-wasip1/{release,debug}/minipandoc.wasm
set -eu

profile="${1:-release}"
case "$profile" in
  release|debug) ;;
  -h|--help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

WASI_SDK_VERSION="${WASI_SDK_VERSION:-26}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
WASI_SDK_ROOT="${WASI_SDK_ROOT:-$CACHE_HOME/minipandoc/wasi-sdk-$WASI_SDK_VERSION}"

# Detect a wasi-sdk asset for the current host.
detect_asset() {
  local os arch uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "$uname_s" in
    Linux)  os=linux ;;
    Darwin) os=macos ;;
    *) echo "error: unsupported host OS '$uname_s' for auto-provisioning; set WASI_SYSROOT manually" >&2; exit 2 ;;
  esac
  case "$uname_m" in
    x86_64|amd64)  arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) echo "error: unsupported host arch '$uname_m' for auto-provisioning; set WASI_SYSROOT manually" >&2; exit 2 ;;
  esac
  echo "wasi-sdk-${WASI_SDK_VERSION}.0-${arch}-${os}"
}

# Auto-provision wasi-sdk if the user hasn't pointed us at one.
if [ -z "${WASI_SYSROOT:-}" ]; then
  if [ ! -d "$WASI_SDK_ROOT/share/wasi-sysroot" ]; then
    asset="$(detect_asset)"
    url="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/${asset}.tar.gz"
    echo "fetching $asset (~110 MB, one-time) from $url"
    mkdir -p "$(dirname "$WASI_SDK_ROOT")"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fL "$url" -o "$tmp/wasi-sdk.tar.gz"
    tar -xzf "$tmp/wasi-sdk.tar.gz" -C "$tmp"
    mv "$tmp/$asset" "$WASI_SDK_ROOT"
    trap - EXIT
    rm -rf "$tmp"
    echo "installed wasi-sdk at $WASI_SDK_ROOT"
  fi
  export WASI_SYSROOT="$WASI_SDK_ROOT/share/wasi-sysroot"
  : "${CLANG:=$WASI_SDK_ROOT/bin/clang}"
  : "${LLVM_AR:=$WASI_SDK_ROOT/bin/llvm-ar}"
fi

if [ ! -d "$WASI_SYSROOT/lib/wasm32-wasip1" ]; then
  echo "error: $WASI_SYSROOT/lib/wasm32-wasip1 not found — wrong sysroot?" >&2
  exit 2
fi

CLANG="${CLANG:-clang-20}"
if ! command -v "$CLANG" >/dev/null 2>&1 && [ ! -x "$CLANG" ]; then
  echo "error: clang not found at '$CLANG'; install LLVM 20+ or let this script provision wasi-sdk (unset WASI_SYSROOT to re-enable auto-download)" >&2
  exit 2
fi

AR="${LLVM_AR:-llvm-ar-20}"
if ! command -v "$AR" >/dev/null 2>&1 && [ ! -x "$AR" ]; then
  AR="llvm-ar"
fi

# Ensure the Rust std library for wasm32-wasip1 is installed.
if command -v rustup >/dev/null 2>&1; then
  if ! rustup target list --installed 2>/dev/null | grep -qx wasm32-wasip1; then
    echo "adding rustup target wasm32-wasip1"
    rustup target add wasm32-wasip1
  fi
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
