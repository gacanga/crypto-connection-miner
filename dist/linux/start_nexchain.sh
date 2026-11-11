#!/bin/sh
# start_nexchain.sh - NEX Chain (NEXC, ethash) on the Crypto Connection pool: put your NEX Chain address (0x...) in ADDRESS, then: ./start_nexchain.sh
#   A NEX Chain address comes from the NEX wallet (getnexwallet.com) or MetaMask with the NEX Chain network (RPC https://rpc.getnexwallet.com, chain ID 6396).
ADDRESS=YOUR_NEXC_ADDRESS
WORKER=rig1
POOL=crypto-connection.net:4083
cd "$(dirname "$0")"
[ "$ADDRESS" = "YOUR_NEXC_ADDRESS" ] && { echo "Edit start_nexchain.sh first: put your NEX Chain address in ADDRESS."; exit 1; }
while true; do
  ./crypto-connection-miner --algo ethash --pool "$POOL" --user "$ADDRESS.$WORKER" --pass x --log miner_nexchain.log
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
