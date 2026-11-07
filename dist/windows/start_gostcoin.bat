@echo off
REM start_gostcoin.bat - GOSTcoin on the Crypto Connection pool: put your GOSTcoin address in ADDRESS, then double-click.
set ADDRESS=YOUR_GST_ADDRESS
set WORKER=rig1
set POOL=crypto-connection.net:4033
if "%ADDRESS%"=="YOUR_GST_ADDRESS" (echo Edit start_gostcoin.bat first: put your GOSTcoin address in ADDRESS. & pause & exit /b 1)
:loop
crypto-connection-miner.exe --pool %POOL% --user %ADDRESS%.%WORKER% --pass x --log miner_gostcoin.log
echo Miner stopped (exit code %ERRORLEVEL%), restart in 5 s (close this window to quit)
timeout /t 5 /nobreak >nul
goto loop
