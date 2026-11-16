/*
 * ccm_cpu.cpp - Crypto Connection Miner 0.10.2, CPU edition: Chipcoin (CHC) on the CPU, no GPU, no CUDA, no dev fee.
 *   Built for the platforms that have no NVIDIA build: macOS on Apple Silicon (arm64, since 0.10.2) and any 64-bit
 *   Linux (x86-64 or arm64). Same command line as the NVIDIA build in CPU mode:
 *     crypto-connection-miner --algo chc --cpu --user YOUR_CHC_ADDRESS.worker [--threads N] [--cpu-path auto|...]
 *   The proof of work is src/chc_cpu.c (shared with the NVIDIA build): SHA-NI, AVX2 x8, ARMv8 SHA-256 (every Apple
 *   Silicon Mac) or portable C; every path the CPU supports must pass its self test (nonce of Chipcoin mainnet block
 *   11625, candidates of an easy target against the reference sha256d) and the fastest one is used.
 *   Stratum: the Bitcoin stratum v1 of the Crypto Connection pool (Miningcore, family chipcoin): subscribe ->
 *   [[...], extranonce1 (2 bytes), 2]; notify [job, previous hash (32-bit words byte-swapped), coinb1, coinb2,
 *   branches, version, bits, time, clean]; the coinbase is a Chipcoin transaction whose locktime holds extranonce1 ||
 *   extranonce2 (2 bytes: thread slot 4 bits + counter 12 bits); share target = diff1 / difficulty (Bitcoin diff1)
 *   compared with the double SHA-256 read big-endian; submit [worker, job, extranonce2, time, nonce].
 *   Every candidate of the scan (top 64 bits) is checked again with the full 256-bit target before it is sent.
 * The macOS port was started and first tested on an Apple M1 by the Chipcoin developer (16/11/2026, a Python
 *   wrapper around src/chc_cpu.c); this native edition follows the stratum client of gpu/gostminer.cu.
 * Build: macos/build_macos.sh (clang, arm64) or linux/build_cpu.sh (gcc / clang); nothing else than the C and C++
 *   standard libraries and POSIX threads and sockets.
 * Licence: GPL-3, as the rest of Crypto Connection Miner (see LICENSE).
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#include <sys/sysctl.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <math.h>
#include <time.h>
#include <ctype.h>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <chrono>
#include <set>
#include <algorithm>

#include "sha256.h"
#include "chc_cpu.h"

#define MINER_VERSION "0.10.2"
#define MINER_NAME "Crypto Connection Miner"
#define DEFAULT_POOL_HOST "crypto-connection.net"
#define DEFAULT_POOL_PORT_CHC 4093
#define MAX_THREADS 256

#if defined(MSG_NOSIGNAL)
#define SEND_FLAGS MSG_NOSIGNAL
#else
#define SEND_FLAGS 0
#endif

static void sleep_ms(unsigned ms) { usleep((useconds_t)ms * 1000); }

static const char *platform_name()
{
#if defined(__APPLE__) && defined(__aarch64__)
	return "macOS arm64";
#elif defined(__APPLE__)
	return "macOS x86-64";
#elif defined(__linux__) && defined(__aarch64__)
	return "Linux arm64";
#elif defined(__linux__) && defined(__x86_64__)
	return "Linux x86-64";
#else
	return "POSIX";
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
	localtime_r(&t, &lt);
	char ts[32];
	strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &lt);
	std::lock_guard<std::mutex> lk(g_log_mx);
	printf("[%s] %s\n", ts, msg);
	fflush(stdout);
	if (g_log) { fprintf(g_log, "[%s] %s\n", ts, msg); fflush(g_log); }
}

/* ------------------------------------------------------------------------------------------------
 * configuration
 * ---------------------------------------------------------------------------------------------- */
struct config {
	std::string logfile;
	int stats = 30;
	int refresh = 10;     /* bench: new random header every refresh seconds */
	bool selftest = false;
	int bench = 0;
	int threads = 0;      /* 0 = every hardware thread */
	int cpu_path = -1;    /* -1 = fastest measured, else CHC_CPU_SCALAR / AVX2 / SHANI / ARMSHA */
	std::string pool_host, worker, worker_pass = "x";
	int pool_port = 0;
	bool pool() const { return !pool_host.empty(); }
};

