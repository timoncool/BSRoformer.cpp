#!/bin/bash
# bs_roformer-cli with its ggml libraries for Linux x86-64 on CUDA, built in an Ubuntu 22.04 container (glibc 2.35: runs
# there and on anything newer) from the committed HEAD and the ggml folder's checked-out commit, machine code for every
# card of the toolkit (no PTX), no native CPU flags, no AVX-512, no NCCL.
#   cuda (default): CUDA 13.3, sm 75/80/86/89/90/120a.
#   cuda12:         CUDA 12.9, sm 52/60/61/70/75/80/86/89/90/120a.
# RUNPATH looks beside the program, in ../../models/higgs-engine, where a studio keeps the CUDA 13 runtime and cuBLAS,
# and in ../../models/cuda12-runtime, where it keeps those of CUDA 12.9; libgomp is copied beside the program.
#   vulkan:         the Vulkan backend (LunarG Vulkan SDK; the system's Vulkan loader at run time).
#   cpu:            the processor alone.
#   scripts/release-linux-cuda-docker.sh <output folder> [cache folder] [cuda|cuda12|vulkan|cpu]
set -euo pipefail

VULKAN_SDK_VERSION="1.4.357.0"

if [ "${1:-}" = "--inside" ]; then
  backend="$2"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null
  apt-get install -y -q --no-install-recommends git ninja-build python3-pip ca-certificates build-essential patchelf >/dev/null
  pip3 install -q "cmake>=3.28" >/dev/null
  cuda=(-DGGML_CUDA=ON -DGGML_CUDA_FORCE_MMQ=ON -DGGML_CUDA_NCCL=OFF)
  case "$backend" in
    cuda) flags=("${cuda[@]}" "-DCMAKE_CUDA_ARCHITECTURES=75-real;80-real;86-real;89-real;90-real;120a-real") ;;
    cuda12) flags=("${cuda[@]}" "-DCMAKE_CUDA_FLAGS=-Wno-deprecated-gpu-targets"
                   "-DCMAKE_CUDA_ARCHITECTURES=52-real;60-real;61-real;70-real;75-real;80-real;86-real;89-real;90-real;120a-real") ;;
    vulkan)
      apt-get install -y -q --no-install-recommends curl xz-utils >/dev/null
      sdk=/cache/vulkansdk-$VULKAN_SDK_VERSION
      if [ ! -x "$sdk/x86_64/bin/glslc" ]; then
        echo "[..] Vulkan SDK $VULKAN_SDK_VERSION"
        rm -rf "$sdk" && mkdir -p "$sdk"
        curl -fsSL "https://sdk.lunarg.com/sdk/download/$VULKAN_SDK_VERSION/linux/vulkansdk-linux-x86_64-$VULKAN_SDK_VERSION.tar.xz" | tar -xJ -C "$sdk" --strip-components=1
      fi
      export VULKAN_SDK="$sdk/x86_64" PATH="$sdk/x86_64/bin:$PATH"
      cp -P "$sdk"/x86_64/lib/VulkanLoader/lib/libvulkan.so* /usr/lib/x86_64-linux-gnu/
      flags=(-DGGML_CUDA=OFF -DGGML_VULKAN=ON -DVulkan_LIBRARY=/usr/lib/x86_64-linux-gnu/libvulkan.so) ;;
    cpu) flags=(-DGGML_CUDA=OFF) ;;
    *) echo "[ERROR] backend $backend: cuda, cuda12, vulkan or cpu"; exit 1 ;;
  esac
  echo "[..] source $(git -c safe.directory='*' -C /src rev-parse --short HEAD), ggml $(git -c safe.directory='*' -C /src/ggml rev-parse --short HEAD), $backend"
  rm -rf /cache/src && mkdir -p /cache/src/ggml
  git -c safe.directory='*' -C /src archive HEAD | tar -x -C /cache/src
  git -c safe.directory='*' -C /src/ggml archive HEAD | tar -x -C /cache/src/ggml
  cd /cache/src
  # settings come from this script alone, not from a cache an earlier run left
  rm -rf "/cache/build-$backend/CMakeCache.txt"
  cmake -B "/cache/build-$backend" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_DIR=ggml \
    -DBSR_BUILD_TESTS=OFF -DBSR_BUILD_CLI=ON \
    -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_NATIVE=OFF \
    '-DCMAKE_BUILD_RPATH=$ORIGIN;$ORIGIN/../../models/higgs-engine;$ORIGIN/../../models/cuda12-runtime' "${flags[@]}" >/dev/null
  echo "[..] build"
  cmake --build "/cache/build-$backend" -j "$(( $(nproc) * 3 / 4 ))" 2>&1 | tail -3
  out="/out/$backend"
  rm -rf "$out" && mkdir -p "$out"
  cp "$(find "/cache/build-$backend" -name bs_roformer-cli -type f -perm -u+x | head -1)" "$out/"
  # core libs by SONAME plus the loadable backend modules (ggml-cpu-<variant> and ggml-cuda — no version suffix) that
  # ggml_backend_load_all picks from at run time by cpuid; not the version links that copy the same file again
  find "/cache/build-$backend" \( -name 'libggml.so.0' -o -name 'libggml-base.so.0' -o -name 'libggml-cpu-*.so' -o -name 'libggml-cuda.so' -o -name 'libggml-vulkan.so' \) | while read -r f; do cp -L "$f" "$out/"; done
  cp "$(gcc -print-file-name=libgomp.so.1)" "$out/"
  # the CUDA toolkit's folder of the build machine must not reach a user's machine
  for f in "$out"/bs_roformer-cli "$out"/libggml*.so*; do patchelf --set-rpath '$ORIGIN:$ORIGIN/../../models/higgs-engine:$ORIGIN/../../models/cuda12-runtime' "$f"; done
  for f in "$out"/*; do echo "$(basename "$f"): zmm $(objdump -d --no-show-raw-insn "$f" | grep -c '%zmm' || true)"; done
  readelf -d "$out/bs_roformer-cli" | grep -E 'NEEDED|RUNPATH'
  sha256sum "$out"/*
  echo "[OK] bs_roformer-cli ($backend)"
  exit 0
fi

out="${1:?output folder}"
cache="${2:-$HOME/bsroformer-linux2204-cache}"
backend="${3:-cuda}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$out" "$cache"
cp "$repo/scripts/release-linux-cuda-docker.sh" "$out/.release-linux-cuda-docker.sh"
image=ubuntu:22.04
[ "$backend" = "cuda" ] && image=nvidia/cuda:13.3.1-devel-ubuntu22.04
[ "$backend" = "cuda12" ] && image=nvidia/cuda:12.9.1-devel-ubuntu22.04
docker run --rm --cpus "$(( $(nproc) * 2 / 3 ))" -v "$repo:/src:ro" -v "$(cd "$out" && pwd):/out" -v "$cache/$backend:/cache" "$image" bash /out/.release-linux-cuda-docker.sh --inside "$backend"
