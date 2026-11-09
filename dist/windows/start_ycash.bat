@echo off
REM start_ycash.bat - Ycash (YEC, equihash192) on the Crypto Connection pool: put your transparent Ycash address (s1...) in ADDRESS, then double-click.
REM   The equihash192 solver needs about 5.4 GB of GPU memory (cards with 6 GB or more). Wallets: YecWallet or ycashd (github.com/ycashfoundation).
set ADDRESS=YOUR_YCASH_ADDRESS
set WORKER=rig1
set POOL=crypto-connection.net:4053
if "%ADDRESS%"=="YOUR_YCASH_ADDRESS" (echo Edit start_ycash.bat first: put your Ycash address in ADDRESS. & pause & exit /b 1)
:loop
crypto-connection-miner.exe --algo equihash192 --pool %POOL% --user %ADDRESS%.%WORKER% --pass x --log miner_ycash.log
echo Miner stopped (exit code %ERRORLEVEL%), restart in 5 s (close this window to quit)
timeout /t 5 /nobreak >nul
goto loop
