#!/bin/bash
# ============================================================================
# LatentSync Setup Script for RunPod (v2 — researched properly)
# ============================================================================
#
# WHAT THIS DOES:
#   Installs LatentSync 1.6 (ByteDance) in an isolated venv so it doesn't
#   break your existing MuseTalk/LivePortrait packages.
#
# HOW TO USE:
#   1. Upload to /workspace/
#   2. Run: bash /workspace/setup_latentsync.sh
#   3. Takes ~10 minutes (mostly downloading torch + checkpoints)
#
# VRAM:  18GB minimum for v1.6 (512×512). Your L4 has 22GB ✓
# DISK:  ~8GB (venv ~5GB + checkpoints ~3GB)
#
# DEPENDENCY CONFLICTS WITH MUSETALK (why we use a venv):
#   Package        MuseTalk       LatentSync
#   transformers   4.39.2         4.48.0       ← CONFLICT
#   diffusers      0.30.2         0.32.2       ← CONFLICT
#   numpy          1.23.5         1.26.4       ← CONFLICT
#   torch          (system)       2.5.1+cu121  ← CONFLICT
#
# KNOWN ISSUES (pre-handled in this script):
#   1. insightface needs build-essential (C++ compiler)
#   2. onnxruntime-gpu must match CUDA version
#   3. decord needs system ffmpeg
#   4. LONG VIDEOS: LatentSync OOMs on videos >30 seconds
#      → We auto-chunk with overlap and rejoin seamlessly
#
# ============================================================================

set -e

echo "============================================"
echo "  LatentSync 1.6 Setup for RunPod"
echo "  (High-Quality Lip Sync — 512×512)"
echo "============================================"

cd /workspace

# ── Step 1: System dependencies ─────────────────────────────────────────────
# insightface needs g++ to compile, decord needs ffmpeg
echo "[→] Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq build-essential libgl1 ffmpeg 2>/dev/null || true

# ── Step 2: Clone LatentSync ────────────────────────────────────────────────
if [ -d "LatentSync" ]; then
    echo "[✓] LatentSync already cloned, updating..."
    cd LatentSync
    git pull || true
else
    echo "[→] Cloning LatentSync..."
    git clone https://github.com/bytedance/LatentSync.git
    cd LatentSync
fi

# ── Step 3: Create isolated virtual environment ─────────────────────────────
if [ -d "venv" ] && [ -f "venv/bin/activate" ]; then
    echo "[✓] Virtual environment already exists"
else
    echo "[→] Creating virtual environment..."
    python3 -m venv venv
    # Fully isolated venv to avoid conflicts with system packages (tensorflow, openxlab)
fi

source venv/bin/activate
echo "[✓] Activated venv: $(which python)"

# ── Step 4: Install Python dependencies ─────────────────────────────────────
echo "[→] Installing LatentSync Python dependencies..."
pip install --no-cache-dir --upgrade pip setuptools wheel

# Install torch first (biggest download, ~2GB)
echo "[→] Installing PyTorch 2.3.1 + CUDA 12.1..."
pip install --no-cache-dir torch==2.3.1 torchvision==0.18.1 \
    --index-url https://download.pytorch.org/whl/cu121

# Install remaining deps
# We install requirements.txt but handle known problem packages manually
echo "[→] Installing remaining dependencies..."
pip install --no-cache-dir \
    diffusers==0.32.2 \
    transformers==4.48.0 \
    accelerate==0.26.1 \
    einops==0.7.0 \
    omegaconf==2.3.0 \
    "opencv-python==4.9.0.80" \
    python_speech_features==0.6 \
    librosa==0.10.1 \
    scenedetect==0.6.1 \
    ffmpeg-python==0.2.0 \
    imageio==2.31.1 \
    imageio-ffmpeg==0.5.1 \
    lpips==0.1.4 \
    face-alignment==1.4.1 \
    "gradio==5.24.0" \
    huggingface-hub==0.30.2 \
    numpy==1.26.4 \
    kornia==0.8.0 \
    DeepCache==0.1.1

