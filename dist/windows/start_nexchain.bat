@echo off
REM start_nexchain.bat - NEX Chain (NEXC, ethash) on the Crypto Connection pool: put your NEX Chain address (0x...) in ADDRESS, then double-click.
REM   A NEX Chain address comes from the NEX wallet (getnexwallet.com) or MetaMask with the NEX Chain network (RPC https://rpc.getnexwallet.com, chain ID 6396).
set ADDRESS=YOUR_NEXC_ADDRESS
set WORKER=rig1
set POOL=crypto-connection.net:4083
if "%ADDRESS%"=="YOUR_NEXC_ADDRESS" (echo Edit start_nexchain.bat first: put your NEX Chain address in ADDRESS. & pause & exit /b 1)
:loop
crypto-connection-miner.exe --algo ethash --pool %POOL% --user %ADDRESS%.%WORKER% --pass x --log miner_nexchain.log
echo Miner stopped (exit code %ERRORLEVEL%), restart in 5 s (close this window to quit)
timeout /t 5 /nobreak >nul
goto loop
