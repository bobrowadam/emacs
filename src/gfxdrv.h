/* gfxdrv.h --- GPU drawing-driver abstraction for GNU Emacs.
   Copyright (C) 2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.


   The redisplay-facing drawing POLICY (gfxterm.c) is platform
   neutral and calls into a small driver vtable for every pixel that hits
   the GPU.  Today the only driver is Metal (mtlterm.m, macOS); an OpenGL
   driver for GNU/Linux and Windows can be added later by implementing
   `struct gfx_driver' and setting `gfx_drv' -- no redisplay logic needs
   to be rewritten (it took long enough to make pixel-perfect once).

   CONTRACT (read before implementing a driver):

   - Coordinates: logical pixels, top-left origin, the same space the
     redisplay engine uses (struct glyph_string `x'/`y'/`ybase', window
     boxes, frame pixel sizes).  HiDPI scaling is the driver's business.

   - Colors: unsigned long 0x00RRGGBB, exactly what `struct face' carries
     in `foreground'/`background'.

   - Render cycle: drawing between begin_frame and end_frame accumulates
     into a persistent frame-sized render target ("static texture") whose
     content SURVIVES across cycles -- the engine repaints only dirty
     regions, so the driver must load, not clear, the previous content
     (clear only a brand-new or resized target).  end_frame (present_p =
     true) commits and presents; with present_p false it commits but only
     marks a present as pending (deferred presents are how the policy
     avoids flashing intermediate states: immediate draws outside the
     cycle, and clear-only cycles on garbaged frames).  present () shows
     the current target content on screen and clears the pending flag.

   - The policy may call any drawing op only while in_cycle () is true;
     it opens a self-contained cycle for the engine's outside-the-cycle
     draws itself (see gfx_draw_glyph_string).

   - Glyphs: get_glyph rasterizes (and caches) GLYPH-ID -- a font-backend
     glyph index, NOT a character -- of FONT into the driver's atlas and
     returns its metrics; draw_glyph paints it with the top-left of the
     glyph box at (x, ybase - bearing_y).  Fonts arrive as the engine's
     `struct font *'; the driver extracts its native handle (CTFont on
     macOS, FT_Face/cairo on the future GL driver).

   - Textures (images, video frames): opaque `void *' handles owned by
     the driver, drawn as quads with a UV subrect (slices) and alpha.

   The Lisp-visible extras (inline video, frame capture) are platform
   capabilities, not part of this vtable; see mtlterm.h.  */

#ifndef EMACS_GFXDRV_H
#define EMACS_GFXDRV_H

#include <stdbool.h>

struct frame;
struct window;
struct font;
struct image;
struct glyph_string;
struct glyph_row;
struct draw_fringe_bitmap_params;
struct run;

/* One rasterized glyph in the driver's atlas.  bearing_y is the distance
   from the glyph box top to the baseline; advance_x the natural pen
   advance (used by composition runs; grid text advances by the engine's
   integer pixel_width instead).  */
struct gfx_glyph
{
  unsigned long long cache_key;
  int  atlas_x, atlas_y;
  int  width, height;
  int  bearing_x, bearing_y;
  float advance_x;
  bool valid;
};

struct gfx_driver
{
  const char *name;

  /* Non-zero once the driver has per-frame data for F (i.e. the GPU
     backend was enabled on it); every other op may assume it.  */
  bool (*frame_ready) (struct frame *f);

  /* --- Render cycle (see CONTRACT above) --- */
  void (*begin_frame) (struct frame *f);
  void (*end_frame) (struct frame *f, bool present_p);
  void (*present) (struct frame *f);
  bool (*in_cycle) (struct frame *f);
  bool (*pending_present) (struct frame *f);

  /* --- Clipping --- */
  /* Clip subsequent draws to the engine's clip rect for S (the native
     get_glyph_string_clip_rect result; kept driver-side so the policy
     never touches NativeRectangle).  */
  void (*clip_to_glyph_string) (struct glyph_string *s);
  void (*clear_clip) (struct frame *f);

  /* --- Primitives --- */
  void (*fill_rect) (struct frame *f, int x, int y, int w, int h,
                     unsigned long color);
  /* Copy the (X, Y, W, H) region of the render target to (DST_X, DST_Y).
     Source and destination may overlap (scroll_run, shift-for-insert);
     the driver resolves that (e.g. bouncing through a scratch target).  */
  void (*copy_region) (struct frame *f, int x, int y, int w, int h,
                       int dst_x, int dst_y);

