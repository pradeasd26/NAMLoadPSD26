#!/bin/bash
# Mengunduh NeuralAmpModelerCore pada commit yang sudah diuji, beserta Eigen.
# Dipakai oleh setup.sh (Mac) dan workflow GitHub Actions.
set -euo pipefail

NAM_COMMIT="0b3d3c97b0859a3a8c92a8628c4dd89a25eb5842"
DIR="NeuralAmpModelerCore"

if [ -d "$DIR/NAM" ] && [ -f "$DIR/Dependencies/eigen/Eigen/Dense" ]; then
  echo "NAM Core sudah ada, dilewati."
  exit 0
fi

rm -rf "$DIR"
git clone https://github.com/sdatkinson/NeuralAmpModelerCore.git "$DIR"
git -C "$DIR" checkout --quiet "$NAM_COMMIT"
# Hanya Eigen yang dibutuhkan (AudioDSPTools tidak dipakai di app).
git -C "$DIR" submodule update --init --depth 1 Dependencies/eigen \
  || git -C "$DIR" submodule update --init Dependencies/eigen
echo "NAM Core @ $NAM_COMMIT siap."
