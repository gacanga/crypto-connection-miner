@echo off
REM test.bat - checks every GPU against the consensus hashes of GOSTcoin (gostd), Bitmark (lyra2v2), Feathercoin (neoscrypt), Daler (ting),
REM   Ycash (equihash192: reference solutions and real Ycash blocks; needs about 5.4 GB of GPU memory), NEX Chain (ethash: real blocks,
REM   DAG of about 1 GB built on the GPU) and Chipcoin (chc: real Chipcoin block found again)
crypto-connection-miner.exe --selftest
crypto-connection-miner.exe --algo lyra2v2 --selftest
crypto-connection-miner.exe --algo neoscrypt --selftest
crypto-connection-miner.exe --algo ting --selftest
crypto-connection-miner.exe --algo equihash192 --selftest
crypto-connection-miner.exe --algo ethash --selftest
crypto-connection-miner.exe --algo chc --selftest
pause
