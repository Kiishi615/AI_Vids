#!/bin/bash
# ============================================================================
# Lightning AI — Full Pipeline: Portrait → Animate → Loop → Lip Sync
# ============================================================================
#
# Adapted from RunPod scripts for Lightning AI.
# Uses conda env instead of venv, $HOME/workspace instead of /workspace.
#
# USAGE:
#   conda activate lipsync
#   bash lightning_run_pipeline.sh <image> <audio> [pickle] [steps] [guidance]
#
# ARGUMENTS:
#   1. image    — Portrait image (PNG, JPG)
#   2. audio    — Audio track (WAV, MP3, etc.)
#   3. pickle   — (Optional) Motion pickle. Default: auto-generated
#   4. steps    — (Optional) LatentSync inference steps. Default: 30
#   5. guidance — (Optional) Guidance scale 1.0-3.0. Default: 2.5 (singing)
#
# EXAMPLES:
#   bash lightning_run_pipeline.sh ~/workspace/portraits/Kid1.png ~/workspace/audio/song.mp3
#   bash lightning_run_pipeline.sh ~/workspace/portraits/Kid1.png ~/workspace/audio/song.mp3 custom.pkl 40
#
# GPU RECOMMENDATIONS:
#   - LivePortrait (Step 1): T4 is fine (16GB VRAM)
#   - LatentSync  (Step 3): L40S recommended (48GB VRAM)
#   You can run Step 1+2 on T4, then switch to L40S for Step 3.
#
# ============================================================================

set -e

WORKSPACE="$HOME/workspace"

# ── Parse Arguments ─────────────────────────────────────────────────────────
IMAGE="${1:?ERROR: Provide image as 1st argument (e.g. ~/workspace/portraits/Kid1.png)}"
AUDIO="${2:?ERROR: Provide audio as 2nd argument (e.g. ~/workspace/audio/song.mp3)}"
PICKLE="${3:-}"
STEPS="${4:-30}"
GUIDANCE="${5:-2.5}"

# ── Validate ────────────────────────────────────────────────────────────────
[ ! -f "$IMAGE" ] && echo "❌ Image not found: $IMAGE" && exit 1
[ ! -f "$AUDIO" ] && echo "❌ Audio not found: $AUDIO" && exit 1

# If no pickle provided, generate one
if [ -z "$PICKLE" ] || [ ! -f "$PICKLE" ]; then
    PICKLE="$WORKSPACE/natural_blink.pkl"
    if [ ! -f "$PICKLE" ]; then
        echo "[→] Generating blink animation pickle..."
        python "$WORKSPACE/generate_blink_pickle.py"
        # Move to workspace if generated elsewhere
        if [ -f "natural_blink.pkl" ] && [ ! -f "$PICKLE" ]; then
            mv natural_blink.pkl "$PICKLE"
        fi
    fi
fi

[ ! -f "$PICKLE" ] && echo "❌ Pickle not found: $PICKLE" && exit 1

# ── Derive names ────────────────────────────────────────────────────────────
NAME=$(basename "$IMAGE" | sed 's/\.[^.]*$//')
mkdir -p "$WORKSPACE/output"
mkdir -p "$WORKSPACE/final"

AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO")
AUDIO_MINS=$(awk "BEGIN {print int($AUDIO_DURATION / 60)}")
AUDIO_SECS=$(awk "BEGIN {printf \"%.1f\", $AUDIO_DURATION - ($AUDIO_MINS * 60)}")

echo ""
echo "============================================"
echo "  🎬 Lip-Sync Pipeline: $NAME"
echo "  ⚡ Lightning AI Edition"
echo "============================================"
echo "  Image:       $IMAGE"
echo "  Audio:       $AUDIO  (${AUDIO_MINS}m ${AUDIO_SECS}s)"
echo "  Pickle:      $PICKLE"
echo "  LatentSync:  ${STEPS} steps, guidance ${GUIDANCE}"
echo "============================================"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# STEP 1: LivePortrait — Animate portrait (blink + head movement)
# ════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎭 STEP 1/3: Animating portrait (LivePortrait)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ANIMATED="$WORKSPACE/output/${NAME}_animated.mp4"

