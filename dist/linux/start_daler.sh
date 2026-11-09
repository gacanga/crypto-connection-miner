#!/bin/sh
# start_daler.sh - Daler (DLR, ting) on the Crypto Connection pool: put your Ting account (64 hex characters) in ACCOUNT, then: ./start_daler.sh
#   A Ting account comes from the Ting ID Android app or from ting wallet create (github.com/ting-organization/ting-miner).
ACCOUNT=YOUR_TING_ACCOUNT
WORKER=rig1
POOL=crypto-connection.net:4073
cd "$(dirname "$0")"
[ "$ACCOUNT" = "YOUR_TING_ACCOUNT" ] && { echo "Edit start_daler.sh first: put your Ting account in ACCOUNT."; exit 1; }
while true; do
  ./crypto-connection-miner --algo ting --pool "$POOL" --user "$ACCOUNT.$WORKER" --pass x --log miner_daler.log
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
