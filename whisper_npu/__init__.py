"""whisper-npu — Whisper (OpenVINO GenAI, Intel NPU) as a llama-swap backend.

Keep this module import-cheap: `whisperd --help` must not pull numpy/openvino.
"""

__version__ = "0.1.0"
