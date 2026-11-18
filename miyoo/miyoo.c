/*
 * miyoo.c  Controls and cursor for the Miyoo Mini (OnionOS)
 *
 * The Miyoo Mini SDL2 (steward-fu/sdl2) delivers the buttons as keys and
 * has no mouse or cursor. This file turns the buttons into a virtual mouse
 * and draws a software cursor on the screen texture.
 *
 * Miyoo Mini buttons -> keys delivered by SDL (OnionOS keymon):
 *   D-pad: arrows     A: Space       B: Left Ctrl   X: Left Shift
 *   Y: Left Alt       L1: E          R1: T          L2: Tab
 *   R2: Backspace     Select: Right Ctrl   Start: Enter   Menu: Esc
 *
 * In-game mapping:
 *   D-pad ............ move the cursor (hold to accelerate)
 *   R1 (hold) ........ fast cursor
 *   L1 + D-pad ....... keyboard arrow keys (menus that use the keyboard)
 *   A ................ left click
 *   B ................ right click (cancel / game menu)
 *   Start ............ Enter
 *   Select ........... toggle message skip (like F1)
 *   Menu ............. pause menu: RESUME GAME / RESTART GAME / EXIT GAME
 *
 * RG DS / RG DS Plus (BananaOS, ROCKNIX): also built with -DRGDS. The
 * controller becomes keys through PortMaster's gptokeyb (see
 * rgds/xsystem35.gptk), with the same keys as on the Miyoo; A, B and Select
 * also accept Z, X and S, key names gptokeyb surely knows. No pause menu
 * (Select + Start closes the game) and no pre-rendered MIDI music.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "config.h"

#ifdef MIYOO_MINI

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef RGDS
#include <math.h>
#endif
#include "sdl_compat.h"

#include "portab.h"
#include "event.h"
#include "gfx.h"
#include "gfx_private.h"
#include "nact.h"
#include "msgskip.h"
#include "miyoo.h"

/* On the RG DS the pause menu is compiled in, but unused. */
#ifdef RGDS
#define RGDS_UNUSED __attribute__((unused))
#else
#define RGDS_UNUSED
#endif

/* ---------------------------------------------------------------------- */
/* Software cursor                                                        */
/* ---------------------------------------------------------------------- */

#define CUR_W 12
#define CUR_H 19

static const char *cursor_image[CUR_H] = {
	"X           ",
	"XX          ",
	"X.X         ",
	"X..X        ",
	"X...X       ",
	"X....X      ",
	"X.....X     ",
	"X......X    ",
	"X.......X   ",
	"X........X  ",
	"X.........X ",
	"X......XXXXX",
	"X...X..X    ",
	"X..XX..X    ",
	"X.X  X..X   ",
	"XX   X..X   ",
	"X     X..X  ",
	"      X..X  ",
	"       XX   ",
};

static float cur_x = -1, cur_y = -1;
static bool drawn;
static SDL_Rect drawn_rect;
static Uint32 backup[CUR_W * CUR_H];

/* The Miyoo SDL renderer ignores the rectangle position in
   SDL_LockTexture (it always returns the start of the texture). So the
   whole texture is locked and the offset is computed here. Each lock costs
   a copy of the whole screen, so it is done at most once per frame. */
static Uint8 *lock_whole(int *pitch) {
	if (!gfx_texture)
		return NULL;
	void *base = NULL;
#if XSYSTEM35_SDL_VERSION == 2
	if (SDL_LockTexture(gfx_texture, NULL, &base, pitch) != 0)
		return NULL;
#else
	if (!SDL_LockTexture(gfx_texture, NULL, &base, pitch))
		return NULL;
#endif
	return base;
}

static void ensure_position(void) {
	if (cur_x >= 0)
		return;
	int w = 640, h = 480;
	gfx_getViewSize(&w, &h);
	cur_x = w / 2;
	cur_y = h / 2;
}

static void restore_backup(Uint8 *base, int pitch) {
	for (int y = 0; y < drawn_rect.h; y++) {
		Uint32 *row = (Uint32 *)(base + (drawn_rect.y + y) * pitch) + drawn_rect.x;
		memcpy(row, &backup[y * CUR_W], drawn_rect.w * sizeof(Uint32));
	}
	drawn = false;
}

void miyoo_cursor_reset(void) {
	drawn = false;
}

void miyoo_cursor_hide(void) {
	if (!drawn)
		return;
	int pitch;
	Uint8 *base = lock_whole(&pitch);
	if (!base) {
		drawn = false;
		return;
	}
	restore_backup(base, pitch);
	SDL_UnlockTexture(gfx_texture);
}

