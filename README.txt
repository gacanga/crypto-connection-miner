Crypto Connection Miner 0.6.0 - multi-coin GPU miner for NVIDIA. No dev fee. (Named GostMiner up to 0.4.0.)
  --algo gostd     (default)  GOSTcoin (GST)
  --algo lyra2v2              Bitmark (MARKS) and other Lyra2REv2 coins
  --algo neoscrypt            Feathercoin (FTC) and other NeoScrypt coins (new in 0.6.0)

NVIDIA GPUs from Maxwell (GTX 900) to Blackwell (RTX 50), Windows 10/11 x64 and Linux x86-64 (glibc 2.34+).
Driver: a recent NVIDIA driver (CUDA 12.9 support for the newest cards; any 525+ driver for Pascal/Turing/Ampere/Ada).

Easiest: edit and run start_gostcoin.bat / start_gostcoin.sh (GOSTcoin), start_bitmark.bat / start_bitmark.sh
(Bitmark) or start_feathercoin.bat / start_feathercoin.sh (Feathercoin): put your address in ADDRESS. They mine on
the Crypto Connection pool (crypto-connection.net, 1 % pool fee) and restart the miner automatically.
Statistics: https://crypto-connection.net

Command line:
  GOSTcoin, Windows: crypto-connection-miner.exe --user YOUR_GST_ADDRESS.rig1
  GOSTcoin, Linux:   ./crypto-connection-miner --user YOUR_GST_ADDRESS.rig1
  Bitmark,  Windows: crypto-connection-miner.exe --algo lyra2v2 --user YOUR_MARKS_ADDRESS.rig1
  Bitmark,  Linux:   ./crypto-connection-miner --algo lyra2v2 --user YOUR_MARKS_ADDRESS.rig1
  Feathercoin, Windows: crypto-connection-miner.exe --algo neoscrypt --user YOUR_FTC_ADDRESS.rig1
  Feathercoin, Linux:   ./crypto-connection-miner --algo neoscrypt --user YOUR_FTC_ADDRESS.rig1
  With --user and no --pool the miner connects to the Crypto Connection pool: crypto-connection.net port 4033
  (GOSTcoin), 4043 (Bitmark) or 4063 (Feathercoin). Any other stratum pool: add --pool HOST:PORT (and --pass x).

Options:
  --algo A         gostd (GOSTcoin, default), lyra2v2 (Bitmark) or neoscrypt (Feathercoin)
  --pool HOST:PORT stratum pool (default with --user: crypto-connection.net, port 4033 gostd / 4043 lyra2v2 /
                   4063 neoscrypt)
  --user A.W       your address and a worker name; --pass d=64 asks the pool for a fixed difficulty
  --gpus 0,1,2     GPUs to use (default: all)
  --kernel N       gostd: force a kernel variant (default: each GPU measures the 5 variants for 3 s, keeps the fastest)
  --intensity N    lyra2v2: 2^N hashes per launch (default 22 on GPUs up to 20 SM, 23-24 on larger ones,
                   limited by the GPU memory); neoscrypt: 2^N hashes per launch (default 16 up to 20 SM, 17-18 on
                   larger ones, about 33 KB of GPU memory per hash). Speed shown in kH/s for neoscrypt.
  --stats S        statistics every S seconds (default 30)
  --log FILE       also write the log to FILE
  --selftest       check every GPU against the coin's consensus hash and exit (test.bat / test.sh check all three)
  --bench S        hash for S seconds without a pool
  Solo on a local GOSTcoin wallet (getwork, gostd): --conf gostcoin.conf --port 8795

Checks: at start-up the miner checks its CPU references against real blocks (GOSTcoin: genesis block, a coinbase
transaction id and a merkle root; Bitmark: block 2490869 hash, its lyra2rev2 proof of work and merkle root;
Feathercoin: block 6428900 hash and its NeoScrypt proof of work). If it prints WRONG, do not mine. The lyra2v2 GPU
self test must find the nonce of Bitmark block 2490869, the neoscrypt one the nonce of Feathercoin block 6428900.
Every GPU result is checked again on the CPU before it is sent.

CUDA errors: if a GPU reports a CUDA error, the miner writes the last pool messages to the log and exits with
code 3; the start scripts restart it after 5 s (a clean restart is the safe way to recover a GPU).

Overclocking (gostd): this kernel loads the GPU core harder than older gostd miners. On P104-100 / GTX 10xx cards a
core overclock (+100 or +200 MHz) caused "illegal memory access" errors in our tests; with the core at stock clock
there was none. Keep the core at stock (a memory offset is fine) and lower it if the error appears.

Typical speed on a P104-100 (GTX 1070 class) at 160 W, core at stock: gostd 21-23 MH/s, lyra2v2 36-37 MH/s,
neoscrypt about 865 kH/s.

Licence: GNU GPL v3 (the lyra2v2 and neoscrypt kernels come from ccminer), see NOTICE.txt and COPYING.txt. Source
code: https://github.com/gacanga/crypto-connection-miner (also CryptoConnectionMiner-v0.6.0-src.tar.gz).
