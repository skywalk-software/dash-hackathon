# Supporting speech service

Astra powers the editor. This adapter supplies only transcript text and word timing.

The public `qwen-asr` package provides `Qwen3ASRModel.LLM(...)`. Dash uses its vLLM ASR backend and requests `return_time_stamps=True` with a separately loaded Qwen3-ForcedAligner. The aligner in this wrapper uses the official PyTorch implementation; ASR uses vLLM. This is the upstream supported combined path, not a claim that ASR alone produces reliable word times.

[Upstream setup and API](https://github.com/QwenLM/Qwen3-ASR#vllm-backend).

Use Python 3.12, a compatible CUDA/PyTorch driver environment, and a GPU with enough memory for both models. Start with a fresh environment. The optional FlashAttention install can improve performance but is not required by this starter. The first startup downloads public model weights.

```sh
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r server/requirements.txt
DASH_ASR_GPU_MEMORY=0.5 python server/app.py
curl http://127.0.0.1:8001/health
curl --fail -H 'Content-Type: audio/wav' --data-binary @sample.wav \
  http://127.0.0.1:8001/transcribe
```

Input: mono 16 kHz signed 16-bit PCM WAV, at most 120 seconds / 8 MiB. The Mac adapter writes this format. Output:

```json
{
  "text": "Make this shorter.",
  "language": "English",
  "words": [
    {"text": "Make", "start": 0.2, "end": 0.5},
    {"text": "this", "start": 0.5, "end": 0.7},
    {"text": "shorter.", "start": 0.7, "end": 1.2}
  ],
  "duration": 1.5,
  "timestamp_unit": "seconds"
}
```

The JSON above illustrates the format; it is not a measured model result. Word times are audio-relative **seconds**. The Mac validates them and adds the capture-start offset before passing session-relative **milliseconds** to the editor engine. It fails on absent alignment rather than substituting invented timestamps.

Configuration: `DASH_ASR_MODEL` (default `Qwen/Qwen3-ASR-1.7B`), `DASH_ASR_GPU_MEMORY` (default `0.5`), `DASH_LANGUAGE` (default `English`), optional `DASH_ASR_API_KEY` (same value on client/server). See upstream for supported alignment languages.

The service processes one inference at a time; overlapping requests receive HTTP 429. It binds only to loopback. Use SSH forwarding for development. Running a shared internet service needs proper authentication, TLS, request timeouts, rate limits, and a deployment/retention policy. GPU execution and alignment quality have not been validated in this starter.

From the Mac, forward only the speech port: `ssh -N -L 8001:127.0.0.1:8001 YOUR_GPU_HOST`. Set `DASH_ASR_URL=http://127.0.0.1:8001` in `.env.local`. Astra requests go directly to the OpenAI API; no local text-model server is needed.
