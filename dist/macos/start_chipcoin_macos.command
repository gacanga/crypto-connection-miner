#!/bin/bash
# start_chipcoin_macos.command - Chipcoin (CHC) on the CPU of a Mac, Crypto Connection pool, no dev fee.
#   Double-click it in the Finder (the first time: right-click > Open > Open, because the miner is not notarized by
#   Apple). The first time it asks for your Chipcoin address (CHCQ...) and keeps it in chipcoin_address.txt next to it;
#   edit or delete that file to change it. The miner restarts by itself if it stops; close the window or press Ctrl+C
#   to quit. Settings below: WORKER (name of this Mac on the pool), THREADS (empty = the performance cores),
#   DIFF (fixed share difficulty: 0.1 = the pool minimum; empty = vardiff).
#   A Chipcoin mainnet address (post-quantum, starts with CHCQ) comes from the official Chipcoin wallet
#   (chipcoinprotocol.com, github.com/chipcoin-protocol/chipcoin: chipcoin wallet-generate).
WORKER=mac1
POOL=crypto-connection.net:4093
THREADS=
DIFF=0.1
cd "$(dirname "$0")" || exit 1
# files downloaded with a browser are quarantined by macOS: allow the miner of this folder to run
xattr -d com.apple.quarantine ./crypto-connection-miner 2>/dev/null
chmod +x ./crypto-connection-miner 2>/dev/null
CONF=chipcoin_address.txt
ADDRESS=""
[ -s "$CONF" ] && ADDRESS=$(tr -d ' \r\n\t' < "$CONF")
while [ "${ADDRESS#CHCQ}" = "$ADDRESS" ] || [ ${#ADDRESS} -lt 40 ]; do
  [ -n "$ADDRESS" ] && echo "\"$ADDRESS\" is not a Chipcoin mainnet address (it starts with CHCQ)."
  printf "Your Chipcoin address (CHCQ...): "
  read -r ADDRESS || exit 1
  ADDRESS=$(printf "%s" "$ADDRESS" | tr -d ' \r\n\t')
done
printf "%s\n" "$ADDRESS" > "$CONF"
PASS=x
[ -n "$DIFF" ] && PASS="d=$DIFF"
echo "Mining Chipcoin for $ADDRESS.$WORKER on $POOL - follow it on https://crypto-connection.net (My stats)"
while true; do
  if [ -n "$THREADS" ]; then
    ./crypto-connection-miner --algo chc --cpu --threads "$THREADS" --pool "$POOL" --user "$ADDRESS.$WORKER" --pass "$PASS" --log miner_chipcoin_macos.log
  else
    ./crypto-connection-miner --algo chc --cpu --pool "$POOL" --user "$ADDRESS.$WORKER" --pass "$PASS" --log miner_chipcoin_macos.log
  fi
  echo "Miner stopped (exit code $?), restart in 5 s (Ctrl+C to quit)"; sleep 5
done