void miyoo_cursor_show(void) {
	ensure_position();

	int vw = 0, vh = 0;
	gfx_getViewSize(&vw, &vh);
	SDL_Rect r = { (int)cur_x, (int)cur_y, CUR_W, CUR_H };
	if (r.x + r.w > vw)
		r.w = vw - r.x;
	if (r.y + r.h > vh)
		r.h = vh - r.y;
	bool visible = r.x >= 0 && r.y >= 0 && r.w > 0 && r.h > 0;

	/* Cursor already drawn at the same place: nothing to do. */
	if (drawn && visible && r.x == drawn_rect.x && r.y == drawn_rect.y &&
		r.w == drawn_rect.w && r.h == drawn_rect.h)
		return;
	if (!drawn && !visible)
		return;

	int pitch;
	Uint8 *base = lock_whole(&pitch);
	if (!base) {
		drawn = false;
		return;
	}
	if (drawn)
		restore_backup(base, pitch);
	if (visible) {
		for (int y = 0; y < r.h; y++) {
			Uint32 *row = (Uint32 *)(base + (r.y + y) * pitch) + r.x;
			memcpy(&backup[y * CUR_W], row, r.w * sizeof(Uint32));
			for (int x = 0; x < r.w; x++) {
				char c = cursor_image[y][x];
				if (c == 'X')
					row[x] = 0xff000000;  /* black (XRGB8888) */
				else if (c == '.')
					row[x] = 0xffffffff;  /* white */
			}
		}
		drawn = true;
		drawn_rect = r;
	}
	SDL_UnlockTexture(gfx_texture);
}

/* ---------------------------------------------------------------------- */
/* Transition effects done in software                                    */
/* ---------------------------------------------------------------------- */

/* The Miyoo SDL renderer draws any texture with transparency incorrectly
   (the image comes out squeezed and duplicated side by side). So, during
   effects, each frame is assembled on the CPU (copy, alpha blend, scale)
   and a single opaque image is sent to the screen, the same way as the
   normal game screen, which works. */

#define MAX_TEX 64
static struct { SDL_Texture *tx; SDL_Surface *sf; } tex_pixels[MAX_TEX];

static SDL_Surface *pixels_of(SDL_Texture *tx) {
	for (int i = 0; i < MAX_TEX; i++)
		if (tex_pixels[i].tx == tx)
			return tex_pixels[i].sf;
	return NULL;
}

static bool lock_any(SDL_Texture *tx, void **pixels, int *pitch) {
	*pixels = NULL;
#if XSYSTEM35_SDL_VERSION == 2
	return SDL_LockTexture(tx, NULL, pixels, pitch) == 0 && *pixels;
#else
	return SDL_LockTexture(tx, NULL, pixels, pitch) && *pixels;
#endif
}

/* Creates the texture and keeps a copy of its pixels (XRGB8888) for the
   software compositor. */
SDL_Texture *miyoo_texture_from_surface(SDL_Renderer *renderer, SDL_Surface *src) {
	SDL_Surface *conv = sdl_ConvertSurface(src, SDL_PIXELFORMAT_XRGB8888);
	if (!conv)
		return NULL;
	SDL_Texture *tx = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_XRGB8888,
	                                    SDL_TEXTUREACCESS_STREAMING, conv->w, conv->h);
	if (!tx) {
		SDL_DestroySurface(conv);
		return NULL;
	}
	void *pixels;
	int pitch;
	if (lock_any(tx, &pixels, &pitch)) {
		for (int y = 0; y < conv->h; y++)
			memcpy((Uint8 *)pixels + y * pitch,
			       (Uint8 *)conv->pixels + y * conv->pitch, conv->w * 4);
		SDL_UnlockTexture(tx);
	}
	for (int i = 0; i < MAX_TEX; i++) {
		if (!tex_pixels[i].tx) {
			tex_pixels[i].tx = tx;
			tex_pixels[i].sf = conv;
			return tx;
		}
	}
	SDL_DestroySurface(conv);  /* table full: no copy, the effect becomes a cut */
	return tx;
}

void miyoo_destroy_texture(SDL_Texture *tx) {
	if (!tx)
		return;
	for (int i = 0; i < MAX_TEX; i++) {
		if (tex_pixels[i].tx == tx) {
			SDL_DestroySurface(tex_pixels[i].sf);
			tex_pixels[i].tx = NULL;
			tex_pixels[i].sf = NULL;
		}
	}
	SDL_DestroyTexture(tx);
}

static Uint32 *fb, *snap;      /* assembled frame / copy of the game screen */
static int fb_w, fb_h, fb_cap;
static SDL_Texture *fb_tx;
static int fb_tx_w, fb_tx_h;
static bool comp_active, comp_used;

void miyoo_comp_begin(void) {
	comp_active = false;
	comp_used = false;
	if (!gfx_texture)
		return;
	int w = view_w, h = view_h;
	if (w <= 0 || h <= 0)
		return;
	if (w * h > fb_cap) {
		free(fb);
		free(snap);
		fb = malloc(w * h * 4);
		snap = malloc(w * h * 4);
		fb_cap = (fb && snap) ? w * h : 0;
		if (!fb_cap)
			return;
	}
	fb_w = w;
	fb_h = h;
	void *pixels;
	int pitch;
	if (!lock_any(gfx_texture, &pixels, &pitch))
		return;
	for (int y = 0; y < h; y++)
		memcpy(snap + y * w, (Uint8 *)pixels + y * pitch, w * 4);
	SDL_UnlockTexture(gfx_texture);
	memcpy(fb, snap, w * h * 4);
	comp_active = true;
}

