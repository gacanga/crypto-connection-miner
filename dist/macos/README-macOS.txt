Crypto Connection Miner 0.10.2 - macOS (Apple Silicon) - Chipcoin (CHC) on the CPU, no dev fee
================================================================================================

What it is
  A native miner for Macs with an Apple chip (M1, M2, M3, M4 and later): it mines Chipcoin on the CPU with the
  SHA-256 instructions of the Apple chip, on the Crypto Connection pool (https://crypto-connection.net). Nothing to
  install, nothing to compile, no GPU needed. It mines Chipcoin only (the other coins need the NVIDIA build).

Start
  1. You need a Chipcoin mainnet address (CHCQ...): official Chipcoin wallet, https://chipcoinprotocol.com
     (github.com/chipcoin-protocol/chipcoin, "chipcoin wallet-generate"). Keep the wallet file safe.
  2. Unzip the archive (double-click), open the folder.
  3. Right-click start_chipcoin_macos.command > Open > Open (only the first time: the miner is not notarized by
     Apple, so macOS asks once). A Terminal window opens and asks for your CHCQ... address, then mining starts.
     Next times: double-click it.
  4. Follow your hashrate, balance and payments on https://crypto-connection.net (My stats), with your address.
  If macOS still refuses ("cannot be opened"): System Settings > Privacy & Security > "Open Anyway", or in Terminal,
  in the folder: xattr -dr com.apple.quarantine .

Settings (edit start_chipcoin_macos.command with TextEdit)
  WORKER   name of this Mac on the pool (default mac1)
  THREADS  mining threads (empty = the performance cores; they run at low priority so the Mac stays usable)
  DIFF     fixed share difficulty (0.1 = the pool minimum, about one share every 43 s at 10 MH/s; empty = vardiff)
  Your address is kept in chipcoin_address.txt (delete it to type another one).

Command line (Terminal, in the folder)
  ./crypto-connection-miner --algo chc --cpu --user YOUR_CHC_ADDRESS.mac1 --pass d=0.1
  ./crypto-connection-miner --selftest          checks every CPU path on Chipcoin block 11625
  ./crypto-connection-miner --bench 20          speed test without the pool
  Options: --threads N, --cpu-path auto|arm|c, --pool HOST:PORT, --stats S, --log FILE.

At start-up the miner checks its SHA-256 against Chipcoin block 11625 and every CPU path against the reference: if a
line says WRONG or FAILED, do not mine and tell us. Every share is checked again before it is sent.

Credits: Claudio Francesconi, founder of Chipcoin Protocol, started the macOS port and first tested it on an Apple M1.
Source code (GPL-3): https://github.com/gacanga/crypto-connection-miner (cpu/ccm_cpu.cpp, src/chc_cpu.c).
