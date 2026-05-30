#!/bin/bash
# ============================================================================
# Lightning AI — One-Shot Setup (Run on T4)
# ============================================================================
#
# Does EVERYTHING in one go:
#   1. System deps (ffmpeg, compilers)
#   2. Conda env with ALL packages (pinned versions)
#   3. Clone repos
#   4. Download model weights (~8GB)
#   5. Verify everything works (imports + GPU test)
#
# RUN ON: T4 (costs ~20 min of your 79 free hours)
# TIME:   ~15-20 min (mostly downloading weights)
#
# USAGE:
#   bash lightning_setup.sh
#
# ============================================================================

set -e

WORKSPACE="$HOME/workspace"
CONDA_ENV="base"  # Lightning AI only allows 1 env — use the default

echo ""
echo "============================================"
echo "  ⚡ Lightning AI — Full Setup"
echo "  Running on: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'CPU')"
echo "============================================"
echo ""

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# ── 1. System packages ─────────────────────────────────────────────────────
echo "[1/5] System dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential libgl1 ffmpeg git-lfs 2>/dev/null || true
echo "  [✓] Done"

# ── 2. Conda environment + ALL packages ────────────────────────────────────
# Lightning AI only allows 1 conda env per Studio — use the default
echo "[2/5] Using default environment..."
echo "  [✓] Python $(python --version) at $(which python)"

echo "  [→] Installing packages (this takes a few minutes)..."
pip install --no-cache-dir --upgrade pip setuptools wheel

# PyTorch with CUDA 12.1
pip install --no-cache-dir \
    torch==2.3.1 torchvision==0.18.1 torchaudio==2.3.1 \
    --index-url https://download.pytorch.org/whl/cu121

# All project dependencies (pinned)
pip install --no-cache-dir \
    numpy==1.26.4 \
    "opencv-python==4.9.0.80" \
    Pillow==10.2.0 \
    imageio==2.31.1 \
    imageio-ffmpeg==0.5.1 \
    ffmpeg-python==0.2.0 \
    einops==0.7.0 \
    omegaconf==2.3.0 \
    pyyaml tqdm scipy scikit-image \
    diffusers==0.32.2 \
    transformers==4.48.0 \
    accelerate==0.26.1 \
    python_speech_features==0.6 \
    librosa==0.10.1 \
    scenedetect==0.6.1 \
    lpips==0.1.4 \
    face-alignment==1.4.1 \
    huggingface-hub==0.30.2 \
    kornia==0.8.0 \
    DeepCache==0.1.1 \
    mediapipe==0.10.14 \
    safetensors \
    tyro dill lmdb \
    pykalman \
    "gradio==5.24.0"

# Packages that can be flaky
pip install --no-cache-dir decord==0.6.0 2>/dev/null || \
    pip install --no-cache-dir decord 2>/dev/null || \
    echo "  [⚠] decord skipped (non-critical)"

pip install --no-cache-dir onnxruntime-gpu==1.21.0 2>/dev/null || \
    pip install --no-cache-dir onnxruntime-gpu 2>/dev/null || \
    echo "  [⚠] onnxruntime-gpu install issue"

pip install --no-cache-dir insightface==0.7.3 2>/dev/null || \
    pip install --no-cache-dir insightface 2>/dev/null || \
    echo "  [⚠] insightface install issue"

echo "  [✓] All packages installed"

# ── 3. Clone repos ─────────────────────────────────────────────────────────
echo "[3/5] Cloning repositories..."
cd "$WORKSPACE"

if [ -d "LivePortrait" ]; then
    echo "  [✓] LivePortrait exists"
else
    git clone https://github.com/KwaiVGI/LivePortrait.git
    echo "  [✓] LivePortrait cloned"
fi

if [ -d "LatentSync" ]; then
    echo "  [✓] LatentSync exists"
else
    git clone https://github.com/bytedance/LatentSync.git
    echo "  [✓] LatentSync cloned"
fi

# ── 4. Download model weights ──────────────────────────────────────────────
echo "[4/5] Downloading model weights (~8GB total)..."

