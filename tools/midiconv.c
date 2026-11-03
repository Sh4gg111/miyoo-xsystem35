/*
 * midiconv.c - converts the MIDI music of a System 3.x game to WAV on the
 * Miyoo Mini itself, the first time the game is launched.
 *
 * Synthesizing MIDI while the game runs is too heavy for the Miyoo CPU, so
 * launch.sh runs this once, before xsystem35. It reads the tracks straight
 * from <game>MA.ALD (the same way xsystem35 does), renders them with
 * FluidSynth and the game's own sound bank (.sf2), and writes
 * <game>/midi/<track>.wav, which the patched xsystem35 plays instead of the
 * MIDI.
 *
 *  - Shows a progress screen (SDL2) on the Miyoo.
 *  - Resumable: each track is written to <n>.wav.part and renamed when it
 *    is complete, so tracks that are already done are skipped next time.
 *    Tracks already converted on a PC (<n>.mp3 / <n>.ogg) are skipped too.
 *  - Menu cancels (the conversion continues on the next launch).
 *  - When every track is done it creates midi/.done, and launch.sh stops
 *    calling it.
 *
 * Usage:
 *   midiconv [--nogui] <game folder> [sample rate]      (default 22050)
 * Exit codes: 0 done, 1 error, 3 cancelled by the user.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */
#include <dirent.h>
#include <errno.h>
#include <fluidsynth.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifndef NO_GUI
#include <SDL.h>
#endif

#define MAX_VOLUMES 26
#define MAX_TRACKS 1024

static double now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---------------------------------------------------------------------- */
/* Progress screen                                                         */
/* ---------------------------------------------------------------------- */

#define SCR_W 640
#define SCR_H 480
#define COL_BG    0xff101830u
#define COL_TEXT  0xffffffffu
#define COL_DIM   0xff8890b0u
#define COL_BAR   0xffffb020u
#define COL_FRAME 0xffffffffu
#define COL_ERR   0xffff6060u

static int use_gui = 1;

#ifndef NO_GUI
static SDL_Window *win;
static SDL_Renderer *ren;
static SDL_Texture *tex;
static uint32_t fb[SCR_W * SCR_H];

static const struct { char c; uint8_t rows[7]; } glyphs[] = {
	{'A', {0x0e,0x11,0x11,0x1f,0x11,0x11,0x11}},
	{'B', {0x1e,0x11,0x11,0x1e,0x11,0x11,0x1e}},
	{'C', {0x0e,0x11,0x10,0x10,0x10,0x11,0x0e}},
	{'D', {0x1e,0x11,0x11,0x11,0x11,0x11,0x1e}},
	{'E', {0x1f,0x10,0x10,0x1e,0x10,0x10,0x1f}},
	{'F', {0x1f,0x10,0x10,0x1e,0x10,0x10,0x10}},
	{'G', {0x0e,0x11,0x10,0x17,0x11,0x11,0x0f}},
	{'H', {0x11,0x11,0x11,0x1f,0x11,0x11,0x11}},
	{'I', {0x0e,0x04,0x04,0x04,0x04,0x04,0x0e}},
	{'J', {0x07,0x02,0x02,0x02,0x02,0x12,0x0c}},
	{'K', {0x11,0x12,0x14,0x18,0x14,0x12,0x11}},
	{'L', {0x10,0x10,0x10,0x10,0x10,0x10,0x1f}},
	{'M', {0x11,0x1b,0x15,0x15,0x11,0x11,0x11}},
	{'N', {0x11,0x19,0x15,0x13,0x11,0x11,0x11}},
	{'O', {0x0e,0x11,0x11,0x11,0x11,0x11,0x0e}},
	{'P', {0x1e,0x11,0x11,0x1e,0x10,0x10,0x10}},
	{'Q', {0x0e,0x11,0x11,0x11,0x15,0x12,0x0d}},
	{'R', {0x1e,0x11,0x11,0x1e,0x14,0x12,0x11}},
	{'S', {0x0f,0x10,0x10,0x0e,0x01,0x01,0x1e}},
	{'T', {0x1f,0x04,0x04,0x04,0x04,0x04,0x04}},
	{'U', {0x11,0x11,0x11,0x11,0x11,0x11,0x0e}},
	{'V', {0x11,0x11,0x11,0x11,0x11,0x0a,0x04}},
	{'W', {0x11,0x11,0x11,0x15,0x15,0x15,0x0a}},
	{'X', {0x11,0x11,0x0a,0x04,0x0a,0x11,0x11}},
	{'Y', {0x11,0x11,0x0a,0x04,0x04,0x04,0x04}},
	{'Z', {0x1f,0x01,0x02,0x04,0x08,0x10,0x1f}},
	{'0', {0x0e,0x11,0x13,0x15,0x19,0x11,0x0e}},
	{'1', {0x04,0x0c,0x04,0x04,0x04,0x04,0x0e}},
	{'2', {0x0e,0x11,0x01,0x02,0x04,0x08,0x1f}},
	{'3', {0x1f,0x02,0x04,0x02,0x01,0x11,0x0e}},
	{'4', {0x02,0x06,0x0a,0x12,0x1f,0x02,0x02}},
	{'5', {0x1f,0x10,0x1e,0x01,0x01,0x11,0x0e}},
	{'6', {0x06,0x08,0x10,0x1e,0x11,0x11,0x0e}},
	{'7', {0x1f,0x01,0x02,0x04,0x08,0x08,0x08}},
	{'8', {0x0e,0x11,0x11,0x0e,0x11,0x11,0x0e}},
	{'9', {0x0e,0x11,0x11,0x0f,0x01,0x02,0x0c}},
	{'.', {0x00,0x00,0x00,0x00,0x00,0x0c,0x0c}},
	{',', {0x00,0x00,0x00,0x00,0x0c,0x04,0x08}},
	{':', {0x00,0x0c,0x0c,0x00,0x0c,0x0c,0x00}},
	{'-', {0x00,0x00,0x00,0x1f,0x00,0x00,0x00}},
	{'/', {0x01,0x01,0x02,0x04,0x08,0x10,0x10}},
	{'(', {0x02,0x04,0x08,0x08,0x08,0x04,0x02}},
	{')', {0x08,0x04,0x02,0x02,0x02,0x04,0x08}},
	{'%', {0x18,0x19,0x02,0x04,0x08,0x13,0x03}},
	{'!', {0x04,0x04,0x04,0x04,0x04,0x00,0x04}},
	{'\'',{0x04,0x04,0x08,0x00,0x00,0x00,0x00}},
};