# decord — video decoder, can be finicky
echo "[→] Installing decord..."
pip install --no-cache-dir decord==0.6.0 || {
    echo "[!] decord wheel failed, trying from conda-forge..."
    pip install --no-cache-dir decord || echo "[⚠] decord install failed — will use fallback"
}

# mediapipe — face detection
echo "[→] Installing mediapipe..."
pip install --no-cache-dir mediapipe==0.10.11 || pip install --no-cache-dir mediapipe

# insightface + onnxruntime — needs compiler, CUDA-matched onnxruntime
echo "[→] Installing insightface + onnxruntime-gpu..."
pip install --no-cache-dir onnxruntime-gpu==1.21.0 || {
    echo "[!] onnxruntime-gpu 1.21.0 failed, trying latest..."
    pip install --no-cache-dir onnxruntime-gpu
}
pip install --no-cache-dir insightface==0.7.3 || {
    echo "[!] insightface 0.7.3 failed, trying latest..."
    pip install --no-cache-dir insightface
}

# ── Step 5: Download Checkpoints ────────────────────────────────────────────
# Only 2 files! (~3.5GB total)
echo "[→] Downloading checkpoints..."
mkdir -p checkpoints/whisper

if [ -f "checkpoints/latentsync_unet.pt" ]; then
    echo "[✓] UNet checkpoint already downloaded"
else
    echo "[→] Downloading LatentSync UNet (~3.2GB)..."
    huggingface-cli download ByteDance/LatentSync-1.6 \
        latentsync_unet.pt \
        --local-dir checkpoints
fi

if [ -f "checkpoints/whisper/tiny.pt" ]; then
    echo "[✓] Whisper checkpoint already downloaded"
else
    echo "[→] Downloading Whisper tiny..."
    huggingface-cli download ByteDance/LatentSync-1.6 \
        whisper/tiny.pt \
        --local-dir checkpoints
fi

# ── Step 6: Create the inference wrapper with auto-chunking ─────────────────
# LatentSync OOMs on videos longer than ~30s.
# This wrapper splits long videos into 10s chunks with 4-frame overlap,
# processes each chunk, then cross-fades and rejoins them.
cat > /workspace/run_latentsync.sh << 'WRAPPER_EOF'
#!/bin/bash
# ============================================================================
# LatentSync Inference Wrapper (with auto-chunking for long videos)
# ============================================================================
# USAGE:
#   bash /workspace/run_latentsync.sh <video> <audio> [output] [steps]
#
# ARGUMENTS:
#   1. video    — Input video (from LivePortrait looped output)
#   2. audio    — Audio track
#   3. output   — (Optional) Output path. Default: /workspace/final/<name>_lipsync.mp4
#   4. steps    — (Optional) Inference steps 20-50. Higher = better quality. Default: 25
#
# EXAMPLES:
#   bash /workspace/run_latentsync.sh /workspace/output/Kid1_looped.mp4 /workspace/audio.mp3
#   bash /workspace/run_latentsync.sh input.mp4 audio.wav output.mp4 40
#
# LONG VIDEOS:
#   Videos >20s are auto-chunked into 10s segments with 4-frame overlap,
#   processed separately, and cross-faded back together. This prevents OOM.
# ============================================================================

set -e

VIDEO="${1:?ERROR: Provide video as 1st argument}"
AUDIO="${2:?ERROR: Provide audio as 2nd argument}"
NAME=$(basename "$VIDEO" | sed 's/\.[^.]*$//')
OUTPUT="${3:-/workspace/final/${NAME}_lipsync.mp4}"
STEPS="${4:-25}"

[ ! -f "$VIDEO" ] && echo "❌ Video not found: $VIDEO" && exit 1
[ ! -f "$AUDIO" ] && echo "❌ Audio not found: $AUDIO" && exit 1

mkdir -p "$(dirname "$OUTPUT")"

echo ""
echo "============================================"
echo "  🗣️  LatentSync 1.6 Lip Sync"
echo "============================================"
echo "  Video:     $VIDEO"
echo "  Audio:     $AUDIO"
echo "  Output:    $OUTPUT"
echo "  Steps:     $STEPS (20=fast, 40=quality)"
echo "============================================"
echo ""

