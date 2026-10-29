#!/bin/bash
# Jalankan di Mac: ./setup.sh  → menghasilkan NAMLoader.xcodeproj
set -e
bash scripts/fetch_nam_core.sh
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
open NAMLoader.xcodeproj
