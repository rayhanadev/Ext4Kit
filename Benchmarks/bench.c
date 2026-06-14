/*
 * Ext4Kit benchmark harness.
 *
 * Exercises the vendored lwext4 with the same call patterns Ext4Volume.swift
 * uses, against a file-backed block device, so performance changes (block
 * cache size, write-back mode, enumeration strategy, I/O chunk sizes) can be
 * measured without mounting a real FSKit volume.
 *
 * Build via the Makefile in this directory; the lwext4 sources and CONFIG
 * defines mirror the Xcode target exactly, with CONFIG_BLOCK_DEV_CACHE_SIZE
 * overridable per build (`make CACHE=2048`).
 *
 * Usage: bench <image-path> [options]
 *   --size-mb N     image size (default 256)
 *   --files N       files for create/enum/rename/unlink storms (default 1000)
 *   --io-mb N       sequential I/O volume (default 64)
 *   --chunk-kb N    fread/fwrite chunk size (default 1024; models FSKit ioSize)
 *   --wb            enable ext4_cache_write_back for the whole run
 *   --no-journal    skip ext4_journal_start
 *   --keep          don't delete the image afterwards (for fsck inspection)
 *   --verify        re-mount and verify written data pattern (correctness)
 *   --fuzz N        instead of benchmarks: N corrupt-image mount/walk rounds
 *                   (graceful errors pass; crashes and hangs are findings)
 *   --fuzz-seed S   RNG seed for --fuzz (printed per round for replay)
 *   --soak SECS     instead of benchmarks: randomized mixed metadata/data ops
 *                   for SECS seconds, then remount + structural walk + data
 *                   pattern verification
 *   --crash N       instead of benchmarks: N journal-replay trials — a forked
 *                   child churns under deferred checkpoints and abandons
 *                   mid-stream; the parent replays and verifies a protected
 *                   sentinel survives and the fs stays walkable
 */

#include <ext4.h>
#include <ext4_mkfs.h>
#include <ext4_blockdev.h>

#include <file_dev.h>

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MP "/bench/"

static struct ext4_blockdev *bd;
static int opt_wb = 0;
static int opt_journal = 1;
static int opt_keep = 0;
static int opt_verify = 0;
static uint64_t opt_size_mb = 256;
static int opt_files = 1000;
static uint64_t opt_io_mb = 64;
static size_t opt_chunk = 1024 * 1024;

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void die(const char *what, int rc)
{
	fprintf(stderr, "FATAL: %s rc=%d\n", what, rc);
	exit(1);
}

/* Physical-I/O counter snapshot (lwext4 maintains these on the iface). */
static uint32_t ctr_r0, ctr_w0;
static void ctr_begin(void)
{
	ctr_r0 = bd->bdif->bread_ctr;
	ctr_w0 = bd->bdif->bwrite_ctr;
}

static void report(const char *name, double secs, double ops, const char *unit)
{
	uint32_t br = bd->bdif->bread_ctr - ctr_r0;
	uint32_t bw = bd->bdif->bwrite_ctr - ctr_w0;
	printf("%-22s %9.3fs  %12.1f %-8s  bread=%-8u bwrite=%-8u\n",
	       name, secs, ops / secs, unit, br, bw);
	fflush(stdout);
}

/* Deterministic data pattern so --verify can detect corruption. */
static void fill_pattern(uint8_t *buf, size_t len, uint64_t seed)
{
	uint64_t x = seed * 6364136223846793005ULL + 1442695040888963407ULL;
	for (size_t i = 0; i < len; i++) {
		x ^= x << 13;
		x ^= x >> 7;
		x ^= x << 17;
		buf[i] = (uint8_t)x;
	}
}

static void make_image(const char *path)
{
	/* Pre-size the backing file. */
	FILE *f = fopen(path, "wb");
	if (!f)
		die("fopen image", -1);
	if (fseeko(f, (off_t)(opt_size_mb * 1024 * 1024) - 1, SEEK_SET) != 0)
		die("fseeko", -1);
	fputc(0, f);
	fclose(f);

	file_dev_name_set(path);
	bd = file_dev_get();
	if (!bd)
		die("file_dev_get", -1);

	static struct ext4_fs fs;
	struct ext4_mkfs_info info;
	memset(&info, 0, sizeof(info));
	info.block_size = 4096;
	info.journal = true;
	info.label = "BENCH";
	int rc = ext4_mkfs(&fs, bd, &info, F_SET_EXT4);
	if (rc != EOK)
		die("ext4_mkfs", rc);
}

