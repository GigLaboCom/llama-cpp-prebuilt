/* generate — load a GGUF on the archive's libraries and generate tokens.
 *
 *   generate <backends-dir> <model.gguf> [n-tokens] [prompt]
 *
 * Not run in CI (no model there). By hand, on a machine with a GPU:
 * every layer is offloaded (n_gpu_layers = 999), greedy sampling, and the
 * prompt-processing and generation rates are printed. Exit 0 when at least
 * one token was generated.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ggml-backend.h"
#include "llama.h"

static double now(void) {
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <backends-dir> <model.gguf> [n-tokens] [prompt]\n", argv[0]);
        return 1;
    }
    const char *dir = argv[1];
    const char *path = argv[2];
    int n_gen = argc > 3 ? atoi(argv[3]) : 64;
    const char *prompt = argc > 4 ? argv[4]
        : "<|im_start|>user\nWrite one sentence about the sea.<|im_end|>\n<|im_start|>assistant\n";

    ggml_backend_load_all_from_path(dir);
    llama_backend_init();
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        printf("device %zu: %s — %s\n", i, ggml_backend_dev_name(dev), ggml_backend_dev_description(dev));
    }

    struct llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 999;
    double t0 = now();
    struct llama_model *model = llama_model_load_from_file(path, mp);
    if (!model) {
        fprintf(stderr, "FAIL model did not load\n");
        return 1;
    }
    char desc[256];
    llama_model_desc(model, desc, sizeof desc);
    printf("model: %s, loaded in %.2f s\n", desc, now() - t0);

    struct llama_context_params cp = llama_context_default_params();
    cp.n_ctx = 2048;
    cp.n_batch = 512;
    struct llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        fprintf(stderr, "FAIL context\n");
        return 1;
    }
    const struct llama_vocab *vocab = llama_model_get_vocab(model);

    int n_prompt = -llama_tokenize(vocab, prompt, (int32_t)strlen(prompt), NULL, 0, true, true);
    llama_token *tokens = malloc(sizeof(llama_token) * (size_t)n_prompt);
    if (llama_tokenize(vocab, prompt, (int32_t)strlen(prompt), tokens, n_prompt, true, true) < 0) {
        fprintf(stderr, "FAIL tokenize\n");
        return 1;
    }

    struct llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    t0 = now();
    if (llama_decode(ctx, llama_batch_get_one(tokens, n_prompt)) != 0) {
        fprintf(stderr, "FAIL decode prompt\n");
        return 1;
    }
    double t_prompt = now() - t0;

    int produced = 0;
    printf("---\n");
    t0 = now();
    for (; produced < n_gen; produced++) {
        llama_token tok = llama_sampler_sample(smpl, ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) break;
        char piece[256];
        int n = llama_token_to_piece(vocab, tok, piece, sizeof piece, 0, true);
        if (n > 0) fwrite(piece, 1, (size_t)n, stdout);
        fflush(stdout);
        if (llama_decode(ctx, llama_batch_get_one(&tok, 1)) != 0) {
            fprintf(stderr, "\nFAIL decode\n");
            return 1;
        }
    }
    double t_gen = now() - t0;
    printf("\n---\n");
    printf("prompt: %d tokens in %.3f s (%.1f tokens/s)\n", n_prompt, t_prompt, n_prompt / t_prompt);
    printf("generated: %d tokens in %.3f s (%.1f tokens/s)\n", produced, t_gen, produced / t_gen);

    llama_sampler_free(smpl);
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    free(tokens);
    return produced > 0 ? 0 : 1;
}