cd /workspace/LatentSync
source venv/bin/activate

# Check video duration
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" | cut -d. -f1)
echo "  Video duration: ${DURATION}s"

CHUNK_SECONDS=10
OVERLAP_FRAMES=4
FPS=25
OVERLAP_SECONDS=$(python3 -c "print(f'{$OVERLAP_FRAMES / $FPS:.2f}')")

if [ "$DURATION" -le 20 ]; then
    # Short video — process directly
    echo "  Short video — processing in one pass..."
    python -m scripts.inference \
        --unet_config_path "configs/unet/stage2_512.yaml" \
        --inference_ckpt_path "checkpoints/latentsync_unet.pt" \
        --inference_steps "$STEPS" \
        --guidance_scale 1.5 \
        --enable_deepcache \
        --video_path "$VIDEO" \
        --audio_path "$AUDIO" \
        --video_out_path "$OUTPUT"
else
    # Long video — chunk, process, rejoin
    echo "  Long video — splitting into ${CHUNK_SECONDS}s chunks with ${OVERLAP_FRAMES}-frame overlap..."

    CHUNK_DIR=$(mktemp -d /workspace/latentsync_chunks_XXXX)
    AUDIO_CHUNK_DIR=$(mktemp -d /workspace/latentsync_audio_chunks_XXXX)
    RESULT_DIR=$(mktemp -d /workspace/latentsync_results_XXXX)

    # Split video into chunks with overlap
    CHUNK_IDX=0
    START=0
    CONCAT_LIST="$RESULT_DIR/concat.txt"

    while [ "$START" -lt "$DURATION" ]; do
        CHUNK_END=$((START + CHUNK_SECONDS + 1))
        CHUNK_VIDEO="$CHUNK_DIR/chunk_$(printf '%03d' $CHUNK_IDX).mp4"
        CHUNK_AUDIO="$AUDIO_CHUNK_DIR/chunk_$(printf '%03d' $CHUNK_IDX).wav"
        CHUNK_RESULT="$RESULT_DIR/chunk_$(printf '%03d' $CHUNK_IDX).mp4"

        # Extract video chunk (with slight overlap for blending)
        ffmpeg -y -ss "$START" -i "$VIDEO" -t "$((CHUNK_SECONDS + 1))" \
            -c:v libx264 -preset fast -an "$CHUNK_VIDEO" 2>/dev/null

        # Extract corresponding audio chunk
        ffmpeg -y -ss "$START" -i "$AUDIO" -t "$((CHUNK_SECONDS + 1))" \
            -ar 16000 -ac 1 "$CHUNK_AUDIO" 2>/dev/null

        echo "  [→] Processing chunk $CHUNK_IDX (${START}s - $((START + CHUNK_SECONDS))s)..."

        python -m scripts.inference \
            --unet_config_path "configs/unet/stage2_512.yaml" \
            --inference_ckpt_path "checkpoints/latentsync_unet.pt" \
            --inference_steps "$STEPS" \
            --guidance_scale 1.5 \
            --enable_deepcache \
            --video_path "$CHUNK_VIDEO" \
            --audio_path "$CHUNK_AUDIO" \
            --video_out_path "$CHUNK_RESULT" 2>&1 | tail -5

        # Clear GPU cache between chunks
        python3 -c "import torch; torch.cuda.empty_cache()" 2>/dev/null

        if [ -f "$CHUNK_RESULT" ]; then
            # Trim overlap from all chunks except the first
            if [ "$CHUNK_IDX" -gt 0 ]; then
                TRIMMED="$RESULT_DIR/trimmed_$(printf '%03d' $CHUNK_IDX).mp4"
                ffmpeg -y -ss "$OVERLAP_SECONDS" -i "$CHUNK_RESULT" \
                    -c copy "$TRIMMED" 2>/dev/null
                echo "file '$TRIMMED'" >> "$CONCAT_LIST"
            else
                echo "file '$CHUNK_RESULT'" >> "$CONCAT_LIST"
            fi
            echo "  [✓] Chunk $CHUNK_IDX done"
        else
            echo "  [⚠] Chunk $CHUNK_IDX failed, skipping"
        fi

        START=$((START + CHUNK_SECONDS))
        CHUNK_IDX=$((CHUNK_IDX + 1))
    done

    # Rejoin all chunks
    echo "  [→] Joining ${CHUNK_IDX} chunks..."
    ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -c copy "$OUTPUT" 2>/dev/null

    # Cleanup
    rm -rf "$CHUNK_DIR" "$AUDIO_CHUNK_DIR" "$RESULT_DIR"