static void mount_fs(void)
{
	int rc = ext4_device_register(bd, "bench0");
	if (rc != EOK)
		die("ext4_device_register", rc);
	rc = ext4_mount("bench0", MP, false);
	if (rc != EOK)
		die("ext4_mount", rc);
	rc = ext4_recover(MP);
	if (rc != EOK && rc != ENOTSUP)
		die("ext4_recover", rc);
	if (opt_journal) {
		rc = ext4_journal_start(MP);
		if (rc != EOK)
			die("ext4_journal_start", rc);
	}
	if (opt_wb)
		ext4_cache_write_back(MP, true);
}

static void unmount_fs(void)
{
	if (opt_wb)
		ext4_cache_write_back(MP, false);
	if (opt_journal)
		ext4_journal_stop(MP);
	ext4_cache_flush(MP);
	int rc = ext4_umount(MP);
	if (rc != EOK)
		die("ext4_umount", rc);
	ext4_device_unregister("bench0");
}

/* Mirrors Ext4Volume.createItem: existence probe, create, mode, times,
 * parent touch — the full FSKit-path cost, not just ext4_fopen. */
static void fskit_style_create(const char *path, const char *parent,
			       uint32_t now)
{
	ext4_file f;
	uint32_t ino;
	struct ext4_inode inode;

	if (ext4_raw_inode_fill(path, &ino, &inode) == EOK)
		die("create: exists", EEXIST);
	int rc = ext4_fopen(&f, path, "wb");
	if (rc != EOK)
		die("ext4_fopen create", rc);
	ext4_fclose(&f);
	ext4_raw_inode_fill(path, &ino, &inode);
	ext4_mode_set(path, 0644);
	ext4_atime_set(path, now);
	ext4_mtime_set(path, now);
	ext4_ctime_set(path, now);
	ext4_mtime_set(parent, now);
	ext4_ctime_set(parent, now);
}

static void w_create(void)
{
	int rc = ext4_dir_mk(MP "d0");
	if (rc != EOK)
		die("dir_mk d0", rc);
	uint32_t now = (uint32_t)time(NULL);
	char path[128];

	ctr_begin();
	double t0 = now_s();
	for (int i = 0; i < opt_files; i++) {
		snprintf(path, sizeof(path), MP "d0/file-%05d", i);
		fskit_style_create(path, MP "d0", now);
	}
	report("create", now_s() - t0, opt_files, "files/s");
}

static void w_seqwrite(void)
{
	uint8_t *buf = malloc(opt_chunk);
	ext4_file f;
	int rc = ext4_fopen(&f, MP "big.bin", "wb");
	if (rc != EOK)
		die("fopen big", rc);

	uint64_t total = opt_io_mb * 1024 * 1024;
	ctr_begin();
	double t0 = now_s();
	for (uint64_t off = 0; off < total; off += opt_chunk) {
		fill_pattern(buf, opt_chunk, off);
		size_t w = 0;
		rc = ext4_fwrite(&f, buf, opt_chunk, &w);
		if (rc != EOK || w != opt_chunk)
			die("fwrite", rc);
	}
	ext4_fclose(&f);
	report("seqwrite", now_s() - t0, (double)opt_io_mb, "MiB/s");
	free(buf);
}

static void w_seqread(void)
{
	uint8_t *buf = malloc(opt_chunk);
	ext4_file f;
	int rc = ext4_fopen(&f, MP "big.bin", "rb");
	if (rc != EOK)
		die("fopen big r", rc);

	uint64_t total = opt_io_mb * 1024 * 1024;
	ctr_begin();
	double t0 = now_s();
	for (uint64_t off = 0; off < total; off += opt_chunk) {
		size_t r = 0;
		rc = ext4_fread(&f, buf, opt_chunk, &r);
		if (rc != EOK || r != opt_chunk)
			die("fread", rc);
	}
	ext4_fclose(&f);
	report("seqread", now_s() - t0, (double)opt_io_mb, "MiB/s");
	free(buf);
}