static const uint8_t *glyph_rows(char c) {
	if (c >= 'a' && c <= 'z')
		c -= 32;
	for (size_t i = 0; i < sizeof(glyphs) / sizeof(glyphs[0]); i++)
		if (glyphs[i].c == c)
			return glyphs[i].rows;
	return NULL;
}

static void fill(int x, int y, int w, int h, uint32_t col) {
	for (int j = y; j < y + h; j++) {
		if (j < 0 || j >= SCR_H)
			continue;
		for (int i = x; i < x + w; i++)
			if (i >= 0 && i < SCR_W)
				fb[j * SCR_W + i] = col;
	}
}

/* Draws text centered at row y, with each font pixel scaled to s x s. */
static void text(int y, int s, uint32_t col, const char *t) {
	int w = (int)strlen(t) * 6 * s - s;
	int x = (SCR_W - w) / 2;
	for (; *t; t++, x += 6 * s) {
		const uint8_t *rows = glyph_rows(*t);
		if (!rows)
			continue;
		for (int r = 0; r < 7; r++)
			for (int c = 0; c < 5; c++)
				if (rows[r] & (0x10 >> c))
					fill(x + c * s, y + r * s, s, s, col);
	}
}

static void present(void) {
	void *base;
	int pitch;
	/* The Miyoo SDL ignores the rectangle when locking, so lock it whole. */
	if (SDL_LockTexture(tex, NULL, &base, &pitch) == 0) {
		for (int y = 0; y < SCR_H; y++)
			memcpy((uint8_t *)base + y * pitch, fb + y * SCR_W, SCR_W * 4);
		SDL_UnlockTexture(tex);
	}
	SDL_RenderClear(ren);
	SDL_RenderCopy(ren, tex, NULL, NULL);
	SDL_RenderPresent(ren);
}

static int gui_init(void) {
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
		return -1;
	}
	win = SDL_CreateWindow("midiconv", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
	                       SCR_W, SCR_H, 0);
	if (!win)
		return -1;
	ren = SDL_CreateRenderer(win, -1, 0);
	if (!ren)
		return -1;
	tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
	                        SCR_W, SCR_H);
	if (!tex)
		return -1;
	return 0;
}

