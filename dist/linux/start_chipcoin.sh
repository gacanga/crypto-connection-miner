#!/bin/sh
# start_chipcoin.sh - Chipcoin (CHC, sha256d read big-endian) on the Crypto Connection pool: put your Chipcoin address (CHCQ...) in ADDRESS, then: ./start_chipcoin.sh
#   A Chipcoin mainnet address (post-quantum, starts with CHCQ) comes from the official Chipcoin wallet (chipcoinprotocol.com,
#   github.com/chipcoin-protocol/chipcoin: chipcoin wallet-generate). Bitcoin ASICs cannot mine Chipcoin: NVIDIA GPUs here, CPUs with start_chipcoin_cpu.
ADDRESS=YOUR_CHC_ADDRESS
WORKER=rig1
POOL=crypto-connection.net:4093
cd "$(dirname "$0")"
[ "$ADDRESS" = "YOUR_CHC_ADDRESS" ] && { echo "Edit start_chipcoin.sh first: put your Chipcoin address in ADDRESS."; exit 1; }
while true; do
  ./crypto-connection-miner --algo chc --pool "$POOL" --user "$ADDRESS.$WORKER" --pass x --log miner_chipcoin.log
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