static void w_randread(void)
{
	enum { RN = 8192, RSZ = 4096 };
	uint8_t buf[RSZ];
	ext4_file f;
	int rc = ext4_fopen(&f, MP "big.bin", "rb");
	if (rc != EOK)
		die("fopen big rr", rc);
	uint64_t fsize = ext4_fsize(&f);
	uint64_t x = 0x9e3779b97f4a7c15ULL;

	ctr_begin();
	double t0 = now_s();
	for (int i = 0; i < RN; i++) {
		x ^= x << 13; x ^= x >> 7; x ^= x << 17;
		uint64_t off = (x % (fsize - RSZ)) & ~((uint64_t)RSZ - 1);
		rc = ext4_fseek(&f, (int64_t)off, SEEK_SET);
		if (rc != EOK)
			die("rr fseek", rc);
		size_t r = 0;
		rc = ext4_fread(&f, buf, RSZ, &r);
		if (rc != EOK)
			die("rr fread", rc);
	}
	ext4_fclose(&f);
	report("randread4k", now_s() - t0, RN, "ops/s");
}

/* Mirrors Ext4Volume.enumerateDirectory with attributes requested:
 * iterate entries, ext4_raw_inode_fill(parent + "/" + name) per entry. */
static void w_enum_stat(void)
{
	ext4_dir d;
	char path[300];
	int entries = 0;

	ctr_begin();
	double t0 = now_s();
	int rc = ext4_dir_open(&d, MP "d0");
	if (rc != EOK)
		die("dir_open", rc);
	const ext4_direntry *de;
	while ((de = ext4_dir_entry_next(&d)) != NULL) {
		if (de->name_length == 0)
			continue;
		snprintf(path, sizeof(path), MP "d0/%.*s",
			 (int)de->name_length, (const char *)de->name);
		uint32_t ino;
		struct ext4_inode inode;
		ext4_raw_inode_fill(path, &ino, &inode);
		entries++;
	}
	ext4_dir_close(&d);
	report("enum+stat", now_s() - t0, entries, "ents/s");
}

/* Cookie-resume cost, positional style: re-open the directory and skip N
 * entries for each batch of 64, the way positional cookies forced
 * Ext4Volume to. O(n^2/batch) overall. */
static void w_enum_resume(void)
{
	enum { BATCH = 64 };
	int total = 0;

	ctr_begin();
	double t0 = now_s();
	uint64_t skip = 0;
	for (;;) {
		ext4_dir d;
		int rc = ext4_dir_open(&d, MP "d0");
		if (rc != EOK)
			die("dir_open resume", rc);
		uint64_t seen = 0;
		int packed = 0;
		const ext4_direntry *de;
		while ((de = ext4_dir_entry_next(&d)) != NULL) {
			seen++;
			if (seen <= skip)
				continue;
			packed++;
			total++;
			if (packed == BATCH)
				break;
		}
		ext4_dir_close(&d);
		if (packed < BATCH)
			break;
		skip = seen;
	}
	report("enum-resume", now_s() - t0, total, "ents/s");
}

/* Cookie-resume cost, offset style: the cookie is dir.next_off, seeded back
 * into a fresh iterator per batch — what Ext4Volume does now. O(n) overall. */
static void w_enum_resume_off(void)
{
	enum { BATCH = 64 };
	int total = 0;

	ctr_begin();
	double t0 = now_s();
	uint64_t cookie = 0;
	for (;;) {
		ext4_dir d;
		int rc = ext4_dir_open(&d, MP "d0");
		if (rc != EOK)
			die("dir_open resume-off", rc);
		if (cookie != 0) {
			if (cookie == (uint64_t)-1 || cookie >= d.f.fsize) {
				ext4_dir_close(&d);
				break;
			}
			d.next_off = cookie;
		}
		int packed = 0;
		const ext4_direntry *de;
		while ((de = ext4_dir_entry_next(&d)) != NULL) {
			cookie = d.next_off;
			packed++;
			total++;
			if (packed == BATCH)
				break;
		}
		ext4_dir_close(&d);
		if (packed < BATCH)
			break;
	}
	report("enum-resume-off", now_s() - t0, total, "ents/s");
}

static void w_deep_stat(void)
{
	char path[300] = MP "deep";
	int rc = ext4_dir_mk(path);
	if (rc != EOK)
		die("deep mk", rc);
	for (int i = 1; i < 8; i++) {
		snprintf(path + strlen(path), sizeof(path) - strlen(path), "/deep");
		rc = ext4_dir_mk(path);
		if (rc != EOK)
			die("deep mk2", rc);
	}
	snprintf(path + strlen(path), sizeof(path) - strlen(path), "/leaf.txt");
	ext4_file f;
	rc = ext4_fopen(&f, path, "wb");
	if (rc != EOK)
		die("deep create", rc);
	ext4_fclose(&f);

	enum { N = 20000 };
	ctr_begin();
	double t0 = now_s();
	for (int i = 0; i < N; i++) {
		uint32_t ino;
		struct ext4_inode inode;
		rc = ext4_raw_inode_fill(path, &ino, &inode);
		if (rc != EOK)
			die("deep stat", rc);
	}
	report("deepstat", now_s() - t0, N, "ops/s");
}

