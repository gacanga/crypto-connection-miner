# Crypto Connection Miner

Mineur GPU multi-coins, libre et gratuit, pour cartes NVIDIA, fait pour la pool
[Crypto Connection](https://crypto-connection.net). **Sans frais de développeur.** (S'appelait GostMiner jusqu'à la
version 0.4.0 : https://github.com/gacanga/GostMiner.)

| Algorithme | Option | Coins | Port Crypto Connection |
|---|---|---|---|
| gostd (GOST R 34.11-2012 « Streebog », enchaîné) | `--algo gostd` (par défaut) | GOSTcoin (GST) | 4033 |
| Lyra2REv2 | `--algo lyra2v2` | Bitmark (MARKS) et autres coins Lyra2REv2 | 4043 |
| NeoScrypt | `--algo neoscrypt` | Feathercoin (FTC) et autres coins NeoScrypt | 4063 |
| Ting (SHA-256 sur l'en-tête balisé de Ting) | `--algo ting` | Daler (DLR) et autres coins de Ting | 4073 |
| Equihash 192,7 (« ZcashPoW ») | `--algo equihash192` | Ycash (YEC) | (pool fermée le 10/11/2026 : utilisez `--pool`) |
| Ethash (époques de 30000 blocs) | `--algo ethash` | NEX Chain (NEXC) et autres chaînes Ethash | 4083 |

- Cartes NVIDIA de Maxwell (GTX 900) à Blackwell (RTX 50), Windows 10/11 x64 et Linux x86-64 (glibc 2.34 ou plus).
  equihash192 demande environ 5,4 Go de mémoire par carte (cartes de 6 Go ou plus) ; ethash garde le DAG de l'époque
  en cours dans la mémoire du GPU (environ 1 Go sur NEX Chain en novembre 2026, +8 Mo tous les 30000 blocs).
- Mine par défaut sur la pool Crypto Connection ; toute pool stratum de ces coins fonctionne avec `--pool` (Ting : une
  pool qui parle le stratum décrit plus bas). Minage solo possible sur un wallet GOSTcoin local (getwork).
- Chaque part trouvée par le GPU est revérifiée sur le CPU avant envoi ; les références CPU sont contrôlées sur de
  vrais blocs au démarrage.

English: [README.md](README.md).

## Téléchargement

Les binaires sont sur la page [Releases](https://github.com/gacanga/crypto-connection-miner/releases), avec leur
SHA-256. Les mêmes fichiers sont sur la [page Téléchargements](https://crypto-connection.net/#/downloads) de la pool.

| Fichier | SHA-256 |
|---|---|
| CryptoConnectionMiner-v0.9.0-win64-cuda12.zip | `78d1f6d2c65dadfe4dcb05c1ebe49dbcf09407ac22de6b833f0078784d9fbae5` |
| CryptoConnectionMiner-v0.9.0-linux-x64-cuda12.tar.gz | `27c7e740f715ffc77f64eba647fb057e8be1b50292012ef0a01c1f3cafc3b331` |

Vérifiez un fichier avant de le lancer : Windows (PowerShell) `Get-FileHash FICHIER -Algorithm SHA256`, Linux
`sha256sum FICHIER`.

## Démarrage rapide

Le plus simple : ouvrez `start_gostcoin.bat` / `start_gostcoin.sh` (GOSTcoin), `start_bitmark.bat` /
`start_bitmark.sh` (Bitmark), `start_feathercoin.bat` / `start_feathercoin.sh` (Feathercoin), `start_daler.bat` /
`start_daler.sh` (Daler : mettez votre compte Ting dans `ACCOUNT`) ou `start_nexchain.bat` / `start_nexchain.sh`
(NEX Chain : une adresse 0x...), mettez votre adresse dans `ADDRESS`, puis lancez-le. Il mine sur la pool Crypto
Connection et relance le mineur automatiquement. Suivez votre hashrate, votre solde et vos paiements sur
https://crypto-connection.net (Mes stats).

En ligne de commande : avec `--user` et sans `--pool`, le mineur se connecte à la pool Crypto Connection
(crypto-connection.net, port 4033 pour GOSTcoin, 4043 pour Bitmark, 4063 pour Feathercoin, 4073 pour Daler, 4083 pour
NEX Chain). La pool Ycash de Crypto Connection a fermé le 10/11/2026 : pour Ycash, indiquez `--pool` avec une autre
pool Ycash.

```
GOSTcoin, Windows :  crypto-connection-miner.exe --user VOTRE_ADRESSE_GST.rig1
GOSTcoin, Linux :    ./crypto-connection-miner --user VOTRE_ADRESSE_GST.rig1
Bitmark,  Windows :  crypto-connection-miner.exe --algo lyra2v2 --user VOTRE_ADRESSE_MARKS.rig1
Bitmark,  Linux :    ./crypto-connection-miner --algo lyra2v2 --user VOTRE_ADRESSE_MARKS.rig1
Feathercoin, Windows : crypto-connection-miner.exe --algo neoscrypt --user VOTRE_ADRESSE_FTC.rig1
Feathercoin, Linux :   ./crypto-connection-miner --algo neoscrypt --user VOTRE_ADRESSE_FTC.rig1
Daler, Windows :     crypto-connection-miner.exe --algo ting --user VOTRE_COMPTE_TING.rig1
Daler, Linux :       ./crypto-connection-miner --algo ting --user VOTRE_COMPTE_TING.rig1
NEX Chain, Windows : crypto-connection-miner.exe --algo ethash --user VOTRE_ADRESSE_NEXC.rig1
NEX Chain, Linux :   ./crypto-connection-miner --algo ethash --user VOTRE_ADRESSE_NEXC.rig1
Ycash (autre pool) : crypto-connection-miner.exe --algo equihash192 --pool HOTE:PORT --user VOTRE_ADRESSE_YEC.rig1
Autre pool :         crypto-connection-miner.exe --pool HOTE:PORT --user VOTRE_ADRESSE.rig1 --pass x
```

`test.bat` / `test.sh` testent chaque carte sur les six algorithmes.

Un compte Ting (paiements en Daler) fait 64 caractères hexadécimaux : créez-le avec l'appli Android Ting ID
(https://github.com/ting-organization/ting-id) ou avec `ting wallet create` de ting-miner
(https://github.com/ting-organization/ting-miner).

Les paiements en Ycash vont sur une adresse transparente (s1...) : YecWallet ou ycashd
(https://github.com/ycashfoundation).

Une adresse NEX Chain est une adresse de type Ethereum 0x... : le wallet NEX (https://getnexwallet.com) ou MetaMask
avec le réseau NEX Chain (RPC https://rpc.getnexwallet.com, chain ID 6396).

## Options

| Option | Rôle |
|---|---|
| `--algo A` | `gostd` (GOSTcoin, par défaut), `lyra2v2` (Bitmark), `neoscrypt` (Feathercoin), `ting` (Daler), `equihash192` (Ycash) ou `ethash` (NEX Chain) |
| `--pool HOTE:PORT` | pool stratum (par défaut avec `--user` : crypto-connection.net, port 4033 gostd / 4043 lyra2v2 / 4063 neoscrypt / 4073 ting / 4083 ethash) |
| `--user ADRESSE.WORKER --pass x` | votre adresse de paiement et un nom de worker ; `--pass d=64` demande une difficulté fixe à la pool |
| `--gpus 0,1,2` | cartes utilisées (par défaut : toutes) |
| `--kernel N` | gostd : variante de noyau forcée (par défaut, chaque carte mesure les 5 variantes 3 s et garde la plus rapide) |
| `--intensity N` | lyra2v2 : 2^N hashs par lancement (par défaut 22 jusqu'à 20 SM, 23-24 au-delà, limité par la mémoire de la carte) ; neoscrypt : 2^N hashs par lancement (par défaut 16 jusqu'à 20 SM, 17-18 au-delà, environ 33 Ko de mémoire de carte par hash) |
| `--tpb N` | equihash192 : threads par bloc des noyaux de collision (multiple de 32, 512 par défaut) |
| `--stats S` | statistiques toutes les S secondes (30 par défaut) |
| `--log FICHIER` | écrit aussi le journal dans FICHIER |
| `--selftest` | teste chaque carte sur le hash de consensus du coin, puis quitte |
| `--bench S` | calcule S secondes sans pool |
| `--conf gostcoin.conf --port 8795` | solo sur un wallet GOSTcoin local (getwork, gostd) |

## Contrôles

Au démarrage, le mineur vérifie ses références CPU sur de vrais blocs : bloc genèse de GOSTcoin, identifiant d'une
coinbase et racine merkle ; hash du bloc Bitmark 2490869, sa preuve de travail lyra2rev2 et sa racine merkle ; hash
du bloc Feathercoin 6428900 et sa preuve de travail NeoScrypt ; BlockId du bloc Ting 35104 ; pour Ycash, réponses
connues du BLAKE2b « ZcashPoW » et 6 vrais blocs Ycash (solution minée valide, hash du bloc recalculé, solutions
altérées refusées) ; avec `--algo ethash`, réponses connues de keccak, tailles du cache et du DAG des tables de
go-ethereum et 2 vrais blocs NEX Chain (mix digest et résultat). S'il affiche `WRONG`, ne minez pas. L'autotest GPU lyra2v2 doit retrouver le nonce du bloc Bitmark
2490869, celui de neoscrypt le nonce du bloc Feathercoin 6428900, celui de ting le nonce du bloc Ting 35104, celui
d'equihash192 exactement les solutions de référence de 5 en-têtes (3 d'un vrai job de pool, 2 vrais blocs Ycash dont
la solution minée doit être retrouvée), celui d'ethash le nonce du bloc NEX Chain 30001 avec un DAG construit sur le
GPU, et chaque candidat de 16 lancements à cible facile doit être validé sur le CPU.

## Erreurs CUDA et overclocking

Si une carte signale une erreur CUDA, le mineur écrit les derniers messages de la pool dans le journal et quitte avec
le code 3 ; les scripts de lancement le relancent après 5 s (un redémarrage propre est le moyen sûr de récupérer
une carte).

Le noyau gostd sollicite le cœur du GPU plus que les anciens mineurs gostd. Sur P104-100 / GTX 10xx, un overclock du
cœur (+100 ou +200 MHz) a provoqué des erreurs « illegal memory access » lors de nos essais ; avec le cœur
d'origine, aucune. Laissez le cœur d'origine (décalage mémoire et limite de puissance : sans problème) et baissez-le
si l'erreur apparaît.

Vitesse typique sur une P104-100 (classe GTX 1070) à 160 W, cœur d'origine : gostd 21-23 MH/s, lyra2v2 36-37 MH/s,
neoscrypt environ 865 kH/s (le mineur affiche les vitesses neoscrypt en kH/s), ting environ 2,05-2,09 GH/s (affichés
2050-2090 MH/s), equihash192 environ 11 à 15 Sol/s selon la fréquence mémoire (solutions valides par
seconde). Ethash est limité par la mémoire : environ 32 MH/s avec la mémoire à +700 MHz (5702 MHz) et 18 MH/s avec la
mémoire baissée à 2999 MHz (la carte ne consomme que 55 à 60 W).

## Stratum Ting (Daler)

Ting n'a pas de protocole stratum à lui ; la pool Crypto Connection (Miningcore, famille `ting`) parle celui-ci :

- `mining.subscribe` -> `[[...], EXTRANONCE1 (8 hex = 4 octets), 12]`
- `mining.authorize` `["COMPTE.worker", "x"]` - COMPTE est un compte Ting, 64 caractères hexadécimaux
- `mining.set_difficulty` `[d]` - cible d'une part = 2^224 / d (difficulté 1 = environ 2^32 hashs)
- `mining.notify` `[id du job, ENTETE (les 278 octets de l'en-tête avant le nonce, hex), hauteur, cible du réseau (64
  hex, big-endian), clean]`
- `mining.submit` `["COMPTE.worker", id du job, NONCE (32 hex = les 16 octets du nonce tels qu'ils vont dans l'en-tête,
  un u128 little-endian ; octets 12-15 = EXTRANONCE1)]`

Une part : SHA-256(`"Ting/"` 05 00 `"block"` || ENTETE || NONCE), lu comme un entier big-endian, <= la cible de la part
(c'est le BlockId des règles du protocole Ting, section 8.1). Le mineur calcule une fois par job les quatre premiers
blocs SHA-256 et les 8 premiers tours du dernier : un essai coûte 56 tours d'une seule compression.

## Equihash 192,7 (Ycash)

Un passage du solveur = un nonce : 2^24 hashs BLAKE2b-384 (personnalisation « ZcashPoW » || 192 || 7) donnent 2^25
chaînes de 24 octets, puis 6 étapes de collision sur des chiffres de 24 bits et une finale sur 48 bits (algorithme de
Wagner, 4096 seaux, listes chaînées en mémoire partagée), puis les 128 indices de chaque candidat sont reconstruits.
Le solveur est celui de [YecMiner](https://github.com/gacanga/YecMiner) (même auteur, Apache-2.0, `gpu/equihash192`). Chaque candidat est remis dans l'ordre
canonique et validé sur le CPU (collisions, ordre, indices distincts) avant que son hash de bloc,
SHA256d(en-tête || fd9001 || solution), soit comparé à la cible de la part.

Stratum (style Zcash, comme Miningcore et NOMP) : `mining.subscribe` -> `[session, EXTRANONCE1]` ; `mining.set_target`
`[64 hex, big-endian]` (pris tel quel ; `mining.set_difficulty` seul : cible = 0x0007ffff..ff / d) ; `mining.notify`
`[job, version, hash précédent, racine merkle, réservé, heure, bits, clean]` (champs dans l'ordre des octets de
l'en-tête) ; le nonce de 32 octets est EXTRANONCE1 || EXTRANONCE2 (emplacement GPU, session, compteur) ;
`mining.submit` `[worker, job, heure, EXTRANONCE2, "fd9001" + solution]`.

## Ethash (NEX Chain)

Ethash tel que go-ethereum / core-geth le calculent, époques de 30000 blocs : le mineur trouve l'époque à partir du
seed hash du job, construit le cache de l'époque sur le CPU (environ 2 s), chaque GPU en tire le DAG (environ 20 à 30 s
pour 1 Go sur une P104-100), puis chaque nonce coûte un keccak512, 64 accès à des pages de 128 octets du DAG (8 threads
par hash, une lecture groupée par page) et un keccak256. Les noyaux (`gpu/ethash`) et la référence CPU
(`src/ethash_ref.c`) ont été écrits pour ce mineur. Chaque candidat est vérifié sur le CPU (Ethash « light » à partir
du cache) contre la cible complète de la part.

Stratum : EthereumStratum/1.0.0 (NiceHash), comme Miningcore le sert : `mining.subscribe` `[agent,
"EthereumStratum/1.0.0"]` -> `[[...], EXTRANONCE1]` ; `mining.notify` `[job, seed hash, header hash, clean]` ;
`mining.set_difficulty` `[d]` - cible d'une part = 2^224 / d (difficulté 1 = 2^32 hashs) ; le nonce de 8 octets est
EXTRANONCE1 || partie du mineur (emplacement GPU, compteur, 32 bits parcourus par le GPU) ; `mining.submit` `[worker,
job, partie du mineur (hex, sans EXTRANONCE1)]`. `mining.set_extranonce` est pris en charge.

## Compilation

- Windows : CUDA 12.9 et Visual Studio 2022 (outils C++), puis `windows\build_miner.bat dev\crypto-connection-miner.exe`.
- Linux : CUDA 12.9 (`CUDA_HOME`) et gcc / g++ 11 ou plus, puis `linux/build_linux.sh dev/crypto-connection-miner`.
  Le binaire publié est compilé avec gcc-11 / g++-11 (utilisés s'ils sont installés) et `linux/glibc_compat.c`, pour
  tourner sur glibc 2.34 et plus même s'il est compilé sur un système plus récent.
- Code machine pour toutes les générations de GPU visées par CUDA 12.9 (sm_50 à sm_120) plus PTX ; `GM_ARCHS` permet
  d'en compiler moins, par exemple `GM_ARCHS=-arch=sm_61`.
- Les références C doivent être compilées avec `-fno-strict-aliasing` : Lyra2.c enfreint les règles d'aliasing du C
  et gcc -O2 calculerait sinon un lyra2rev2 faux (le contrôle au démarrage le détecte).
- Les scripts de lancement des paquets sont dans `dist/`.

## Changements

- 0.9.0 : nouvel algorithme `--algo ethash` pour NEX Chain (NEXC) et les autres chaînes Ethash : DAG construit sur le
  GPU, noyau de recherche à 8 threads par hash, référence CPU écrite pour ce mineur ; EthereumStratum/1.0.0
  (ci-dessus) ; port de pool 4083 par défaut ; scripts `start_nexchain` ; `test` vérifie les six algorithmes ;
  contrôles CPU sur 2 vrais blocs NEX Chain, autotest GPU sur le bloc NEX Chain 30001. La pool Ycash de Crypto
  Connection a fermé le 10/11/2026 : les scripts `start_ycash` ne sont plus dans les paquets (`--algo equihash192`
  reste, avec `--pool`). Autres algorithmes inchangés.
- 0.8.0 : nouvel algorithme `--algo equihash192` pour Ycash (YEC) : Equihash 192,7 « ZcashPoW » avec le solveur de
  YecMiner (Apache-2.0), environ 11 à 15 Sol/s sur une P104-100, environ 5,4 Go de mémoire par carte ; stratum de
  style Zcash (ci-dessus) ; port de pool 4053 par défaut ; option `--tpb` ; scripts `start_ycash` ; `test` vérifie les
  cinq algorithmes ; contrôles CPU sur 6 vrais blocs Ycash et autotest GPU sur 5 en-têtes de référence. gostd, lyra2v2,
  neoscrypt et ting inchangés.
- 0.7.0 : nouvel algorithme `--algo ting` pour Daler (DLR) sur Ting : une compression SHA-256 par essai à partir d'un
  état intermédiaire (quatre premiers blocs et 8 premiers tours du dernier calculés une fois par job, mots 16 à 23 du
  message en partie précalculés), environ 2,05-2,09 GH/s sur une P104-100 ; stratum Crypto Connection pour Ting
  (ci-dessus) ; port de pool 4073 par défaut ; scripts `start_daler` ; `test` vérifie les quatre algorithmes ; autotests
  CPU et GPU sur le bloc Ting 35104. gostd, lyra2v2 et neoscrypt inchangés.
- 0.6.0 : nouvel algorithme `--algo neoscrypt` pour Feathercoin (FTC) et les autres coins NeoScrypt, avec les noyaux
  NeoScrypt de ccminer 2.3.1 (environ 865 kH/s sur une P104-100, comme ccminer) et un contrôle CPU de chaque part ;
  port de pool 4063 par défaut ; scripts `start_feathercoin` ; `test` vérifie les trois algorithmes ; autotests CPU
  et GPU sur le bloc Feathercoin 6428900. gostd et lyra2v2 inchangés.
- 0.5.0 : renommé Crypto Connection Miner (binaire `crypto-connection-miner`) ; `--user` sans `--pool` mine sur la
  pool Crypto Connection ; scripts `start_gostcoin` / `start_bitmark` réglés sur crypto-connection.net (4033 / 4043).
  Code de minage identique à GostMiner 0.4.0.

## Licence

GNU GPL v3 (`LICENSE`, `COPYING.txt`) : les noyaux GPU lyra2v2 et neoscrypt viennent de ccminer 2.3.1 ; le noyau
ting (`gpu/ting`), les noyaux ethash (`gpu/ethash`) et la référence CPU d'Ethash (`src/ethash_ref.c`) ont été
écrits pour ce mineur ; le solveur equihash192 (`gpu/equihash192`) vient de YecMiner, même
auteur, Apache-2.0 (compatible avec la GPL v3). Le code tiers et ses licences sont listés dans `NOTICE.txt`.
