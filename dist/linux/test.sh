#!/bin/sh
# test.sh - checks every GPU against the consensus hashes of GOSTcoin (gostd), Bitmark (lyra2v2), Feathercoin (neoscrypt), Daler (ting),
#   Ycash (equihash192: reference solutions and real Ycash blocks; needs about 5.4 GB of GPU memory), NEX Chain (ethash: real blocks,
#   DAG of about 1 GB built on the GPU) and Chipcoin (chc: real Chipcoin block found again, on the GPU and with every CPU path)
cd "$(dirname "$0")" && ./crypto-connection-miner --selftest && ./crypto-connection-miner --algo lyra2v2 --selftest && ./crypto-connection-miner --algo neoscrypt --selftest && ./crypto-connection-miner --algo ting --selftest && ./crypto-connection-miner --algo equihash192 --selftest && ./crypto-connection-miner --algo ethash --selftest && ./crypto-connection-miner --algo chc --selftest && ./crypto-connection-miner --algo chc --cpu --selftest