bool miyoo_comp_draw(SDL_Texture *tx, const SDL_Rect *srcrect, const SDL_Rect *dstrect) {
	if (!comp_active)
		return false;

	const Uint32 *src;
	int src_w, src_h, src_stride;
	if (tx == gfx_texture) {
		src = snap;
		src_w = fb_w;
		src_h = fb_h;
		src_stride = fb_w;
	} else {
		SDL_Surface *sf = pixels_of(tx);
		if (!sf)
			return false;
		src = sf->pixels;
		src_w = sf->w;
		src_h = sf->h;
		src_stride = sf->pitch / 4;
	}

	SDL_Rect sr = srcrect ? *srcrect : (SDL_Rect){0, 0, src_w, src_h};
	SDL_Rect dr = dstrect ? *dstrect : (SDL_Rect){0, 0, fb_w, fb_h};
	if (sr.w <= 0 || sr.h <= 0 || dr.w <= 0 || dr.h <= 0)
		return true;

	SDL_BlendMode mode = SDL_BLENDMODE_NONE;
	Uint8 alpha = 255;
	SDL_GetTextureBlendMode(tx, &mode);
	SDL_GetTextureAlphaMod(tx, &alpha);
	if (mode == SDL_BLENDMODE_NONE)
		alpha = 255;
	if (alpha == 0 && mode != SDL_BLENDMODE_NONE)
		return true;

	int x0 = dr.x < 0 ? 0 : dr.x;
	int y0 = dr.y < 0 ? 0 : dr.y;
	int x1 = dr.x + dr.w > fb_w ? fb_w : dr.x + dr.w;
	int y1 = dr.y + dr.h > fb_h ? fb_h : dr.y + dr.h;
	unsigned a = alpha, ia = 255 - alpha;

	for (int y = y0; y < y1; y++) {
		int sy = sr.y + (int)((long)(y - dr.y) * sr.h / dr.h);
		if (sy < 0 || sy >= src_h)
			continue;
		const Uint32 *srow = src + sy * src_stride;
		Uint32 *drow = fb + y * fb_w;
		for (int x = x0; x < x1; x++) {
			int sx = sr.x + (int)((long)(x - dr.x) * sr.w / dr.w);
			if (sx < 0 || sx >= src_w)
				continue;
			Uint32 s = srow[sx];
			if (mode == SDL_BLENDMODE_ADD) {
				Uint32 d = drow[x];
				unsigned r = ((d >> 16) & 0xff) + (((s >> 16) & 0xff) * a >> 8);
				unsigned g = ((d >> 8) & 0xff) + (((s >> 8) & 0xff) * a >> 8);
				unsigned b = (d & 0xff) + ((s & 0xff) * a >> 8);
				drow[x] = 0xff000000 | (r > 255 ? 255 : r) << 16 |
				          (g > 255 ? 255 : g) << 8 | (b > 255 ? 255 : b);
			} else if (a == 255) {
				drow[x] = s | 0xff000000;
			} else {
				Uint32 d = drow[x];
				unsigned r = (((s >> 16) & 0xff) * a + ((d >> 16) & 0xff) * ia) / 255;
				unsigned g = (((s >> 8) & 0xff) * a + ((d >> 8) & 0xff) * ia) / 255;
				unsigned b = ((s & 0xff) * a + (d & 0xff) * ia) / 255;
				drow[x] = 0xff000000 | r << 16 | g << 8 | b;
			}
		}
	}
	comp_used = true;
	return true;
}

void miyoo_comp_end(void) {
	if (!comp_active || !comp_used) {
		comp_active = false;
		return;
	}
	comp_active = false;
	if (!fb_tx || fb_tx_w != fb_w || fb_tx_h != fb_h) {
		if (fb_tx)
			SDL_DestroyTexture(fb_tx);
		fb_tx = SDL_CreateTexture(gfx_renderer, SDL_PIXELFORMAT_XRGB8888,
		                          SDL_TEXTUREACCESS_STREAMING, fb_w, fb_h);
		fb_tx_w = fb_w;
		fb_tx_h = fb_h;
		if (!fb_tx)
			return;
	}
	void *pixels;
	int pitch;
	if (!lock_any(fb_tx, &pixels, &pitch))
		return;
	for (int y = 0; y < fb_h; y++)
		memcpy((Uint8 *)pixels + y * pitch, fb + y * fb_w, fb_w * 4);
	SDL_UnlockTexture(fb_tx);
	sdl_RenderTexture(gfx_renderer, fb_tx, NULL, NULL);
}

enum { DIR_UP, DIR_DOWN, DIR_LEFT, DIR_RIGHT };
static bool dpad[4];
static bool l1_held, r1_held;

