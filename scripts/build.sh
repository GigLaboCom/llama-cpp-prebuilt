#!/usr/bin/env bash
# Build the pinned llama.cpp exactly as wipemark-app's
# `crates/wipemark-llama-sys/build.rs` (feature `native`) builds it, and
# pack it as one release archive for one target.
#
# Used by .github/workflows/release.yml and ci.yml, and by hand:
#
#   scripts/build.sh                       # the host's target, PIN's tag
#   LLAMA_SRC=/path/to/llama.cpp scripts/build.sh   # fetch from a local clone
#
# Environment (all optional):
#   TARGET_TRIPLE  rust target triple; detected from the host when unset
#   LLAMA_SRC      a local git checkout that has LLAMA_COMMIT (no network)
#   WORK_DIR       scratch: source, build trees, install prefix (default work/)
#   DIST_DIR       where the archive and its .sha256 land (default dist/)
#   JOBS           build parallelism (default: the number of CPUs)
#
# What it does, in wipemark-llama-sys's order:
#   0. fetch llama.cpp at LLAMA_COMMIT (shallow) and verify it — HEAD, the
#      upstream tag, the ggml commit (scripts/sync-ggml.last), the ggml and
#      llama versions — the way `verify_pin` does, and more;
#   1. stage 1: ONE shared ggml from llama.cpp/ggml, GGML_BACKEND_DL=ON,
#      backends as run-time-loaded modules (CPU variants on x86_64, Vulkan
#      on Linux/Windows, Metal on macOS);
#   2. stage 2: libllama against that ggml (LLAMA_USE_SYSTEM_GGML=ON), no
#      tools/server/common/examples/tests/app;
#   3. bindings.rs with the same bindgen invocation (bindgen/);
#   4. the archive: include/ lib/ [bin/] backends/ bindings.rs wrapper.h
#      LICENSE-llama.cpp PROVENANCE.txt.
#
# Deliberate differences from wipemark-llama-sys, all listed in README.md
# ("What differs from a wipemark-llama-sys build"): no GGML_BACKEND_DIR is
# compiled in, the rpath is $ORIGIN / @loader_path instead of an absolute
# build path, and the MSVC flags are CMake's Release defaults.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../PIN
. "$here/PIN"

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ---- target ---------------------------------------------------------------
detect_target() {
  local s m
  s="$(uname -s)"; m="$(uname -m)"
  case "$s/$m" in
    Linux/x86_64) echo x86_64-unknown-linux-gnu ;;
    Linux/aarch64 | Linux/arm64) echo aarch64-unknown-linux-gnu ;;
    Darwin/arm64) echo aarch64-apple-darwin ;;
    MINGW*/x86_64 | MSYS*/x86_64 | CYGWIN*/x86_64) echo x86_64-pc-windows-msvc ;;
    *) die "no target for $s/$m; set TARGET_TRIPLE" ;;
  esac
}
target="${TARGET_TRIPLE:-$(detect_target)}"

# What wipemark-llama-sys gets from the `cmake` crate (0.1.58) and the `cc`
# crate (1.4.5) on each target: CMAKE_{C,CXX,ASM}_FLAGS are cc's default
# flags at opt-level 0 with -O/-g removed and warnings off (`-w`), and the
# optimisation comes from CMAKE_BUILD_TYPE=Release (-O3 -DNDEBUG).
# GGML_CPU_ALL_VARIANTS is ON only on x86 (`cpu_all_variants()`); GGML_VULKAN
# is what wipemark's CI exports for a Linux build and what D187 ships on
# Linux and Windows; Metal is ggml's default on Apple.
case "$target" in
  x86_64-unknown-linux-gnu)
    os=linux;   cc_flags="-ffunction-sections -fdata-sections -fPIC -m64 -w"
    all_variants=ON;  vulkan=ON ;;
  aarch64-unknown-linux-gnu)
    os=linux;   cc_flags="-ffunction-sections -fdata-sections -fPIC -w"
    all_variants=OFF; vulkan=ON ;;
  aarch64-apple-darwin)
    os=macos;   cc_flags="-ffunction-sections -fdata-sections -fPIC --target=arm64-apple-macosx -mmacosx-version-min=11.0 -w"
    all_variants=OFF; vulkan=OFF ;;
  x86_64-pc-windows-msvc)
    # See README: the cmake crate would replace CMAKE_<LANG>_FLAGS_RELEASE
    # with "-nologo -MD -Brepro" under the Visual Studio generator, which
    # drops /O2, /DNDEBUG and /EHsc. CMake's own Release defaults are kept.
    os=windows; cc_flags=""
    all_variants=ON;  vulkan=ON ;;
  *) die "unsupported target $target" ;;
