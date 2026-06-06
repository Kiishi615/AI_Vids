#!/bin/bash
###############################################################################
# EchoMimic v3 Flash-Pro — H100 One-Shot Setup
# 
# Run this ONCE when you spin up a fresh H100 instance.
# It clones the repo, installs dependencies, and downloads all models.
#
# Usage:  bash ~/workspace/h100_setup_echomimic.sh
# Time:   ~10-15 minutes (mostly model downloads, ~23GB total)
###############################################################################
set -euo pipefail

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     EchoMimic v3 Flash-Pro — H100 Setup                    ║"
echo "║     Resolution: 768×768 | Steps: 8 | VRAM: ~12-20GB        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

START=$(date +%s)
WORKSPACE="${HOME}"
REPO_DIR="${WORKSPACE}/echomimic_v3"
MODELS_DIR="${REPO_DIR}/models/flash"

# ─────────────────────────────────────────────────────────────────────
# Step 1: Clone the repository
# ─────────────────────────────────────────────────────────────────────
echo "━━━ [1/5] Cloning EchoMimic v3 repo ━━━"
if [ -d "${REPO_DIR}" ]; then
    echo "⚡ Repo already exists at ${REPO_DIR}, pulling latest..."
    cd "${REPO_DIR}" && git pull
else
    cd "${WORKSPACE}"
    git clone https://github.com/antgroup/echomimic_v3.git
    cd "${REPO_DIR}"
fi
echo "✅ Repo ready."
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 2: Fix requirements & Install Python dependencies
# ─────────────────────────────────────────────────────────────────────
echo "━━━ [2/5] Installing Python dependencies ━━━"

# Lightning AI uses newer Python (3.12) which doesn't support TF 2.15.
# We unpin tensorflow and a few others to let pip resolve them naturally.
echo "⚡ Patching strict version requirements for compatibility..."
sed -i 's/tensorflow==2.15.0/tensorflow/g' requirements.txt
sed -i 's/moviepy==2.2.1/moviepy/g' requirements.txt

pip install --upgrade pip setuptools wheel

# Install main requirements
pip install -r requirements.txt

# Install missing deps that infer_flash.py needs but aren't in requirements.txt
pip install pyloudnorm

# Fix dependency conflicts: Upgrade HF ecosystem
pip install --upgrade transformers huggingface_hub datasets gradio diffusers

# Explicitly force urllib3 downgrade to satisfy Lightning AI SDK
pip install "urllib3==2.5.0"

# Make sure huggingface-cli is available for fast model downloads
pip install -U "huggingface_hub[cli]"

echo "✅ Dependencies installed."
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 3: Download base model — Wan2.1-Fun-V1.1-1.3B-InP (~19GB)
# ─────────────────────────────────────────────────────────────────────
echo "━━━ [3/5] Downloading base model: Wan2.1-Fun-V1.1-1.3B-InP (~19GB) ━━━"
mkdir -p "${MODELS_DIR}"

if [ -d "${MODELS_DIR}/Wan2.1-Fun-V1.1-1.3B-InP" ] && [ "$(ls -A ${MODELS_DIR}/Wan2.1-Fun-V1.1-1.3B-InP 2>/dev/null)" ]; then
    echo "⚡ Base model already downloaded, skipping."
else
    python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='alibaba-pai/Wan2.1-Fun-V1.1-1.3B-InP', local_dir='${MODELS_DIR}/Wan2.1-Fun-V1.1-1.3B-InP')"
fi
echo "✅ Base model ready."
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 4: Download audio encoder — chinese-wav2vec2-base (~0.4GB)
# Flash-Pro uses chinese-wav2vec2-base (NOT wav2vec2-base-960h)
# ─────────────────────────────────────────────────────────────────────
echo "━━━ [4/5] Downloading audio encoder: chinese-wav2vec2-base (~0.4GB) ━━━"

if [ -d "${MODELS_DIR}/chinese-wav2vec2-base" ] && [ "$(ls -A ${MODELS_DIR}/chinese-wav2vec2-base 2>/dev/null)" ]; then
    echo "⚡ Audio encoder already downloaded, skipping."
else
    python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='TencentGameMate/chinese-wav2vec2-base', local_dir='${MODELS_DIR}/chinese-wav2vec2-base')" 2>/dev/null \
    || {
        echo "⚠️  HuggingFace download failed, trying ModelScope fallback..."
        pip install modelscope 2>/dev/null || true
        python3 -c "
from modelscope import snapshot_download
snapshot_download('TencentGameMate/chinese-wav2vec2-base', 
                  cache_dir='${MODELS_DIR}/chinese-wav2vec2-base')
"
    }
fi
echo "✅ Audio encoder ready."
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 5: Download EchoMimicV3 Flash-Pro transformer weights (~3.5GB)
# ─────────────────────────────────────────────────────────────────────
echo "━━━ [5/5] Downloading EchoMimicV3 Flash-Pro weights (~3.5GB) ━━━"

TRANSFORMER_FILE="${MODELS_DIR}/echomimicv3-flash-pro/diffusion_pytorch_model.safetensors"
if [ -f "${TRANSFORMER_FILE}" ]; then
    echo "⚡ Transformer weights already downloaded, skipping."
else
    python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='BadToBest/EchoMimicV3', allow_patterns='echomimicv3-flash-pro/**', local_dir='${MODELS_DIR}')"
fi
echo "✅ Transformer weights ready."
echo ""

# ─────────────────────────────────────────────────────────────────────
# Create input/output directories
# ─────────────────────────────────────────────────────────────────────
mkdir -p "${WORKSPACE}/inputs"
mkdir -p "${WORKSPACE}/outputs"

# ─────────────────────────────────────────────────────────────────────
# Verify setup
# ─────────────────────────────────────────────────────────────────────
echo "━━━ Verifying model files ━━━"
PASS=true

check_path() {
    if [ -e "$1" ]; then
        echo "  ✅ $2"
    else
        echo "  ❌ MISSING: $2 ($1)"
        PASS=false
    fi
}

check_path "${MODELS_DIR}/Wan2.1-Fun-V1.1-1.3B-InP" "Base model (Wan2.1-Fun-V1.1-1.3B-InP)"
check_path "${MODELS_DIR}/chinese-wav2vec2-base" "Audio encoder (chinese-wav2vec2-base)"
check_path "${TRANSFORMER_FILE}" "Flash-Pro transformer weights"

echo ""

if [ "$PASS" = true ]; then
    END=$(date +%s)
    ELAPSED=$((END - START))
    MINS=$((ELAPSED / 60))
    SECS=$((ELAPSED % 60))

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✅ SETUP COMPLETE in ${MINS}m ${SECS}s                          ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  Next steps:                                               ║"
    echo "║  1. Upload portrait  → ~/inputs/portrait.png               ║"
    echo "║  2. Upload audio     → ~/inputs/audio.wav                  ║"
    echo "║  3. Run test:  bash ~/AI_Vids/run_echomimic_test.sh        ║"
    echo "║  4. Run full:  bash ~/AI_Vids/run_echomimic_full.sh        ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
else
    echo "❌ SETUP INCOMPLETE — Some models are missing. Check errors above."
    exit 1
fi