cd "$WORKSPACE/LivePortrait"

python inference.py \
    -s "$IMAGE" \
    -d "$PICKLE" \
    --flag_pasteback \
    2>&1 | tail -10

# Find LivePortrait output
LP_OUTPUT=$(find "$WORKSPACE/LivePortrait/animations" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$LP_OUTPUT" ]; then
    LP_OUTPUT=$(find "$WORKSPACE/LivePortrait" -path "*/output/*" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
fi

if [ -z "$LP_OUTPUT" ]; then
    echo "❌ LivePortrait didn't produce output."
    exit 1
fi

cp "$LP_OUTPUT" "$ANIMATED"
CLIP_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ANIMATED")
echo ""
echo "✅ Animated clip: $ANIMATED (${CLIP_DURATION}s)"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# STEP 2: Loop the animated clip to match audio length (with crossfade)
# ════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔁 STEP 2/3: Looping clip to match audio (${AUDIO_MINS}m ${AUDIO_SECS}s)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LOOPED="$WORKSPACE/output/${NAME}_looped.mp4"
XFADE_DUR=0.5  # Crossfade duration in seconds for smooth loop transitions

# Step 2a: Create a crossfaded master clip (two copies blended at the seam)
# This eliminates the jarring cut when the animation loops
CLIP_DUR_INT=$(printf '%.0f' "$CLIP_DURATION")
XFADE_OFFSET=$(awk "BEGIN {printf \"%.2f\", $CLIP_DURATION - $XFADE_DUR}")
MASTER_CLIP="$WORKSPACE/output/${NAME}_master_loop.mp4"

echo "  Creating crossfaded master clip (${XFADE_DUR}s fade)..."
ffmpeg -y -i "$ANIMATED" -i "$ANIMATED" \
    -filter_complex \
    "[0:v][1:v]xfade=transition=fade:duration=${XFADE_DUR}:offset=${XFADE_OFFSET},format=yuv420p[v]" \
    -map "[v]" -an \
    -c:v libx264 -preset fast -crf 18 \
    "$MASTER_CLIP" 2>/dev/null

# Step 2b: Loop the master clip to fill the audio duration
MASTER_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MASTER_CLIP")
LOOPS=$(awk "BEGIN {print int(($AUDIO_DURATION / $MASTER_DURATION) + 1)}")
echo "  Master clip: ${MASTER_DURATION}s × ${LOOPS} loops → trimmed to ${AUDIO_DURATION}s"

CONCAT_LIST=$(mktemp "$WORKSPACE/concat_XXXX.txt")
for i in $(seq 1 $LOOPS); do
    echo "file '$(realpath $MASTER_CLIP)'" >> "$CONCAT_LIST"
done

ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" \
    -t "$AUDIO_DURATION" \
    -c copy \
    "$LOOPED" 2>/dev/null

rm "$CONCAT_LIST"
LOOPED_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$LOOPED")
echo "✅ Looped video: $LOOPED (${LOOPED_DURATION}s)"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# STEP 3: LatentSync — Lip-sync to audio
# ════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗣️  STEP 3/3: Lip-syncing with LatentSync"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FINAL="$WORKSPACE/final/${NAME}_final.mp4"
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$LOOPED" | cut -d. -f1)

cd "$WORKSPACE/LatentSync"

CHUNK_SECONDS=10
OVERLAP_FRAMES=4
FPS=25
OVERLAP_SECONDS=$(python3 -c "print(f'{$OVERLAP_FRAMES / $FPS:.2f}')")

if [ "$DURATION" -le 20 ]; then
    echo "  Short video — processing in one pass..."
    python -m scripts.inference \
        --unet_config_path "configs/unet/stage2_512.yaml" \
        --inference_ckpt_path "checkpoints/latentsync_unet.pt" \
        --inference_steps "$STEPS" \
        --guidance_scale "$GUIDANCE" \
        --enable_deepcache \
        --video_path "$LOOPED" \
        --audio_path "$AUDIO" \
        --video_out_path "$FINAL"
else
    echo "  Long video (${DURATION}s) — chunking into ${CHUNK_SECONDS}s segments..."

    CHUNK_DIR=$(mktemp -d "$WORKSPACE/chunks_XXXX")
    AUDIO_CHUNK_DIR=$(mktemp -d "$WORKSPACE/achunks_XXXX")
    RESULT_DIR=$(mktemp -d "$WORKSPACE/results_XXXX")
    CONCAT_LIST_LS="$RESULT_DIR/concat.txt"

    CHUNK_IDX=0
    START=0

    while [ "$START" -lt "$DURATION" ]; do
        CHUNK_VIDEO="$CHUNK_DIR/chunk_$(printf '%03d' $CHUNK_IDX).mp4"
        CHUNK_AUDIO="$AUDIO_CHUNK_DIR/chunk_$(printf '%03d' $CHUNK_IDX).wav"
        CHUNK_RESULT="$RESULT_DIR/chunk_$(printf '%03d' $CHUNK_IDX).mp4"

        ffmpeg -y -ss "$START" -i "$LOOPED" -t "$((CHUNK_SECONDS + 1))" \
            -c:v libx264 -preset fast -an "$CHUNK_VIDEO" 2>/dev/null

        ffmpeg -y -ss "$START" -i "$AUDIO" -t "$((CHUNK_SECONDS + 1))" \
            -ar 16000 -ac 1 "$CHUNK_AUDIO" 2>/dev/null

        echo "  [→] Chunk $CHUNK_IDX (${START}s - $((START + CHUNK_SECONDS))s)..."

        python -m scripts.inference \
            --unet_config_path "configs/unet/stage2_512.yaml" \
            --inference_ckpt_path "checkpoints/latentsync_unet.pt" \
            --inference_steps "$STEPS" \
            --guidance_scale "$GUIDANCE" \
            --enable_deepcache \
            --video_path "$CHUNK_VIDEO" \
            --audio_path "$CHUNK_AUDIO" \
            --video_out_path "$CHUNK_RESULT" 2>&1 | tail -5

        python3 -c "import torch; torch.cuda.empty_cache()" 2>/dev/null

        if [ -f "$CHUNK_RESULT" ]; then
            if [ "$CHUNK_IDX" -gt 0 ]; then
                TRIMMED="$RESULT_DIR/trimmed_$(printf '%03d' $CHUNK_IDX).mp4"
                ffmpeg -y -ss "$OVERLAP_SECONDS" -i "$CHUNK_RESULT" \
                    -c copy "$TRIMMED" 2>/dev/null
                echo "file '$TRIMMED'" >> "$CONCAT_LIST_LS"
            else
                echo "file '$CHUNK_RESULT'" >> "$CONCAT_LIST_LS"
            fi
            echo "  [✓] Chunk $CHUNK_IDX done"
        else
            echo "  [⚠] Chunk $CHUNK_IDX failed"
        fi

        START=$((START + CHUNK_SECONDS))
        CHUNK_IDX=$((CHUNK_IDX + 1))
    done

    echo "  [→] Joining ${CHUNK_IDX} chunks..."
    ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST_LS" -c copy "$FINAL" 2>/dev/null
    rm -rf "$CHUNK_DIR" "$AUDIO_CHUNK_DIR" "$RESULT_DIR"
fi

echo ""
if [ -f "$FINAL" ]; then
    FINAL_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FINAL")
    SIZE=$(ls -lh "$FINAL" | awk '{print $5}')
    echo "============================================"
    echo "  🎉 Done! $NAME"
    echo "============================================"
    echo "  Output:   $FINAL"
    echo "  Duration: ${FINAL_DURATION}s"
    echo "  Size:     $SIZE"
    echo "============================================"
else
    echo "❌ Pipeline failed — check errors above"
    exit 1
fi
