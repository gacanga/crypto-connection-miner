@echo off
REM start_bitmark.bat - Bitmark (lyra2v2) on the Crypto Connection pool: put your Bitmark address in ADDRESS, then double-click.
set ADDRESS=YOUR_MARKS_ADDRESS
set WORKER=rig1
set POOL=crypto-connection.net:4043
if "%ADDRESS%"=="YOUR_MARKS_ADDRESS" (echo Edit start_bitmark.bat first: put your Bitmark address in ADDRESS. & pause & exit /b 1)
:loop
crypto-connection-miner.exe --algo lyra2v2 --pool %POOL% --user %ADDRESS%.%WORKER% --pass x --log miner_bitmark.log
echo Miner stopped (exit code %ERRORLEVEL%), restart in 5 s (close this window to quit)
timeout /t 5 /nobreak >nul
goto loop
