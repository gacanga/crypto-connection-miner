#!/bin/sh
# start_bitmark.sh - Bitmark (lyra2v2) on the Crypto Connection pool: put your Bitmark address in ADDRESS, then: ./start_bitmark.sh
ADDRESS=YOUR_MARKS_ADDRESS
WORKER=rig1
POOL=crypto-connection.net:4043
cd "$(dirname "$0")"
[ "$ADDRESS" = "YOUR_MARKS_ADDRESS" ] && { echo "Edit start_bitmark.sh first: put your Bitmark address in ADDRESS."; exit 1; }
while true; do
  ./crypto-connection-miner --algo lyra2v2 --pool "$POOL" --user "$ADDRESS.$WORKER" --pass x --log miner_bitmark.log
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