static void gui_quit(void) {
	if (tex) SDL_DestroyTexture(tex);
	if (ren) SDL_DestroyRenderer(ren);
	if (win) SDL_DestroyWindow(win);
	SDL_Quit();
}

/* Returns 1 if the user pressed Menu (cancel). */
static int poll_cancel(void) {
	SDL_Event e;
	int cancel = 0;
	while (SDL_PollEvent(&e)) {
		if (e.type == SDL_QUIT)
			cancel = 1;
		if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE)
			cancel = 1;
	}
	return cancel;
}

/* Waits for any button (or a few seconds). */
static void wait_button(double timeout) {
	double end = now() + timeout;
	SDL_Event e;
	while (now() < end) {
		while (SDL_PollEvent(&e))
			if (e.type == SDL_KEYDOWN || e.type == SDL_QUIT)
				return;
		SDL_Delay(30);
	}
}
#endif

static void draw_progress(int cur, int total, double frac, double eta) {
#ifndef NO_GUI
	if (!use_gui)
		return;
	char buf[96];
	for (int i = 0; i < SCR_W * SCR_H; i++)
		fb[i] = COL_BG;
	text(110, 4, COL_TEXT, "CONVERTING MUSIC");
	text(160, 2, COL_DIM, "ONLY ON THE FIRST LAUNCH");

	snprintf(buf, sizeof(buf), "TRACK %d / %d", cur, total);
	text(215, 3, COL_TEXT, buf);

	int bx = 70, by = 260, bw = SCR_W - 140, bh = 34;
	fill(bx - 3, by - 3, bw + 6, bh + 6, COL_FRAME);
	fill(bx, by, bw, bh, COL_BG);
	int fw = (int)(bw * (frac < 0 ? 0 : frac > 1 ? 1 : frac));
	fill(bx, by, fw, bh, COL_BAR);

	if (eta >= 0) {
		int m = (int)(eta / 60 + 0.5);
		if (eta < 60)
			snprintf(buf, sizeof(buf), "%d%%  -  LESS THAN 1 MIN LEFT", (int)(frac * 100));
		else
			snprintf(buf, sizeof(buf), "%d%%  -  ABOUT %d MIN LEFT", (int)(frac * 100), m);
	} else {
		snprintf(buf, sizeof(buf), "%d%%", (int)(frac * 100));
	}
	text(316, 2, COL_TEXT, buf);

	text(400, 2, COL_DIM, "MENU: STOP (IT CONTINUES NEXT TIME)");
	present();
#else
	(void)cur; (void)total; (void)frac; (void)eta;
#endif
}

static void show_error(const char *l1, const char *l2) {
	fprintf(stderr, "ERROR: %s %s\n", l1, l2 ? l2 : "");
#ifndef NO_GUI
	if (!use_gui)
		return;
	for (int i = 0; i < SCR_W * SCR_H; i++)
		fb[i] = COL_BG;
	text(150, 3, COL_ERR, "MUSIC CONVERSION FAILED");
	text(220, 2, COL_TEXT, l1);
	if (l2)
		text(250, 2, COL_TEXT, l2);
	text(330, 2, COL_DIM, "PRESS ANY BUTTON");
	present();
	wait_button(15);
#endif
}

/* ---------------------------------------------------------------------- */
/* ALD archive (the same format xsystem35 reads, see dri.c)                */
/* ---------------------------------------------------------------------- */

static unsigned get2(const uint8_t *b) { return b[0] | b[1] << 8; }
static unsigned get3(const uint8_t *b) { return b[0] | b[1] << 8 | b[2] << 16; }
static unsigned get4(const uint8_t *b) {
	return b[0] | b[1] << 8 | b[2] << 16 | (unsigned)b[3] << 24;
}

static uint8_t *read_file(const char *path, size_t *size) {
	FILE *fp = fopen(path, "rb");
	if (!fp)
		return NULL;
	fseek(fp, 0, SEEK_END);
	long n = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	uint8_t *buf = malloc(n > 0 ? n : 1);
	if (!buf || fread(buf, 1, n, fp) != (size_t)n) {
		free(buf);
		fclose(fp);
		return NULL;
	}
	fclose(fp);
	*size = n;
	return buf;
}

static char *volumes[MAX_VOLUMES + 1];
static char *sf2_path;