#ifdef RGDS
/* RG DS analog stick read directly through SDL (through gptokeyb it became
   arrow keys and moved crooked). Axes 0 = X and 1 = Y; others with
   RGDS_STICK_X / RGDS_STICK_Y. Each axis range is learned while playing: a
   stick that doesn't reach +-32767 on one side still reaches full speed. */
#define MAX_AXES 8
static int axis_val[MAX_AXES], axis_min[MAX_AXES], axis_max[MAX_AXES];
static int logged_min[MAX_AXES], logged_max[MAX_AXES];
static int stick_x = 0, stick_y = 1;
static bool stick_ready;
static SDL_Joystick *stick_js;
static int axis_center[MAX_AXES], num_axes;
/* Stick log (RGDS_STICK_LOG=1 turns it on): up to 400 lines in run.log. */
static int stick_log_left;
static Uint32 stick_log_last;

static void rgds_stick_init(void) {
	stick_ready = true;
	const char *v;
	if ((v = getenv("RGDS_STICK_X")) && *v)
		stick_x = atoi(v);
	if ((v = getenv("RGDS_STICK_Y")) && *v)
		stick_y = atoi(v);
	if ((v = getenv("RGDS_STICK_LOG")) && *v == '1')
		stick_log_left = 400;
	SDL_InitSubSystem(SDL_INIT_JOYSTICK);
	for (int i = 0; i < SDL_NumJoysticks(); i++) {
		SDL_Joystick *j = SDL_JoystickOpen(i);
		if (!j)
			continue;
		fprintf(stderr, "[rgds] controller %d: %s, %d axes, %d buttons\n", i,
		        SDL_JoystickName(j), SDL_JoystickNumAxes(j), SDL_JoystickNumButtons(j));
		if (!stick_js && SDL_JoystickNumAxes(j) >= 2)
			stick_js = j;
	}
	SDL_JoystickEventState(SDL_ENABLE);
	if (stick_js) {
		/* Rest position of each axis (stick released when the game starts). */
		SDL_JoystickUpdate();
		num_axes = SDL_JoystickNumAxes(stick_js);
		if (num_axes > MAX_AXES)
			num_axes = MAX_AXES;
		fprintf(stderr, "[rgds] rest:");
		for (int a = 0; a < num_axes; a++) {
			int c = SDL_JoystickGetAxis(stick_js, a);
			axis_center[a] = (c > -8000 && c < 8000) ? c : 0;
			fprintf(stderr, " axis%d=%d", a, c);
		}
		fprintf(stderr, "\n");
	}
	fprintf(stderr, "[rgds] stick: X axis = %d, Y axis = %d\n", stick_x, stick_y);
}

static void rgds_axis(int axis, int value) {
	if (axis < 0 || axis >= MAX_AXES)
		return;
	value -= axis_center[axis];
	axis_val[axis] = value;
	if (value < axis_min[axis])
		axis_min[axis] = value;
	if (value > axis_max[axis])
		axis_max[axis] = value;
	/* In the log: each axis range, when it grows a lot. */
	if (axis_min[axis] < logged_min[axis] - 4000 || axis_max[axis] > logged_max[axis] + 4000) {
		logged_min[axis] = axis_min[axis];
		logged_max[axis] = axis_max[axis];
		fprintf(stderr, "[rgds] axis %d: %d to %d\n", axis, axis_min[axis], axis_max[axis]);
	}
}

/* -1..1, using the learned range (at least 12000 on each side). */
static float stick_norm(int axis) {
	if (axis < 0 || axis >= MAX_AXES)
		return 0;
	int v = axis_val[axis];
	int range = v >= 0 ? axis_max[axis] : -axis_min[axis];
	if (range < 12000)
		range = 12000;
	float f = (float)v / range;
	return f > 1 ? 1 : f < -1 ? -1 : f;
}
#endif

/* ---------------------------------------------------------------------- */
/* Pause menu (Menu button): RESUME GAME / RESTART GAME / EXIT GAME        */
/* ---------------------------------------------------------------------- */

/* xsystem35's own menu uses a system dialog box, which doesn't exist on
   the Miyoo. This menu is drawn straight on the screen, with a built-in
   5x7 font (upper case, digits and a few symbols). */

static const struct { char c; Uint8 rows[7]; } glyphs[] = {
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
	{'?', {0x0e,0x11,0x01,0x02,0x04,0x00,0x04}},
	{':', {0x00,0x0c,0x0c,0x00,0x0c,0x0c,0x00}},
};

#define FONT_SCALE 3

static const Uint8 *glyph_rows(char c) {
	for (size_t i = 0; i < sizeof(glyphs) / sizeof(glyphs[0]); i++)
		if (glyphs[i].c == c)
			return glyphs[i].rows;
	return NULL;
}

static int text_width(const char *t, int scale) {
	return (int)strlen(t) * 6 * scale - scale;
}

static void fill_rect(Uint8 *base, int pitch, int x, int y, int w, int h, Uint32 color) {
	for (int j = y; j < y + h; j++) {
		if (j < 0 || j >= view_h)
			continue;
		Uint32 *row = (Uint32 *)(base + j * pitch);
		for (int i = x; i < x + w; i++)
			if (i >= 0 && i < view_w)
				row[i] = color;
	}
}

