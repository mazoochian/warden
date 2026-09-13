# llama-server — self-hosted local model

Runs [llama.cpp](https://github.com/ggml-org/llama.cpp)'s CPU-first
inference server instead of a hosted API. Sized for
[Qwen3.5-4B](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) (~2.7 GB at
`Q4_K_M`, ~2.1 GB resident), chosen for real tool-calling support and solid
multilingual quality in a footprint an old CPU-only box can run.

1. Download the GGUF once, wherever you have a good connection:
   ```bash
   mkdir -p examples/llama-server/models
   curl -L -o examples/llama-server/models/Qwen3.5-4B-Q4_K_M.gguf \
     https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf
   ```
2. Bring it up:
   ```bash
   docker compose -f compose.yaml -f examples/llama-server/compose.yaml up -d
   ```
3. Point warden at it in `.env`:
   ```bash
   export WARDEN_LLM_PROVIDER=openai_compat
   export WARDEN_OPENAI_BASE_URL=http://llama-server:8090/v1
   export WARDEN_OPENAI_MODEL=qwen3.5-4b
   ```

Qwen3.5 defaults to an extended "thinking" trace before its answer, which
can burn the whole token budget on a short question. `compose.yaml` here
already disables it (`--reasoning off`); if you swap in a different model,
check whether it needs the same treatment.

Swapping models means changing the GGUF filename in both the download
command and `compose.yaml`'s `--model`/`--alias` args, and
`WARDEN_OPENAI_MODEL` to match.
