#!/bin/bash
# MLX (Live Video's local story model) ships its GPU shaders as .metal sources, which SwiftPM compiles with the
# Metal Toolchain (an Xcode component: xcodebuild -downloadComponent MetalToolchain). MusicAmp doesn't need them
# compiled: it loads the precompiled mlx.metallib it downloads next to the model (GPU.metallib, LocalStoryModel).
# Without the toolchain this puts mlx-swift in edit mode (Packages/mlx-swift, git-ignored) and leaves its shader
# folders out of the build. With the toolchain it does nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

if xcrun -sdk macosx metal --version >/dev/null 2>&1; then exit 0; fi

if [[ ! -d Packages/mlx-swift ]]; then
    swift package resolve >/dev/null
    swift package edit mlx-swift >/dev/null
fi

python3 -I - Packages/mlx-swift/Package.swift <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
mark = '"mlx/mlx/backend/cpu/gemms/simd_bf16.cpp",\n        ] + noCudaCmlxExcludes'
if '"mlx-generated/metal",' in s:
    sys.exit(0)
if mark not in s:
    sys.exit("mlx-precompiled-shaders: mlx-swift's Package.swift changed, update the patch")
s = s.replace(mark, '''"mlx/mlx/backend/cpu/gemms/simd_bf16.cpp",

            // MusicAmp: shaders come precompiled (mlx.metallib, see Scripts/mlx-precompiled-shaders.sh)
            "mlx/mlx/backend/metal/kernels",
            "mlx-generated/metal",
        ] + noCudaCmlxExcludes''')
open(p, "w").write(s)
print("mlx-swift: shaders left out of the build (precompiled mlx.metallib)")
EOF