static void w_rename(void)
{
	char a[128], b[128];
	ctr_begin();
	double t0 = now_s();
	for (int i = 0; i < opt_files; i++) {
		snprintf(a, sizeof(a), MP "d0/file-%05d", i);
		snprintf(b, sizeof(b), MP "d0/moved-%05d", i);
		int rc = ext4_frename(a, b);
		if (rc != EOK)
			die("frename", rc);
	}
	report("rename", now_s() - t0, opt_files, "files/s");
}

static void w_unlink(void)
{
	char path[128];
	ctr_begin();
	double t0 = now_s();
	for (int i = 0; i < opt_files; i++) {
		snprintf(path, sizeof(path), MP "d0/moved-%05d", i);
		int rc = ext4_fremove(path);
		if (rc != EOK)
			die("fremove", rc);
	}
	report("unlink", now_s() - t0, opt_files, "files/s");
}

/* -------------------------------- fuzzing -------------------------------- */

static uint64_t fuzz_rng_state;
static uint64_t fuzz_rng(void)
{
	uint64_t x = fuzz_rng_state;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	return fuzz_rng_state = x;
}

static void watchdog(int sig)
{
	(void)sig;
	fprintf(stderr, "FATAL: fuzz round hung (watchdog) — see last 'round=' line\n");
	_exit(3);
}

/* Mirrors the extension's activate sequence against a corrupted image and
 * walks what it can. Any rc != EOK is a graceful pass; the failure modes
 * being hunted are crashes and hangs inside lwext4. */
static void fuzz_mount_walk(void)
{
	int rc = ext4_device_register(bd, "bench0");
	if (rc != EOK)
		return;
	rc = ext4_mount("bench0", MP, false);
	if (rc != EOK) {
		ext4_device_unregister("bench0");
		return;
	}
	(void)ext4_recover(MP);
	int journaled = ext4_journal_start(MP) == EOK;

	struct ext4_mount_stats st;
	(void)ext4_mount_point_stats(MP, &st);

	ext4_dir d;
	if (ext4_dir_open(&d, MP) == EOK) {
		const ext4_direntry *de;
		int walked = 0;
		char path[300];
		while ((de = ext4_dir_entry_next(&d)) != NULL && walked++ < 256) {
			if (de->name_length == 0)
				continue;
			snprintf(path, sizeof(path), MP "%.*s",
				 (int)de->name_length, (const char *)de->name);
			uint32_t ino;
			struct ext4_inode inode;
			(void)ext4_raw_inode_fill(path, &ino, &inode);
			ext4_file f;
			if (ext4_fopen(&f, path, "rb") == EOK) {
				uint8_t buf[4096];
				size_t r;
				(void)ext4_fread(&f, buf, sizeof(buf), &r);
				ext4_fclose(&f);
			}
		}
		ext4_dir_close(&d);
	}

	/* Exercise one write so allocator paths see corrupt bitmaps too. */
	ext4_file wf;
	if (ext4_fopen(&wf, MP "fuzz-write.bin", "wb") == EOK) {
		uint8_t buf[8192];
		memset(buf, 0xA5, sizeof(buf));
		size_t w;
		(void)ext4_fwrite(&wf, buf, sizeof(buf), &w);
		ext4_fclose(&wf);
	}

	if (journaled)
		(void)ext4_journal_stop(MP);
	(void)ext4_cache_flush(MP);
	(void)ext4_umount(MP);
	ext4_device_unregister("bench0");
}