static void draw_text(Uint8 *base, int pitch, int x, int y, const char *t,
                      int scale, Uint32 color) {
	for (; *t; t++, x += 6 * scale) {
		const Uint8 *rows = glyph_rows(*t);
		if (!rows)
			continue;  /* space */
		for (int r = 0; r < 7; r++)
			for (int c = 0; c < 5; c++)
				if (rows[r] & (0x10 >> c))
					fill_rect(base, pitch, x + c * scale, y + r * scale, scale, scale, color);
	}
}

/* Centered text. */
static void draw_text_c(Uint8 *base, int pitch, int cx, int y, const char *t,
                        int scale, Uint32 color) {
	draw_text(base, pitch, cx - text_width(t, scale) / 2, y, t, scale, color);
}

static void present_screen(void) {
	SDL_RenderClear(gfx_renderer);
	sdl_RenderTexture(gfx_renderer, gfx_texture, NULL, NULL);
	SDL_RenderPresent(gfx_renderer);
}

enum { PM_RESUME, PM_RESTART, PM_EXIT, PM_COUNT };
static const char *const pm_labels[PM_COUNT] = { "RESUME GAME", "RESTART GAME", "EXIT GAME" };

#define COL_WHITE     0xffffffff
#define COL_BLACK     0xff000000
#define COL_PANEL     0xff1c2448  /* dark blue */
#define COL_HIGHLIGHT 0xffffb020  /* yellow-orange */
#define COL_DIM       0xffa0a8c8

/* One option button. Selected: yellow-orange background and black text.
   Not selected: dark blue background, white border and text. */
static void draw_button(Uint8 *base, int pitch, int x, int y, int w, int h,
                        const char *label, bool sel) {
	fill_rect(base, pitch, x, y, w, h, sel ? COL_HIGHLIGHT : COL_WHITE);
	fill_rect(base, pitch, x + 2, y + 2, w - 4, h - 4, sel ? COL_HIGHLIGHT : COL_PANEL);
	draw_text_c(base, pitch, x + w / 2, y + (h - 7 * FONT_SCALE) / 2, label,
	            FONT_SCALE, sel ? COL_BLACK : COL_WHITE);
}

/* confirm < 0: the menu with the three options.
   confirm = PM_RESTART / PM_EXIT: "ARE YOU SURE?" for that option. */
static void draw_pause_menu(const Uint32 *saved, int selected, int confirm) {
	int pitch;
	Uint8 *base = lock_whole(&pitch);
	if (!base)
		return;
	/* Restore the game screen and darken it a little. */
	for (int y = 0; y < view_h; y++) {
		Uint32 *row = (Uint32 *)(base + y * pitch);
		const Uint32 *src = saved + y * view_w;
		for (int x = 0; x < view_w; x++)
			row[x] = 0xff000000 | ((src[x] >> 1) & 0x7f7f7f);
	}

	const int bh_btn = 7 * FONT_SCALE + 18;              /* button height */
	const int bw_btn = text_width("RESTART GAME", FONT_SCALE) + 48;
	const int gap = 14;
	int bw = bw_btn + 64;
	int bh = confirm < 0 ? PM_COUNT * bh_btn + (PM_COUNT - 1) * gap + 64
	                     : 7 * FONT_SCALE + bh_btn + 2 * 14 + 80;
	int bx = (view_w - bw) / 2, by = (view_h - bh) / 2;
	int cx = view_w / 2;

	fill_rect(base, pitch, bx, by, bw, bh, COL_WHITE);
	fill_rect(base, pitch, bx + 3, by + 3, bw - 6, bh - 6, COL_PANEL);

	if (confirm < 0) {
		int y = by + 32;
		for (int i = 0; i < PM_COUNT; i++, y += bh_btn + gap)
			draw_button(base, pitch, cx - bw_btn / 2, y, bw_btn, bh_btn,
			            pm_labels[i], i == selected);
	} else {
		int y = by + 26;
		draw_text_c(base, pitch, cx, y, "ARE YOU SURE?", FONT_SCALE, COL_WHITE);
		y += 7 * FONT_SCALE + 22;
		draw_button(base, pitch, cx - bw_btn / 2, y, bw_btn, bh_btn,
		            pm_labels[confirm], true);
		y += bh_btn + 18;
		draw_text_c(base, pitch, cx, y, "A: YES    B: NO", 2, COL_DIM);
	}
	SDL_UnlockTexture(gfx_texture);
	present_screen();
}

/* Shows the pause menu and waits for a choice. The game is paused meanwhile.
   D-pad chooses, A confirms; B or Menu resume the game (or, on the
   "ARE YOU SURE?" screen, go back to the menu). Returns PM_RESUME,
   PM_RESTART or PM_EXIT. */
