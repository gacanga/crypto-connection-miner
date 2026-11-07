@echo off
REM ===========================================================================
REM build_bench.bat - builds dev\gostbench.exe (GostMiner development bench) with nvcc + MSVC.
REM   Target : NVIDIA P104-100 (Pascal, sm_61), CUDA 12.9, Visual Studio 2022, static CUDA runtime.
REM   Extra nvcc flags : GOST_NVCC_EXTRA (e.g. -DGOST_RUNROLL=2), output name suffix : GOST_SUFFIX (dev\gostbench%GOST_SUFFIX%.exe)
REM   Log    : logs\build_bench.log
REM ===========================================================================
setlocal EnableExtensions
cd /d "%~dp0.."
if not exist logs mkdir logs
if not exist dev mkdir dev
set "LOG=%CD%\logs\build_bench.log"
echo [%date% %time%] build_bench start> "%LOG%"

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
nvcc --version >> "%LOG%" 2>&1

set "EXE=dev\gostbench%GOST_SUFFIX%.exe"
if exist "%EXE%" del /q "%EXE%"
echo [%date% %time%] compiling gpu\gostbench.cu %GOST_NVCC_EXTRA% -^> %EXE% >> "%LOG%"
nvcc -O3 %GOST_NVCC_EXTRA% -arch=sm_61 -Wno-deprecated-gpu-targets -allow-unsupported-compiler -std=c++17 ^
     -Igpu -Isrc -Xptxas -v -Xcompiler "/O2 /EHsc /W3 /MT" -cudart static ^
     -o "%EXE%" gpu\gostbench.cu src\gost_ref.c >> "%LOG%" 2>&1
if not exist "%EXE%" goto :fail
echo [%date% %time%] build_bench OK >> "%LOG%"
echo [exit 0]>> "%LOG%"
exit /b 0

:fail
echo [%date% %time%] build_bench FAILED >> "%LOG%"
echo [exit 1]>> "%LOG%"
exit /b 1