esac

work="${WORK_DIR:-$here/work}"
dist="${DIST_DIR:-$here/dist}"
if [ -z "${JOBS:-}" ]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")"
fi

# A path as the native tools want it (C:/... on Windows, unchanged elsewhere).
native() { if [ "$os" = windows ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
# "<hash>  <file>" everywhere: Git Bash's sha256sum marks binary mode with
# "<hash> *<file>", which other checkers and the provenance grep reject.
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi \
    | sed -E 's/^([0-9a-f]{64}) [ *]/\1  /'
}

name="llama-cpp-${LLAMA_TAG}-${target}"
src="$work/llama.cpp"
prefix="$work/prefix-$target"
b1="$work/build-ggml-$target"
b2="$work/build-llama-$target"
stage="$dist/$name"
started="$(date -u +%s)"

mkdir -p "$work" "$dist"

# ---- 0. the source, verified ----------------------------------------------
log "llama.cpp $LLAMA_TAG @ $LLAMA_COMMIT"
source_repo="$LLAMA_REPO"
if [ -n "${LLAMA_SRC:-}" ]; then
  git -C "$LLAMA_SRC" cat-file -e "$LLAMA_COMMIT^{commit}" 2>/dev/null \
    || die "LLAMA_SRC=$LLAMA_SRC is not a git checkout that has $LLAMA_COMMIT"
  source_repo="$(cd "$LLAMA_SRC" && pwd)"
fi
if [ -e "$src/.git" ] && [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" = "$LLAMA_COMMIT" ]; then
  echo "ok: already @ $LLAMA_COMMIT"
else
  rm -rf "$src"; mkdir -p "$src"
  git -C "$src" init -q
  git -C "$src" remote add origin "$source_repo"
  git -C "$src" fetch -q --depth 1 origin "$LLAMA_COMMIT"
  git -C "$src" checkout -q FETCH_HEAD
fi
head="$(git -C "$src" rev-parse HEAD)"
[ "$head" = "$LLAMA_COMMIT" ] || die "llama.cpp is at $head, pinned @ $LLAMA_COMMIT"

# The tag names the commit upstream (a tag can move; a commit cannot).
if [ -z "${LLAMA_SRC:-}" ]; then
  tagged="$(git ls-remote "$LLAMA_REPO" "refs/tags/$LLAMA_TAG" | awk '{print $1}')"
  [ "$tagged" = "$LLAMA_COMMIT" ] || die "upstream tag $LLAMA_TAG is ${tagged:-absent}, PIN says $LLAMA_COMMIT"
fi
ggml_last="$(tr -d '[:space:]' < "$src/scripts/sync-ggml.last")"
[ "$ggml_last" = "$GGML_COMMIT" ] || die "llama.cpp vendors ggml $ggml_last, PIN says $GGML_COMMIT"
ver() { sed -n "s/^set($1_VERSION_$2 \([0-9]*\))/\1/p" "$3" | head -1; }
ggml_v="$(ver GGML MAJOR "$src/ggml/CMakeLists.txt").$(ver GGML MINOR "$src/ggml/CMakeLists.txt").$(ver GGML PATCH "$src/ggml/CMakeLists.txt")"
[ "$ggml_v" = "$GGML_VERSION" ] || die "ggml version is $ggml_v, PIN says $GGML_VERSION"
llama_v="$(ver LLAMA MAJOR "$src/CMakeLists.txt").$(ver LLAMA MINOR "$src/CMakeLists.txt").$(ver LLAMA PATCH "$src/CMakeLists.txt")"
[ "$llama_v" = "$LLAMA_VERSION" ] || die "llama version is $llama_v, PIN says $LLAMA_VERSION"
echo "ok: HEAD, tag, ggml $GGML_COMMIT ($ggml_v), llama $llama_v"

# Quirk 1 of wipemark-llama-sys (`ensure_ggml_pc_in`): ggml configured as
# the top-level project wants ggml.pc.in, which the llama.cpp subtree omits.
# Verbatim from ggml-org/ggml at GGML_COMMIT.
[ -e "$src/ggml/ggml.pc.in" ] || cp "$here/scripts/ggml.pc.in" "$src/ggml/ggml.pc.in"

# ---- common CMake arguments -----------------------------------------------
common=(-DCMAKE_BUILD_TYPE=Release
        "-DCMAKE_INSTALL_PREFIX=$(native "$prefix")"
        -DCMAKE_INSTALL_LIBDIR=lib
        -DCMAKE_INSTALL_BINDIR=bin
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON)
case "$os" in
  linux)
    # $ORIGIN for lib/ (libllama -> libggml -> libggml-base), $ORIGIN/../lib
    # for backends/ (each backend -> libggml-base).
    common+=('-DCMAKE_INSTALL_RPATH=$ORIGIN;$ORIGIN/../lib'
             "-DCMAKE_C_COMPILER=$(command -v cc)"
             "-DCMAKE_CXX_COMPILER=$(command -v c++)"
             "-DCMAKE_ASM_COMPILER=$(command -v cc)") ;;
  macos)
    common+=('-DCMAKE_INSTALL_RPATH=@loader_path;@loader_path/../lib'
             -DCMAKE_INSTALL_NAME_DIR=@rpath
             -DCMAKE_OSX_ARCHITECTURES=arm64
             "-DCMAKE_C_COMPILER=$(command -v cc)"
             "-DCMAKE_CXX_COMPILER=$(command -v c++)"
             "-DCMAKE_ASM_COMPILER=$(command -v cc)") ;;
  windows)
    # The cmake crate's choice for an MSVC target: a Visual Studio
    # generator, 64-bit host tools, x64 platform.
    common+=(-A x64 -T host=x64) ;;