static config g_cfg;
static std::atomic<bool> g_quit(false);
static std::atomic<uint64_t> g_cpu_bad(0);

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

/* digest (big-endian hash) <= little-endian 256-bit target */
static bool digest_le_target(const uint8_t digest[32], const uint8_t target[32])
{
	for (int i = 0; i < 32; i++) {
		if (digest[i] < target[31 - i]) return true;
		if (digest[i] > target[31 - i]) return false;
	}
	return true;
}

/* a unit of work: header in consensus byte order (nonce 0), share and network targets */
struct work {
	uint8_t header[80];
	uint8_t target[32];       /* share target, little-endian uint256 (target[31] = most significant byte) */
	uint64_t target64;        /* digest bytes 0..7 (big-endian) must be <= this */
	uint8_t net_target[32];   /* little-endian, from nbits: share = block candidate */
	uint64_t gen;             /* stratum generation (new job / difficulty / connection) when built */
	std::string job_id, en2_hex, ntime_hex;
	double diff;
};

/* full check of a nonce against the 256-bit share target (Chipcoin: sha256d read big-endian) */
static bool cpu_check(const work &w, uint32_t nonce, uint8_t digest[32])
{
	uint8_t hdr[80];
	memcpy(hdr, w.header, 80);
	hdr[76] = (uint8_t)nonce; hdr[77] = (uint8_t)(nonce >> 8); hdr[78] = (uint8_t)(nonce >> 16); hdr[79] = (uint8_t)(nonce >> 24);
	gm_sha256d(hdr, 80, digest);
	return digest_le_target(digest, w.target);
}

/* ------------------------------------------------------------------------------------------------
 * minimal JSON parser + stratum v1 client
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
static int g_en2size = 2;
static std::atomic<uint64_t> g_gen(1);        /* bumped on each new job / difficulty / disconnection */
static std::atomic<bool> g_connected(false);
static std::atomic<uint64_t> g_shares_ok(0), g_shares_bad(0), g_candidates(0), g_submitted(0);
static int g_sock = -1;
static std::mutex g_send_mx;
static std::atomic<uint32_t> g_next_id(100);

static bool s_send(const std::string &line)
{
	std::lock_guard<std::mutex> lk(g_send_mx);
	if (g_sock < 0) return false;
	std::string l = line + "\n";
	size_t sent = 0;
	while (sent < l.size()) {
		ssize_t n = send(g_sock, l.data() + sent, l.size() - sent, SEND_FLAGS);
		if (n <= 0) return false;
		sent += (size_t)n;
	}
	return true;
}

static int s_connect(const std::string &host, int port)
{
	addrinfo hints, *res = NULL;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	char ps[16];
	snprintf(ps, sizeof(ps), "%d", port);
	if (getaddrinfo(host.c_str(), ps, &hints, &res) != 0 || !res) return -1;
	int s = -1;
	for (addrinfo *ai = res; ai; ai = ai->ai_next) {
		s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (s < 0) continue;
		if (connect(s, ai->ai_addr, ai->ai_addrlen) == 0) break;
		close(s);
		s = -1;
	}
	freeaddrinfo(res);
	if (s >= 0) {
		/* the pool sends a job at least every few seconds: 120 s without anything = connection lost */
		struct timeval r, w;
		r.tv_sec = 120; r.tv_usec = 0;
		w.tv_sec = 30; w.tv_usec = 0;
		setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&r, sizeof(r));
		setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&w, sizeof(w));
		int one = 1;
		setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof(one));
#if defined(SO_NOSIGPIPE)
		setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, (const char *)&one, sizeof(one));   /* macOS: no MSG_NOSIGNAL */
#endif
	}
	return s;
}

static uint32_t hex_u32(const std::string &h)
{
	return (uint32_t)strtoul(h.c_str(), NULL, 16);
}

static void s_handle(const std::string &line)
{
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
		}
	}
}

