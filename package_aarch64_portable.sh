# package_aarch64_portable.sh
#!/usr/bin/env bash
set -euo pipefail

# Package an out-of-the-box aarch64 Wine tarball by:
#  - cross-building Box64 (ARM64)
#  - extracting the provided x86_64 WoW64 Wine build
#  - collecting x86_64 runtime libraries from the 64-bit bootstrap
#  - generating ARM64 wrapper scripts that run Wine under Box64

if [ $# -ne 1 ]; then
  echo "Usage: $0 <wine-amd64-wow64.tar.xz>" >&2
  exit 1
fi

INPUT_WOW64_TAR="$(readlink -f "$1")"
if ! echo "$INPUT_WOW64_TAR" | grep -q 'amd64-wow64.*\.tar\.xz$'; then
  echo "The input must be a *-amd64-wow64.tar.xz built by build_wine.sh" >&2
  exit 1
fi

# Where bootstraps are (from your workflows & scripts)
BOOTSTRAP_X64=${BOOTSTRAP_X64:-/opt/chroots/bionic64_chroot}

if [ ! -d "$BOOTSTRAP_X64" ]; then
  echo "Missing x64 bootstrap at $BOOTSTRAP_X64 (did you untar bootstraps.tar.xz?)" >&2
  exit 1
fi

work_root="$(mktemp -d)"
stage="$work_root/stage"
mkdir -p "$stage"

# 1) Extract Wine (x86_64 WoW64) into the stage under 'wine64'
echo "==> Extracting Wine WoW64 build"
mkdir -p "$stage/wine64"
tar -C "$stage" -xf "$INPUT_WOW64_TAR"
# The tar contains a folder like wine-<ver>-amd64-wow64
wine_dir="$(find "$stage" -maxdepth 1 -type d -name 'wine-*amd64-wow64' | head -n1)"
[ -n "$wine_dir" ]
# Normalize path to $stage/wine64
rsync -a --delete "$wine_dir"/ "$stage/wine64/"
rm -rf "$wine_dir"

# 2) Cross-build Box64 for aarch64 and stage it
echo "==> Building Box64 (aarch64)"
src="$work_root/src"
mkdir -p "$src"
git clone --depth 1 https://github.com/ptitSeb/box64.git "$src/box64"
mkdir -p "$src/box64/build"
pushd "$src/box64/build" >/dev/null
cmake .. \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DARM_DYNAREC=ON \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
  -DCMAKE_INSTALL_PREFIX="$stage/runtime/box64"
make -j"$(nproc)"
make install
popd >/dev/null
install -m 0755 "$stage/runtime/box64/bin/box64" "$stage/runtime/box64/box64"
rm -rf "$stage/runtime/box64/bin"

# 3) Collect x86_64 runtime libraries from the 64-bit bootstrap.
echo "==> Collecting x86_64 runtime libraries from bootstrap"
x64root="$BOOTSTRAP_X64"
lib_out="$stage/runtime/x86_64/lib"
mkdir -p "$lib_out"

# List of binary targets to resolve (ELF x86_64):
targets=(
  "$stage/wine64/bin/wine64"
  "$stage/wine64/bin/wineserver"
)

# Add key wine unix libs, which pull most deps at runtime
while IFS= read -r so; do
  targets+=("$so")
done < <(find "$stage/wine64/lib" -type f -name '*.so' -print)

mapfile -t search_dirs < <(printf "%s\n" \
  "$x64root/lib/x86_64-linux-gnu" \
  "$x64root/usr/lib/x86_64-linux-gnu" \
  "$x64root/lib64" \
  "$x64root/usr/lib64" \
  "$x64root/usr/local/lib/x86_64-linux-gnu" \
  "$x64root/usr/local/lib64" | awk '!x[$0]++')

declare -A seen
found_so_paths=()

find_so() {
  local name="$1"
  for d in "${search_dirs[@]}"; do
    [ -d "$d" ] || continue
    local p="$d/$name"
    if [ -e "$p" ]; then
      echo "$p"
      return 0
    fi
    # Also try glob for versioned names if name is a SONAME like libfoo.so
    if [[ "$name" =~ \.so$ ]]; then
      local g
      g="$(ls -1 "$d/$name"* 2>/dev/null | head -n1 || true)"
      if [ -n "$g" ]; then
        echo "$g"
        return 0
      fi
    fi
  done
  return 1
}

needed_from_file() {
  # Print NEEDED entries using readelf (works on host for x86_64 ELF)
  readelf -d "$1" 2>/dev/null | awk '/NEEDED/ {gsub(/\[|\]/,"",$5); print $5}'
}

queue=("${targets[@]}")

while [ "${#queue[@]}" -gt 0 ]; do
  f="${queue[0]}"; queue=("${queue[@]:1}")
  if [ ! -f "$f" ]; then continue; fi
  # Skip non-ELF
  if ! file -b "$f" | grep -q 'ELF 64-bit.*x86-64'; then continue; fi
  # Read NEEDED
  while IFS= read -r need; do
    [ -n "$need" ] || continue
    if [ -n "${seen[$need]+yes}" ]; then continue; fi
    seen[$need]=1
    if p="$(find_so "$need")"; then
      found_so_paths+=("$p")
      # Recurse: also parse that .so for its own NEEDEDs
      queue+=("$p")
    else
      echo "WARN: could not find $need in bootstrap; continuing" >&2
    fi
  done < <(needed_from_file "$f")
done

# Always include the x86_64 dynamic loader
ld64_candidates=(
  "$x64root/lib64/ld-linux-x86-64.so.2"
  "$x64root/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
  "$x64root/lib/ld-linux-x86-64.so.2"
)
for c in "${ld64_candidates[@]}"; do
  if [ -e "$c" ]; then
    found_so_paths+=("$c")
    break
  fi
done

# Copy unique libs
echo "==> Copying $(printf "%s\n" "${found_so_paths[@]}" | sort -u | wc -l) libraries"
printf "%s\n" "${found_so_paths[@]}" | sort -u | while IFS= read -r so; do
  rel="$(basename "$so")"
  install -Dm0755 "$so" "$lib_out/$rel"
done

# 4) Create ARM64 wrapper scripts (bin/)
echo "==> Creating aarch64 wrapper scripts"
bin="$stage/bin"
mkdir -p "$bin"

cat > "$bin/_env.sh" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
# Resolve root of the portable bundle
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )/.."

