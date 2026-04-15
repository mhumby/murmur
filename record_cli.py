"""Records audio to a WAV file until interrupted (SIGINT)."""

import signal
import sys
import wave
import numpy as np
import sounddevice as sd

SAMPLE_RATE = 16_000
CHANNELS = 1

chunks: list[np.ndarray] = []


def callback(indata, frames, time, status):
    chunks.append(indata.copy())


def save_and_exit(signum, frame):
    if not chunks:
        sys.exit(0)
    audio = np.concatenate(chunks, axis=0)

    # Trim trailing silence
    chunk_size = int(SAMPLE_RATE * 0.05)
    end = len(audio)
    while end > chunk_size:
        if np.max(np.abs(audio[end - chunk_size : end])) > 0.01:
            break
        end -= chunk_size
    audio = audio[:end]

    out_path = sys.argv[1]
    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes((audio * 32767).astype(np.int16).tobytes())
    sys.exit(0)


signal.signal(signal.SIGINT, save_and_exit)
signal.signal(signal.SIGTERM, save_and_exit)

with sd.InputStream(samplerate=SAMPLE_RATE, channels=CHANNELS, dtype="float32", callback=callback):
    signal.pause()
