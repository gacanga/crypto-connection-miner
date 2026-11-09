@echo off
REM test.bat - checks every GPU against the consensus hashes of GOSTcoin (gostd), Bitmark (lyra2v2), Feathercoin (neoscrypt) and Daler (ting)
crypto-connection-miner.exe --selftest
crypto-connection-miner.exe --algo lyra2v2 --selftest
crypto-connection-miner.exe --algo neoscrypt --selftest
crypto-connection-miner.exe --algo ting --selftest
pause
