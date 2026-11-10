#!/usr/bin/env bash
# Fetch OCA model files sized to this machine's hardware — the "model files"
# half of INSTALL.md step 6 (the runtime half stays `oca runtime install`).
#
# This is the explicit user action that rule allows: OCA itself never touches
# the network, and nothing is committed to git — weights land in
# ~/.oca/models/{llm,embeddings,whisper} and nowhere else.
#
# Tiers mirror `oca doctor`'s hardware row (crates/oca-ai/src/hardware.rs,
# ADR-0008): Lite < 16 GB RAM ≤ Standard < 32 GB ≤ Comfortable. This script
# calls them lite / standard / advanced. Tiers, not model names — swap the
# manifest below for whatever your machine prefers.
#
# Usage: scripts/fetch-models.sh [options]
#   --tier lite|standard|advanced   don't prompt; take this tier
#   --list                          print the manifest for every tier and exit
#   --dry-run                       show what would be fetched, fetch nothing
#   --yes                           accept the detected tier without prompting
#   --verify                        re-check files already on disk, then exit
#   --no-embeddings                 skip ~/.oca/models/embeddings
#   --no-whisper                    skip ~/.oca/models/whisper
#   --only SLOT                     fetch just one slot: llm | embeddings | whisper
#   --dest DIR                      models root (default ~/.oca/models)
#   -h, --help                      this text
#
# Safe to re-run: complete files are skipped, interrupted downloads resume.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$HOME/.oca/models"
TIER=""
ONLY=""
LIST=0 DRY=0 ASSUME_YES=0 VERIFY=0 WANT_EMBED=1 WANT_WHISPER=1

usage() { sed -n '14,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier) TIER="${2:?--tier needs a value}"; shift 2 ;;
        --tier=*) TIER="${1#*=}"; shift ;;
        --only) ONLY="${2:?--only needs a value}"; shift 2 ;;
        --only=*) ONLY="${1#*=}"; shift ;;
        --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
        --dest=*) DEST="${1#*=}"; shift ;;
        --list) LIST=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --verify) VERIFY=1; shift ;;
        --no-embeddings) WANT_EMBED=0; shift ;;
        --no-whisper) WANT_WHISPER=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option $1 (try --help)" >&2; exit 2 ;;
    esac
done

# --- manifest ---------------------------------------------------------------
# tier|repo|file|bytes — sizes are Content-Length as served today; a mismatch
# means upstream reshuffled and the download fails loudly instead of landing
# a file OCA would happily discover.
BASE_HF="https://huggingface.co"
llm_for() {
    case "$1" in
        lite)     echo "bartowski/Qwen2.5-3B-Instruct-GGUF|Qwen2.5-3B-Instruct-Q4_K_M.gguf|1929903264" ;;
        standard) echo "bartowski/Qwen2.5-7B-Instruct-GGUF|Qwen2.5-7B-Instruct-Q4_K_M.gguf|4683074240" ;;
        advanced) echo "bartowski/Qwen2.5-32B-Instruct-GGUF|Qwen2.5-32B-Instruct-Q4_K_M.gguf|19851336576" ;;
    esac
}
# One embedding model for every tier — 274 MB, and embeddings-only mode needs
# no LLM at all (Phase 11).
EMBED="nomic-ai/nomic-embed-text-v1.5-GGUF|nomic-embed-text-v1.5.f16.gguf|274290560"
# Dictation quality tracks available RAM: tiny machines get base, the rest small.
whisper_for() {
    case "$1" in
        lite) echo "ggerganov/whisper.cpp|ggml-base.bin|147951465" ;;
        *)    echo "ggerganov/whisper.cpp|ggml-small.bin|487601967" ;;
    esac
}
TIERS="lite standard advanced"
describe_tier() {
    case "$1" in
        lite)     echo "Lite — models up to ~4B" ;;
        standard) echo "Standard — ~7–9B" ;;
        advanced) echo "Comfortable — 14–32B" ;;
    esac
}

human() { # bytes -> "4.4 GiB"
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%.0f %s" : "%.1f %s"), b, u[i]
    }'
}