static void stratum_thread()
{
	int backoff = 5;
	while (!g_quit) {
		mlog("pool: connecting to %s:%d", g_cfg.pool_host.c_str(), g_cfg.pool_port);
		int s = s_connect(g_cfg.pool_host, g_cfg.pool_port);
		if (s < 0) {
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
		s_send("{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"CryptoConnectionMiner/" MINER_VERSION "\"]}");
		s_send("{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"" + jesc(g_cfg.worker) + "\",\"" + jesc(g_cfg.worker_pass) + "\"]}");
		std::string buf;
		char tmp[4096];
		while (!g_quit) {
			ssize_t n = recv(s, tmp, sizeof(tmp), 0);
			if (n <= 0) { if (!g_quit) mlog("pool: connection lost"); break; }
			buf.append(tmp, (size_t)n);
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
			close(g_sock);
			g_sock = -1;
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

/* builds a work unit for one thread: extranonce2 = (thread slot, counter), Bitcoin merkle root (sha256d) */
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
	/* 2-byte extranonce2 (Chipcoin pool): thread slot in the top 4 bits, counter in the low 12 */
	const uint64_t v = en2size == 2 ? (((uint64_t)(slot & 0xF) << 12) | (en2ctr++ & 0xFFF))
	                                : (((uint64_t)(slot & 0xFF) << 24) | (en2ctr++ & 0xFFFFFF));
	for (int i = 0; i < en2size && i < 8; i++) en2[en2size - 1 - i] = (uint8_t)(v >> (8 * i));
	std::vector<uint8_t> cb;
	cb.reserve(j.coinb1.size() + en1.size() + en2.size() + j.coinb2.size());
	cb.insert(cb.end(), j.coinb1.begin(), j.coinb1.end());
	cb.insert(cb.end(), en1.begin(), en1.end());
	cb.insert(cb.end(), en2.begin(), en2.end());
	cb.insert(cb.end(), j.coinb2.begin(), j.coinb2.end());
	uint8_t root[32];
	gm_sha256d(cb.data(), cb.size(), root);
	for (size_t k = 0; k < j.branches.size(); k++) {
		uint8_t pair[64];
		memcpy(pair, root, 32);
		memcpy(pair + 32, j.branches[k].data(), 32);
		gm_sha256d(pair, 64, root);
	}
	uint8_t *h = w.header;
	/* header fields little-endian (the byte order of Bitcoin headers) on any host */
	for (int k = 0; k < 4; k++) h[k] = (uint8_t)(j.version >> (8 * k));
	memcpy(h + 4, j.prev_le, 32);
	memcpy(h + 36, root, 32);
	for (int k = 0; k < 4; k++) h[68 + k] = (uint8_t)(j.ntime >> (8 * k));
	for (int k = 0; k < 4; k++) h[72 + k] = (uint8_t)(j.nbits >> (8 * k));
	memset(h + 76, 0, 4);
	diff_to_target(diff, w.target, w.target64);
	nbits_to_target(j.nbits, w.net_target);
	w.job_id = j.id;
	w.en2_hex = tohex(en2.data(), en2.size());
	w.ntime_hex = j.ntime_hex;
	w.diff = diff;
	return true;
}

static void submit_share(int t, const work &w, uint32_t nonce, const uint8_t digest[32])
{
	char nh[16];
	snprintf(nh, sizeof(nh), "%08x", nonce);
	const uint32_t id = ++g_next_id;
	if (digest_le_target(digest, w.net_target)) {
		g_candidates++;
		mlog("CPU thread %d: share is a BLOCK candidate, hash %s (job %s)", t, tohex(digest, 32).c_str(), w.job_id.c_str());
	}
	std::string msg = "{\"id\":" + std::to_string(id) + ",\"method\":\"mining.submit\",\"params\":[\"" + jesc(g_cfg.worker) +
	                  "\",\"" + jesc(w.job_id) + "\",\"" + w.en2_hex + "\",\"" + jesc(w.ntime_hex) + "\",\"" + nh + "\"]}";
	if (s_send(msg)) g_submitted++;
	else mlog("CPU thread %d: share not sent (pool disconnected)", t);
}

/* ------------------------------------------------------------------------------------------------
 * Chipcoin on the CPU (src/chc_cpu.c)
 * ---------------------------------------------------------------------------------------------- */
/* Chipcoin mainnet block 11625 (13/11/2026): its 80-byte header and its block hash */
static const char *CHC_REF_HEADER =
	"010000000000000000277c2d5963ea85b92474b725ee08bd8d8395968e65e4d678357cdd71cc151a7aede43c0e2cacc66a7cb9ca43934fdb"
	"26e57a2a3e1e47805024bfc39825f76a407e531b5d129956";
static const char *CHC_REF_HASH = "000000000007f447604c3215afac8d63926ef08b35f31d982bcb58a8075c8c13";

/* CPU reference checks: SHA-256 test vector and the sha256d of Chipcoin block 11625 = its block hash */
static bool cpu_reference_ok()
{
	uint8_t s[32];
	gm_sha256((const uint8_t *)"abc", 3, s);
	const bool s1 = tohex(s, 32) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
	uint8_t ch[80], cd[32];
	unhex(CHC_REF_HEADER, ch, 80);
	gm_sha256d(ch, 80, cd);
	const bool c1 = tohex(cd, 32) == CHC_REF_HASH;
	mlog("CPU reference: sha256 %s, Chipcoin block 11625 hash %s", s1 ? "OK" : "WRONG", c1 ? "OK" : "WRONG");
	return s1 && c1;
}

/* self test of one path: (1) it finds the nonce of Chipcoin block 11625 in a range that contains it (target = the
 * block's own hash), (2) every candidate of an easy target validates with gm_sha256d and none is missed */
static bool chc_cpu_selftest(int path)
{
	uint8_t hdr[80];
	unhex(CHC_REF_HEADER, hdr, 80);
	const uint32_t nonce = (uint32_t)hdr[76] | ((uint32_t)hdr[77] << 8) | ((uint32_t)hdr[78] << 16) | ((uint32_t)hdr[79] << 24);
	uint8_t ref[32];
	unhex(CHC_REF_HASH, ref, 32);
	uint64_t t64 = 0;
	for (int i = 0; i < 8; i++) t64 = (t64 << 8) | ref[i];
	chc_cpu_job job;
	chc_cpu_prepare(hdr, &job);
	uint32_t out[64];
	uint32_t n = chc_cpu_scan(path, &job, nonce - 1003, 2011, t64, out, 64);
	bool found = false;
	for (uint32_t i = 0; i < n; i++) if (out[i] == nonce) found = true;
	/* easy target: top 64 bits <= 2^56, about one hash in 256 */
	for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)(i * 37 + 11);
	chc_cpu_prepare(hdr, &job);
	const uint64_t easy = 1ULL << 56;
	const uint32_t first = 0x7FFFFF00u, count = 6007;
	std::vector<uint32_t> cand(count);
	n = chc_cpu_scan(path, &job, first, count, easy, cand.data(), count);
	int bad = 0, expected = 0;
	std::set<uint32_t> got(cand.begin(), cand.begin() + n);
	for (uint32_t k = 0; k < count; k++) {
		const uint32_t nn = first + k;
		uint8_t h2[80], dg[32];
		memcpy(h2, hdr, 80);
		h2[76] = (uint8_t)nn; h2[77] = (uint8_t)(nn >> 8); h2[78] = (uint8_t)(nn >> 16); h2[79] = (uint8_t)(nn >> 24);
		gm_sha256d(h2, 80, dg);
		uint64_t top = 0;
		for (int b = 0; b < 8; b++) top = (top << 8) | dg[b];
		const bool meets = top <= easy;
		if (meets) expected++;
		if (meets != (got.count(nn) > 0)) bad++;
	}
	const bool ok = found && expected > 0 && bad == 0 && (int)n == expected;
	mlog("CPU self test chc (%s): Chipcoin block 11625 nonce %s, %d easy candidates checked with the reference, %d wrong -> %s",
	     chc_cpu_path_name(path), found ? "found" : "NOT found", expected, bad, ok ? "OK" : "FAILED");
	return ok;
}

/* nonces per second of one thread on a path (about 0.2 s of measure) */
static double chc_cpu_speed(int path)
{
	uint8_t hdr[80];
	for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)(i * 13 + 5);
	chc_cpu_job job;
	chc_cpu_prepare(hdr, &job);
	uint32_t out[4];
	uint32_t first = 0;
	uint64_t done = 0;
	const auto t0 = std::chrono::steady_clock::now();
	double dt = 0;
	while (dt < 0.2) {
		chc_cpu_scan(path, &job, first, 65536, 0, out, 4);
		first += 65536;
		done += 65536;
		dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	}
	return done / dt;
}

/* mining threads run below normal priority, so the computer stays usable */
static void cpu_thread_priority_low()
{
#if defined(__APPLE__)
	pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);   /* macOS: still allowed on the performance cores */
#elif defined(__linux__)
	setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 10);   /* Linux: per thread */
