# AGENTS.md

Guidance for AI agents working in this repo. Read the code comments too — most of
the operational lore (cache warming, PID-1 signals, config patching) lives there,
not in the README.

## What this is

Whisper speech-to-text (int8 OpenVINO GenAI export) on the **Intel NPU**, served
by `whisperd`, a **stdlib-only** HTTP server that llama-swap treats as an
OpenAI-compatible `POST /v1/audio/transcriptions` backend.

This is the **server half** of a push-to-talk dictation setup. The client
(`dictate daemon`: mic capture, energy VAD, clipboard/`wtype` paste, dim overlay)
is **not in this repo** — it lives in
[dotfiles](https://github.com/xavicampa/dotfiles) under
`.config/nixos/homepc/dictation`, along with the llama-swap entry and the NixOS
NPU driver overlay. See "Outside this repo" below.

## Layout

```
whisper_npu/whisperd.py   transport: argparse, http.server, multipart, WAV, signals
whisper_npu/engine.py     inference: HF download, config patch, NPU compile
whisper_npu/__init__.py   version string only (keep import-cheap)
Containerfile             image, FROM openvino/ubuntu24_runtime:<ver>
pyproject.toml            deps + `whisperd` console script
.github/workflows/docker.yml   the only CI: tag push -> GHCR image
```

Two modules, deliberately. Keep the transport/inference split: `whisperd.py`
must not import `openvino_genai` or `huggingface_hub` (both are lazy-imported
inside `engine.build_pipeline`, engine.py:32-35) so CLI startup and `--help`
stay cheap. `numpy` is currently imported at module top level (whisperd.py:42)
despite the note in `__init__.py:3` — don't add more heavy top-level imports.

## Commands

```
pip install .          # then: whisperd --port 5899
whisperd --host 127.0.0.1 --port 5899    # PORT env also honored
podman build -t ghcr.io/xavicampa/whisper-npu:2026.4.1 .
```

There is **no test suite, no linter, no type checker, no formatter, no Makefile,
no lockfile** in this repo. Don't invent commands; verify changes by running
`whisperd` standalone and curling the endpoints (see README for the podman
invocation with `--device /dev/accel/accel0`).

Serving contract: `GET /` status JSON (llama-swap preload probe) · `GET /health`
200 once loaded, else 503 · `POST /v1/audio/transcriptions` -> `{"text": "..."}`.
Everything else is 404.

## Invariants — do not break these

1. **Three-way version lockstep.** Containerfile's
   `FROM openvino/ubuntu24_runtime:<ver>` ↔ pyproject's
   `openvino-genai==<series>.*` ↔ the **host's** `intel-npu-driver` overlay pin
   (in dotfiles; currently compiler 1.38.0). CI checks only the first two
   (docker.yml:28-32). The NPU compile cache keys on the **compiler version, not
   OpenVINO**, so breaking the third silently invalidates the shared
   `npu-cache` and every request pays a ~70 s recompile. Bump all three together
   and say so in the commit message.
2. **The HF cache is mutated in place.** engine.py:56-63 deletes
   `forced_decoder_ids` from the *downloaded snapshot's* `generation_config.json`
   — chmod to 0o644 then write, because HF blobs are read-only and snapshots are
   symlinks to them, so this **writes through to the shared blob** used by the
   dictate client and anything else on the host. Without this patch,
   `task=translate` silently never fires (the export hard-pins `<|transcribe|>`).
   Preserve this behaviour if you touch model loading.
3. **`HTTPServer` is single-threaded on purpose.** The per-request
   `engine.set_task_language()` mutation of the pipeline's generation config is
   only lock-free-safe because one request is served at a time
   (engine.py:82-84, whisperd.py:19-20). Swapping in `ThreadingHTTPServer`
   requires locking.
4. **The SIGTERM handler is required, not cosmetic.** The kernel never kills
   PID 1 with a `SIG_DFL` signal, so without an installed handler `podman stop`
   burns the whole `-t` timeout and SIGKILLs. `srv.shutdown()` cannot run on the
   `serve_forever` thread, hence the helper thread (whisperd.py:186-192).
5. **`RLIMIT_MEMLOCK` is raised to infinity in `build_pipeline`**
   (engine.py:43-49). llama-swap spawns whisperd as a systemd *system* service,
   which starts from the 8 MiB default, and the level-zero NPU compiler mlocks
   its DMA/weight buffers. Keep the soft-limit-only raise + the fallback log if the hard limit
   isn't infinity.
6. **`response_format` is `json` only, audio is PCM16 mono 16 kHz WAV only**
   (whisperd.py:85-90, 139-141). Anything else is a 400 by design — there is no
   decoder/resampler in a stdlib-only server and the only client is our own
   daemon. Don't "improve" this into a general OpenAI-compatible endpoint
   without being asked.
7. **`catch-all except Exception` in `do_POST`** (whisperd.py:159) keeps one bad
   segment from killing the backend. Don't narrow it.

## Gotchas

- **Model load failure does not exit.** `main()` logs, sets `state.error`, keeps
  serving, `/health` returns 503 forever, and the process still exits 0 on
  shutdown (whisperd.py:178-182). llama-swap sees the failed healthcheck; the
  process reports success. Intentional, but easy to misread.
- **Model snapshots use huggingface_hub's *default* cache** (`~/.cache/huggingface/hub`,
  bind-mounted from the host), *not* `DICTATE_CACHE_DIR`. Only the NPU compile
  cache lives at `$DICTATE_CACHE_DIR/npu-cache`.
- **Ports disagree by design:** `DEFAULT_PORT = 5899` (standalone), Containerfile
  `CMD whisperd --port 5812`, llama-swap passes `${PORT}`. llama-swap always
  passes `--port`, so this is benign — don't "unify" it.
- **Env var names are `DICTATE_*`, not `WHISPER_*`**, shared with the client.
  The cache dirs are deliberately common so host and container keep each other
  warm. Renaming them breaks that contract.
- **`wave` is a PEP 594 dead battery**, slated for removal in 3.15. The project
  already runs on 3.14 and requires >=3.11, and already had to work around one
  removal (`cgi`, gone in 3.13 — hence the hand-rolled `parse_multipart` using
  `email.BytesParser`). Keep this in mind for future Python bumps.
- **Full request body is buffered into memory** (whisperd.py:138). Fine for
  short dictation segments, not for arbitrary clients.
- **Git tags are release triggers, not versions.** Tag `v2026.4.1` is the
  OpenVINO base version; package version is `0.1.0`. The image tag is derived
  from the Containerfile `FROM` line, not from the git tag.
- The `whisper-*-turbo-*-ov` exports ignore `task=translate` in GenAI 2026.4
  (int8 *and* fp16, NPU *and* CPU) — engine.py:69-71. `whisper-medium-int8-ov`
  handles it correctly, which is why medium is the default. Don't switch models
  without checking.

## Outside this repo (can't be fixed from here)

Behaviour depends on three things in the dotfiles repo:
`dictate daemon` (the client), the llama-swap `whisper-medium-int8-npu` entry
(`configuration.nix`), and the `intel-npu-driver` overlay pin. A change here may
need a matching change there — flag it rather than assume it's covered.

## Style

Comments carry the *why*, including dead ends and version-specific bugs. Match
that: when you add a workaround, state what it works around and where it breaks.
Module docstrings are user-facing (`main()` builds the `--help` description from
`__doc__.splitlines()[0]`).
