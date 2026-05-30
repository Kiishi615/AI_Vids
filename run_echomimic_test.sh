#!/bin/bash
###############################################################################
# EchoMimic v3 — Quick Test (10-second clip)
#
# Run this FIRST to validate your setup before the full 5-minute generation.
# Uses only 250 frames (~10 seconds at 25fps), finishes in ~2-3 minutes.
#
# Usage:  bash ~/AI_Vids/run_echomimic_test.sh
# 
# Optional args:
#   bash ~/AI_Vids/run_echomimic_test.sh /path/to/portrait.png /path/to/audio.wav
###############################################################################
set -euo pipefail

WORKSPACE="${HOME}"
REPO_DIR="${WORKSPACE}/echomimic_v3"
MODELS_DIR="${REPO_DIR}/models/flash"

# Input files — use args or defaults
IMAGE_PATH="${1:-${WORKSPACE}/inputs/portrait.png}"
AUDIO_PATH="${2:-${WORKSPACE}/inputs/audio.wav}"

# Validate inputs exist
if [ ! -f "${IMAGE_PATH}" ]; then
    echo "❌ Portrait image not found: ${IMAGE_PATH}"
    echo "   Upload your portrait to ~/inputs/portrait.png"
    echo "   Or pass a custom path: bash $0 /path/to/portrait.png /path/to/audio.wav"
    exit 1
fi

if [ ! -f "${AUDIO_PATH}" ]; then
    echo "❌ Audio file not found: ${AUDIO_PATH}"
    echo "   Upload your audio to ~/inputs/audio.wav"
    echo "   Or pass a custom path: bash $0 /path/to/portrait.png /path/to/audio.wav"
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     EchoMimic v3 — QUICK TEST (10-second clip)             ║"
echo "║     768×768 | 8 steps | Flash-Pro                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Portrait: ${IMAGE_PATH}"
echo "  Audio:    ${AUDIO_PATH}"
echo "  Output:   ${WORKSPACE}/outputs/"
echo ""

cd "${REPO_DIR}"

START=$(date +%s)

python infer_flash.py \
    --image_path "${IMAGE_PATH}" \
    --audio_path "${AUDIO_PATH}" \
    --prompt "A person is singing passionately with expressive body movement, swaying naturally to the rhythm of the music." \
    --num_inference_steps 15 \
    --config_path config/config.yaml \
    --model_name "${MODELS_DIR}/Wan2.1-Fun-V1.1-1.3B-InP" \
    --transformer_path "${MODELS_DIR}/echomimicv3-flash-pro/transformer/diffusion_pytorch_model.safetensors" \
    --wav2vec_model_dir "${MODELS_DIR}/chinese-wav2vec2-base" \
    --save_path "${WORKSPACE}/outputs" \
    --sampler_name "Flow_Unipc" \
    --video_length 250 \
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
echo "║  ✅ TEST COMPLETE in ${MINS}m ${SECS}s                          ║"
echo "║  Check output: ls -la ${WORKSPACE}/outputs/              ║"
echo "║                                                            ║"
echo "║  If it looks good, run the full version:                   ║"
echo "║  bash ~/AI_Vids/run_echomimic_full.sh                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
