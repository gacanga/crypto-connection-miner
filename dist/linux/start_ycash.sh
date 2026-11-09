#!/bin/sh
# start_ycash.sh - Ycash (YEC, equihash192) on the Crypto Connection pool: put your transparent Ycash address (s1...) in ADDRESS, then: ./start_ycash.sh
#   The equihash192 solver needs about 5.4 GB of GPU memory (cards with 6 GB or more). Wallets: YecWallet or ycashd (github.com/ycashfoundation).
ADDRESS=YOUR_YCASH_ADDRESS
WORKER=rig1
POOL=crypto-connection.net:4053
cd "$(dirname "$0")"
[ "$ADDRESS" = "YOUR_YCASH_ADDRESS" ] && { echo "Edit start_ycash.sh first: put your Ycash address in ADDRESS."; exit 1; }
while true; do
  ./crypto-connection-miner --algo equihash192 --pool "$POOL" --user "$ADDRESS.$WORKER" --pass x --log miner_ycash.log
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
