"""Transcriber — uses mlx-whisper for fast on-device inference on Apple Silicon."""

import re
import numpy as np

# Model options (fastest → most accurate):
#   "mlx-community/whisper-tiny-mlx"      ~fastest, good for short phrases
#   "mlx-community/whisper-base-mlx"      good balance
#   "mlx-community/whisper-small-mlx"     more accurate
#   "mlx-community/whisper-large-v3-mlx"  most accurate, slower
DEFAULT_MODEL = "mlx-community/whisper-base-mlx"

# Regex to detect hallucination loops (same phrase repeated 3+ times)
_LOOP_PATTERN = re.compile(r"(.{4,}?)\1{2,}")


class Transcriber:
    def __init__(self, model_name: str = DEFAULT_MODEL, language: str = "en"):
        self.model_name = model_name
        self.language = language

    def transcribe(self, audio: np.ndarray) -> str:
        """Transcribe a float32 16 kHz audio array. Returns the text string."""
        if audio is None or len(audio) == 0:
            return ""

        # Minimum 0.5 seconds to avoid spurious transcriptions
        if len(audio) < 8_000:
            return ""

        import mlx_whisper

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model_name,
            language=self.language,
            verbose=False,
        )

        text: str = result.get("text", "").strip()

        # Discard hallucination loops (e.g. "amíg滑 amíg滑 amíg滑...")
        if _LOOP_PATTERN.search(text):
            return ""

        return text

    @property
    def model_display_name(self) -> str:
        return self.model_name.split("/")[-1].replace("-mlx", "").replace("-", " ").title()
