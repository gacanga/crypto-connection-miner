/*
 * gostminer.cu - Crypto Connection Miner 0.6 (named GostMiner up to 0.4): multi-coin GPU miner for NVIDIA, no dev fee.
 *   --algo gostd     (default) GOSTcoin (GST): gostd = GOST R 34.11-2012-256( GOST R 34.11-2012-512( 80-byte header ) )
 *   --algo lyra2v2   Bitmark (MARKS) and other Lyra2REv2 coins: blake256 > keccak256 > cubehash256 > Lyra2(1,4,4) >
 *                    skein256 > cubehash256 > bmw256 (kernels of MYMINER / ccminer 2.3.1 in gpu/lyra2v2, GPL-3)
 *   --algo neoscrypt Feathercoin (FTC) and other NeoScrypt coins: FastKDF(BLAKE2s) > Salsa20/20 + ChaCha20/20
 *                    (N 128, r 2) > FastKDF (kernels of ccminer 2.3.1 / MYMINER in gpu/neoscrypt, GPL-3) - since 0.6.0
 * Solo on a local GOSTcoin wallet (RPC getwork, gostd only) or on a stratum pool (MiningCore).
 * NVIDIA GPUs from Maxwell (sm_50) to Blackwell (sm_120), Windows and Linux.
 *
 * One host thread per GPU scans the 2^32 nonces of its work; every GPU candidate is checked on the CPU against the
 * full 256-bit target: gostd with the GOSTcoin consensus code (src/gost_ref.c), lyra2v2 with MiningCore's reference
 * (src/lyra2ref, checked against the "powhash" of real Bitmark blocks), neoscrypt with the NeoScrypt reference
 * (src/neoscrypt, checked against the proof-of-work hash of real Feathercoin blocks).
 *  - solo (gostd): getwork from the wallet, new work every --refresh seconds or as soon as the wallet's block count
 *    changes, the block is handed in with getwork [data]; the wallet builds the block (its own coinbase key).
 *  - pool: stratum v1 (mining.subscribe / authorize / notify / set_difficulty / submit). Each GPU builds its own
 *    coinbase (extranonce2 = GPU slot + counter).
 *      gostd  : transaction id = gostd(coinbase) as is; merkle node = gostd(left || left) (GOSTcoin consensus);
 *               share target = diff1 / difficulty (Bitcoin diff1).
 *      lyra2v2: transaction id = sha256d(coinbase); merkle node = sha256d(left || right) (Bitcoin);
 *               share target = 256 * diff1 / difficulty (ccminer / MiningCore "shareMultiplier": 256 for Lyra2).
 *      neoscrypt: same coinbase and merkle as lyra2v2 (Bitcoin); share target = 65536 * diff1 / difficulty
 *               (ccminer / MiningCore "shareMultiplier": 65536 for NeoScrypt).
 *
 * Usage: crypto-connection-miner.exe [--algo gostd|lyra2v2|neoscrypt] [--gpus 0,1,2] [--kernel N] [--intensity N] [--stats 30] [--log <file>]
 *          [--selftest] [--bench S]
 *          solo: [--conf <gostcoin.conf>] [--host 127.0.0.1] [--port N] [--refresh 10]
 *          pool: --pool <host>:<port> --user <address>.<worker> [--pass x]
 *          --user without --pool and without --conf: the Crypto Connection pool, crypto-connection.net port 4033
 *          (gostd), 4043 (lyra2v2) or 4063 (neoscrypt).
 *   --kernel N (gostd): table placement variant (0 maxw 3 blocks/SM, 1 mix34 3 blocks/SM, 2 maxw 4 blocks/SM + shared
 *   stash, 3 shared 2 blocks/SM, 4 maxw 2 blocks/SM); by default each GPU measures every variant for 3 s at start-up
 *   and keeps the fastest (the best one depends on the GPU generation and clocks).
 *   --intensity N (lyra2v2): 2^N hashes per launch (default: 22 on GPUs with up to 20 SM, more on larger GPUs,
 *   limited by the GPU memory: 160 bytes per hash).
 *   --intensity N (neoscrypt): 2^N hashes per launch (default: 16 on GPUs with up to 20 SM, 17 up to 48 SM, 18 above,
 *   limited by the GPU memory: about 33 KB per hash). The speed is shown in kH/s for neoscrypt.
 *   A CUDA error stops the miner with exit code 3 (start it from a loop: start_pool.bat / start_pool.sh restart it).
 *   Solo: the RPC user, password and port are read from gostcoin.conf (default %APPDATA%\GOSTCoin\gostcoin.conf
 *   on Windows, ~/.gostcoin/gostcoin.conf on Linux); they are never printed.
 * Build: windows\build_miner.bat [output exe] (CUDA 12.9 + Visual Studio 2022) or linux/build_linux.sh (CUDA 12.9),
 *   static CUDA runtime, code for sm_50 sm_52 sm_60 sm_61 sm_70 sm_75 sm_80 sm_86 sm_89 sm_90 sm_100 sm_120 + PTX.
 * Licence: GPL-3 (the lyra2v2 and neoscrypt kernels come from ccminer, GPL-3); gostd code: see LICENSE / README.
 */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _CRT_SECURE_NO_WARNINGS
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#pragma comment(lib, "ws2_32.lib")
#define sock_close closesocket
#define SEND_FLAGS 0
static void sleep_ms(unsigned ms) { ::Sleep(ms); }
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <signal.h>
typedef int SOCKET;
#define INVALID_SOCKET (-1)
#define SD_BOTH SHUT_RDWR
#define sock_close close
#define SEND_FLAGS MSG_NOSIGNAL
static void sleep_ms(unsigned ms) { usleep((useconds_t)ms * 1000); }
#endif
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <math.h>
#include <time.h>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <chrono>
#include <ctype.h>

#include "gost_ref.h"
#include "gostd_core.h"
#include "sha256.h"
#include "lyra2ref.h"
#include "lyra2v2/lyra2v2_gpu.h"
#include "neoscrypt/neoscrypt_gpu.h"
#include "neoscrypt_ref.h"

#define GOSTMINER_VERSION "0.6.0"
#define MINER_NAME "Crypto Connection Miner"
/* default pool when only --user is given: the Crypto Connection pool (crypto-connection.net) */
#define DEFAULT_POOL_HOST "crypto-connection.net"
#define DEFAULT_POOL_PORT_GOSTD 4033
#define DEFAULT_POOL_PORT_LYRA2V2 4043
#define DEFAULT_POOL_PORT_NEOSCRYPT 4063

/* receive / send time-outs of a socket, in milliseconds */
static void sock_timeouts(SOCKET s, int rcv_ms, int snd_ms)
{
#ifdef _WIN32
	DWORD r = (DWORD)rcv_ms, w = (DWORD)snd_ms;
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&r, sizeof(r));
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&w, sizeof(w));
#else
	struct timeval r, w;
	r.tv_sec = rcv_ms / 1000; r.tv_usec = (rcv_ms % 1000) * 1000;
	w.tv_sec = snd_ms / 1000; w.tv_usec = (snd_ms % 1000) * 1000;
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&r, sizeof(r));
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&w, sizeof(w));
#endif
}

/* ------------------------------------------------------------------------------------------------
 * logging
 * ---------------------------------------------------------------------------------------------- */
static std::mutex g_log_mx;
static FILE *g_log = NULL;

static void mlog(const char *fmt, ...)
{
	char msg[2048];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	time_t t = time(NULL);
	struct tm lt;
#ifdef _WIN32
	localtime_s(&lt, &t);
#else
	localtime_r(&t, &lt);
#endif
	char ts[32];
	strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &lt);
	std::lock_guard<std::mutex> lk(g_log_mx);
	printf("[%s] %s\n", ts, msg);
	fflush(stdout);
	if (g_log) { fprintf(g_log, "[%s] %s\n", ts, msg); fflush(g_log); }
}

/* ------------------------------------------------------------------------------------------------
 * GPU part
 * ---------------------------------------------------------------------------------------------- */
#define CKR(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
	mlog("GPU %d: CUDA error %s (%s:%d)", gpu, cudaGetErrorString(e_), __FILE__, __LINE__); return false; } } while (0)

__device__ uint64_t d_T[8][256];
__constant__ gostd_job_t c_job;

/* table bank: (output word j, table i) in MASK -> read-only cache, otherwise shared memory */
template <uint64_t MASK>
struct dev_tb {
	const uint64_t (*s)[256];
	__host__ __device__ __forceinline__ uint64_t t(int i, int j, uint32_t idx) const
	{
#ifdef __CUDA_ARCH__
		if ((MASK >> (8 * j + i)) & 1) return __ldg(&d_T[i][idx]);
		return s[i][idx];
#else
		(void)i; (void)j; (void)idx; return 0;
#endif
	}
};

/* table placements measured on the P104-100 of the rig (06/11/2026, gostbench):
 *  - MASK_MAXW: the lookups of the ccminer streebog_maxwell kernel, per output word: w0 T0,T7 | w1 T0,T1,T7 |
 *    w2 T0,T1,T7 | w3 T0,T4,T7 | w4 T0,T2,T6,T7 | w5 T0,T1,T6,T7 | w6 T0,T6,T7 | w7 T0,T1,T6,T7
 *  - MASK_MIX34: table i via __ldg for word j when (i + j) % 8 < 3 (even words) or < 4 (odd words)
 * The best one depends on the card and its clocks (GPU 4, memory -1000: maxw 3 blocks/SM 25.5 MH/s;
 * GPU 0, memory 0: mix34 3 blocks/SM or maxw 4 blocks/SM with the shared stash 23.8 MH/s, ccminer 22.6),
 * so the miner measures the variants on each GPU at start-up (--kernel N forces one). */
#define MASK_MAXW (0x81ULL | 0x83ULL << 8 | 0x83ULL << 16 | 0x91ULL << 24 | 0xC5ULL << 32 | 0xC3ULL << 40 | \
                   0xC1ULL << 48 | 0xC3ULL << 56)
#define ROTB(i, j, K) ((((i) + (j)) % 8 < (K)) ? (1ULL << (8 * (j) + (i))) : 0ULL)
#define ROTW(j, K) (ROTB(0, j, K) | ROTB(1, j, K) | ROTB(2, j, K) | ROTB(3, j, K) | \
                    ROTB(4, j, K) | ROTB(5, j, K) | ROTB(6, j, K) | ROTB(7, j, K))
#define MASK_MIX34 (ROTW(0, 3) | ROTW(1, 4) | ROTW(2, 3) | ROTW(3, 4) | ROTW(4, 3) | ROTW(5, 4) | ROTW(6, 3) | ROTW(7, 4))
#define TPB 256
#define MAX_RES 15

template <uint64_t MASK, int MINB, bool SHSTASH>
__global__ void __launch_bounds__(TPB, MINB) k_search(uint32_t start, uint32_t npt, uint32_t *res)
{
	__shared__ uint64_t sT[8][256];
	__shared__ uint64_t sstash[SHSTASH ? 8 : 1][SHSTASH ? TPB : 1];
	uint64_t lstash[8];
	for (int k = threadIdx.x; k < 2048; k += TPB) sT[k >> 8][k & 255] = d_T[k >> 8][k & 255];
	__syncthreads();
	dev_tb<MASK> tb;
	tb.s = sT;
	uint64_t *stash = SHSTASH ? &sstash[0][threadIdx.x] : lstash;
	const int sstride = SHSTASH ? TPB : 1;
	const uint32_t stride = gridDim.x * TPB;
	uint32_t nonce = start + blockIdx.x * TPB + threadIdx.x;
	for (uint32_t it = 0; it < npt; it++, nonce += stride) {
		const uint64_t w0 = gostd_nonce<dev_tb<MASK>, false>(tb, c_job, nonce, 0, stash, sstride);
		if (gost_bswap64(w0) <= c_job.target) {
			const uint32_t slot = atomicAdd(&res[0], 1u);
			if (slot < MAX_RES) res[1 + slot] = nonce;
		}
	}
}

