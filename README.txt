Crypto Connection Miner 0.9.0 - multi-coin GPU miner for NVIDIA. No dev fee. (Named GostMiner up to 0.4.0.)
  --algo gostd     (default)  GOSTcoin (GST)
  --algo lyra2v2              Bitmark (MARKS) and other Lyra2REv2 coins
  --algo neoscrypt            Feathercoin (FTC) and other NeoScrypt coins
  --algo ting                 Daler (DLR) on Ting; the user is your Ting account (64 hex characters)
  --algo equihash192          Ycash (YEC), Equihash 192,7; the user is your transparent Ycash address (s1...); needs
                              about 5.4 GB of GPU memory per card (6 GB cards or more). The Crypto Connection Ycash
                              pool closed on 10/11/2026: use --pool with another Ycash pool
  --algo ethash               NEX Chain (NEXC) and other Ethash chains (new in 0.9.0); the user is your 0x...
                              address; the DAG of the current epoch stays in GPU memory (about 1 GB on NEX Chain)

NVIDIA GPUs from Maxwell (GTX 900) to Blackwell (RTX 50), Windows 10/11 x64 and Linux x86-64 (glibc 2.34+).
Driver: a recent NVIDIA driver (CUDA 12.9 support for the newest cards; any 525+ driver for Pascal/Turing/Ampere/Ada).

Easiest: edit and run start_gostcoin.bat / start_gostcoin.sh (GOSTcoin), start_bitmark.bat / start_bitmark.sh
(Bitmark), start_feathercoin.bat / start_feathercoin.sh (Feathercoin), start_nexchain.bat / start_nexchain.sh
(NEX Chain): put your address in ADDRESS, or start_daler.bat / start_daler.sh (Daler): put your Ting account in
ACCOUNT. They mine on the Crypto Connection pool (crypto-connection.net, 1 % pool fee) and restart the miner
automatically. A Ting account comes from the Ting ID Android app (github.com/ting-organization/ting-id) or from
"ting wallet create" (github.com/ting-organization/ting-miner). A NEX Chain address (0x...) comes from the NEX wallet
(getnexwallet.com) or MetaMask with the NEX Chain network (RPC https://rpc.getnexwallet.com, chain ID 6396).
Statistics: https://crypto-connection.net

Command line:
  GOSTcoin, Windows: crypto-connection-miner.exe --user YOUR_GST_ADDRESS.rig1
  GOSTcoin, Linux:   ./crypto-connection-miner --user YOUR_GST_ADDRESS.rig1
  Bitmark,  Windows: crypto-connection-miner.exe --algo lyra2v2 --user YOUR_MARKS_ADDRESS.rig1
  Bitmark,  Linux:   ./crypto-connection-miner --algo lyra2v2 --user YOUR_MARKS_ADDRESS.rig1
  Feathercoin, Windows: crypto-connection-miner.exe --algo neoscrypt --user YOUR_FTC_ADDRESS.rig1
  Feathercoin, Linux:   ./crypto-connection-miner --algo neoscrypt --user YOUR_FTC_ADDRESS.rig1
  Daler, Windows:       crypto-connection-miner.exe --algo ting --user YOUR_TING_ACCOUNT.rig1
  Daler, Linux:         ./crypto-connection-miner --algo ting --user YOUR_TING_ACCOUNT.rig1
  NEX Chain, Windows:   crypto-connection-miner.exe --algo ethash --user YOUR_NEXC_ADDRESS.rig1
  NEX Chain, Linux:     ./crypto-connection-miner --algo ethash --user YOUR_NEXC_ADDRESS.rig1
  Ycash (other pool):   crypto-connection-miner.exe --algo equihash192 --pool HOST:PORT --user YOUR_YEC_ADDRESS.rig1
  With --user and no --pool the miner connects to the Crypto Connection pool: crypto-connection.net port 4033
  (GOSTcoin), 4043 (Bitmark), 4063 (Feathercoin), 4073 (Daler) or 4083 (NEX Chain). Any other stratum pool: add
  --pool HOST:PORT (and --pass x); for Ting the pool must speak the Crypto Connection stratum for Ting (README.md);
  for Ethash, EthereumStratum/1.0.0 (NiceHash), as Miningcore pools speak it.

Options:
  --algo A         gostd (GOSTcoin, default), lyra2v2 (Bitmark), neoscrypt (Feathercoin), ting (Daler),
                   equihash192 (Ycash) or ethash (NEX Chain)
  --pool HOST:PORT stratum pool (default with --user: crypto-connection.net, port 4033 gostd / 4043 lyra2v2 /
                   4063 neoscrypt / 4073 ting / 4083 ethash)
  --user A.W       your address and a worker name; --pass d=64 asks the pool for a fixed difficulty
  --gpus 0,1,2     GPUs to use (default: all)
  --kernel N       gostd: force a kernel variant (default: each GPU measures the 5 variants for 3 s, keeps the fastest)
  --intensity N    lyra2v2: 2^N hashes per launch (default 22 on GPUs up to 20 SM, 23-24 on larger ones,
                   limited by the GPU memory); neoscrypt: 2^N hashes per launch (default 16 up to 20 SM, 17-18 on
                   larger ones, about 33 KB of GPU memory per hash). Speed shown in kH/s for neoscrypt.
  --tpb N          equihash192: threads per block of the collision kernels (multiple of 32, default 512).
                   Speed shown in Sol/s (valid solutions per second) for equihash192.
  --stats S        statistics every S seconds (default 30)
  --log FILE       also write the log to FILE
  --selftest       check every GPU against the coin's consensus hash and exit (test.bat / test.sh check all six)
  --bench S        hash for S seconds without a pool
  Solo on a local GOSTcoin wallet (getwork, gostd): --conf gostcoin.conf --port 8795

Checks: at start-up the miner checks its CPU references against real blocks (GOSTcoin: genesis block, a coinbase
transaction id and a merkle root; Bitmark: block 2490869 hash, its lyra2rev2 proof of work and merkle root;
Feathercoin: block 6428900 hash and its NeoScrypt proof of work; Ting: BlockId of block 35104; Ycash: BLAKE2b
"ZcashPoW" known answers and 6 real blocks, mined solution and block hash; with --algo ethash: keccak known answers,
cache and DAG sizes, 2 real NEX Chain blocks). If it prints WRONG, do not mine. The lyra2v2 GPU self test must find
the nonce of Bitmark block 2490869, the neoscrypt one the nonce of Feathercoin block 6428900, the ting one the nonce of
Ting block 35104, the equihash192 one exactly the reference solutions of 5 headers (2 of them real Ycash blocks whose
mined solution must be found), the ethash one the nonce of NEX Chain block 30001 with the DAG built on the GPU.
Every GPU result is checked again on the CPU before it is sent.

Ethash: at start-up (and at each new epoch, every 30000 blocks) the miner builds the epoch's cache on the CPU (about
2 s) and every GPU builds its DAG (about 20-30 s for 1 GB on a P104-100) before mining.