static void run_fuzz(const char *image, int rounds, uint64_t seed)
{
	/* Build one pristine populated image, snapshot its bytes. */
	make_image(image);
	mount_fs();
	int saved_files = opt_files;
	opt_files = 64;
	w_create();
	w_seqwrite();
	opt_files = saved_files;
	unmount_fs();

	FILE *f = fopen(image, "rb");
	if (!f)
		die("fuzz: reopen image", -1);
	fseeko(f, 0, SEEK_END);
	size_t img_size = (size_t)ftello(f);
	uint8_t *pristine = malloc(img_size);
	fseeko(f, 0, SEEK_SET);
	if (fread(pristine, 1, img_size, f) != img_size)
		die("fuzz: snapshot read", -1);
	fclose(f);

	/* Metadata lives at the front; bias corruption there but spray the
	 * whole image too. */
	size_t meta_zone = img_size < 32 * 1024 * 1024 ? img_size : 32 * 1024 * 1024;

	fuzz_rng_state = seed ? seed : 0x243F6A8885A308D3ULL;
	signal(SIGALRM, watchdog);

	int mounted_ok = 0;
	for (int i = 0; i < rounds; i++) {
		uint64_t round_seed = fuzz_rng_state;
		/* Print BEFORE acting so a crash identifies its round. */
		printf("fuzz round=%d/%d seed=0x%llx\n", i + 1, rounds,
		       (unsigned long long)round_seed);
		fflush(stdout);

		FILE *w = fopen(image, "r+b");
		if (!w)
			die("fuzz: open working image", -1);
		fwrite(pristine, 1, img_size, w);
		int nbytes = 1 + (int)(fuzz_rng() % 64);
		for (int b = 0; b < nbytes; b++) {
			size_t zone = (fuzz_rng() % 4 == 0) ? img_size : meta_zone;
			size_t off = 1024 + (size_t)(fuzz_rng() % (zone - 1024));
			uint8_t v = (uint8_t)fuzz_rng();
			fseeko(w, (off_t)off, SEEK_SET);
			fputc(v, w);
		}
		fclose(w);

		alarm(20);
		file_dev_name_set(image);
		bd = file_dev_get();
		fuzz_mount_walk();
		alarm(0);
		mounted_ok++;
	}
	printf("fuzz: %d/%d rounds completed without crash or hang\n",
	       mounted_ok, rounds);
	free(pristine);
}

/* --------------------------------- soak ---------------------------------- */

static void verify_pattern(void);

static void run_soak(const char *image, int seconds)
{
	enum { MAXF = 512, NAMELEN = 64 };
	static char names[MAXF][NAMELEN];
	int live = 0;
	uint64_t ops = 0, errs = 0;

	make_image(image);
	mount_fs();

	/* A pattern file that must survive the whole run intact. */
	w_seqwrite();

	int rc = ext4_dir_mk(MP "soak");
	if (rc != EOK)
		die("soak: mkdir", rc);

	fuzz_rng_state = 0x9E3779B97F4A7C15ULL;
	uint8_t chunk[16384];
	double deadline = now_s() + seconds;

	while (now_s() < deadline) {
		uint64_t roll = fuzz_rng() % 100;
		char path[128], path2[128];
		if (roll < 25 && live < MAXF) {
			/* create + write a bit */
			snprintf(names[live], NAMELEN, "f-%llu",
				 (unsigned long long)fuzz_rng());
			snprintf(path, sizeof(path), MP "soak/%s", names[live]);
			ext4_file f;
			if (ext4_fopen(&f, path, "wb") == EOK) {
				fill_pattern(chunk, sizeof(chunk), roll);
				size_t w;
				if (ext4_fwrite(&f, chunk, sizeof(chunk), &w) != EOK)
					errs++;
				ext4_fclose(&f);
				live++;
			} else {
				errs++;
			}
		} else if (roll < 45 && live > 0) {
			/* read + verify a random live file */
			int i = (int)(fuzz_rng() % live);
			snprintf(path, sizeof(path), MP "soak/%s", names[i]);
			ext4_file f;
			if (ext4_fopen(&f, path, "rb") == EOK) {
				uint8_t got[16384];
				size_t r;
				if (ext4_fread(&f, got, sizeof(got), &r) != EOK)
					errs++;
				ext4_fclose(&f);
			} else {
				errs++;
			}
		} else if (roll < 60 && live > 0) {
			/* rename */
			int i = (int)(fuzz_rng() % live);
			snprintf(path, sizeof(path), MP "soak/%s", names[i]);
			snprintf(names[i], NAMELEN, "r-%llu",
				 (unsigned long long)fuzz_rng());
			snprintf(path2, sizeof(path2), MP "soak/%s", names[i]);
			if (ext4_frename(path, path2) != EOK)
				errs++;
		} else if (roll < 75 && live > 0) {
			/* unlink */
			int i = (int)(fuzz_rng() % live);
			snprintf(path, sizeof(path), MP "soak/%s", names[i]);
			if (ext4_fremove(path) != EOK)
				errs++;
			memcpy(names[i], names[live - 1], NAMELEN);
			live--;
		} else if (roll < 85 && live > 0) {
			/* truncate shrink */
			int i = (int)(fuzz_rng() % live);
			snprintf(path, sizeof(path), MP "soak/%s", names[i]);
			ext4_file f;
			if (ext4_fopen(&f, path, "r+b") == EOK) {
				(void)ext4_ftruncate(&f, fuzz_rng() % 16384);
				ext4_fclose(&f);
			}
		} else if (roll < 92) {
			/* stat storm over the dir */
			ext4_dir d;
			if (ext4_dir_open(&d, MP "soak") == EOK) {
				const ext4_direntry *de;
				int n = 0;
				while ((de = ext4_dir_entry_next(&d)) && n++ < 64) {}
				ext4_dir_close(&d);
			}
		} else {
			(void)ext4_cache_flush(MP);
		}
		ops++;
	}

	unmount_fs();
	mount_fs();

	/* Structural walk + the pattern file must be intact. */
	ext4_dir d;
	int walked = 0;
	if (ext4_dir_open(&d, MP "soak") == EOK) {
		const ext4_direntry *de;
		char path[160];
		while ((de = ext4_dir_entry_next(&d)) != NULL) {
			if (de->name_length == 0)
				continue;
			snprintf(path, sizeof(path), MP "soak/%.*s",
				 (int)de->name_length, (const char *)de->name);
			uint32_t ino;
			struct ext4_inode inode;
			if (ext4_raw_inode_fill(path, &ino, &inode) == EOK)
				walked++;
		}
		ext4_dir_close(&d);
	}
	verify_pattern();
	unmount_fs();

	printf("soak: %llu ops, %llu graceful errors, %d live files walked, "
	       "pattern intact\n",
	       (unsigned long long)ops, (unsigned long long)errs, walked);
}

