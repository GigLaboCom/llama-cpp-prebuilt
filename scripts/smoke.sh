#!/usr/bin/env bash
# Smoke-test a packed release archive the way a consumer meets it: unpack
# it somewhere new, check its sha256 and its dynamic linking, build
# smoke/smoke.c against include/ and lib/ alone, and run it.
#
#   scripts/smoke.sh dist/llama-cpp-b10731-<target>.tar.gz [required-registry ...]
#
# Registries named after the archive must register (e.g. CPU Vulkan);
# a GPU device is never required. No model is loaded.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
case "$(uname -s)" in
  Linux) os=linux ;; Darwin) os=macos ;; MINGW* | MSYS* | CYGWIN*) os=windows ;; *) die "unknown OS" ;;
esac
native() { if [ "$os" = windows ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

if [ -e "$archive.sha256" ]; then
  (cd "$(dirname "$archive")" && sha256 -c "$(basename "$archive").sha256")
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$archive" -C "$tmp"
root="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ "$(basename "$root").tar.gz" = "$(basename "$archive")" ] || die "archive root $(basename "$root") does not match its name"
for f in include/llama.h include/ggml.h include/ggml-backend.h include/gguf.h bindings.rs wrapper.h LICENSE-llama.cpp PROVENANCE.txt; do
  [ -e "$root/$f" ] || die "archive lacks $f"
done

echo "== every file matches PROVENANCE.txt"
(cd "$root" && grep -E '^[0-9a-f]{64}  ' PROVENANCE.txt | sha256 -c - > "$tmp/files.check") \
  || { cat "$tmp/files.check"; die "a file does not match PROVENANCE.txt"; }
echo "ok"

echo "== dynamic linking"
case "$os" in
  linux)
    for f in "$root"/lib/*.so.*.* "$root"/backends/*.so; do
      runpath="$(readelf -d "$f" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p;s/.*(RPATH).*\[\(.*\)\]/\1/p')"
      case "$runpath" in
        '$ORIGIN:$ORIGIN/../lib') ;;
        *) die "$f has rpath '$runpath'" ;;
      esac
      if ldd "$f" | grep -q 'not found'; then ldd "$f"; die "$f has an unresolved dependency"; fi
      echo "  $(basename "$f"): rpath $runpath, all dependencies resolve"
    done ;;
  macos)
    for f in "$root"/lib/*.*.*.dylib "$root"/backends/*.so; do
      bad="$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^(@rpath/|/usr/lib/|/System/Library/)' || true)"
      [ -z "$bad" ] || die "$f depends on $bad"
      rp="$(otool -l "$f" | awk '/LC_RPATH/{getline;getline;print $2}' | tr '\n' ' ')"
      [ "$rp" = "@loader_path @loader_path/../lib " ] || die "$f has rpath '$rp'"
      echo "  $(basename "$f"): rpath $rp"
    done ;;
  windows)
    ls "$root"/bin/*.dll "$root"/lib/*.lib >/dev/null ;;
esac

echo "== build smoke against the archive"
cmake -S "$(native "$here/smoke")" -B "$(native "$tmp/build")" -DPREBUILT="$(native "$root")" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$(native "$tmp/build")" --config Release --target smoke >/dev/null
exe="$tmp/build/smoke"
[ -x "$exe" ] || exe="$tmp/build/Release/smoke.exe"

echo "== run"
if [ "$os" = windows ]; then
  PATH="$root/bin:$PATH" "$exe" "$(native "$root/backends")" "$@"
else
  # No LD_LIBRARY_PATH / DYLD_*: the rpaths have to be enough.
  env -u LD_LIBRARY_PATH "$exe" "$root/backends" "$@"
fi
