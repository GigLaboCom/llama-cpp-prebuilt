/* bindgen entry point for wipemark-llama-sys.
 *
 * Carried over from heretic-mnemoria
 * `mnemoria-server/ee/ml/crates/ml-engine-ggml-sys/wrapper/wrapper.h` at
 * `a160f8c` (the project is closed; this copy is ours now). Cut:
 * whisper.h and the mtmd block. Added: gguf.h, for reading a model's
 * metadata without loading it (`wipemark_llama::estimate`).
 *
 *   - ggml.h          : types the other headers use (ggml_type, the log callback)
 *   - ggml-backend.h  : ggml_backend_load_all_from_path / reg / dev — the
 *                       dynamic backend loader GGML_BACKEND_DL=ON exposes
 *   - gguf.h          : the GGUF header reader (metadata only, no tensors)
 *   - llama.h         : model, context, sampling, chat templates
 *
 * Include dirs are added by build.rs from the vendored tree and the shared
 * ggml install prefix.
 */
#include "ggml.h"
#include "ggml-backend.h"
#include "gguf.h"
#include "llama.h"
