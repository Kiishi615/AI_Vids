#!/bin/bash
# ============================================================================
# MuseTalk Setup Script for RunPod (v2 — battle-tested)
# ============================================================================
# Installs MuseTalk alongside your existing LivePortrait setup.
# MuseTalk handles audio-driven lip sync — it takes a video (from LivePortrait)
# and an audio file, then inpaints the mouth region to match the speech/singing.
#
# HOW TO USE:
#   1. Upload this file to /workspace/ on your RunPod pod
#   2. Run: bash /workspace/setup_musetalk.sh
#   3. Takes ~10-15 minutes (mostly downloading model weights)
#
# PREREQUISITES:
#   - RunPod pod with GPU (L4/A100/A40 recommended, minimum 4GB VRAM)
#   - LivePortrait already set up (via setup_liveportrait.sh)
#
# ERRORS THIS SCRIPT PREVENTS:
#   - FileNotFoundError: ./models/musetalk/config.json      (wrong path)
#   - FileNotFoundError: ./models/face-parse-bisenet/...    (wrong spelling)
#   - ImportError: huggingface-hub>=0.19.3,<1.0             (version mismatch)
#   - ModuleNotFoundError: GenerationMixin                  (transformers too new)
# ============================================================================

set -e  # Stop on any error

echo "============================================"
echo "  MuseTalk Setup for RunPod (v2)"
echo "  (Audio-Driven Lip Sync)"
echo "============================================"

cd /workspace

# ── Step 1: Clone MuseTalk ──────────────────────────────────────────────────
if [ -d "MuseTalk" ]; then
    echo "[✓] MuseTalk already cloned, updating..."
    cd MuseTalk
    git pull || true  # Don't fail if offline
else
    echo "[→] Cloning MuseTalk..."
    git clone https://github.com/TMElyralab/MuseTalk.git
    cd MuseTalk
fi

# ── Step 2: Install Python Dependencies ─────────────────────────────────────
echo "[→] Installing MuseTalk Python dependencies..."
pip install -r requirements.txt

# Pin exact versions that MuseTalk was built for.
# The official download_weights.sh installs huggingface_hub[cli] which upgrades
# to v1.17+ and breaks transformers 4.39.2. We pin both to avoid this.
echo "[→] Pinning compatible dependency versions..."
pip install transformers==4.39.2 huggingface_hub==0.30.2

echo "[→] Restoring Gradio fix for LivePortrait compatibility..."
pip install --upgrade gradio gradio_client

echo "[→] Fixing Numpy 2.0 OpenCV breaking bug..."
pip install "numpy<2.0.0"

# Install gdown for Google Drive downloads (face-parse model)
pip install -q gdown

# ── Step 3: Install MMLab Suite ─────────────────────────────────────────────
# MuseTalk requires mmlab packages for face detection and pose estimation
echo "[→] Installing MMLab packages (mmengine, mmcv, mmdet, mmpose)..."
pip install --no-cache-dir -U openmim
mim install mmengine
mim install "mmcv>=2.0.1"
mim install "mmdet>=3.1.0"
mim install "mmpose>=1.1.0"

# ── Step 4: Ensure FFmpeg is installed ──────────────────────────────────────
if command -v ffmpeg &> /dev/null; then
    echo "[✓] FFmpeg already installed: $(ffmpeg -version 2>&1 | head -1)"
else
    echo "[→] Installing FFmpeg..."
    apt-get update -qq && apt-get install -y -qq ffmpeg
fi

export FFMPEG_PATH=$(which ffmpeg)
echo "[✓] FFMPEG_PATH=$FFMPEG_PATH"

# ── Step 5: Download Model Weights ──────────────────────────────────────────
# Matches the official MuseTalk download_weights.sh exactly.
#
# Required directory structure (relative to /workspace/MuseTalk/):
#   models/
#   ├── musetalk/           — V1 (musetalk.json + pytorch_model.bin)
#   ├── musetalkV15/        — V15 (musetalk.json + unet.pth) ← we use this
#   ├── dwpose/             — DWPose (dw-ll_ucoco_384.pth)
#   ├── face-parse-bisent/  — Face parsing (NOTE: "bisent" not "bisenet"!)
#   │   ├── 79999_iter.pth          ← from Google Drive
#   │   └── resnet18-5c106cde.pth   ← from PyTorch model zoo
#   ├── sd-vae/             — SD VAE (config.json + diffusion_pytorch_model.bin)
#   └── whisper/            — Whisper tiny (config + model + preprocessor)
echo "[→] Downloading MuseTalk model weights..."

# Create ALL model directories upfront
mkdir -p models/musetalk models/musetalkV15 models/dwpose \
         models/face-parse-bisent models/sd-vae models/whisper

# ── MuseTalk V15 weights (what we actually use) ──
if [ -f "models/musetalkV15/unet.pth" ] && [ -f "models/musetalkV15/musetalk.json" ]; then
    echo "[✓] MuseTalk V15 weights already downloaded"
else
    echo "[→] Downloading MuseTalk V15 weights (~3.4GB)..."
    huggingface-cli download TMElyralab/MuseTalk \
        --local-dir models \
        --include "musetalkV15/musetalk.json" "musetalkV15/unet.pth" \
        --local-dir-use-symlinks False
fi

# ── MuseTalk V1 config (fallback) ──
if [ -f "models/musetalk/musetalk.json" ]; then
    echo "[✓] MuseTalk V1 config already downloaded"
