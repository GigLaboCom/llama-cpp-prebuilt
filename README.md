# llama-cpp-prebuilt

Prebuilt [llama.cpp](https://github.com/ggml-org/llama.cpp) for
[Wipemark](https://github.com/GigLaboCom/wipemark-app): one GitHub release
per pinned llama.cpp commit, for four targets, each archive with its
provenance and its sha256.

**For whom.** `wipemark-app`'s `wipemark-llama-sys` crate links llama.cpp
as shared libraries. Building them from source costs about fifteen minutes
in every CI run and needs cmake, a C++ compiler, libclang, and — for the
GPU backend — the Vulkan SDK and `glslc` on every developer machine. This
repository builds them once per pin, with exactly the configuration
`wipemark-llama-sys` uses, and publishes them; the consumer downloads one
archive, checks its sha256, and links. It is useful to anyone who wants
the same thing, but it is shaped for that one consumer and makes no other
promises.

| target | runner | backends |
|---|---|---|
| `x86_64-unknown-linux-gnu` | `ubuntu-24.04` | CPU (14 x86 variants, picked at run time) + Vulkan |
| `aarch64-unknown-linux-gnu` | `ubuntu-24.04-arm` | CPU (one armv8 library) + Vulkan |
| `x86_64-pc-windows-msvc` | `windows-latest` | CPU (9 x86 variants) + Vulkan |
| `aarch64-apple-darwin` | `macos-latest` | CPU + Metal + BLAS (Accelerate) |

No CUDA: the shipped GPU backends are Vulkan on Linux and Windows and
Metal on macOS (Wipemark decision D187).

## Licence

llama.cpp and ggml are MIT-licensed, `Copyright (c) 2023-2026 The ggml
authors`. The full text is [`LICENSE-llama.cpp`](LICENSE-llama.cpp) here
and `LICENSE-llama.cpp` in every archive; whoever redistributes the
libraries must keep it with them.

Compiled into the Vulkan backend are the Khronos Vulkan headers
(`Vulkan-Hpp`, Apache-2.0 / MIT) from the build machine's Vulkan SDK; the
libraries link the platform C++ runtime, and on Linux and Windows the
OpenMP runtime (`libgomp`, `vcomp140`).

The scripts in this repository are MIT-licensed too ([`LICENSE`](LICENSE)).

## What a release contains

A release is tagged with the llama.cpp release tag it builds — `b10731` —
and carries, for each target:

| asset | what it is |
|---|---|
| `llama-cpp-<tag>-<target>.tar.gz` | the archive (gzip'd tar on every platform, Windows included) |
| `PROVENANCE-<target>.txt` | a copy of the archive's `PROVENANCE.txt`, readable without downloading it |
| `SHA256SUMS` | `sha256sum` format, one line per archive and per provenance file |

Every archive unpacks into one directory named like the archive:

```
llama-cpp-b10731-x86_64-unknown-linux-gnu/
  include/            llama.h, llama-cpp.h, gguf.h, ggml.h, ggml-backend.h, ggml-*.h — every installed header
  lib/                Linux:   libllama.so.0.3.0, libggml.so.0.22.0, libggml-base.so.0.22.0 + their SONAME and dev symlinks
                      macOS:   libllama.0.3.0.dylib, libggml.0.22.0.dylib, libggml-base.0.22.0.dylib + symlinks
                      Windows: llama.lib, ggml.lib, ggml-base.lib (import libraries)
  bin/                Windows only: llama.dll, ggml.dll, ggml-base.dll
  backends/           the run-time-loaded backends: libggml-cpu-*.so, libggml-vulkan.so,
                      libggml-metal.so, libggml-blas.so / ggml-cpu-*.dll, ggml-vulkan.dll
  bindings.rs         Rust FFI bindings, generated on that target by the same bindgen invocation wipemark-llama-sys runs
  wrapper.h           the header bindgen read (a byte copy of wipemark-llama-sys's wrapper/wrapper.h)
  LICENSE-llama.cpp   MIT, the ggml authors
  PROVENANCE.txt      how, where and from what it was built, and the sha256 of every file above
```

* **Linking.** Link `llama`, `ggml` and `ggml-base` (dynamically). The
  backends are *not* linked: `ggml` loads them at run time from a
  directory the program names (`ggml_backend_load_all_from_path`, or
  `ggml_backend_load` per file). No backend directory is compiled into
  `libggml`.
* **Finding each other.** On Linux every library carries
  `RUNPATH=$ORIGIN:$ORIGIN/../lib`, on macOS `LC_RPATH @loader_path` and
  `@loader_path/../lib` with `@rpath/…` install names, so `libllama` finds
  `libggml` beside it and a backend finds `libggml-base` in `../lib` —
  with no `LD_LIBRARY_PATH`. The *executable* still needs an rpath to
  wherever `lib/` ends up. On Windows the three DLLs in `bin/` go beside the
  executable (or on `PATH`).
* **Runtime requirements.** Linux: glibc ≥ 2.39 and GCC 13's libstdc++
  (the runner is Ubuntu 24.04), `libgomp.so.1`; the Vulkan backend
  additionally `libvulkan.so.1` — without it only that backend fails to
  load. macOS: 11.0 or newer. Windows: the Visual C++ runtime
  (`vcruntime140`, `msvcp140`, `vcomp140`), and `vulkan-1.dll`, which a GPU
  driver installs.
* **Bindings are per target.** `c_char`, `c_long` and the layout of
  system types differ between targets; use the `bindings.rs` of the archive
  you link. On `x86_64-unknown-linux-gnu` it is byte-identical to what
  `wipemark-llama-sys`'s own build generates.

## Verifying a download

```sh
tag=b10731 target=x86_64-unknown-linux-gnu
base=https://github.com/GigLaboCom/llama-cpp-prebuilt/releases/download/$tag
curl -fLO "$base/llama-cpp-$tag-$target.tar.gz"
curl -fLO "$base/SHA256SUMS"
sha256sum -c SHA256SUMS --ignore-missing          # macOS: shasum -a 256 -c SHA256SUMS --ignore-missing
tar -xzf "llama-cpp-$tag-$target.tar.gz"
cd "llama-cpp-$tag-$target" && grep -E '^[0-9a-f]{64}  ' PROVENANCE.txt | sha256sum -c --quiet -
```

`SHA256SUMS` comes from the same place as the archive, so it proves the
download was not damaged, not that it is the archive you meant. A
consumer that cares pins each archive's sha256 in its own repository (the
table below; Wipemark keeps them in `wipemark-llama-sys/PIN.md`) and
compares against that.

## The consumer contract (what wipemark-llama-sys implements)

1. **Which asset.** `https://github.com/GigLaboCom/llama-cpp-prebuilt/releases/download/<tag>/llama-cpp-<tag>-<target>.tar.gz`,
   where `<tag>` is `pin::LLAMA_TAG` and `<target>` is cargo's `TARGET`.
   The four targets above are the only ones published.
2. **Which bytes.** The sha256 of that archive, pinned in the consumer's
   repository, checked before anything is unpacked; a mismatch is a build
   failure, never a fallback. `SHA256SUMS` is a convenience, not the pin.
3. **What it holds.** One top-level directory `llama-cpp-<tag>-<target>/`
   laid out as above. `PROVENANCE.txt`'s `llama.cpp_commit:` line equals
   the consumer's `pin::LLAMA_COMMIT` — a cheap check worth making on a
   directory a developer pointed at by hand, which has no archive to hash.
4. **How to use it.** `cargo:rustc-link-search=native=<root>/lib`,
   `cargo:rustc-link-lib=dylib={ggml,ggml-base,llama}` (unchanged), an rpath
   to `<root>/lib` (or `$ORIGIN`-relative once the libraries are bundled
   beside the binary), `include!` of `<root>/bindings.rs` in place of
   `$OUT_DIR/bindings.rs`, and `<root>/backends` as the backends directory
   handed to `Runtime::init` (`WIPEMARK_LLAMA_BACKENDS_DIR`). On Windows,
   `<root>/bin/*.dll` are copied beside the executable.
5. **A local copy.** **`WIPEMARK_LLAMA_PREBUILT=<path>`** — the root of an
   unpacked archive (the directory holding `include/`, `lib/`, `backends/`,
   `bindings.rs`). When it is set, nothing is downloaded and the archive
   hash is not checked (there is no archive); the `PROVENANCE.txt` commit
   check still applies. When it is unset, the release asset is downloaded
   and verified.

### b10731

Pin `ggml-0.22.0+llama-0eadefe`: llama.cpp `0eadefebd3f8f92a86d634a0e5b8fffc9dc792c0`,
ggml `36da57138425487184aa1da2eee2cde155909c6f` (0.22.0), libllama 0.3.0.
Release: <https://github.com/GigLaboCom/llama-cpp-prebuilt/releases/tag/b10731>.

| target | sha256 of `llama-cpp-b10731-<target>.tar.gz` |
|---|---|
| `x86_64-unknown-linux-gnu` | _filled in by the first release_ |
| `aarch64-unknown-linux-gnu` | _filled in by the first release_ |
| `x86_64-pc-windows-msvc` | _filled in by the first release_ |
| `aarch64-apple-darwin` | _filled in by the first release_ |

## How it is built

[`scripts/build.sh`](scripts/build.sh) is the whole build, used by CI and
by hand (`scripts/build.sh` on any of the four hosts; Git Bash on
Windows). It reproduces `wipemark-llama-sys`'s `build.rs` (feature
`native`) step for step:

0. **The source, verified.** llama.cpp is fetched shallow at
   `LLAMA_COMMIT` from [`PIN`](PIN) and refused unless its `HEAD` is that
   commit (wipemark's `verify_pin`), the upstream tag names the same commit,
   `scripts/sync-ggml.last` names `GGML_COMMIT`, and the ggml and llama
   versions in the CMake files are the pinned ones. `LLAMA_SRC=<clone>`
   fetches from a local clone instead.
1. **One shared ggml** from `llama.cpp/ggml`: `BUILD_SHARED_LIBS=ON`,
   `GGML_BACKEND_DL=ON`, `GGML_CPU_ALL_VARIANTS=ON` on x86_64 (`OFF` on
   arm64, as wipemark-llama-sys does), `GGML_NATIVE=OFF`,
   `GGML_BUILD_TESTS=OFF`, `GGML_BUILD_EXAMPLES=OFF`, `GGML_VULKAN=ON` on
   Linux and Windows (Metal and BLAS are ggml's defaults on Apple),
   `CMAKE_BUILD_TYPE=Release`. The `ggml.pc.in` the llama.cpp subtree omits
   is restored verbatim (`scripts/ggml.pc.in`).
2. **libllama against it**: `LLAMA_USE_SYSTEM_GGML=ON`, the install prefix
   on `CMAKE_PREFIX_PATH`, its `include/` on the compile flags (the
   `find_package(ggml)` quirk), `GGML_BACKEND_DL=ON`,
   `LLAMA_BUILD_{TESTS,EXAMPLES,SERVER,TOOLS,APP,COMMON}=OFF`,
   `LLAMA_CURL=OFF`, `BUILD_SHARED_LIBS=ON`.
3. **bindings.rs** by [`bindgen/`](bindgen/): bindgen 0.71.1 (and the rest of
   wipemark's lockfile for it), the same builder chain — `wrapper.h`,
   `-I<prefix>/include -I<llama.cpp>/include`, allowlist
   `ggml_backend_.*`, `llama_.*`, `gguf_.*` — `TARGET` set as cargo sets it
   for a build script, formatted by `rustfmt` from wipemark's toolchain
   (1.94.1).
4. **The archive**, its `PROVENANCE.txt` (repository and commit, workflow
   run, llama.cpp tag and commit, ggml commit and version, build date,
   runner image, OS, compiler, cmake, Vulkan SDK / `glslc` or Xcode and SDK
   versions, rustc, rustfmt, bindgen, libclang; both configure command
   lines; every resolved `GGML_*` and `LLAMA_*` cache option; SONAME,
   NEEDED and RUNPATH or install names of every library; the sha256 of
   every file), and its `.sha256`.

[`scripts/smoke.sh`](scripts/smoke.sh) then tests the *packed* archive the
way a consumer meets it: unpack it somewhere new, check every file against
`PROVENANCE.txt`, check the rpaths and that every dependency resolves,
build [`smoke/smoke.c`](smoke/smoke.c) against `include/` and `lib/`
alone, and run it — every backend library must load and export
`ggml_backend_init`, the named registries must register (CPU everywhere,
Vulkan on Linux through Mesa's software driver, Metal on macOS), and
`llama_backend_init` must run. No GPU device and no model are required.
[`smoke/generate.c`](smoke/generate.c) is the by-hand check with a model:
it offloads every layer and prints tokens per second.

### What differs from a wipemark-llama-sys build

Deliberate, and the only differences:

* **No `GGML_BACKEND_DIR`.** wipemark-llama-sys compiles its absolute
  `$OUT_DIR/backends` into `libggml` as the default search directory of
  `ggml_backend_load_all()`; a path on a CI runner means nothing on the
  consumer's machine. Here none is compiled in, the backends are installed
  to `bin/` and moved to `backends/`. Wipemark never calls the no-argument
  loader — `Runtime::init` names its directories — so it sees no
  difference.
* **Relative rpaths.** `$ORIGIN` / `@loader_path` (plus `../lib` for the
  backends) instead of the absolute install path wipemark-llama-sys puts
  on libllama, and `CMAKE_BUILD_WITH_INSTALL_RPATH=ON` on both stages.
* **MSVC flags.** For an MSVC target the `cmake` crate, under the Visual
  Studio generator, replaces `CMAKE_<LANG>_FLAGS` *and*
  `CMAKE_<LANG>_FLAGS_RELEASE` with `-nologo -MD -Brepro`, which drops
  `/O2`, `/DNDEBUG` and `/EHsc`: wipemark-llama-sys on Windows would build
  an unoptimised ggml with assertions on and no C++ exception model. This
  build keeps CMake's Release defaults instead (`/O2 /Ob2 /DNDEBUG`,
  `/EHsc`, `/MD`). On Linux and macOS the flags are the `cmake` and `cc`
  crates' exactly (`-ffunction-sections -fdata-sections -fPIC [-m64] -w`,
  and `--target=arm64-apple-macosx -mmacosx-version-min=11.0` on macOS).
* **Only the libraries are packed** — not `lib/cmake/` or `lib/pkgconfig/`,
  whose contents name the build machine's prefix.

## Cutting a release for a new pin

The pin moves in wipemark-app first (`wipemark-llama-sys/PIN.md`, "Bump
procedure"); this repository follows it.

1. Edit [`PIN`](PIN): `LLAMA_TAG`, `LLAMA_COMMIT` (what the tag names
   upstream), `GGML_COMMIT` (`scripts/sync-ggml.last` at that commit),
   `GGML_VERSION`, `LLAMA_VERSION` (the CMake files), `PIN_STRING`. If
   wipemark changed its `wrapper.h`, its bindgen version or its toolchain,
   copy them into `bindgen/` (`wrapper/wrapper.h`, `Cargo.lock` —
   `cp ../wipemark-app/Cargo.lock bindgen/ && cargo metadata
   --manifest-path bindgen/Cargo.toml > /dev/null` prunes it —
   `rust-toolchain.toml`). If its `build.rs` changed a CMake flag, change
   `scripts/build.sh` to match.
2. Commit and push to `main`; the `ci` workflow builds and smoke-tests
   x86_64 Linux.
3. Tag that commit with the llama.cpp tag and push the tag:
   `git tag b<N> && git push origin b<N>`. The `release` workflow refuses a
   tag that is not the `PIN`'s, builds the four targets, smoke-tests each,
   and publishes the release only when all four are green. A failed target
   can be re-run from the Actions page. Before tagging, the same workflow
   can be dry-run on `main` by hand (`gh workflow run release -f tag=b<N>`):
   it builds and smoke-tests the four targets and publishes nothing; with
   `-f publish=true` on a tagged commit it publishes (assets are replaced).
4. Download each archive, check it against `SHA256SUMS`, record the four
   sha256 in the table above and in wipemark's `PIN.md`.
