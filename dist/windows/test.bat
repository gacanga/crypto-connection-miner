@echo off
REM test.bat - checks every GPU against the consensus hashes of GOSTcoin (gostd), Bitmark (lyra2v2) and Feathercoin (neoscrypt)
crypto-connection-miner.exe --selftest
crypto-connection-miner.exe --algo lyra2v2 --selftest
crypto-connection-miner.exe --algo neoscrypt --selftest
pause