typedef void (*search_fn)(uint32_t, uint32_t, uint32_t *);
struct kernel_variant {
	const char *name;
	search_fn fn;
};
static const kernel_variant g_kernels[] = {
	{ "maxw 3 blocks/SM", k_search<MASK_MAXW, 3, false> },
	{ "mix34 3 blocks/SM", k_search<MASK_MIX34, 3, false> },
	{ "maxw 4 blocks/SM shared stash", k_search<MASK_MAXW, 4, true> },
	{ "shared 2 blocks/SM", k_search<0, 2, false> },
	{ "maxw 2 blocks/SM", k_search<MASK_MAXW, 2, false> },
};
#define NKERNELS ((int)(sizeof(g_kernels) / sizeof(g_kernels[0])))

/* full digests (self test) */
__global__ void __launch_bounds__(256, 1) k_dump(uint32_t start, uint32_t n, uint64_t *out)
{
	__shared__ uint64_t sT[8][256];
	uint64_t stash[8];
	for (int k = threadIdx.x; k < 2048; k += 256) sT[k >> 8][k & 255] = d_T[k >> 8][k & 255];
	__syncthreads();
	dev_tb<0> tb;
	tb.s = sT;
	const uint32_t i = blockIdx.x * 256 + threadIdx.x;
	if (i >= n) return;
	gostd_nonce<dev_tb<0>, true>(tb, c_job, start + i, out + 4 * (size_t)i, stash, 1);
}

/* ------------------------------------------------------------------------------------------------
 * configuration
 * ---------------------------------------------------------------------------------------------- */
enum algo_t { ALGO_GOSTD = 0, ALGO_LYRA2V2 = 1, ALGO_NEOSCRYPT = 2 };
static const char *algo_name(algo_t a) { return a == ALGO_LYRA2V2 ? "lyra2v2" : a == ALGO_NEOSCRYPT ? "neoscrypt" : "gostd"; }

struct config {
	algo_t algo = ALGO_GOSTD;
	int intensity = 0;   /* lyra2v2 / neoscrypt: 2^N hashes per launch, 0 = automatic */
	std::vector<int> gpus;
	std::string conf, host = "127.0.0.1", user, pass, logfile;
	int port = 0;
	int refresh = 10;
	int stats = 30;
	bool selftest = false;
	int bench = 0;
	int kernel = -1;   /* -1 = measure at start-up */
	bool solo_exit_on_error = true;
	/* pool mode (stratum) */
	std::string pool_host, worker, worker_pass = "x";
	int pool_port = 0;
	bool pool() const { return !pool_host.empty(); }
};

static config g_cfg;
static std::atomic<bool> g_quit(false);
static std::atomic<uint64_t> g_blockcount(0);
static std::atomic<uint64_t> g_found(0), g_accepted(0), g_rejected(0), g_cpu_bad(0);

static std::string trim(const std::string &s)
{
	size_t a = s.find_first_not_of(" \t\r\n"), b = s.find_last_not_of(" \t\r\n");
	return a == std::string::npos ? std::string() : s.substr(a, b - a + 1);
}

