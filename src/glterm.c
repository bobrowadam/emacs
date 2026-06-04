/* glterm.c --- OpenGL gfx driver for GNU Emacs (SKELETON, NOT IMPLEMENTED).
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


   This file is the prepared integration point: the whole
   redisplay drawing policy already lives in gfxterm.c and renders
   exclusively through the `struct gfx_driver' vtable (gfxdrv.h), so an
   OpenGL backend for GNU/Linux and Windows only needs to implement the
   ops below -- none of the pixel-parity logic has to be redone.

   To bring this to life:

   1. configure.ac: make --with-gl real (it currently errors out as
      reserved): check for EGL/GLX + GL headers, set MTL_OBJ-equivalent
      vars (GL_OBJ="gfxterm.o glterm.o"), define HAVE_GFX_GL.

   2. Per-frame state (the analogue of MtlFrameData): a GL context bound
      to the frame's native window, a persistent FBO-backed RGBA texture
      the size of the frame ("static texture": content must survive
      across render cycles -- LOAD, not clear), a scratch texture for
      overlapping copy_region, and small shader programs equivalent to
      mtl_shaders: solid rect, R8-atlas glyph (with the coverage gamma
      pow(c, 0.82) weight match!), RGBA textured quad.

   3. Glyph rasterization: FreeType/cairo via the frame's font backend
      (struct font * -> ftcrfont).  Fill `struct gfx_glyph' exactly like
      mtl_rasterize_glyph_id does: bearing_y = bitmap_top (distance from
      box top to baseline -- mind the off-by-one history in mtlterm.m),
      advance_x from the font, atlas packed row by row.

   4. Render cycle: begin_frame binds the FBO; end_frame (present_p)
      flushes; present blits the FBO texture to the window (swap).  Honor
      the deferred-present contract (gfxdrv.h) or the clear-only cycles
      and the immediate-draw paths WILL flash like they once did on
      Metal.

   5. The reference implementation for every op is mtl_drv_* in
      mtlterm.m.  */

#include <config.h>

#ifdef HAVE_GFX_GL  /* Never defined yet: --with-gl is reserved.  */

#include "lisp.h"
#include "dispextern.h"
#include "frame.h"
#include "gfxdrv.h"

#error "The OpenGL gfx driver is not implemented yet (see this file's header)."

/* The vtable to fill in, mirroring mtl_gfx_driver:

static struct gfx_driver gl_gfx_driver =
{
  .name                 = "opengl",
  .frame_ready          = gl_drv_frame_ready,
  .begin_frame          = gl_drv_begin_frame,
  .end_frame            = gl_drv_end_frame,
  .present              = gl_drv_present,
  .in_cycle             = gl_drv_in_cycle,
  .pending_present      = gl_drv_pending_present,
  .clip_to_glyph_string = gl_drv_clip_to_glyph_string,
  .clear_clip           = gl_drv_clear_clip,
  .fill_rect            = gl_drv_fill_rect,
  .copy_region          = gl_drv_copy_region,
  .font_ready_p         = gl_drv_font_ready_p,
  .get_glyph            = gl_drv_get_glyph,
  .draw_glyph           = gl_drv_draw_glyph,
  .color_font_p         = gl_drv_color_font_p,
  .draw_color_glyph     = gl_drv_draw_color_glyph,
  .warm_glyph_cache     = gl_drv_warm_glyph_cache,
  .image_texture        = gl_drv_image_texture,
  .draw_texture         = gl_drv_draw_texture,
  .draw_bitmap          = gl_drv_draw_bitmap,
  .relief_colors        = NULL,  -- optional: gfxterm falls back to a
                                    plain shade blend, which is correct
                                    on platforms without appearance-
                                    dynamic colors
  .frame_foreground     = gl_drv_frame_foreground,
  .frame_background     = gl_drv_frame_background,
  .cursor_color         = gl_drv_cursor_color,
  .note_cursor          = NULL,  -- optional: no cursor animations
};

   and at frame-enable time:  gfx_drv = &gl_gfx_driver;  */

#endif /* HAVE_GFX_GL */
