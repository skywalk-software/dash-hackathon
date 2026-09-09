# Third-party notices

Dash's source is MIT licensed. Its dependencies and model weights retain their own licenses.

| Component | License / source |
|---|---|
| Automerge 3.4.1 | MIT — see the LICENSE installed with `@automerge/automerge` |
| Qwen3-ASR toolkit and models | Apache-2.0 — [upstream](https://github.com/QwenLM/Qwen3-ASR) and each model card |
| vLLM | Apache-2.0 — [upstream](https://github.com/vllm-project/vllm) |
| FastAPI | MIT — [upstream](https://github.com/fastapi/fastapi) |
| Uvicorn | BSD-3-Clause — [upstream](https://github.com/encode/uvicorn) |

Python transitive dependencies (including PyTorch, NumPy and Transformers) are installed separately. No model weights, font binaries, or third-party SDK binaries are checked in. If you redistribute a bundled application/container, retain the license files/notices for every included dependency; this source-level table does not replace them.
