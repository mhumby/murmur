"""Transcriber — uses mlx-whisper for fast on-device inference on Apple Silicon."""

import numpy as np

# Model options (fastest → most accurate):
#   "mlx-community/whisper-tiny-mlx"      ~fastest, good for short phrases
#   "mlx-community/whisper-base-mlx"      good balance
#   "mlx-community/whisper-small-mlx"     more accurate
#   "mlx-community/whisper-large-v3-mlx"  most accurate, slower
DEFAULT_MODEL = "mlx-community/whisper-base-mlx"


class Transcriber:
    def __init__(self, model_name: str = DEFAULT_MODEL):
        self.model_name = model_name
        self._model_loaded = False
        # Model is loaded lazily on first transcription to keep startup fast.

    def transcribe(self, audio: np.ndarray) -> str:
        """Transcribe a float32 16 kHz audio array. Returns the text string."""
        if audio is None or len(audio) == 0:
            return ""

        # Minimum 0.5 seconds to avoid spurious transcriptions
        if len(audio) < 8_000:
            return ""

        import mlx_whisper  # noqa: PLC0415  (lazy import keeps startup fast)

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model_name,
            verbose=False,
        )

        text: str = result.get("text", "")
        return text.strip()

    @property
    def model_display_name(self) -> str:
        return self.model_name.split("/")[-1].replace("-mlx", "").replace("-", " ").title()