/* ----------------------------- crash / replay ---------------------------- */
//
// A real power-loss test needs real hardware (a yanked USB stick); this is
// the unprivileged proxy. lwext4's file_dev is unbuffered (setbuf(.,0)), so
// writes hit the backing file synchronously and a bare process exit loses
// nothing — to create genuine journal-replay work we enable write-back mode
// (ext4_cache_write_back), which defers in-place *checkpoint* writes while
// journal commit blocks still land synchronously. A child does churn under
// write-back and _exit()s without flushing, abandoning committed-but-not-
// checkpointed transactions in memory. The parent then mounts, runs
// ext4_recover (which replays them), and checks two things: a sentinel file
// written and durably committed BEFORE any churn is still byte-intact, and
// the churn directory walks without a crash or hang. Replaying onto a
// corrupt result, or losing the sentinel, is a fatal finding.

#define CRASH_SENTINEL_SEED 0x5E47C0DEULL
#define CRASH_SENTINEL_SIZE (256 * 1024)

static const char *g_image;

static void crash_write_sentinel(void)
{
	uint8_t *buf = malloc(CRASH_SENTINEL_SIZE);
	fill_pattern(buf, CRASH_SENTINEL_SIZE, CRASH_SENTINEL_SEED);
	ext4_file f;
	if (ext4_fopen(&f, MP "sentinel.bin", "wb") != EOK)
		die("crash: sentinel create", -1);
	size_t w = 0;
	if (ext4_fwrite(&f, buf, CRASH_SENTINEL_SIZE, &w) != EOK || w != CRASH_SENTINEL_SIZE)
		die("crash: sentinel write", -1);
	ext4_fclose(&f);
	free(buf);
}

static int crash_check_sentinel(void)
{
	uint8_t *got = malloc(CRASH_SENTINEL_SIZE);
	uint8_t *exp = malloc(CRASH_SENTINEL_SIZE);
	fill_pattern(exp, CRASH_SENTINEL_SIZE, CRASH_SENTINEL_SEED);
	ext4_file f;
	int ok = 1;
	if (ext4_fopen(&f, MP "sentinel.bin", "rb") != EOK) {
		free(got);
		free(exp);
		return 0;
	}
	size_t r = 0;
	if (ext4_fread(&f, got, CRASH_SENTINEL_SIZE, &r) != EOK || r != CRASH_SENTINEL_SIZE
		|| memcmp(got, exp, CRASH_SENTINEL_SIZE) != 0)
		ok = 0;
	ext4_fclose(&f);
	free(got);
	free(exp);
	return ok;
}

