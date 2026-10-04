//! Generates `bindings.rs` the way wipemark-app's
//! `crates/wipemark-llama-sys/build.rs` (`generate_bindings`) does: the
//! same bindgen version (Cargo.lock), the same header (`wrapper/wrapper.h`,
//! a byte copy), the same include order and the same allowlist. Keep the
//! builder chain below identical to that function.
//!
//! Usage (from this directory, as scripts/build.sh runs it):
//!
//! ```sh
//! TARGET=<rust target triple> cargo run --locked --release -- \
//!     <install prefix>/include <llama.cpp source>/include <out>/bindings.rs
//! ```
//!
//! `TARGET` is what cargo sets for a build script; bindgen reads it to pick
//! the clang target, so it is set here the same way.

use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: {} <prefix-include> <llama-include> <out.rs>", args[0]);
        std::process::exit(2);
    }
    let (prefix_include, llama_include, out) = (&args[1], &args[2], &args[3]);

    let bindings = bindgen::Builder::default()
        .header("wrapper/wrapper.h")
        .clang_arg(format!("-I{}", Path::new(prefix_include).display()))
        .clang_arg(format!("-I{}", Path::new(llama_include).display()))
        .allowlist_function("ggml_backend_.*")
        .allowlist_function("llama_.*")
        .allowlist_type("llama_.*")
        .allowlist_function("gguf_.*")
        .allowlist_type("gguf_.*")
        .generate()
        .expect("llama-cpp-prebuilt: bindgen failed");
    bindings
        .write_to_file(out)
        .expect("llama-cpp-prebuilt: write bindings.rs failed");
}