esac

# ---- 1. one shared ggml -----------------------------------------------------
stage1=(cmake -S "$(native "$src/ggml")" -B "$(native "$b1")" "${common[@]}")
[ "$os" = windows ] || stage1+=("-DCMAKE_C_FLAGS=$cc_flags" "-DCMAKE_CXX_FLAGS=$cc_flags" "-DCMAKE_ASM_FLAGS=$cc_flags")
stage1+=(-DBUILD_SHARED_LIBS=ON
         -DGGML_BACKEND_DL=ON
         "-DGGML_CPU_ALL_VARIANTS=$all_variants"
         -DGGML_NATIVE=OFF
         -DGGML_BUILD_TESTS=OFF
         -DGGML_BUILD_EXAMPLES=OFF)
[ "$vulkan" = ON ] && stage1+=(-DGGML_VULKAN=ON)

# REUSE_BUILD=1 keeps an existing prefix and skips both stages: for
# iterating on the packing by hand, never in CI.
reuse=no
[ "${REUSE_BUILD:-}" = 1 ] && [ -e "$prefix/include/llama.h" ] && reuse=yes

log "stage 1: shared ggml"
printf '%q ' "${stage1[@]}"; echo
if [ "$reuse" = no ]; then
  rm -rf "$b1" "$b2" "$prefix"
  "${stage1[@]}"
  cmake --build "$(native "$b1")" --config Release --target install --parallel "$JOBS"
fi

