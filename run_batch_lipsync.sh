#!/bin/bash
# ============================================================================
# Batch Lip-Sync: Process All 10 Kids Efficiently
# ============================================================================
#
# Processes all Kid1..Kid10 portraits through the full pipeline.
# Optimized for cost: loads the MuseTalk model ONCE and processes all kids
# through it sequentially, instead of reloading the 3.4GB model 10 times.
#
# USAGE:
#   bash /workspace/run_batch_lipsync.sh <audio> [pickle] [bbox_shift]
#
# ARGUMENTS:
#   1. audio       — Your audio track (WAV, MP3, etc.)
#   2. pickle      — (Optional) Motion pickle. Default: /workspace/natural_blink.pkl
#   3. bbox_shift  — (Optional) Mouth openness. Default: 0
#
# EXAMPLES:
#   bash /workspace/run_batch_lipsync.sh /workspace/audio.mp3
#   bash /workspace/run_batch_lipsync.sh /workspace/audio.mp3 /workspace/natural_blink.pkl 3
#
# OUTPUT:
#   /workspace/final/Kid1_final.mp4
#   /workspace/final/Kid2_final.mp4
#   ...
#   /workspace/final/Kid10_final.mp4
#
# HOW IT SAVES TIME:
#   Sequential (10 × single):  Model loads 10 times → ~50 min overhead
#   This batch script:         Model loads ONCE → ~5 min overhead
#   Savings:                   ~45 minutes of model loading
#
# ============================================================================

set -e

AUDIO="${1:?ERROR: Provide audio as 1st argument (e.g. /workspace/audio.mp3)}"
PICKLE="${2:-/workspace/natural_blink.pkl}"
BBOX_SHIFT="${3:-0}"

[ ! -f "$AUDIO" ] && echo "❌ Audio not found: $AUDIO" && exit 1
[ ! -f "$PICKLE" ] && echo "❌ Pickle not found: $PICKLE" && exit 1

mkdir -p /workspace/output /workspace/final

AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO")
AUDIO_MINS=$(awk "BEGIN {print int($AUDIO_DURATION / 60)}")

echo ""
echo "============================================"
echo "  🎬 Batch Lip-Sync: All Kids"
echo "============================================"
echo "  Audio:       $AUDIO (${AUDIO_MINS}m)"
echo "  Pickle:      $PICKLE"
echo "  Bbox Shift:  $BBOX_SHIFT"
echo "============================================"
echo ""

# ── Discover all kid portraits ──────────────────────────────────────────────
PORTRAITS=()
for i in {1..10}; do
    for ext in png jpg jpeg PNG JPG JPEG; do
        if [ -f "/workspace/Kid${i}.${ext}" ]; then
            PORTRAITS+=("/workspace/Kid${i}.${ext}")
            break
        fi
    done
done