# File size in bytes — GNU stat first, BSD/macOS second (perf.sh already
# bridges this same GNU/BSD gap for `date`).
fsize() {
    local s
    s=$(stat -c%s "$1" 2>/dev/null) || s=$(stat -f%z "$1" 2>/dev/null) || s=0
    echo "$s"
}

# --- hardware (same thresholds as oca-ai's Hardware::tier) -------------------
detect_ram_bytes() {
    local kb=""
    if [[ -r /proc/meminfo ]]; then
        kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    elif command -v sysctl >/dev/null 2>&1; then
        kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
    fi
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    echo $(( kb * 1024 ))
}
detect_cores() { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1; }
detect_vram_mb() {
    command -v nvidia-smi >/dev/null 2>&1 || { echo 0; return; }
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
        | awk '{s += $1} END {print s + 0}'
}
tier_for_ram() { # mirrors Hardware::tier(); "" when detection failed
    case "$1" in
        0)      echo "" ;;
        *)      if   (( $1 >= 32000000000 )); then echo advanced
                elif (( $1 >= 16000000000 )); then echo standard
                else echo lite; fi ;;
    esac
}

# --- output helpers ---------------------------------------------------------
step() { printf '\n== %s ==\n' "$1"; }
err()  { echo "error: $*" >&2; exit 1; }

# --- --list -----------------------------------------------------------------
if [[ $LIST -eq 1 ]]; then
    printf '%-9s %-9s %10s  %s\n' TIER RAM MODEL "file -> destination"
    for t in $TIERS; do
        case "$t" in
            lite) ram="8 GB" ;;
            standard) ram="16–31 GB" ;;
            advanced) ram="32 GB+" ;;
        esac
        IFS='|' read -r repo file bytes <<<"$(llm_for "$t")"
        printf '%-9s %-9s %10s  %s\n' "$t" "$ram" "$(human "$bytes")" \
            "$file -> $DEST/llm/"
        IFS='|' read -r repo file bytes <<<"$(whisper_for "$t")"
        printf '%-9s %-9s %10s  %s\n' "" "" "$(human "$bytes")" \
            "$file -> $DEST/whisper/   (dictation)"
    done
    IFS='|' read -r repo file bytes <<<"$EMBED"
    printf '%-9s %-9s %10s  %s\n' "all" "" "$(human "$bytes")" \
        "$file -> $DEST/embeddings/   (hybrid search)"
    echo
    echo "All: one GGUF per slot; OCA discovers whatever *.gguf sits in each"
    echo "directory (whisper also accepts legacy *.bin). Edit the manifest in"
    echo "$0 to substitute models — tiers, not model names (ADR-0008)."
    exit 0
fi

# --- detect hardware --------------------------------------------------------
RAM_BYTES=$(detect_ram_bytes)
CORES=$(detect_cores)
VRAM_MB=$(detect_vram_mb)
DETECTED=$(tier_for_ram "$RAM_BYTES")

# Same arithmetic as Hardware::ram_gb (decimal GB) so this line matches
# `oca doctor` byte for byte.
gb() { echo $(( $1 / 1000000000 )); }

if [[ -n "$DETECTED" ]]; then
    hw_line="$(gb "$RAM_BYTES") GB RAM × $CORES cores → $(describe_tier "$DETECTED")"
else
    hw_line="RAM unknown × $CORES cores → tier must be chosen by hand"
fi
[[ "$VRAM_MB" -gt 0 ]] && hw_line+=" · $((VRAM_MB / 1024)) GB VRAM (GPU layers are yours to configure)"

echo "OCA model fetch"
echo "  hardware: $hw_line"

# --- choose the tier --------------------------------------------------------
TIER_NOTE=""
if [[ -n "$TIER" ]]; then
    case "$TIER" in
        lite|standard|advanced) ;;
        Comfortable|comfortable) TIER=advanced ;;   # accept oca's own name
        Standard) TIER=standard ;;
        Lite) TIER=lite ;;
        *) err "unknown tier '$TIER' (expected lite, standard or advanced)" ;;
    esac