# ---- 2. libllama against it -------------------------------------------------
# Quirk 2 (`build_against_system_ggml`): under GGML_BACKEND_DL=ON the
# installed ggml-config.cmake propagates no include dir, so it goes on the
# compile flags.
inc="$(native "$prefix/include")"
stage2=(cmake -S "$(native "$src")" -B "$(native "$b2")" "${common[@]}"
        "-DCMAKE_PREFIX_PATH=$(native "$prefix")")
[ "$os" = windows ] || stage2+=("-DCMAKE_C_FLAGS=-I$inc $cc_flags" "-DCMAKE_CXX_FLAGS=-I$inc $cc_flags" "-DCMAKE_ASM_FLAGS=$cc_flags")
stage2+=(-DGGML_BACKEND_DL=ON
         -DLLAMA_USE_SYSTEM_GGML=ON
         -DLLAMA_BUILD_TESTS=OFF
         -DLLAMA_BUILD_EXAMPLES=OFF
         -DLLAMA_BUILD_SERVER=OFF
         -DLLAMA_BUILD_TOOLS=OFF
         -DLLAMA_BUILD_APP=OFF
         -DLLAMA_BUILD_COMMON=OFF
         -DLLAMA_CURL=OFF
         -DBUILD_SHARED_LIBS=ON)

log "stage 2: libllama"
printf '%q ' "${stage2[@]}"; echo
if [ "$reuse" = yes ]; then
  :
elif [ "$os" = windows ]; then
  # CFLAGS/CXXFLAGS initialise CMAKE_<LANG>_FLAGS *in front of* CMake's
  # MSVC defaults instead of replacing them.
  CFLAGS="-I$inc" CXXFLAGS="-I$inc" "${stage2[@]}"
else
  "${stage2[@]}"
fi
[ "$reuse" = yes ] || cmake --build "$(native "$b2")" --config Release --target install --parallel "$JOBS"