static int hexval(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static bool unhex(const std::string &h, uint8_t *out, size_t n)
{
	if (h.size() < 2 * n) return false;
	for (size_t i = 0; i < n; i++) {
		int a = hexval(h[2 * i]), b = hexval(h[2 * i + 1]);
		if (a < 0 || b < 0) return false;
		out[i] = (uint8_t)(a * 16 + b);
	}
	return true;
}

static bool unhexv(const std::string &h, std::vector<uint8_t> &out)
{
	if (h.size() % 2) return false;
	out.resize(h.size() / 2);
	return out.empty() || unhex(h, out.data(), out.size());
}

static std::string tohex(const uint8_t *b, size_t n)
{
	static const char *d = "0123456789abcdef";
	std::string s;
	for (size_t i = 0; i < n; i++) { s += d[b[i] >> 4]; s += d[b[i] & 15]; }
	return s;
}

/* gostd of any data: GOST R 34.11-2012-256( GOST R 34.11-2012-512( data ) ), bytes as computed.
 * GOSTcoin transaction id (uint256, little-endian bytes) = this digest as is (checked against the wallet:
 * the txid shown by RPC is the digest reversed); block hash shown by RPC = the digest of the header as is. */
static void gostd_any(const uint8_t *data, size_t len, uint8_t out[32])
{
	uint8_t d512[64];
	gost_ref_512(data, len, d512);
	gost_ref_256(d512, 64, out);
}

/* Bitcoin-family hash (lyra2v2 coins): little-endian uint256 bytes (out[31] = most significant) <= little-endian target */
static bool le_hash_le_target(const uint8_t h[32], const uint8_t target[32])
{
	for (int i = 31; i >= 0; i--) {
		if (h[i] < target[i]) return true;
		if (h[i] > target[i]) return false;
	}
	return true;
}

/* hash as the wallets show it: gostd digest as is, lyra2v2 / neoscrypt (uint256 little-endian) reversed */
static std::string hash_disp(const uint8_t dg[32])
{
	if (g_cfg.algo == ALGO_GOSTD) return tohex(dg, 32);
	uint8_t r[32];
	for (int i = 0; i < 32; i++) r[i] = dg[31 - i];
	return tohex(r, 32);
}

static inline uint32_t bswap32(uint32_t x)
{
	return (x >> 24) | ((x >> 8) & 0xFF00u) | ((x << 8) & 0xFF0000u) | (x << 24);
}

/* ------------------------------------------------------------------------------------------------
 * solo mode: wallet JSON-RPC (getwork)
 * ---------------------------------------------------------------------------------------------- */
static bool read_conf(config &c)
{
	if (c.conf.empty()) {
#ifdef _WIN32
		const char *ad = getenv("APPDATA");
		if (!ad) return false;
		c.conf = std::string(ad) + "\\GOSTCoin\\gostcoin.conf";
#else
		const char *hm = getenv("HOME");
		if (!hm) return false;
		c.conf = std::string(hm) + "/.gostcoin/gostcoin.conf";
#endif
	}
	FILE *f = fopen(c.conf.c_str(), "r");
	if (!f) { mlog("cannot open %s", c.conf.c_str()); return false; }
	char line[1024];
	while (fgets(line, sizeof(line), f)) {
		std::string l = trim(line);
		if (l.empty() || l[0] == '#') continue;
		size_t eq = l.find('=');
		if (eq == std::string::npos) continue;
		std::string k = trim(l.substr(0, eq)), v = trim(l.substr(eq + 1));
		if (k == "rpcuser") c.user = v;
		else if (k == "rpcpassword") c.pass = v;
		else if (k == "rpcport" && c.port == 0) c.port = atoi(v.c_str());
	}
	fclose(f);
	if (c.port == 0) c.port = 9376;
	return !c.user.empty() && !c.pass.empty();
}

static std::string b64(const std::string &in)
{
	static const char *tab = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	std::string out;
	size_t i = 0;
	for (; i + 2 < in.size(); i += 3) {
		uint32_t v = ((uint8_t)in[i] << 16) | ((uint8_t)in[i + 1] << 8) | (uint8_t)in[i + 2];
		out += tab[v >> 18]; out += tab[(v >> 12) & 63]; out += tab[(v >> 6) & 63]; out += tab[v & 63];
	}
	if (i + 1 == in.size()) {
		uint32_t v = (uint8_t)in[i] << 16;
		out += tab[v >> 18]; out += tab[(v >> 12) & 63]; out += "==";
	} else if (i + 2 == in.size()) {
		uint32_t v = ((uint8_t)in[i] << 16) | ((uint8_t)in[i + 1] << 8);
		out += tab[v >> 18]; out += tab[(v >> 12) & 63]; out += tab[(v >> 6) & 63]; out += '=';
	}
	return out;
}

/* one JSON-RPC call over HTTP/1.0 (Connection: close); returns the HTTP body, empty on failure */
static std::string rpc_call(const std::string &method, const std::string &params_json)
{
	std::string body = "{\"jsonrpc\":\"1.0\",\"id\":\"gostminer\",\"method\":\"" + method + "\",\"params\":" + params_json + "}";
	SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (s == INVALID_SOCKET) return std::string();
	sock_timeouts(s, 30000, 30000);
	sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons((u_short)g_cfg.port);
	inet_pton(AF_INET, g_cfg.host.c_str(), &a.sin_addr);
	if (connect(s, (sockaddr *)&a, sizeof(a)) != 0) { sock_close(s); return std::string(); }
	char hdr[512];
	snprintf(hdr, sizeof(hdr),
	         "POST / HTTP/1.0\r\nHost: %s:%d\r\nAuthorization: Basic %s\r\nContent-Type: application/json\r\n"
	         "Content-Length: %u\r\nConnection: close\r\n\r\n",
	         g_cfg.host.c_str(), g_cfg.port, b64(g_cfg.user + ":" + g_cfg.pass).c_str(), (unsigned)body.size());
	std::string req = std::string(hdr) + body;
	size_t sent = 0;
	while (sent < req.size()) {
		int n = send(s, req.data() + sent, (int)(req.size() - sent), SEND_FLAGS);
		if (n <= 0) { sock_close(s); return std::string(); }
		sent += n;
	}
	std::string resp;
	char buf[8192];
	for (;;) {
		int n = recv(s, buf, sizeof(buf), 0);
		if (n <= 0) break;
		resp.append(buf, n);
	}
	sock_close(s);
	size_t p = resp.find("\r\n\r\n");
	return p == std::string::npos ? std::string() : resp.substr(p + 4);
}

/* value of "key":"string" or "key":literal in a flat JSON text */
static bool json_get(const std::string &js, const char *key, std::string &out)
{
	std::string k = std::string("\"") + key + "\"";
	size_t p = js.find(k);
	if (p == std::string::npos) return false;
	p = js.find(':', p + k.size());
	if (p == std::string::npos) return false;
	p++;
	while (p < js.size() && (js[p] == ' ' || js[p] == '\t')) p++;
	if (p < js.size() && js[p] == '"') {
		size_t e = js.find('"', p + 1);
		if (e == std::string::npos) return false;
		out = js.substr(p + 1, e - p - 1);
		return true;
	}
	size_t e = js.find_first_of(",}]", p);
	out = trim(js.substr(p, e == std::string::npos ? std::string::npos : e - p));
	return true;
}

/* a unit of work: header in consensus byte order (nonce 0), 256-bit target.
 * Solo: getwork data (128 bytes, words byte-reversed). Pool: stratum job id, extranonce2 and ntime to submit. */
struct work {
	uint8_t data[128];
	uint8_t header[80];
	uint8_t target[32];   /* little-endian uint256 (target[31] = most significant byte) */
	uint64_t target64;    /* digest bytes 0..7 (big-endian) must be <= this */
	uint64_t height;      /* solo: wallet block count when fetched */
	/* pool mode */
	uint64_t gen;         /* stratum generation (new job / new difficulty) when built */
	std::string job_id, en2_hex, ntime_hex;
	uint8_t net_target[32];   /* little-endian, from nbits: share = block candidate */
	double diff;
};

static bool get_work(work &w)
{
	std::string r = rpc_call("getwork", "[]");
	std::string data, target;
	if (r.empty() || !json_get(r, "data", data) || !json_get(r, "target", target)) {
		std::string err;
		if (!r.empty() && json_get(r, "message", err)) mlog("getwork: %s", err.c_str());
		else mlog("getwork: no answer from the wallet");
		return false;
	}
	if (!unhex(data, w.data, 128) || !unhex(target, w.target, 32)) { mlog("getwork: bad data"); return false; }
	for (int i = 0; i < 80; i += 4) {
		w.header[i] = w.data[i + 3]; w.header[i + 1] = w.data[i + 2];
		w.header[i + 2] = w.data[i + 1]; w.header[i + 3] = w.data[i];
	}
	/* the digest, read big-endian, is the uint256 hash; target[31] is its most significant byte */
	uint64_t t = 0;
	for (int k = 31; k >= 24; k--) t = (t << 8) | w.target[k];
	w.target64 = t;
	w.height = g_blockcount.load();
	return true;
}

/* digest (big-endian hash) <= little-endian 256-bit target */
static bool digest_le_target(const uint8_t digest[32], const uint8_t target[32])
{
	for (int i = 0; i < 32; i++) {
		if (digest[i] < target[31 - i]) return true;
		if (digest[i] > target[31 - i]) return false;
	}
	return true;
}

/* full check of a nonce on the CPU against the 256-bit target */
static bool cpu_check(const work &w, uint32_t nonce, uint8_t digest[32])
{
	uint8_t hdr[80];
	memcpy(hdr, w.header, 80);
	hdr[76] = (uint8_t)nonce; hdr[77] = (uint8_t)(nonce >> 8); hdr[78] = (uint8_t)(nonce >> 16); hdr[79] = (uint8_t)(nonce >> 24);
	if (g_cfg.algo == ALGO_LYRA2V2) {
		mc_lyra2re2_hash((const char *)hdr, (char *)digest);
		return le_hash_le_target(digest, w.target);
	}
	if (g_cfg.algo == ALGO_NEOSCRYPT) {
		neoscrypt(digest, hdr, NEOSCRYPT_PROFILE);
		return le_hash_le_target(digest, w.target);
	}
	gostd_ref(hdr, digest);
	return digest_le_target(digest, w.target);
}

/* digest of a checked nonce <= little-endian target (block candidate test) */
static bool algo_meets(const uint8_t digest[32], const uint8_t target[32])
{
	return g_cfg.algo != ALGO_GOSTD ? le_hash_le_target(digest, target) : digest_le_target(digest, target);
}

static bool submit_solo(const work &w, uint32_t nonce)
{
	uint8_t d[128];
	memcpy(d, w.data, 128);
	/* header bytes 76..79 = nonce little-endian; data words are byte-reversed */
	d[76] = (uint8_t)(nonce >> 24); d[77] = (uint8_t)(nonce >> 16); d[78] = (uint8_t)(nonce >> 8); d[79] = (uint8_t)nonce;
	std::string r = rpc_call("getwork", "[\"" + tohex(d, 128) + "\"]");
	std::string res;
	if (r.empty() || !json_get(r, "result", res)) { mlog("submit: no answer from the wallet"); return false; }
	return res == "true";
}

/* block count watcher (solo): new block -> every GPU thread fetches new work */
static void watcher()
{
	while (!g_quit) {
		std::string r = rpc_call("getblockcount", "[]");
		std::string v;
		if (!r.empty() && json_get(r, "result", v)) {
			uint64_t h = strtoull(v.c_str(), NULL, 10);
			if (h && h != g_blockcount.load()) {
				if (g_blockcount.load()) mlog("new block %llu", (unsigned long long)h);
				g_blockcount = h;
			}
		}
		sleep_ms(1000);
	}
}

/* ------------------------------------------------------------------------------------------------
 * pool mode: minimal JSON parser + stratum v1 client
 * ---------------------------------------------------------------------------------------------- */
struct jv {
	enum kind { NUL, BOOL, NUM, STR, ARR, OBJ } t = NUL;
	bool b = false;
	double n = 0;
	std::string s;
	std::vector<jv> a;
	std::vector<std::pair<std::string, jv>> o;
	const jv *get(const char *k) const
	{
		if (t != OBJ) return NULL;
		for (const auto &kv : o) if (kv.first == k) return &kv.second;
		return NULL;
	}
};

static void jskip(const char *&p) { while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++; }

static bool jstring(const char *&p, std::string &out)
{
	if (*p != '"') return false;
	p++;
	out.clear();
	while (*p && *p != '"') {
		if (*p == '\\') {
			p++;
			switch (*p) {
			case 'n': out += '\n'; break;
			case 't': out += '\t'; break;
			case 'r': out += '\r'; break;
			case 'b': out += '\b'; break;
			case 'f': out += '\f'; break;
			case 'u': for (int k = 0; k < 4 && p[1]; k++) p++; out += '?'; break;
			case 0: return false;
			default: out += *p; break;
			}
			p++;
		} else out += *p++;
	}
	if (*p != '"') return false;
	p++;
	return true;
}

static bool jparse(const char *&p, jv &v, int depth = 0)
{
	if (depth > 32) return false;
	jskip(p);
	if (*p == '{') {
		v.t = jv::OBJ;
		p++;
		jskip(p);
		if (*p == '}') { p++; return true; }
		for (;;) {
			jskip(p);
			std::string k;
			if (!jstring(p, k)) return false;
			jskip(p);
			if (*p != ':') return false;
			p++;
			jv x;
			if (!jparse(p, x, depth + 1)) return false;
			v.o.emplace_back(k, std::move(x));
			jskip(p);
			if (*p == ',') { p++; continue; }
			if (*p == '}') { p++; return true; }
			return false;
		}
	}
	if (*p == '[') {
		v.t = jv::ARR;
		p++;
		jskip(p);
		if (*p == ']') { p++; return true; }
		for (;;) {
			jv x;
			if (!jparse(p, x, depth + 1)) return false;
			v.a.push_back(std::move(x));
			jskip(p);
			if (*p == ',') { p++; continue; }
			if (*p == ']') { p++; return true; }
			return false;
		}
	}
	if (*p == '"') { v.t = jv::STR; return jstring(p, v.s); }
	if (!strncmp(p, "true", 4)) { v.t = jv::BOOL; v.b = true; p += 4; return true; }
	if (!strncmp(p, "false", 5)) { v.t = jv::BOOL; v.b = false; p += 5; return true; }
	if (!strncmp(p, "null", 4)) { v.t = jv::NUL; p += 4; return true; }
	char *e = NULL;
	v.n = strtod(p, &e);
	if (e == p) return false;
	v.t = jv::NUM;
	p = e;
	return true;
}

static std::string jesc(const std::string &s)
{
	std::string o;
	for (char c : s) {
		if (c == '"' || c == '\\') { o += '\\'; o += c; }
		else if ((unsigned char)c < 0x20) o += ' ';
		else o += c;
	}
	return o;
}

/* stratum job as sent by mining.notify */
struct sjob {
	std::string id;
	uint8_t prev_le[32];              /* previous block hash, little-endian uint256 bytes */
	std::vector<uint8_t> coinb1, coinb2;
	std::vector<std::vector<uint8_t>> branches;
	uint32_t version = 0, nbits = 0, ntime = 0;
	std::string ntime_hex;
};

static std::mutex g_sm;                       /* protects the stratum state below */
static sjob g_job;
static bool g_have_job = false;
static double g_diff = 1.0;
static std::vector<uint8_t> g_en1;
static int g_en2size = 4;
static std::atomic<uint64_t> g_gen(1);        /* bumped on each new job / difficulty / disconnection */
static std::atomic<bool> g_connected(false);
static std::atomic<uint64_t> g_shares_ok(0), g_shares_bad(0), g_candidates(0), g_submitted(0);
static std::string g_last_reject;
static SOCKET g_sock = INVALID_SOCKET;
static std::mutex g_send_mx;
static std::atomic<uint32_t> g_next_id(100);

static bool s_send(const std::string &line)
{
	std::lock_guard<std::mutex> lk(g_send_mx);
	if (g_sock == INVALID_SOCKET) return false;
	std::string l = line + "\n";
	size_t sent = 0;
	while (sent < l.size()) {
		int n = send(g_sock, l.data() + sent, (int)(l.size() - sent), SEND_FLAGS);
		if (n <= 0) return false;
		sent += n;
	}
	return true;
}

static SOCKET s_connect(const std::string &host, int port)
{
	addrinfo hints, *res = NULL;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	char ps[16];
	snprintf(ps, sizeof(ps), "%d", port);
	if (getaddrinfo(host.c_str(), ps, &hints, &res) != 0 || !res) return INVALID_SOCKET;
	SOCKET s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
	if (s != INVALID_SOCKET && connect(s, res->ai_addr, (int)res->ai_addrlen) != 0) { sock_close(s); s = INVALID_SOCKET; }
	freeaddrinfo(res);
	if (s != INVALID_SOCKET) {
		sock_timeouts(s, 120000, 30000);   /* the pool sends a job at least every few seconds */
		int nd = 1;
		setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&nd, sizeof(nd));
	}
	return s;
}

static uint32_t hex_u32(const std::string &h)
{
	return (uint32_t)strtoul(h.c_str(), NULL, 16);
}

/* last stratum events (diagnosis of GPU errors): what the pool sent just before */
static std::mutex g_ev_mx;
static std::string g_ev[8];
static unsigned g_ev_n = 0;
static void ev_note(const std::string &e)
{
	char ts[32];
	const auto now = std::chrono::system_clock::now();
	const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
	snprintf(ts, sizeof(ts), "%lld.%03lld ", (ms / 1000) % 100000, ms % 1000);
	std::lock_guard<std::mutex> lk(g_ev_mx);
	g_ev[g_ev_n++ % 8] = ts + e.substr(0, 90);
}
static std::string ev_dump()
{
	std::lock_guard<std::mutex> lk(g_ev_mx);
	std::string o;
	for (unsigned i = g_ev_n > 8 ? g_ev_n - 8 : 0; i < g_ev_n; i++) { o += " | "; o += g_ev[i % 8]; }
	return o;
}