CUDA errors: if a GPU reports a CUDA error, the miner writes the last pool messages to the log and exits with
code 3; the start scripts restart it after 5 s (a clean restart is the safe way to recover a GPU).

Overclocking (gostd): this kernel loads the GPU core harder than older gostd miners. On P104-100 / GTX 10xx cards a
core overclock (+100 or +200 MHz) caused "illegal memory access" errors in our tests; with the core at stock clock
there was none. Keep the core at stock (a memory offset is fine) and lower it if the error appears.

Typical speed on a P104-100 (GTX 1070 class) at 160 W, core at stock: gostd 21-23 MH/s, lyra2v2 36-37 MH/s,
neoscrypt about 865 kH/s, ting about 2.05-2.09 GH/s, equihash192 about 11-15 Sol/s, ethash about 32 MH/s with the
memory at +700 MHz (Ethash is limited by the memory clock: 18 MH/s with the memory lowered to 2999 MHz).

Licence: GNU GPL v3 (the lyra2v2 and neoscrypt kernels come from ccminer; the ting and ethash kernels and the Ethash
CPU reference were written for this miner; the equihash192 solver comes from YecMiner, same author, Apache-2.0), see
NOTICE.txt and COPYING.txt. Source code: https://github.com/gacanga/crypto-connection-miner (also
CryptoConnectionMiner-v0.9.0-src.tar.gz).
