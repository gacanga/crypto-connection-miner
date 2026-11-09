@echo off
REM ===========================================================================
REM build_miner.bat [output exe] - builds Crypto Connection Miner 0.7 (multi-coin NVIDIA miner: gostd GOSTcoin, lyra2v2 Bitmark,
REM   neoscrypt Feathercoin, ting Daler;
REM   solo + pool, no dev fee) with nvcc + MSVC.
REM   Output : the given path relative to the gostminer folder (default dev\gostminer.exe)
REM            -> a new version can be built while dev\gostminer.exe is mining.
REM   GPUs   : machine code for every NVIDIA generation CUDA 12.9 targets (Maxwell sm_50 to Blackwell sm_120)
REM            + PTX compute_120 for later GPUs. Set GM_ARCHS to build fewer, e.g. set GM_ARCHS=-arch=sm_61
REM   Needs  : CUDA 12.9, Visual Studio 2022 (C++ tools). Static CUDA and C runtimes.
REM   Sources: gpu\gostminer.cu, gpu\lyra2v2\*.cu + gpu\neoscrypt\*.cu (MYMINER / ccminer kernels, GPL-3), gpu\ting\ting_gpu.cu, src\gost_ref.c,
REM            src\sha256.c, src\lyra2ref\*.c + src\lyra2ref\sha3\*.c (CPU reference of lyra2rev2, MiningCore libmultihash),
REM            src\neoscrypt\neoscrypt.c (CPU reference of NeoScrypt, BSD)
REM   Log    : logs\build_miner.log
REM ===========================================================================
setlocal EnableExtensions
cd /d "%~dp0.."
if not exist logs mkdir logs
if not exist dev mkdir dev
set "OUT=%~1"
if "%OUT%"=="" set "OUT=dev\gostminer.exe"
set "LOG=%CD%\logs\build_miner.log"
echo [%date% %time%] build_miner start -^> %OUT%> "%LOG%"
set "CUDA129=%CUDA_PATH_V12_9%"
if "%CUDA129%"=="" set "CUDA129=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9"
if not exist "%CUDA129%\bin\nvcc.exe" (
    echo ERROR: CUDA 12.9 nvcc.exe not found >> "%LOG%"
    goto :fail
)
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSINSTALL="
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%i"
)
if "%VSINSTALL%"=="" set "VSINSTALL=C:\Program Files\Microsoft Visual Studio\2022\Community"
if not exist "%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat" (
    echo ERROR: vcvars64.bat not found under "%VSINSTALL%" >> "%LOG%"
    goto :fail
)
set VSCMD_SKIP_SENDTELEMETRY=1
call "%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "PATH=%CUDA129%\bin;%PATH%"
if "%GM_ARCHS%"=="" set "GM_ARCHS=-gencode arch=compute_50,code=sm_50 -gencode arch=compute_52,code=sm_52 -gencode arch=compute_60,code=sm_60 -gencode arch=compute_61,code=sm_61 -gencode arch=compute_70,code=sm_70 -gencode arch=compute_75,code=sm_75 -gencode arch=compute_80,code=sm_80 -gencode arch=compute_86,code=sm_86 -gencode arch=compute_89,code=sm_89 -gencode arch=compute_90,code=sm_90 -gencode arch=compute_100,code=sm_100 -gencode arch=compute_120,code=sm_120 -gencode arch=compute_120,code=compute_120"
nvcc --version >> "%LOG%" 2>&1
echo archs: %GM_ARCHS% >> "%LOG%"
if exist "%OUT%" del /q "%OUT%"
if exist "%OUT%" (
    echo ERROR: %OUT% is in use >> "%LOG%"
    goto :fail
)
set "L2=gpu\lyra2v2\lyra2v2_gpu.cu gpu\lyra2v2\ccminer_shim.cu gpu\lyra2v2\cuda_blake256.cu gpu\lyra2v2\cuda_bmw256.cu gpu\lyra2v2\cuda_cubehash256.cu gpu\lyra2v2\cuda_skein256.cu gpu\lyra2v2\cuda_lyra2v2.cu"
set "NS=gpu\neoscrypt\neoscrypt_gpu.cu gpu\neoscrypt\cuda_neoscrypt.cu"
set "TING=gpu\ting\ting_gpu.cu"
set "REF=src\neoscrypt\neoscrypt.c src\gost_ref.c src\sha256.c src\lyra2ref\lyra2re2_only.c src\lyra2ref\Lyra2.c src\lyra2ref\Sponge.c src\lyra2ref\sha3\sph_blake.c src\lyra2ref\sha3\sph_keccak.c src\lyra2ref\sha3\sph_cubehash.c src\lyra2ref\sha3\sph_skein.c src\lyra2ref\sha3\sph_bmw.c"
if not exist build\win mkdir build\win
echo [%date% %time%] compiling gpu\gostminer.cu + lyra2v2, neoscrypt and ting kernels + CPU references >> "%LOG%"
nvcc -O3 --threads 0 %GM_ARCHS% -Wno-deprecated-gpu-targets -allow-unsupported-compiler -std=c++17 ^
     -Igpu -Isrc -Igpu\lyra2v2 -Xptxas -v -Xcompiler "/O2 /EHsc /W3 /MT" -cudart static -odir build\win ^
     -o "%OUT%" gpu\gostminer.cu %L2% %NS% %TING% %REF% -lws2_32 >> "%LOG%" 2>&1
if not exist "%OUT%" goto :fail
echo [%date% %time%] build_miner OK >> "%LOG%"
echo [exit 0]>> "%LOG%"
exit /b 0
:fail
echo [%date% %time%] build_miner FAILED >> "%LOG%"
echo [exit 1]>> "%LOG%"
exit /b 1
