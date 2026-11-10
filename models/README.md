# Model installation (no weights in git)

OCA is fully usable without any models (AGENTS rule 3). Models are **optional,
side-loaded, and never committed to this repository**.

Layout (created on demand):

```
~/.oca/models/
├── llm/           # GGUF models for llama-server (local generation)
├── embeddings/    # small embedding model for RAG (Phase 11)
└── whisper/       # whisper.cpp models for dictation (Phase 7B)
```

Rules (architecture A7/A8):

- Runtime packs (`llama-server`, whisper) install via `oca runtime install --from <file>`
  so offline side-loading is first-class (lands Phase 7).
- Every pack and model ships a **SHA-256 manifest**; `oca doctor` verifies it.
- One heavy model resident at a time by default (LLM *or* embeddings *or* whisper).
- `oca doctor` recommends a size class from hardware tiers (Lite / Standard /
  Comfortable) — pick by RAM/VRAM, not by model name.
- No telemetry, no downloads without an explicit user action.

## Fetching models: `scripts/fetch-models.sh`

The one script does the tier arithmetic for you — it reads the same RAM
thresholds as `oca doctor` (ADR-0008), offers **lite / standard / advanced**,
and downloads one file per slot above:

```sh
./scripts/fetch-models.sh            # detect hardware, prompt for a tier
./scripts/fetch-models.sh --list     # show the whole manifest first
./scripts/fetch-models.sh --tier standard --dry-run
```

| Tier | RAM | LLM (Q4_K_M) | Whisper |
| --- | --- | --- | --- |
| lite | < 16 GB | Qwen2.5-3B (~1.8 GiB) | `ggml-base` |
| standard | 16–31 GB | Qwen2.5-7B (~4.4 GiB) | `ggml-small` |
| advanced | ≥ 32 GB | Qwen2.5-32B (~18.5 GiB) | `ggml-small` |

Every tier also gets `nomic-embed-text-v1.5` (~262 MiB) for hybrid search —
embeddings-only mode needs no LLM at all. Files are size-checked as they
land, recorded in `~/.oca/models/manifest.sha256`, skipped when already
present, and resumed when interrupted. Edit the manifest in the script to
substitute models: tiers, not model names.

The script is the *explicit user action* this rule allows — nothing in `oca`
itself ever reaches the network.