#endif
}

struct thread_stat {
	std::atomic<uint64_t> hashes{0};
	std::atomic<bool> alive{false};
};
static thread_stat g_stat[MAX_THREADS];

/* one mining thread: thread t of n scans its own 1/n of the 2^32 nonces of each work unit (extranonce2 slot t mod 16,
 * own counter), so two threads never hash the same header and nonce */
static void chc_cpu_thread(int t, int n, int path)
{
	cpu_thread_priority_low();
	const bool bench = g_cfg.bench > 0;
	const uint64_t lo = ((uint64_t)t << 32) / (uint64_t)n, hi = ((uint64_t)(t + 1) << 32) / (uint64_t)n;
	uint32_t en2ctr = 0;
	uint32_t seed = 0x9E3779B9u * (uint32_t)(t + 1);
	g_stat[t].alive = true;
	while (!g_quit) {
		work w;
		if (bench) {
			for (int i = 0; i < 80; i++) { seed = seed * 1664525u + 1013904223u; w.header[i] = (uint8_t)(seed >> 24); }
			memset(w.target, 0, 32);
			w.target64 = 0;
			w.gen = 0;
		} else if (!pool_work(t & 0xF, en2ctr, w)) { sleep_ms(200); continue; }
		chc_cpu_job job;
		chc_cpu_prepare(w.header, &job);
		const auto t0 = std::chrono::steady_clock::now();
		uint64_t nonce = lo;
		while (!g_quit && nonce < hi) {
			if (!bench) {
				if (g_gen.load() != w.gen) break;   /* new job, difficulty or connection */
			} else if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > g_cfg.refresh) break;
			const uint32_t cnt = (uint32_t)std::min<uint64_t>(65536, hi - nonce);
			uint32_t res[16];
			const uint32_t found = chc_cpu_scan(path, &job, (uint32_t)nonce, cnt, w.target64, res, 16);
			g_stat[t].hashes += cnt;
			nonce += cnt;
			if (bench) continue;
			for (uint32_t i = 0; i < found; i++) {
				uint8_t dg[32];
				if (!cpu_check(w, res[i], dg)) {
					/* the scan compares the top 64 bits only: a candidate can fail the full target */
					uint64_t top = 0;
					for (int b = 0; b < 8; b++) top = (top << 8) | dg[b];
					if (top > w.target64) { g_cpu_bad++; mlog("CPU thread %d: nonce %08x does not validate", t, res[i]); }
					continue;
				}
				submit_share(t, w, res[i], dg);
			}
		}
	}
	g_stat[t].alive = false;
}

