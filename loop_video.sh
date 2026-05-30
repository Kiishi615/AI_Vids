#!/bin/bash
# ============================================================================
# Loop a short clip into a long seamless video, with optional audio overlay
# ============================================================================
# HOW TO USE:
#   bash /workspace/loop_video.sh <input_clip.mp4> <output_name.mp4> [duration_seconds] [audio_file]
#
# EXAMPLES:
#   # Loop video only (no audio)
#   bash /workspace/loop_video.sh animated_portrait.mp4 final_20min.mp4
#
#   # Loop video + overlay audio
#   bash /workspace/loop_video.sh lipsync_clip.mp4 final_20min.mp4 1200 /workspace/audio/song.wav
#
#   # 5-minute output with audio
#   bash /workspace/loop_video.sh lipsync_clip.mp4 final_5min.mp4 300 /workspace/audio/song.wav
# ============================================================================

INPUT_FILE="${1:?ERROR: Provide input file as first argument}"
OUTPUT_FILE="${2:-looped_output.mp4}"
TARGET_DURATION="${3:-1200}"  # Default: 1200 seconds = 20 minutes
AUDIO_FILE="${4:-}"           # Optional: audio file to overlay

# Get the duration of the input clip
CLIP_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT_FILE")
echo "Input clip duration: ${CLIP_DURATION}s"
echo "Target duration: ${TARGET_DURATION}s"
if [ -n "$AUDIO_FILE" ]; then
    AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO_FILE")
    echo "Audio duration: ${AUDIO_DURATION}s"
fi

# Calculate how many loops we need
LOOPS=$(awk "BEGIN {print int(($TARGET_DURATION / $CLIP_DURATION) + 1)}")
echo "Loops needed: $LOOPS"

# Create the concat list
CONCAT_LIST=$(mktemp /workspace/concat_XXXX.txt)
for i in $(seq 1 $LOOPS); do
    echo "file '$(realpath $INPUT_FILE)'" >> "$CONCAT_LIST"
done

mkdir -p /workspace/final

if [ -n "$AUDIO_FILE" ] && [ -f "$AUDIO_FILE" ]; then
    echo "Muxing with audio: $AUDIO_FILE"
    
    # First, create the looped video (no audio)
    TEMP_LOOPED=$(mktemp /workspace/temp_looped_XXXX.mp4)
    ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -t "$TARGET_DURATION" -c copy "$TEMP_LOOPED" 2>/dev/null
    
    # Check if audio needs looping too
    AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO_FILE")
    
    if (( $(awk "BEGIN {print ($AUDIO_DURATION >= $TARGET_DURATION) ? 1 : 0}") )); then
        # Audio is long enough — use directly
        ffmpeg -y -i "$TEMP_LOOPED" -i "$AUDIO_FILE" \
            -t "$TARGET_DURATION" \
            -c:v copy -c:a aac -b:a 192k \
            -map 0:v:0 -map 1:a:0 \
            "/workspace/final/$OUTPUT_FILE" 2>/dev/null
    else
        # Audio needs looping too
        echo "Audio shorter than target — looping audio..."
        AUDIO_LOOPS=$(awk "BEGIN {print int(($TARGET_DURATION / $AUDIO_DURATION) + 1)}")
        AUDIO_CONCAT=$(mktemp /workspace/audio_concat_XXXX.txt)
        for i in $(seq 1 $AUDIO_LOOPS); do
            echo "file '$(realpath $AUDIO_FILE)'" >> "$AUDIO_CONCAT"
        done
        
        TEMP_AUDIO=$(mktemp /workspace/temp_audio_XXXX.wav)
        ffmpeg -y -f concat -safe 0 -i "$AUDIO_CONCAT" \
            -t "$TARGET_DURATION" "$TEMP_AUDIO" 2>/dev/null
        rm "$AUDIO_CONCAT"
        
        ffmpeg -y -i "$TEMP_LOOPED" -i "$TEMP_AUDIO" \
            -t "$TARGET_DURATION" \
            -c:v copy -c:a aac -b:a 192k \
            -map 0:v:0 -map 1:a:0 \
            "/workspace/final/$OUTPUT_FILE" 2>/dev/null
        
        rm "$TEMP_AUDIO"
    fi
    
    rm "$TEMP_LOOPED"
else
    # No audio — just loop the video
    ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -t "$TARGET_DURATION" -c copy "/workspace/final/$OUTPUT_FILE"
fi

# Clean up
rm "$CONCAT_LIST"

echo ""
echo "✅ Done! Output saved to: /workspace/final/$OUTPUT_FILE"
echo "   Duration: ${TARGET_DURATION}s"
if [ -n "$AUDIO_FILE" ]; then
    echo "   Audio: $AUDIO_FILE"
fi
ls -lh "/workspace/final/$OUTPUT_FILE"
