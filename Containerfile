# whisperd — Whisper (OpenVINO GenAI, Intel NPU) as an OpenAI-compatible
# llama-swap backend. Images: ghcr.io/xavicampa/whisper-npu:<openvino-base-ver>
# (+ :latest), built by .github/workflows/docker.yml on tag push. Offline/
# hand build (same tag):
#   podman build -t ghcr.io/xavicampa/whisper-npu:2026.4.1 .
# Run on homepc by llama-swap's whisper-medium-int8-npu entry — see the
# `dictate` client (dotfiles .config/nixos/homepc/dictation) + its NOTES.
#
# Base carries the whole NPU userspace stack: openvino 2026.4.1 + NPU plugin +
# intel-level-zero-npu/intel-driver-compiler-npu 1.38.0 — the same compiler
# version as the host's intel-npu-driver overlay pin, so the host's
# ~/.cache/dictation/npu-cache blobs stay warm across nix <-> container (the
# cache keys on the compiler, not OpenVINO). Bump the base and the host pin
# together, and keep pyproject's openvino-genai pin in the same series (the
# workflow checks it).
FROM docker.io/openvino/ubuntu24_runtime:2026.4.1
# stock image runs as UID 1000; root lets pip write /opt/venv, and under
# rootless podman container-root == the host user, which keeps the /data/cache
# bind-mount writable.
USER root
COPY . /opt/whisper-npu/
RUN python3 -m pip install --no-cache-dir /opt/whisper-npu
ENV DICTATE_CACHE_DIR=/data/cache
CMD ["whisperd", "--port", "5812"]