static void s_handle(const std::string &line)
{
	ev_note(line);
	const char *p = line.c_str();
	jv m;
	if (!jparse(p, m) || m.t != jv::OBJ) { mlog("pool: unreadable message"); return; }
	const jv *method = m.get("method");
	const jv *id = m.get("id");
	const jv *result = m.get("result");
	const jv *error = m.get("error");
	const jv *params = m.get("params");
	if (method && method->t == jv::STR) {
		if (method->s == "mining.set_difficulty" && params && params->t == jv::ARR && !params->a.empty() && params->a[0].t == jv::NUM) {
			std::lock_guard<std::mutex> lk(g_sm);
			if (params->a[0].n > 0 && params->a[0].n != g_diff) {
				g_diff = params->a[0].n;
				mlog("pool: difficulty %.6g", g_diff);
				g_gen++;
			}
			return;
		}
		if (method->s == "mining.notify" && params && params->t == jv::ARR && params->a.size() >= 8) {
			const auto &a = params->a;
			sjob j;
			if (a[0].t != jv::STR || a[1].t != jv::STR || a[2].t != jv::STR || a[3].t != jv::STR || a[4].t != jv::ARR ||
			    a[5].t != jv::STR || a[6].t != jv::STR || a[7].t != jv::STR) { mlog("pool: bad mining.notify"); return; }
			j.id = a[0].s;
			uint8_t pv[32];
			if (!unhex(a[1].s, pv, 32)) { mlog("pool: bad previous hash"); return; }
			/* the pool sends the little-endian hash with each 32-bit word byte-swapped */
			for (int w = 0; w < 8; w++)
				for (int k = 0; k < 4; k++) j.prev_le[4 * w + k] = pv[4 * w + 3 - k];
			if (!unhexv(a[2].s, j.coinb1) || !unhexv(a[3].s, j.coinb2)) { mlog("pool: bad coinbase"); return; }
			for (const auto &b : a[4].a) {
				std::vector<uint8_t> v;
				if (b.t != jv::STR || !unhexv(b.s, v) || v.size() != 32) { mlog("pool: bad merkle branch"); return; }
				j.branches.push_back(v);
			}
			j.version = hex_u32(a[5].s);
			j.nbits = hex_u32(a[6].s);
			j.ntime = hex_u32(a[7].s);
			j.ntime_hex = a[7].s;
			const bool clean = a.size() > 8 && a[8].t == jv::BOOL && a[8].b;
			std::lock_guard<std::mutex> lk(g_sm);
			const bool newblock = !g_have_job || memcmp(j.prev_le, g_job.prev_le, 32) != 0;
			g_job = j;
			g_have_job = true;
			g_gen++;
			if (newblock) {
				uint8_t disp[32];
				for (int i = 0; i < 32; i++) disp[i] = j.prev_le[31 - i];
				mlog("pool: new block job %s (previous %s...)%s", j.id.c_str(), tohex(disp, 8).c_str(), clean ? " clean" : "");
			}
			return;
		}
		if (method->s == "client.reconnect" || method->s == "client.show_message") {
			mlog("pool: %s (ignored)", method->s.c_str());
			return;
		}
		return;
	}
	if (!id || id->t != jv::NUM) return;
	const int iid = (int)id->n;
	const bool ok = result && result->t == jv::BOOL && result->b && (!error || error->t == jv::NUL);
	std::string emsg;
	if (error && error->t == jv::ARR && error->a.size() >= 2 && error->a[1].t == jv::STR) emsg = error->a[1].s;
	else if (error && error->t == jv::OBJ && error->get("message") && error->get("message")->t == jv::STR) emsg = error->get("message")->s;
	if (iid == 1) {
		/* subscribe: [[subscriptions], extranonce1, extranonce2_size] */
		if (!result || result->t != jv::ARR || result->a.size() < 3 || result->a[1].t != jv::STR || result->a[2].t != jv::NUM) {
			mlog("pool: subscribe failed %s", emsg.c_str());
			return;
		}
		std::lock_guard<std::mutex> lk(g_sm);
		unhexv(result->a[1].s, g_en1);
		g_en2size = (int)result->a[2].n;
		mlog("pool: subscribed, extranonce1 %s, extranonce2 %d bytes", result->a[1].s.c_str(), g_en2size);
		g_gen++;
		return;
	}
	if (iid == 2) {
		if (ok) mlog("pool: worker %s authorized", g_cfg.worker.c_str());
		else mlog("pool: worker %s NOT authorized %s", g_cfg.worker.c_str(), emsg.c_str());
		return;
	}
	if (iid >= 100) {
		if (ok) g_shares_ok++;
		else {
			g_shares_bad++;
			mlog("pool: share rejected: %s", emsg.empty() ? "no reason given" : emsg.c_str());
			std::lock_guard<std::mutex> lk(g_sm);
			g_last_reject = emsg;
		}
	}
}

static void stratum_thread()
{
	int backoff = 5;
	while (!g_quit) {
		mlog("pool: connecting to %s:%d", g_cfg.pool_host.c_str(), g_cfg.pool_port);
		SOCKET s = s_connect(g_cfg.pool_host, g_cfg.pool_port);
		if (s == INVALID_SOCKET) {
			mlog("pool: connection failed, retry in %d s", backoff);
			for (int i = 0; i < backoff * 10 && !g_quit; i++) sleep_ms(100);
			if (backoff < 60) backoff *= 2;
			continue;
		}
		backoff = 5;
		{
			std::lock_guard<std::mutex> lk(g_send_mx);
			g_sock = s;
		}
		g_connected = true;
		s_send("{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"CryptoConnectionMiner/" GOSTMINER_VERSION "\"]}");
		s_send("{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"" + jesc(g_cfg.worker) + "\",\"" + jesc(g_cfg.worker_pass) + "\"]}");
		std::string buf;
		char tmp[4096];
		while (!g_quit) {
			int n = recv(s, tmp, sizeof(tmp), 0);
			if (n <= 0) { mlog("pool: connection lost"); break; }
			buf.append(tmp, n);
			size_t nl;
			while ((nl = buf.find('\n')) != std::string::npos) {
				std::string line = trim(buf.substr(0, nl));
				buf.erase(0, nl + 1);
				if (!line.empty()) s_handle(line);
			}
			if (buf.size() > (1u << 20)) { mlog("pool: message too long"); break; }
		}
		{
			std::lock_guard<std::mutex> lk(g_send_mx);
			sock_close(g_sock);
			g_sock = INVALID_SOCKET;
		}
		g_connected = false;
		{
			std::lock_guard<std::mutex> lk(g_sm);
			g_have_job = false;
			g_en1.clear();
		}
		g_gen++;
		for (int i = 0; i < 50 && !g_quit; i++) sleep_ms(100);
	}
}

/* 256-bit little-endian target = diff1 / difficulty, diff1 = 0x00000000FFFF0000...0000 (Bitcoin) */
static void diff_to_target(double diff, uint8_t target[32], uint64_t &target64)
{
	memset(target, 0, 32);
	if (diff <= 0) diff = 1e-9;
	/* x = target / 2^192 = 65535 * 2^16 / diff */
	double x = 65535.0 * 65536.0 / diff;
	uint64_t limb[4] = {0, 0, 0, 0};   /* limb[3] = bits 192..255 */
	if (x >= 18446744073709551615.0) { limb[3] = limb[2] = limb[1] = limb[0] = ~0ULL; }
	else {
		for (int L = 3; L >= 0; L--) {
			const double f = floor(x);
			limb[L] = (uint64_t)f;
			x = (x - f) * 18446744073709551616.0;
		}
	}
	for (int L = 0; L < 4; L++)
		for (int k = 0; k < 8; k++) target[8 * L + k] = (uint8_t)(limb[L] >> (8 * k));
	target64 = limb[3];
}

/* little-endian 256-bit target from compact nbits */
static void nbits_to_target(uint32_t nbits, uint8_t target[32])
{
	memset(target, 0, 32);
	const int exp = (int)(nbits >> 24);
	const uint32_t mant = nbits & 0x007FFFFF;
	for (int i = 0; i < 3; i++) {
		const int pos = exp - 3 + i;
		if (pos >= 0 && pos < 32) target[pos] = (uint8_t)(mant >> (8 * i));
	}
}

/* builds a pool work unit for one GPU: extranonce2 = (gpu slot, counter), coinbase-hash merkle root */
static bool pool_work(int slot, uint32_t &en2ctr, work &w)
{
	sjob j;
	std::vector<uint8_t> en1;
	int en2size;
	double diff;
	{
		std::lock_guard<std::mutex> lk(g_sm);
		if (!g_have_job || g_en1.empty()) return false;
		j = g_job;
		en1 = g_en1;
		en2size = g_en2size;
		diff = g_diff;
		w.gen = g_gen.load();
	}
	if (en2size < 1 || en2size > 16) en2size = 4;
	std::vector<uint8_t> en2((size_t)en2size, 0);
	const uint64_t v = ((uint64_t)(slot & 0xFF) << 24) | (en2ctr++ & 0xFFFFFF);
	for (int i = 0; i < en2size && i < 8; i++) en2[en2size - 1 - i] = (uint8_t)(v >> (8 * i));
	std::vector<uint8_t> cb;
	cb.reserve(j.coinb1.size() + en1.size() + en2.size() + j.coinb2.size());
	cb.insert(cb.end(), j.coinb1.begin(), j.coinb1.end());
	cb.insert(cb.end(), en1.begin(), en1.end());
	cb.insert(cb.end(), en2.begin(), en2.end());
	cb.insert(cb.end(), j.coinb2.begin(), j.coinb2.end());
	uint8_t root[32];
	if (g_cfg.algo != ALGO_GOSTD) {
		/* Bitcoin: txid = sha256d(coinbase), merkle node = sha256d(left || right), branches as sent by the pool */
		gm_sha256d(cb.data(), cb.size(), root);
		for (size_t k = 0; k < j.branches.size(); k++) {
			uint8_t pair[64];
			memcpy(pair, root, 32);
			memcpy(pair + 32, j.branches[k].data(), 32);
			gm_sha256d(pair, 64, root);
		}
	} else {
		gostd_any(cb.data(), cb.size(), root);   /* transaction id, little-endian bytes */
		/* GOSTcoin merkle node = gostd(left || left), as is: the two-range Hash() of GOSTcoin src/hash.h copies the left
		 * node twice, so only the number of branches matters (checked on the 2-transaction blocks 1684050, 1683423) */
		for (size_t k = 0; k < j.branches.size(); k++) {
			uint8_t pair[64];
			memcpy(pair, root, 32);
			memcpy(pair + 32, root, 32);
			gostd_any(pair, 64, root);
		}
	}
	uint8_t *h = w.header;
	memcpy(h + 0, &j.version, 4);
	memcpy(h + 4, j.prev_le, 32);
	memcpy(h + 36, root, 32);
	memcpy(h + 68, &j.ntime, 4);
	memcpy(h + 72, &j.nbits, 4);
	memset(h + 76, 0, 4);
	/* Lyra2 pools (MiningCore shareMultiplier 256, ccminer) count shares 256 times easier than diff1,
	 * NeoScrypt pools (shareMultiplier 65536) 65536 times */
	diff_to_target(g_cfg.algo == ALGO_LYRA2V2 ? diff / 256.0 : g_cfg.algo == ALGO_NEOSCRYPT ? diff / 65536.0 : diff,
	               w.target, w.target64);
	nbits_to_target(j.nbits, w.net_target);
	w.job_id = j.id;
	w.en2_hex = tohex(en2.data(), en2.size());
	w.ntime_hex = j.ntime_hex;
	w.diff = diff;
	w.height = 0;
	return true;
}

static void submit_share(int gpu, const work &w, uint32_t nonce, const uint8_t digest[32])
{
	char nh[16];
	snprintf(nh, sizeof(nh), "%08x", nonce);
	const uint32_t id = ++g_next_id;
	const bool cand = algo_meets(digest, w.net_target);
	if (cand) {
		g_candidates++;
		mlog("GPU %d: share is a BLOCK candidate, hash %s (job %s)", gpu, hash_disp(digest).c_str(), w.job_id.c_str());
	}
	std::string msg = "{\"id\":" + std::to_string(id) + ",\"method\":\"mining.submit\",\"params\":[\"" + jesc(g_cfg.worker) +
	                  "\",\"" + jesc(w.job_id) + "\",\"" + w.en2_hex + "\",\"" + jesc(w.ntime_hex) + "\",\"" + nh + "\"]}";
	if (s_send(msg)) g_submitted++;
	else mlog("GPU %d: share not sent (pool disconnected)", gpu);
}