  /* --- Glyphs --- */
  bool (*font_ready_p) (struct font *font);
  struct gfx_glyph *(*get_glyph) (struct font *font, unsigned int glyph_id);
  void (*draw_glyph) (struct frame *f, struct gfx_glyph *g,
                      float x, float ybase, unsigned long color);
  /* Color fonts (e.g. Apple Color Emoji) bypass the coverage atlas.  */
  bool (*color_font_p) (struct font *font);
  /* Draw a color glyph; returns its advance (0 if missing/unsupported).  */
  float (*draw_color_glyph) (struct frame *f, struct font *font,
                             unsigned int glyph_id, float x, float ybase);
  /* Pre-rasterize the printable ASCII of F's default face.  */
  void (*warm_glyph_cache) (struct frame *f);

  /* --- Images --- */
  /* Cached texture for IMG at its display size; W and H receive the
     texture dimensions (for slice UVs).  NULL when the image has no
     pixmap.  */
  void *(*image_texture) (struct frame *f, struct image *img,
                          int *w, int *h);
  void (*draw_texture) (struct frame *f, void *texture,
                        float x, float y, float w, float h,
                        float u0, float v0, float u1, float v1,
                        float alpha);

  /* --- Fringe bitmaps --- */
  /* Draw the engine's MSB-first unsigned-short bitmap rows as COLOR.  */
  void (*draw_bitmap) (struct frame *f, unsigned short *bits, int dh,
                       int wd, int h, int x, int y, unsigned long color);

  /* --- Colors --- */
  /* Relief light/dark for S's face: platform-appearance aware (on macOS
     NSColor highlight/shadowWithLevel: shift with dark mode; a plain
     blend toward white/black does NOT match what the native backend
     renders).  */
  void (*relief_colors) (struct glyph_string *s, unsigned long *light,
                         unsigned long *dark);
  unsigned long (*frame_foreground) (struct frame *f);
  unsigned long (*frame_background) (struct frame *f);
  unsigned long (*cursor_color) (struct frame *f);

  /* --- Cursor animation hint --- */
  /* Tell the driver where the cursor landed.  Returns true when an
     animated cursor overlay will draw it (the policy then skips the
     static cursor to avoid doubling); false for plain static drawing.  */
  bool (*note_cursor) (struct frame *f, int x, int y, int w, int h,
                       unsigned long color);
};

/* The active driver (set by the platform backend before any policy call;
   Metal sets it in mtl_setup_frame).  One driver per process.  */
extern struct gfx_driver *gfx_drv;

/* -----------------------------------------------------------------------
   Platform-neutral drawing policy (gfxterm.c): the redisplay_interface /
   terminal hook implementations shared by every gfx driver.
   ----------------------------------------------------------------------- */

extern void gfx_draw_glyph_string (struct glyph_string *s);
extern void gfx_clear_frame (struct frame *f);
extern void gfx_clear_frame_area (struct frame *f, int x, int y,
                                  int width, int height);
extern void gfx_clear_under_internal_border (struct frame *f);
extern void gfx_flush_display (struct frame *f);
extern void gfx_update_begin (struct frame *f);
extern void gfx_update_end (struct frame *f);
extern void gfx_frame_up_to_date (struct frame *f);
extern void gfx_scroll_run (struct window *w, struct run *run);
extern void gfx_after_update_window_line (struct window *w,
                                          struct glyph_row *desired_row);
extern void gfx_draw_window_cursor (struct window *w,
                                    struct glyph_row *row, int x, int y,
                                    enum text_cursor_kinds cursor_type,
                                    int cursor_width, bool on_p,
                                    bool active_p);
extern void gfx_draw_vertical_window_border (struct window *w,
                                             int x, int y0, int y1);
extern void gfx_draw_window_divider (struct window *w,
                                     int x0, int x1, int y0, int y1);
extern void gfx_draw_fringe_bitmap (struct window *w, struct glyph_row *row,
                                    struct draw_fringe_bitmap_params *p);
extern void gfx_define_fringe_bitmap (int which, unsigned short *bits,
                                      int h, int wd);
extern void gfx_destroy_fringe_bitmap (int which);
extern void gfx_compute_glyph_string_overhangs (struct glyph_string *s);
extern void gfx_shift_glyphs_for_insert (struct frame *f, int x, int y,
                                         int w, int h, int by);
extern void gfx_warm_glyph_cache (struct frame *f);

/* Queue a rect to be cleared to the frame background at the start of the
   next render cycle (scroll-bar gutters: their hooks run in the layout
   phase, before any cycle is open).  */
extern void gfx_queue_clear (struct frame *f, int x, int y, int w, int h);

/* Drop the policy's per-frame bookkeeping (call from the platform's
   frame-resource teardown).  */
extern void gfx_free_frame_state (struct frame *f);

/* Diagnostic counters (read by mtl-draw-stats).  */
extern int mtl_dgs_call_count;
extern int mtl_dgs_nofd_count;
extern int mtl_dgs_nofont_count;
extern int mtl_dgs_drawn_count;

#endif /* EMACS_GFXDRV_H */
