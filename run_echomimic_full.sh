#!/bin/bash
###############################################################################
# EchoMimic v3 — Full 5-Minute Generation (768×768, Flash-Pro)
#
# This is the production run. Make sure you've tested with run_echomimic_test.sh
# first to validate the setup.
#
# Estimated time on H100: 30-60 minutes
# Estimated cost: ~$1.00-$2.00 at $1.99/hr
#
# Usage:  bash ~/AI_Vids/run_echomimic_full.sh
#
# Optional args:
#   bash ~/AI_Vids/run_echomimic_full.sh /path/to/portrait.png /path/to/audio.wav "Custom prompt"
###############################################################################
set -euo pipefail

WORKSPACE="${HOME}"
REPO_DIR="${WORKSPACE}/echomimic_v3"
MODELS_DIR="${REPO_DIR}/models/flash"

# Input files — use args or defaults
IMAGE_PATH="${1:-${WORKSPACE}/inputs/portrait.png}"
AUDIO_PATH="${2:-${WORKSPACE}/inputs/audio.wav}"
PROMPT="${3:-A person is singing passionately with expressive body movement, swaying naturally to the rhythm of the music.}"

# Validate inputs exist
if [ ! -f "${IMAGE_PATH}" ]; then
    echo "❌ Portrait image not found: ${IMAGE_PATH}"
    echo "   Upload your portrait to ~/inputs/portrait.png"
    exit 1
fi

if [ ! -f "${AUDIO_PATH}" ]; then
    echo "❌ Audio file not found: ${AUDIO_PATH}"
    echo "   Upload your audio to ~/inputs/audio.wav"
    exit 1
fi

# Calculate expected video length from audio duration
AUDIO_DURATION=$(python3 -c "
import librosa
y, sr = librosa.load('${AUDIO_PATH}', sr=16000)
print(f'{len(y)/sr:.1f}')
" 2>/dev/null || echo "300.0")

TOTAL_FRAMES=$(python3 -c "print(int(float('${AUDIO_DURATION}') * 25))")

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     EchoMimic v3 — FULL GENERATION                        ║"
echo "║     768×768 | 8 steps | Flash-Pro | H100                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Portrait:      ${IMAGE_PATH}"
echo "  Audio:         ${AUDIO_PATH}"
echo "  Audio length:  ${AUDIO_DURATION}s"
echo "  Total frames:  ${TOTAL_FRAMES}"
echo "  Prompt:        ${PROMPT}"
echo "  Output:        ${WORKSPACE}/outputs/"
echo ""
echo "  Estimated time: 30-60 minutes on H100"
echo "  Starting in 5 seconds... (Ctrl+C to cancel)"
echo ""
sleep 5

cd "${REPO_DIR}"

START=$(date +%s)

python infer_flash.py \
    --image_path "${IMAGE_PATH}" \
    --audio_path "${AUDIO_PATH}" \
    --prompt "${PROMPT}" \
    --num_inference_steps 15 \
    --config_path config/config.yaml \
    --model_name "${MODELS_DIR}/Wan2.1-Fun-V1.1-1.3B-InP" \
    --transformer_path "${MODELS_DIR}/echomimicv3-flash-pro/transformer/diffusion_pytorch_model.safetensors" \
    --wav2vec_model_dir "${MODELS_DIR}/chinese-wav2vec2-base" \
    --save_path "${WORKSPACE}/outputs" \
    --sampler_name "Flow_Unipc" \
    --video_length "${TOTAL_FRAMES}" \
    --guidance_scale 6.0 \
    --audio_guidance_scale 2.0 \
    --audio_scale 1.0 \
    --neg_scale 1.0 \
    --neg_steps 0 \
    --seed 43 \
    --enable_teacache \
    --teacache_threshold 0.08 \
    --num_skip_start_steps 5 \
    --riflex_k 6 \
    --ulysses_degree 1 \
    --ring_degree 1 \
    --weight_dtype "bfloat16" \
    --sample_size 768 768 \
    --fps 25 \
    --shift 5.0 \
    --GPU_memory_mode "normal"

END=$(date +%s)
ELAPSED=$((END - START))
MINS=$((ELAPSED / 60))
SECS=$((ELAPSED % 60))

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ GENERATION COMPLETE in ${MINS}m ${SECS}s                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Output: ${WORKSPACE}/outputs/                             ║"
echo "║                                                            ║"
echo "║  Verify with:                                              ║"
echo "║  ffprobe -i ~/workspace/outputs/*_output.mp4               ║"
echo "║     -show_entries format=duration                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# List output files
echo ""
echo "Output files:"
ls -lh "${WORKSPACE}/outputs/"*.mp4 2>/dev/null || echo "  (no .mp4 files found)"
