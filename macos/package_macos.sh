#!/bin/sh
# package_macos.sh [version] - builds, checks and packages Crypto Connection Miner for macOS on Apple Silicon:
#   out/CryptoConnectionMiner-v<version>-macos-arm64.zip (miner, start script, READMEs, licence) + its SHA-256.
#   Run on an Apple Silicon Mac (or the GitHub Actions macos-14 runner): the self test must pass before packaging.
set -eu
cd "$(dirname "$0")/.."
VER="${1:-0.10.2}"
NAME="CryptoConnectionMiner-v$VER-macos-arm64"
rm -rf "out/$NAME" "out/$NAME.zip"
mkdir -p "out/$NAME"
sh macos/build_macos.sh "out/$NAME/crypto-connection-miner"
"out/$NAME/crypto-connection-miner" --selftest
cp dist/macos/start_chipcoin_macos.command dist/macos/README-macOS.txt dist/macos/LISEZMOI-macOS.txt LICENSE NOTICE.txt "out/$NAME/"
chmod +x "out/$NAME/start_chipcoin_macos.command" "out/$NAME/crypto-connection-miner"
(cd out && ditto -c -k --keepParent "$NAME" "$NAME.zip")
(cd out && shasum -a 256 "$NAME.zip" | tee "$NAME.zip.sha256")
