#!/bin/bash
# Jalankan di Mac: ./setup.sh  → menghasilkan NAMLoader.xcodeproj
set -e
[ -d NeuralAmpModelerCore ] || git clone --recursive https://github.com/sdatkinson/NeuralAmpModelerCore.git
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
open NAMLoader.xcodeproj