# LivePortrait (~4GB)
cd "$WORKSPACE/LivePortrait"
if [ -d "pretrained_weights" ] && [ "$(ls -A pretrained_weights 2>/dev/null)" ]; then
    echo "  [✓] LivePortrait weights exist"
else
    mkdir -p pretrained_weights
    echo "  [→] LivePortrait weights (~4GB)..."
    huggingface-cli download KwaiVGI/LivePortrait --local-dir pretrained_weights
fi

# LatentSync (~3.5GB)
cd "$WORKSPACE/LatentSync"
mkdir -p checkpoints/whisper

if [ -f "checkpoints/latentsync_unet.pt" ]; then
    echo "  [✓] LatentSync UNet checkpoint exists"
else
    echo "  [→] LatentSync UNet (~3.2GB)..."
    huggingface-cli download ByteDance/LatentSync-1.6 \
        latentsync_unet.pt --local-dir checkpoints
fi

if [ -f "checkpoints/whisper/tiny.pt" ]; then
    echo "  [✓] Whisper checkpoint exists"
else
    echo "  [→] Whisper tiny..."
    huggingface-cli download ByteDance/LatentSync-1.6 \
        whisper/tiny.pt --local-dir checkpoints
fi

# ── 5. Verify everything ──────────────────────────────────────────────────
echo "[5/5] Verifying..."
echo ""

mkdir -p "$WORKSPACE/portraits" "$WORKSPACE/output" "$WORKSPACE/final" "$WORKSPACE/audio"

ERRORS=0

python -c "
import sys, torch
print(f'Python:       {sys.version.split()[0]}')
print(f'PyTorch:      {torch.__version__}')
print(f'CUDA:         {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU:          {torch.cuda.get_device_name(0)}')
    vram = torch.cuda.get_device_properties(0).total_memory / 1e9
    print(f'VRAM:         {vram:.1f} GB')

import diffusers, transformers, kornia, librosa, cv2, mediapipe, insightface
print(f'diffusers:    {diffusers.__version__}  ✅')
print(f'transformers: {transformers.__version__}  ✅')
print(f'kornia:       {kornia.__version__}  ✅')
print(f'opencv:       {cv2.__version__}  ✅')
print(f'mediapipe:    {mediapipe.__version__}  ✅')
print(f'insightface:  {insightface.__version__}  ✅')
" 2>&1 || ERRORS=$((ERRORS + 1))

echo ""
echo "Checkpoints:"
for f in "$WORKSPACE/LatentSync/checkpoints/latentsync_unet.pt" \
         "$WORKSPACE/LatentSync/checkpoints/whisper/tiny.pt"; do
    if [ -f "$f" ]; then
        echo "  ✅ $(basename $f) ($(du -sh "$f" | cut -f1))"
    else
        echo "  ❌ MISSING: $f"
        ERRORS=$((ERRORS + 1))
    fi
done
if [ -d "$WORKSPACE/LivePortrait/pretrained_weights" ]; then
    echo "  ✅ LivePortrait weights ($(du -sh --apparent-size "$WORKSPACE/LivePortrait/pretrained_weights" 2>/dev/null | cut -f1))"
else
    echo "  ❌ MISSING: LivePortrait weights"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ $ERRORS -gt 0 ]; then
    echo "⚠ $ERRORS issue(s) — check above"
else
    echo "============================================"
    echo "  ✅ Setup Complete! Everything works."
    echo "============================================"
    echo ""
    echo "  Upload your files:"
    echo "    Portraits → $WORKSPACE/portraits/"
    echo "    Audio     → $WORKSPACE/audio/"
    echo ""
    echo "  Run the pipeline:"
    echo "    conda activate $CONDA_ENV"
    echo "    bash $WORKSPACE/lightning_run_pipeline.sh \\"
    echo "      $WORKSPACE/portraits/Kid1.png \\"
    echo "      $WORKSPACE/audio/song.mp3"
    echo ""
    echo "  💡 LivePortrait runs fine on T4."
    echo "  💡 For LatentSync, switch to L40S for best results."
    echo "============================================"
fi
