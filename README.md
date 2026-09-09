<p align="center"><img src="docs/banner.svg" alt="Dash — Speak. Point. Keep writing." width="100%"></p>

<p align="center">
  <strong>A small native editor for spoken edits and pointed-at text.</strong><br>
  Built for a hackathon. Easy to read, change, and make your own.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-102326">
  <img alt="Qwen3 + vLLM" src="https://img.shields.io/badge/inference-Qwen3%20%2B%20vLLM-bcef90?labelColor=102326">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-bcef90?labelColor=102326">
  <img alt="Prototype" src="https://img.shields.io/badge/status-hackathon%20starter-f4f1e7?labelColor=102326">
</p>

## The idea

Press **Start recording**, speak an edit, and select the passage you mean. Stop recording and Dash sends your microphone audio for transcription and word timing. The editor matches those words with your cursor/selection history, generates edits, and reconciles them with anything you typed meanwhile.

> “Make this paragraph shorter. And turn these details into a list.”

Normal Mac microphone. Your own model services. Plain text all the way down.

## What’s here

- **Native macOS editor** — open/save text files, selection tracking, conversation history, and before/after inspection.
- **Microphone capture** — default system input, permission prompt, local PCM WAV recording, and playback.
- **Qwen3 speech pipeline** — Qwen3-ASR on vLLM plus Qwen3-ForcedAligner for word timestamps.
- **Qwen3 editing** — a configurable vLLM chat endpoint handles interpretation, generation, and reconciliation.
- **Automerge state** — scoped edits, revision checks, and cancellation guards preserve concurrent typing.

**Starter status:** the code is wired together, but the microphone → GPU → final-edit flow has not been validated end to end. Expect setup friction and imperfect model results. The editor can open and edit files without the model services. Speech requests fail visibly when the service is unavailable; there are no fabricated transcripts or timestamps in the normal microphone flow.

## Quick start · Mac

You need macOS 14+, Xcode, XcodeGen, and Node 22+.

```sh
brew install xcodegen node
npm ci --prefix Engine --ignore-scripts
cp .env.example .env.local
./scripts/build.sh
python3 scripts/run.py
```

Use the launcher to load `.env.local` and start the local editing helper. Direct Xcode Run opens the editor, but does not load that configuration or automatically start the helper.

Choose your default microphone in **System Settings → Sound → Input**. On first recording, allow microphone access. Keep requests under two minutes. Start the GPU services below to enable transcription and generated edits.

## Model services · CUDA Linux

The Mac is the UI/client. vLLM runs on a CUDA Linux host; this starter does not install a GPU stack on macOS.

**1. Speech and word timing** — use a fresh Python 3.12 environment:

```sh
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r server/requirements.txt
python server/app.py
```

This loads `Qwen/Qwen3-ASR-1.7B` through the official `qwen-asr` vLLM backend and `Qwen/Qwen3-ForcedAligner-0.6B` for alignment. The wrapper exposes `/health` and `/transcribe` on loopback port **8001**. Model weights download on first start. See [speech setup](docs/SPEECH.md).

**2. Text editing** — in a separate compatible vLLM environment/GPU allocation:

```sh
vllm serve Qwen/Qwen3-8B --host 127.0.0.1 --port 8000 \
  --max-model-len 16384 --gpu-memory-utilization 0.4
```

Memory requirements depend on GPU, context length, and other resident models. These are starting settings, not a validated single-GPU deployment. Use separate GPUs or adjust memory allocations if both services cannot fit.

**3. Forward to your Mac:**

```sh
ssh -N -L 8000:127.0.0.1:8000 -L 8001:127.0.0.1:8001 YOUR_GPU_HOST
```

The defaults in `.env.example` now point at both services. Restart the Mac app after changing settings. Remote URLs must use HTTPS; HTTP is accepted only for loopback.

## Make it yours

| Area | Start here |
|---|---|
| Microphone and speech client | [`App/MicrophoneCaptureService.swift`](App/MicrophoneCaptureService.swift) |
| Editor and conversation UI | [`App/EditorView.swift`](App/EditorView.swift) |
| Speech server | [`server/app.py`](server/app.py) |
| Model endpoint and settings | [`Engine/model_client.mjs`](Engine/model_client.mjs) |
| Interpretation prompt | [`Engine/hack6/interpret.txt`](Engine/hack6/interpret.txt) |
| Generation and reconciliation prompts | [`Engine/hack8/`](Engine/hack8/) |
| Cursor/recording data types | [`Packages/EditorInteractionKit/`](Packages/EditorInteractionKit/) |

Read the [architecture](docs/ARCHITECTURE.md), [contribution notes](CONTRIBUTING.md), and [next steps](docs/ROADMAP.md).

## Data and limitations

Audio is sent only after Stop to your configured speech service. Document text and editing instructions are sent to your configured text model. This wrapper holds audio in memory for inference; the model runtime may have its own logging configuration.

The Mac retains recordings and capture packages in `~/Library/Application Support/DashHackathon/`. Packages include **whole document revisions**, not just selected text. Restart clears the UI, not saved files. Delete those directories yourself when finished; review exports before sharing. Optional diagnostic export also contains document/model content.

Word times are aligned to the recorded audio. Mapping audio start to the cursor clock uses the recorder-start time and is approximate. There is no live streaming transcription, calibrated input latency, packaged Node helper, automatic server installer, or production distribution/notarization flow yet. Small models may reject or misinterpret complex edits; use disposable sample text while experimenting.

## Checks

```sh
npm test --prefix Engine
swift test --package-path Packages/EditorInteractionKit
python3 -m unittest discover -s server -p 'test_*.py'
python3 scripts/check-public.py
```

CI builds the Mac app and runs offline checks. It does not download models or claim a live microphone/GPU test.

## License & credits

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Built with [Automerge](https://automerge.org/), [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR), and [vLLM](https://github.com/vllm-project/vllm). Models and dependencies retain their own licenses. Model weights are not included in this repository.