elif [[ $ASSUME_YES -eq 1 || ! -t 0 ]]; then
    if [[ -n "$DETECTED" ]]; then
        TIER="$DETECTED"
        TIER_NOTE=" (detected; pass --tier to override)"
    else
        err "RAM undetectable and no --tier given — rerun with --tier lite|standard|advanced"
    fi
else
    echo
    echo "Choose a tier (press Enter for the detected one):"
    for i in 1 2 3; do
        t=$(echo "$TIERS" | cut -d' ' -f"$i")
        mark=""
        [[ "$t" == "$DETECTED" ]] && mark="  <- detected"
        printf '  %d) %-9s %s%s\n' "$i" "$t" "$(describe_tier "$t")" "$mark"
    done
    reply=""
    read -r -p "> " reply </dev/tty || true
    case "$reply" in
        "") TIER="${DETECTED:-}" ;;
        1|lite) TIER=lite ;;
        2|standard) TIER=standard ;;
        3|advanced|comfortable) TIER=advanced ;;
        *) err "unexpected answer '$reply' (use --tier lite|standard|advanced)" ;;
    esac
    [[ -n "$TIER" ]] || err "no tier selected"
fi
echo "  tier:    $TIER — $(describe_tier "$TIER")$TIER_NOTE"

case "$ONLY" in
    ""|llm|embeddings|whisper) ;;
    *) err "unknown slot '$ONLY' (expected llm, embeddings or whisper)" ;;
esac

# --- plan -------------------------------------------------------------------
plan=()   # "url|dest|bytes"
add() { plan+=("$1|$2|$3"); }
if [[ -z "$ONLY" || "$ONLY" == llm ]]; then
    IFS='|' read -r repo file bytes <<<"$(llm_for "$TIER")"
    add "$BASE_HF/$repo/resolve/main/$file" "$DEST/llm/$file" "$bytes"
fi
if [[ ( -z "$ONLY" || "$ONLY" == embeddings ) && $WANT_EMBED -eq 1 ]]; then
    IFS='|' read -r repo file bytes <<<"$EMBED"
    add "$BASE_HF/$repo/resolve/main/$file" "$DEST/embeddings/$file" "$bytes"
fi
if [[ ( -z "$ONLY" || "$ONLY" == whisper ) && $WANT_WHISPER -eq 1 ]]; then
    IFS='|' read -r repo file bytes <<<"$(whisper_for "$TIER")"
    add "$BASE_HF/$repo/resolve/main/$file" "$DEST/whisper/$file" "$bytes"