export BOX64_PATH="${BOX64_PATH:-$ROOT/wine64/bin:$ROOT/wine64/lib:$ROOT/wine64/lib64:$ROOT/wine64/lib/wine/x86_64-unix}"
export BOX64_LD_LIBRARY_PATH="${BOX64_LD_LIBRARY_PATH:-$ROOT/runtime/x86_64/lib:$ROOT/wine64/lib:$ROOT/wine64/lib64}"
export BOX64="${BOX64:-$ROOT/runtime/box64/box64}"

# Make sure dynamic loader is reachable first in search path
export BOX64_LD_LIBRARY_PATH="$ROOT/runtime/x86_64/lib:$BOX64_LD_LIBRARY_PATH"

# Quiet first-run Gecko/GStreamer prompts unless user overrides
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mshtml=,winegstreamer=}"
EOSH
chmod +x "$bin/_env.sh"

make_wrap() {
  local name="$1" target="$2"
  cat > "$bin/$name" <<'EOSH2'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_env.sh"
EOSH2
  cat >> "$bin/$name" <<EOF
exec "\$BOX64" "\$ROOT/wine64/bin/$target" "\$@"
EOF
  chmod +x "$bin/$name"
}

make_wrap "wine64" "wine64"
make_wrap "wineserver" "wineserver"
make_wrap "winecfg" "winecfg"
# 'wine' should point to wine64 in WoW64 mode
make_wrap "wine" "wine64"

# 5) License/README note for the portable aarch64 build
cat > "$stage/README.aarch64.md" <<'EORD'
# Wine aarch64 portable (box64+wow64)

This build runs on aarch64 (ARM64) Linux without extra packages:
- Uses Box64 to execute the bundled x86_64 WoW64 Wine.
- Bundles all required x86_64 runtime libraries and the x86_64 dynamic loader.

## Usage

```bash
tar -xf wine-<ver>-aarch64-portable.tar.xz
cd wine-<ver>-aarch64-portable
./bin/winecfg
# or:
./bin/wine your_app.exe