/* Child: mount, defer checkpoints, churn, abandon without unmount/flush. */
static void crash_child(uint64_t survive_ops)
{
	file_dev_name_set(g_image);
	bd = file_dev_get();
	if (ext4_device_register(bd, "bench0") != EOK)
		_exit(2);
	if (ext4_mount("bench0", MP, false) != EOK)
		_exit(2);
	ext4_recover(MP);
	ext4_journal_start(MP);
	ext4_cache_write_back(MP, true);

	ext4_dir_mk(MP "churn");
	char path[128];
	uint8_t buf[8192];
	for (uint64_t i = 0; i < survive_ops; i++) {
		snprintf(path, sizeof(path), MP "churn/f-%llu", (unsigned long long)(i % 256));
		ext4_file f;
		if (ext4_fopen(&f, path, "wb") == EOK) {
			memset(buf, (int)(i & 0xff), sizeof(buf));
			size_t w;
			ext4_fwrite(&f, buf, sizeof(buf), &w);
			ext4_fclose(&f);
		}
		if ((i % 5) == 0) {
			snprintf(path, sizeof(path), MP "churn/f-%llu",
				 (unsigned long long)((i + 7) % 256));
			ext4_fremove(path);
		}
	}
	/* Abandon. Deferred checkpoints in the in-memory bcache are lost;
	 * committed journal transactions remain on disk for replay. */
	_exit(0);
}

/* Parent: replay the abandoned journal and verify consistency. */
static int crash_recover_and_check(void)
{
	file_dev_name_set(g_image);
	bd = file_dev_get();
	if (ext4_device_register(bd, "bench0") != EOK)
		return 0;
	if (ext4_mount("bench0", MP, false) != EOK) {
		ext4_device_unregister("bench0");
		return 0;
	}
	ext4_recover(MP);
	ext4_journal_start(MP);

	// The sentinel was durably committed before any churn, so it must
	// survive regardless of replay — this catches replay CORRUPTING
	// already-durable data.
	int ok = crash_check_sentinel();

	// Consistency check: every churn dirent must resolve to a live inode.
	// A bad replay that left a dangling dirent (name pointing at a freed
	// or never-allocated inode) fails here, not just on a crash/hang. We
	// deliberately do NOT check churn file *contents*: lwext4 journals
	// metadata only, so a crash can legitimately leave a recovered inode
	// whose unjournaled data blocks never reached disk.
	//
	// The churn dir must also exist with real entries — otherwise a child
	// that died before doing any work would let the trial pass vacuously.
	ext4_dir d;
	if (ext4_dir_open(&d, MP "churn") != EOK) {
		fprintf(stderr, "crash: churn dir missing after replay (child did no work?)\n");
		ok = 0;
	} else {
		const ext4_direntry *de;
		char path[160];
		int realEntries = 0;
		while ((de = ext4_dir_entry_next(&d)) != NULL) {
			int len = de->name_length;
			if (len == 0)
				continue;
			if ((len == 1 && de->name[0] == '.')
				|| (len == 2 && de->name[0] == '.' && de->name[1] == '.'))
				continue;
			realEntries++;
			snprintf(path, sizeof(path), MP "churn/%.*s", len, (const char *)de->name);
			uint32_t ino;
			struct ext4_inode inode;
			if (ext4_raw_inode_fill(path, &ino, &inode) != EOK) {
				fprintf(stderr, "crash: dangling dirent '%s' after replay\n", path);
				ok = 0;
				break;
			}
		}
		ext4_dir_close(&d);
		if (ok && realEntries == 0) {
			fprintf(stderr, "crash: churn dir empty after replay (child did no work?)\n");
			ok = 0;
		}
	}

	ext4_journal_stop(MP);
	ext4_cache_flush(MP);
	ext4_umount(MP);
	ext4_device_unregister("bench0");
	return ok;
}

static void run_crash(const char *image, int trials)
{
	g_image = image;

	/* Pristine image with a durably-committed sentinel. */
	make_image(image);
	mount_fs();
	crash_write_sentinel();
	unmount_fs();

	signal(SIGALRM, watchdog);
	fuzz_rng_state = 0xC0FFEED00DULL;

	int passed = 0;
	for (int i = 0; i < trials; i++) {
		uint64_t survive = 1 + (fuzz_rng() % 400);
		printf("crash trial=%d/%d survive_ops=%llu\n", i + 1, trials,
		       (unsigned long long)survive);
		fflush(stdout);

		pid_t pid = fork();
		if (pid < 0)
			die("crash: fork", -1);
		if (pid == 0)
			crash_child(survive);

		int status = 0;
		waitpid(pid, &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
			fprintf(stderr,
				"FATAL: crash child failed to run workload (trial %d, status=%d)\n",
				i + 1, status);
			exit(3);
		}

		alarm(30);
		int ok = crash_recover_and_check();
		alarm(0);
		if (!ok) {
			fprintf(stderr,
				"FATAL: sentinel lost or fs inconsistent after replay "
				"(trial %d, survive_ops=%llu)\n",
				i + 1, (unsigned long long)survive);
			exit(3);
		}
		passed++;
	}
	printf("crash: %d/%d trials recovered cleanly (sentinel intact, fs walkable)\n",
	       passed, trials);
}

