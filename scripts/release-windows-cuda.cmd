@echo off
rem bs_roformer-cli with its ggml libraries for Windows x64 on CUDA, machine code for every card of the toolkit (no PTX),
rem no native CPU flags, no AVX-512, no NCCL; ggml from the ggml folder beside CMakeLists.txt (the release's GGML_DIR).
rem   cuda (default): CUDA 13.3, sm 75/80/86/89/90/120a.
rem   cuda12:         CUDA 12.9 (D:\Projects\_tools\cuda-12.9, MSVC 14.44), sm 52/60/61/70/75/80/86/89/90/120a.
rem   vulkan:         the Vulkan backend (LunarG Vulkan SDK; the system's vulkan-1.dll at run time).
rem   cpu:            the processor alone.
rem   scripts\release-windows-cuda.cmd <output folder> <build folder> [cuda|cuda12|vulkan|cpu]
rem Each backend is set up by its own label: inside an if-block cmd expands %PATH% before vcvars runs.
setlocal
set "OUT=%~1"
set "BUILD=%~2"
set "BACKEND=%~3"
if "%BACKEND%"=="" set "BACKEND=cuda"
if "%OUT%"=="" (echo [ERROR] output folder & exit /b 1)
if "%BUILD%"=="" (echo [ERROR] build folder & exit /b 1)
set VSLANG=1033
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if /i not "%BACKEND%"=="cuda" if /i not "%BACKEND%"=="cuda12" if /i not "%BACKEND%"=="vulkan" if /i not "%BACKEND%"=="cpu" (
  echo [ERROR] backend %BACKEND%: cuda, cuda12, vulkan or cpu
  exit /b 1
)
goto :setup_%BACKEND%

:setup_cuda
set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3"
call "%VCVARS%" >nul
set "FLAGS=-DGGML_CUDA=ON -DGGML_CUDA_FORCE_MMQ=ON -DGGML_CUDA_NCCL=OFF -DCMAKE_CUDA_ARCHITECTURES=75-real;80-real;86-real;89-real;90-real;120a-real"
goto :configure

:setup_vulkan
set "VULKAN_SDK=C:\VulkanSDK\1.4.357.0"
call "%VCVARS%" >nul
set "FLAGS=-DGGML_CUDA=OFF -DGGML_VULKAN=ON"
goto :configure

:setup_cpu
call "%VCVARS%" >nul
set "FLAGS=-DGGML_CUDA=OFF"
goto :configure

:setup_cuda12
set "CUDA_PATH=D:\Projects\_tools\cuda-12.9"
call "%VCVARS%" -vcvars_ver=14.44 >nul
set "PATH=D:\Projects\_tools\cuda-12.9\bin;%PATH%"
set "FLAGS=-DGGML_CUDA=ON -DGGML_CUDA_FORCE_MMQ=ON -DGGML_CUDA_NCCL=OFF -DCUDAToolkit_ROOT=D:/Projects/_tools/cuda-12.9 -DCMAKE_CUDA_COMPILER=D:/Projects/_tools/cuda-12.9/bin/nvcc.exe -DCMAKE_CUDA_FLAGS=-Wno-deprecated-gpu-targets -DCMAKE_CUDA_ARCHITECTURES=52-real;60-real;61-real;70-real;75-real;80-real;86-real;89-real;90-real;120a-real"
goto :configure

:configure
where cl >nul 2>&1 || (echo [ERROR] MSVC is not set up for %BACKEND% & exit /b 1)
cd /d "%~dp0.."
if not exist ggml\CMakeLists.txt (echo [ERROR] no ggml folder & exit /b 1)
echo [..] %BACKEND%
rem settings come from this script alone, not from a cache an earlier run left
cmake --fresh -S . -B "%BUILD%" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_DIR=ggml ^
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl ^
  -DBSR_BUILD_TESTS=OFF -DBSR_BUILD_CLI=ON ^
  -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_NATIVE=OFF ^
  %FLAGS% >nul || (echo [ERROR] configure & exit /b 1)
echo [..] build
start "" /b /belownormal /wait cmake --build "%BUILD%" -j 8 || (echo [ERROR] build & exit /b 1)
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%"
for /r "%BUILD%" %%f in (bs_roformer-cli.exe ggml*.dll) do copy /y "%%f" "%OUT%\" >nul
dir /b "%OUT%"
echo [OK] bs_roformer-cli (%BACKEND%)
exit /b 0
