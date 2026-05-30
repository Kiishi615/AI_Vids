#!/bin/bash
# ============================================================================
# Fix: numpy binary incompatibility on Lightning AI
# ============================================================================
#
# PROBLEM:
#   "numpy.dtype size changed, may indicate binary incompatibility.
#    Expected 96 from C header, got 88 from PyObject"
#
#   Lightning AI's pre-compiled packages expect numpy 2.x (dtype=96 bytes),
#   but our setup pinned numpy==1.26.4 (dtype=88 bytes).
#
# FIX:
#   Upgrade numpy to 2.x so it matches the pre-compiled C extensions.
#
# USAGE:
#   bash ~/workspace/fix_numpy_compat.sh
#
# TIME: ~2 minutes
# ============================================================================

set -e

echo ""
echo "============================================"
echo "  🔧 Fixing numpy binary incompatibility"
echo "============================================"
echo ""

# ── Step 1: Check current numpy version ─────────────────────────────────────
CURRENT=$(python -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "not installed")
echo "  Current numpy: $CURRENT"

# ── Step 2: Upgrade numpy to 2.x ────────────────────────────────────────────
echo "  [→] Upgrading numpy to 2.x..."
pip install --no-cache-dir "numpy>=2.0,<2.2" 2>&1 | tail -3

NEW_VER=$(python -c "import numpy; print(numpy.__version__)" 2>/dev/null)
echo "  [✓] numpy now: $NEW_VER"

# ── Step 3: Force-reinstall packages with C extensions ──────────────────────
# These may have cached bindings to the old numpy ABI
echo ""
echo "  [→] Rebuilding C-extension packages against numpy $NEW_VER..."
pip install --no-cache-dir --force-reinstall \
    scipy \
    scikit-image \
    2>&1 | tail -5

echo "  [✓] Rebuilt scipy + scikit-image"

# Also ensure opencv is compatible
pip install --no-cache-dir --force-reinstall \
    "opencv-python>=4.9" \
    2>&1 | tail -3

echo "  [✓] Rebuilt opencv"

# ── Step 4: Verify the full import chain ────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verifying import chain..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

python -c "
import sys
print(f'  Python:        {sys.version.split()[0]}')

import numpy as np
print(f'  numpy:         {np.__version__}  ✅')

import scipy
print(f'  scipy:         {scipy.__version__}  ✅')

from skimage import transform
print(f'  scikit-image:  OK  ✅')

import torch
print(f'  torch:         {torch.__version__}  ✅')
if torch.cuda.is_available():
    print(f'  GPU:           {torch.cuda.get_device_name(0)}')

# This is the exact chain that was failing:
import transformers
print(f'  transformers:  {transformers.__version__}  ✅')

import diffusers
print(f'  diffusers:     {diffusers.__version__}  ✅')

from diffusers.models.autoencoders.autoencoder_kl import AutoencoderKL
print(f'  AutoencoderKL: importable  ✅')

import kornia
print(f'  kornia:        {kornia.__version__}  ✅')

import librosa
print(f'  librosa:       {librosa.__version__}  ✅')

import cv2
print(f'  opencv:        {cv2.__version__}  ✅')

import mediapipe
print(f'  mediapipe:     {mediapipe.__version__}  ✅')

import insightface
print(f'  insightface:   {insightface.__version__}  ✅')

print()
print('  🎉 All imports passed — LatentSync should work now!')
" 2>&1

RESULT=$?

echo ""
if [ $RESULT -eq 0 ]; then
    echo "============================================"
    echo "  ✅ Fixed! Re-run your pipeline:"
    echo ""
    echo "  bash ~/workspace/lightning_run_pipeline.sh \\"
    echo "    ~/workspace/portraits/Kid1.png \\"
    echo "    ~/workspace/audio/5min.mp3"
    echo "============================================"
else
    echo "============================================"
    echo "  ⚠ Some imports still failing — check above"
    echo "============================================"
    echo ""
    echo "  If mediapipe or insightface fail, try:"
    echo "    pip install --force-reinstall mediapipe insightface"
fi
echo ""