/* ------------------------------------------------------------------------------------------------
 * per-GPU mining thread
 * ---------------------------------------------------------------------------------------------- */
struct gpu_stat {
	std::atomic<uint64_t> hashes{0};
	std::atomic<bool> alive{false};
};
static gpu_stat g_stat[16];

static bool gpu_init(int gpu, int grid[NKERNELS])
{
	CKR(cudaSetDevice(gpu));
	cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);   /* low CPU use; ignored if the context exists */
	cudaGetLastError();
	cudaDeviceProp prop;
	CKR(cudaGetDeviceProperties(&prop, gpu));
	CKR(cudaMemcpyToSymbol(d_T, gost_ref_tables(), sizeof(uint64_t) * 8 * 256));
	for (int k = 0; k < NKERNELS; k++) {
		int bps = 0;
		CKR(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&bps, (const void *)g_kernels[k].fn, TPB, 0));
		grid[k] = bps > 0 ? prop.multiProcessorCount * bps * 8 : 0;
	}
	mlog("GPU %d: %s, compute %d.%d, %d SM, %.1f GB", gpu, prop.name, prop.major, prop.minor, prop.multiProcessorCount,
	     prop.totalGlobalMem / 1073741824.0);
	return true;
}

/* GPU self test: 4096 digests against the consensus reference */
static bool gpu_selftest(int gpu)
{
	uint8_t hdr[80];
	for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)(i * 37 + 11);
	hdr[0] = 0xFF; hdr[64] = 0xFF;   /* forces the Sigma carries */
	gostd_job_t J;
	gostd_prepare_job(&J, hdr, 0, gost_ref_tables(), gost_ref_constants());
	CKR(cudaMemcpyToSymbol(c_job, &J, sizeof(J)));
	const uint32_t n = 4096, start = 0x12345678u;
	uint64_t *d_out;
	CKR(cudaMalloc(&d_out, 32 * (size_t)n));
	k_dump<<<n / 256, 256>>>(start, n, d_out);
	CKR(cudaGetLastError());
	std::vector<uint64_t> out(4 * (size_t)n);
	CKR(cudaMemcpy(out.data(), d_out, 32 * (size_t)n, cudaMemcpyDeviceToHost));
	CKR(cudaFree(d_out));
	int bad = 0;
	for (uint32_t i = 0; i < n; i++) {
		uint8_t want[32];
		const uint32_t nn = start + i;
		hdr[76] = (uint8_t)nn; hdr[77] = (uint8_t)(nn >> 8); hdr[78] = (uint8_t)(nn >> 16); hdr[79] = (uint8_t)(nn >> 24);
		gostd_ref(hdr, want);
		for (int w = 0; w < 4; w++) {
			uint64_t v = 0;
			for (int k = 7; k >= 0; k--) v = (v << 8) | want[8 * w + k];
			if (out[4 * (size_t)i + w] != v) { bad++; break; }
		}
	}
	mlog("GPU %d: self test %u digests, %d mismatches -> %s", gpu, n, bad, bad ? "FAILED" : "OK");
	return bad == 0;
}

/* kernel variant: forced, or the fastest of a 3 s measurement each (target 0: no result); -1 on CUDA error */
static int gpu_pick_kernel(int gpu, const int grids[NKERNELS], uint32_t *d_res)
{
	int kv = g_cfg.kernel;
	if (kv >= 0 && kv < NKERNELS) return kv;
	uint8_t hdr[80];
	for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)(i * 13 + gpu);
	gostd_job_t J;
	gostd_prepare_job(&J, hdr, 0, gost_ref_tables(), gost_ref_constants());
	cudaMemcpyToSymbol(c_job, &J, sizeof(J));
	double best = 0;
	kv = 0;
	for (int k = 0; k < NKERNELS && !g_quit; k++) {
		if (grids[k] <= 0) { mlog("GPU %d: kernel %d (%s) cannot run on this GPU", gpu, k, g_kernels[k].name); continue; }
		uint32_t tnpt = 8;
		double tot = 0, el = 0;
		uint32_t st = 0;
		while (el < 3.0 && !g_quit) {
			const auto l0 = std::chrono::steady_clock::now();
			g_kernels[k].fn<<<grids[k], TPB>>>(st, tnpt, d_res);
			if (cudaDeviceSynchronize() != cudaSuccess) { mlog("GPU %d: CUDA error during the kernel measurement", gpu); return -1; }
			const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - l0).count();
			const double n = (double)grids[k] * TPB * tnpt;
			st += (uint32_t)n;
			if (ms < 100 && tnpt < 1024) { tnpt *= 2; continue; }
			tot += n;
			el += ms / 1000.0;
		}
		const double mhs = el > 0 ? tot / el / 1e6 : 0;
		mlog("GPU %d: kernel %d (%s) %.2f MH/s", gpu, k, g_kernels[k].name, mhs);
		if (mhs > best) { best = mhs; kv = k; }
	}
	return kv;
}

static std::atomic<uint64_t> g_gpu_resets(0);
static std::atomic<bool> g_cuda_fatal(false);   /* a GPU hit a CUDA error: the process exits with code 3 to be restarted */

/* mines on one GPU until quit (returns true) or a CUDA error (returns false, details logged) */
static bool gpu_mine(int gpu, int slot, int kv, int grid, uint32_t *d_res)
{
	const search_fn kfn = g_kernels[kv].fn;
	const bool bench = g_cfg.bench > 0;
	const bool pool = g_cfg.pool();
	uint32_t npt = 8;
	uint32_t en2ctr = 0;
	while (!g_quit) {
		work w;
		if (bench) {
			for (int i = 0; i < 80; i++) w.header[i] = (uint8_t)(rand() & 0xFF);
			memset(w.target, 0, 32);
			w.target64 = 0;
			w.height = 0;
		} else if (pool) {
			if (!pool_work(slot, en2ctr, w)) { sleep_ms(200); continue; }
		} else if (!get_work(w)) {
			sleep_ms(5000);
			continue;
		}
		gostd_job_t J;
		gostd_prepare_job(&J, w.header, w.target64, gost_ref_tables(), gost_ref_constants());
		cudaError_t e = cudaMemcpyToSymbol(c_job, &J, sizeof(J));
		if (e != cudaSuccess) { mlog("GPU %d: job upload failed: %s", gpu, cudaGetErrorString(e)); return false; }
		const auto t0 = std::chrono::steady_clock::now();
		uint64_t start = 0;
		while (!g_quit && start < (1ULL << 32)) {
			if (pool) {
				if (g_gen.load() != w.gen) break;   /* new job, difficulty or connection */
			} else if (!bench) {
				if (g_blockcount.load() != w.height) break;   /* new block */
				if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > g_cfg.refresh) break;
			} else if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > g_cfg.refresh) break;
			uint64_t n = (uint64_t)grid * TPB * npt;
			if (start + n > (1ULL << 32)) {
				const uint64_t left = (1ULL << 32) - start;
				npt = (uint32_t)((left + (uint64_t)grid * TPB - 1) / ((uint64_t)grid * TPB));
				if (npt == 0) npt = 1;
				n = (uint64_t)grid * TPB * npt;
			}
			cudaMemset(d_res, 0, sizeof(uint32_t));
			const auto l0 = std::chrono::steady_clock::now();
			kfn<<<grid, TPB>>>((uint32_t)start, npt, d_res);
			uint32_t res[1 + MAX_RES];
			e = cudaMemcpy(res, d_res, sizeof(res), cudaMemcpyDeviceToHost);
			if (e != cudaSuccess) {
				mlog("GPU %d: CUDA error %s (kernel %d, grid %d, %u nonces per thread, start %08llx, %.1f s on this work)",
				     gpu, cudaGetErrorString(e), kv, grid, npt, (unsigned long long)start,
				     std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
				return false;
			}
			const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - l0).count();
			g_stat[gpu].hashes += n;
			start += n;
			/* aim at ~150 ms per launch (well below the Windows watchdog) */
			if (ms < 100 && npt < 1024) npt *= 2;
			else if (ms > 300 && npt > 1) npt /= 2;
			const uint32_t cnt = res[0] < MAX_RES ? res[0] : MAX_RES;
			for (uint32_t i = 0; i < cnt && !bench; i++) {
				uint8_t dg[32];
				const uint32_t nonce = res[1 + i];
				if (!cpu_check(w, nonce, dg)) {
					/* only the first 64 bits are compared on the GPU: a candidate can fail the full target */
					if (gost_bswap64(*(const uint64_t *)dg) > w.target64) { g_cpu_bad++; mlog("GPU %d: nonce %08x does not validate on the CPU", gpu, nonce); }
					continue;
				}
				if (pool) {
					submit_share(gpu, w, nonce, dg);
					continue;
				}
				g_found++;
				mlog("GPU %d: BLOCK FOUND nonce %08x hash %s", gpu, nonce, tohex(dg, 32).c_str());
				if (submit_solo(w, nonce)) { g_accepted++; mlog("GPU %d: block accepted by the wallet", gpu); }
				else { g_rejected++; mlog("GPU %d: block REJECTED by the wallet (stale or invalid)", gpu); }
			}
		}
	}
	return true;
}

/* ------------------------------------------------------------------------------------------------
 * lyra2v2 GPU part (gpu/lyra2v2: MYMINER / ccminer kernels)
 * ---------------------------------------------------------------------------------------------- */
/* Bitmark block 2490869 (lyra2rev2, found on 06/11/2026): header, its nonce and its powhash (RPC getblock) */
static const char *L2_REF_HEADER =
	"040a00006ec06025cec8b06a24321c0ecf7be669339bda929314aa2e8ce18e3105c474f41ccb3d8bf2ed6c2e651ca0852ad2412d43c17c02"
	"6cb9138d9fb863c082b5076edad6ee6a2e6d141c00d64314";
static const char *L2_REF_POWHASH = "000000000507ca55f0028b8ff5299bd5b0daf9ae126e12df00a7039e3802df45";
static const char *L2_REF_BLOCKHASH = "3217121846a8c5678d3471e11e34efdff5572e06d29b43b0dc34f521ce8441c9";

static uint32_t l2_pick_throughput(int gpu, const cudaDeviceProp &prop)
{
	int n = g_cfg.intensity;
	if (n <= 0) n = prop.multiProcessorCount <= 20 ? 22 : prop.multiProcessorCount <= 48 ? 23 : 24;
	if (n < 12) n = 12;
	if (n > 25) n = 25;
	uint64_t thr = 1ULL << n;
	size_t fr = 0, tot = 0;
	if (cudaMemGetInfo(&fr, &tot) == cudaSuccess && fr > 0) {
		while (thr > 4096 && thr * 160ULL > (uint64_t)(fr * 0.6)) thr >>= 1;   /* 32 B hash + 128 B Lyra2 matrix */
	}
	if (g_cfg.intensity > 0 && thr != (1ULL << n)) mlog("GPU %d: intensity %d does not fit in the GPU memory, %llu hashes per launch", gpu, n, (unsigned long long)thr);
	return (uint32_t)thr;
}

