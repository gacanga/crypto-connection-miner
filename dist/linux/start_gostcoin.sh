#!/bin/sh
# start_gostcoin.sh - GOSTcoin on the Crypto Connection pool: put your GOSTcoin address in ADDRESS, then: ./start_gostcoin.sh
ADDRESS=YOUR_GST_ADDRESS
WORKER=rig1
POOL=crypto-connection.net:4033
cd "$(dirname "$0")"
[ "$ADDRESS" = "YOUR_GST_ADDRESS" ] && { echo "Edit start_gostcoin.sh first: put your GOSTcoin address in ADDRESS."; exit 1; }
while true; do
  ./crypto-connection-miner --pool "$POOL" --user "$ADDRESS.$WORKER" --pass x --log miner_gostcoin.log
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
