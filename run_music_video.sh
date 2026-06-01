#!/bin/bash

# ==============================================================================
# MUSIC VIDEO AUTO-SPLICER
# ==============================================================================
# This script bypasses VAE Autoregressive Drift by splitting long audio files
# into 30-second segments, processing each segment from the crisp original 
# portrait image, and seamlessly stitching them back together into an HD
# final output.
# ==============================================================================

# Activate Conda Environment
source ~/miniconda3/etc/profile.d/conda.sh
conda activate echomimic_v3

# Set paths
WORKSPACE="/teamspace/studios/this_studio"
MODELS_DIR="${WORKSPACE}/echomimic_v3/models/flash"

IMAGE_PATH="${WORKSPACE}/inputs/portrait.png"
FULL_AUDIO_PATH="${WORKSPACE}/inputs/audio.wav"

OUTPUT_DIR="${WORKSPACE}/outputs/music_video"
TMP_DIR="${OUTPUT_DIR}/tmp_audio"

mkdir -p "${OUTPUT_DIR}"
mkdir -p "${TMP_DIR}"

# 1. Get total audio duration in seconds
DURATION_EXACT=$(ffprobe -i "${FULL_AUDIO_PATH}" -show_entries format=duration -v quiet -of csv="p=0")
TOTAL_DURATION=$(echo "$DURATION_EXACT" | awk '{print int($1)}')
SEGMENT_LENGTH=30

echo "================================================="
echo "🎵 MUSIC VIDEO AUTO-SPLICER INITIATED 🎵"
echo "Total audio duration: ${TOTAL_DURATION}s"
echo "Splitting into ${SEGMENT_LENGTH}s segments to prevent AI blur drift..."
echo "================================================="

cd ${WORKSPACE}/AI_Vids
cp infer_long.py ${WORKSPACE}/echomimic_v3/
cd ${WORKSPACE}/echomimic_v3

# Calculate number of segments
NUM_SEGMENTS=$(( (TOTAL_DURATION + SEGMENT_LENGTH - 1) / SEGMENT_LENGTH ))

CONCAT_FILE="${OUTPUT_DIR}/concat.txt"
> "${CONCAT_FILE}"

# 2. Process each segment
for i in $(seq 0 $((NUM_SEGMENTS - 1))); do
    START_TIME=$(( i * SEGMENT_LENGTH ))
    SEGMENT_AUDIO="${TMP_DIR}/segment_${i}.wav"
    SEGMENT_VIDEO="${OUTPUT_DIR}/segment_${i}.mp4"
    
    echo " "
    echo "🎬 Processing Segment $((i+1))/$NUM_SEGMENTS (Time: $START_TIME to $((START_TIME + SEGMENT_LENGTH)) seconds)"
    echo "-------------------------------------------------"
    
    # Extract audio segment using FFmpeg
    ffmpeg -y -i "${FULL_AUDIO_PATH}" -ss ${START_TIME} -t ${SEGMENT_LENGTH} -acodec pcm_s16le -ar 16000 "${SEGMENT_AUDIO}" -loglevel error
    
    # Get exact frame count for this specific segment
    SEG_DUR=$(ffprobe -i "${SEGMENT_AUDIO}" -show_entries format=duration -v quiet -of csv="p=0")
    FRAMES=$(echo "$SEG_DUR" | awk '{print int($1 * 25 + 0.5)}')
    
    echo "Segment Frames: $FRAMES"
    
    # Run EchoMimic Inference
    python infer_long.py \
        --image_path "${IMAGE_PATH}" \
        --audio_path "${SEGMENT_AUDIO}" \
        --prompt "A person is singing passionately with expressive body movement, swaying naturally to the rhythm of the music. Beautiful normal eyes, stable eyes, open eyes, looking at camera." \
        --negative_prompt "morphing eyes, changing eyes, distorted eyes, closed eyes, cross-eyed, strange eyes, weird eyes, bad anatomy, bad face, deformed, blurry, demonic." \
        --num_inference_steps 25 \
        --config_path config/config.yaml \
        --model_name "${MODELS_DIR}/Wan2.1-Fun-V1.1-1.3B-InP" \
        --transformer_path "${MODELS_DIR}/echomimicv3-flash-pro/diffusion_pytorch_model.safetensors" \
        --save_path "${OUTPUT_DIR}" \
        --sampler_name "Flow_Unipc" \
        --video_length ${FRAMES} \
        --guidance_scale 6.0 \
        --audio_guidance_scale 2.5 \
        --audio_scale 1.2 \
        --neg_scale 1.0 \
        --neg_steps 0 \
        --seed 43 \
        --teacache_threshold 0.08 \
        --num_skip_start_steps 5 \
        --use_dynamic_cfg \
        --use_dynamic_acfg \
        --enable_riflex \
        --riflex_k 6 \
        --ulysses_degree 1 \
        --ring_degree 1
        
    # The output video is saved as portrait_output.mp4 in OUTPUT_DIR. Rename it.
    if [ -f "${OUTPUT_DIR}/portrait_output.mp4" ]; then
        mv "${OUTPUT_DIR}/portrait_output.mp4" "${SEGMENT_VIDEO}"
        # Add to concat file for final stitching
        echo "file '${SEGMENT_VIDEO}'" >> "${CONCAT_FILE}"
        echo "✅ Segment $((i+1)) generated successfully."
    else
        echo "❌ ERROR: Segment $((i+1)) failed to generate!"
        exit 1
    fi
done

echo "================================================="
echo "🎞️ Stitching segments together..."
FINAL_OUTPUT="${OUTPUT_DIR}/FINAL_Music_Video.mp4"
ffmpeg -y -f concat -safe 0 -i "${CONCAT_FILE}" -c copy "${FINAL_OUTPUT}" -loglevel error

echo "🎉 DONE! Your flawless, blur-free music video is waiting at:"
echo "${FINAL_OUTPUT}"
echo "================================================="
