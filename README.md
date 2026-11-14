# whisper-npu

Whisper (int8, OpenVINO GenAI) on the **Intel NPU**, served by `whisperd` — a
small stdlib-only HTTP server that plugs into [llama-swap](https://github.com/mostlygeek/llama-swap)
as an OpenAI-compatible `POST /v1/audio/transcriptions` backend.

This repo is the **server half** of a push-to-talk dictation setup; the client
(`dictate daemon`: mic capture, energy VAD, clipboard/`wtype` insertion, dim
overlay) lives in the [dotfiles](https://github.com/xavicampa/dotfiles) under
`.config/nixos/homepc/dictation` and just POSTs wav segments here.

## Requirements

- **Intel NPU, on Linux.** The image carries the userspace stack (OpenVINO
  runtime + NPU plugin + level-zero compiler) but not the driver: the host
  must have Intel's NPU kernel driver + firmware exposing `/dev/accel/accel0`
  (homepc: the `intel-npu-driver` overlay pin in dotfiles). Containers pass
  the device through (`--device /dev/accel/accel0`).
- **Host driver and image compiler in the same version** (currently 1.38.0):
  host and container share `npu-cache`, which keys on the compiler, not on
  OpenVINO. Drift doesn't fail — it silently invalidates the cache and every
  request pays the ~70 s recompile (see Container image below).
- **Python ≥ 3.11** for the standalone path — which needs the host NPU
  driver too; only the container path keeps the NPU stack out of your host
  Python. (`RLIMIT_MEMLOCK` is raised by whisperd itself; the default hard
  limit on Linux is fine.)
- **Network on first run** to pull the export from Hugging Face
  (`~/.cache/huggingface/hub`); after that, warm-cache loads are ~10 s and
  offline.

## Serving contract

```
GET  /                        -> status json (llama-swap preload hits this)
GET  /health                  -> 200 once the pipeline is loaded, else 503 (checkEndpoint)
POST /v1/audio/transcriptions -> {"text": "..."}; 400 bad audio/response_format,
                                 503 while the model isn't loaded
anything else                 -> 404
```

Model load failure is not fatal: whisperd logs it, keeps serving, `/health`
stays 503 and POSTs answer 503 — and the process still exits 0 on shutdown.
llama-swap sees the failed healthcheck; the process reports success.

- Audio: **PCM16 mono 16 kHz wav** only (the client's format; anything else is
  a 400 — no decoder in a stdlib-only server).
- Multipart fields: `file`, `model` (llama-swap routing), `task`
  (`translate`/`transcribe`), `language` (whisper code, empty = auto),
  `response_format=json` (only).
- Single-threaded by design: one segment at a time, no locks around the pipeline.

## Env

| Var | Meaning | Default |
|---|---|---|
| `DICTATE_MODEL` | HF id of the OpenVINO whisper export | `OpenVINO/whisper-medium-int8-ov` |
| `DICTATE_CACHE_DIR` | NPU compile-cache root (`$DIR/npu-cache`) | `~/.cache/dictation` (`/data/cache` in the image) |
| `DICTATE_TASK` / `DICTATE_LANGUAGE` | default task/language | empty (model default / auto) |
| `PORT` | fallback for `--port` (CLI flag wins; llama-swap always passes `--port`) | 5899 standalone, 5812 in the image CMD |

The `DICTATE_*` names are shared with the `dictate` client (the env + on-disk
cache contract predates the split; the caches are deliberately common so host
and container keep each other warm).

## Container image

`ghcr.io/xavicampa/whisper-npu:<openvino-base-version>` (e.g. `:2026.4.1`) +
`:latest`, built by [.github/workflows/docker.yml](.github/workflows/docker.yml)
on a `v*` tag push (the tag is just the trigger — any tag matching `v*` works;
the image version comes from the Containerfile's
`FROM openvino/ubuntu24_runtime:<ver>` line) or manually via workflow_dispatch.

The base image is not incidental: it carries the OpenVINO runtime + NPU plugin
+ level-zero NPU compiler. The NPU compile cache (`npu-cache`) keys on the
**compiler version**, so a consumer that shares its host `npu-cache` with this
image must keep the base's compiler pinned in lockstep with the host driver —
the reason the tag follows the OpenVINO version.

Run under llama-swap (the working homepc `cmd`):

```
podman run --replace --init --name ${MODEL_ID}
  --network host
  --device /dev/accel/accel0
  -v ~/.cache/dictation:/data/cache
  -v ~/.cache/huggingface/hub:/root/.cache/huggingface/hub
  -e DICTATE_MODEL=OpenVINO/whisper-medium-int8-ov
  -e DICTATE_TASK=translate
  ghcr.io/xavicampa/whisper-npu:2026.4.1
  whisperd --port ${PORT}
```

What makes `podman stop` graceful is whisperd's installed SIGTERM handler: the
kernel never kills PID 1 with a default-disposition signal, so without a
handler the stop signal is simply ignored and podman burns the whole `-t`
timeout before SIGKILLing. `--init` (or your own tini) only adds cleaner
signal/proxy semantics on top — it is not what makes shutdown work.

## Standalone

```
pip install .        # deps: numpy, huggingface_hub, openvino-genai==2026.4.*
whisperd --port 5899
```
