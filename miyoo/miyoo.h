/* miyoo.h  Controles e cursor para o Miyoo Mini (OnionOS) */
#ifndef __MIYOO_H__
#define __MIYOO_H__

#ifdef MIYOO_MINI
#include "sdl_compat.h"
#include "portab.h"

/* Converte botoes em mouse virtual. Retorna true se consumiu o evento. */
bool miyoo_handle_event(SDL_Event *e);
/* Chamado a cada leitura de eventos: move o cursor e trata "segurar Menu". */
void miyoo_update(void);
/* Posiciona o cursor (quando o jogo "teleporta" o mouse). */
void miyoo_set_cursor(int x, int y);

/* Cursor desenhado por software na textura da tela. */
void miyoo_cursor_show(void);
void miyoo_cursor_hide(void);
void miyoo_cursor_reset(void);
/* Efeitos de transicao montados por software. */
SDL_Texture *miyoo_texture_from_surface(SDL_Renderer *renderer, SDL_Surface *src);
void miyoo_destroy_texture(SDL_Texture *tx);
void miyoo_comp_begin(void);
bool miyoo_comp_draw(SDL_Texture *tx, const SDL_Rect *srcrect, const SDL_Rect *dstrect);
void miyoo_comp_end(void);
/* Avisa que a tela acabou de ser atualizada. */
void miyoo_on_present(void);
#endif

#endif