/* ------------------------------------------------------------------------------------------------
 * main
 * ---------------------------------------------------------------------------------------------- */
static void on_signal(int)
{
	g_quit = true;
}

/* hardware threads to use by default: on macOS the performance cores only when the Mac reports them (the
 * efficiency cores add little and slow down the rest of the Mac), elsewhere every hardware thread */
static int default_threads()
{
#if defined(__APPLE__)
	int perf = 0;
	size_t len = sizeof(perf);
	if (sysctlbyname("hw.perflevel0.logicalcpu", &perf, &len, NULL, 0) == 0 && perf > 0) return perf;
#endif
	const int n = (int)std::thread::hardware_concurrency();
	return n > 0 ? n : 1;
}

static void usage()
{
	fprintf(stderr,
	        MINER_NAME " " MINER_VERSION " (CPU edition, %s) - Chipcoin on the CPU, no dev fee\n"
	        "usage: crypto-connection-miner --algo chc --cpu --user ADDRESS.WORKER [--pool HOST:PORT] [--pass X]\n"
	        "                               [--threads N] [--cpu-path auto|shani|avx2|arm|c] [--stats S] [--log FILE]\n"
	        "                               [--selftest] [--bench S]\n"
	        "  --user alone: Crypto Connection pool, " DEFAULT_POOL_HOST " port 4093 (the user is your CHCQ... address)\n"
	        "  --pass d=0.1: fixed share difficulty 0.1 (the pool minimum), handy for slow CPUs\n"
	        "  --threads: the performance cores on Apple Silicon, every hardware thread elsewhere, by default\n"
	        "  --cpu-path: the fastest path that passes its self test, by default (arm = ARMv8 SHA-256, Apple Silicon)\n"
	        "  This edition mines Chipcoin (--algo chc) only: the other algorithms need the NVIDIA build.\n",
	        platform_name());
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&](void) -> const char * { return (i + 1 < argc) ? argv[++i] : ""; };
		if (a == "--algo" || a == "-a") {
			std::string v = next();
			for (auto &c : v) c = (char)tolower((unsigned char)c);
			if (v != "chc" && v != "chipcoin") {
				fprintf(stderr, "algorithm %s: this CPU edition mines Chipcoin only (--algo chc); use the NVIDIA build for %s\n", v.c_str(), v.c_str());
				return 1;
			}
		}
		else if (a == "--cpu") { /* always on the CPU */ }
		else if (a == "--threads" || a == "-t") {
			g_cfg.threads = atoi(next());
			if (g_cfg.threads < 1 || g_cfg.threads > MAX_THREADS) { fprintf(stderr, "--threads: 1 to %d\n", MAX_THREADS); return 1; }
		}
		else if (a == "--cpu-path") {
			std::string v = next();
			for (auto &c : v) c = (char)tolower((unsigned char)c);
			if (v == "auto") g_cfg.cpu_path = -1;
			else if (v == "shani" || v == "sha-ni" || v == "sha") g_cfg.cpu_path = CHC_CPU_SHANI;
			else if (v == "avx2") g_cfg.cpu_path = CHC_CPU_AVX2;
			else if (v == "arm" || v == "armsha" || v == "arm-sha" || v == "neon") g_cfg.cpu_path = CHC_CPU_ARMSHA;
			else if (v == "c" || v == "scalar" || v == "portable") g_cfg.cpu_path = CHC_CPU_SCALAR;
			else { fprintf(stderr, "--cpu-path: auto, shani, avx2, arm or c\n"); return 1; }
		}
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
		else if (a == "--stats") g_cfg.stats = atoi(next());
		else if (a == "--refresh") g_cfg.refresh = atoi(next());
		else if (a == "--log") g_cfg.logfile = next();
		else if (a == "--selftest") g_cfg.selftest = true;
		else if (a == "--bench") g_cfg.bench = atoi(next());
		else if (a == "--help" || a == "-h") { usage(); return 0; }
		else { usage(); return 1; }
	}
	if (g_cfg.stats < 1) g_cfg.stats = 30;
	if (g_cfg.refresh < 1) g_cfg.refresh = 10;
	/* --user without --pool: the Crypto Connection pool */
	if (!g_cfg.pool() && !g_cfg.worker.empty()) {
		g_cfg.pool_host = DEFAULT_POOL_HOST;
		g_cfg.pool_port = DEFAULT_POOL_PORT_CHC;
	}
	if (!g_cfg.bench && !g_cfg.selftest && (!g_cfg.pool() || g_cfg.pool_port <= 0 || g_cfg.worker.empty())) { usage(); return 1; }
	if (!g_cfg.logfile.empty()) g_log = fopen(g_cfg.logfile.c_str(), "a");
	mlog("%s %s (CPU edition, %s) - Chipcoin on the CPU, no dev fee, %s mode", MINER_NAME, MINER_VERSION, platform_name(),
	     g_cfg.bench ? "bench" : g_cfg.selftest ? "self test" : "pool");
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);

	if (!cpu_reference_ok()) return 2;

	/* every path this CPU can run is tested; the fastest (or the one asked) is used */
	int cpu_path = CHC_CPU_SCALAR;
	const int paths[4] = { CHC_CPU_SHANI, CHC_CPU_AVX2, CHC_CPU_ARMSHA, CHC_CPU_SCALAR };
	bool ok = true;
	double best = -1;
	for (int p : paths) {
		if (!chc_cpu_supported(p)) continue;
		if (!chc_cpu_selftest(p)) { ok = false; mlog("CPU path %s: self test FAILED, not used", chc_cpu_path_name(p)); continue; }
		if (g_cfg.cpu_path >= 0 && p != g_cfg.cpu_path) continue;
		const double sp = chc_cpu_speed(p);
		mlog("CPU path %s: %.2f MH/s per thread", chc_cpu_path_name(p), sp / 1e6);
		if (sp > best) { best = sp; cpu_path = p; }
	}
	if (g_cfg.selftest) { mlog(ok ? "SELF TEST OK" : "SELF TEST FAILED"); return ok ? 0 : 3; }
	if (best < 0) {
		if (g_cfg.cpu_path >= 0) mlog("CPU path %s unusable on this CPU (not supported or self test failed)", chc_cpu_path_name(g_cfg.cpu_path));
		else mlog("no usable CPU path, exit");
		return ok ? 2 : 3;
	}
	int nt = g_cfg.threads > 0 ? g_cfg.threads : default_threads();
	if (nt > MAX_THREADS) nt = MAX_THREADS;
	g_cfg.threads = nt;
	mlog("CPU mining: %d threads, path %s (about %.1f MH/s expected if every thread gets a core), low priority",
	     nt, chc_cpu_path_name(cpu_path), best * nt / 1e6);

	std::thread wt;
	if (g_cfg.bench == 0) {
		mlog("pool %s:%d, worker %s", g_cfg.pool_host.c_str(), g_cfg.pool_port, g_cfg.worker.c_str());
		wt = std::thread(stratum_thread);
	}
	std::vector<std::thread> th;
	for (int k = 0; k < nt; k++) th.emplace_back(chc_cpu_thread, k, nt, cpu_path);

	auto last = std::chrono::steady_clock::now();
	std::vector<uint64_t> prev(MAX_THREADS, 0);
	const auto t_start = last;
	double bench_total = 0;
	while (!g_quit) {
		sleep_ms(1000);
		if (g_cfg.bench && std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count() > g_cfg.bench) g_quit = true;
		const auto now = std::chrono::steady_clock::now();
		const double dt = std::chrono::duration<double>(now - last).count();
		if (dt < g_cfg.stats && !g_quit) continue;
		double total = 0;
		int alive = 0;
		for (int k = 0; k < nt; k++) {
			const uint64_t h = g_stat[k].hashes.load();
			total += (h - prev[k]) / dt / 1e6;
			prev[k] = h;
			if (g_stat[k].alive) alive++;
		}
		if (g_cfg.bench) {
			bench_total = total;
			mlog("%.2f MH/s (CPU %d threads, path %s)", total, nt, chc_cpu_path_name(cpu_path));
		} else {
			double diff;
			{ std::lock_guard<std::mutex> lk(g_sm); diff = g_diff; }
			mlog("%.2f MH/s (CPU %d threads) | shares sent %llu, accepted %llu, rejected %llu, cpu-invalid %llu | block candidates %llu | diff %.6g | pool %s",
			     total, alive, (unsigned long long)g_submitted.load(), (unsigned long long)g_shares_ok.load(),
			     (unsigned long long)g_shares_bad.load(), (unsigned long long)g_cpu_bad.load(),
			     (unsigned long long)g_candidates.load(), diff, g_connected ? "connected" : "DISCONNECTED");
		}
		last = now;
	}
	{
		std::lock_guard<std::mutex> lk(g_send_mx);
		if (g_sock >= 0) shutdown(g_sock, SHUT_RDWR);   /* unblocks recv in the stratum thread */
	}
	for (auto &t : th) t.join();
	if (wt.joinable()) wt.join();
	if (g_cfg.bench) mlog("bench: %.2f MH/s on %d threads (path %s)", bench_total, nt, chc_cpu_path_name(cpu_path));
	mlog(MINER_NAME " stopped");
	if (g_log) fclose(g_log);
	return 0;
}
