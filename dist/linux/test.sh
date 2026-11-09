#!/bin/sh
# test.sh - checks every GPU against the consensus hashes of GOSTcoin (gostd), Bitmark (lyra2v2), Feathercoin (neoscrypt) and Daler (ting)
cd "$(dirname "$0")" && ./crypto-connection-miner --selftest && ./crypto-connection-miner --algo lyra2v2 --selftest && ./crypto-connection-miner --algo neoscrypt --selftest && ./crypto-connection-miner --algo ting --selftest
