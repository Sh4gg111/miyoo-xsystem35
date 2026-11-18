/* miyoo.h  Controls and cursor for the Miyoo Mini (OnionOS) */
#ifndef __MIYOO_H__
#define __MIYOO_H__

#ifdef MIYOO_MINI
#include "sdl_compat.h"
#include "portab.h"

/* Turns buttons into a virtual mouse. Returns true if it consumed the event. */
bool miyoo_handle_event(SDL_Event *e);
/* Called on every event poll: moves the cursor and handles the Menu button. */
void miyoo_update(void);
/* Moves the cursor (when the game warps the mouse). */
void miyoo_set_cursor(int x, int y);

/* Software cursor drawn on the screen texture. */
void miyoo_cursor_show(void);
void miyoo_cursor_hide(void);
void miyoo_cursor_reset(void);
/* Transition effects composited in software. */
SDL_Texture *miyoo_texture_from_surface(SDL_Renderer *renderer, SDL_Surface *src);
void miyoo_destroy_texture(SDL_Texture *tx);
void miyoo_comp_begin(void);
bool miyoo_comp_draw(SDL_Texture *tx, const SDL_Rect *srcrect, const SDL_Rect *dstrect);
void miyoo_comp_end(void);
/* Start and end of each screen update. */
void miyoo_frame_begin(void);
void miyoo_frame_copied(void);
void miyoo_on_present(void);
/* Waits for the next frame (replaces the SDL_Delay(16) of "vsync"). */
void miyoo_wait_frame(void);
#endif

#endif
