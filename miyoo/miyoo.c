/*
 * miyoo.c  Controles e cursor para o Miyoo Mini (OnionOS)
 *
 * O SDL2 do Miyoo Mini (steward-fu/sdl2) entrega os botoes como teclas e
 * nao tem mouse nem cursor. Este arquivo transforma os botoes em um mouse
 * virtual e desenha um cursor por software na textura da tela.
 *
 * Botoes do Miyoo Mini -> teclas que o SDL entrega (keymon do OnionOS):
 *   D-pad: setas      A: espaco      B: Ctrl esq.   X: Shift esq.
 *   Y: Alt esq.       L1: E          R1: T          L2: Tab
 *   R2: Backspace     Select: Ctrl dir.   Start: Enter   Menu: Esc
 *
 * Mapeamento no jogo:
 *   D-pad ............ move o cursor (segure para acelerar)
 *   R1 (segurar) ..... cursor rapido
 *   L1 + D-pad ....... setas do teclado (menus que usam teclado)
 *   A ................ clique esquerdo
 *   B ................ clique direito (cancelar / menu do jogo)
 *   Start ............ Enter
 *   Select ........... liga/desliga o pulo de mensagens (como F1)
 *   Menu ............. pergunta se quer sair do jogo
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "config.h"

#ifdef MIYOO_MINI

#include <stdlib.h>
#include <string.h>
#include "sdl_compat.h"

#include "portab.h"
#include "event.h"
#include "gfx.h"
#include "gfx_private.h"
#include "nact.h"
#include "msgskip.h"
#include "miyoo.h"

/* ---------------------------------------------------------------------- */
/* Cursor por software                                                     */
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

/* O render do SDL do Miyoo ignora a posicao do retangulo em
   SDL_LockTexture (sempre devolve o inicio da textura). Por isso travamos
   a textura inteira e calculamos o deslocamento aqui. Cada trava custa uma
   copia da tela toda, entao fazemos no maximo uma por quadro. */
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

	/* Cursor ja desenhado no mesmo lugar: nada a fazer. */
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
					row[x] = 0xff000000;  /* preto (XRGB8888) */
				else if (c == '.')
					row[x] = 0xffffffff;  /* branco */
			}
		}
		drawn = true;
		drawn_rect = r;
	}
	SDL_UnlockTexture(gfx_texture);
}

/* ---------------------------------------------------------------------- */
/* Efeitos de transicao feitos por software                                */
/* ---------------------------------------------------------------------- */

/* O render do SDL do Miyoo desenha errado qualquer textura com
   transparencia (a imagem sai espremida e duplicada lado a lado). Por isso,
   durante os efeitos, montamos cada quadro na CPU (copiar, misturar com
   transparencia, escalar) e mandamos para a tela uma unica imagem opaca,
   do mesmo jeito que a tela normal do jogo, que funciona. */

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

/* Cria a textura e guarda uma copia dos pixels (XRGB8888) para o
   compositor por software. */
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
	SDL_DestroySurface(conv);  /* tabela cheia: sem copia, efeito vira corte */
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

static Uint32 *fb, *snap;      /* quadro montado / copia da tela do jogo */
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

/* ---------------------------------------------------------------------- */
/* Dialogo de saida ("Do you want to leave?")                              */
/* ---------------------------------------------------------------------- */

/* O menu do proprio xsystem35 usa uma caixa de dialogo do sistema, que nao
   existe no Miyoo. Este dialogo e desenhado direto na tela, com uma fonte
   5x7 embutida (so com as letras necessarias). */

static const struct { char c; Uint8 rows[7]; } glyphs[] = {
	{'D', {0x1e,0x11,0x11,0x11,0x11,0x11,0x1e}},
	{'N', {0x11,0x19,0x15,0x13,0x11,0x11,0x11}},
	{'Y', {0x11,0x11,0x0a,0x04,0x04,0x04,0x04}},
	{'a', {0x00,0x00,0x0e,0x01,0x0f,0x11,0x0f}},
	{'e', {0x00,0x00,0x0e,0x11,0x1f,0x10,0x0e}},
	{'l', {0x0c,0x04,0x04,0x04,0x04,0x04,0x0e}},
	{'n', {0x00,0x00,0x16,0x19,0x11,0x11,0x11}},
	{'o', {0x00,0x00,0x0e,0x11,0x11,0x11,0x0e}},
	{'s', {0x00,0x00,0x0f,0x10,0x0e,0x01,0x1e}},
	{'t', {0x08,0x08,0x1c,0x08,0x08,0x09,0x06}},
	{'u', {0x00,0x00,0x11,0x11,0x11,0x13,0x0d}},
	{'v', {0x00,0x00,0x11,0x11,0x11,0x0a,0x04}},
	{'w', {0x00,0x00,0x11,0x11,0x15,0x15,0x0a}},
	{'y', {0x00,0x00,0x11,0x11,0x0f,0x01,0x0e}},
	{'?', {0x0e,0x11,0x01,0x02,0x04,0x00,0x04}},
};