static bool l2_gpu_init(int gpu)
{
	CKR(cudaSetDevice(gpu));
	cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);   /* low CPU use; ignored if the context exists */
	cudaGetLastError();
	cudaDeviceProp prop;
	CKR(cudaGetDeviceProperties(&prop, gpu));
	if (prop.major < 5) { mlog("GPU %d: %s, compute %d.%d: lyra2v2 needs Maxwell (5.0) or later", gpu, prop.name, prop.major, prop.minor); return false; }
	const uint32_t thr = l2_pick_throughput(gpu, prop);
	CKR(l2_init(gpu, thr));
	double lg = log2((double)thr);
	mlog("GPU %d: %s, compute %d.%d, %d SM, %.1f GB, lyra2v2 %u hashes per launch (intensity %.1f)", gpu, prop.name, prop.major,
	     prop.minor, prop.multiProcessorCount, prop.totalGlobalMem / 1073741824.0, thr, lg);
	return true;
}

/* GPU self test: (1) the GPU finds the nonce of a real Bitmark block in a launch that contains it,
 * (2) every candidate of a launch with an easy target validates on the CPU */
static bool l2_gpu_selftest(int gpu)
{
	uint8_t hdr[80];
	unhex(L2_REF_HEADER, hdr, 80);
	const uint32_t nonce = (uint32_t)hdr[76] | ((uint32_t)hdr[77] << 8) | ((uint32_t)hdr[78] << 16) | ((uint32_t)hdr[79] << 24);
	const uint32_t ctr = bswap32(nonce);   /* GPU counter that puts this nonce in the header */
	uint8_t tgt[32];
	const uint32_t nbits = (uint32_t)hdr[72] | ((uint32_t)hdr[73] << 8) | ((uint32_t)hdr[74] << 16) | ((uint32_t)hdr[75] << 24);
	nbits_to_target(nbits, tgt);
	CKR(l2_set_job(gpu, hdr, tgt));
	const uint32_t thr = l2_throughput(gpu);
	const uint32_t start = ctr - (ctr % thr);
	uint32_t f[2];
	CKR(l2_scan(gpu, start, f));
	const bool found = f[0] == ctr || f[1] == ctr;
	/* easy target: about 1 hash in 4096 passes on the top 64 bits */
	uint8_t easy[32];
	memset(easy, 0xFF, 32);
	easy[31] = 0x00; easy[30] = 0x0F;
	for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)(i * 29 + 7 + gpu);
	CKR(l2_set_job(gpu, hdr, easy));
	int checked = 0, bad = 0;
	for (int k = 0; k < 4; k++) {
		CKR(l2_scan(gpu, 0x01000000u * (k + 1), f));
		for (int i = 0; i < 2; i++) {
			if (!f[i]) continue;
			uint8_t h2[80], dg[32];
			memcpy(h2, hdr, 80);
			const uint32_t hn = bswap32(f[i]);
			memcpy(h2 + 76, &hn, 4);
			mc_lyra2re2_hash((const char *)h2, (char *)dg);
			checked++;
			if (!le_hash_le_target(dg, easy)) bad++;
		}
	}
	const bool ok = found && checked > 0 && bad == 0;
	mlog("GPU %d: lyra2v2 self test: Bitmark block 2490869 nonce %s, %d candidates checked on the CPU, %d wrong -> %s", gpu,
	     found ? "found" : "NOT found", checked, bad, ok ? "OK" : "FAILED");
	return ok;
}

/* mines lyra2v2 on one GPU until quit (returns true) or a CUDA error (returns false, details logged) */
static bool l2_gpu_mine(int gpu, int slot)
{
	const bool bench = g_cfg.bench > 0;
	const uint32_t thr = l2_throughput(gpu);
	uint32_t en2ctr = 0;
	while (!g_quit) {
		work w;
		if (bench) {
			for (int i = 0; i < 80; i++) w.header[i] = (uint8_t)(rand() & 0xFF);
			memset(w.target, 0, 32);
			w.target64 = 0;
			w.height = 0;
		} else if (!pool_work(slot, en2ctr, w)) { sleep_ms(200); continue; }
		cudaError_t e = l2_set_job(gpu, w.header, w.target);
		if (e != cudaSuccess) { mlog("GPU %d: job upload failed: %s", gpu, cudaGetErrorString(e)); return false; }
		const auto t0 = std::chrono::steady_clock::now();
		uint64_t start = 0;
		while (!g_quit && start < (1ULL << 32)) {
			if (!bench) {
				if (g_gen.load() != w.gen) break;   /* new job, difficulty or connection */
			} else if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > g_cfg.refresh) break;
			uint32_t f[2];
			e = l2_scan(gpu, (uint32_t)start, f);
			if (e != cudaSuccess) {
				mlog("GPU %d: CUDA error %s (lyra2v2, %u hashes per launch, start %08llx, %.1f s on this work)", gpu,
				     cudaGetErrorString(e), thr, (unsigned long long)start,
				     std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
				return false;
			}
			g_stat[gpu].hashes += thr;
			start += thr;
			for (int i = 0; i < 2 && !bench; i++) {
				if (!f[i]) continue;
				uint8_t dg[32];
				const uint32_t nonce = bswap32(f[i]);   /* header nonce (little-endian), see lyra2v2_gpu.h */
				if (!cpu_check(w, nonce, dg)) {
					/* the GPU compares the top 64 bits only: a candidate can fail the full target */
					uint64_t top = 0;
					for (int k = 31; k >= 24; k--) top = (top << 8) | dg[k];
					if (top > w.target64) { g_cpu_bad++; mlog("GPU %d: nonce %08x does not validate on the CPU", gpu, nonce); }
					continue;
				}
				submit_share(gpu, w, nonce, dg);
			}
		}
	}
	return true;
}

static void l2_gpu_thread(int gpu, int slot)
{
	while (!g_quit) {
		if (!l2_gpu_init(gpu) || !l2_gpu_selftest(gpu)) { mlog("GPU %d: disabled", gpu); l2_free(gpu); break; }
		mlog("GPU %d: mining lyra2v2", gpu);
		g_stat[gpu].alive = true;
		const bool ok = l2_gpu_mine(gpu, slot);
		g_stat[gpu].alive = false;
		l2_free(gpu);
		if (ok) break;   /* quit */
		mlog("GPU %d: CUDA error, the miner exits to be restarted (last pool messages, unix s mod 1e5:%s)", gpu, ev_dump().c_str());
		g_cuda_fatal = true;
		g_quit = true;
		break;
	}
}

/* ------------------------------------------------------------------------------------------------
 * neoscrypt GPU part (gpu/neoscrypt: ccminer 2.3.1 / MYMINER kernels)
 * ---------------------------------------------------------------------------------------------- */
/* Feathercoin block 6428900 (09/11/2026): header (RPC getblockheader <hash> false), its block hash (sha256d) and its
 * proof-of-work hash (neoscrypt, reversed) */
static const char *NS_REF_HEADER =
	"04000020214711c16e990effbfe925821e70d2b2a6e3caf5f56f3eba9f6ee13574d9003c552dc38d8c9c66d568dd8efc9bbec3f5586fbd51"
	"a5d341d4c029595968b1a5dffb69f16a1ca8001d0665bbdc";
static const char *NS_REF_BLOCKHASH = "e5b05d8584e98b10d52fc3263956e79b224f4bb00bfe5aa86a0d3f9eb71f38a6";
static const char *NS_REF_POWHASH = "00000000798105eb9fa40b3fdd1c542f9097bf00d15d74e43c755e0c8510d3a9";

static uint32_t ns_pick_throughput(int gpu, const cudaDeviceProp &prop)
{
	int n = g_cfg.intensity;
	if (n <= 0) n = prop.multiProcessorCount <= 20 ? 16 : prop.multiProcessorCount <= 48 ? 17 : 18;
	if (n < 8) n = 8;
	if (n > 20) n = 20;
	uint64_t thr = 1ULL << n;
	size_t fr = 0, tot = 0;
	if (cudaMemGetInfo(&fr, &tot) == cudaSuccess && fr > 0) {
		while (thr > 1024 && thr * (uint64_t)NS_BYTES_PER_HASH > (uint64_t)(fr * 0.7)) thr >>= 1;
	}
	if (g_cfg.intensity > 0 && thr != (1ULL << n)) mlog("GPU %d: intensity %d does not fit in the GPU memory, %llu hashes per launch", gpu, n, (unsigned long long)thr);
	return (uint32_t)thr;
}

static bool ns_gpu_init(int gpu)
{
	CKR(cudaSetDevice(gpu));
	cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);   /* low CPU use; ignored if the context exists */
	cudaGetLastError();
	cudaDeviceProp prop;
	CKR(cudaGetDeviceProperties(&prop, gpu));
	if (prop.major < 5) { mlog("GPU %d: %s, compute %d.%d: neoscrypt needs Maxwell (5.0) or later", gpu, prop.name, prop.major, prop.minor); return false; }
	const uint32_t thr = ns_pick_throughput(gpu, prop);
	CKR(ns_init(gpu, thr));
	mlog("GPU %d: %s, compute %d.%d, %d SM, %.1f GB, neoscrypt %u hashes per launch (intensity %.1f, %.2f GB of buffers)", gpu,
	     prop.name, prop.major, prop.minor, prop.multiProcessorCount, prop.totalGlobalMem / 1073741824.0, thr, log2((double)thr),
	     (double)thr * NS_BYTES_PER_HASH / 1073741824.0);
	return true;
}

/* GPU self test: (1) the GPU finds the nonce of a real Feathercoin block in a launch that contains it,
 * (2) the candidates of launches with an easy target validate on the CPU */
static bool ns_gpu_selftest(int gpu)
{
	uint8_t hdr[80];
	unhex(NS_REF_HEADER, hdr, 80);
	const uint32_t nonce = (uint32_t)hdr[76] | ((uint32_t)hdr[77] << 8) | ((uint32_t)hdr[78] << 16) | ((uint32_t)hdr[79] << 24);
	uint8_t tgt[32];
	const uint32_t nbits = (uint32_t)hdr[72] | ((uint32_t)hdr[73] << 8) | ((uint32_t)hdr[74] << 16) | ((uint32_t)hdr[75] << 24);
	nbits_to_target(nbits, tgt);
	CKR(ns_set_job(gpu, hdr, tgt));
	const uint32_t thr = ns_throughput(gpu);
	const uint32_t start = nonce - (nonce % thr);
	uint32_t f = 0;
	bool hit = false;
	CKR(ns_scan(gpu, start, &f, &hit));
	const bool found = hit && f == nonce;
	/* easy target: about 1 hash in 4096 passes the top 32 bits; the GPU returns one of them per launch */
	uint8_t easy[32];
	memset(easy, 0xFF, 32);
	easy[31] = 0x00; easy[30] = 0x0F;
	for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)(i * 29 + 7 + gpu);
	CKR(ns_set_job(gpu, hdr, easy));
	int checked = 0, bad = 0;
	for (int k = 0; k < 4; k++) {
		CKR(ns_scan(gpu, 0x01000000u * (k + 1), &f, &hit));
		if (!hit) continue;
		uint8_t h2[80], dg[32];
		memcpy(h2, hdr, 80);
		memcpy(h2 + 76, &f, 4);
		neoscrypt(dg, h2, NEOSCRYPT_PROFILE);
		checked++;
		if (!le_hash_le_target(dg, easy)) bad++;
	}
	const bool ok = found && checked > 0 && bad == 0;
	mlog("GPU %d: neoscrypt self test: Feathercoin block 6428900 nonce %s, %d candidates checked on the CPU, %d wrong -> %s", gpu,
	     found ? "found" : "NOT found", checked, bad, ok ? "OK" : "FAILED");
	return ok;
}

