#!/bin/bash
# ============================================================================
# Lip-Sync Pipeline: Portrait → Animate → Loop → Lip Sync (LatentSync)
# ============================================================================
#
# Takes a still image, animates it (blink + head), loops it to match your
# audio length, then syncs the lips to the audio using LatentSync.
#
# USAGE:
#   bash /workspace/run_lipsync_pipeline.sh <image> <audio> [pickle] [steps]
#
# ARGUMENTS:
#   1. image       — Your portrait image (PNG, JPG, etc.)
#   2. audio       — Your audio track (WAV, MP3, FLAC, M4A — anything FFmpeg reads)
#   3. pickle      — (Optional) Motion pickle file. Default: /workspace/natural_blink.pkl
#   4. steps       — (Optional) LatentSync inference steps 20-50. Default: 25
#
# EXAMPLES:
#   # Basic — uses default pickle and quality settings
#   bash /workspace/run_lipsync_pipeline.sh /workspace/Kid1.png /workspace/5min.mp3
#
#   # Custom pickle + higher quality
#   bash /workspace/run_lipsync_pipeline.sh /workspace/Kid1.png /workspace/5min.mp3 /workspace/natural_blink.pkl 40
#
#   # Batch all 10 kids (use the batch script instead)
#   bash /workspace/run_batch_lipsync.sh /workspace/5min.mp3
#
# OUTPUT:
#   /workspace/final/<name>_final.mp4
#
# ============================================================================

set -e

# ── Parse Arguments ─────────────────────────────────────────────────────────
IMAGE="${1:?ERROR: Provide image as 1st argument (e.g. /workspace/Kid1.png)}"
AUDIO="${2:?ERROR: Provide audio as 2nd argument (e.g. /workspace/5min.mp3)}"
PICKLE="${3:-/workspace/natural_blink.pkl}"
STEPS="${4:-25}"

# ── Validate ────────────────────────────────────────────────────────────────
[ ! -f "$IMAGE" ] && echo "❌ Image not found: $IMAGE" && exit 1
[ ! -f "$AUDIO" ] && echo "❌ Audio not found: $AUDIO" && exit 1
[ ! -f "$PICKLE" ] && echo "❌ Pickle not found: $PICKLE" && exit 1

# ── Derive names ────────────────────────────────────────────────────────────
# "Kid1.png" → "Kid1"
NAME=$(basename "$IMAGE" | sed 's/\.[^.]*$//')

mkdir -p /workspace/output
mkdir -p /workspace/final

# Get audio duration (this is our target length)
AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO")
AUDIO_MINS=$(awk "BEGIN {print int($AUDIO_DURATION / 60)}")
AUDIO_SECS=$(awk "BEGIN {printf \"%.1f\", $AUDIO_DURATION - ($AUDIO_MINS * 60)}")

echo ""
echo "============================================"
echo "  🎬 Lip-Sync Pipeline: $NAME"
echo "============================================"
echo "  Image:       $IMAGE"
echo "  Audio:       $AUDIO  (${AUDIO_MINS}m ${AUDIO_SECS}s)"
echo "  Pickle:      $PICKLE"
echo "  LatentSync:  ${STEPS} steps (20=fast, 40=quality)"
echo "============================================"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# STEP 1: LivePortrait — Create animated clip with blink + head movement
# ════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎭 STEP 1/3: Animating portrait (LivePortrait)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ANIMATED="/workspace/output/${NAME}_animated.mp4"

cd /workspace/LivePortrait

python inference.py \
    -s "$IMAGE" \
    -d "$PICKLE" \
    --flag_pasteback \
    2>&1 | tail -10

# LivePortrait saves to its own output dir — find the latest .mp4
LP_OUTPUT=$(find /workspace/LivePortrait/animations -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$LP_OUTPUT" ]; then
    LP_OUTPUT=$(find /workspace/LivePortrait -path "*/output/*" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
fi

if [ -z "$LP_OUTPUT" ]; then
    echo "❌ LivePortrait didn't produce output."
    echo "   Check the errors above, then try running manually:"
    echo "   cd /workspace/LivePortrait && python inference.py -s $IMAGE -d $PICKLE"
    exit 1
fi

cp "$LP_OUTPUT" "$ANIMATED"
CLIP_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ANIMATED")
echo ""
echo "✅ Animated clip: $ANIMATED (${CLIP_DURATION}s)"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# STEP 2: Loop the animated clip to match audio length
# ════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔁 STEP 2/3: Looping clip to match audio (${AUDIO_MINS}m ${AUDIO_SECS}s)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LOOPED="/workspace/output/${NAME}_looped.mp4"
LOOPS=$(awk "BEGIN {print int(($AUDIO_DURATION / $CLIP_DURATION) + 1)}")
echo "  Clip: ${CLIP_DURATION}s × ${LOOPS} loops → trimmed to ${AUDIO_DURATION}s"

# Build concat list
CONCAT_LIST=$(mktemp /workspace/concat_XXXX.txt)
for i in $(seq 1 $LOOPS); do
    echo "file '$(realpath $ANIMATED)'" >> "$CONCAT_LIST"
done

# Loop and trim to exact audio length (doesn't need to be a perfect multiple)
ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" \
    -t "$AUDIO_DURATION" \
    -c copy \
    "$LOOPED" 2>/dev/null

rm "$CONCAT_LIST"

LOOPED_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$LOOPED")
echo "✅ Looped video: $LOOPED (${LOOPED_DURATION}s)"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# STEP 3: LatentSync — Sync lips to the audio
# ════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗣️  STEP 3/3: Lip-syncing with LatentSync"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  LatentSync 1.6 (ByteDance) — 512×512 latent diffusion lip sync"
echo "  Steps: $STEPS (higher = better quality, slower)"
echo ""

FINAL="/workspace/final/${NAME}_final.mp4"

# Use the LatentSync wrapper (handles auto-chunking for long videos)
bash /workspace/run_latentsync.sh "$LOOPED" "$AUDIO" "$FINAL" "$STEPS"

echo ""
echo "============================================"
echo "  🎉 Done! $NAME"
echo "============================================"
echo ""
echo "  OUTPUT: $FINAL"
if [ -f "$FINAL" ]; then
    FINAL_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FINAL")
    echo "  Duration: ${FINAL_DURATION}s"
    echo "  Size: $(ls -lh "$FINAL" | awk '{print $5}')"
fi
echo ""
echo "  Preview: ffplay $FINAL"
echo ""
echo "  Intermediate files (safe to delete):"
echo "    $ANIMATED"
echo "    $LOOPED"
echo ""
echo "============================================"
