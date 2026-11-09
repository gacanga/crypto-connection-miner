@echo off
REM start_daler.bat - Daler (DLR, ting) on the Crypto Connection pool: put your Ting account (64 hex characters) in ACCOUNT, then double-click.
REM   A Ting account comes from the Ting ID Android app or from ting wallet create (github.com/ting-organization/ting-miner).
set ACCOUNT=YOUR_TING_ACCOUNT
set WORKER=rig1
set POOL=crypto-connection.net:4073
if "%ACCOUNT%"=="YOUR_TING_ACCOUNT" (echo Edit start_daler.bat first: put your Ting account in ACCOUNT. & pause & exit /b 1)
:loop
crypto-connection-miner.exe --algo ting --pool %POOL% --user %ACCOUNT%.%WORKER% --pass x --log miner_daler.log
echo Miner stopped (exit code %ERRORLEVEL%), restart in 5 s (close this window to quit)
timeout /t 5 /nobreak >nul
goto loop