static void scan_dir(const char *dir) {
	DIR *d = opendir(dir);
	if (!d)
		return;
	struct dirent *e;
	while ((e = readdir(d))) {
		const char *n = e->d_name;
		size_t len = strlen(n);
		char path[1024];
		snprintf(path, sizeof(path), "%s/%s", dir, n);
		if (len >= 4 && !strcasecmp(n + len - 4, ".sf2") && !sf2_path) {
			sf2_path = strdup(path);
			continue;
		}
		if (len < 7 || strcasecmp(n + len - 4, ".ALD"))
			continue;
		char kind = n[len - 6], letter = n[len - 5];
		if ((kind == 'M' || kind == 'm') &&
		    ((letter >= 'A' && letter <= 'Z') || (letter >= 'a' && letter <= 'z'))) {
			int vol = (letter | 0x20) - 'a' + 1;
			if (!volumes[vol])
				volumes[vol] = strdup(path);
		}
	}
	closedir(d);
}

struct track {
	unsigned no;          /* track number used by the game (index + 1) */
	const uint8_t *data;
	size_t size;
};

/* ---------------------------------------------------------------------- */
/* Rendering                                                               */
/* ---------------------------------------------------------------------- */

static void write_wav_header(FILE *fp, int rate, uint32_t data_bytes) {
	uint8_t h[44];
	uint32_t v;
	uint16_t s;
	memcpy(h, "RIFF", 4);
	v = 36 + data_bytes;   memcpy(h + 4, &v, 4);
	memcpy(h + 8, "WAVEfmt ", 8);
	v = 16;                memcpy(h + 16, &v, 4);
	s = 1;                 memcpy(h + 20, &s, 2);   /* PCM */
	s = 2;                 memcpy(h + 22, &s, 2);   /* stereo */
	v = rate;              memcpy(h + 24, &v, 4);
	v = rate * 4;          memcpy(h + 28, &v, 4);   /* bytes per second */
	s = 4;                 memcpy(h + 32, &s, 2);   /* bytes per frame */
	s = 16;                memcpy(h + 34, &s, 2);   /* bits */
	memcpy(h + 36, "data", 4);
	memcpy(h + 40, &data_bytes, 4);
	fseek(fp, 0, SEEK_SET);
	fwrite(h, 1, sizeof(h), fp);
}

enum { RES_OK = 0, RES_FAIL = -1, RES_CANCEL = -2, RES_NOSPACE = -3 };

/* Progress state, shared with render() so the bar moves inside a track. */
static int pr_cur, pr_total;
static double pr_start, pr_last_draw;

static void progress_update(double track_frac) {
	double frac = ((pr_cur - 1) + track_frac) / pr_total;
	double el = now() - pr_start;
	double eta = (frac > 0.02 && el > 5) ? el / frac * (1 - frac) : -1;
	draw_progress(pr_cur, pr_total, frac, eta);
	if (!use_gui) {
		printf("\r  track %d/%d  %3d%%", pr_cur, pr_total, (int)(frac * 100));
		fflush(stdout);
	}
}