#define FONT_SCALE 3
#define GLYPH_ADV (6 * FONT_SCALE)

static const Uint8 *glyph_rows(char c) {
	for (size_t i = 0; i < sizeof(glyphs) / sizeof(glyphs[0]); i++)
		if (glyphs[i].c == c)
			return glyphs[i].rows;
	return NULL;
}

static int text_width(const char *t) {
	return (int)strlen(t) * GLYPH_ADV - FONT_SCALE;
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

static void draw_text(Uint8 *base, int pitch, int x, int y, const char *t, Uint32 color) {
	for (; *t; t++, x += GLYPH_ADV) {
		const Uint8 *rows = glyph_rows(*t);
		if (!rows)
			continue;  /* espaco */
		for (int r = 0; r < 7; r++)
			for (int c = 0; c < 5; c++)
				if (rows[r] & (0x10 >> c))
					fill_rect(base, pitch, x + c * FONT_SCALE, y + r * FONT_SCALE,
					          FONT_SCALE, FONT_SCALE, color);
	}
}

static void present_screen(void) {
	SDL_RenderClear(gfx_renderer);
	sdl_RenderTexture(gfx_renderer, gfx_texture, NULL, NULL);
	SDL_RenderPresent(gfx_renderer);
}

static void draw_quit_dialog(const Uint32 *saved, int selected) {
	int pitch;
	Uint8 *base = lock_whole(&pitch);
	if (!base)
		return;
	/* Restaura a tela do jogo e escurece um pouco o fundo. */
	for (int y = 0; y < view_h; y++) {
		Uint32 *row = (Uint32 *)(base + y * pitch);
		const Uint32 *src = saved + y * view_w;
		for (int x = 0; x < view_w; x++)
			row[x] = 0xff000000 | ((src[x] >> 1) & 0x7f7f7f);
	}

	const char *msg = "Do you want to leave?";
	int bw = text_width(msg) + 48, bh = 7 * FONT_SCALE * 2 + 72;
	int bx = (view_w - bw) / 2, by = (view_h - bh) / 2;
	const Uint32 white = 0xffffffff, black = 0xff000000, panel = 0xff1c2448;
	const Uint32 highlight = 0xffffb020;  /* amarelo-alaranjado */

	fill_rect(base, pitch, bx, by, bw, bh, white);
	fill_rect(base, pitch, bx + 3, by + 3, bw - 6, bh - 6, panel);
	draw_text(base, pitch, bx + 24, by + 20, msg, white);

	const char *opts[2] = { "Yes", "No" };
	int ow = 4 * GLYPH_ADV + 24, oh = 7 * FONT_SCALE + 16;
	int oy = by + bh - oh - 16;
	for (int i = 0; i < 2; i++) {
		int ox = bx + bw / 2 + (i == 0 ? -ow - 16 : 16);
		bool sel = i == selected;
		/* Selecionada: fundo amarelo-alaranjado e texto preto.
		   Nao selecionada: fundo azul-escuro, borda e texto brancos. */
		fill_rect(base, pitch, ox, oy, ow, oh, sel ? highlight : white);
		fill_rect(base, pitch, ox + 2, oy + 2, ow - 4, oh - 4, sel ? highlight : panel);
		int tx = ox + (ow - text_width(opts[i])) / 2;
		draw_text(base, pitch, tx, oy + 8, opts[i], sel ? black : white);
	}
	SDL_UnlockTexture(gfx_texture);
	present_screen();
}

/* Mostra o dialogo e espera a resposta. O jogo fica pausado enquanto isso.
   D-pad escolhe, A confirma, B ou Menu cancelam. Retorna true para sair. */
static bool run_quit_dialog(void) {
	if (!gfx_texture || view_w <= 0 || view_h <= 0)
		return false;
	miyoo_cursor_hide();

	Uint32 *saved = malloc(view_w * view_h * 4);
	if (!saved)
		return false;
	int pitch;
	Uint8 *base = lock_whole(&pitch);
	if (!base) {
		free(saved);
		return false;
	}
	for (int y = 0; y < view_h; y++)
		memcpy(saved + y * view_w, base + y * pitch, view_w * 4);
	SDL_UnlockTexture(gfx_texture);

	int selected = 1;  /* "No" por padrao, para nao sair sem querer */
	bool result = false, done = false;
	bool pressed_a = false, pressed_b = false, pressed_menu = false;
	draw_quit_dialog(saved, selected);

	while (!done) {
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			if (e.type != SDL_EVENT_KEY_DOWN && e.type != SDL_EVENT_KEY_UP)
				continue;
			bool down = e.type == SDL_EVENT_KEY_DOWN;
			switch (sdl_KeyboardEventKey(&e.key)) {
			case SDLK_LEFT: case SDLK_RIGHT: case SDLK_UP: case SDLK_DOWN:
				if (down) {
					selected = !selected;
					draw_quit_dialog(saved, selected);
				}
				break;
			/* Age ao soltar o botao, para o "soltar" nao vazar para o jogo.
			   O soltar do Menu que abriu o dialogo e ignorado. */
			case SDLK_SPACE:  /* A */
				if (down)
					pressed_a = true;
				else if (pressed_a) {
					result = selected == 0;
					done = true;
				}
				break;
			case SDLK_LCTRL:  /* B */
				if (down)
					pressed_b = true;
				else if (pressed_b)
					done = true;
				break;
			case SDLK_ESCAPE: /* Menu */
				if (down)
					pressed_menu = true;
				else if (pressed_menu)
					done = true;
				break;
			default:
				break;
			}
		}
		SDL_Delay(16);
	}

	/* Devolve a tela do jogo como estava. */
	base = lock_whole(&pitch);
	if (base) {
		for (int y = 0; y < view_h; y++)
			memcpy(base + y * pitch, saved + y * view_w, view_w * 4);
		SDL_UnlockTexture(gfx_texture);
	}
	free(saved);
	if (!result)
		present_screen();

	/* Nada de botao "preso" depois do dialogo. */
	memset(dpad, 0, sizeof(dpad));
	l1_held = r1_held = false;
	event_reset_input_state();
	gfx_requestRedraw();
	return result;
}

