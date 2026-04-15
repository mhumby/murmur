"""Audio recorder — captures microphone input at 16 kHz (Whisper's native rate)."""

import threading
import numpy as np
import sounddevice as sd

SAMPLE_RATE = 16_000
CHANNELS = 1
DTYPE = "float32"


class AudioRecorder:
    def __init__(self):
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._stream: sd.InputStream | None = None

    def start(self) -> None:
        with self._lock:
            self._chunks = []

        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

        with self._lock:
            if not self._chunks:
                return np.zeros(0, dtype=np.float32)
            audio = np.concatenate(self._chunks, axis=0).flatten()

        return _trim_silence(audio)

    def _callback(self, indata: np.ndarray, frames: int, time, status) -> None:
        with self._lock:
            self._chunks.append(indata.copy())


def _trim_silence(audio: np.ndarray, threshold: float = 0.01, chunk_ms: int = 50) -> np.ndarray:
    """Strip trailing silence to prevent Whisper from hallucinating filler."""
    chunk_size = int(SAMPLE_RATE * chunk_ms / 1000)
    end = len(audio)
    while end > chunk_size:
        chunk = audio[end - chunk_size : end]
        if np.max(np.abs(chunk)) > threshold:
            break
        end -= chunk_size
    return audio[:end]