/* mines neoscrypt on one GPU until quit (returns true) or a CUDA error (returns false, details logged) */
static bool ns_gpu_mine(int gpu, int slot)
{
	const bool bench = g_cfg.bench > 0;
	const uint32_t thr = ns_throughput(gpu);
	uint32_t en2ctr = 0;
	while (!g_quit) {
		work w;
		if (bench) {
			for (int i = 0; i < 80; i++) w.header[i] = (uint8_t)(rand() & 0xFF);
			memset(w.target, 0, 32);
			w.target64 = 0;
			w.height = 0;
		} else if (!pool_work(slot, en2ctr, w)) { sleep_ms(200); continue; }
		cudaError_t e = ns_set_job(gpu, w.header, w.target);
		if (e != cudaSuccess) { mlog("GPU %d: job upload failed: %s", gpu, cudaGetErrorString(e)); return false; }
		const auto t0 = std::chrono::steady_clock::now();
		uint64_t start = 0;
		while (!g_quit && start < (1ULL << 32)) {
			if (!bench) {
				if (g_gen.load() != w.gen) break;   /* new job, difficulty or connection */
			} else if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > g_cfg.refresh) break;
			uint32_t nonce = 0;
			bool hit = false;
			e = ns_scan(gpu, (uint32_t)start, &nonce, &hit);
			if (e != cudaSuccess) {
				mlog("GPU %d: CUDA error %s (neoscrypt, %u hashes per launch, start %08llx, %.1f s on this work)", gpu,
				     cudaGetErrorString(e), thr, (unsigned long long)start,
				     std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
				return false;
			}
			g_stat[gpu].hashes += thr;
			start += thr;
			if (!hit || bench) continue;
			uint8_t dg[32];
			if (!cpu_check(w, nonce, dg)) {
				/* the GPU compares the top 32 bits only: a candidate can fail the full target */
				uint32_t top = (uint32_t)dg[28] | ((uint32_t)dg[29] << 8) | ((uint32_t)dg[30] << 16) | ((uint32_t)dg[31] << 24);
				uint32_t t7 = (uint32_t)w.target[28] | ((uint32_t)w.target[29] << 8) | ((uint32_t)w.target[30] << 16) | ((uint32_t)w.target[31] << 24);
				if (top > t7) { g_cpu_bad++; mlog("GPU %d: nonce %08x does not validate on the CPU", gpu, nonce); }
				continue;
			}
			submit_share(gpu, w, nonce, dg);
		}
	}
	return true;
}

static void ns_gpu_thread(int gpu, int slot)
{
	while (!g_quit) {
		if (!ns_gpu_init(gpu) || !ns_gpu_selftest(gpu)) { mlog("GPU %d: disabled", gpu); ns_free(gpu); break; }
		mlog("GPU %d: mining neoscrypt", gpu);
		g_stat[gpu].alive = true;
		const bool ok = ns_gpu_mine(gpu, slot);
		g_stat[gpu].alive = false;
		ns_free(gpu);
		if (ok) break;   /* quit */
		mlog("GPU %d: CUDA error, the miner exits to be restarted (last pool messages, unix s mod 1e5:%s)", gpu, ev_dump().c_str());
		g_cuda_fatal = true;
		g_quit = true;
		break;
	}
}

static void gpu_thread(int gpu, int slot)
{
	if (g_cfg.algo == ALGO_LYRA2V2) { l2_gpu_thread(gpu, slot); return; }
	if (g_cfg.algo == ALGO_NEOSCRYPT) { ns_gpu_thread(gpu, slot); return; }
	int kv = -1;
	int resets = 0;
	auto window = std::chrono::steady_clock::now();
	while (!g_quit) {
		int grids[NKERNELS] = {0};
		if (!gpu_init(gpu, grids) || !gpu_selftest(gpu)) { mlog("GPU %d: disabled", gpu); break; }
		uint32_t *d_res = NULL;
		if (cudaMalloc(&d_res, sizeof(uint32_t) * (1 + MAX_RES)) != cudaSuccess) { mlog("GPU %d: cudaMalloc failed", gpu); break; }
		if (kv < 0) kv = gpu_pick_kernel(gpu, grids, d_res);
		bool ok = kv >= 0;
		if (ok) {
			mlog("GPU %d: mining with kernel %d (%s)", gpu, kv, g_kernels[kv].name);
			g_stat[gpu].alive = true;
			ok = gpu_mine(gpu, slot, kv, grids[kv], d_res);
			g_stat[gpu].alive = false;
		}
		cudaFree(d_res);
		if (ok) break;   /* quit */
		if (g_cfg.pool() || g_cfg.solo_exit_on_error) {
			/* an "illegal memory access" leaves the CUDA context unusable and cudaDeviceReset then reported the
			 * GPUs "busy or unavailable" (06/11/2026): stop the process so that the run loop starts it again */
			mlog("GPU %d: CUDA error, the miner exits to be restarted (last pool messages, unix s mod 1e5:%s)", gpu, ev_dump().c_str());
			g_cuda_fatal = true;
			g_quit = true;
			break;
		}
		/* CUDA error: reset this GPU only and start again (at most 10 resets per hour, then give up) */
		const auto now = std::chrono::steady_clock::now();
		if (std::chrono::duration<double>(now - window).count() > 3600) { window = now; resets = 0; }
		if (++resets > 10) { mlog("GPU %d: more than 10 CUDA errors in one hour, the GPU is left idle", gpu); break; }
		g_gpu_resets++;
		cudaDeviceReset();
		mlog("GPU %d: device reset, restart in 3 s (reset %d this hour)", gpu, resets);
		for (int i = 0; i < 30 && !g_quit; i++) sleep_ms(100);
	}
}

/* ------------------------------------------------------------------------------------------------
 * main
 * ---------------------------------------------------------------------------------------------- */
#ifdef _WIN32
static BOOL WINAPI on_ctrl(DWORD)
{
	g_quit = true;
	return TRUE;
}
#else
static void on_signal(int)
{
	g_quit = true;
}
#endif

static std::vector<int> parse_gpus(const char *s)
{
	std::vector<int> v;
	const char *p = s;
	while (*p) {
		v.push_back(atoi(p));
		while (*p && *p != ',') p++;
		if (*p == ',') p++;
	}
	return v;
}

/* CPU reference checks: genesis block hash and the id of a coinbase transaction of the chain */
static bool cpu_reference_ok()
{
	uint8_t hdr[80] = {0}, dg[32];
	static const char *mk = "1cf1e5211650ba5218b5b869c48c4bc480c4fd1bc849fdc1a81d68547b9f4d58";
	uint8_t m[32];
	unhex(mk, m, 32);
	hdr[0] = 1;
	for (int i = 0; i < 32; i++) hdr[36 + i] = m[31 - i];
	const uint32_t tme = 1491156549u, bits = 0x1e0ffff0u, nonce = 517725659u;
	memcpy(hdr + 68, &tme, 4); memcpy(hdr + 72, &bits, 4); memcpy(hdr + 76, &nonce, 4);
	gostd_ref(hdr, dg);
	const bool g1 = tohex(dg, 32) == "00000dd00df9728558f339d2e034e2c862329d509018b56d699aec5b6fa6ba1f";
	uint8_t dg2[32];
	gostd_any(hdr, 80, dg2);
	const bool g2 = memcmp(dg, dg2, 32) == 0;
	/* coinbase of block 1684066 (found by this miner, then named GostMiner, on 06/11/2026), txid 06d198af...7bc5fe81 */
	static const char *cbh =
		"01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0d0362b219012f062f50"
		"3253482fffffffff01286bee0000000000232102f6b156117d5d19a8ecde7f1905f93f67469311b0ec819c53e08a2ebbc1497df7ac"
		"00000000";
	std::vector<uint8_t> cb;
	unhexv(cbh, cb);
	uint8_t tx[32], disp[32];
	gostd_any(cb.data(), cb.size(), tx);
	for (int i = 0; i < 32; i++) disp[i] = tx[31 - i];
	const bool t1 = tohex(disp, 32) == "06d198af6bd336bfca64abd9bf1e0f8986ad5e02dd2bd30c3ffed3a17bc5fe81";
	/* merkle root of block 1684050 (2 transactions): gostd(txid0 || txid0), txid0 = e98eda59...4ba1f8b1 */
	uint8_t node[64], mr[32];
	unhex("e98eda594f61e0cd4f29da4409add223af1c2a45c3b14fd1b09d34c34ba1f8b1", disp, 32);
	for (int i = 0; i < 32; i++) node[i] = node[32 + i] = disp[31 - i];
	gostd_any(node, 64, mr);
	for (int i = 0; i < 32; i++) disp[i] = mr[31 - i];
	const bool m1 = tohex(disp, 32) == "5edd6f4645c947f3d6d0f58f81033bc1879fa3975cfd1bed6c488164eae9e3ec";
	mlog("CPU reference gostd: genesis block hash %s, coinbase txid %s, merkle root %s", (g1 && g2) ? "OK" : "WRONG",
	     t1 ? "OK" : "WRONG", m1 ? "OK" : "WRONG");
	/* lyra2v2 / Bitmark: SHA-256 test vector, block hash (sha256d) and powhash (lyra2rev2) of block 2490869,
	 * merkle root of its 2 transactions */
	uint8_t s[32], lh[80], ld[32], lr[32];
	gm_sha256((const uint8_t *)"abc", 3, s);
	const bool s1 = tohex(s, 32) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
	unhex(L2_REF_HEADER, lh, 80);
	gm_sha256d(lh, 80, ld);
	for (int i = 0; i < 32; i++) lr[i] = ld[31 - i];
	const bool b1 = tohex(lr, 32) == L2_REF_BLOCKHASH;
	mc_lyra2re2_hash((const char *)lh, (char *)ld);
	for (int i = 0; i < 32; i++) lr[i] = ld[31 - i];
	const bool p1 = tohex(lr, 32) == L2_REF_POWHASH;
	uint8_t t0[32], t1b[32], pr[64];
	unhex("6e85b44018e816ee52eadb2c6561adbce61d814551bfe505264a4fdd64aa22ed", lr, 32);
	for (int i = 0; i < 32; i++) t0[i] = lr[31 - i];
	unhex("d81e89d4c090d8ad5c86389ea40f730aaa60c39a5818d21ce074c3c65a485b79", lr, 32);
	for (int i = 0; i < 32; i++) t1b[i] = lr[31 - i];
	memcpy(pr, t0, 32); memcpy(pr + 32, t1b, 32);
	gm_sha256d(pr, 64, ld);
	for (int i = 0; i < 32; i++) lr[i] = ld[31 - i];
	const bool r1 = tohex(lr, 32) == "6e07b582c063b89f8d13b96c027cc1432d41d22a85a01c652e6cedf28b3dcb1c";
	mlog("CPU reference lyra2v2: sha256 %s, Bitmark block hash %s, powhash %s, merkle root %s", s1 ? "OK" : "WRONG",
	     b1 ? "OK" : "WRONG", p1 ? "OK" : "WRONG", r1 ? "OK" : "WRONG");
	/* neoscrypt / Feathercoin: block hash (sha256d) and proof-of-work hash (neoscrypt) of block 6428900 */
	uint8_t nh[80], nd[32], nr[32];
	unhex(NS_REF_HEADER, nh, 80);
	gm_sha256d(nh, 80, nd);
	for (int i = 0; i < 32; i++) nr[i] = nd[31 - i];
	const bool n1 = tohex(nr, 32) == NS_REF_BLOCKHASH;
	neoscrypt(nd, nh, NEOSCRYPT_PROFILE);
	for (int i = 0; i < 32; i++) nr[i] = nd[31 - i];
	const bool n2 = tohex(nr, 32) == NS_REF_POWHASH;
	mlog("CPU reference neoscrypt: Feathercoin block hash %s, proof-of-work hash %s", n1 ? "OK" : "WRONG", n2 ? "OK" : "WRONG");
	return g1 && g2 && t1 && m1 && s1 && b1 && p1 && r1 && n1 && n2;
}

