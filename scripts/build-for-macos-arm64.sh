#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

ensure_command_line_tools() {
  if ! command -v xcode-select >/dev/null 2>&1; then
    echo "Could not find xcode-select; install Xcode Command Line Tools and try again." >&2
    exit 1
  fi

  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are not installed. Run 'xcode-select --install' and re-run this script." >&2
    exit 1
  fi

  local sdk_path=""
  if command -v xcrun >/dev/null 2>&1; then
    sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  fi

  if [[ -z "$sdk_path" || ! -d "$sdk_path" ]]; then
    echo "Could not determine the macOS SDK path. Install the Xcode Command Line Tools (xcode-select --install) or a full Xcode installation and re-run this script." >&2
    exit 1
  fi

  local -a clang_candidates=()
  if command -v clang++ >/dev/null 2>&1; then
    clang_candidates+=("system::$(command -v clang++)")
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_llvm_prefix
    brew_llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
    if [[ -n "$brew_llvm_prefix" ]]; then
      clang_candidates+=("brew::${brew_llvm_prefix}/bin/clang++")
    else
      clang_candidates+=("brew-install::llvm")
    fi
  fi

  local selected_clang=""
  local selected_source=""
  local last_error=""
  local last_output=""

  local entry
  for entry in "${clang_candidates[@]}"; do
    local source="${entry%%::*}"
    local candidate="${entry#*::}"
    local llvm_prefix=""

    if [[ "$source" == "brew-install" ]]; then
      echo "Installing Homebrew llvm to provide libc++ headers..." >&2
      brew install llvm
      llvm_prefix="$(brew --prefix llvm)"
      candidate="${llvm_prefix}/bin/clang++"
      source="brew"
    elif [[ "$source" == "brew" ]]; then
      llvm_prefix="${candidate%/bin/clang++}"
    fi

    if [[ ! -x "$candidate" ]]; then
      continue
    fi

    local tmp_dir
    if ! tmp_dir=$(mktemp -d 2>/dev/null); then
      tmp_dir=$(mktemp -d -t plotjuggler)
    fi
    local compile_log="$tmp_dir/compile.log"

    if printf '#include <type_traits>\nint main() { return 0; }\n' | "$candidate" -xc++ - -std=c++17 -isysroot "$sdk_path" -c -o "$tmp_dir/test.o" 2>"$compile_log"; then
      selected_clang="$candidate"
      selected_source="$source"
      rm -rf "$tmp_dir"
      break
    else
      last_error="Failed to compile with $candidate"
      last_output="$(cat "$compile_log")"
      rm -rf "$tmp_dir"
    fi
  done

  if [[ -z "$selected_clang" ]]; then
    echo "Unable to compile a small C++17 test program with the available toolchains." >&2
    if [[ -n "$last_error" ]]; then
      echo "$last_error" >&2
    fi
    if [[ -n "$last_output" ]]; then
      echo "Compiler output:" >&2
      while IFS= read -r line; do
        echo "  $line" >&2
      done <<<"$last_output"
    fi
    cat >&2 <<'EOF'
Please reinstall the Xcode Command Line Tools:

  sudo rm -rf /Library/Developer/CommandLineTools
  xcode-select --install
  sudo xcode-select --switch /Library/Developer/CommandLineTools

Alternatively install a full Xcode and switch to it:

  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

After fixing the toolchain rerun this script.
EOF
    exit 1
  fi

  export SDKROOT="$sdk_path"
  export CMAKE_OSX_SYSROOT="$sdk_path"

  local clang_dir
  clang_dir="$(dirname "$selected_clang")"
  local cc_candidate="$clang_dir/clang"
  if [[ -x "$cc_candidate" ]]; then
    export CC="$cc_candidate"
  fi
  export CXX="$selected_clang"

  if [[ "$selected_source" == "brew" ]]; then
    local llvm_prefix_final="${selected_clang%/bin/clang++}"
    export PATH="${llvm_prefix_final}/bin:${PATH}"
    export LDFLAGS="${LDFLAGS:-} -L${llvm_prefix_final}/lib"
    export CPPFLAGS="${CPPFLAGS:-} -I${llvm_prefix_final}/include"
  fi
}


