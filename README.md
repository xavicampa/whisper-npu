# whisper-npu

Whisper (int8, OpenVINO GenAI) on the **Intel NPU**, served by `whisperd` — a
small stdlib-only HTTP server that plugs into [llama-swap](https://github.com/mostlygeek/llama-swap)
as an OpenAI-compatible `POST /v1/audio/transcriptions` backend.

This repo is the **server half** of a push-to-talk dictation setup; the client
(`dictate daemon`: mic capture, energy VAD, clipboard/`wtype` insertion, dim
overlay) lives in the [dotfiles](https://github.com/xavicampa/dotfiles) under
`.config/nixos/homepc/dictation` and just POSTs wav segments here.

## Serving contract

```
GET  /                        -> status json (llama-swap preload hits this)
GET  /health                  -> 200 once the pipeline is loaded (checkEndpoint)
POST /v1/audio/transcriptions -> {"text": "..."}
```

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

The `DICTATE_*` names are shared with the `dictate` client (the env + on-disk
cache contract predates the split; the caches are deliberately common so host
and container keep each other warm).

## Container image

`ghcr.io/xavicampa/whisper-npu:<openvino-base-version>` (e.g. `:2026.4.1`) +
`:latest`, built by [.github/workflows/docker.yml](.github/workflows/docker.yml)
on tag push (the tag is the trigger; the image version comes from the
Containerfile's `FROM openvino/ubuntu24_runtime:<ver>` line).

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

`--init` matters until you add your own tini: as PID 1, whisperd's SIGTERM
handler still works, but `podman stop` semantics are cleaner with init; the
handler itself is required (the kernel won't kill PID 1 with SIG_DFL SIGTERM).

## Standalone

```
pip install .        # deps: numpy, huggingface_hub, openvino-genai==2026.4.*
whisperd --port 5899
```
