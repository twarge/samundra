#!/bin/sh
# Build the hr4000-capture diagnostic tool.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O \
    apps/Samundra/Sources/HR4000.swift \
    apps/Samundra/Sources/SpectrometerModels.swift \
    apps/Samundra/Sources/HR4000Device.swift \
    apps/Samundra/Sources/Spectrum.swift \
    apps/Samundra/Sources/SpectrumProcessing.swift \
    Tools/hr4000-capture/main.swift \
    -framework IOUSBHost \
    -o build/hr4000-capture
echo "Built build/hr4000-capture"
