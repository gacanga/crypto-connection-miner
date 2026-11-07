@echo off
REM test.bat - checks every GPU against the consensus hashes of GOSTcoin (gostd) and Bitmark (lyra2v2)
crypto-connection-miner.exe --selftest
crypto-connection-miner.exe --algo lyra2v2 --selftest
pause
