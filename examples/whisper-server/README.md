# whisper-server — voice transcription

Runs [whisper.cpp](https://github.com/ggml-org/whisper.cpp)'s server so a
captionless voice message addressed to the bot gets transcribed and
answered, instead of just noticing "a voice message arrived".

1. Download a model once:
   ```bash
   mkdir -p examples/whisper-server/models
   curl -L -o examples/whisper-server/models/ggml-base.bin \
     https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
   ```
   `ggml-base.bin` (~148 MB) is the multilingual base model, picked over
   the English-only `.en` variants. `ggml-small.bin` (~466 MB) and
   `ggml-medium.bin` (~1.5 GB) trade more RAM/CPU for better accuracy.
2. Bring it up:
   ```bash
   docker compose -f compose.yaml -f examples/whisper-server/compose.yaml up -d
   ```
3. Point warden at it in `.env`:
   ```bash
   export WARDEN_WHISPER_URL=http://whisper-server:8091
   ```

Swapping models means changing the filename in both the download command
and `compose.yaml`'s `--model` arg.
