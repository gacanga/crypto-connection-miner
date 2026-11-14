#!/bin/sh
# start_chipcoin_cpu.sh - Chipcoin (CHC) on the CPU, Crypto Connection pool: put your Chipcoin address (CHCQ...) in ADDRESS, then: ./start_chipcoin_cpu.sh
#   No GPU and no NVIDIA driver needed. THREADS: number of mining threads (empty = every hardware thread; they run at low
#   priority). DIFF: fixed share difficulty (0.1 = the pool minimum, about one share every 43 s at 10 MH/s; empty = vardiff).
#   A Chipcoin mainnet address (post-quantum, starts with CHCQ) comes from the official Chipcoin wallet (chipcoinprotocol.com,
#   github.com/chipcoin-protocol/chipcoin: chipcoin wallet-generate). A standard sha256d cpuminer cannot mine Chipcoin (the
#   hash is read big-endian): this miner can.
ADDRESS=YOUR_CHC_ADDRESS
WORKER=cpu1
POOL=crypto-connection.net:4093
THREADS=
DIFF=0.1
cd "$(dirname "$0")"
[ "$ADDRESS" = "YOUR_CHC_ADDRESS" ] && { echo "Edit start_chipcoin_cpu.sh first: put your Chipcoin address in ADDRESS."; exit 1; }
PASS=x
[ -n "$DIFF" ] && PASS="d=$DIFF"
while true; do
  if [ -n "$THREADS" ]; then
    ./crypto-connection-miner --algo chc --cpu --threads "$THREADS" --pool "$POOL" --user "$ADDRESS.$WORKER" --pass "$PASS" --log miner_chipcoin_cpu.log
  else
    ./crypto-connection-miner --algo chc --cpu --pool "$POOL" --user "$ADDRESS.$WORKER" --pass "$PASS" --log miner_chipcoin_cpu.log
  fi
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