RGDS_UNUSED static int run_pause_menu(void) {
	if (!gfx_texture || view_w <= 0 || view_h <= 0)
		return PM_RESUME;
	miyoo_cursor_hide();

	Uint32 *saved = malloc(view_w * view_h * 4);
	if (!saved)
		return PM_RESUME;
	int pitch;
	Uint8 *base = lock_whole(&pitch);
	if (!base) {
		free(saved);
		return PM_RESUME;
	}
	for (int y = 0; y < view_h; y++)
		memcpy(saved + y * view_w, base + y * pitch, view_w * 4);
	SDL_UnlockTexture(gfx_texture);

	int selected = PM_RESUME, confirm = -1, result = PM_RESUME;
	bool done = false;
	/* Buttons act on release, so the release doesn't leak into the game.
	   A release only counts if its press happened while the menu was open
	   (this also ignores the release of the Menu press that opened it). */
	bool pressed_a = false, pressed_b = false, pressed_menu = false;
	draw_pause_menu(saved, selected, confirm);

	while (!done) {
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			if (e.type != SDL_EVENT_KEY_DOWN && e.type != SDL_EVENT_KEY_UP)
				continue;
			bool down = e.type == SDL_EVENT_KEY_DOWN;
			switch (sdl_KeyboardEventKey(&e.key)) {
			case SDLK_UP: case SDLK_LEFT:
				if (down && confirm < 0) {
					selected = (selected + PM_COUNT - 1) % PM_COUNT;
					draw_pause_menu(saved, selected, confirm);
				}
				break;
			case SDLK_DOWN: case SDLK_RIGHT:
				if (down && confirm < 0) {
					selected = (selected + 1) % PM_COUNT;
					draw_pause_menu(saved, selected, confirm);
				}
				break;
			case SDLK_SPACE:  /* A */
#ifdef RGDS
			case SDLK_z:
#endif
				if (down) {
					pressed_a = true;
				} else if (pressed_a) {
					pressed_a = false;
					if (confirm >= 0) {            /* "ARE YOU SURE?" -> yes */
						result = confirm;
						done = true;
					} else if (selected == PM_RESUME) {
						done = true;
					} else {                       /* ask before restart/exit */
						confirm = selected;
						draw_pause_menu(saved, selected, confirm);
					}
				}
				break;
			case SDLK_LCTRL:  /* B */
#ifdef RGDS
			case SDLK_x:
#endif
			case SDLK_ESCAPE: /* Menu */
			{
				bool *pressed = sdl_KeyboardEventKey(&e.key) == SDLK_ESCAPE
				                ? &pressed_menu : &pressed_b;
				if (down) {
					*pressed = true;
				} else if (*pressed) {
					*pressed = false;
					if (confirm >= 0) {            /* back to the menu */
						confirm = -1;
						draw_pause_menu(saved, selected, confirm);
					} else {
						done = true;               /* resume */
					}
				}
				break;
			}
			default:
				break;
			}
		}
		SDL_Delay(16);
	}

	/* Put the game screen back as it was. */
	base = lock_whole(&pitch);
	if (base) {
		for (int y = 0; y < view_h; y++)
			memcpy(base + y * pitch, saved + y * view_w, view_w * 4);
		SDL_UnlockTexture(gfx_texture);
	}
	free(saved);
	if (result == PM_RESUME)
		present_screen();

	/* No button left "stuck" after the menu. */
	memset(dpad, 0, sizeof(dpad));
	l1_held = r1_held = false;
	event_reset_input_state();
	gfx_requestRedraw();
	return result;
}

/* ---------------------------------------------------------------------- */
/* Virtual mouse                                                          */
/* ---------------------------------------------------------------------- */

RGDS_UNUSED static bool pause_menu_requested;
static Uint32 move_since, last_tick;
static Uint32 last_present;
static bool in_update;

static void send_motion(void) {
	SDL_Event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = SDL_EVENT_MOUSE_MOTION;
	ev.motion.x = (int)cur_x;
	ev.motion.y = (int)cur_y;
	event_handle_event(&ev);
	gfx_requestRedraw();
}

static void send_button(int button, bool down) {
	ensure_position();
	SDL_Event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = down ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
	ev.button.button = button;
	ev.button.x = (int)cur_x;
	ev.button.y = (int)cur_y;
	ev.button.clicks = 1;
#if XSYSTEM35_SDL_VERSION == 2
	ev.button.state = down ? SDL_PRESSED : SDL_RELEASED;
#else
	ev.button.down = down;
#endif
	event_handle_event(&ev);
}

void miyoo_set_cursor(int x, int y) {
#ifdef RGDS
	if (stick_log_left > 0) {
		stick_log_left--;
		fprintf(stderr, "[rgds] the game moved the cursor: %.0f,%.0f -> %d,%d\n", cur_x, cur_y, x, y);
	}
#endif
	cur_x = x;
	cur_y = y;
	gfx_requestRedraw();
}

