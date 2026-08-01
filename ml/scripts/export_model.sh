#!/usr/bin/env bash
#
# Turn a trained LoRA adapter into the model directory the iOS app ships.
#
# Three steps: fuse the adapter into the base weights, quantize the result to 4-bit, then strip the
# directory to what MLX Swift actually reads. The last step matters more than it sounds — the phone
# copy is the largest thing in the app bundle, and Hugging Face repos carry a lot that inference never
# touches.
#
# Usage:
#   ml/scripts/export_model.sh [adapter_dir] [output_dir]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="$ROOT/ml/.venv/bin/python"

BASE="${BASE_MODEL:-mlx-community/Qwen3-0.6B-bf16}"
ADAPTER="${1:-$ROOT/ml/out/qwen3-0.6b-lora}"
OUT="${2:-$ROOT/ml/out/pulse-expense-4bit}"
FUSED="$ROOT/ml/out/.fused-tmp"

echo "==> fusing adapter into base weights"
rm -rf "$FUSED"
"$PY" -m mlx_lm fuse \
  --model "$BASE" \
  --adapter-path "$ADAPTER" \
  --save-path "$FUSED"

echo "==> quantizing to 4-bit"
rm -rf "$OUT"
"$PY" -m mlx_lm convert \
  --hf-path "$FUSED" \
  --mlx-path "$OUT" \
  -q --q-bits 4 --q-group-size 64

rm -rf "$FUSED"

echo "==> contents"
ls -la "$OUT"
echo "==> total size"
du -sh "$OUT"

cat <<'NOTE'

The app needs this whole directory: model.safetensors, config.json, and the tokenizer files.
Drop it in as a folder reference so Xcode does not flatten it into the bundle root.
NOTE