else
    echo "[→] Downloading MuseTalk V1 config..."
    huggingface-cli download TMElyralab/MuseTalk \
        --local-dir models \
        --include "musetalk/musetalk.json" "musetalk/pytorch_model.bin" \
        --local-dir-use-symlinks False
fi

# ── SD-VAE (latent space encoder/decoder) ──
# Code uses vae_type="sd-vae" → looks in models/sd-vae/
if [ -f "models/sd-vae/diffusion_pytorch_model.bin" ]; then
    echo "[✓] SD-VAE weights already downloaded"
else
    echo "[→] Downloading SD-VAE weights..."
    huggingface-cli download stabilityai/sd-vae-ft-mse \
        --local-dir models/sd-vae \
        --include "config.json" "diffusion_pytorch_model.bin" \
        --local-dir-use-symlinks False
fi

# ── Whisper (audio feature extraction) ──
if [ -f "models/whisper/pytorch_model.bin" ]; then
    echo "[✓] Whisper model already downloaded"
else
    echo "[→] Downloading Whisper model..."
    huggingface-cli download openai/whisper-tiny \
        --local-dir models/whisper \
        --include "config.json" "pytorch_model.bin" "preprocessor_config.json" \
        --local-dir-use-symlinks False
fi

# ── DWPose (face detection + landmarks) ──
if [ -f "models/dwpose/dw-ll_ucoco_384.pth" ]; then
    echo "[✓] DWPose model already downloaded"
else
    echo "[→] Downloading DWPose model..."
    huggingface-cli download yzd-v/DWPose \
        --local-dir models/dwpose \
        --include "dw-ll_ucoco_384.pth" \
        --local-dir-use-symlinks False
fi

# ── Face Parse BiSeNet (face segmentation) ──
# CRITICAL: directory MUST be "face-parse-bisent" (not "bisenet")
# These files come from Google Drive + PyTorch model zoo, NOT HuggingFace
if [ -f "models/face-parse-bisent/79999_iter.pth" ] && [ -f "models/face-parse-bisent/resnet18-5c106cde.pth" ]; then
    echo "[✓] Face parsing models already downloaded"
else
    echo "[→] Downloading face parsing model (79999_iter.pth) from Google Drive..."
    # gdown syntax: positional URL, NOT --id flag (older gdown versions don't support --id)
    gdown "https://drive.google.com/uc?id=154JgKpzCPW82qINcVieuPH3fZ2e0P812" \
        -O models/face-parse-bisent/79999_iter.pth \
        || {
            echo "[!] gdown failed, trying wget fallback..."
            # Direct download link as fallback
            pip install -q gdown --upgrade
            python -c "
import gdown
gdown.download(id='154JgKpzCPW82qINcVieuPH3fZ2e0P812', output='models/face-parse-bisent/79999_iter.pth', quiet=False)
"
        }

    echo "[→] Downloading ResNet18 backbone from PyTorch model zoo..."
    wget -q --show-progress -O models/face-parse-bisent/resnet18-5c106cde.pth \
        https://download.pytorch.org/models/resnet18-5c106cde.pth
fi

# ── Step 6: Create working directories ──────────────────────────────────────
mkdir -p /workspace/audio         # Put your audio files here
mkdir -p /workspace/output        # Intermediate files
mkdir -p /workspace/final         # Final output goes here

# ── Step 7: Comprehensive verification ──────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verifying installation..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check all required model files
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
echo "  Model files:"
check_file "models/musetalkV15/musetalk.json"
check_file "models/musetalkV15/unet.pth"
check_file "models/sd-vae/config.json"
check_file "models/sd-vae/diffusion_pytorch_model.bin"
check_file "models/whisper/pytorch_model.bin"
check_file "models/whisper/preprocessor_config.json"
check_file "models/dwpose/dw-ll_ucoco_384.pth"
check_file "models/face-parse-bisent/79999_iter.pth"
check_file "models/face-parse-bisent/resnet18-5c106cde.pth"

echo ""
echo "  Python imports:"
python -c "
import torch
print(f'  ✅ PyTorch: {torch.__version__}')
print(f'     CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'     GPU: {torch.cuda.get_device_name(0)}')
    print(f'     VRAM: {torch.cuda.get_device_properties(0).total_mem / 1e9:.1f} GB')

import transformers
print(f'  ✅ transformers: {transformers.__version__}')

import huggingface_hub
print(f'  ✅ huggingface_hub: {huggingface_hub.__version__}')

from transformers import WhisperModel
print(f'  ✅ WhisperModel import OK')

import mmcv
print(f'  ✅ mmcv: {mmcv.__version__}')
" || {
    echo "  ❌ Some imports failed — check error messages above"
    MISSING=$((MISSING + 1))
}

echo ""
if [ $MISSING -gt 0 ]; then
    echo "============================================"
    echo "  ⚠️  Setup completed with $MISSING issue(s)"
    echo "  Fix the missing items above before running"
    echo "============================================"
else
    echo "============================================"
    echo "  ✅ MuseTalk Setup Complete! All checks passed."
    echo "============================================"
fi

echo ""
echo "  FILES:"
echo "    /workspace/MuseTalk/          — MuseTalk codebase"
echo "    /workspace/audio/             — Put your audio files here"
echo "    /workspace/final/             — Lip-synced output"
echo ""
echo "  NEXT STEP:"
echo "    # Single portrait:"
echo "    bash /workspace/run_lipsync_pipeline.sh \\"
echo "      /workspace/Kid1.png /workspace/audio.mp3"
echo ""
echo "    # Batch all 10 kids:"
echo "    bash /workspace/run_batch_lipsync.sh /workspace/audio.mp3"
echo ""
echo "============================================"
