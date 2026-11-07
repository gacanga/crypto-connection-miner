/**
 * MYMINER - runtime switches for the Phase 2 kernels.
 *
 * Every optimised kernel is compiled next to the original one, so one binary can be A/B tested
 * (scripts\bench.ps1 -Env MYMINER_DISABLE=...) and an optimisation can be switched off on a rig
 * without rebuilding.
 *
 * Environment variable MYMINER_DISABLE: comma separated list, case insensitive, among
 *   echo     ECHO-512 with lane-replicated AES table        (x11..x17, x16r/x16s, c11, phi, tribus...)
 *   shavite  SHAvite-512 with lane-replicated AES table     (x11..x17, x16r/x16s, c11, sib...)
 *   fugue    Fugue-512 with lane-replicated SMIX table      (x13..x17, x16r/x16s, hmq1725, sonoa...)
 *   hamsi    Hamsi-512 with unrolled message expansion      (x13..x17, x16r/x16s, hmq1725, sonoa...)
 *            OFF by default: the original is faster on the P104 (x13 +2.7 %, x17 +1.4 %); MYMINER_ENABLE=hamsi
 *   whirlpool Whirlpool-512 (64-byte input) with lane-replicated table (x15, x17, x16r/x16s, hmq1725, sonoa...)
 *   groestl256 Groestl-256 with lane-replicated table (allium)
 *   blake512 Blake-512 (64-byte input) with precomputed rounds on Pascal (quark, x11..x17, x16r, jha, timetravel...)
 *            OFF by default: measured on the P104 at -0.1 to -0.9 % (168 registers); MYMINER_ENABLE=blake512 turns it on
 *   lyra2v2  Lyra2 v2 wandering kernel, compile-time block dims + unrolled loops (lyra2v2, lyra2v3 not)
 *   all      all of the above
 * Example (cmd.exe):  set MYMINER_DISABLE=echo,fugue
 * MYMINER_ENABLE (same syntax) turns on an optimisation that is off by default (blake512, hamsi).
 *
 * The Lyra2 matrix placement is a compile-time value (CMake MYMINER_LYRA2_BUF / MYMINER_LYRA2Z_BUF).
 */
#pragma once

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

struct myminer_opts_t {
	bool echo_repl;
	bool shavite_repl;
	bool fugue_repl;
	bool hamsi_unroll;
	bool lyra2v2_fast;
	bool whirlpool_repl;
	bool groestl256_repl;
	bool blake512_unroll;
};

/* true if "name" is one of the comma / semicolon / space separated tokens of "list" */
inline bool myminer_opts_has(const char *list, const char *name)
{
	const size_t n = strlen(name);
	const char *p = list;
	while (*p) {
		while (*p == ',' || *p == ';' || *p == ' ') p++;
		const char *start = p;
		while (*p && *p != ',' && *p != ';' && *p != ' ') p++;
		const size_t len = (size_t)(p - start);
		if (len == n) {
			size_t i = 0;
			while (i < n && tolower((unsigned char)start[i]) == name[i]) i++;
			if (i == n) return true;
		}
	}
	return false;
}

inline myminer_opts_t myminer_opts_parse()
{
	myminer_opts_t o;
	o.echo_repl = true;
	o.shavite_repl = true;
	o.fugue_repl = true;
	o.hamsi_unroll = false; /* measured slower on the P104, see above */
	o.lyra2v2_fast = true;
	o.whirlpool_repl = true;
	o.groestl256_repl = true;
	o.blake512_unroll = false; /* measured slower on the P104, see above */

	const char *en = getenv("MYMINER_ENABLE");
	if (en && *en) {
		if (myminer_opts_has(en, "blake512")) o.blake512_unroll = true;
		if (myminer_opts_has(en, "hamsi")) o.hamsi_unroll = true;
		fprintf(stderr, "MYMINER: MYMINER_ENABLE=%s -> blake512:%s hamsi:%s\n", en,
			o.blake512_unroll ? "new" : "original", o.hamsi_unroll ? "new" : "original");
	}

	const char *env = getenv("MYMINER_DISABLE");
	if (env && *env) {
		const bool all = myminer_opts_has(env, "all");
		if (all || myminer_opts_has(env, "echo")) o.echo_repl = false;
		if (all || myminer_opts_has(env, "shavite")) o.shavite_repl = false;
		if (all || myminer_opts_has(env, "fugue")) o.fugue_repl = false;
		if (all || myminer_opts_has(env, "hamsi")) o.hamsi_unroll = false;
		if (all || myminer_opts_has(env, "lyra2v2")) o.lyra2v2_fast = false;
		if (all || myminer_opts_has(env, "whirlpool")) o.whirlpool_repl = false;
		if (all || myminer_opts_has(env, "groestl256")) o.groestl256_repl = false;
		if (all || myminer_opts_has(env, "blake512")) o.blake512_unroll = false;
		fprintf(stderr, "MYMINER: MYMINER_DISABLE=%s -> echo:%s shavite:%s fugue:%s hamsi:%s lyra2v2:%s whirlpool:%s groestl256:%s blake512:%s\n", env,
			o.echo_repl ? "new" : "original", o.shavite_repl ? "new" : "original",
			o.fugue_repl ? "new" : "original", o.hamsi_unroll ? "new" : "original",
			o.lyra2v2_fast ? "new" : "original", o.whirlpool_repl ? "new" : "original",
			o.groestl256_repl ? "new" : "original", o.blake512_unroll ? "new" : "original");
	}
	return o;
}

/* parsed once per process (thread-safe initialisation of a function-local static, C++11) */
inline const myminer_opts_t &myminer_opts()
{
	static const myminer_opts_t o = myminer_opts_parse();
	return o;
}