static int render(fluid_synth_t *synth, const struct track *t, const char *out,
                  const char *part, int rate, double *secs) {
	fluid_synth_system_reset(synth);
	fluid_player_t *pl = new_fluid_player(synth);
	if (!pl)
		return RES_FAIL;
	fluid_player_add_mem(pl, t->data, t->size);
	fluid_player_play(pl);

	FILE *fp = fopen(part, "wb");
	if (!fp) {
		delete_fluid_player(pl);
		return errno == ENOSPC ? RES_NOSPACE : RES_FAIL;
	}
	write_wav_header(fp, rate, 0);

	enum { BLOCK = 1024 };
	int16_t buf[BLOCK * 2];
	uint64_t frames = 0, last_loud = 0;
	int tail = rate;                  /* 1 s after the end, for release tails */
	int result = RES_OK;
	int total_ticks = 0;
	while (fluid_player_get_status(pl) == FLUID_PLAYER_PLAYING || tail > 0) {
		if (fluid_player_get_status(pl) != FLUID_PLAYER_PLAYING)
			tail -= BLOCK;
		fluid_synth_write_s16(synth, BLOCK, buf, 0, 2, buf, 1, 2);
		for (int i = 0; i < BLOCK * 2; i++) {
			if (buf[i] > 64 || buf[i] < -64) {
				last_loud = frames + BLOCK;
				break;
			}
		}
		if (fwrite(buf, sizeof(int16_t), BLOCK * 2, fp) != BLOCK * 2) {
			result = errno == ENOSPC ? RES_NOSPACE : RES_FAIL;
			break;
		}
		frames += BLOCK;
		if (frames > (uint64_t)rate * 60 * 20)     /* safety cap: 20 min */
			break;

		double tnow = now();
		if (tnow - pr_last_draw > 0.25) {
			pr_last_draw = tnow;
			if (!total_ticks)
				total_ticks = fluid_player_get_total_ticks(pl);
			double tf = total_ticks > 0
				? (double)fluid_player_get_current_tick(pl) / total_ticks : 0;
			if (tf > 1) tf = 1;
			progress_update(tf);
#ifndef NO_GUI
			if (use_gui && poll_cancel()) {
				result = RES_CANCEL;
				break;
			}
#endif
		}
	}
	delete_fluid_player(pl);

	if (result == RES_OK) {
		/* Cut the silence at the end (keeps 0.25 s), so the loop restarts
		   without a long pause. */
		uint64_t keep = last_loud + rate / 4;
		if (keep > frames)
			keep = frames;
		if (keep < (uint64_t)rate / 10)
			keep = frames < (uint64_t)rate / 10 ? frames : (uint64_t)rate / 10;
		write_wav_header(fp, rate, (uint32_t)(keep * 4));
		if (fflush(fp) != 0)
			result = errno == ENOSPC ? RES_NOSPACE : RES_FAIL;
		if (result == RES_OK && ftruncate(fileno(fp), 44 + keep * 4) != 0)
			result = RES_FAIL;
		if (result == RES_OK)
			fsync(fileno(fp));
		*secs = (double)keep / rate;
	}
	if (fclose(fp) != 0 && result == RES_OK)
		result = errno == ENOSPC ? RES_NOSPACE : RES_FAIL;

	if (result == RES_OK && rename(part, out) != 0)
		result = RES_FAIL;
	if (result != RES_OK)
		unlink(part);
	return result;
}

static int exists(const char *path) {
	struct stat st;
	return stat(path, &st) == 0;
}

static int already_done(const char *outdir, unsigned no) {
	static const char *ext[] = { "wav", "mp3", "ogg" };
	char path[1100];
	for (int i = 0; i < 3; i++) {
		snprintf(path, sizeof(path), "%s/%u.%s", outdir, no, ext[i]);
		if (exists(path))
			return 1;
	}
	return 0;
}

static int finish(int code) {
#ifndef NO_GUI
	if (use_gui)
		gui_quit();
#endif
	return code;
}