if [ ${#PORTRAITS[@]} -eq 0 ]; then
    echo "❌ No portraits found! Expected /workspace/Kid1.png, Kid2.png, etc."
    echo "   Looking for: /workspace/Kid{1..10}.{png,jpg,jpeg}"
    exit 1
fi

echo "  Found ${#PORTRAITS[@]} portrait(s):"
for p in "${PORTRAITS[@]}"; do
    echo "    $(basename $p)"
done
echo ""

# ════════════════════════════════════════════════════════════════════════════
# PHASE 1: LivePortrait + Loop ALL kids (fast — ~2 min per kid)
# ════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎭 PHASE 1: Animating + Looping all portraits"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LOOPED_VIDEOS=()
NAMES=()

for IMAGE in "${PORTRAITS[@]}"; do
    NAME=$(basename "$IMAGE" | sed 's/\.[^.]*$//')
    NAMES+=("$NAME")
    ANIMATED="/workspace/output/${NAME}_animated.mp4"
    LOOPED="/workspace/output/${NAME}_looped.mp4"

    # Skip if already looped
    if [ -f "$LOOPED" ]; then
        echo "  [✓] $NAME already animated + looped, skipping"
        LOOPED_VIDEOS+=("$LOOPED")
        continue
    fi

    echo ""
    echo "  [→] Animating $NAME..."
    cd /workspace/LivePortrait
    python inference.py \
        -s "$IMAGE" \
        -d "$PICKLE" \
        --flag_pasteback \
        2>&1 | tail -5

    # Find LivePortrait output
    LP_OUTPUT=$(find /workspace/LivePortrait/animations -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -z "$LP_OUTPUT" ]; then
        LP_OUTPUT=$(find /workspace/LivePortrait -path "*/output/*" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    fi

    if [ -z "$LP_OUTPUT" ]; then
        echo "  ⚠ LivePortrait failed for $NAME, skipping"
        continue
    fi

    cp "$LP_OUTPUT" "$ANIMATED"
    CLIP_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ANIMATED")

    # Loop to match audio
    echo "  [→] Looping $NAME (${CLIP_DURATION}s → ${AUDIO_DURATION}s)..."
    LOOPS=$(awk "BEGIN {print int(($AUDIO_DURATION / $CLIP_DURATION) + 1)}")
    CONCAT_LIST=$(mktemp /workspace/concat_XXXX.txt)
    for j in $(seq 1 $LOOPS); do
        echo "file '$(realpath $ANIMATED)'" >> "$CONCAT_LIST"
    done

    ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" \
        -t "$AUDIO_DURATION" \
        -c copy \
        "$LOOPED" 2>/dev/null

    rm "$CONCAT_LIST"
    LOOPED_VIDEOS+=("$LOOPED")
    echo "  [✓] $NAME animated + looped"
done

echo ""
echo "  ✅ Phase 1 complete: ${#LOOPED_VIDEOS[@]} videos ready for lip-sync"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# PHASE 2: MuseTalk — Lip-sync ALL kids in ONE model load
# ════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗣️  PHASE 2: Lip-syncing all portraits (single model load)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  This processes all kids sequentially but loads the 3.4GB model only ONCE."
echo ""

cd /workspace/MuseTalk

# Build a single YAML config with ALL kids as separate tasks
CONFIG="/workspace/MuseTalk/configs/inference/pipeline_batch.yaml"
echo "# Auto-generated batch config for ${#LOOPED_VIDEOS[@]} portraits" > "$CONFIG"

TASK_NUM=0
for idx in "${!LOOPED_VIDEOS[@]}"; do
    LOOPED="${LOOPED_VIDEOS[$idx]}"
    cat >> "$CONFIG" << EOF
task_${TASK_NUM}:
  video_path: "${LOOPED}"
  audio_path: "${AUDIO}"
  bbox_shift: ${BBOX_SHIFT}
EOF
    TASK_NUM=$((TASK_NUM + 1))
done

echo "  Config written: $CONFIG ($TASK_NUM tasks)"

# Pre-flight checks
UNET_CONFIG="./models/musetalkV15/musetalk.json"
UNET_WEIGHTS="./models/musetalkV15/unet.pth"

if [ ! -f "$UNET_CONFIG" ]; then
    UNET_CONFIG="./models/musetalk/musetalk.json"
    UNET_WEIGHTS="./models/musetalk/pytorch_model.bin"
fi

PREFLIGHT_FAIL=0
for f in "$UNET_CONFIG" "$UNET_WEIGHTS" \
         "./models/face-parse-bisent/79999_iter.pth" \
         "./models/face-parse-bisent/resnet18-5c106cde.pth" \
         "./models/dwpose/dw-ll_ucoco_384.pth" \
         "./models/sd-vae/diffusion_pytorch_model.bin" \
         "./models/whisper/pytorch_model.bin"; do
    if [ ! -f "$f" ]; then
        echo "  ❌ MISSING: $f"
        PREFLIGHT_FAIL=1
    fi
done

if [ $PREFLIGHT_FAIL -eq 1 ]; then
    echo "❌ Missing model files. Re-run: bash /workspace/setup_musetalk.sh"
    exit 1
fi

# Auto-detect batch size
export FFMPEG_PATH=$(which ffmpeg)
VRAM_GB=$(python -c "import torch; print(int(torch.cuda.get_device_properties(0).total_mem / 1e9))" 2>/dev/null || echo "0")
if [ "$VRAM_GB" -ge 40 ]; then
    BATCH_SIZE=32
elif [ "$VRAM_GB" -ge 20 ]; then
    BATCH_SIZE=16
elif [ "$VRAM_GB" -ge 10 ]; then
    BATCH_SIZE=8
else
    BATCH_SIZE=4
fi

echo "  Batch size: $BATCH_SIZE (auto for ${VRAM_GB}GB VRAM)"
echo "  Float16: enabled"
echo ""
echo "  Starting inference (model loads once, processes all tasks)..."
echo "  ────────────────────────────────────────"

python -m scripts.inference \
    --inference_config "$CONFIG" \
    --unet_config "$UNET_CONFIG" \
    --unet_model_path "$UNET_WEIGHTS" \
    --batch_size $BATCH_SIZE \
    --use_float16 \
    2>&1 | tee /workspace/output/batch_musetalk.log

echo "  ────────────────────────────────────────"

# ── Collect results ─────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Collecting results..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Copy all result videos to /workspace/final/
RESULT_COUNT=0
for idx in "${!NAMES[@]}"; do
    NAME="${NAMES[$idx]}"
    LOOPED="${LOOPED_VIDEOS[$idx]}"
    LOOPED_BASE=$(basename "$LOOPED" .mp4)

    # MuseTalk names outputs based on input video + audio names
    RESULT=$(find /workspace/MuseTalk/results -name "${LOOPED_BASE}*" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    if [ -n "$RESULT" ]; then
        FINAL="/workspace/final/${NAME}_final.mp4"
        cp "$RESULT" "$FINAL"
        SIZE=$(ls -lh "$FINAL" | awk '{print $5}')
        echo "  ✅ $NAME → $FINAL ($SIZE)"
        RESULT_COUNT=$((RESULT_COUNT + 1))
    else
        echo "  ⚠  $NAME — no output found"
    fi
done

echo ""
echo "============================================"
echo "  🎉 Batch Complete!"
echo "============================================"
echo ""
echo "  Processed:  $RESULT_COUNT / ${#NAMES[@]} portraits"
echo "  Output dir: /workspace/final/"
echo ""
echo "  Files:"
ls -lh /workspace/final/*_final.mp4 2>/dev/null || echo "  (none)"
echo ""
echo "============================================"
