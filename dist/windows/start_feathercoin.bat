@echo off
REM start_feathercoin.bat - Feathercoin (neoscrypt) on the Crypto Connection pool: put your Feathercoin address in ADDRESS, then double-click.
set ADDRESS=YOUR_FTC_ADDRESS
set WORKER=rig1
set POOL=crypto-connection.net:4063
if "%ADDRESS%"=="YOUR_FTC_ADDRESS" (echo Edit start_feathercoin.bat first: put your Feathercoin address in ADDRESS. & pause & exit /b 1)
:loop
crypto-connection-miner.exe --algo neoscrypt --pool %POOL% --user %ADDRESS%.%WORKER% --pass x --log miner_feathercoin.log
echo Miner stopped (exit code %ERRORLEVEL%), restart in 5 s (close this window to quit)
timeout /t 5 /nobreak >nul
goto loop
