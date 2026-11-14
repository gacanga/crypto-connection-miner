@echo off
REM start_chipcoin_cpu.bat - Chipcoin (CHC) on the CPU, Crypto Connection pool: put your Chipcoin address (CHCQ...) in ADDRESS, then double-click.
REM   No GPU and no NVIDIA driver needed. THREADS: number of mining threads (empty = every hardware thread; they run at low
REM   priority). DIFF: fixed share difficulty (0.1 = the pool minimum, about one share every 43 s at 10 MH/s; empty = vardiff).
REM   A Chipcoin mainnet address (post-quantum, starts with CHCQ) comes from the official Chipcoin wallet (chipcoinprotocol.com,
REM   github.com/chipcoin-protocol/chipcoin: chipcoin wallet-generate). A standard sha256d cpuminer cannot mine Chipcoin (the
REM   hash is read big-endian): this miner can.
set ADDRESS=YOUR_CHC_ADDRESS
set WORKER=cpu1
set POOL=crypto-connection.net:4093
set THREADS=
set DIFF=0.1
if "%ADDRESS%"=="YOUR_CHC_ADDRESS" (echo Edit start_chipcoin_cpu.bat first: put your Chipcoin address in ADDRESS. & pause & exit /b 1)
set PASS=x
if not "%DIFF%"=="" set PASS=d=%DIFF%
set TOPT=
if not "%THREADS%"=="" set TOPT=--threads %THREADS%
:loop
crypto-connection-miner.exe --algo chc --cpu %TOPT% --pool %POOL% --user %ADDRESS%.%WORKER% --pass %PASS% --log miner_chipcoin_cpu.log
echo Miner stopped (exit code %ERRORLEVEL%), restart in 5 s (close this window to quit)
timeout /t 5 /nobreak >nul
goto loop