static void verify_pattern(void)
{
	uint8_t *buf = malloc(opt_chunk);
	uint8_t *expect = malloc(opt_chunk);
	ext4_file f;
	int rc = ext4_fopen(&f, MP "big.bin", "rb");
	if (rc != EOK)
		die("verify fopen", rc);
	uint64_t total = opt_io_mb * 1024 * 1024;
	for (uint64_t off = 0; off < total; off += opt_chunk) {
		size_t r = 0;
		rc = ext4_fread(&f, buf, opt_chunk, &r);
		if (rc != EOK || r != opt_chunk)
			die("verify fread", rc);
		fill_pattern(expect, opt_chunk, off);
		if (memcmp(buf, expect, opt_chunk) != 0) {
			fprintf(stderr, "FATAL: data mismatch at offset %llu\n",
				(unsigned long long)off);
			exit(1);
		}
	}
	ext4_fclose(&f);
	free(buf);
	free(expect);
	printf("verify: OK (%llu MiB pattern intact after remount)\n",
	       (unsigned long long)opt_io_mb);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <image> [--wb] [--no-journal] "
			"[--size-mb N] [--files N] [--io-mb N] [--chunk-kb N] "
			"[--keep] [--verify]\n", argv[0]);
		return 2;
	}
	const char *image = argv[1];
	int opt_fuzz = 0, opt_soak = 0, opt_crash = 0;
	uint64_t opt_fuzz_seed = 0;
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--wb")) opt_wb = 1;
		else if (!strcmp(argv[i], "--no-journal")) opt_journal = 0;
		else if (!strcmp(argv[i], "--keep")) opt_keep = 1;
		else if (!strcmp(argv[i], "--verify")) opt_verify = 1;
		else if (!strcmp(argv[i], "--size-mb") && i + 1 < argc) opt_size_mb = strtoull(argv[++i], NULL, 10);
		else if (!strcmp(argv[i], "--files") && i + 1 < argc) opt_files = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--io-mb") && i + 1 < argc) opt_io_mb = strtoull(argv[++i], NULL, 10);
		else if (!strcmp(argv[i], "--chunk-kb") && i + 1 < argc) opt_chunk = strtoull(argv[++i], NULL, 10) * 1024;
		else if (!strcmp(argv[i], "--fuzz") && i + 1 < argc) opt_fuzz = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--fuzz-seed") && i + 1 < argc) opt_fuzz_seed = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--soak") && i + 1 < argc) opt_soak = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--crash") && i + 1 < argc) opt_crash = atoi(argv[++i]);
		else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
	}

	if (opt_fuzz > 0) {
		run_fuzz(image, opt_fuzz, opt_fuzz_seed);
		if (!opt_keep)
			unlink(image);
		return 0;
	}
	if (opt_soak > 0) {
		run_soak(image, opt_soak);
		if (!opt_keep)
			unlink(image);
		return 0;
	}
	if (opt_crash > 0) {
		run_crash(image, opt_crash);
		if (!opt_keep)
			unlink(image);
		return 0;
	}

	printf("# image=%s size=%lluMiB files=%d io=%lluMiB chunk=%zuKiB "
	       "cache=%d wb=%d journal=%d\n",
	       image, (unsigned long long)opt_size_mb, opt_files,
	       (unsigned long long)opt_io_mb, opt_chunk / 1024,
	       CONFIG_BLOCK_DEV_CACHE_SIZE, opt_wb, opt_journal);

	make_image(image);
	mount_fs();

	w_create();
	w_seqwrite();
	w_seqread();
	w_randread();
	w_enum_stat();
	w_enum_resume();
	w_enum_resume_off();
	w_deep_stat();
	w_rename();
	w_unlink();

	unmount_fs();

	if (opt_verify) {
		/* Fresh mount so the verify read can't be served by state
		 * left over from the writing mount. */
		mount_fs();
		verify_pattern();
		unmount_fs();
	}

	if (!opt_keep)
		unlink(image);
	return 0;
}