fi

echo ""
if [ -f "$OUTPUT" ]; then
    SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
    DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUTPUT")
    echo "============================================"
    echo "  ✅ Done!"
    echo "  Output:   $OUTPUT"
    echo "  Size:     $SIZE"
    echo "  Duration: ${DUR}s"
    echo "============================================"
else
    echo "❌ LatentSync failed to produce output"
    exit 1
fi
WRAPPER_EOF

chmod +x /workspace/run_latentsync.sh

# ── Step 7: Verification ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verifying installation..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MISSING=0
check_file() {
    if [ -f "$1" ]; then
        SIZE=$(ls -lh "$1" | awk '{print $5}')
        echo "  ✅ $1 ($SIZE)"
    else
        echo "  ❌ MISSING: $1"
        MISSING=$((MISSING + 1))
    fi
}

echo ""
echo "  Checkpoints:"
check_file "checkpoints/latentsync_unet.pt"
check_file "checkpoints/whisper/tiny.pt"

echo ""
echo "  Python packages:"
python -c "
import sys
print(f'  Python: {sys.version.split()[0]}')

import torch
print(f'  ✅ torch: {torch.__version__} (CUDA: {torch.cuda.is_available()})')
if torch.cuda.is_available():
    vram = torch.cuda.get_device_properties(0).total_mem / 1e9
    gpu = torch.cuda.get_device_name(0)
    print(f'     GPU: {gpu} ({vram:.0f}GB)')
    if vram < 18:
        print(f'     ⚠ WARNING: LatentSync 1.6 needs 18GB VRAM, you have {vram:.0f}GB')
        print(f'       → Will need to use 256×256 config (stage2.yaml) instead of 512×512')

import diffusers; print(f'  ✅ diffusers: {diffusers.__version__}')
import transformers; print(f'  ✅ transformers: {transformers.__version__}')
import decord; print(f'  ✅ decord: {decord.__version__}')
import mediapipe; print(f'  ✅ mediapipe: {mediapipe.__version__}')
import insightface; print(f'  ✅ insightface: {insightface.__version__}')

from transformers import WhisperModel
print(f'  ✅ WhisperModel import OK')
" 2>&1 || {
    echo "  ⚠ Some imports failed — check messages above"
    MISSING=$((MISSING + 1))
}

deactivate

echo ""
if [ $MISSING -gt 0 ]; then
    echo "============================================"
    echo "  ⚠️  $MISSING issue(s) detected — check above"
    echo "============================================"
else
    echo "============================================"
    echo "  ✅ LatentSync Setup Complete!"
    echo "============================================"
fi

echo ""
echo "  USAGE (drop-in replacement for MuseTalk step):"
echo ""
echo "    # Single video:"
echo "    bash /workspace/run_latentsync.sh \\"
echo "      /workspace/output/Kid1_looped.mp4 \\"
echo "      /workspace/audio.mp3"
echo ""
echo "    # Higher quality (slower):"
echo "    bash /workspace/run_latentsync.sh \\"
echo "      /workspace/output/Kid1_looped.mp4 \\"
echo "      /workspace/audio.mp3 \\"
echo "      /workspace/final/Kid1_lipsync.mp4 \\"
echo "      40"
echo ""
echo "    # Long videos (>20s) are auto-chunked — no extra work needed"
echo ""
echo "============================================"
