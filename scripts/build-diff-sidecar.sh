#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT}/Native/DiffSidecar"
BINARY_NAME="cmux-diff-sidecar"
BUILD_OUTPUT_DIR="${TARGET_BUILD_DIR:-${CRATE_DIR}/target/cmux-diff-sidecar}"
BUILD_WORK_DIR="${TARGET_TEMP_DIR:-${CRATE_DIR}/target/cmux-diff-sidecar-build}"
CARGO_RUNNER="${ROOT}/scripts/run-diff-sidecar-cargo.sh"
TOOLCHAIN="$(awk -F '"' '/^[[:space:]]*channel[[:space:]]*=/{print $2; exit}' "${CRATE_DIR}/rust-toolchain.toml")"

# shellcheck source=scripts/build-phase-caller-path.sh
. "${ROOT}/scripts/build-phase-caller-path.sh"
# Xcode build phases do not inherit a login-shell PATH. Prefer rustup's
# conventional bin directory, then the standard Homebrew prefixes.
export PATH="${CARGO_HOME:-${HOME}/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required to build ${BINARY_NAME}; run ./scripts/setup.sh after installing Rust from https://rustup.rs" >&2
  exit 1
fi

rust_target_for_arch() {
  case "$1" in
    arm64|arm64e) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *)
      echo "error: unsupported Rust macOS arch $1" >&2
      return 1
      ;;
  esac
}

ensure_rust_target() {
  local target="$1"
  if ! rustup target list --toolchain "$TOOLCHAIN" --installed | grep -qx "$target"; then
    rustup target add --toolchain "$TOOLCHAIN" "$target"
  fi
}

requested_archs="${CMUX_DIFF_SIDECAR_ARCHS:-${ARCHS:-}}"
if [[ -z "$requested_archs" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) requested_archs="arm64" ;;
    x86_64) requested_archs="x86_64" ;;
    *)
      echo "error: cannot infer Rust macOS target for host arch $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

mkdir -p "$BUILD_OUTPUT_DIR"
mkdir -p "$BUILD_WORK_DIR"
binaries=()
seen_targets=""
for arch in $requested_archs; do
  target="$(rust_target_for_arch "$arch")"
  case " $seen_targets " in
    *" $target "*) continue ;;
  esac
  seen_targets="$seen_targets $target"
  ensure_rust_target "$target"
  target_dir="${BUILD_WORK_DIR}/${target}"
  # xcodebuild injects the app's MACOSX_DEPLOYMENT_TARGET (14.0) into every
  # script phase. Under Xcode 27 beta, proc-macro dylibs linked at >= 14 are
  # rejected by macOS 27 dyld ("mis-aligned LINKEDIT string pool"), so pin the
  # cargo build to the linker-safe minimum; the assembled binary is restamped
  # to the app minimum below before verification.
  CARGO_TARGET_DIR="$target_dir" \
    MACOSX_DEPLOYMENT_TARGET="${CMUX_DIFF_SIDECAR_BUILD_MIN_MACOS:-11.0}" \
    "$CARGO_RUNNER" build \
      --manifest-path "${CRATE_DIR}/Cargo.toml" \
      --bin "$BINARY_NAME" \
      --release \
      --locked \
      --target "$target" \
      --no-default-features
  source_binary="${target_dir}/${target}/release/${BINARY_NAME}"
  [[ -x "$source_binary" ]] || { echo "error: missing ${source_binary}" >&2; exit 1; }
  binaries+=("$source_binary")
done

output_binary="${BUILD_OUTPUT_DIR}/${BINARY_NAME}"
if [[ "${#binaries[@]}" -eq 1 ]]; then
  rsync -a "${binaries[0]}" "$output_binary"
else
  lipo -create -output "$output_binary" "${binaries[@]}"
fi
chmod +x "$output_binary"

# Xcode 27 beta's ld emits dylib LINKEDIT that macOS 27 dyld rejects as
# "mis-aligned LINKEDIT string pool" whenever MACOSX_DEPLOYMENT_TARGET >= 14,
# which breaks the in-phase proc-macro builds. Cargo therefore builds with
# rustc's own deployment target; restamp the assembled binary to the app's
# minimum macOS afterwards. vtool only rewrites LC_BUILD_VERSION.
restamp_minos="${CMUX_DIFF_SIDECAR_MIN_MACOS:-14.0}"
if command -v vtool >/dev/null 2>&1; then
  for arch in $requested_archs; do
    current_minos="$(otool -arch "$arch" -l "$output_binary" | awk '/LC_BUILD_VERSION/{f=1; next} f && /minos /{print $2; exit}')"
    if [[ "$current_minos" != "$restamp_minos" ]]; then
      vtool -arch "$arch" -set-build-version macos "$restamp_minos" "$restamp_minos" -replace \
        -output "$output_binary.restamped" "$output_binary"
      mv "$output_binary.restamped" "$output_binary"
    fi
  done
fi
"${ROOT}/scripts/verify-diff-sidecar-artifact.sh" "$output_binary" --archs "$requested_archs"

if [[ -z "${TARGET_BUILD_DIR:-}" ]]; then
  echo "built ${output_binary}"
  exit 0
fi

destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
destination="${destination_dir}/${BINARY_NAME}"
mkdir -p "$destination_dir"
rsync -a "$output_binary" "$destination"
chmod +x "$destination"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$destination" >/dev/null
fi

# Xcode's dependency-analysis output is keyed by the normal architecture and
# deployment-target settings. The Xcode phase pins the script overrides to
# those same build settings before invoking this script. The stamp is
# intentionally optional so direct script callers retain override support.
if [[ -n "${CMUX_DIFF_SIDECAR_STAMP:-}" ]]; then
  stamp_tmp="$(mktemp "${CMUX_DIFF_SIDECAR_STAMP}.tmp.XXXXXX")"
  cleanup_stamp_tmp() {
    [[ -e "$stamp_tmp" ]] && rm -f "$stamp_tmp"
  }
  trap cleanup_stamp_tmp EXIT
  {
    printf 'requested_archs=%s\n' "$requested_archs"
    printf 'min_macos=%s\n' "${CMUX_DIFF_SIDECAR_MIN_MACOS:-14.0}"
    shasum -a 256 "$destination"
  } > "$stamp_tmp"
  mv -f "$stamp_tmp" "$CMUX_DIFF_SIDECAR_STAMP"
  trap - EXIT
fi
