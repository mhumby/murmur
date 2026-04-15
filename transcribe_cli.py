"""Transcribes a WAV file using mlx-whisper. Prints result to stdout."""

import re
import sys

import numpy as np

LOOP_PATTERN = re.compile(r"(.{4,}?)\1{2,}")


def main():
    audio_path = sys.argv[1]
    model = sys.argv[2] if len(sys.argv) > 2 else "mlx-community/whisper-base-mlx"

    # Read WAV file
    import wave
    with wave.open(audio_path, "rb") as wf:
        frames = wf.readframes(wf.getnframes())
        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32767.0

    if len(audio) < 8_000:  # less than 0.5s
        return

    import mlx_whisper
    result = mlx_whisper.transcribe(audio, path_or_hf_repo=model, language="en", verbose=False)
    text = result.get("text", "").strip()

    # Filter hallucination loops
    if LOOP_PATTERN.search(text):
        return

    if text:
        print(text)


if __name__ == "__main__":
    main()