# ---- 3. the archive's tree --------------------------------------------------
log "staging $name"
rm -rf "$stage"
mkdir -p "$stage/include" "$stage/lib" "$stage/backends"
cp "$prefix"/include/*.h "$stage/include/"
case "$os" in
  linux)
    cp -P "$prefix"/lib/libggml.so* "$prefix"/lib/libggml-base.so* "$prefix"/lib/libllama.so* "$stage/lib/"
    cp "$prefix"/bin/libggml-*.so "$stage/backends/" ;;
  macos)
    cp -P "$prefix"/lib/libggml.*dylib "$prefix"/lib/libggml-base.*dylib "$prefix"/lib/libllama.*dylib "$stage/lib/"
    cp "$prefix"/bin/libggml-*.so "$stage/backends/" ;;
  windows)
    mkdir -p "$stage/bin"
    cp "$prefix"/lib/ggml.lib "$prefix"/lib/ggml-base.lib "$prefix"/lib/llama.lib "$stage/lib/"
    cp "$prefix"/bin/ggml.dll "$prefix"/bin/ggml-base.dll "$prefix"/bin/llama.dll "$stage/bin/"
    for f in "$prefix"/bin/ggml-*.dll; do
      [ "$(basename "$f")" = ggml-base.dll ] || cp "$f" "$stage/backends/"
    done ;;
esac
ls "$stage/backends" | grep -q . || die "no backend library was installed"
cp "$src/LICENSE" "$stage/LICENSE-llama.cpp"
cp "$here/bindgen/wrapper/wrapper.h" "$stage/wrapper.h"

log "bindings.rs (bindgen, as wipemark-llama-sys runs it)"
(cd "$here/bindgen" && TARGET="$target" cargo run --locked --release -q -- \
  "$(native "$prefix/include")" "$(native "$src/include")" "$(native "$stage/bindings.rs")")
grep -q 'pub fn llama_backend_init' "$stage/bindings.rs" || die "bindings.rs has no llama_backend_init"

# ---- 4. provenance ------------------------------------------------------------
log "PROVENANCE.txt"
first() { "$@" 2>&1 | head -1 || true; }
# Every cache entry whose name matches the extended regex $1.
cache() { grep -E "^($1):[A-Z]+=" "$2" | sed -E 's/^([^:]+):[A-Z]+=/\1=/' | LC_ALL=C sort || true; }
lockver() { awk -v n="name = \"$1\"" '$0 == n { getline; gsub(/version = |"/, ""); print }' "$here/bindgen/Cargo.lock"; }
compiler() { # lang file
  local f="$2"
  printf '%s %s %s' "$(sed -n "s/^set(CMAKE_$1_COMPILER \"\(.*\)\")/\1/p" "$f")" \
    "$(sed -n "s/^set(CMAKE_$1_COMPILER_ID \"\(.*\)\")/\1/p" "$f")" \
    "$(sed -n "s/^set(CMAKE_$1_COMPILER_VERSION \"\(.*\)\")/\1/p" "$f")"
}
repo_commit="$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
git -C "$here" diff --quiet HEAD 2>/dev/null || repo_commit="$repo_commit-dirty"
{
  echo "repository: https://github.com/GigLaboCom/llama-cpp-prebuilt"
  echo "repository_commit: $repo_commit"
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    echo "workflow_run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID} (attempt ${GITHUB_RUN_ATTEMPT:-1})"
  else
    echo "workflow_run: none (built by hand)"
  fi
  echo "target: $target"
  echo "archive: $name.tar.gz"
  echo "llama.cpp_repository: $LLAMA_REPO"
  echo "llama.cpp_tag: $LLAMA_TAG"
  echo "llama.cpp_commit: $LLAMA_COMMIT"
  echo "llama_version: $LLAMA_VERSION"
  echo "ggml_commit: $GGML_COMMIT"
  echo "ggml_version: $GGML_VERSION"
  echo "pin: $PIN_STRING"
  echo "build_date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "build_seconds: $(( $(date -u +%s) - started ))"
  echo "runner_image: ${ImageOS:-n/a} ${ImageVersion:-}"
  echo "runner_os: $(uname -srm)"
  case "$os" in
    linux) echo "distribution: $(. /etc/os-release && echo "$PRETTY_NAME")"
           echo "glibc: $(first ldd --version)" ;;
    macos) echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
           echo "xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
           echo "macos_sdk: $(xcrun --show-sdk-version)" ;;
    windows) echo "windows: $(cmd //c ver 2>/dev/null | tr -d '\r' | grep -v '^$' | head -1)" ;;
  esac
  echo "cmake: $(first cmake --version)"
  echo "cmake_generator: $(sed -n 's/^CMAKE_GENERATOR:INTERNAL=//p' "$b1/CMakeCache.txt")"
  echo "c_compiler: $(compiler C "$(ls "$b1"/CMakeFiles/*/CMakeCCompiler.cmake | head -1)")"
  echo "cxx_compiler: $(compiler CXX "$(ls "$b1"/CMakeFiles/*/CMakeCXXCompiler.cmake | head -1)")"
  if [ "$vulkan" = ON ]; then
    echo "glslc: $(glslc --version 2>&1 | tr '\n' ' ')"
    echo "vulkan_sdk: ${VULKAN_SDK:-system packages}"
    [ "$os" = linux ] && echo "vulkan_packages: $(dpkg-query -W -f='${Package}=${Version} ' libvulkan-dev glslc spirv-headers 2>/dev/null)"
    echo "vulkan_headers: $(sed -n 's/^Vulkan_VERSION:[A-Z]*=//p;s/^Vulkan_INCLUDE_DIR:[A-Z]*=/include=/p' "$b1/CMakeCache.txt" | tr '\n' ' ')"
  fi
  echo "rustc: $(cd "$here/bindgen" && first rustc --version)"
  echo "rustfmt: $(cd "$here/bindgen" && first rustfmt --version)"
  echo "bindgen: $(lockver bindgen)"
  echo "clang-sys: $(lockver clang-sys)"
  echo "libclang: ${LIBCLANG_PATH:-found by clang-sys} $(first clang --version)"
  echo "bindgen_target: $target"
  echo "bindgen_header: wrapper.h (wipemark-llama-sys wrapper/wrapper.h, byte copy)"
  echo "bindgen_clang_args: -I<prefix>/include -I<llama.cpp>/include"
  echo "bindgen_allowlist: function ggml_backend_.* | function llama_.* | type llama_.* | function gguf_.* | type gguf_.*"
  echo
  echo "## stage 1 (ggml) configure"
  printf '%q ' "${stage1[@]}" | sed "s#$(native "$work")#<work>#g"; echo
  echo
  echo "## stage 2 (llama) configure"
  printf '%q ' "${stage2[@]}" | sed "s#$(native "$work")#<work>#g"; echo
  [ "$os" = windows ] && echo "(stage 2 environment: CFLAGS=-I<prefix>/include CXXFLAGS=-I<prefix>/include)"
  echo
  echo "## stage 1 resolved options (CMakeCache.txt)"
  cache 'GGML_[A-Z0-9_]+' "$b1/CMakeCache.txt"
  cache 'BUILD_SHARED_LIBS' "$b1/CMakeCache.txt"
  cache 'CMAKE_(C|CXX)_FLAGS(_RELEASE)?' "$b1/CMakeCache.txt"
  cache 'CMAKE_OSX_[A-Z_]+' "$b1/CMakeCache.txt"
  echo
  echo "## stage 2 resolved options (CMakeCache.txt)"
  cache 'LLAMA_[A-Z0-9_]+' "$b2/CMakeCache.txt"
  cache 'CMAKE_(C|CXX)_FLAGS(_RELEASE)?' "$b2/CMakeCache.txt" | sed "s#$(native "$work")#<work>#g"
  echo
  echo "## dynamic linking"
  case "$os" in
    linux)
      for f in "$stage"/lib/*.so.*.* "$stage"/backends/*.so; do
        echo "${f#"$stage"/}: $(readelf -d "$f" | sed -n 's/.*(\(SONAME\|NEEDED\|RUNPATH\|RPATH\)).*\[\(.*\)\]/\1=\2/p' | tr '\n' ' ')"
      done ;;
    macos)
      for f in "$stage"/lib/*.*.*.dylib "$stage"/backends/*.so; do
        echo "${f#"$stage"/}: id=$(otool -D "$f" | tail -n +2 | tr -d '\n') deps=$(otool -L "$f" | tail -n +2 | awk '{print $1}' | tr '\n' ' ') rpath=$(otool -l "$f" | awk '/LC_RPATH/{getline;getline;print $2}' | tr '\n' ' ')"
      done ;;
    windows)
      for f in "$stage"/bin/*.dll "$stage"/backends/*.dll; do
        deps=""
        command -v objdump >/dev/null && deps="$(objdump -p "$f" 2>/dev/null | sed -n 's/^\tDLL Name: //p' | tr -d '\r' | tr '\n' ' ')"
        echo "${f#"$stage"/}: imports=${deps:-not recorded}"
      done ;;
  esac
  echo
  echo "## files (sha256)"
  (cd "$stage" && find . -type f ! -name PROVENANCE.txt | sed 's#^\./##' | LC_ALL=C sort | while read -r f; do sha256 "$f"; done)
  (cd "$stage" && find . -type l | sed 's#^\./##' | LC_ALL=C sort | while read -r f; do echo "symlink  $f -> $(readlink "$f")"; done)
} > "$stage/PROVENANCE.txt"

# ---- 5. pack ------------------------------------------------------------------
log "packing $name.tar.gz"
rm -f "$dist/$name.tar.gz" "$dist/$name.tar.gz.sha256"
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$dist/$name.tar.gz" -C "$dist" "$name"
else
  tar --uid 0 --gid 0 -czf "$dist/$name.tar.gz" -C "$dist" "$name"
fi
cp "$stage/PROVENANCE.txt" "$dist/PROVENANCE-$target.txt"
(cd "$dist" && sha256 "$name.tar.gz" > "$name.tar.gz.sha256" && cat "$name.tar.gz.sha256")
sed '/^## files/q' "$stage/PROVENANCE.txt"
echo "built $name in $(( $(date -u +%s) - started )) s"
