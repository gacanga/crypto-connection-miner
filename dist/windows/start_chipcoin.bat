@echo off
REM start_chipcoin.bat - Chipcoin (CHC, sha256d read big-endian) on the Crypto Connection pool: put your Chipcoin address (CHCQ...) in ADDRESS, then double-click.
REM   A Chipcoin mainnet address (post-quantum, starts with CHCQ) comes from the official Chipcoin wallet (chipcoinprotocol.com,
REM   github.com/chipcoin-protocol/chipcoin: chipcoin wallet-generate). Bitcoin ASICs cannot mine Chipcoin: GPUs only.
set ADDRESS=YOUR_CHC_ADDRESS
set WORKER=rig1
set POOL=crypto-connection.net:4093
if "%ADDRESS%"=="YOUR_CHC_ADDRESS" (echo Edit start_chipcoin.bat first: put your Chipcoin address in ADDRESS. & pause & exit /b 1)
:loop
crypto-connection-miner.exe --algo chc --pool %POOL% --user %ADDRESS%.%WORKER% --pass x --log miner_chipcoin.log
echo Miner stopped (exit code %ERRORLEVEL%), restart in 5 s (close this window to quit)
timeout /t 5 /nobreak >nul
goto loop
