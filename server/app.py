"""Small WAV → Qwen3-ASR (vLLM) → Qwen3-ForcedAligner service.

Run on a CUDA Linux machine. No cloud account or company services are required.
"""
import asyncio
from contextlib import asynccontextmanager
import hmac
import io
import os
import threading
import wave

MAX_BYTES = 8 * 1024 * 1024
MAX_SECONDS = 120


def validate_wav(data):
    with wave.open(io.BytesIO(data), 'rb') as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() != 16000:
            raise ValueError('Expected mono 16-bit PCM WAV at 16000 Hz.')
        count = audio.getnframes()
        if not 0 < count <= MAX_SECONDS * 16000:
            raise ValueError('Record between 0 and 120 seconds.')
        samples = audio.readframes(count)
        if len(samples) != count * 2:
            raise ValueError('Truncated WAV.')
        return samples, count / 16000


def create_app():
    # Heavy optional dependencies are imported only on the GPU server.
    import numpy as np
    import torch
    from fastapi import FastAPI, HTTPException, Request
    from qwen_asr import Qwen3ASRModel
    from starlette.concurrency import run_in_threadpool

    model = None
    lock = threading.Lock()
    token = os.environ.get('DASH_ASR_API_KEY', '')

    @asynccontextmanager
    async def lifespan(app):
        nonlocal model
        model = Qwen3ASRModel.LLM(
            model=os.environ.get('DASH_ASR_MODEL', 'Qwen/Qwen3-ASR-1.7B'),
            gpu_memory_utilization=float(os.environ.get('DASH_ASR_GPU_MEMORY', '0.5')),
            max_inference_batch_size=1,
            max_new_tokens=2048,
            forced_aligner='Qwen/Qwen3-ForcedAligner-0.6B',
            forced_aligner_kwargs={'dtype': torch.bfloat16, 'device_map': 'cuda:0'},
        )
        yield

    app = FastAPI(title='Dash · speech & timing', lifespan=lifespan)

    @app.get('/health')
    def health():
        return {'ready': model is not None, 'backend': 'qwen3-asr-vllm', 'timestamps': 'qwen3-forced-aligner'}

    def infer(samples, duration):
        if not lock.acquire(blocking=False):
            raise HTTPException(429, 'Speech worker is busy. Try again shortly.')
        try:
            signal = np.frombuffer(samples, dtype='<i2').astype(np.float32) / 32768
            result = model.transcribe(audio=(signal, 16000), language=os.environ.get('DASH_LANGUAGE', 'English'), return_time_stamps=True)[0]
            words = [{'text': w.text, 'start': float(w.start_time), 'end': float(w.end_time)} for w in result.time_stamps]
            if not words or not result.text.strip():
                raise HTTPException(422, 'No aligned speech detected.')
            return {'text': result.text, 'language': result.language, 'words': words, 'duration': duration, 'timestamp_unit': 'seconds'}
        finally:
            lock.release()

    @app.post('/transcribe')
    async def transcribe(request: Request):
        if token and not hmac.compare_digest(request.headers.get('authorization', ''), 'Bearer ' + token):
            raise HTTPException(401, 'Invalid service credential.')
        data = bytearray()
        async for chunk in request.stream():
            data.extend(chunk)
            if len(data) > MAX_BYTES:
                raise HTTPException(413, 'Recording is too large.')
        try:
            samples, duration = validate_wav(bytes(data))
        except (ValueError, wave.Error, EOFError):
            raise HTTPException(422, 'Expected a valid mono 16 kHz PCM WAV, up to 120 seconds.')
        return await run_in_threadpool(infer, samples, duration)

    return app


if __name__ == '__main__':
    import uvicorn
    # Loopback default: forward this port over SSH for use from a Mac.
    uvicorn.run(create_app(), host='127.0.0.1', port=8001, access_log=False)