int main(int argc, char **argv) {
	int a = 1;
	if (a < argc && !strcmp(argv[a], "--nogui")) {
		use_gui = 0;
		a++;
	}
#ifdef NO_GUI
	use_gui = 0;
#endif
	if (argc - a < 1) {
		fprintf(stderr, "usage: %s [--nogui] <game folder> [sample rate]\n", argv[0]);
		return 2;
	}
	const char *game = argv[a];
	int rate = argc - a > 1 ? atoi(argv[a + 1]) : 22050;
	if (rate < 8000 || rate > 96000)
		rate = 22050;

	char outdir[1024], done_mark[1100];
	snprintf(outdir, sizeof(outdir), "%s/midi", game);
	snprintf(done_mark, sizeof(done_mark), "%s/.done", outdir);
	if (exists(done_mark)) {
		printf("midiconv: %s already exists, nothing to do\n", done_mark);
		return 0;
	}

	scan_dir(game);
	if (!sf2_path || !volumes[1]) {
		printf("midiconv: no .sf2 or no *MA.ALD in %s, nothing to do\n", game);
		return 0;
	}

	/* Read the music archive and list the MIDI tracks. */
	size_t sizes[MAX_VOLUMES + 1] = {0};
	uint8_t *data[MAX_VOLUMES + 1] = {0};
	for (int v = 1; v <= MAX_VOLUMES; v++)
		if (volumes[v])
			data[v] = read_file(volumes[v], &sizes[v]);
	uint8_t *first = data[1];
	if (!first || sizes[1] < 6) {
		fprintf(stderr, "midiconv: cannot read %s\n", volumes[1]);
		return 1;
	}
	unsigned ofssize = get3(first) << 8;
	unsigned linksize = (get3(first + 3) << 8) - ofssize;
	if (!ofssize || !linksize || ofssize + linksize > sizes[1]) {
		fprintf(stderr, "midiconv: %s is not a valid .ALD\n", volumes[1]);
		return 1;
	}
	const uint8_t *link = first + ofssize;

	static struct track todo[MAX_TRACKS];
	int ntodo = 0, nall = 0;
	mkdir(outdir, 0755);
	for (unsigned i = 0; i < linksize / 3 && ntodo < MAX_TRACKS; i++) {
		int vol = link[i * 3];
		if (vol < 1 || vol > MAX_VOLUMES || !data[vol])
			continue;
		const uint8_t *buf = data[vol];
		unsigned oi = get2(link + i * 3 + 1);
		if ((oi + 1) * 3 > sizes[vol])
			continue;
		unsigned off = get3(buf + oi * 3) << 8;
		if (!off || off + 8 > sizes[vol])
			continue;
		unsigned ptr = get4(buf + off), size = get4(buf + off + 4);
		if (off + ptr + size > sizes[vol] || size < 4 || memcmp(buf + off + ptr, "MThd", 4))
			continue;
		nall++;
		/* Leftover of an interrupted run. */
		char part[1100];
		snprintf(part, sizeof(part), "%s/%u.wav.part", outdir, i + 1);
		unlink(part);
		if (already_done(outdir, i + 1))
			continue;
		todo[ntodo].no = i + 1;
		todo[ntodo].data = buf + off + ptr;
		todo[ntodo].size = size;
		ntodo++;
	}
	printf("midiconv: %s\nsound bank: %s\nrate: %d Hz\ntracks: %d, to convert: %d\n",
	       game, sf2_path, rate, nall, ntodo);

	if (ntodo == 0) {
		FILE *m = fopen(done_mark, "w");
		if (m) fclose(m);
		return 0;
	}

#ifndef NO_GUI
	if (use_gui && gui_init() != 0) {
		fprintf(stderr, "midiconv: no screen (%s), converting without progress\n",
		        SDL_GetError());
		gui_quit();
		use_gui = 0;
	}
#endif
	pr_total = ntodo;
	pr_cur = 1;
	pr_start = now();
	progress_update(0);

	/* The sound bank is loaded once and reused for every track. */
	fluid_settings_t *st = new_fluid_settings();
	fluid_settings_setnum(st, "synth.sample-rate", rate);
	fluid_settings_setnum(st, "synth.gain", 0.6);
	fluid_settings_setint(st, "synth.reverb.active", 0);
	fluid_settings_setint(st, "synth.chorus.active", 0);
	fluid_settings_setint(st, "synth.polyphony", 64);
	fluid_settings_setstr(st, "player.timing-source", "sample");
	fluid_synth_t *synth = new_fluid_synth(st);
	if (!synth || fluid_synth_sfload(synth, sf2_path, 1) == FLUID_FAILED) {
		show_error("CANNOT LOAD THE SOUND BANK (.SF2)", NULL);
		return finish(1);
	}

	int rc = 0;
	double music = 0;
	for (int k = 0; k < ntodo; k++) {
		pr_cur = k + 1;
		pr_last_draw = 0;
		char out[1100], part[1100];
		snprintf(out, sizeof(out), "%s/%u.wav", outdir, todo[k].no);
		snprintf(part, sizeof(part), "%s/%u.wav.part", outdir, todo[k].no);
		double t0 = now(), secs = 0;
		int r = render(synth, &todo[k], out, part, rate, &secs);
		if (r == RES_CANCEL) {
			printf("%smidiconv: cancelled by the user (%d/%d done)\n", use_gui ? "" : "\n", k, ntodo);
			rc = 3;
			break;
		}
		if (r == RES_NOSPACE) {
			show_error("THE SD CARD IS FULL.", "FREE SOME SPACE AND TRY AGAIN.");
			rc = 1;
			break;
		}
		if (r != RES_OK) {
			/* A broken track: skip it (the game falls back to the MIDI). */
			fprintf(stderr, "\nmidiconv: track %u failed, skipped\n", todo[k].no);
			continue;
		}
		music += secs;
		printf("%s  track %3u: %5.1f s of music in %5.1f s\n", use_gui ? "" : "\n", todo[k].no, secs, now() - t0);
	}

	delete_fluid_synth(synth);
	delete_fluid_settings(st);

	if (rc == 0) {
		FILE *m = fopen(done_mark, "w");
		if (m) fclose(m);
		printf("midiconv: done, %.1f min of music in %.1f min\n", music / 60,
		       (now() - pr_start) / 60);
	}
	return finish(rc);
}
