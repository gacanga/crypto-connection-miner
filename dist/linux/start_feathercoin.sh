#!/bin/sh
# start_feathercoin.sh - Feathercoin (neoscrypt) on the Crypto Connection pool: put your Feathercoin address in ADDRESS, then: ./start_feathercoin.sh
ADDRESS=YOUR_FTC_ADDRESS
WORKER=rig1
POOL=crypto-connection.net:4063
cd "$(dirname "$0")"
[ "$ADDRESS" = "YOUR_FTC_ADDRESS" ] && { echo "Edit start_feathercoin.sh first: put your Feathercoin address in ADDRESS."; exit 1; }
while true; do
  ./crypto-connection-miner --algo neoscrypt --pool "$POOL" --user "$ADDRESS.$WORKER" --pass x --log miner_feathercoin.log
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