/* ---------------------------------------------------------------------- */
/* Mouse virtual                                                           */
/* ---------------------------------------------------------------------- */

static bool quit_dialog_requested;
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
	cur_x = x;
	cur_y = y;
	gfx_requestRedraw();
}

bool miyoo_handle_event(SDL_Event *e) {
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
		send_button(SDL_BUTTON_LEFT, down);
		return true;
	case SDLK_LCTRL:   /* B */
		send_button(SDL_BUTTON_RIGHT, down);
		return true;
	case SDLK_e:       /* L1 */
		l1_held = down;
		return true;
	case SDLK_t:       /* R1 */
		r1_held = down;
		return true;
	case SDLK_RCTRL:   /* Select */
		if (!down)
			msgskip_activate(!msgskip_isActivated());
		return true;
	case SDLK_ESCAPE:  /* Menu */
		if (down)
			quit_dialog_requested = true;
		return true;
	default:
		return false;  /* Start (Enter) e os demais seguem como teclas */
	}

	dpad[dir] = down;
	/* Com L1 segurado, o D-pad funciona como setas do teclado. Soltar o
	   botao sempre passa adiante, para nenhuma seta ficar "presa". */
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

	if (quit_dialog_requested && !in_update) {
		quit_dialog_requested = false;
		if (run_quit_dialog()) {
			nact_quit(false);
			return;
		}
		now = SDL_GetTicks();
		last_tick = now;
	}

	if (l1_held || in_update)
		return;
	int dx = dpad[DIR_RIGHT] - dpad[DIR_LEFT];
	int dy = dpad[DIR_DOWN] - dpad[DIR_UP];
	if (!dx && !dy) {
		move_since = 0;
		return;
	}
	ensure_position();

	if (!move_since) {
		move_since = now;
		/* Toque curto: anda 1 pixel, para ajuste fino. */
		cur_x += dx;
		cur_y += dy;
	} else {
		/* Acelera suavemente de 140 a 420 px/s em 0,5 s. */
		float held = (now - move_since) / 1000.0f;
		float t = held > 0.5f ? 1.0f : held / 0.5f;
		float speed = 140.0f + t * t * 280.0f;
		if (r1_held)
			speed = 800.0f;
		/* Diagonal com a mesma velocidade das retas. */
		if (dx && dy)
			speed *= 0.7071f;
		cur_x += dx * speed * dt;
		cur_y += dy * speed * dt;
	}

	int w = 640, h = 480;
	gfx_getViewSize(&w, &h);
	if (cur_x < 0) cur_x = 0;
	if (cur_y < 0) cur_y = 0;
	if (cur_x > w - 1) cur_x = w - 1;
	if (cur_y > h - 1) cur_y = h - 1;
	send_motion();

	/* No PC o cursor e desenhado pelo sistema, independente do jogo. Aqui
	   ele faz parte da imagem, entao, se o jogo esta lendo os botoes sem
	   redesenhar a tela, redesenhamos nos mesmos (no maximo ~60 vezes/s). */
	if (now - last_present >= 16) {
		in_update = true;
		gfx_updateScreen();
		in_update = false;
	}
}

void miyoo_on_present(void) {
	last_present = SDL_GetTicks();
}

#endif /* MIYOO_MINI */