bool miyoo_handle_event(SDL_Event *e) {
#ifdef RGDS
	/* xsystem35 also reads the controller as a joystick. Here the buttons
	   already arrive as keys (gptokeyb), so the joystick is ignored to avoid
	   everything happening twice. */
	switch (e->type) {
	case SDL_EVENT_JOYSTICK_AXIS_MOTION:
		rgds_axis(e->jaxis.axis, e->jaxis.value);
		return true;
	case SDL_EVENT_JOYSTICK_ADDED:
	case SDL_EVENT_JOYSTICK_BALL_MOTION:
	case SDL_EVENT_JOYSTICK_HAT_MOTION:
	case SDL_EVENT_JOYSTICK_BUTTON_DOWN:
	case SDL_EVENT_JOYSTICK_BUTTON_UP:
		return true;
	default:
		break;
	}
#endif
	if (e->type != SDL_EVENT_KEY_DOWN && e->type != SDL_EVENT_KEY_UP)
		return false;
	bool down = e->type == SDL_EVENT_KEY_DOWN;
	int dir = -1;

	switch (sdl_KeyboardEventKey(&e->key)) {
	case SDLK_UP:    dir = DIR_UP;    break;
	case SDLK_DOWN:  dir = DIR_DOWN;  break;
	case SDLK_LEFT:  dir = DIR_LEFT;  break;
	case SDLK_RIGHT: dir = DIR_RIGHT; break;

	case SDLK_SPACE:   /* A */
#ifdef RGDS
	case SDLK_z:
#endif
		send_button(SDL_BUTTON_LEFT, down);
		return true;
	case SDLK_LCTRL:   /* B */
#ifdef RGDS
	case SDLK_x:
#endif
		send_button(SDL_BUTTON_RIGHT, down);
		return true;
	case SDLK_e:       /* L1 */
		l1_held = down;
		return true;
	case SDLK_t:       /* R1 */
		r1_held = down;
		return true;
	case SDLK_RCTRL:   /* Select */
#ifdef RGDS
	case SDLK_s:
#endif
		if (!down)
			msgskip_activate(!msgskip_isActivated());
		return true;
	case SDLK_ESCAPE:  /* Menu */
#ifndef RGDS
		/* The RG DS has no pause menu: Select + Start quits (gptokeyb). */
		if (down)
			pause_menu_requested = true;
#endif
		return true;
	default:
		return false;  /* Start (Enter) and the rest go on as keys */
	}

	dpad[dir] = down;
	/* With L1 held, the D-pad works as keyboard arrows. Releases are always
	   passed on, so no arrow key gets stuck. */
	if (l1_held || !down)
		return false;
	return true;
}

void miyoo_update(void) {
	Uint32 now = SDL_GetTicks();
	float dt = last_tick ? (now - last_tick) / 1000.0f : 0.0f;
	last_tick = now;
	if (dt > 0.1f)
		dt = 0.1f;

#ifndef RGDS
	if (pause_menu_requested && !in_update) {
		pause_menu_requested = false;
		int choice = run_pause_menu();
		if (choice != PM_RESUME) {
			/* nact_quit(true) restarts the game from the beginning, the
			   same as "Restart" in xsystem35's menu on a PC. */
			nact_quit(choice == PM_RESTART);
			return;
		}
		now = SDL_GetTicks();
		last_tick = now;
	}
#endif

#ifdef RGDS
	if (!stick_ready)
		rgds_stick_init();
	/* Reads the current axis state directly (besides the events). */
	if (stick_js)
		for (int a = 0; a < num_axes; a++)
			rgds_axis(a, SDL_JoystickGetAxis(stick_js, a));
#endif
	if (l1_held || in_update)
		return;
	int dx = dpad[DIR_RIGHT] - dpad[DIR_LEFT];
	int dy = dpad[DIR_DOWN] - dpad[DIR_UP];
#ifdef RGDS
	{
		/* Analog stick: speed proportional to tilt, in any direction (20% dead
		   zone in the center). It takes priority over the arrows: on the RG DS
		   Plus axes 2 and 3 mirror the stick's horizontal movement, and a gptokeyb
		   that turned them into arrows would push the cursor the other way. */
		float sx = stick_norm(stick_x), sy = stick_norm(stick_y);
		float mag = sqrtf(sx * sx + sy * sy);
		const float dz = 0.2f;
		if (mag > dz) {
			float k = ((mag > 1 ? 1 : mag) - dz) / (1 - dz);
			float speed = r1_held ? 900.0f : 60.0f + 640.0f * k * k;
			ensure_position();
			cur_x += sx / mag * speed * dt;
			cur_y += sy / mag * speed * dt;
			move_since = 0;
			if (stick_log_left > 0 && now - stick_log_last >= 150) {
				stick_log_last = now;
				stick_log_left--;
				fprintf(stderr, "[rgds] stick:");
				for (int a = 0; a < num_axes; a++)
					fprintf(stderr, " e%d=%d", a, axis_val[a]);
				fprintf(stderr, " | x=%.2f y=%.2f vel=%.0f | cursor %.0f,%.0f\n",
				        sx, sy, speed, cur_x, cur_y);
			}
			goto moved;
		}
	}
#endif
	if (!dx && !dy) {
		move_since = 0;
		return;
	}
	ensure_position();
#ifdef RGDS
	if (stick_log_left > 0 && now - stick_log_last >= 150) {
		stick_log_last = now;
		stick_log_left--;
		fprintf(stderr, "[rgds] arrows: dx=%d dy=%d | cursor %.0f,%.0f\n", dx, dy, cur_x, cur_y);
	}
#endif

	if (!move_since) {
		move_since = now;
		/* Short tap: move 1 pixel, for fine adjustment. */
		cur_x += dx;
		cur_y += dy;
	} else {
		/* Smoothly accelerates from 140 to 420 px/s over 0.5 s. */
		float held = (now - move_since) / 1000.0f;
		float t = held > 0.5f ? 1.0f : held / 0.5f;
		float speed = 140.0f + t * t * 280.0f;
		if (r1_held)
			speed = 800.0f;
		/* Diagonals at the same speed as straight lines. */
		if (dx && dy)
			speed *= 0.7071f;
		cur_x += dx * speed * dt;
		cur_y += dy * speed * dt;
	}

#ifdef RGDS
moved:;
#endif
	int w = 640, h = 480;
	gfx_getViewSize(&w, &h);
	if (cur_x < 0) cur_x = 0;
	if (cur_y < 0) cur_y = 0;
	if (cur_x > w - 1) cur_x = w - 1;
	if (cur_y > h - 1) cur_y = h - 1;
	send_motion();

	/* On a PC the cursor is drawn by the system, independently of the game.
	   Here it is part of the image, so if the game is reading buttons without
	   redrawing the screen, we redraw it ourselves (at most ~60 times/s). */
	if (now - last_present >= 16) {
		in_update = true;
		gfx_updateScreen();
		in_update = false;
	}
}

