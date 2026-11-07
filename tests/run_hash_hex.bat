@echo off
REM run_hash_hex.bat <hex> [<hex> ...] - builds tests\hash_hex.exe (MSVC) if needed and prints the GOSTcoin hashes.
REM   Log: logs\hash_hex.log
setlocal EnableExtensions
cd /d "%~dp0.."
if not exist logs mkdir logs
set "LOG=%CD%\logs\hash_hex.log"
echo [%date% %time%] hash_hex> "%LOG%"
if not exist tests\hash_hex.exe (
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    set VSCMD_SKIP_SENDTELEMETRY=1
    call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    cl /nologo /O2 /MT /D_CRT_SECURE_NO_WARNINGS /Isrc tests\hash_hex.c src\gost_ref.c /Fe:tests\hash_hex.exe /Fo:tests\ >> "%LOG%" 2>&1
)
tests\hash_hex.exe %* >> "%LOG%" 2>&1
echo [exit 0]>> "%LOG%"
exit /b 0