fi
[[ ${#plan[@]} -gt 0 ]] || err "nothing to fetch (that slot is disabled)"

need=0 have=0
for entry in "${plan[@]}"; do
    IFS='|' read -r url path bytes <<<"$entry"
    if [[ -f "$path" ]] && [[ "$(fsize "$path")" == "$bytes" ]]; then
        have=$(( have + bytes ))
    else
        need=$(( need + bytes ))
    fi
done

step "Plan"
for entry in "${plan[@]}"; do
    IFS='|' read -r url path bytes <<<"$entry"
    if [[ -f "$path" ]] && [[ "$(fsize "$path")" == "$bytes" ]]; then
        printf '  skip  %-40s %s (present)\n' "$(basename "$path")" "$(human "$bytes")"
    else
        printf '  fetch %-40s %s\n' "$(basename "$path")" "$(human "$bytes")"
    fi
done
echo "  total: $(human "$need") to download ($(human "$have") already on disk)"

if [[ $VERIFY -eq 1 ]]; then
    step "Verify"
    bad=0
    for entry in "${plan[@]}"; do
        IFS='|' read -r url path bytes <<<"$entry"
        if [[ -f "$path" ]] && [[ "$(fsize "$path")" == "$bytes" ]]; then
            echo "  ok   $(basename "$path")"
        else
            echo "  FAIL $(basename "$path") — missing or wrong size"; bad=1
        fi
    done
    [[ $bad -eq 0 ]] || err "verification failed — re-run without --verify to refetch"
    exit 0
fi

if [[ $DRY -eq 1 ]]; then
    echo
    echo "dry run — nothing fetched."
    exit 0
fi
if [[ $need -eq 0 ]]; then
    echo
    echo "Everything for tier '$TIER' is already installed."
    exit 0
fi

# --- disk space -------------------------------------------------------------
mkdir -p "$DEST/llm" "$DEST/embeddings" "$DEST/whisper"
avail=$(df -B1 --output=avail "$DEST" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)
if ! [[ "$avail" =~ ^[0-9]+$ ]]; then
    # BSD/macOS df has no --output; -Pk reports 1024-blocks.
    avail=$(df -Pk "$DEST" 2>/dev/null | awk 'NR==2 {print $4 * 1024}' || echo 0)
fi
[[ "$avail" =~ ^[0-9]+$ ]] || avail=0
if (( avail > 0 && avail < need )); then
    err "not enough space: need $(human "$need"), $(human "$avail") free on $(dirname "$DEST")"
fi

# --- download ---------------------------------------------------------------
fetch() { # url dest expected
    local url="$1" dest="$2" expect="$3" part have
    part="$dest.part"
    if [[ -f "$dest" ]]; then
        have=$(fsize "$dest")
        if [[ "$have" == "$expect" ]]; then return 0; fi
        echo "  $(basename "$dest") is $(human "$have"), expected $(human "$expect") — refetching"
        rm -f "$dest"
    fi
    echo "  → $(basename "$dest") ($(human "$expect"))"
    local curl_opts=(-fL --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o "$part")
    if [[ -t 2 ]]; then curl_opts+=(--progress-bar); else curl_opts+=(-sS); fi
    if ! curl "${curl_opts[@]}" "$url"; then
        rm -f "$part"
        err "download failed: $url
       (partial file removed — re-run to retry)"
    fi
    have=$(fsize "$part")
    if [[ "$have" != "$expect" ]]; then
        rm -f "$part"
        err "size mismatch for $(basename "$dest"): got $(human "$have"), expected $(human "$expect")
       upstream may have replaced the file — update the manifest in $0"
    fi
    mv "$part" "$dest"
    # Record what landed: models/README.md promises a SHA-256 manifest.
    # Rewrite (not append) so a refetch never duplicates its own entry.
    if command -v sha256sum >/dev/null 2>&1; then
        mkdir -p "$DEST"
        if [[ -f "$DEST/manifest.sha256" ]]; then
            grep -vF "  $dest" "$DEST/manifest.sha256" > "$DEST/manifest.sha256.tmp" || true
            mv "$DEST/manifest.sha256.tmp" "$DEST/manifest.sha256"
        fi
        sha256sum "$dest" >> "$DEST/manifest.sha256"
    fi
}

step "Fetch (resumable — Ctrl-C, re-run, it continues)"
for entry in "${plan[@]}"; do
    IFS='|' read -r url path bytes <<<"$entry"
    fetch "$url" "$path" "$bytes"
done

# --- report -----------------------------------------------------------------
step "Installed"
for entry in "${plan[@]}"; do
    IFS='|' read -r url path bytes <<<"$entry"
    printf '  %-14s %s (%s)\n' "$(basename "$(dirname "$path")")/" "$(basename "$path")" "$(human "$bytes")"
done
[[ -f "$DEST/manifest.sha256" ]] && echo "  sha256: $DEST/manifest.sha256"

echo
echo "Next steps:"
if command -v oca >/dev/null 2>&1; then
    echo "  oca doctor          # Models row should now be green"
else
    echo "  ./scripts/install.sh   # build/install the oca binary first"
fi
CFG="$HOME/.oca/config.toml"
if [[ -f "$CFG" ]] && grep -Eq '^[[:space:]]*mock[[:space:]]*=[[:space:]]*true' "$CFG"; then
    echo
    echo "  NOTE: $CFG has 'mock = true' — OCA will keep using the built-in"
    echo "  scripted model and IGNORE these files until you turn it off:"
    echo "      sed -i 's/mock = true/mock = false/' $CFG"
fi
if ! command -v whisper-cli >/dev/null 2>&1 && ! ls "$HOME"/.oca/runtime/*/whisper-cli >/dev/null 2>&1; then
    echo
    echo "  Dictation needs the whisper runtime too (models alone are not enough):"
    echo "      oca runtime install --from oca-runtime-<platform>.tar.gz"
fi