if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Please install Homebrew before running this script." >&2
  exit 1
fi

ensure_command_line_tools

NEEDS_QT_RELINK=0
if brew list --versions qt >/dev/null 2>&1; then
  NEEDS_QT_RELINK=1
fi

brew install cmake qt@5 protobuf mosquitto zeromq zstd git-lfs

# If a newer version of qt is installed, you may need to temporarily link to qt5
brew link qt@5 --overwrite --force

# Add CMake into your env-vars to be detected by cmake
QT_HOME=$(brew --prefix qt@5)

CPPFLAGS="${CPPFLAGS:-}"
CPPFLAGS+=" -I $QT_HOME/include"
export CPPFLAGS

PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
if [[ -n $PKG_CONFIG_PATH ]]; then
  PKG_CONFIG_PATH+=":"
fi
PKG_CONFIG_PATH+="$QT_HOME/lib/pkgconfig"
export PKG_CONFIG_PATH

LDFLAGS="${LDFLAGS:-}"
LDFLAGS+=" -L$QT_HOME/lib"
export LDFLAGS

mkdir -p build

CMAKE_SYSROOT_ARGS=()
if [[ -n "${SDKROOT:-}" ]]; then
  CMAKE_SYSROOT_ARGS+=(-DCMAKE_OSX_SYSROOT="${SDKROOT}")
fi

cmake -S .. -B build/PlotJuggler -DCMAKE_INSTALL_PREFIX=install -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "${CMAKE_SYSROOT_ARGS[@]}"
cmake --build build/PlotJuggler --config RelWithDebInfo --target install

INSTALL_ROOT="${PWD}/install"
APP_NAME="PlotJuggler.app"
APP_DIR="${INSTALL_ROOT}/${APP_NAME}"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cat > "${APP_DIR}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.plotjuggler.PlotJuggler</string>
  <key>CFBundleName</key>
  <string>PlotJuggler</string>
  <key>CFBundleDisplayName</key>
  <string>PlotJuggler</string>
  <key>CFBundleExecutable</key>
  <string>PlotJuggler</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

cat > "${MACOS_DIR}/PlotJuggler" <<'EOF'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
LIB_DIR="$INSTALL_ROOT/lib"
PLUGIN_DIR_CANDIDATES=("$INSTALL_ROOT/plugins" "$INSTALL_ROOT/lib/qt5/plugins")
if [[ -d "$LIB_DIR" ]]; then
  export DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi
for candidate in "${PLUGIN_DIR_CANDIDATES[@]}"; do
  if [[ -d "$candidate" ]]; then
    export QT_PLUGIN_PATH="$candidate${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
    break
  fi
done
PLOTJUGGLER_BIN="$INSTALL_ROOT/bin/plotjuggler"
if [[ ! -x "$PLOTJUGGLER_BIN" ]]; then
  echo "Error: expected PlotJuggler binary at $PLOTJUGGLER_BIN" >&2
  exit 1
fi
exec "$PLOTJUGGLER_BIN" "$@"
EOF
chmod +x "${MACOS_DIR}/PlotJuggler"

USER_APPLICATIONS="${HOME}/Applications"
if [[ ! -e "${USER_APPLICATIONS}" ]]; then
  mkdir -p "${USER_APPLICATIONS}"
fi

if [[ -d "${USER_APPLICATIONS}" ]]; then
  if ln -sfn "${APP_DIR}" "${USER_APPLICATIONS}/${APP_NAME}"; then
    echo "Linked ${APP_NAME} into ${USER_APPLICATIONS}"
  else
    echo "Warning: Failed to link ${APP_NAME} into ${USER_APPLICATIONS}" >&2
  fi
else
  echo "Warning: ${USER_APPLICATIONS} exists but is not a directory; skipping symlink." >&2
fi

# Run once you are done building to restore the original linking
if [[ "${NEEDS_QT_RELINK}" -eq 1 ]]; then
  brew link qt --overwrite
else
  echo "Skipping 'brew link qt --overwrite' because Homebrew formula 'qt' is not installed."
  brew unlink qt@5 >/dev/null 2>&1 || true
fi