/* ---------------------------------------------------------------------- */
/* Frame pacing and measurement                                           */
/* ---------------------------------------------------------------------- */

static Uint64 frame_start, frame_copied;

/* Measurement while the cursor moves; written to log/run.log every 3 s
   (only with MIYOO_FPS_LOG=1).
   copy = cursor + SDL_RenderCopy (the Miyoo SDL copies the whole screen to
   GPU memory and rotates it 180 degrees); flip = SDL_RenderPresent. */
static struct {
	Uint64 t0, last;
	int frames;
	double copy_sum, copy_max, flip_sum, flip_max, gap_max;
} st;

static double ms_between(Uint64 a, Uint64 b) {
	return (b - a) * 1000.0 / SDL_GetPerformanceFrequency();
}

void miyoo_frame_begin(void) {
	frame_start = SDL_GetPerformanceCounter();
	frame_copied = 0;
}

void miyoo_frame_copied(void) {
	frame_copied = SDL_GetPerformanceCounter();
}

void miyoo_on_present(void) {
	last_present = SDL_GetTicks();
	/* Measurement is only on with MIYOO_FPS_LOG=1 (see launch.sh). */
	static int log_on = -1;
	if (log_on < 0) {
		const char *v = getenv("MIYOO_FPS_LOG");
		log_on = v && *v == '1';
	}
	if (!log_on || !move_since || !frame_start || !frame_copied) {
		st.t0 = 0;
		return;
	}
	Uint64 now = SDL_GetPerformanceCounter();
	if (!st.t0) {
		memset(&st, 0, sizeof(st));
		st.t0 = st.last = now;
		return;
	}
	double copy = ms_between(frame_start, frame_copied);
	double flip = ms_between(frame_copied, now);
	double gap = ms_between(st.last, now);
	st.last = now;
	st.frames++;
	st.copy_sum += copy;
	st.flip_sum += flip;
	if (copy > st.copy_max) st.copy_max = copy;
	if (flip > st.flip_max) st.flip_max = flip;
	if (gap > st.gap_max) st.gap_max = gap;
	double total = ms_between(st.t0, now);
	if (total >= 3000) {
		fprintf(stderr, "[miyoo] cursor: %.1f frames/s | copy %.1f ms (max %.1f) | flip %.1f ms (max %.1f) | longest gap %.1f ms\n",
		        st.frames * 1000.0 / total, st.copy_sum / st.frames, st.copy_max,
		        st.flip_sum / st.frames, st.flip_max, st.gap_max);
		st.t0 = 0;
	}
}

void miyoo_wait_frame(void) {
	/* Aims at 60 frames/s with a fixed rhythm: sleeps only for the time left
	   until the next frame (the original slept 16 ms AFTER drawing). If the
	   frame is late, it goes on without sleeping. If it is very late (game
	   loading something), the count restarts. */
	static Uint64 next;
	Uint64 freq = SDL_GetPerformanceFrequency();
	Uint64 period = freq / 60;
	Uint64 now = SDL_GetPerformanceCounter();
	if (!next || now > next + period * 3)
		next = now;
	next += period;
	if (next > now) {
		Uint32 ms = (Uint32)((next - now) * 1000 / freq);
		if (ms > 0)
			SDL_Delay(ms);
	}
}

#endif /* MIYOO_MINI */
