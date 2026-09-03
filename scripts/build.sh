#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

if [ ! -d "vendor/dobby" ]; then
    echo "[build] Cloning Dobby..."
    git clone --depth=1 https://github.com/jmpews/Dobby.git vendor/dobby
fi

if [ ! -f "build/vendor/dobby/libdobby.a" ]; then
    echo "[build] Building Dobby..."
    mkdir -p build
    cd build
    cmake ../vendor/dobby \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DDOBBY_DEBUG=OFF \
        -DDOBBY_GENERATE_SHARED=OFF \
        -G "Unix Makefiles"
    make -j$(sysctl -n hw.ncpu)
    cd "$PROJECT_DIR"
fi

make -j$(sysctl -n hw.ncpu)

if [ -f out/macsteam.dylib ]; then
    echo "[build] OK: out/macsteam.dylib"
else
    echo "[build] FAILED"
    exit 1
fi