static void usage()
{
	fprintf(stderr,
	        MINER_NAME " " GOSTMINER_VERSION " - GPU miner for NVIDIA, no dev fee\n"
	        "usage: crypto-connection-miner [--algo gostd|lyra2v2|neoscrypt] [--gpus 0,1] [--kernel N] [--intensity N]\n"
	        "                               [--stats S] [--log FILE] [--selftest] [--bench S]\n"
	        "  --algo : gostd (GOSTcoin, default), lyra2v2 (Bitmark) or neoscrypt (Feathercoin)\n"
	        "  solo : [--conf FILE] [--host IP] [--port N] [--refresh S]   (getwork on the local GOSTcoin wallet, gostd)\n"
	        "  pool : --pool HOST:PORT --user ADDRESS.WORKER [--pass X]      (stratum)\n"
	        "         --user alone: Crypto Connection pool, " DEFAULT_POOL_HOST " port 4033 (gostd) / 4043 (lyra2v2) / 4063 (neoscrypt)\n");
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&](void) -> const char * { return (i + 1 < argc) ? argv[++i] : ""; };
		if (a == "--algo" || a == "-a") {
			std::string v = next();
			for (auto &c : v) c = (char)tolower((unsigned char)c);
			if (v == "gostd" || v == "gost" || v == "gostcoin" || v == "gst") g_cfg.algo = ALGO_GOSTD;
			else if (v == "lyra2v2" || v == "lyra2rev2" || v == "lyra2re2" || v == "bitmark" || v == "marks") g_cfg.algo = ALGO_LYRA2V2;
			else if (v == "neoscrypt" || v == "feathercoin" || v == "ftc") g_cfg.algo = ALGO_NEOSCRYPT;
			else { fprintf(stderr, "unknown algorithm %s\n", v.c_str()); usage(); return 1; }
		}
		else if (a == "--intensity" || a == "-i") g_cfg.intensity = atoi(next());
		else if (a == "--gpus") g_cfg.gpus = parse_gpus(next());
		else if (a == "--conf") g_cfg.conf = next();
		else if (a == "--host") g_cfg.host = next();
		else if (a == "--port") g_cfg.port = atoi(next());
		else if (a == "--refresh") g_cfg.refresh = atoi(next());
		else if (a == "--stats") g_cfg.stats = atoi(next());
		else if (a == "--log") g_cfg.logfile = next();
		else if (a == "--selftest") g_cfg.selftest = true;
		else if (a == "--bench") g_cfg.bench = atoi(next());
		else if (a == "--kernel") g_cfg.kernel = atoi(next());
		else if (a == "--pool") {
			std::string hp = next();
			if (hp.compare(0, 14, "stratum+tcp://") == 0) hp = hp.substr(14);
			const size_t c2 = hp.rfind(':');
			if (c2 == std::string::npos) { usage(); return 1; }
			g_cfg.pool_host = hp.substr(0, c2);
			g_cfg.pool_port = atoi(hp.c_str() + c2 + 1);
		}
		else if (a == "--user") g_cfg.worker = next();
		else if (a == "--pass") g_cfg.worker_pass = next();
		else { usage(); return 1; }
	}
	/* --user without --pool and without --conf: the Crypto Connection pool */
	if (!g_cfg.pool() && g_cfg.conf.empty() && !g_cfg.worker.empty() && !g_cfg.bench && !g_cfg.selftest) {
		g_cfg.pool_host = DEFAULT_POOL_HOST;
		g_cfg.pool_port = g_cfg.algo == ALGO_LYRA2V2 ? DEFAULT_POOL_PORT_LYRA2V2 :
		                  g_cfg.algo == ALGO_NEOSCRYPT ? DEFAULT_POOL_PORT_NEOSCRYPT : DEFAULT_POOL_PORT_GOSTD;
	}
	if (g_cfg.pool() && (g_cfg.pool_port <= 0 || g_cfg.worker.empty())) { usage(); return 1; }
	if (!g_cfg.logfile.empty()) g_log = fopen(g_cfg.logfile.c_str(), "a");
	mlog("%s %s - GPU miner for NVIDIA (gostd: GOSTcoin, lyra2v2: Bitmark, neoscrypt: Feathercoin), no dev fee, algorithm %s, %s mode",
	     MINER_NAME, GOSTMINER_VERSION, algo_name(g_cfg.algo), g_cfg.bench ? "bench" : g_cfg.pool() ? "pool" : "solo");
	if (g_cfg.algo != ALGO_GOSTD && !g_cfg.pool() && !g_cfg.bench && !g_cfg.selftest) {
		mlog("%s: pool mode only (--pool HOST:PORT --user ADDRESS.WORKER)", algo_name(g_cfg.algo));
		return 1;
	}
#ifdef _WIN32
	SetConsoleCtrlHandler(on_ctrl, TRUE);
#else
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);
#endif

	if (!cpu_reference_ok()) return 2;

	int ndev = 0;
	if (cudaGetDeviceCount(&ndev) != cudaSuccess || ndev == 0) { mlog("no CUDA device"); return 2; }
	if (g_cfg.gpus.empty()) for (int i = 0; i < ndev; i++) g_cfg.gpus.push_back(i);

	if (g_cfg.selftest) {
		bool ok = true;
		for (int g : g_cfg.gpus) {
			if (g_cfg.algo == ALGO_LYRA2V2) { ok = l2_gpu_init(g) && l2_gpu_selftest(g) && ok; l2_free(g); }
			else if (g_cfg.algo == ALGO_NEOSCRYPT) { ok = ns_gpu_init(g) && ns_gpu_selftest(g) && ok; ns_free(g); }
			else { int grids[NKERNELS]; ok = gpu_init(g, grids) && gpu_selftest(g) && ok; }
		}
		mlog(ok ? "SELF TEST OK" : "SELF TEST FAILED");
		return ok ? 0 : 3;
	}

#ifdef _WIN32
	WSADATA wsa;
	WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
	std::thread wt;
	if (g_cfg.bench == 0 && g_cfg.pool()) {
		mlog("pool %s:%d, worker %s", g_cfg.pool_host.c_str(), g_cfg.pool_port, g_cfg.worker.c_str());
		wt = std::thread(stratum_thread);
	} else if (g_cfg.bench == 0) {
		if (!read_conf(g_cfg)) { mlog("rpcuser / rpcpassword not found in %s", g_cfg.conf.c_str()); return 2; }
		mlog("wallet RPC %s:%d (credentials from %s)", g_cfg.host.c_str(), g_cfg.port, g_cfg.conf.c_str());
		std::string r = rpc_call("getblockcount", "[]"), v;
		if (r.empty() || !json_get(r, "result", v)) { mlog("the wallet does not answer on %s:%d", g_cfg.host.c_str(), g_cfg.port); return 2; }
		g_blockcount = strtoull(v.c_str(), NULL, 10);
		mlog("wallet block count %llu", (unsigned long long)g_blockcount.load());
		wt = std::thread(watcher);
	}

	std::vector<std::thread> th;
	for (size_t k = 0; k < g_cfg.gpus.size(); k++) th.emplace_back(gpu_thread, g_cfg.gpus[k], (int)k);

	auto last = std::chrono::steady_clock::now();
	uint64_t prev[16] = {0};
	/* neoscrypt is about 1000 times slower per hash: speed shown in kH/s */
	const double unit = g_cfg.algo == ALGO_NEOSCRYPT ? 1e3 : 1e6;
	const char *uname = g_cfg.algo == ALGO_NEOSCRYPT ? "kH/s" : "MH/s";
	int idle_reports = 0;
	const auto t_start = last;
	while (!g_quit) {
		sleep_ms(1000);
		if (g_cfg.bench && std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count() > g_cfg.bench) g_quit = true;
		const auto now = std::chrono::steady_clock::now();
		const double dt = std::chrono::duration<double>(now - last).count();
		if (dt < g_cfg.stats && !g_quit) continue;
		std::string line;
		double total = 0;
		int alive = 0;
		for (int g : g_cfg.gpus) {
			const uint64_t h = g_stat[g].hashes.load();
			const double mhs = (h - prev[g]) / dt / unit;
			prev[g] = h;
			total += mhs;
			if (g_stat[g].alive) alive++;
			char b[48];
			snprintf(b, sizeof(b), " GPU%d %.2f", g, mhs);
			line += b;
		}
		if (g_cfg.pool()) {
			double diff;
			{ std::lock_guard<std::mutex> lk(g_sm); diff = g_diff; }
			mlog("%.2f %s (%s ) | shares sent %llu, accepted %llu, rejected %llu, cpu-invalid %llu | block candidates %llu | diff %.6g | pool %s | %d GPU running, %llu GPU resets",
			     total, uname, line.c_str(), (unsigned long long)g_submitted.load(), (unsigned long long)g_shares_ok.load(),
			     (unsigned long long)g_shares_bad.load(), (unsigned long long)g_cpu_bad.load(),
			     (unsigned long long)g_candidates.load(), diff, g_connected ? "connected" : "DISCONNECTED", alive,
			     (unsigned long long)g_gpu_resets.load());
		} else {
			mlog("%.2f %s (%s ) | blocks found %llu, accepted %llu, rejected %llu, cpu-invalid %llu | height %llu | %d GPU running, %llu GPU resets",
			     total, uname, line.c_str(), (unsigned long long)g_found.load(), (unsigned long long)g_accepted.load(),
			     (unsigned long long)g_rejected.load(), (unsigned long long)g_cpu_bad.load(),
			     (unsigned long long)g_blockcount.load(), alive, (unsigned long long)g_gpu_resets.load());
		}
		last = now;
		if (alive == 0 && !g_quit) {
			if (++idle_reports * g_cfg.stats >= 90) { mlog("no GPU mining for 90 s, exit"); g_quit = true; }
		} else idle_reports = 0;
	}
	if (g_cfg.pool()) {
		std::lock_guard<std::mutex> lk(g_send_mx);
		if (g_sock != INVALID_SOCKET) shutdown(g_sock, SD_BOTH);   /* unblocks recv in the stratum thread */
	}
	for (auto &t : th) t.join();
	if (wt.joinable()) wt.join();
	mlog(g_cuda_fatal ? MINER_NAME " stopped after a CUDA error (exit code 3: restart)" : MINER_NAME " stopped");
	if (g_log) fclose(g_log);
	return g_cuda_fatal ? 3 : 0;
}
