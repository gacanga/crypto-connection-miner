#!/bin/sh
# test.sh - checks every GPU against the consensus hashes of GOSTcoin (gostd) and Bitmark (lyra2v2)
cd "$(dirname "$0")" && ./crypto-connection-miner --selftest && ./crypto-connection-miner --algo lyra2v2 --selftest
