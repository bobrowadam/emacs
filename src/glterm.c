/* glterm.c --- OpenGL (EGL + OpenGL ES) gfx driver for GNU Emacs.
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


   This is the GNU/Linux counterpart of mtlterm.m: the cross-platform
   drawing policy lives in gfxterm.c and renders exclusively through the
   `struct gfx_driver' vtable (gfxdrv.h); this file implements that vtable
   on top of EGL + OpenGL ES 3, with the glyph atlas rasterized by
   FreeType (reached through the cairo scaled font of the ftcr backend).

   The reference for every op is the matching mtl_drv_* in mtlterm.m.  The
   render target is a frame-sized RGBA8 texture in an FBO (the "static
   texture": its content survives across cycles -- LOAD, not clear).  All
   drawing happens off screen into that FBO; gl_capture_frame reads it back
   for the pixel-parity harness.  On-screen present (gl_present_to_window)
   blits the FBO to the frame's X window through an EGL window surface and
   swaps, on the same deferred-present schedule as the Metal driver: the
   EGL display is brought up on the X11 platform when an X connection
   exists (window surfaces need it) and falls back to surfaceless only for
   a frameless batch run.

   Grayscale glyphs go through an R8 coverage atlas; color glyphs (emoji)
   are rasterized through cairo (which scales the bitmap strike to the
   laid-out size) into premultiplied RGBA textures, drawn with the image
   program -- see gl_color_glyph_get.

   Two structural optimizations shape the draw path.  Glyphs and solid
   rectangles share one submission-ordered vertex batch (the rects sample
   a white block reserved in the atlas) whose quads are clipped on the
   CPU at queue time, so a whole redraw flushes as a handful of draw
   calls; see gl_batch_append.  And the present blits only what the back
   buffer is actually missing, derived from EGL_EXT_buffer_age plus a
   per-swap record of dirty regions, handing the compositor the damaged
   boxes through eglSwapBuffersWithDamage; see gl_present_to_window.  */

#include <config.h>

#ifdef HAVE_GFX_GL

#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#ifdef HAVE_GSTREAMER
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#endif

#include <cairo.h>
#include <cairo-ft.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#include "lisp.h"
#include "dispextern.h"
#include "frame.h"
#include "blockinput.h"
#include "termchar.h"
#include "window.h"
#include "character.h"
#include "font.h"
#include "ftfont.h"
#include "composite.h"
/* Platform terminal headers: PGTK (GTK/GDK) or X11.  They define mutually
   exclusive frame macros (FRAME_X_WINDOW, FRAME_GDK_WINDOW, ...) and must
   not be included together.  */
#ifdef HAVE_PGTK
# include "pgtkterm.h"
# include <gtk/gtk.h>
# ifdef GDK_WINDOWING_WAYLAND
#  include <gdk/gdkwayland.h>
#  ifdef HAVE_WAYLAND_EGL
#   include <wayland-egl.h>
#  endif
# endif
/* gdkx.h is intentionally NOT included: it brings in X11/Xlib.h which
   conflicts with pgtkgui.h's own X11-compatible typedefs (Window, Display,
   XRectangle).  Instead we use dlsym at runtime to obtain the GDK X11
   helpers (gdk_x11_display_get_xdisplay, gdk_x11_window_get_xid), avoiding
   the header conflict while still enabling on-screen present for PGTK+X11.  */
#else
# include "xterm.h"
#endif
#include "gfxdrv.h"
#include "glterm.h"

/* ------------------------------------------------------------------ */
/* Color helper: the policy hands us `unsigned long' face pixels.  On a
   TrueColor X visual (the only kind in practice) the pixel packs the
   channels; we treat it as 0x00RRGGBB, matching the gfxdrv.h contract.
   TODO: decode through the frame's visual masks for exotic visuals.  */
static void
gl_unpack_color (unsigned long c, float rgba[4])
{
  rgba[0] = ((c >> 16) & 0xff) / 255.0f;
  rgba[1] = ((c >> 8) & 0xff) / 255.0f;
  rgba[2] = (c & 0xff) / 255.0f;
  rgba[3] = 1.0f;
}

/* ------------------------------------------------------------------ */
/* GLES3 shaders (ports of the MSL in mtlterm.m).  Top-left-origin pixel
   space -> NDC; the glyph shader applies the pow(coverage, 0.82) weight
   that matches the native (cairo) text ink.  */

static const char *VS_RECT =
  "#version 300 es\n"
  "layout(location=0) in vec2 a_pos;\n"
  "layout(location=2) in vec4 a_color;\n"
  "uniform vec2 u_size;\n"
  "out vec4 v_color;\n"
  "void main(){\n"
  "  vec2 n = vec2((a_pos.x/u_size.x)*2.0-1.0, 1.0-(a_pos.y/u_size.y)*2.0);\n"
  "  gl_Position = vec4(n,0.0,1.0); v_color=a_color; }\n";
static const char *FS_RECT =
  "#version 300 es\n"
  "precision mediump float;\n"
  "in vec4 v_color; out vec4 o;\n"
  "void main(){ o = v_color; }\n";

static const char *VS_GLYPH =
  "#version 300 es\n"
  "layout(location=0) in vec2 a_pos;\n"
  "layout(location=1) in vec2 a_uv;\n"
  "layout(location=2) in vec4 a_color;\n"
  "uniform vec2 u_size;\n"
  /* highp UVs: a 2048px atlas needs more than fp16's ~10-bit mantissa to
     address its texels exactly on strict-mediump GPUs.  */
  "out highp vec2 v_uv; out vec4 v_color;\n"
  "void main(){\n"
  "  vec2 n = vec2((a_pos.x/u_size.x)*2.0-1.0, 1.0-(a_pos.y/u_size.y)*2.0);\n"
  "  gl_Position = vec4(n,0.0,1.0); v_uv=a_uv; v_color=a_color; }\n";
static const char *FS_GLYPH =
  "#version 300 es\n"
  "precision mediump float;\n"
  "in highp vec2 v_uv; in vec4 v_color; out vec4 o;\n"
  "uniform sampler2D u_atlas;\n"
  "void main(){\n"
  "  float cov = texture(u_atlas, v_uv).r;\n"
  "  cov = pow(cov, 0.82);\n"
  "  o = vec4(v_color.rgb, v_color.a*cov); }\n";

/* RGBA textured quad (images / video frames). */
static const char *VS_IMAGE =
  "#version 300 es\n"
  "layout(location=0) in vec2 a_pos;\n"
  "layout(location=1) in vec2 a_uv;\n"
  "uniform vec2 u_size;\n"
  "out highp vec2 v_uv;\n"
  "void main(){\n"
  "  vec2 n = vec2((a_pos.x/u_size.x)*2.0-1.0, 1.0-(a_pos.y/u_size.y)*2.0);\n"
  "  gl_Position = vec4(n,0.0,1.0); v_uv=a_uv; }\n";
/* The image texture holds PREMULTIPLIED alpha (from a cairo ARGB32 surface);
   scaling all four channels by u_alpha keeps it premultiplied, and the caller
   composites it with glBlendFunc (GL_ONE, GL_ONE_MINUS_SRC_ALPHA), which is
   exactly cairo's OVER operator.  */
static const char *FS_IMAGE =
  "#version 300 es\n"
  "precision mediump float;\n"
  "in highp vec2 v_uv; out vec4 o;\n"
  "uniform sampler2D u_tex; uniform float u_alpha;\n"
  "void main(){ o = texture(u_tex,v_uv) * u_alpha; }\n";

/* ------------------------------------------------------------------ */
/* Global GL objects (one process-wide context, like Metal's g_device).  */

#define GL_ATLAS_W 2048
#define GL_ATLAS_H 2048

static bool      g_gl_ready = false;
static EGLDisplay g_dpy = EGL_NO_DISPLAY;
static EGLContext g_ctx = EGL_NO_CONTEXT;
static EGLConfig  g_cfg;
static EGLint     g_cfg_alpha;  /* EGL_ALPHA_SIZE of g_cfg (0 = opaque) */
/* How g_dpy was created: determines whether window surfaces are available
   and which native window type to use for on-screen present.  */
enum gl_dpy_type { GL_DPY_SURFACELESS, GL_DPY_X11, GL_DPY_WAYLAND };
static enum gl_dpy_type g_dpy_type = GL_DPY_SURFACELESS;
/* Partial present support.  EGL_EXT_buffer_age reports how many swaps ago
   the current back buffer was last presented, which tells exactly which
   frames' changes it is missing; the present then blits only the union of
   those dirty regions.  Unlike EGL_BUFFER_PRESERVED (which some compositing
   window managers advertise but do not honor), the age is what the driver
   actually guarantees about its own buffer rotation, so this is correct
   under any compositor.  eglSwapBuffersWithDamage additionally hands the
   compositor the damaged box so it recomposites only that band.  */
static bool      g_has_buffer_age = false;
static PFNEGLSWAPBUFFERSWITHDAMAGEKHRPROC g_swap_damage = NULL;
/* The draw/read surface currently bound to g_ctx, so we never re-issue an
   eglMakeCurrent that would not change anything.  FBO rendering works under
   any bound surface, so the window surface is kept current across frames
   instead of switching to surfaceless and back on every present.  */
static EGLSurface g_bound_surf = EGL_NO_SURFACE;
static bool       g_bound_known = false;

/* Make SURF current on g_ctx (draw == read == SURF; EGL_NO_SURFACE means
   surfaceless).  No-op when SURF is already bound.  */
static bool
gl_bind_surface (EGLSurface surf)
{
  if (g_bound_known && surf == g_bound_surf) return true;
  if (!eglMakeCurrent (g_dpy, surf, surf, g_ctx)) return false;
  g_bound_surf = surf;
  g_bound_known = true;
  return true;
}

static GLuint g_prog_rect, g_prog_glyph, g_prog_image;
static GLint  g_u_rect_size, g_u_glyph_size, g_u_glyph_atlas;
static GLint  g_u_image_size, g_u_image_tex, g_u_image_alpha;
static GLuint g_vbo;

static GLuint g_atlas;                 /* R8 coverage atlas */
static int    g_atlas_next_x, g_atlas_next_y, g_atlas_row_h;

/* Batched grayscale glyphs.  Every glyph from the coverage atlas shares
   g_atlas and g_prog_glyph, so instead of one draw call per glyph we
   accumulate their quads here and emit a single glDrawArrays.  The batch
   is flushed (gl_flush_glyph_batch) whenever the GL state that follows
   would differ: a clip/scissor change, any non-glyph primitive, or the
   end of the render cycle.  All glyphs in a flush therefore share one
   scissor (each glyph string sets its clip once, then draws its glyphs),
   so the output is identical to drawing them one by one.  */
#define GL_GLYPH_VERT_FLOATS 8         /* x,y,u,v,r,g,b,a */
static float *g_glyph_batch;           /* GL_GLYPH_VERT_FLOATS per vertex */
static int    g_glyph_batch_verts;     /* vertices queued */
static int    g_glyph_batch_cap;       /* capacity in vertices */
static struct gl_frame_data *g_glyph_batch_fd;  /* frame the quads target */
static void gl_flush_glyph_batch (void);
static void gl_batch_append (struct gl_frame_data *fd, float x0, float y0,
                             float x1, float y1, float u0, float v0,
                             float u1, float v1, const float rgba[4]);
struct gl_video;
#ifdef HAVE_GSTREAMER
static void gl_video_overlay (struct gl_frame_data *fd, int sw, int sh);
static void gl_video_free (struct gl_frame_data *fd);
static bool gl_video_pump (struct gl_video *v);
#endif

/* Cursor animation overlay + note_cursor.  Config globals are defined with
   the animation types (after struct gl_anim, which holds the enum).  */
static void gl_anim_overlay (struct gl_frame_data *fd, int sw, int sh);
static bool gl_anim_overlay_active (struct gl_frame_data *fd);
static bool gl_drv_note_cursor (struct frame *f, int x, int y, int w, int h,
                                unsigned long color);

/* Render scale.  The FBO and every glyph/image/bitmap is rasterized and
   drawn at physical pixels = logical * g_atlas_scale.

   On X11 there is NO backing-scale indirection like the macOS Retina
   drawable: an Emacs frame's X window is sized to FRAME_PIXEL_WIDTH and
   Emacs lays out its text area in device pixels regardless of the GTK
   scale factor (a 14px font stays 14px, the char cell stays 8px, with
   GDK_SCALE=1 or 2 alike).  HiDPI sharpness on X is obtained the Emacs
   way, with a higher Xft.dpi / larger font: the cairo pixel_size grows,
   so the atlas is already rasterized big and crisp at scale 1.  Keying
   the FBO off the GTK scale factor (xg_get_scale) would oversize it
   relative to the real window surface, forcing a downscale on present
   (verified: GDK_SCALE=2 -> xg_get_scale 2, but the X window stays
   640x400, not 1280x800).  So the default scale is 1.

   GL_SCALE is an explicit knob: values > 1 render everything at N x and
   the present blit downsamples to the window (a supersampling AA pass),
   and it is the path a future compositor-aware scale would feed.  The
   atlas stores physical-size bitmaps, so a scale change flushes both
   glyph caches.  */
static double g_atlas_scale = 1.0;

static void gl_flush_glyph_caches (void);

/* Resolve the render scale for frame F: the GL_SCALE env override first,
   then the GDK compositor scale on Wayland (HiDPI), else 1.  On Wayland the
   compositor reports the output's physical-to-logical ratio via GDK; feeding
   it here makes the FBO and the wl_egl_window match the physical resolution
   so the blit is 1:1 and glyphs are rasterized at device pixels.  */
static double
gl_frame_scale (struct frame *f)
{
  const char *env = getenv ("GL_SCALE");
  if (env && *env)
    {
      double s = atof (env);
      if (s >= 1.0) return s;
    }
#if defined HAVE_PGTK && defined GDK_WINDOWING_WAYLAND && defined HAVE_WAYLAND_EGL
  if (g_dpy_type == GL_DPY_WAYLAND && f && FRAME_PGTK_P (f))
    {
      GdkWindow *gdk_win = FRAME_GDK_WINDOW (f);
      if (gdk_win)
        {
          int s = gdk_window_get_scale_factor (gdk_win);
          if (s >= 1) return (double) s;
        }
    }
#endif
  (void) f;
  return 1.0;
}

/* ------------------------------------------------------------------ */
/* Glyph cache: key (font ptr mixed with glyph id) -> struct gfx_glyph.
   Open-addressing table with linear probing.  */

#define GL_GLYPH_CAP 8192
static struct gfx_glyph g_glyphs[GL_GLYPH_CAP];
static int g_glyph_count;

static struct gfx_glyph *
glyph_cache_lookup (unsigned long long key)
{
  unsigned h = (unsigned) (key % GL_GLYPH_CAP);
  for (int i = 0; i < GL_GLYPH_CAP; i++)
    {
      struct gfx_glyph *g = &g_glyphs[(h + i) % GL_GLYPH_CAP];
      if (!g->valid) return NULL;
      if (g->cache_key == key) return g;
    }
  return NULL;
}

/* Reset the atlas packing and the glyph table, then re-reserve the 4x4
   white block at (0,0) that batched solid rects sample (the rect quads
   share the glyph program: a coverage of 1.0 passes the gamma curve
   unchanged, so one program and one texture cover glyphs and fills and
   the two never split the batch).  Any queued quads still reference the
   old layout, so they are flushed first.  */
static void
gl_atlas_reset (void)
{
  gl_flush_glyph_batch ();
  memset (g_glyphs, 0, sizeof g_glyphs);
  g_glyph_count = 0;
  static const unsigned char white[16] = {
    255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255,
  };
  glBindTexture (GL_TEXTURE_2D, g_atlas);
  glPixelStorei (GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D (GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RED,
                   GL_UNSIGNED_BYTE, white);
  g_atlas_next_x = 5;
  g_atlas_next_y = 0;
  g_atlas_row_h = 4;
}

/* Texture coordinates of the white block's center texel.  */
#define GL_WHITE_U (2.0f / GL_ATLAS_W)
#define GL_WHITE_V (2.0f / GL_ATLAS_H)

static struct gfx_glyph *
glyph_cache_insert (unsigned long long key)
{
  if (g_glyph_count * 4 >= GL_GLYPH_CAP * 3)   /* >75% full: reset atlas */
    gl_atlas_reset ();
  unsigned h = (unsigned) (key % GL_GLYPH_CAP);
  for (int i = 0; i < GL_GLYPH_CAP; i++)
    {
      struct gfx_glyph *g = &g_glyphs[(h + i) % GL_GLYPH_CAP];
      if (!g->valid)
        {
          memset (g, 0, sizeof *g);
          g->cache_key = key;
          g->valid = true;
          g_glyph_count++;
          return g;
        }
    }
  return NULL;
}

/* ------------------------------------------------------------------ */
/* Cursor animation (the MtlAnimator analogue): spring glide, comet trail,
   and particle bursts (sonicboom / ripple / pixiedust), composited over
   the frame in the present.  Opt-in: off unless gpu.el turns it on, so the
   headless parity harness (which enables only the backend) sees a plain
   static cursor.  */

enum gl_cursor_mode
{
  GL_CURSOR_BLOCK = 0, GL_CURSOR_SPRING = 1, GL_CURSOR_TORPEDO = 2,
  GL_CURSOR_SONICBOOM = 3, GL_CURSOR_RIPPLE = 4, GL_CURSOR_PIXIEDUST = 5,
  GL_CURSOR_HOLLOW = 6, GL_CURSOR_BEAM = 7,
};

#define GL_TRAIL_LEN      40
#define GL_MAX_PARTICLES  80
#define GL_TRAIL_LIFETIME 0.40f
#define GL_SPRING_OMEGA   8.0f   /* settles in ~150ms, like Metal */

struct gl_particle { float x, y, vx, vy, age, size; unsigned long color; };

struct gl_anim
{
  float tx, ty, tw, th;          /* Emacs cursor target, logical px */
  unsigned long color;           /* real frame cursor color */
  float sx, svx, sy, svy;        /* spring position + velocity, per axis */
  bool hidden;                   /* blink-off phase */
  bool have_target;              /* a cursor was placed at least once */
  /* Comet trail (torpedo): ring buffer of recent positions + their age.  */
  float trail_x[GL_TRAIL_LEN], trail_y[GL_TRAIL_LEN], trail_age[GL_TRAIL_LEN];
  int trail_head, trail_count;
  struct gl_particle particles[GL_MAX_PARTICLES];
  int n_particles;
};

/* Cursor animation config (the g_mtl_* analogues).  Animations are opt-in
   (gpu.el flips g_gl_animations_enabled on); the default mode is sonicboom
   so that, once enabled, the GPU flag ships a cursor effect out of the box.
   g_gl_cursor_suppress is set per-command so typing does not spray effects.  */
static int  g_gl_cursor_mode        = GL_CURSOR_SONICBOOM;
static bool g_gl_animations_enabled = false;
static int  g_gl_trail_len          = 20;
static bool g_gl_cursor_suppress    = false;

/* ------------------------------------------------------------------ */
/* Dirty-region tracking for the partial present.  A single union box
   degenerates as soon as two distant regions change in one frame (the
   edited row at the top plus the mode line at the bottom span almost the
   whole frame), so the set keeps up to GL_DIRTY_MAX disjoint boxes in FBO
   pixel coordinates (bottom-left origin) and merges on overlap/overflow.  */

#define GL_DIRTY_MAX 8

struct gl_dirty_set
{
  bool all;                     /* everything changed: boxes irrelevant */
  int n;
  int b[GL_DIRTY_MAX][4];       /* x0, y0, x1, y1 (exclusive) */
};

static void
gl_dirty_clear (struct gl_dirty_set *d)
{
  d->all = false;
  d->n = 0;
}

/* Add a box, growing an existing one when they touch (within SLACK px,
   so the per-glyph marks of one row coalesce into a single box) and
   folding into the closest box on overflow.  */
static void
gl_dirty_add (struct gl_dirty_set *d, int x0, int y0, int x1, int y1)
{
  const int SLACK = 8;
  if (d->all || x0 >= x1 || y0 >= y1)
    return;
  for (int i = 0; i < d->n; i++)
    {
      int *b = d->b[i];
      if (x0 <= b[2] + SLACK && x1 >= b[0] - SLACK
          && y0 <= b[3] + SLACK && y1 >= b[1] - SLACK)
        {
          if (x0 < b[0]) b[0] = x0;
          if (y0 < b[1]) b[1] = y0;
          if (x1 > b[2]) b[2] = x1;
          if (y1 > b[3]) b[3] = y1;
          return;
        }
    }
  if (d->n < GL_DIRTY_MAX)
    {
      int *b = d->b[d->n++];
      b[0] = x0; b[1] = y0; b[2] = x1; b[3] = y1;
      return;
    }
  /* Full: fold into the box whose union grows the least.  */
  int best = 0;
  long best_growth = -1;
  for (int i = 0; i < d->n; i++)
    {
      int *b = d->b[i];
      long ux0 = min (b[0], x0), uy0 = min (b[1], y0);
      long ux1 = max (b[2], x1), uy1 = max (b[3], y1);
      long growth = (ux1 - ux0) * (uy1 - uy0)
        - (long) (b[2] - b[0]) * (b[3] - b[1]);
      if (best_growth < 0 || growth < best_growth)
        { best_growth = growth; best = i; }
    }
  int *b = d->b[best];
  if (x0 < b[0]) b[0] = x0;
  if (y0 < b[1]) b[1] = y0;
  if (x1 > b[2]) b[2] = x1;
  if (y1 > b[3]) b[3] = y1;
}

/* Union SRC into DST (used to repair an aged back buffer).  */
static void
gl_dirty_union (struct gl_dirty_set *dst, const struct gl_dirty_set *src)
{
  if (src->all)
    { dst->all = true; return; }
  for (int i = 0; i < src->n && !dst->all; i++)
    gl_dirty_add (dst, src->b[i][0], src->b[i][1], src->b[i][2], src->b[i][3]);
}

/* Per-frame GL state (the MtlFrameData analogue).  Associated with a
   `struct frame *' through a small process-wide map.  */

struct gl_frame_data
{
  struct frame *f;
  GLuint fbo, tex;             /* static texture render target */
  GLuint scratch_fbo, scratch_tex;
  int w, h;                    /* texture size in physical pixels */
  double scale;
  bool in_cycle;
  bool needs_present;
  EGLSurface surf;             /* on-screen window surface, or EGL_NO_SURFACE */
  unsigned long surf_win;      /* X window `surf' was created for (0 = none) */
#if defined HAVE_PGTK && defined HAVE_WAYLAND_EGL
  struct wl_egl_window *wl_win;        /* Wayland EGL window, or NULL */
  struct wl_surface    *wl_surf;       /* child wl_surface for EGL (frame callbacks) */
  struct wl_surface    *wl_parent_surf;/* GDK's wl_surface (parent of our subsurface) */
  struct wl_subsurface *wl_sub;        /* wl_subsurface linking child to parent */
  struct wl_callback   *frame_cb;      /* pending wl_surface.frame callback, or NULL */
  bool frame_ready;                    /* compositor signalled ready for next frame */
  int wl_sub_x, wl_sub_y;              /* last position set on wl_sub */
#endif
#ifdef HAVE_PGTK
  gulong after_paint_id;       /* GdkFrameClock "after-paint" handler, or 0.
                                  X11 sessions only: GTK's client-side
                                  windows composite widget paints through
                                  the same X window we present to, so we
                                  re-present after every GTK paint.  */
  void *frame_clock;           /* the GdkFrameClock the handler is on */
#endif
  int surf_w, surf_h;          /* cached surface size (re-queried on resize) */
  bool clip_on;
  int clip_x, clip_y, clip_w, clip_h;   /* top-left logical */
  /* FBO changes accumulated since the last swap (bottom-left pixel
     coords).  The present consumes it: after the swap it is recorded in
     swap_dirty and cleared.  */
  struct gl_dirty_set dirty;
  /* What each of the last GL_SWAP_RING swaps changed, newest at
     (swap_head - 1); `all' also marks overlay frames (their pixels live
     outside the FBO).  Combined with the back buffer's age this yields
     exactly the region an aged buffer is missing.  */
#define GL_SWAP_RING 8
  struct gl_dirty_set swap_dirty[GL_SWAP_RING];
  int swap_head;
  /* Buffer-switch cross-fade: a snapshot of the previous frame fades out
     over the new content while trans_dur > 0 (see gl_transition_start).  */
  GLuint trans_tex;
  int trans_w, trans_h;
  double trans_start, trans_dur;
  /* When the last successful swap happened.  The animation pumps (cursor
     effects, cross-fade) throttle on it: their ticks interleave with
     redisplay's own presents, and burst-presenting the surface well above
     the refresh rate makes Mesa juggle extra swapchain buffers -- under
     which radeonsi has been seen presenting a stale one (an ancient frame
     flashing for one vblank).  Time-based animations lose nothing by
     skipping a tick that lands right after a present.  */
  double last_swap;
  /* When gl_pump_tick last ran, for real-elapsed animation steps.  */
  double last_pump;
  /* Inline video, or NULL.  Composited over the FBO blit on every present
     (see gl_present_to_window); the MtlVideoPlayer analogue.  */
  struct gl_video *video;
  /* Cursor animation overlay state.  */
  struct gl_anim anim;
};

#define GL_MAX_FRAMES 64
static struct gl_frame_data *g_frames[GL_MAX_FRAMES];
static struct gl_frame_data *g_cur;     /* frame of the open cycle */

/* The lookup runs once per drawing op (per glyph at the worst), so keep
   the last hit: redisplay works one frame at a time and the slot scan
   only happens on a frame switch.  */
static struct gl_frame_data *g_fd_mru;

static struct gl_frame_data *
gl_get_frame_data (struct frame *f)
{
  if (g_fd_mru && g_fd_mru->f == f)
    return g_fd_mru;
  for (int i = 0; i < GL_MAX_FRAMES; i++)
    if (g_frames[i] && g_frames[i]->f == f)
      return g_fd_mru = g_frames[i];
  return NULL;
}

/* ------------------------------------------------------------------ */
/* GL helpers.  */

static GLuint
gl_compile (GLenum type, const char *src)
{
  GLuint s = glCreateShader (type);
  glShaderSource (s, 1, &src, NULL);
  glCompileShader (s);
  GLint ok = 0;
  glGetShaderiv (s, GL_COMPILE_STATUS, &ok);
  if (!ok)
    {
      char log[1024];
      glGetShaderInfoLog (s, sizeof log, NULL, log);
      fprintf (stderr, "glterm: shader compile failed: %s\n", log);
    }
  return s;
}

static GLuint
gl_program (const char *vs, const char *fs)
{
  GLuint p = glCreateProgram ();
  glAttachShader (p, gl_compile (GL_VERTEX_SHADER, vs));
  glAttachShader (p, gl_compile (GL_FRAGMENT_SHADER, fs));
  glLinkProgram (p);
  GLint ok = 0;
  glGetProgramiv (p, GL_LINK_STATUS, &ok);
  if (!ok)
    {
      char log[1024];
      glGetProgramInfoLog (p, sizeof log, NULL, log);
      fprintf (stderr, "glterm: program link failed: %s\n", log);
    }
  return p;
}

#if defined HAVE_PGTK && defined HAVE_WAYLAND_EGL
/* Global wl_subcompositor used to create GPU subsurfaces.  Queried once
   from the Wayland registry so we do not need to repeat the roundtrip on
   every frame enable.  */
static struct wl_subcompositor *g_wl_subcompositor;

static void
gl_wl_reg_global (void *data, struct wl_registry *reg,
                  uint32_t name, const char *iface, uint32_t version)
{
  (void) data; (void) version;
  if (strcmp (iface, "wl_subcompositor") == 0)
    g_wl_subcompositor
      = wl_registry_bind (reg, name, &wl_subcompositor_interface, 1);
}

static void
gl_wl_reg_remove (void *data, struct wl_registry *reg, uint32_t name)
{ (void) data; (void) reg; (void) name; }

static const struct wl_registry_listener gl_wl_reg_listener = {
  gl_wl_reg_global, gl_wl_reg_remove,
};

/* Bind Wayland globals (wl_subcompositor) via a one-shot registry roundtrip.
   Safe to call multiple times; does nothing after the first successful run.  */
static void
gl_wl_init_registry (void)
{
  if (g_wl_subcompositor) return;
  GdkDisplay *gdpy = gdk_display_get_default ();
  if (!gdpy || !GDK_IS_WAYLAND_DISPLAY (gdpy)) return;
  struct wl_display *wl_dpy = gdk_wayland_display_get_wl_display (gdpy);
  if (!wl_dpy) return;
  struct wl_registry *reg = wl_display_get_registry (wl_dpy);
  if (!reg) return;
  wl_registry_add_listener (reg, &gl_wl_reg_listener, NULL);
  wl_display_roundtrip (wl_dpy);
}
#endif /* HAVE_PGTK && HAVE_WAYLAND_EGL */

/* Bring up the process-wide EGL surfaceless context and the shared GL
   objects.  Returns false on failure (the caller keeps the platform
   backend).  */
static bool
gl_global_init (void)
{
  if (g_gl_ready) return true;

  PFNEGLGETPLATFORMDISPLAYEXTPROC get_dpy =
    (PFNEGLGETPLATFORMDISPLAYEXTPROC)
    eglGetProcAddress ("eglGetPlatformDisplayEXT");

  bool force_surfaceless = !!getenv ("GL_FORCE_SURFACELESS");

#ifdef HAVE_PGTK
  /* PGTK build: get the EGL display from GDK.  Try Wayland first (native
     EGL surface support), fall back to X11 GDK backend if available.
     GL_FORCE_SURFACELESS skips both, keeping the headless GPU path.  */
  if (!force_surfaceless)
    {
      GdkDisplay *gdpy = gdk_display_get_default ();
      if (gdpy)
        {
# ifdef GDK_WINDOWING_WAYLAND
          if (GDK_IS_WAYLAND_DISPLAY (gdpy))
            {
              struct wl_display *wl_dpy =
                gdk_wayland_display_get_wl_display (gdpy);
              if (wl_dpy)
                {
                  if (get_dpy)
                    g_dpy = get_dpy (EGL_PLATFORM_WAYLAND_KHR, wl_dpy, NULL);
                  if (g_dpy == EGL_NO_DISPLAY)
                    g_dpy = eglGetDisplay ((EGLNativeDisplayType) wl_dpy);
                  if (g_dpy != EGL_NO_DISPLAY)
                    {
                      g_dpy_type = GL_DPY_WAYLAND;
                      gl_wl_init_registry ();
                    }
                }
            }
# endif /* GDK_WINDOWING_WAYLAND */
          /* PGTK/X11 session (GDK_BACKEND=x11 or Wayland unavailable):
             obtain the underlying X Display* via dlsym so we never include
             gdkx.h (which conflicts with pgtkgui.h typedefs).  */
          if (g_dpy == EGL_NO_DISPLAY)
            {
              typedef void *(*get_xdisplay_fn) (GdkDisplay *);
              get_xdisplay_fn gx =
                (get_xdisplay_fn) dlsym (RTLD_DEFAULT,
                                         "gdk_x11_display_get_xdisplay");
              if (gx)
                {
                  void *xdpy = gx (gdpy);
                  if (xdpy)
                    {
                      if (get_dpy)
                        g_dpy = get_dpy (EGL_PLATFORM_X11_KHR, xdpy, NULL);
                      if (g_dpy == EGL_NO_DISPLAY)
                        g_dpy = eglGetDisplay ((EGLNativeDisplayType) xdpy);
                      if (g_dpy != EGL_NO_DISPLAY)
                        g_dpy_type = GL_DPY_X11;
                    }
                }
            }
        }
    }
#else  /* !HAVE_PGTK: X11 build */
  /* Prefer an X11-platform display: it renders to FBOs exactly like the
     surfaceless one (so the headless capture path is unchanged), but it
     can also create window surfaces, which is what on-screen present
     needs.  Fall back to surfaceless only when there is no X connection
     (a pure batch run with no frame).
     GL_FORCE_SURFACELESS keeps the surfaceless path even with an X
     connection: on a DRI3-less X server (e.g. Xvfb) the X11 platform
     falls back to llvmpipe, whereas surfaceless still reaches the real GPU.
     Use it for the headless GPU benchmark.  */
  Display *xdpy = (!force_surfaceless && x_display_list)
                    ? x_display_list->display : NULL;
  if (xdpy && get_dpy)
    {
      g_dpy = get_dpy (EGL_PLATFORM_X11_KHR, xdpy, NULL);
      if (g_dpy != EGL_NO_DISPLAY)
        g_dpy_type = GL_DPY_X11;
    }
  if (g_dpy == EGL_NO_DISPLAY && xdpy)
    {
      g_dpy = eglGetDisplay ((EGLNativeDisplayType) xdpy);
      if (g_dpy != EGL_NO_DISPLAY)
        g_dpy_type = GL_DPY_X11;
    }
#endif /* !HAVE_PGTK */

  if (g_dpy == EGL_NO_DISPLAY && get_dpy)
    g_dpy = get_dpy (EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
  if (g_dpy == EGL_NO_DISPLAY)
    g_dpy = eglGetDisplay (EGL_DEFAULT_DISPLAY);
  if (g_dpy == EGL_NO_DISPLAY) return false;

  EGLint maj, min;
  if (!eglInitialize (g_dpy, &maj, &min))
    {
      /* The native display (Wayland or X11) could not initialize EGL.
         This happens on some X11 servers without EGL support.  Fall back
         to the surfaceless/pbuffer path so FBO capture still works.  */
      g_dpy = EGL_NO_DISPLAY;
      g_dpy_type = GL_DPY_SURFACELESS;
      if (get_dpy)
        g_dpy = get_dpy (EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
      if (g_dpy == EGL_NO_DISPLAY)
        g_dpy = eglGetDisplay (EGL_DEFAULT_DISPLAY);
      if (g_dpy == EGL_NO_DISPLAY) return false;
      if (!eglInitialize (g_dpy, &maj, &min)) return false;
    }
  if (!eglBindAPI (EGL_OPENGL_ES_API)) return false;

  /* Wayland DRM configs typically expose only 10:10:10:2 formats; requesting
     EGL_ALPHA_SIZE=8 would exclude them.  Ask for at least 1 alpha bit so
     both XRGB2101010 (alpha 2) and ARGB8888 configs match: the subsurface
     relies on translucency to let GTK's scroll bars on the parent surface
     show through the gutters (see gl_ensure_target).  Requesting 0 would
     let EGL's sorting pick an alpha-less XRGB config first; keep 0 only as
     a retry when no alpha-bearing config exists at all.  X11/surfaceless
     have standard RGBA8888 configs, so keep 8 there.  Wayland configs also
     lack EGL_PBUFFER_BIT; request only EGL_WINDOW_BIT.  */
  EGLint cfg_attr[] = {
    EGL_SURFACE_TYPE, (g_dpy_type == GL_DPY_SURFACELESS)
                        ? EGL_PBUFFER_BIT
                        : (g_dpy_type == GL_DPY_WAYLAND)
                          ? EGL_WINDOW_BIT
                          : (EGL_WINDOW_BIT | EGL_PBUFFER_BIT),
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
    EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
    EGL_ALPHA_SIZE, (g_dpy_type == GL_DPY_WAYLAND) ? 1 : 8,
    EGL_NONE
  };
  EGLint n = 0;
  if ((!eglChooseConfig (g_dpy, cfg_attr, &g_cfg, 1, &n) || n < 1)
      && g_dpy_type == GL_DPY_WAYLAND)
    {
      /* No alpha-bearing Wayland config: retry opaque (scroll-bar gutters
         then keep the frame background, as before).  */
      cfg_attr[11] = 0;
      n = 0;
      eglChooseConfig (g_dpy, cfg_attr, &g_cfg, 1, &n);
    }
  if (n < 1)
    {
      /* The native EGL display (Wayland or X11) has no matching GLES3 configs.
         This happens on weston headless (pure pixman/software, no GPU EGL).
         Terminate the native display and retry with the surfaceless path so
         that FBO capture and headless testing still work.  */
      if (g_dpy_type != GL_DPY_SURFACELESS)
        {
          eglTerminate (g_dpy);
          g_dpy = EGL_NO_DISPLAY;
          g_dpy_type = GL_DPY_SURFACELESS;
          if (get_dpy)
            g_dpy = get_dpy (EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
          if (g_dpy == EGL_NO_DISPLAY)
            g_dpy = eglGetDisplay (EGL_DEFAULT_DISPLAY);
          if (g_dpy == EGL_NO_DISPLAY) return false;
          if (!eglInitialize (g_dpy, &maj, &min)) return false;
          /* Rebuild config attrs: surfaceless uses PBUFFER_BIT only with
             standard RGBA8888 configs (restore alpha=8).  */
          cfg_attr[1] = EGL_PBUFFER_BIT;
          cfg_attr[11] = 8;
          n = 0;
          if (!eglChooseConfig (g_dpy, cfg_attr, &g_cfg, 1, &n) || n < 1)
            return false;
        }
      else
        return false;
    }

  EGLint ctx_attr[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE };
  g_ctx = eglCreateContext (g_dpy, g_cfg, EGL_NO_CONTEXT, ctx_attr);
  if (g_ctx == EGL_NO_CONTEXT) return false;
  eglGetConfigAttrib (g_dpy, g_cfg, EGL_ALPHA_SIZE, &g_cfg_alpha);
  if (getenv ("GL_LOG_PRESENT"))
    fprintf (stderr, "[glinit] dpy_type=%d cfg_alpha=%d\n",
             (int) g_dpy_type, (int) g_cfg_alpha);
  if (!gl_bind_surface (EGL_NO_SURFACE))
    return false;

  /* Partial-present support (see the comment at g_has_buffer_age).  */
  {
    const char *ext = eglQueryString (g_dpy, EGL_EXTENSIONS);
    if (ext && strstr (ext, "EGL_EXT_buffer_age"))
      g_has_buffer_age = true;
    if (ext && strstr (ext, "EGL_KHR_swap_buffers_with_damage"))
      g_swap_damage = (PFNEGLSWAPBUFFERSWITHDAMAGEKHRPROC)
        eglGetProcAddress ("eglSwapBuffersWithDamageKHR");
    else if (ext && strstr (ext, "EGL_EXT_swap_buffers_with_damage"))
      g_swap_damage = (PFNEGLSWAPBUFFERSWITHDAMAGEKHRPROC)
        eglGetProcAddress ("eglSwapBuffersWithDamageEXT");
  }

  g_prog_rect  = gl_program (VS_RECT,  FS_RECT);
  g_prog_glyph = gl_program (VS_GLYPH, FS_GLYPH);
  g_prog_image = gl_program (VS_IMAGE, FS_IMAGE);
  g_u_rect_size   = glGetUniformLocation (g_prog_rect,  "u_size");
  g_u_glyph_size  = glGetUniformLocation (g_prog_glyph, "u_size");
  g_u_glyph_atlas = glGetUniformLocation (g_prog_glyph, "u_atlas");
  g_u_image_size  = glGetUniformLocation (g_prog_image, "u_size");
  g_u_image_tex   = glGetUniformLocation (g_prog_image, "u_tex");
  g_u_image_alpha = glGetUniformLocation (g_prog_image, "u_alpha");

  glGenBuffers (1, &g_vbo);

  glGenTextures (1, &g_atlas);
  glBindTexture (GL_TEXTURE_2D, g_atlas);
  glTexImage2D (GL_TEXTURE_2D, 0, GL_R8, GL_ATLAS_W, GL_ATLAS_H, 0,
                GL_RED, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  gl_atlas_reset ();            /* reserve the white block for rect quads */

  glPixelStorei (GL_UNPACK_ALIGNMENT, 1);
  glEnable (GL_BLEND);
  glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

  g_gl_ready = true;
  return true;
}

/* Ensure FD's static texture matches (w,h); (re)create + clear if not.  */
static void
gl_ensure_target (struct gl_frame_data *fd, int w, int h)
{
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  if (fd->tex && fd->w == w && fd->h == h) return;

  if (!fd->tex) glGenTextures (1, &fd->tex);
  glBindTexture (GL_TEXTURE_2D, fd->tex);
  glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA,
                GL_UNSIGNED_BYTE, NULL);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  if (!fd->scratch_tex) glGenTextures (1, &fd->scratch_tex);
  glBindTexture (GL_TEXTURE_2D, fd->scratch_tex);
  glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA,
                GL_UNSIGNED_BYTE, NULL);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

  if (!fd->fbo) glGenFramebuffers (1, &fd->fbo);
  glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
  glFramebufferTexture2D (GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                          GL_TEXTURE_2D, fd->tex, 0);
  if (!fd->scratch_fbo) glGenFramebuffers (1, &fd->scratch_fbo);
  glBindFramebuffer (GL_FRAMEBUFFER, fd->scratch_fbo);
  glFramebufferTexture2D (GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                          GL_TEXTURE_2D, fd->scratch_tex, 0);

  fd->w = w;
  fd->h = h;

  /* Brand-new/resized target: clear to the frame background and present
     the whole frame this cycle (the snapshot underneath is stale).  */
  fd->dirty.all = true;
  glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
  glViewport (0, 0, w, h);
  float bg[4];
  gl_unpack_color (FRAME_BACKGROUND_PIXEL (fd->f), bg);
  glDisable (GL_SCISSOR_TEST);
#if defined HAVE_PGTK && defined HAVE_WAYLAND_EGL
  /* On a Wayland subsurface, clear to premultiplied transparent instead
     of the frame background: pixels redisplay never draws are exactly
     the toolkit scroll-bar gutters, and with alpha 0 the compositor
     blends them away so GTK's scroll bars on the parent surface show
     through our overlay (on X11 the server clips the presents under the
     native scroll-bar windows instead).  Needs an alpha-bearing config;
     opaque configs keep the old background clear.  */
  if (g_dpy_type == GL_DPY_WAYLAND && g_cfg_alpha > 0)
    glClearColor (0.0f, 0.0f, 0.0f, 0.0f);
  else
#endif
    glClearColor (bg[0], bg[1], bg[2], 1.0f);
  glClear (GL_COLOR_BUFFER_BIT);
}

/* Mark a top-left logical rect (x,y,w,h) as changed: converted to FBO
   pixel coords (bottom-left), clamped to the target, and added to the
   frame's dirty set.  The present then blits only those boxes.  */
static void
gl_mark_dirty (struct gl_frame_data *fd, double x, double y,
               double w, double h)
{
  if (fd->dirty.all || w <= 0 || h <= 0) return;
  double s = fd->scale;
  int px0 = (int) floor (x * s);
  int px1 = (int) ceil ((x + w) * s);
  int py_top = (int) floor (y * s);
  int py_bot = (int) ceil ((y + h) * s);
  /* Flip Y: top-left logical -> bottom-left FBO.  */
  int fy0 = fd->h - py_bot;
  int fy1 = fd->h - py_top;
  if (px0 < 0) px0 = 0;
  if (fy0 < 0) fy0 = 0;
  if (px1 > fd->w) px1 = fd->w;
  if (fy1 > fd->h) fy1 = fd->h;
  gl_dirty_add (&fd->dirty, px0, fy0, px1, fy1);
}

/* Apply FD's recorded clip rect as the GL scissor, in the FBO's
   bottom-left space.  Only the non-batched primitives (image textures,
   fringe bitmaps) call this, right before their draw; batched quads are
   clipped on the CPU at queue time instead (gl_batch_append).  */
static void
gl_scissor_apply_now (struct gl_frame_data *fd)
{
  if (!fd->clip_on)
    {
      glDisable (GL_SCISSOR_TEST);
      return;
    }
  double s = fd->scale;
  int x = (int) (fd->clip_x * s);
  int y = (int) (fd->clip_y * s);
  int w = (int) (fd->clip_w * s);
  int h = (int) (fd->clip_h * s);
  glEnable (GL_SCISSOR_TEST);
  glScissor (x, fd->h - (y + h), w, h);
}

/* ------------------------------------------------------------------ */
/* Glyph rasterization: FreeType (via the ftcr backend's cairo scaled
   font) into the R8 atlas.  Mirrors mtl_rasterize_glyph_id; FreeType's
   bitmap_left/bitmap_top already are the contract's bearing_x/bearing_y.  */

static FT_Face
gl_lock_face (struct font *font, cairo_scaled_font_t **out_sf)
{
  if (!font) return NULL;
  /* Only the cairo/FreeType font drivers carry a `cr_scaled_font' at the
     `struct font_info' layout we cast to.  Emacs can fall back to a core
     X11 font (xfont_driver) for glyphs no cairo font covers (e.g. some
     CJK when no scalable CJK font matches); its `struct font' is a
     different (xfont_info) layout, so reading cr_scaled_font there yields
     garbage and crashes cairo_ft_scaled_font_lock_face.  Guard the cast.
     Such glyphs cannot go through our atlas; the caller skips them rather
     than crashing.  */
  if (font->driver != &ftcrfont_driver
      && font->driver != &ftcrhbfont_driver)
    return NULL;
  struct font_info *fi = (struct font_info *) font;
  cairo_scaled_font_t *sf = fi->cr_scaled_font;
  if (!sf) return NULL;
  *out_sf = sf;
  FT_Face face = cairo_ft_scaled_font_lock_face (sf);
  return face;
}

/* FreeType load flags matching how cairo itself would rasterize SF.
   The scaled font carries the platform's font options (Xft resources on
   plain X11, the GTK settings on PGTK); rendering the atlas with plain
   FT_LOAD_RENDER uses normal hinting regardless, which matches Xft's
   default but NOT the slight hinting GTK configures, shifting stems of
   dense glyphs by a pixel against the cairo reference.  Deriving the
   flags from the options keeps every platform at parity.  */
static FT_Int32
gl_ft_load_flags (cairo_scaled_font_t *sf)
{
  FT_Int32 flags = FT_LOAD_RENDER;
  cairo_font_options_t *o = cairo_font_options_create ();
  cairo_scaled_font_get_font_options (sf, o);
  switch (cairo_font_options_get_hint_style (o))
    {
    case CAIRO_HINT_STYLE_NONE:
      flags |= FT_LOAD_NO_HINTING;
      break;
    case CAIRO_HINT_STYLE_SLIGHT:
      flags |= FT_LOAD_TARGET_LIGHT;
      break;
    default:
      /* DEFAULT/MEDIUM/FULL: normal hinting, the previous behavior.  */
      flags |= FT_LOAD_TARGET_NORMAL;
      break;
    }
  /* CAIRO_ANTIALIAS_NONE is not mirrored: it would need a 1-bit atlas
     path (FT_PIXEL_MODE_MONO), and the grayscale atlas cannot represent
     it anyway.  Those setups keep antialiased glyphs, as before.  */
  cairo_font_options_destroy (o);
  return flags;
}

static struct gfx_glyph *
gl_rasterize_glyph (struct font *font, unsigned int glyph_id,
                    unsigned long long key)
{
  cairo_scaled_font_t *sf = NULL;
  FT_Face face = gl_lock_face (font, &sf);
  if (!face) return NULL;

  /* HiDPI: re-hint and rasterize at physical resolution so the atlas
     bitmap is crisp at the (physical) draw site.  cairo activates its
     own FT size on the next lock, so overriding the ppem here is safe.
     The bitmap, bearings and box come out in physical pixels (what the
     draw path expects); the advance is converted back to logical.  */
  double s = g_atlas_scale;
  if (s != 1.0 && face->size)
    {
      FT_UInt xp = (FT_UInt) lround (face->size->metrics.x_ppem * s);
      FT_UInt yp = (FT_UInt) lround (face->size->metrics.y_ppem * s);
      if (xp > 0 && yp > 0)
        FT_Set_Pixel_Sizes (face, xp, yp);
    }

  if (FT_Load_Glyph (face, glyph_id, gl_ft_load_flags (sf)))
    {
      cairo_ft_scaled_font_unlock_face (sf);
      return NULL;
    }
  FT_GlyphSlot g = face->glyph;
  int bw = g->bitmap.width, bh = g->bitmap.rows;
  float adv = (g->advance.x / 64.0f) / (float) s;
  int bx = g->bitmap_left, by = g->bitmap_top;

  struct gfx_glyph *e;
  if (bw <= 0 || bh <= 0)
    {
      cairo_ft_scaled_font_unlock_face (sf);
      e = glyph_cache_insert (key);
      if (!e) return NULL;
      e->width = e->height = 0;
      e->advance_x = adv;
      return e;
    }

  /* Atlas row packing.  */
  if (g_atlas_next_x + bw > GL_ATLAS_W)
    {
      g_atlas_next_x = 0;
      g_atlas_next_y += g_atlas_row_h + 1;
      g_atlas_row_h = 0;
    }
  if (g_atlas_next_y + bh > GL_ATLAS_H)
    /* Atlas full: repack from the top (gl_atlas_reset flushes the queued
       quads that still reference the old layout).  */
    gl_atlas_reset ();

  glBindTexture (GL_TEXTURE_2D, g_atlas);
  glPixelStorei (GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D (GL_TEXTURE_2D, 0, g_atlas_next_x, g_atlas_next_y,
                   bw, bh, GL_RED, GL_UNSIGNED_BYTE, g->bitmap.buffer);

  e = glyph_cache_insert (key);
  if (!e) { cairo_ft_scaled_font_unlock_face (sf); return NULL; }
  e->atlas_x = g_atlas_next_x;
  e->atlas_y = g_atlas_next_y;
  e->width = bw;
  e->height = bh;
  e->bearing_x = bx;
  e->bearing_y = by;          /* distance from box top to baseline */
  e->advance_x = adv;

  g_atlas_next_x += bw + 1;
  if (bh > g_atlas_row_h) g_atlas_row_h = bh;

  cairo_ft_scaled_font_unlock_face (sf);
  return e;
}

/* ------------------------------------------------------------------ */
/* Vtable ops.  */

static bool
gl_drv_frame_ready (struct frame *f)
{
  return gl_get_frame_data (f) != NULL;
}

static void
gl_drv_begin_frame (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd) return;
  /* Render the FBO under whatever surface is already current (the window
     surface persists across frames); only bind if nothing is current yet.
     This drops the per-frame surfaceless<->window make-current churn.  */
  if (!g_bound_known) gl_bind_surface (EGL_NO_SURFACE);
  double sc = gl_frame_scale (f);
  if (sc != g_atlas_scale)
    {
      /* The atlas holds physical-size bitmaps; a scale change makes the
         cached glyphs the wrong size, so drop both caches.  */
      g_atlas_scale = sc;
      gl_flush_glyph_caches ();
    }
  fd->scale = sc;
  if (getenv ("GL_LOG_SCALE"))
    fprintf (stderr, "[glscale] scale=%.2f logical=%dx%d physical=%dx%d\n",
             sc, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f),
             (int) (FRAME_PIXEL_WIDTH (f) * sc),
             (int) (FRAME_PIXEL_HEIGHT (f) * sc));
  int w = (int) (FRAME_PIXEL_WIDTH (f) * fd->scale);
  int h = (int) (FRAME_PIXEL_HEIGHT (f) * fd->scale);
  /* The dirty box is NOT reset here: it accumulates "changes since the
     last swap" across cycles (a deferred present spans several) and the
     present consumes it.  gl_ensure_target sets dirty.all when it clears
     a new or resized target, which must be presented whole.  */
  gl_ensure_target (fd, w, h);          /* LOAD: clears only if new/resized */
  glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
  glViewport (0, 0, fd->w, fd->h);
  fd->clip_on = false;
  glDisable (GL_SCISSOR_TEST);
  /* Start the cycle with an empty glyph batch.  */
  g_glyph_batch_verts = 0;
  g_glyph_batch_fd = NULL;
  fd->in_cycle = true;
  g_cur = fd;
}

/* Monotonic seconds, for the buffer-switch cross-fade timing.  */
static double
gl_now (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
}

/* True when the animation pump may issue a present.  On Wayland we gate on
   the compositor's wl_surface.frame callback (event-driven vsync) so the
   pump submits at most one frame per vblank; on X11 and surfaceless we keep
   the 12 ms time guard.  */
static bool
gl_swap_ok (struct gl_frame_data *fd)
{
#if defined HAVE_PGTK && defined HAVE_WAYLAND_EGL
  if (g_dpy_type == GL_DPY_WAYLAND)
    return fd->frame_ready;
#endif
  return gl_now () - fd->last_swap >= 0.012;
}

#ifdef HAVE_PGTK
static void gl_pgtk_after_paint (void *clock, void *data);
#endif

/* Ensure fd->surf is valid for the current frame window; return true when
   a swap-ready surface has been obtained.  Creates or recreates the EGL
   window surface when the native window handle changes.  Handles three
   cases: X11 (non-PGTK), PGTK/Wayland, and PGTK/X11 (GDK over X11).
   The shared blit-and-swap logic that follows is identical for all.  */
static bool
gl_ensure_egl_surface (struct gl_frame_data *fd)
{
  struct frame *f = fd->f;
  if (!f) return false;
  if (g_dpy_type == GL_DPY_SURFACELESS) return false;

#ifdef HAVE_PGTK
  if (!FRAME_PGTK_P (f)) return false;

# if defined GDK_WINDOWING_WAYLAND && defined HAVE_WAYLAND_EGL
  if (g_dpy_type == GL_DPY_WAYLAND)
    {
      GdkWindow *gdk_win = FRAME_GDK_WINDOW (f);
      if (!gdk_win) return false;
      struct wl_surface *parent_surf =
        gdk_wayland_window_get_wl_surface (gdk_win);
      if (!parent_surf) return false;

      if (fd->surf == EGL_NO_SURFACE || fd->wl_parent_surf != parent_surf)
        {
          /* Tear down stale EGL surface, wl_egl_window, and subsurface.  */
          if (fd->surf != EGL_NO_SURFACE)
            {
              if (g_bound_known && g_bound_surf == fd->surf)
                {
                  eglMakeCurrent (g_dpy, EGL_NO_SURFACE,
                                  EGL_NO_SURFACE, g_ctx);
                  g_bound_surf = EGL_NO_SURFACE;
                }
              eglDestroySurface (g_dpy, fd->surf);
              fd->surf = EGL_NO_SURFACE;
            }
          if (fd->wl_win)
            { wl_egl_window_destroy (fd->wl_win); fd->wl_win = NULL; }
          if (fd->wl_sub)
            { wl_subsurface_destroy (fd->wl_sub); fd->wl_sub = NULL; }
          if (fd->wl_surf && fd->wl_surf != fd->wl_parent_surf)
            { wl_surface_destroy (fd->wl_surf); fd->wl_surf = NULL; }

          int w = fd->w > 0 ? fd->w : 1;
          int h = fd->h > 0 ? fd->h : 1;
          fd->wl_parent_surf = parent_surf;

          /* Render into a wl_subsurface so that GDK's own shm frame
             commits to the parent surface never conflict with our EGL
             frames.  The subsurface is desync: it presents independently
             of any GDK parent commit.  Fall back to using the parent
             surface directly when wl_subcompositor is unavailable.  */
          GdkDisplay *gdpy = gdk_display_get_default ();
          struct wl_compositor *wl_comp =
            gdk_wayland_display_get_wl_compositor (gdpy);
          if (wl_comp && g_wl_subcompositor)
            {
              fd->wl_surf = wl_compositor_create_surface (wl_comp);
              fd->wl_sub  = wl_subcompositor_get_subsurface (
                              g_wl_subcompositor, fd->wl_surf, parent_surf);
              /* Real position set below (and refreshed on every ensure):
                 the parent wl_surface covers the whole toplevel, and the
                 edit area sits below the GTK menu bar.  */
              wl_subsurface_set_position (fd->wl_sub, 0, 0);
              wl_subsurface_set_desync (fd->wl_sub);
              /* Clear input region: our subsurface is purely for rendering;
                 all pointer/keyboard input must reach GDK's parent surface.
                 The Wayland default (infinite region) would steal events.  */
              struct wl_region *empty = wl_compositor_create_region (wl_comp);
              wl_surface_set_input_region (fd->wl_surf, empty);
              wl_region_destroy (empty);
              wl_surface_commit (fd->wl_surf);
            }
          else
            fd->wl_surf = parent_surf; /* legacy fallback, may flicker */

          fd->wl_win = wl_egl_window_create (fd->wl_surf, w, h);
          if (!fd->wl_win) return false;
          fd->surf = eglCreateWindowSurface (g_dpy, g_cfg,
                                             (EGLNativeWindowType) fd->wl_win,
                                             NULL);
          if (fd->surf == EGL_NO_SURFACE)
            {
              wl_egl_window_destroy (fd->wl_win);
              fd->wl_win = NULL;
              return false;
            }
          fd->surf_win = 0;
          for (int i = 0; i < GL_SWAP_RING; i++)
            { gl_dirty_clear (&fd->swap_dirty[i]);
              fd->swap_dirty[i].all = true; }
          fd->surf_w = fd->surf_h = -1;
        }
      else
        {
          /* Wayland requires an explicit resize when the frame size changes;
             the EGL surface dimensions update on the next eglSwapBuffers.  */
          int w = fd->w > 0 ? fd->w : 1;
          int h = fd->h > 0 ? fd->h : 1;
          wl_egl_window_resize (fd->wl_win, w, h, 0, 0);
        }

      /* Keep the subsurface anchored to the edit area's offset inside
         the toplevel: the parent wl_surface covers the whole toplevel
         window, and rendering at (0,0) would cover the GTK menu bar and
         shift the frame content up by its height (caught by the Wayland
         parity suite: every category off by the menu-bar height).  The
         offset is parent-surface state, applied on GDK's next commit.  */
      if (fd->wl_sub)
        {
          GtkWidget *edit = FRAME_GTK_WIDGET (f);
          GtkWidget *top = edit ? gtk_widget_get_toplevel (edit) : NULL;
          int ox = 0, oy = 0;
          if (edit && top
              && gtk_widget_translate_coordinates (edit, top, 0, 0,
                                                   &ox, &oy)
              && (ox != fd->wl_sub_x || oy != fd->wl_sub_y))
            {
              wl_subsurface_set_position (fd->wl_sub, ox, oy);
              fd->wl_sub_x = ox;
              fd->wl_sub_y = oy;
              /* The new position only latches on a parent commit; GDK
                 commits the parent on its own cadence, which is fine for
                 a one-time layout change like the menu bar appearing.  */
            }
        }
      return true;
    }
# endif /* GDK_WINDOWING_WAYLAND && HAVE_WAYLAND_EGL */

  /* PGTK/X11: the EGL display was obtained from the X11 Display* via dlsym
     in gl_global_init.  Get the XID of GDK's backing X window the same way
     to avoid including gdkx.h (conflicts with pgtkgui.h typedefs).  */
  if (g_dpy_type == GL_DPY_X11)
    {
      GdkWindow *gdk_win = FRAME_GDK_WINDOW (f);
      if (!gdk_win) return false;
      typedef uintptr_t (*get_xid_fn) (GdkWindow *);
      get_xid_fn gx =
        (get_xid_fn) dlsym (RTLD_DEFAULT, "gdk_x11_window_get_xid");
      if (!gx) return false;
      uintptr_t xid = gx (gdk_win);
      if (!xid) return false;

      if (fd->surf == EGL_NO_SURFACE || fd->surf_win != xid)
        {
          if (fd->surf != EGL_NO_SURFACE)
            {
              if (g_bound_known && g_bound_surf == fd->surf)
                {
                  eglMakeCurrent (g_dpy, EGL_NO_SURFACE,
                                  EGL_NO_SURFACE, g_ctx);
                  g_bound_surf = EGL_NO_SURFACE;
                }
              eglDestroySurface (g_dpy, fd->surf);
            }
          fd->surf = eglCreateWindowSurface (g_dpy, g_cfg,
                                             (EGLNativeWindowType) xid,
                                             NULL);
          fd->surf_win = xid;
          if (fd->surf == EGL_NO_SURFACE) return false;
          for (int i = 0; i < GL_SWAP_RING; i++)
            { gl_dirty_clear (&fd->swap_dirty[i]);
              fd->swap_dirty[i].all = true; }
          fd->surf_w = fd->surf_h = -1;

          /* Stop the X server from filling exposed areas of this window
             with its background: GTK's scroll bars are native child X
             windows, and when one moves on a frame resize the server
             fills the strip it vacated with the (white) background
             AFTER our present -- no GTK paint follows, so nothing ever
             repairs the band (QA 15-transitions, deterministic).  With
             background_pixmap = None the server leaves the previous
             pixels (ours) in place instead.  Xlib is reached via dlsym
             like the GDK X11 helpers (gdkx.h stays excluded).  */
          {
            typedef void *(*get_xdpy_fn) (void *);
            typedef int (*set_bg_fn) (void *, unsigned long, unsigned long);
            get_xdpy_fn gxd =
              (get_xdpy_fn) dlsym (RTLD_DEFAULT,
                                   "gdk_x11_display_get_xdisplay");
            set_bg_fn xsb =
              (set_bg_fn) dlsym (RTLD_DEFAULT,
                                 "XSetWindowBackgroundPixmap");
            if (gxd && xsb)
              {
                void *xdpy = gxd (gdk_window_get_display (gdk_win));
                if (xdpy)
                  xsb (xdpy, xid, 0UL /* None */);
              }
          }

          /* Present again after every GTK paint: with client-side windows
             GTK composites widget paints through this same X window and
             would otherwise overwrite our content (see
             gl_pgtk_after_paint).  */
          GdkFrameClock *fc = gdk_window_get_frame_clock (gdk_win);
          if (fc && (!fd->after_paint_id || fd->frame_clock != (void *) fc))
            {
              if (fd->after_paint_id && fd->frame_clock)
                g_signal_handler_disconnect (fd->frame_clock,
                                             fd->after_paint_id);
              fd->after_paint_id =
                g_signal_connect_after (fc, "after-paint",
                                        G_CALLBACK (gl_pgtk_after_paint), fd);
              fd->frame_clock = fc;
            }
        }
      return true;
    }

  return false;  /* Wayland not available and not on an X11 PGTK session */

#else  /* !HAVE_PGTK: X11 build */

  if (!FRAME_X_P (f)) return false;
  Window win = FRAME_X_WINDOW (f);
  if (!win) return false;
  if (fd->surf == EGL_NO_SURFACE || fd->surf_win != (unsigned long) win)
    {
      if (fd->surf != EGL_NO_SURFACE)
        {
          if (g_bound_known && g_bound_surf == fd->surf)
            {
              eglMakeCurrent (g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g_ctx);
              g_bound_surf = EGL_NO_SURFACE;
            }
          eglDestroySurface (g_dpy, fd->surf);
        }
      fd->surf = eglCreateWindowSurface (g_dpy, g_cfg,
                                         (EGLNativeWindowType) win, NULL);
      fd->surf_win = (unsigned long) win;
      if (fd->surf == EGL_NO_SURFACE) return false;
      for (int i = 0; i < GL_SWAP_RING; i++)
        { gl_dirty_clear (&fd->swap_dirty[i]); fd->swap_dirty[i].all = true; }
      fd->surf_w = fd->surf_h = -1;
    }
  return true;

#endif /* !HAVE_PGTK */
}

/* Forward declaration needed by gl_wl_frame_cb_done below.  */
static void gl_present_to_window (struct gl_frame_data *fd);

/* wl_surface.frame callback: the compositor fires this once per displayed
   frame to tell us when it is ready for the next submission.  We use it
   as an event-driven vsync gate in the animation pump (gl_swap_ok), so the
   pump never submits faster than the compositor can display.  */
#if defined HAVE_PGTK && defined GDK_WINDOWING_WAYLAND && defined HAVE_WAYLAND_EGL
static void
gl_wl_frame_cb_done (void *data, struct wl_callback *cb, uint32_t serial)
{
  (void) serial;
  struct gl_frame_data *fd = data;
  wl_callback_destroy (cb);
  fd->frame_cb = NULL;
  fd->frame_ready = true;
  /* If a redisplay present was deferred while waiting for this callback
     (needs_present set in gl_drv_end_frame), issue it now.  The EGL
     context is still current from the last gl_present_to_window call.  */
  if (fd->needs_present)
    {
      gl_present_to_window (fd);
      fd->needs_present = false;
    }
}
static const struct wl_callback_listener gl_wl_frame_cb_listener = {
  gl_wl_frame_cb_done
};
#endif /* HAVE_PGTK && GDK_WINDOWING_WAYLAND && HAVE_WAYLAND_EGL */

#ifdef HAVE_PGTK
/* GdkFrameClock "after-paint" handler, PGTK/X11 sessions only.  GTK3's
   client-side windows composite every widget paint through the SAME X
   window our EGL surface presents to, so whatever GTK flushes after our
   swap overwrites those pixels.  Seen live: relocating the GtkScrollbar
   on a frame resize makes GTK wipe the vacated strip to the widget
   background AFTER the present that followed the resize, leaving a
   permanent stale band (QA 15-transitions, deterministic).  Re-presenting
   after every GTK paint keeps the frame content on top; EGL swaps do not
   feed back into GTK's paint cycle, so this cannot loop.  */
static void
gl_pgtk_after_paint (void *clock, void *data)
{
  (void) clock;
  struct gl_frame_data *fd = data;
  if (!fd || fd->in_cycle || fd->surf == EGL_NO_SURFACE)
    return;
  gl_present_to_window (fd);
}
#endif /* HAVE_PGTK */

/* Blit the finished static texture to the frame's on-screen window and swap.
   A no-op when the display is surfaceless (headless benchmark / capture).
   The FBO still holds the frame for gl_capture_frame either way.  */
static void
gl_present_to_window (struct gl_frame_data *fd)
{
  struct frame *f = fd->f;
  if (!f) return;

  /* Quads queued for this frame target its FBO; emit them before the
     draw framebuffer switches to the window.  */
  if (g_glyph_batch_fd == fd)
    gl_flush_glyph_batch ();

#if defined HAVE_PGTK && defined HAVE_WAYLAND_EGL
  /* Toolkit scroll bars live on GDK's parent surface, UNDERNEATH this
     subsurface, and the drawing policy paints the frame background over
     their gutters (alpha 1) like on X11 -- where the X server clips the
     presents under the native scroll-bar windows.  Wayland has no such
     clipping, so punch transparent holes at the bar rects on every
     present: with an alpha-bearing config the compositor shows GTK's
     scroll bars through them.  Any redraw repaints the area, so the
     holes are re-punched here each time; when a bar moves, the vacated
     area is repainted by redisplay and presents opaque again.  */
  if (g_dpy_type == GL_DPY_WAYLAND && g_cfg_alpha > 0 && fd->wl_sub)
    {
      bool punched = false;
      for (Lisp_Object b = FRAME_SCROLL_BARS (f); !NILP (b);
           b = XSCROLL_BAR (b)->next)
        {
          struct scroll_bar *sb = XSCROLL_BAR (b);
          if (sb->width <= 0 || sb->height <= 0)
            continue;
          if (!punched)
            {
              glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
              glEnable (GL_SCISSOR_TEST);
              glClearColor (0.0f, 0.0f, 0.0f, 0.0f);
              punched = true;
            }
          int y = fd->h - (sb->top + sb->height);
          glScissor (sb->left, y < 0 ? 0 : y, sb->width, sb->height);
          glClear (GL_COLOR_BUFFER_BIT);
          gl_mark_dirty (fd, sb->left, sb->top, sb->width, sb->height);
          if (getenv ("GL_LOG_PRESENT"))
            fprintf (stderr, "[glpunch] %d,%d %dx%d (fd %dx%d)\n",
                     sb->left, sb->top, sb->width, sb->height,
                     fd->w, fd->h);
        }
      if (punched)
        glDisable (GL_SCISSOR_TEST);
      /* Diagnostic: GL_DEBUG_HOLE=1 punches a fixed hole mid-frame to
         verify the compositor actually blends this subsurface.  */
      if (getenv ("GL_DEBUG_HOLE"))
        {
          glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
          glEnable (GL_SCISSOR_TEST);
          glClearColor (0.0f, 0.0f, 0.0f, 0.0f);
          glScissor (100, fd->h - 300, 200, 200);
          glClear (GL_COLOR_BUFFER_BIT);
          glDisable (GL_SCISSOR_TEST);
          gl_mark_dirty (fd, 100, 100, 200, 200);
        }
    }
#endif

  if (!gl_ensure_egl_surface (fd)) return;

  if (!gl_bind_surface (fd->surf))
    return;

  /* A window-manager resize reaches the server and reallocates the EGL
     buffers asynchronously; Mesa can hand us a pre-resize size AND a
     pre-resize buffer age for a present that actually lands on a fresh
     (zero-filled) buffer -- a partial blit then leaves visible garbage
     for a frame (caught live by GL_VERIFY_PRESENT: 41% of the buffer
     wrong on a maximize, with age=2).  The client cannot win that race
     beforehand, but right after the swap Mesa HAS validated the new
     geometry, so: present, re-query the size, and if it changed under
     us, immediately present again in full at the true size.  Bounded to
     one retry; the steady state pays one cached-state query per swap.  */
  int size_retry = 0;
 retry_present:;

  /* Swap interval.  Vsync on by default: the blocking swap is the tear
     protection on a bare X server, and on radeonsi it also keeps the
     swapchain rotation tight -- running interval 0 under a compositor
     was tried (the compositor already guarantees tear-free output) and
     the loose buffer rotation brought back the stale-frame flashes the
     12ms present throttle had fixed (an ancient pre-resize buffer shown
     for one vblank during fades).  Swap blocking no longer starves the
     Lisp timers either, now that the unified animation pump issues at
     most one present per tick instead of one per subsystem.
     GL_NO_VSYNC=1 frees the swap from the vblank (throughput
     benchmarks); GL_FORCE_VSYNC=1 reserved for symmetry.  */
  {
    static int vsync = -1;
    if (vsync == -1)
      vsync = getenv ("GL_NO_VSYNC") ? 0 : 1;
    eglSwapInterval (g_dpy, vsync);
  }

  /* The video / cursor-effect / cross-fade overlays paint straight onto
     the back buffer after the blit, so their pixels are not in the FBO:
     any present involving an overlay blits and records full.  An idle
     burst-mode cursor (no live particles) emits nothing and does not
     count, so plain typing under the default effect still goes partial.  */
  bool overlay = (fd->trans_dur > 0 || gl_anim_overlay_active (fd));
#ifdef HAVE_GSTREAMER
  overlay = overlay || fd->video != NULL;
#endif

  /* Partial presents (blit only what the aged back buffer is missing,
     hand the compositor damage rectangles) are OPT-IN, experimental:
     GL_PARTIAL_PRESENT=1.  They buy ~10% on workloads that already run
     above a thousand frames per second, and they cost correctness fights
     on three asynchronous fronts at once -- the driver's buffer rotation
     (ages observed lying across reallocations), the window manager's
     resizes, and the compositor's damage-driven texture updates.  The
     default present is the robust one: blit the whole frame, swap with
     full damage.  A full blit of a laptop-sized frame is a fraction of a
     millisecond of pure GPU copy; stability is worth far more.  */
  static int partial_enabled = -1, log_present = -1;
  if (partial_enabled == -1)
    {
      partial_enabled = (getenv ("GL_PARTIAL_PRESENT")
                         && !getenv ("GL_NO_DAMAGE")) ? 1 : 0;
      log_present = getenv ("GL_LOG_PRESENT") ? 1 : 0;
    }
  static unsigned long present_seq;
  present_seq++;

  /* Buffer age: how many swaps ago this back buffer was last presented
     (0 = new/reallocated/unknown).  Queried after make-current, before
     any rendering to the buffer, as the extension requires.  Always
     queried, not just on partial-eligible presents: an age of 0 is also
     how we learn the buffer was REALLOCATED, which is what happens when
     the window manager resizes the window before Emacs has processed the
     ConfigureNotify (the FBO still has the old size).  */
  EGLint age = 0;
  if (g_has_buffer_age && partial_enabled)
    eglQuerySurface (g_dpy, fd->surf, EGL_BUFFER_AGE_EXT, &age);

  /* Surface size.  Re-queried when the cache disagrees with the FBO (a
     resize Emacs has already processed), when the buffer age says this
     buffer is fresh (a resize Emacs has NOT processed yet reallocates
     the buffers; blitting the stale size would leave undefined -- often
     black -- bands beside old content until the next redisplay), and on
     every present bound for a full blit anyway (overlay frames, whole-
     frame changes, no age extension): those are the rare paths, and a
     full blit with a stale size would not cover a just-resized window.
     Only the steady partial path trusts the cache, and there age >= 1
     vouches that the buffer (hence its size) is unchanged.  */
  if (fd->surf_w != fd->w || fd->surf_h != fd->h
      || age == 0 || overlay || fd->dirty.all
      || !g_has_buffer_age || !partial_enabled)
    {
      EGLint qw = fd->w, qh = fd->h;
      eglQuerySurface (g_dpy, fd->surf, EGL_WIDTH, &qw);
      eglQuerySurface (g_dpy, fd->surf, EGL_HEIGHT, &qh);
      fd->surf_w = qw;
      fd->surf_h = qh;
    }
  EGLint sw = fd->surf_w, sh = fd->surf_h;

  /* A partial repair is only meaningful against a buffer whose content
     and size the age vouches for.  */
  if (overlay || fd->dirty.all || sw != fd->w || sh != fd->h)
    age = 0;

  /* Repair set: what this back buffer is missing = the changes since the
     last swap plus everything the (age - 1) swaps in between wrote.
     Unknown age, a too-old buffer, or a full-frame slot in the chain
     falls back to the always-correct full blit.  */
  struct gl_dirty_set repair = fd->dirty;
  bool full = true;
  if (age > 0 && age <= GL_SWAP_RING)
    {
      full = false;
      for (int i = 0; i < age - 1 && !repair.all; i++)
        gl_dirty_union (&repair,
                        &fd->swap_dirty[(fd->swap_head - 1 - i + GL_SWAP_RING)
                                        % GL_SWAP_RING]);
      full = repair.all;
    }

  if (log_present)
    fprintf (stderr, "[glpresent] #%lu t=%.4f fbo=%dx%d window=%dx%d age=%d %s"
             " boxes=%d trans=%.3f cycle=%d\n",
             present_seq, gl_now (), fd->w, fd->h, sw, sh, (int) age,
             full ? "full" : "partial", full ? 1 : repair.n,
             fd->trans_dur > 0 ? gl_now () - fd->trans_start : -1.0,
             (int) fd->in_cycle);

  /* Both the FBO and the window's default framebuffer use GL bottom-left
     origin, so a straight (unflipped) blit lands right-side-up on screen.
     gl_capture_frame, which targets a top-left PPM, flips; this does not.  */
  glBindFramebuffer (GL_READ_FRAMEBUFFER, fd->fbo);
  glBindFramebuffer (GL_DRAW_FRAMEBUFFER, 0);
  glDisable (GL_SCISSOR_TEST);
  if (full)
    glBlitFramebuffer (0, 0, fd->w, fd->h, 0, 0, sw, sh,
                       GL_COLOR_BUFFER_BIT, GL_NEAREST);
  else
    for (int i = 0; i < repair.n; i++)
      {
        const int *b = repair.b[i];
        glBlitFramebuffer (b[0], b[1], b[2], b[3], b[0], b[1], b[2], b[3],
                           GL_COLOR_BUFFER_BIT, GL_NEAREST);
      }
  /* repair.n == 0: nothing changed since this buffer was shown; just swap.  */

  /* GL_VERIFY_PRESENT=1: read the repaired back buffer and the FBO back
     and compare, BEFORE the overlays (which legitimately diverge).  Any
     mismatch is a partial-repair hole -- the exact source of "stale or
     black rectangle" artifacts -- caught at the present that produced it,
     with its age and box count.  Debug-only: two full-frame readbacks per
     present.  */
  {
    static int verify = -1;
    if (verify == -1) verify = getenv ("GL_VERIFY_PRESENT") ? 1 : 0;
    if (verify && sw == fd->w && sh == fd->h)
      {
        size_t n = (size_t) fd->w * fd->h * 4;
        unsigned char *back = malloc (n), *fbop = malloc (n);
        if (back && fbop)
          {
            glBindFramebuffer (GL_READ_FRAMEBUFFER, 0);
            glReadPixels (0, 0, fd->w, fd->h, GL_RGBA, GL_UNSIGNED_BYTE, back);
            glBindFramebuffer (GL_READ_FRAMEBUFFER, fd->fbo);
            glReadPixels (0, 0, fd->w, fd->h, GL_RGBA, GL_UNSIGNED_BYTE, fbop);
            size_t bad = 0;
            for (size_t i = 0; i < n; i += 4)
              if (back[i] != fbop[i] || back[i+1] != fbop[i+1]
                  || back[i+2] != fbop[i+2])
                bad++;
            if (bad)
              fprintf (stderr,
                       "[glverify] MISMATCH %zu px (age=%d %s boxes=%d)\n",
                       bad, (int) age, full ? "full" : "partial",
                       full ? 1 : repair.n);
          }
        free (back);
        free (fbop);
        glBindFramebuffer (GL_READ_FRAMEBUFFER, fd->fbo);
      }
  }

#ifdef HAVE_GSTREAMER
  /* Inline video overlay: draw the latest decoded frame over the static
     content at its rect, clipped to the window interior, so redisplay can
     keep treating the placeholder area as ordinary buffer background.
     Mirrors MtlFrameData -compositeToScreen.  */
  gl_video_overlay (fd, sw, sh);
#endif

  /* Cursor animation overlay (spring/trail/particles).  Drawn over the
     static content, like the Metal compositor's animation pass.  */
  if (g_gl_animations_enabled)
    gl_anim_overlay (fd, sw, sh);

  /* Buffer-switch cross-fade: draw the previous-frame snapshot over the
     just-blitted new content at a fading alpha.  The snapshot was copied
     from the FBO (bottom-left), so the quad samples it with v flipped to
     match the default framebuffer.  */
  if (fd->trans_dur > 0 && fd->trans_tex
      && fd->trans_w == fd->w && fd->trans_h == fd->h)
    {
      double p = (gl_now () - fd->trans_start) / fd->trans_dur;
      if (p >= 1.0)
        fd->trans_dur = 0;              /* fade complete */
      else
        {
          float a = (float) (1.0 - p);
          a = a * a * (3.0f - 2.0f * a);   /* smoothstep fade-out */
          float fw = (float) sw, fh = (float) sh;
          float v[] = {
            0,0,  0,1,   fw,0, 1,1,   fw,fh, 1,0,
            0,0,  0,1,   fw,fh, 1,0,  0,fh,  0,0,
          };
          glViewport (0, 0, sw, sh);
          glUseProgram (g_prog_image);
          glUniform2f (g_u_image_size, fw, fh);
          glActiveTexture (GL_TEXTURE0);
          glBindTexture (GL_TEXTURE_2D, fd->trans_tex);
          glUniform1i (g_u_image_tex, 0);
          glUniform1f (g_u_image_alpha, a);
          glBindBuffer (GL_ARRAY_BUFFER, g_vbo);
          glBufferData (GL_ARRAY_BUFFER, sizeof v, v, GL_STREAM_DRAW);
          glEnableVertexAttribArray (0);
          glVertexAttribPointer (0, 2, GL_FLOAT, GL_FALSE, 16, (void *) 0);
          glEnableVertexAttribArray (1);
          glVertexAttribPointer (1, 2, GL_FLOAT, GL_FALSE, 16, (void *) 8);
          glBlendFunc (GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
          glDrawArrays (GL_TRIANGLES, 0, 6);
          glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        }
    }

  /* Swap, handing the compositor the regions that differ from what is on
     screen (the current frame's changes, not the age repairs: those match
     the screen already).  The compositor then recomposites only those
     bands.  Zero rects means full damage, which is also the fallback
     without the extension.  GL_PRESENT_FINISH=1 drains the GPU first
     (diagnostic knob for present-order races in the GL stack).  */
  {
    static int finish = -1;
    if (finish == -1) finish = getenv ("GL_PRESENT_FINISH") ? 1 : 0;
    if (finish) glFinish ();
  }
  EGLBoolean swapped;
  if (partial_enabled && g_swap_damage && !overlay && !fd->dirty.all
      && fd->dirty.n > 0 && sw == fd->w && sh == fd->h)
    {
      EGLint rects[GL_DIRTY_MAX * 4];
      for (int i = 0; i < fd->dirty.n; i++)
        {
          const int *b = fd->dirty.b[i];
          rects[i * 4 + 0] = b[0];
          rects[i * 4 + 1] = b[1];
          rects[i * 4 + 2] = b[2] - b[0];
          rects[i * 4 + 3] = b[3] - b[1];
        }
      swapped = g_swap_damage (g_dpy, fd->surf, rects, fd->dirty.n);
    }
  else
    swapped = eglSwapBuffers (g_dpy, fd->surf);

  /* A failed swap presented nothing: keep the dirty set accumulating and
     leave the ring alone, or it would desynchronize from the driver's
     buffer rotation and future repairs would index the wrong slots
     (stale content on screen).  The next present retries.  */
  if (!swapped)
    {
      glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
      return;
    }

  /* Record what this swap changed, so future presents can repair an aged
     back buffer, and start a fresh dirty set: everything accumulated so
     far is on screen now.  Overlay pixels live outside the FBO, so an
     overlay frame is recorded as full.  */
  fd->swap_dirty[fd->swap_head] = fd->dirty;
  if (overlay)
    fd->swap_dirty[fd->swap_head].all = true;
  fd->swap_head = (fd->swap_head + 1) % GL_SWAP_RING;
  gl_dirty_clear (&fd->dirty);
  fd->last_swap = gl_now ();

  /* Post-swap size recheck (see the comment at retry_present): if the
     surface turns out to have resized under this present, what just went
     on screen is partially undefined -- republish everything at the true
     size right now instead of leaving the artifact up until the next
     redisplay.  */
  {
    EGLint qw = sw, qh = sh;
    eglQuerySurface (g_dpy, fd->surf, EGL_WIDTH, &qw);
    eglQuerySurface (g_dpy, fd->surf, EGL_HEIGHT, &qh);
    if ((qw != sw || qh != sh) && size_retry++ == 0)
      {
        fd->surf_w = qw;
        fd->surf_h = qh;
        fd->dirty.all = true;
        goto retry_present;
      }
  }

  /* On Wayland, request a wl_surface.frame callback so the compositor
     signals when it is ready for the next frame (event-driven vsync).
     This replaces the 12 ms time gate in the animation pump (gl_swap_ok).
     Flush immediately so the compositor receives the request before the
     next event-loop iteration.  Register after any size-recheck retry so
     exactly one callback is pending after the final swap.  */
#if defined HAVE_PGTK && defined GDK_WINDOWING_WAYLAND && defined HAVE_WAYLAND_EGL
  if (g_dpy_type == GL_DPY_WAYLAND && fd->wl_surf)
    {
      if (fd->frame_cb)
        { wl_callback_destroy (fd->frame_cb); fd->frame_cb = NULL; }
      fd->frame_cb = wl_surface_frame (fd->wl_surf);
      wl_callback_add_listener (fd->frame_cb, &gl_wl_frame_cb_listener, fd);
      fd->frame_ready = false;
      struct wl_display *wl_dpy =
        gdk_wayland_display_get_wl_display (gdk_display_get_default ());
      if (wl_dpy) wl_display_flush (wl_dpy);
    }
#endif

  /* Keep the window surface current (FBO rendering does not care which
     surface is bound), so the next frame needs no make-current at all.  */
  glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
}

static void
gl_drv_end_frame (struct frame *f, bool present_p)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd) return;
  gl_flush_glyph_batch ();   /* drain any quads left from the last string */
  fd->in_cycle = false;
  g_cur = NULL;
  if (present_p)
    {
      /* On Wayland the compositor signals readiness via wl_surface.frame; a
         second present before that callback fires submits to a swapchain slot
         that still holds the content from two frames ago, producing visible
         flicker.  Defer until gl_swap_ok so at most one swap per vblank goes
         out; the pump or the next redisplay will flush needs_present.
         On X11 / surfaceless the time-gate in gl_swap_ok guards the pump;
         non-pump presents are rare enough that the 12 ms gap is never hit,
         so we leave them unconditional to keep input latency minimal.  */
#if defined HAVE_PGTK && defined HAVE_WAYLAND_EGL
      if (g_dpy_type == GL_DPY_WAYLAND && !gl_swap_ok (fd))
        { glFlush (); fd->needs_present = true; }
      else
#endif
        { gl_present_to_window (fd); fd->needs_present = false; }
    }
  else
    {
      /* Deferred: start the GPU on the frame now so the work overlaps
         the wait until flush_display presents it.  */
      glFlush ();
      fd->needs_present = true;
    }
}

static void
gl_drv_present (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd) return;
  gl_present_to_window (fd);
  fd->needs_present = false;
}

static bool
gl_drv_in_cycle (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  return fd && fd->in_cycle;
}

static bool
gl_drv_pending_present (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  return fd && fd->needs_present;
}

/* The clip ops only record state: batched quads are clipped on the CPU
   at queue time (gl_batch_append), and the non-batched primitives apply
   the recorded rect as a real scissor right before they draw
   (gl_scissor_apply_now).  Neither needs the batch flushed.  */

static void
gl_drv_clip_to_glyph_string (struct glyph_string *s)
{
  struct gl_frame_data *fd = gl_get_frame_data (s->f);
  if (!fd) return;
  NativeRectangle r;
  get_glyph_string_clip_rect (s, &r);
  fd->clip_on = true;
  fd->clip_x = r.x;
  fd->clip_y = r.y;
  fd->clip_w = r.width;
  fd->clip_h = r.height;
}

static void
gl_drv_clear_clip (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd) return;
  fd->clip_on = false;
}

static void
gl_drv_fill_rect (struct frame *f, int x, int y, int w, int h,
                  unsigned long color)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || w <= 0 || h <= 0) return;
  /* A solid rect is a quad sampling the atlas' white block: coverage 1.0
     passes the gamma curve unchanged, so it joins the glyph batch with
     no program switch and no flush.  */
  float s = (float) fd->scale;
  float rgba[4];
  gl_unpack_color (color, rgba);
  gl_batch_append (fd, x * s, y * s, (x + w) * s, (y + h) * s,
                   GL_WHITE_U, GL_WHITE_V, GL_WHITE_U, GL_WHITE_V, rgba);
}

static void
gl_drv_copy_region (struct frame *f, int x, int y, int w, int h,
                    int dst_x, int dst_y)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || w <= 0 || h <= 0) return;
  gl_flush_glyph_batch ();   /* the blit must see already-drawn glyphs */
  gl_mark_dirty (fd, dst_x, dst_y, w, h);
  if (getenv ("GL_LOG_SCROLL"))
    fprintf (stderr, "[glscroll] copy %dx%d from (%d,%d) to (%d,%d)\n",
             w, h, x, y, dst_x, dst_y);
  double s = fd->scale;
  int sx = (int) (x * s), sy = (int) (y * s);
  int dx = (int) (dst_x * s), dy = (int) (dst_y * s);
  int sw = (int) (w * s), sh = (int) (h * s);
  /* Clamp the move to the FBO.  During a resize race Emacs can ask for a
     scroll computed against the old frame size; a blit whose SOURCE rect
     leaves the read buffer writes UNDEFINED pixels (on radeonsi: recycled
     VRAM, i.e. fragments of old frames) into the destination.  Trim both
     rects by the same amount so the copy stays a pure translation.  */
  {
    int lo = sx < dx ? sx : dx;          /* leftmost edge of either rect */
    if (lo < 0) { sx -= lo; dx -= lo; sw += lo; }
    lo = sy < dy ? sy : dy;
    if (lo < 0) { sy -= lo; dy -= lo; sh += lo; }
    int hi = sx > dx ? sx : dx;          /* rightmost start of either rect */
    if (hi + sw > fd->w) sw = fd->w - hi;
    hi = sy > dy ? sy : dy;
    if (hi + sh > fd->h) sh = fd->h - hi;
    if (sw <= 0 || sh <= 0) return;
  }
  int sy0 = fd->h - (sy + sh), dy0 = fd->h - (dy + sh);
  glDisable (GL_SCISSOR_TEST);
  if (dx >= sx + sw || sx >= dx + sw || dy0 >= sy0 + sh || sy0 >= dy0 + sh)
    {
      /* Source and destination are disjoint (page scrolls, large jumps):
         one direct blit within the FBO is legal and halves the bandwidth.
         Only OVERLAPPING blits are undefined in ES 3.  */
      glBindFramebuffer (GL_READ_FRAMEBUFFER, fd->fbo);
      glBindFramebuffer (GL_DRAW_FRAMEBUFFER, fd->fbo);
      glBlitFramebuffer (sx, sy0, sx + sw, sy0 + sh,
                         dx, dy0, dx + sw, dy0 + sh,
                         GL_COLOR_BUFFER_BIT, GL_NEAREST);
    }
  else
    {
      /* Overlapping move (single-line scrolls): bounce through the
         scratch target so the copy is safe.  */
      glBindFramebuffer (GL_READ_FRAMEBUFFER, fd->fbo);
      glBindFramebuffer (GL_DRAW_FRAMEBUFFER, fd->scratch_fbo);
      glBlitFramebuffer (sx, sy0, sx + sw, sy0 + sh,
                         sx, sy0, sx + sw, sy0 + sh,
                         GL_COLOR_BUFFER_BIT, GL_NEAREST);
      glBindFramebuffer (GL_READ_FRAMEBUFFER, fd->scratch_fbo);
      glBindFramebuffer (GL_DRAW_FRAMEBUFFER, fd->fbo);
      glBlitFramebuffer (sx, sy0, sx + sw, sy0 + sh,
                         dx, dy0, dx + sw, dy0 + sh,
                         GL_COLOR_BUFFER_BIT, GL_NEAREST);
    }
  glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
}

static bool
gl_drv_font_ready_p (struct font *font)
{
  if (!font) return false;
  struct font_info *fi = (struct font_info *) font;
  return fi->cr_scaled_font != NULL;
}

static struct gfx_glyph *
gl_drv_get_glyph (struct font *font, unsigned int glyph_id)
{
  if (!font || glyph_id == 0) return NULL;
  unsigned long long key =
    ((unsigned long long) (uintptr_t) font * 6364136223846793005ULL)
    ^ (unsigned long long) glyph_id;
  struct gfx_glyph *e = glyph_cache_lookup (key);
  if (e) return e;
  return gl_rasterize_glyph (font, glyph_id, key);
}

/* Emit the queued quads -- glyphs and solid rects share the program, the
   atlas and one submission-ordered vertex stream -- as a single draw
   call.  Every quad was clipped on the CPU against the clip rect in
   effect when it was queued (gl_batch_append), so the draw itself runs
   scissor-free; the non-batched primitives re-apply the scissor
   themselves (gl_scissor_apply_now).  */
static void
gl_flush_glyph_batch (void)
{
  if (g_glyph_batch_verts == 0 || !g_glyph_batch_fd) return;
  struct gl_frame_data *fd = g_glyph_batch_fd;
  glDisable (GL_SCISSOR_TEST);          /* quads are pre-clipped */
  glUseProgram (g_prog_glyph);
  glUniform2f (g_u_glyph_size, (float) fd->w, (float) fd->h);
  glActiveTexture (GL_TEXTURE0);
  glBindTexture (GL_TEXTURE_2D, g_atlas);
  glUniform1i (g_u_glyph_atlas, 0);
  glBindBuffer (GL_ARRAY_BUFFER, g_vbo);
  glBufferData (GL_ARRAY_BUFFER,
                (GLsizeiptr) g_glyph_batch_verts * GL_GLYPH_VERT_FLOATS
                * sizeof (float),
                g_glyph_batch, GL_STREAM_DRAW);
  glEnableVertexAttribArray (0);
  glVertexAttribPointer (0, 2, GL_FLOAT, GL_FALSE, 32, (void *) 0);
  glEnableVertexAttribArray (1);
  glVertexAttribPointer (1, 2, GL_FLOAT, GL_FALSE, 32, (void *) 8);
  glEnableVertexAttribArray (2);
  glVertexAttribPointer (2, 4, GL_FLOAT, GL_FALSE, 32, (void *) 16);
  glDrawArrays (GL_TRIANGLES, 0, g_glyph_batch_verts);
  g_glyph_batch_verts = 0;
}

/* Queue one textured quad (physical pixel coords, top-left origin) into
   the shared batch.  The quad is clipped here on the CPU against FD's
   current clip rect -- computed with the same integer casts the GL
   scissor used, so the pixel result is identical -- with the texture
   coordinates adjusted proportionally.  Clipping at queue time is what
   lets the batch run scissor-free and survive across glyph strings: a
   full-frame redraw becomes a handful of draw calls.  */
static void
gl_batch_append (struct gl_frame_data *fd, float x0, float y0,
                 float x1, float y1, float u0, float v0,
                 float u1, float v1, const float rgba[4])
{
  if (x0 >= x1 || y0 >= y1)
    return;                     /* degenerate quad: nothing to draw */

  /* A batch targets one frame's FBO; if the frame changed, flush first.  */
  if (g_glyph_batch_fd && g_glyph_batch_fd != fd)
    gl_flush_glyph_batch ();
  g_glyph_batch_fd = fd;

  if (fd->clip_on)
    {
      double s = fd->scale;
      float cx0 = (float) (int) (fd->clip_x * s);
      float cy0 = (float) (int) (fd->clip_y * s);
      float cx1 = cx0 + (float) (int) (fd->clip_w * s);
      float cy1 = cy0 + (float) (int) (fd->clip_h * s);
      if (x0 >= cx1 || x1 <= cx0 || y0 >= cy1 || y1 <= cy0)
        return;
      float du = (u1 - u0) / (x1 - x0), dv = (v1 - v0) / (y1 - y0);
      if (x0 < cx0) { u0 += du * (cx0 - x0); x0 = cx0; }
      if (x1 > cx1) { u1 -= du * (x1 - cx1); x1 = cx1; }
      if (y0 < cy0) { v0 += dv * (cy0 - y0); y0 = cy0; }
      if (y1 > cy1) { v1 -= dv * (y1 - cy1); y1 = cy1; }
    }

  /* Mark the clipped box dirty (top-left physical -> bottom-left FBO).  */
  {
    int px0 = (int) floorf (x0), px1 = (int) ceilf (x1);
    int fy0 = fd->h - (int) ceilf (y1);
    int fy1 = fd->h - (int) floorf (y0);
    if (px0 < 0) px0 = 0;
    if (fy0 < 0) fy0 = 0;
    if (px1 > fd->w) px1 = fd->w;
    if (fy1 > fd->h) fy1 = fd->h;
    gl_dirty_add (&fd->dirty, px0, fy0, px1, fy1);
  }

  /* Grow the CPU-side vertex buffer if needed (6 vertices per quad).  */
  if (g_glyph_batch_verts + 6 > g_glyph_batch_cap)
    {
      int cap = g_glyph_batch_cap ? g_glyph_batch_cap * 2 : 4096;
      float *p = realloc (g_glyph_batch,
                          (size_t) cap * GL_GLYPH_VERT_FLOATS * sizeof (float));
      if (!p) { gl_flush_glyph_batch (); return; }
      g_glyph_batch = p;
      g_glyph_batch_cap = cap;
    }

  float r = rgba[0], gg = rgba[1], b = rgba[2], a = rgba[3];
  float quad[6][GL_GLYPH_VERT_FLOATS] = {
    {x0,y0, u0,v0, r,gg,b,a}, {x1,y0, u1,v0, r,gg,b,a}, {x1,y1, u1,v1, r,gg,b,a},
    {x0,y0, u0,v0, r,gg,b,a}, {x1,y1, u1,v1, r,gg,b,a}, {x0,y1, u0,v1, r,gg,b,a},
  };
  memcpy (g_glyph_batch + (size_t) g_glyph_batch_verts * GL_GLYPH_VERT_FLOATS,
          quad, sizeof quad);
  g_glyph_batch_verts += 6;
}

static void
gl_drv_draw_glyph (struct frame *f, struct gfx_glyph *g,
                   float x, float ybase, unsigned long color)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !g || g->width <= 0 || g->height <= 0) return;
  /* Stored metrics are physical pixels; the draw site is logical.  */
  float s = (float) fd->scale;
  float x0 = x * s + g->bearing_x;
  float y0 = ybase * s - g->bearing_y;
  float rgba[4];
  gl_unpack_color (color, rgba);
  gl_batch_append (fd, x0, y0, x0 + g->width, y0 + g->height,
                   (float) g->atlas_x / GL_ATLAS_W,
                   (float) g->atlas_y / GL_ATLAS_H,
                   (float) (g->atlas_x + g->width) / GL_ATLAS_W,
                   (float) (g->atlas_y + g->height) / GL_ATLAS_H,
                   rgba);
}

static void gl_drv_draw_texture (struct frame *f, void *texture,
                                 float x, float y, float w, float h,
                                 float u0, float v0, float u1, float v1,
                                 float alpha);

static bool
gl_drv_color_font_p (struct font *font)
{
  if (!font) return false;
  cairo_scaled_font_t *sf = NULL;
  FT_Face face = gl_lock_face (font, &sf);
  if (!face) return false;
  bool color = FT_HAS_COLOR (face);
  cairo_ft_scaled_font_unlock_face (sf);
  return color;
}

/* ---- Color glyphs (emoji): cairo-rasterized -> RGBA texture ----
   Color fonts (Noto Color Emoji: CBDT/CBLC bitmap strikes) can't go
   through the R8 coverage atlas.  Rasterizing them with raw FreeType would
   yield the native strike (e.g. 136x128 px), NOT the size Emacs laid out;
   cairo's scaled font already carries the pixel_size matrix and scales the
   strike for us (the same path the X/cairo display uses), so we draw the
   glyph through cairo into an ARGB32 surface and upload that as a
   premultiplied RGBA texture, exactly like gl_drv_image_texture.  The draw
   box and bearings come from cairo_scaled_font_glyph_extents, which are in
   the laid-out (logical) pixel size.  Mirrors mtl_color_glyph.  */

struct gl_color_glyph
{
  unsigned long long key;
  GLuint tex;
  int    w, h;                 /* draw box, logical pixels */
  int    bearing_x, bearing_y; /* pen -> box left; baseline -> box top */
  float  advance_x;
  bool   valid;
};
#define GL_CGLYPH_CAP 512
static struct gl_color_glyph g_cglyphs[GL_CGLYPH_CAP];
static int g_cglyph_count;

/* Drop both glyph caches (used on a backing-scale change): the grayscale
   atlas and the color-glyph textures both hold physical-size bitmaps.  */
static void
gl_flush_glyph_caches (void)
{
  gl_atlas_reset ();
  for (int i = 0; i < GL_CGLYPH_CAP; i++)
    if (g_cglyphs[i].valid)
      glDeleteTextures (1, &g_cglyphs[i].tex);
  memset (g_cglyphs, 0, sizeof g_cglyphs);
  g_cglyph_count = 0;
}

static struct gl_color_glyph *
gl_color_glyph_lookup (unsigned long long key)
{
  unsigned h = (unsigned) (key % GL_CGLYPH_CAP);
  for (int i = 0; i < GL_CGLYPH_CAP; i++)
    {
      struct gl_color_glyph *c = &g_cglyphs[(h + i) % GL_CGLYPH_CAP];
      if (!c->valid) return NULL;
      if (c->key == key) return c;
    }
  return NULL;
}

static struct gl_color_glyph *
gl_color_glyph_get (struct font *font, unsigned int glyph_id)
{
  if (!font || glyph_id == 0) return NULL;
  unsigned long long key =
    ((unsigned long long) (uintptr_t) font * 6364136223846793005ULL)
    ^ (unsigned long long) glyph_id;
  struct gl_color_glyph *c = gl_color_glyph_lookup (key);
  if (c) return c;

  struct font_info *fi = (struct font_info *) font;
  cairo_scaled_font_t *sf = fi->cr_scaled_font;
  if (!sf) return NULL;

  /* Laid-out metrics at the font's pixel_size (cairo scales the strike).  */
  cairo_glyph_t cg = { glyph_id, 0, 0 };
  cairo_text_extents_t ext;
  cairo_scaled_font_glyph_extents (sf, &cg, 1, &ext);
  if (ext.width <= 0 || ext.height <= 0) return NULL;

  int bw = (int) ceil (ext.width)  + 2;
  int bh = (int) ceil (ext.height) + 2;
  int bx = (int) floor (ext.x_bearing);   /* pen -> box left (logical) */
  int by = (int) floor (-ext.y_bearing);  /* baseline -> box top (logical) */

  if (getenv ("GL_LOG_CGLYPH"))
    fprintf (stderr, "[cglyph] gid=%u box=%dx%d bear=%d,%d adv=%.1f\n",
             glyph_id, bw, bh, bx, by, (double) ext.x_advance);

  /* HiDPI: the draw box and bearings stay logical (gl_drv_draw_texture
     maps logical -> FBO by * scale), but the texture is rasterized at
     physical resolution so the emoji is crisp.  At scale 1 this is the
     proven 1x path (sf2 == sf, physical dims == logical).  */
  double s = g_atlas_scale;
  int pw = (int) ceil (bw * s);
  int ph = (int) ceil (bh * s);
  cairo_scaled_font_t *sf2 = sf;
  if (s != 1.0)
    {
      cairo_font_face_t *ff = cairo_scaled_font_get_font_face (sf);
      cairo_matrix_t fm, ctm;
      cairo_scaled_font_get_font_matrix (sf, &fm);
      cairo_scaled_font_get_ctm (sf, &ctm);
      cairo_font_options_t *opts = cairo_font_options_create ();
      cairo_scaled_font_get_font_options (sf, opts);
      cairo_matrix_scale (&fm, s, s);
      sf2 = cairo_scaled_font_create (ff, &fm, &ctm, opts);
      cairo_font_options_destroy (opts);
      if (!sf2 || cairo_scaled_font_status (sf2) != CAIRO_STATUS_SUCCESS)
        { if (sf2) cairo_scaled_font_destroy (sf2); return NULL; }
    }

  /* Render the glyph through cairo at the box origin (-x_bearing, -y_bearing
     + 1px pad, in physical pixels), so the bbox lands inside the surface.
     cairo paints the embedded color for CBDT/COLR glyphs.  */
  cairo_surface_t *surf = cairo_image_surface_create (CAIRO_FORMAT_ARGB32,
                                                      pw, ph);
  if (cairo_surface_status (surf) != CAIRO_STATUS_SUCCESS)
    {
      cairo_surface_destroy (surf);
      if (sf2 != sf) cairo_scaled_font_destroy (sf2);
      return NULL;
    }
  cairo_t *cr = cairo_create (surf);
  cairo_set_scaled_font (cr, sf2);
  cairo_set_source_rgb (cr, 0, 0, 0);
  cairo_glyph_t place = { glyph_id, (-bx + 1) * s, (by + 1) * s };
  cairo_show_glyphs (cr, &place, 1);
  cairo_destroy (cr);
  cairo_surface_flush (surf);
  if (sf2 != sf) cairo_scaled_font_destroy (sf2);

  unsigned char *data = cairo_image_surface_get_data (surf);
  int stride = cairo_image_surface_get_stride (surf);
  if (!data) { cairo_surface_destroy (surf); return NULL; }

  GLuint tex;
  glGenTextures (1, &tex);
  glBindTexture (GL_TEXTURE_2D, tex);
  glPixelStorei (GL_UNPACK_ALIGNMENT, 4);
  glPixelStorei (GL_UNPACK_ROW_LENGTH, stride / 4);
  glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, pw, ph, 0, GL_RGBA,
                GL_UNSIGNED_BYTE, data);
  glPixelStorei (GL_UNPACK_ROW_LENGTH, 0);
  /* cairo ARGB32 is little-endian B,G,R,A: swap R and B for straight RGBA.  */
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, GL_BLUE);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, GL_RED);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  cairo_surface_destroy (surf);

  if (g_cglyph_count * 4 >= GL_CGLYPH_CAP * 3)
    {
      for (int i = 0; i < GL_CGLYPH_CAP; i++)
        if (g_cglyphs[i].valid) glDeleteTextures (1, &g_cglyphs[i].tex);
      memset (g_cglyphs, 0, sizeof g_cglyphs);
      g_cglyph_count = 0;
    }
  unsigned hh = (unsigned) (key % GL_CGLYPH_CAP);
  for (int i = 0; i < GL_CGLYPH_CAP; i++)
    {
      struct gl_color_glyph *e = &g_cglyphs[(hh + i) % GL_CGLYPH_CAP];
      if (!e->valid)
        {
          e->valid = true; e->key = key; e->tex = tex;
          /* The 1px pad shifts the bbox down-right by 1; fold it into the
             bearings so the on-screen origin still lands correctly.  */
          e->w = bw; e->h = bh;
          e->bearing_x = bx - 1; e->bearing_y = by + 1;
          e->advance_x = (float) ext.x_advance;
          g_cglyph_count++;
          return e;
        }
    }
  glDeleteTextures (1, &tex);
  return NULL;
}

static float
gl_drv_draw_color_glyph (struct frame *f, struct font *font,
                         unsigned int glyph_id, float x, float ybase)
{
  struct gl_color_glyph *c = gl_color_glyph_get (font, glyph_id);
  if (!c) return 0.0f;
  /* Metrics are logical pixels; gl_drv_draw_texture maps logical -> FBO.  */
  gl_drv_draw_texture (f, (void *) (uintptr_t) c->tex,
                       x + c->bearing_x, ybase - c->bearing_y,
                       (float) c->w, (float) c->h,
                       0.0f, 0.0f, 1.0f, 1.0f, 1.0f);
  return c->advance_x;
}

static void
gl_drv_warm_glyph_cache (struct frame *f)
{
  struct face *face = FACE_FROM_ID_OR_NULL (f, DEFAULT_FACE_ID);
  if (!face || !face->font) return;
  struct font *font = face->font;
  if (!font->driver || !font->driver->encode_char) return;
  for (int c = 32; c < 127; c++)
    {
      unsigned int gid = font->driver->encode_char (font, c);
      if (gid != FONT_INVALID_CODE && gid != 0)
        gl_drv_get_glyph (font, gid);
    }
}

/* Image texture cache: keyed by the `struct image *' pointer, VALIDATED
   by the image's spec hash and display size.  Pointer identity alone is
   not enough: Emacs's image cache frees evicted images and the allocator
   can hand the same address to a different image later -- a stale hit
   would draw the old picture (a long-gone dashboard banner, say) in the
   new image's place.  The spec hash pins the entry to its image.  */
#define GL_IMG_CAP 256
struct gl_img_entry
{
  struct image *img;
  EMACS_UINT hash;
  GLuint tex;
  int w, h;
};
static struct gl_img_entry g_imgs[GL_IMG_CAP];

static struct gl_img_entry *
gl_img_slot (struct image *img)
{
  struct gl_img_entry *free_slot = NULL;
  for (int i = 0; i < GL_IMG_CAP; i++)
    {
      if (g_imgs[i].img == img) return &g_imgs[i];
      if (!free_slot && g_imgs[i].img == NULL) free_slot = &g_imgs[i];
    }
  return free_slot;
}

/* Rasterize IMG through cairo at its display size (honoring the pattern
   matrix that image.c set for :scale / :rotation / flips, exactly like
   x_cr_draw_image), upload it to a GL texture, and cache it.  The cairo
   surface is premultiplied ARGB32; we upload it as RGBA8 with a B<->R
   texture swizzle so the sampler returns straight RGBA.  Returns the GL
   texture name as an opaque handle; W and H receive the texture size.  */
static void *
gl_drv_image_texture (struct frame *f, struct image *img, int *w, int *h)
{
  if (w) *w = 0;
  if (h) *h = 0;
  if (!img) return NULL;

  cairo_pattern_t *pat = (cairo_pattern_t *) img->cr_data;
  if (!pat || cairo_pattern_get_type (pat) != CAIRO_PATTERN_TYPE_SURFACE)
    return NULL;

  int W = img->width  > 0 ? img->width  : 1;
  int H = img->height > 0 ? img->height : 1;

  struct gl_img_entry *e = gl_img_slot (img);
  if (e && e->img == img && e->hash == img->hash
      && e->tex && e->w == W && e->h == H)
    {
      if (w) *w = W;
      if (h) *h = H;
      return (void *) (uintptr_t) e->tex;
    }

  /* Paint the prepared pattern over an opaque-free ARGB32 surface, the
     same primitive x_cr_draw_image uses (set_source + fill), with dest
     and src both at the origin so the full display-size image lands in
     the surface.  No background fill: the policy already painted the cell
     background, and we composite this over it with OVER.  */
  cairo_surface_t *surf =
    cairo_image_surface_create (CAIRO_FORMAT_ARGB32, W, H);
  if (cairo_surface_status (surf) != CAIRO_STATUS_SUCCESS)
    { cairo_surface_destroy (surf); return NULL; }
  cairo_t *cr = cairo_create (surf);
  cairo_rectangle (cr, 0, 0, W, H);
  cairo_set_source (cr, pat);
  cairo_fill (cr);
  cairo_destroy (cr);
  cairo_surface_flush (surf);

  unsigned char *data = cairo_image_surface_get_data (surf);
  int stride = cairo_image_surface_get_stride (surf);
  if (!data) { cairo_surface_destroy (surf); return NULL; }

  GLuint tex = (e && e->tex) ? e->tex : 0;
  if (!tex) glGenTextures (1, &tex);
  glBindTexture (GL_TEXTURE_2D, tex);
  glPixelStorei (GL_UNPACK_ALIGNMENT, 4);
  glPixelStorei (GL_UNPACK_ROW_LENGTH, stride / 4);
  glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA,
                GL_UNSIGNED_BYTE, data);
  glPixelStorei (GL_UNPACK_ROW_LENGTH, 0);
  /* cairo ARGB32 is little-endian B,G,R,A in memory: swap R and B so the
     sampler returns straight RGBA.  */
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, GL_BLUE);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, GL_RED);
  /* Filtering: match the cairo pattern (BEST -> linear, NEAREST).  */
  GLint filt = (cairo_pattern_get_filter (pat) == CAIRO_FILTER_NEAREST)
               ? GL_NEAREST : GL_LINEAR;
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filt);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filt);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  cairo_surface_destroy (surf);

  if (e)
    { e->img = img; e->hash = img->hash; e->tex = tex; e->w = W; e->h = H; }

  (void) f;
  if (w) *w = W;
  if (h) *h = H;
  return (void *) (uintptr_t) tex;
}

static void
gl_drv_draw_texture (struct frame *f, void *texture,
                     float x, float y, float w, float h,
                     float u0, float v0, float u1, float v1, float alpha)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !texture) return;
  gl_flush_glyph_batch ();   /* keep submission order vs queued quads */
  gl_scissor_apply_now (fd); /* non-batched: needs the real scissor */
  gl_mark_dirty (fd, x, y, w, h);
  float s = (float) fd->scale;
  float x0 = x * s, y0 = y * s, x1 = (x + w) * s, y1 = (y + h) * s;
  float v[] = {
    x0,y0, u0,v0,  x1,y0, u1,v0,  x1,y1, u1,v1,
    x0,y0, u0,v0,  x1,y1, u1,v1,  x0,y1, u0,v1,
  };
  glUseProgram (g_prog_image);
  glUniform2f (g_u_image_size, (float) fd->w, (float) fd->h);
  glActiveTexture (GL_TEXTURE0);
  glBindTexture (GL_TEXTURE_2D, (GLuint) (uintptr_t) texture);
  glUniform1i (g_u_image_tex, 0);
  glUniform1f (g_u_image_alpha, alpha);
  glBindBuffer (GL_ARRAY_BUFFER, g_vbo);
  glBufferData (GL_ARRAY_BUFFER, sizeof v, v, GL_STREAM_DRAW);
  glEnableVertexAttribArray (0);
  glVertexAttribPointer (0, 2, GL_FLOAT, GL_FALSE, 16, (void *) 0);
  glEnableVertexAttribArray (1);
  glVertexAttribPointer (1, 2, GL_FLOAT, GL_FALSE, 16, (void *) 8);
  /* The texture is premultiplied; composite with cairo's OVER operator,
     then restore the straight-alpha blend the glyph/rect paths expect.  */
  glBlendFunc (GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
  glDrawArrays (GL_TRIANGLES, 0, 6);
  glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
}

static void
gl_drv_draw_bitmap (struct frame *f, unsigned short *bits, int dh,
                    int bw, int wd, int h, int x, int y,
                    unsigned long color)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  (void) bw;
  if (!fd || !bits || wd <= 0 || h <= 0) return;
  gl_flush_glyph_batch ();   /* binds its own R8 texture; drain quads first */
  gl_scissor_apply_now (fd); /* non-batched: needs the real scissor */
  if (wd > 16) wd = 16;   /* a fringe bitmap row is an unsigned short */
  gl_mark_dirty (fd, x, y, wd, h);

  /* The bitmap as an R8 coverage texture, cached: a fringe indicator is
     redrawn every time its row updates, with the same handful of
     patterns over and over, so re-uploading per call is pure waste.
     Keyed by an FNV-1a hash of the visible rows plus the box size (a
     64-bit hash over a couple dozen distinct patterns; collisions are
     not a practical concern).  The coverage is color-independent (the
     color rides on the vertices), so one texture serves every face.

     Bit order: the X/cairo backend writes the row straight into a
     CAIRO_FORMAT_A1 surface, where on a little-endian host pixel x is
     bit x (LSB-first) -- the mirror of the macOS/NS driver's MSB-first
     order.  Drawn with the glyph program (1-bit coverage, so the gamma
     is a no-op) and NEAREST sampling for hard edges.  */
  unsigned long long hash = 1469598103934665603ULL;
  for (int r = 0; r < h; r++)
    {
      hash ^= (unsigned long long) bits[dh + r];
      hash *= 1099511628211ULL;
    }
  hash ^= ((unsigned long long) wd << 32) ^ (unsigned long long) h;

#define GL_BITMAP_CAP 64
  static struct { unsigned long long hash; GLuint tex; } cache[GL_BITMAP_CAP];
  static int cache_next;
  GLuint tex = 0;
  for (int i = 0; i < GL_BITMAP_CAP; i++)
    if (cache[i].tex && cache[i].hash == hash)
      { tex = cache[i].tex; break; }
  if (!tex)
    {
      unsigned char *buf = calloc ((size_t) wd * h, 1);
      if (!buf) return;
      for (int r = 0; r < h; r++)
        {
          unsigned short row = bits[dh + r];
          for (int c = 0; c < wd; c++)
            if ((row >> c) & 1)
              buf[r * wd + c] = 0xFF;
        }
      glGenTextures (1, &tex);
      glBindTexture (GL_TEXTURE_2D, tex);
      glPixelStorei (GL_UNPACK_ALIGNMENT, 1);
      glTexImage2D (GL_TEXTURE_2D, 0, GL_R8, wd, h, 0, GL_RED,
                    GL_UNSIGNED_BYTE, buf);
      glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
      glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      free (buf);
      if (cache[cache_next].tex)
        glDeleteTextures (1, &cache[cache_next].tex);
      cache[cache_next].hash = hash;
      cache[cache_next].tex = tex;
      cache_next = (cache_next + 1) % GL_BITMAP_CAP;
    }

  float s = (float) fd->scale;
  float x0 = x * s, y0 = y * s, x1 = (x + wd) * s, y1 = (y + h) * s;
  float rgba[4];
  gl_unpack_color (color, rgba);
  float rr = rgba[0], gg = rgba[1], bb = rgba[2], a = rgba[3];
  float v[] = {
    x0,y0, 0,0, rr,gg,bb,a,  x1,y0, 1,0, rr,gg,bb,a,  x1,y1, 1,1, rr,gg,bb,a,
    x0,y0, 0,0, rr,gg,bb,a,  x1,y1, 1,1, rr,gg,bb,a,  x0,y1, 0,1, rr,gg,bb,a,
  };
  glUseProgram (g_prog_glyph);
  glUniform2f (g_u_glyph_size, (float) fd->w, (float) fd->h);
  glActiveTexture (GL_TEXTURE0);
  glBindTexture (GL_TEXTURE_2D, tex);
  glUniform1i (g_u_glyph_atlas, 0);
  glBindBuffer (GL_ARRAY_BUFFER, g_vbo);
  glBufferData (GL_ARRAY_BUFFER, sizeof v, v, GL_STREAM_DRAW);
  glEnableVertexAttribArray (0);
  glVertexAttribPointer (0, 2, GL_FLOAT, GL_FALSE, 32, (void *) 0);
  glEnableVertexAttribArray (1);
  glVertexAttribPointer (1, 2, GL_FLOAT, GL_FALSE, 32, (void *) 8);
  glEnableVertexAttribArray (2);
  glVertexAttribPointer (2, 4, GL_FLOAT, GL_FALSE, 32, (void *) 16);
  glDrawArrays (GL_TRIANGLES, 0, 6);
}

/* Relief shading.  Port of x_alloc_lighter_color (xterm.c): scale the
   base RGB by FACTOR, and for colors darker than the boost limit add an
   extra additive term so dark backgrounds still get a visible relief.
   Working in 16-bit per channel like the X path, then back to 8-bit.
   This matches vanilla X far better than a flat lighten/darken blend,
   which is what the gfxterm fallback would otherwise use.  */
#define GL_RELIEF_DARK_BOOST_LIMIT 48000

static unsigned long
gl_relief_shade (unsigned long base, double factor, int delta)
{
  long r = ((base >> 16) & 0xff) * 257;
  long g = ((base >> 8) & 0xff) * 257;
  long b = (base & 0xff) * 257;
  long nr = min (0xffff, (long) (factor * r));
  long ng = min (0xffff, (long) (factor * g));
  long nb = min (0xffff, (long) (factor * b));
  long bright = (2 * r + 3 * g + b) / 6;
  if (bright < GL_RELIEF_DARK_BOOST_LIMIT)
    {
      double dimness = 1 - (double) bright / GL_RELIEF_DARK_BOOST_LIMIT;
      int min_delta = (int) (delta * dimness * factor / 2);
      if (factor < 1)
        {
          nr = max (0, nr - min_delta);
          ng = max (0, ng - min_delta);
          nb = max (0, nb - min_delta);
        }
      else
        {
          nr = min (0xffff, nr + min_delta);
          ng = min (0xffff, ng + min_delta);
          nb = min (0xffff, nb + min_delta);
        }
    }
  /* x_alloc_lighter_color's "same color as before" path: when scaling
     leaves the channel unchanged, fall back to an additive delta.  */
  if (nr == r && ng == g && nb == b)
    {
      nr = min (0xffff, r + delta);
      ng = min (0xffff, g + delta);
      nb = min (0xffff, b + delta);
    }
  return (((unsigned long) (nr >> 8)) << 16)
       | (((unsigned long) (ng >> 8)) << 8)
       | (unsigned long) (nb >> 8);
}

/* Appearance-aware relief colors, mirroring x_setup_relief_colors: the
   light relief uses factor 1.2 / delta 0x8000, the dark one 0.6 / 0x4000,
   over the face background (or the box color / image background).  */
static void
gl_drv_relief_colors (struct glyph_string *s, unsigned long *light,
                      unsigned long *dark)
{
  unsigned long base;
  if (s->face->use_box_color_for_shadows_p)
    base = s->face->box_color;
  else if (s->first_glyph->type == IMAGE_GLYPH && s->img && s->img->pixmap
           && !IMAGE_BACKGROUND_TRANSPARENT (s->img, s->f, 0))
    base = IMAGE_BACKGROUND (s->img, s->f, 0);
  else
    base = s->face->background;
  *light = gl_relief_shade (base, 1.2, 0x8000);
  *dark  = gl_relief_shade (base, 0.6, 0x4000);
}

static unsigned long
gl_drv_frame_foreground (struct frame *f)
{
  return FRAME_FOREGROUND_PIXEL (f);
}

static unsigned long
gl_drv_frame_background (struct frame *f)
{
  return FRAME_BACKGROUND_PIXEL (f);
}

static unsigned long
gl_drv_cursor_color (struct frame *f)
{
  /* xterm.h names this cursor_pixel; pgtkterm.h names it cursor_color.
     FRAME_CURSOR_COLOR is only defined in pgtkterm.h, so branch explicitly.  */
#ifdef HAVE_PGTK
  return FRAME_CURSOR_COLOR (f);
#else
  return FRAME_X_OUTPUT (f)->cursor_pixel;
#endif
}

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
  .relief_colors        = gl_drv_relief_colors,
  .frame_foreground     = gl_drv_frame_foreground,
  .frame_background     = gl_drv_frame_background,
  .cursor_color         = gl_drv_cursor_color,
  .note_cursor          = gl_drv_note_cursor,
};

/* ------------------------------------------------------------------ */
/* Cursor animation overlay (the MtlAnimator port).  Mirrors mtlterm.m:
   spring physics, comet trail and particle bursts, advanced by a Lisp
   timer (gpu-anim-tick) because EGL has no display link, and composited
   over the FBO in the present (gl_anim_overlay).  */

/* Critically-damped spring step (analytic, dt-stable).  Mirrors Metal's
   spring_update.  */
static void
gl_spring_step (float *pos, float *vel, float target, float dt)
{
  float omega = GL_SPRING_OMEGA;
  float c1 = *pos - target;
  float c2 = *vel + omega * c1;
  float e = expf (-omega * dt);
  *pos = target + (c1 + c2 * dt) * e;
  *vel = (c2 - omega * (c1 + c2 * dt)) * e;
}

/* Spawn a radial burst at (px,py) for the particle modes.  */
static void
gl_anim_spawn (struct gl_anim *a, float px, float py)
{
  int count = (g_gl_cursor_mode == GL_CURSOR_PIXIEDUST) ? 12 : 3;
  for (int i = 0; i < count && a->n_particles < GL_MAX_PARTICLES; i++)
    {
      float angle = (g_gl_cursor_mode == GL_CURSOR_PIXIEDUST)
                    ? (float) i * 2.399f                    /* golden angle */
                    : (float) i * (2.0f * (float) M_PI / (float) count);
      float speed = (g_gl_cursor_mode == GL_CURSOR_SONICBOOM) ? 60.0f : 40.0f;
      struct gl_particle *p = &a->particles[a->n_particles++];
      p->x = px; p->y = py;
      p->vx = cosf (angle) * speed;
      p->vy = sinf (angle) * speed;
      p->age = 0.0f;
      p->size = (g_gl_cursor_mode == GL_CURSOR_SONICBOOM) ? 6.0f : 3.0f;
      p->color = a->color ? a->color : 0x88C0D0;
    }
}

/* note_cursor vtable op: the policy hands us the cursor rect + color every
   time it would draw the cursor.  We record the target, spawn effects on a
   jump, and (for body-animated modes) tell the policy to skip the static
   cursor.  w/h <= 0 is the blink-off phase.  */
static bool
gl_drv_note_cursor (struct frame *f, int x, int y, int w, int h,
                    unsigned long color)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !g_gl_animations_enabled || g_gl_cursor_mode == GL_CURSOR_BLOCK)
    return false;
  struct gl_anim *a = &fd->anim;

  if (w <= 0 || h <= 0)
    {
      if (!a->hidden)
        {
          a->hidden = true;
          if (!fd->in_cycle) { gl_present_to_window (fd); fd->needs_present = false; }
        }
      return true;
    }

  float fx = (float) x, fy = (float) y;
  float dx = fx - a->tx, dy = fy - a->ty;

  if (!a->have_target)                  /* first placement: snap */
    { a->sx = fx; a->sy = fy; a->svx = a->svy = 0; a->have_target = true; }

  /* Burst on a significant jump (not while typing).  */
  if (!g_gl_cursor_suppress
      && (fabsf (dx) > (float) w * 1.5f || fabsf (dy) > (float) h * 1.5f)
      && (g_gl_cursor_mode == GL_CURSOR_SONICBOOM
          || g_gl_cursor_mode == GL_CURSOR_RIPPLE
          || g_gl_cursor_mode == GL_CURSOR_PIXIEDUST))
    {
      gl_anim_spawn (a, a->tx + w / 2.0f, a->ty + h / 2.0f);
      if (getenv ("GL_LOG_ANIM"))
        fprintf (stderr, "[anim] spawn at %.0f,%.0f n=%d mode=%d\n",
                 (double) a->tx, (double) a->ty, a->n_particles,
                 g_gl_cursor_mode);
    }

  /* Push a trail sample (torpedo).  */
  if (!g_gl_cursor_suppress && g_gl_cursor_mode == GL_CURSOR_TORPEDO
      && (fabsf (dx) > 1 || fabsf (dy) > 1))
    {
      int slot = (a->trail_head + a->trail_count) % GL_TRAIL_LEN;
      a->trail_x[slot] = a->tx; a->trail_y[slot] = a->ty;
      a->trail_age[slot] = 0.0f;
      if (a->trail_count < g_gl_trail_len) a->trail_count++;
      else a->trail_head = (a->trail_head + 1) % GL_TRAIL_LEN;
    }

  a->hidden = false;
  a->color = color;
  a->tx = fx; a->ty = fy; a->tw = (float) w; a->th = (float) h;

  /* Cursor-only motion takes redisplay's fast path (no render cycle), so
     present now or the overlay would lag at its old position.  */
  if (!fd->in_cycle) { gl_present_to_window (fd); fd->needs_present = false; }

  /* Only the body-animated modes draw the cursor in the overlay; the burst
     modes keep the policy's static (inverted-glyph) cursor underneath.  */
  return (g_gl_cursor_mode == GL_CURSOR_SPRING
          || g_gl_cursor_mode == GL_CURSOR_TORPEDO
          || g_gl_cursor_mode == GL_CURSOR_HOLLOW
          || g_gl_cursor_mode == GL_CURSOR_BEAM);
}

/* Advance every cursor animation by DT; true when something moved and
   the overlay needs a new present.  Pure physics: presenting is the
   caller's job (gl_pump_tick / gl_anim_tick).  */
static bool
gl_anim_step (struct frame *f, struct gl_frame_data *fd, double dt)
{
  struct gl_anim *a = &fd->anim;
  bool moved = false;

  /* Mirror the blink phase (the engine toggles cursor_off_p without
     reaching the rif).  */
  if (WINDOWP (f->selected_window))
    {
      bool hidden = XWINDOW (f->selected_window)->cursor_off_p;
      if (hidden != a->hidden) { a->hidden = hidden; moved = true; }
    }

  if (g_gl_cursor_mode == GL_CURSOR_SPRING && a->have_target)
    {
      gl_spring_step (&a->sx, &a->svx, a->tx, (float) dt);
      gl_spring_step (&a->sy, &a->svy, a->ty, (float) dt);
      if (fabsf (a->sx - a->tx) > 0.5f || fabsf (a->sy - a->ty) > 0.5f)
        moved = true;
    }

  if (g_gl_cursor_mode == GL_CURSOR_TORPEDO && a->trail_count > 0)
    {
      for (int i = 0; i < a->trail_count; i++)
        a->trail_age[(a->trail_head + i) % GL_TRAIL_LEN] += (float) dt;
      while (a->trail_count > 0
             && a->trail_age[a->trail_head] >= GL_TRAIL_LIFETIME)
        { a->trail_head = (a->trail_head + 1) % GL_TRAIL_LEN; a->trail_count--; }
      if (a->trail_count > 0) moved = true;
    }

  if (a->n_particles > 0)
    {
      moved = true;
      int alive = 0;
      for (int i = 0; i < a->n_particles; i++)
        {
          struct gl_particle *p = &a->particles[i];
          p->age += (float) dt / 0.6f;
          if (p->age >= 1.0f) continue;
          p->x += p->vx * (float) dt; p->y += p->vy * (float) dt;
          p->vx *= 0.92f; p->vy *= 0.92f;
          a->particles[alive++] = *p;
        }
      a->n_particles = alive;
    }

  return moved;
}

/* Compatibility entry of the old per-subsystem pump (gpu-anim-tick).
   New code goes through gl_pump_tick, which steps everything and
   presents once.  */
bool
gl_anim_tick (struct frame *f, double dt)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd) return g_gl_animations_enabled;
  /* Present only when something moved AND redisplay has not just swapped:
     piling animation presents on top of redisplay's own floods the
     swapchain (see last_swap in gl_frame_data).  The skipped motion still
     reaches the screen with the next tick or present.  */
  if (gl_anim_step (f, fd, dt)
      && !fd->in_cycle && gl_swap_ok (fd))
    { gl_present_to_window (fd); fd->needs_present = false; }
  return g_gl_animations_enabled;
}

/* Single animation pump (gpu-pump-tick).  Advance the cursor effects,
   the buffer cross-fade and the inline video together, then present AT
   MOST ONCE.  gpu.el drives every continuous animation through this one
   entry point: when each subsystem presented from its own timer the
   surface saw bursts well above the refresh rate, which is exactly the
   pressure under which radeonsi was caught presenting a stale buffer
   (see last_swap).  A skipped subsystem loses nothing -- the fade and
   the video are composited by EVERY present, whoever issues it.
   Returns the GL_PUMP_* mask of subsystems that still need pumping so
   the Lisp timer can re-pace itself or stop.  */
int
gl_pump_tick (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd)
    return g_gl_animations_enabled ? GL_PUMP_ANIM : 0;

  double now = gl_now ();
  double dt = fd->last_pump > 0 ? now - fd->last_pump : 1.0 / 30;
  if (dt > 0.1) dt = 0.1;     /* a stalled timer must not teleport physics */
  fd->last_pump = now;

  bool need = g_gl_animations_enabled && gl_anim_step (f, fd, dt);
  bool fade = fd->trans_dur > 0;
  need |= fade;
#ifdef HAVE_GSTREAMER
  if (fd->video)
    need |= gl_video_pump (fd->video);
#endif

  if (getenv ("GL_LOG_PRESENT"))
    fprintf (stderr, "[glpump] t=%.4f need=%d fade=%d in_cycle=%d gap=%.3f\n",
             now, need, fade, fd->in_cycle, now - fd->last_swap);

  if (need && !fd->in_cycle && gl_swap_ok (fd))
    { gl_present_to_window (fd); fd->needs_present = false; }

  /* For overlay-based cursor modes (spring, torpedo, bursts) the pump must
     keep ticking to advance physics even on quiet frames, so return ANIM
     unconditionally when such a mode is active.
     For BLOCK cursor (no overlay) return ANIM only while something actually
     moved this tick; the Lisp timer stops when the screen is static and
     restarts at the next animation event, eliminating spurious presents on
     idle frames.  */
  bool anim_live = g_gl_animations_enabled
    && (g_gl_cursor_mode != GL_CURSOR_BLOCK
        || need
        || gl_anim_overlay_active (fd));
  return (anim_live ? GL_PUMP_ANIM : 0)
    | (fade ? GL_PUMP_FADE : 0)
    | (fd->video ? GL_PUMP_VIDEO : 0);
}

/* Append a solid colored quad (pixel coords, top-left origin) to a CPU
   buffer of rect-shader vertices: {x,y, r,g,b,a}.  */
static void
gl_anim_quad (float *v, int *n, float x0, float y0, float x1, float y1,
              float r, float g, float b, float al)
{
  float q[6][6] = {
    {x0,y0,r,g,b,al}, {x1,y0,r,g,b,al}, {x0,y1,r,g,b,al},
    {x1,y0,r,g,b,al}, {x1,y1,r,g,b,al}, {x0,y1,r,g,b,al},
  };
  memcpy (v + (*n) * 6, q, sizeof q);
  *n += 6;
}

/* True when gl_anim_overlay would emit at least one quad right now.  The
   present uses this to decide whether the frame needs a full blit (overlay
   pixels live only in the back buffer, not the FBO); an idle burst-mode
   cursor emits nothing, so ordinary typing still presents partially.
   Mirrors the emission conditions in gl_anim_overlay below.  */
static bool
gl_anim_overlay_active (struct gl_frame_data *fd)
{
  if (!g_gl_animations_enabled)
    return false;
  struct gl_anim *a = &fd->anim;
  if (a->n_particles > 0)
    return true;
  if (a->hidden)
    return false;
  if (g_gl_cursor_mode == GL_CURSOR_TORPEDO && a->trail_count > 0)
    return true;
  return (g_gl_cursor_mode == GL_CURSOR_SPRING
          || g_gl_cursor_mode == GL_CURSOR_TORPEDO
          || g_gl_cursor_mode == GL_CURSOR_HOLLOW
          || g_gl_cursor_mode == GL_CURSOR_BEAM);
}

/* Composite the cursor effects over the on-screen framebuffer.  Called from
   gl_present_to_window with the window surface current.  Builds one vertex
   buffer of colored quads (trail + body + particles) and draws it with the
   rect shader, alpha-blended.  */
static void
gl_anim_overlay (struct gl_frame_data *fd, int sw, int sh)
{
  struct gl_anim *a = &fd->anim;
  double s = fd->scale;
  float crgba[4];
  gl_unpack_color (a->color ? a->color : 0x88C0D0, crgba);
  float cr = crgba[0], cg = crgba[1], cb = crgba[2];

  if (!gl_anim_overlay_active (fd))
    return;

  /* Worst case: trail (GL_TRAIL_LEN) + body + particles, 6 verts each.  */
  static float verts[(GL_TRAIL_LEN + 1 + GL_MAX_PARTICLES) * 6 * 6];
  int n = 0;

  float cw = a->tw * (float) s, ch = a->th * (float) s;

  if (g_gl_cursor_mode == GL_CURSOR_TORPEDO && a->trail_count > 0 && !a->hidden)
    {
      int tlen = a->trail_count < g_gl_trail_len ? a->trail_count : g_gl_trail_len;
      for (int i = 0; i < tlen; i++)
        {
          int slot = (a->trail_head + i) % GL_TRAIL_LEN;
          float pos = (float) (i + 1) / (float) tlen;
          float frac = a->trail_age[slot] / GL_TRAIL_LIFETIME;
          if (frac > 1.0f) frac = 1.0f;
          float life = 1.0f - frac;
          float alpha = pos * life * life * 0.5f;
          float scale = 0.35f + 0.55f * pos;
          float tx = a->trail_x[slot] * (float) s, ty = a->trail_y[slot] * (float) s;
          float iw = cw * scale, ih = ch * scale;
          float ox = tx + (cw - iw) * 0.5f, oy = ty + (ch - ih) * 0.5f;
          gl_anim_quad (verts, &n, ox, oy, ox + iw, oy + ih, cr, cg, cb, alpha);
        }
    }

  if (!a->hidden
      && (g_gl_cursor_mode == GL_CURSOR_SPRING || g_gl_cursor_mode == GL_CURSOR_TORPEDO
          || g_gl_cursor_mode == GL_CURSOR_HOLLOW || g_gl_cursor_mode == GL_CURSOR_BEAM))
    {
      float cx = (g_gl_cursor_mode == GL_CURSOR_SPRING ? a->sx : a->tx) * (float) s;
      float cy = (g_gl_cursor_mode == GL_CURSOR_SPRING ? a->sy : a->ty) * (float) s;
      if (g_gl_cursor_mode == GL_CURSOR_BEAM)
        cw = 2.0f * (float) s;                 /* thin bar */
      if (g_gl_cursor_mode == GL_CURSOR_HOLLOW)
        {
          float t = (float) s;                 /* 1px outline */
          gl_anim_quad (verts, &n, cx, cy, cx + cw, cy + t, cr, cg, cb, 1);
          gl_anim_quad (verts, &n, cx, cy + ch - t, cx + cw, cy + ch, cr, cg, cb, 1);
          gl_anim_quad (verts, &n, cx, cy, cx + t, cy + ch, cr, cg, cb, 1);
          gl_anim_quad (verts, &n, cx + cw - t, cy, cx + cw, cy + ch, cr, cg, cb, 1);
        }
      else
        gl_anim_quad (verts, &n, cx, cy, cx + cw, cy + ch, cr, cg, cb, 1);
    }

  for (int i = 0; i < a->n_particles; i++)
    {
      struct gl_particle *p = &a->particles[i];
      float al = (1.0f - p->age) * (1.0f - p->age);
      float sz = p->size * (1.0f - p->age * 0.5f) * (float) s;
      float rgba[4]; gl_unpack_color (p->color, rgba);
      float px = p->x * (float) s, py = p->y * (float) s;
      gl_anim_quad (verts, &n, px - sz / 2, py - sz / 2, px + sz / 2, py + sz / 2,
                    rgba[0], rgba[1], rgba[2], al);
    }

  if (getenv ("GL_LOG_ANIM") && n > 0)
    fprintf (stderr, "[anim] overlay quads=%d parts=%d trail=%d hidden=%d\n",
             n / 6, a->n_particles, a->trail_count, (int) a->hidden);
  if (n == 0) return;

  glViewport (0, 0, sw, sh);
  glUseProgram (g_prog_rect);
  glUniform2f (g_u_rect_size, (float) sw, (float) sh);
  glBindBuffer (GL_ARRAY_BUFFER, g_vbo);
  glBufferData (GL_ARRAY_BUFFER, (GLsizeiptr) n * 6 * sizeof (float),
                verts, GL_STREAM_DRAW);
  glEnableVertexAttribArray (0);
  glVertexAttribPointer (0, 2, GL_FLOAT, GL_FALSE, 24, (void *) 0);
  glEnableVertexAttribArray (2);
  glVertexAttribPointer (2, 4, GL_FLOAT, GL_FALSE, 24, (void *) 8);
  glEnable (GL_BLEND);
  glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glDrawArrays (GL_TRIANGLES, 0, n);
}

/* Public config setters used by glfns.c.  */
void gl_cursor_set_mode (int mode)         { g_gl_cursor_mode = mode; }
void gl_cursor_set_trail_len (int len)
{ g_gl_trail_len = len < 1 ? 1 : (len > GL_TRAIL_LEN ? GL_TRAIL_LEN : len); }
void gl_cursor_set_suppress (bool s)       { g_gl_cursor_suppress = s; }
int  gl_cursor_get_mode (void)             { return g_gl_cursor_mode; }
bool gl_animations_get_enabled (void)      { return g_gl_animations_enabled; }
void
gl_animations_set_enabled (bool on)
{
  g_gl_animations_enabled = on;
  if (!on)                                /* clear in-flight effects */
    for (int i = 0; i < GL_MAX_FRAMES; i++)
      if (g_frames[i])
        {
          g_frames[i]->anim.n_particles = 0;
          g_frames[i]->anim.trail_count = 0;
        }
}

/* ------------------------------------------------------------------ */
/* Terminal/rif hookup.  Like mtl_patch_terminal_rif: copy the X rif and
   override ONLY the pixel-drawing functions with the neutral policy in
   gfxterm.c, capturing the original X implementations as the fallback for
   frames the GPU backend is not enabled on.  Replacing the whole rif would
   break frame/face realization (produce_glyphs, frame_parm_handlers...).  */

static struct redisplay_interface *gl_x_rif_copy = NULL;

/* update_end hook for GPU frames.  Runs the neutral policy (gfx_update_end,
   which closes the cycle and presents), then clears mouse_face_defer the way
   x_update_end does.  dispnew.c sets that flag at the start of every window
   update so note_mouse_highlight defers mid-update; every window-system
   backend's update_end clears it again.  gfx_update_end only forwards to the
   captured fallback when the GPU is OFF, so on a GPU frame the flag was never
   cleared: after the first redisplay (the blink-cursor timer, once focused)
   it stayed set and note_mouse_highlight returned early forever, so hovering
   a link stopped highlighting after the first one.  The macro needs the X
   display headers, so this lives here, not in the neutral gfxterm.c.  */
static void
gl_update_end (struct frame *f)
{
  gfx_update_end (f);
  if (gl_get_frame_data (f))
    MOUSE_HL_INFO (f)->mouse_face_defer = false;
}

/* frame_up_to_date hook for GPU frames.  Runs the neutral policy
   (gfx_frame_up_to_date, which presents the finished frame), then re-asserts
   the mouse-face highlight at the last pointer position the way
   XTframe_up_to_date does with FRAME_MOUSE_UPDATE.  A redisplay -- notably the
   blink-cursor timer once the frame has focus -- hides the mouse face;
   without this it is never redrawn, so hovering a link stops highlighting
   after the first time.  The macro lives here (not the neutral gfxterm.c)
   because it needs the X display headers.  note_mouse_highlight only repaints
   when the highlighted region actually changed, so this is cheap; its draws
   land outside the update cycle (deferred present), so flush them.  */
static void
gl_frame_up_to_date (struct frame *f)
{
  gfx_frame_up_to_date (f);
  if (gl_get_frame_data (f))
    {
      FRAME_MOUSE_UPDATE (f);
      struct gl_frame_data *fd = gl_get_frame_data (f);
      if (fd && fd->needs_present && gl_swap_ok (fd))
        {
          gl_present_to_window (fd);
          fd->needs_present = false;
        }
    }
}

void
gl_patch_terminal_rif (struct frame *f)
{
  struct terminal *term = FRAME_TERMINAL (f);
  if (!term || !term->rif) return;

  if (!gl_x_rif_copy)
    {
      gfx_fallback.rif = term->rif;
      gl_x_rif_copy = xmalloc (sizeof (struct redisplay_interface));
      *gl_x_rif_copy = *term->rif;   /* keep all X functions as baseline */

      gl_x_rif_copy->scroll_run_hook                = gfx_scroll_run;
      gl_x_rif_copy->after_update_window_line_hook   = gfx_after_update_window_line;
      gl_x_rif_copy->flush_display                  = gfx_flush_display;
      gl_x_rif_copy->draw_fringe_bitmap             = gfx_draw_fringe_bitmap;
      gl_x_rif_copy->define_fringe_bitmap           = gfx_define_fringe_bitmap;
      gl_x_rif_copy->destroy_fringe_bitmap          = gfx_destroy_fringe_bitmap;
      gl_x_rif_copy->compute_glyph_string_overhangs = gfx_compute_glyph_string_overhangs;
      gl_x_rif_copy->draw_glyph_string              = gfx_draw_glyph_string;
      gl_x_rif_copy->clear_frame_area               = gfx_clear_frame_area;
      gl_x_rif_copy->clear_under_internal_border    = gfx_clear_under_internal_border;
      gl_x_rif_copy->draw_window_cursor             = gfx_draw_window_cursor;
      gl_x_rif_copy->draw_vertical_window_border    = gfx_draw_vertical_window_border;
      gl_x_rif_copy->draw_window_divider            = gfx_draw_window_divider;
      gl_x_rif_copy->shift_glyphs_for_insert        = gfx_shift_glyphs_for_insert;
    }

  term->rif = gl_x_rif_copy;

  if (term->update_begin_hook != gfx_update_begin)
    {
      gfx_fallback.update_begin     = term->update_begin_hook;
      gfx_fallback.update_end       = term->update_end_hook;
      gfx_fallback.clear_frame      = term->clear_frame_hook;
      gfx_fallback.frame_up_to_date = term->frame_up_to_date_hook;
    }
  term->update_begin_hook     = gfx_update_begin;
  term->update_end_hook       = gl_update_end;
  term->clear_frame_hook      = gfx_clear_frame;
  term->frame_up_to_date_hook = gl_frame_up_to_date;
}

/* ------------------------------------------------------------------ */
/* Public entry points (called from glfns.c / the X terminal hookup).  */

/* Bring up the EGL context if needed; return true when the GL backend is
   usable (used by gpu-backend-p without touching any frame).  */
bool
gl_backend_available (void)
{
  return gl_global_init ();
}

const char *
gl_display_type_name (void)
{
  switch (g_dpy_type)
    {
    case GL_DPY_SURFACELESS: return "surfaceless";
    case GL_DPY_X11:         return "x11";
    case GL_DPY_WAYLAND:     return "wayland";
    default:                 return "unknown";
    }
}

/* Enable the GL backend on frame F: bring up the context, allocate the
   per-frame data, and publish the driver.  Returns false on failure.  */
bool
gl_enable_for_frame (struct frame *f)
{
  if (!gl_global_init ()) return false;
  if (gl_get_frame_data (f)) return true;

  int slot = -1;
  for (int i = 0; i < GL_MAX_FRAMES; i++)
    if (!g_frames[i]) { slot = i; break; }
  if (slot < 0) return false;

  struct gl_frame_data *fd = calloc (1, sizeof *fd);
  if (!fd) return false;
  fd->f = f;
  fd->scale = g_atlas_scale;
  g_frames[slot] = fd;

  gfx_drv = &gl_gfx_driver;
  return true;
}

/* Read the static texture back as RGBA8, top-left origin (the
   gpu-capture-frame analogue).  Caller frees *out.  */
bool
gl_capture_frame (struct frame *f, int *w, int *h, unsigned char **out)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->tex) return false;
  if (g_glyph_batch_fd == fd)
    gl_flush_glyph_batch ();    /* the FBO must hold every queued quad */
  int W = fd->w, H = fd->h;
  unsigned char *buf = malloc ((size_t) W * H * 4);
  if (!buf) return false;
  glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
  glDisable (GL_SCISSOR_TEST);
  glReadPixels (0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, buf);
  /* Flip to top-left origin.  */
  unsigned char *flip = malloc ((size_t) W * H * 4);
  if (!flip) { free (buf); return false; }
  for (int row = 0; row < H; row++)
    memcpy (flip + (size_t) row * W * 4,
            buf + (size_t) (H - 1 - row) * W * 4, (size_t) W * 4);
  free (buf);
  *w = W; *h = H; *out = flip;
  return true;
}

/* Snapshot the current FBO (the still-displayed previous frame) into the
   transition texture and arm the cross-fade.  Called from Lisp on
   pre-redisplay-functions, before redisplay paints the new buffer, so the
   FBO still holds the old content.  Mirrors mtl_transition_start.  */
bool
gl_transition_start (struct frame *f, double duration)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->fbo || fd->in_cycle || duration <= 0) return false;

  if (!fd->trans_tex || fd->trans_w != fd->w || fd->trans_h != fd->h)
    {
      if (!fd->trans_tex) glGenTextures (1, &fd->trans_tex);
      glBindTexture (GL_TEXTURE_2D, fd->trans_tex);
      glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, fd->w, fd->h, 0, GL_RGBA,
                    GL_UNSIGNED_BYTE, NULL);
      glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      fd->trans_w = fd->w;
      fd->trans_h = fd->h;
    }
  glBindFramebuffer (GL_FRAMEBUFFER, fd->fbo);
  glBindTexture (GL_TEXTURE_2D, fd->trans_tex);
  glCopyTexSubImage2D (GL_TEXTURE_2D, 0, 0, 0, 0, 0, fd->w, fd->h);

  fd->trans_start = gl_now ();
  fd->trans_dur = duration;
  if (getenv ("GL_LOG_PRESENT"))
    fprintf (stderr, "[gltrans] arm t=%.4f dur=%.0fms fbo=%dx%d\n",
             fd->trans_start, duration * 1000, fd->w, fd->h);
  return true;
}

/* Re-present the on-screen window so the cross-fade advances while the
   event loop is idle (Emacs does not drive a timer for us).  Driven by a
   Lisp 30fps timer; returns true while the fade is still running.  */
bool
gl_transition_tick (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || fd->trans_dur <= 0) return false;
  /* The fade is drawn on EVERY present while it runs, so a tick that
     lands right after a redisplay present has nothing to add; skipping
     it keeps the present rate at the refresh rate instead of flooding
     the swapchain (see last_swap in gl_frame_data).  */
  if (gl_swap_ok (fd))
    gl_present_to_window (fd);
  return fd->trans_dur > 0;
}

/* Query whether a buffer-switch cross-fade is running on F, without
   presenting or otherwise advancing it.  Test harnesses use this to
   wait for a quiescent frame before capturing it.  Time-based: once the
   fade duration has elapsed the next present shows the final state, so
   report inactive even if that present has not landed yet (it may be
   gated on the Wayland frame callback, which needs the event loop).  */
bool
gl_transition_active_p (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  return fd && fd->trans_dur > 0
    && (gl_now () - fd->trans_start) < fd->trans_dur;
}

/* Whether the GPU backend is rendering frame F.  Lets toolkit glue
   (gtkutil.c scroll bars on PGTK) adapt to the EGL present path without
   reaching into the driver's internals.  */
bool
gl_frame_active_p (struct frame *f)
{
  return gl_get_frame_data (f) != NULL;
}

void
gl_free_frame_data (struct frame *f)
{
  for (int i = 0; i < GL_MAX_FRAMES; i++)
    if (g_frames[i] && g_frames[i]->f == f)
      {
        struct gl_frame_data *fd = g_frames[i];
#ifdef HAVE_PGTK
        if (fd->after_paint_id && fd->frame_clock)
          {
            g_signal_handler_disconnect (fd->frame_clock,
                                         fd->after_paint_id);
            fd->after_paint_id = 0;
            fd->frame_clock = NULL;
          }
#endif
        if (g_fd_mru == fd)
          g_fd_mru = NULL;
        if (g_glyph_batch_fd == fd)
          { g_glyph_batch_fd = NULL; g_glyph_batch_verts = 0; }
        if (fd->surf != EGL_NO_SURFACE)
          {
            if (g_bound_known && g_bound_surf == fd->surf)
              { eglMakeCurrent (g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g_ctx);
                g_bound_surf = EGL_NO_SURFACE; }
            eglDestroySurface (g_dpy, fd->surf);
          }
#if defined HAVE_PGTK && defined HAVE_WAYLAND_EGL
        if (fd->frame_cb)
          { wl_callback_destroy (fd->frame_cb); fd->frame_cb = NULL; }
        if (fd->wl_win)
          { wl_egl_window_destroy (fd->wl_win); fd->wl_win = NULL; }
        if (fd->wl_sub)
          { wl_subsurface_destroy (fd->wl_sub); fd->wl_sub = NULL; }
        if (fd->wl_surf && fd->wl_surf != fd->wl_parent_surf)
          { wl_surface_destroy (fd->wl_surf); fd->wl_surf = NULL; }
#endif
        if (fd->fbo) glDeleteFramebuffers (1, &fd->fbo);
        if (fd->scratch_fbo) glDeleteFramebuffers (1, &fd->scratch_fbo);
        if (fd->tex) glDeleteTextures (1, &fd->tex);
        if (fd->scratch_tex) glDeleteTextures (1, &fd->scratch_tex);
        if (fd->trans_tex) glDeleteTextures (1, &fd->trans_tex);
#ifdef HAVE_GSTREAMER
        gl_video_free (fd);
#endif
        free (fd);
        g_frames[i] = NULL;
        gfx_free_frame_state (f);
        return;
      }
}

/* ------------------------------------------------------------------ */
/* Inline video (gpu-video-*).  GStreamer decodes the file into RGBA
   frames; gl_video_tick uploads the newest frame to a texture and the
   present composites it over the FBO blit at the video rect, clipped to
   the window interior.  This is the OpenGL analogue of the Metal driver's
   MtlVideoPlayer (AVFoundation -> CVMetalTextureCache).  Audio is handled
   by playbin's own audio sink.  */

#ifdef HAVE_GSTREAMER

struct gl_video
{
  GstElement *pipeline;        /* playbin */
  GstElement *appsink;         /* RGBA video sink we pull frames from */
  GLuint tex;                  /* uploaded RGBA frame, or 0 */
  int vw, vh;                  /* natural frame size in pixels */
  int rx, ry, rw, rh;          /* draw rect, frame-relative logical px */
  int cx, cy, cw, ch;          /* clip rect, logical px; cw<=0 means none */
  bool loop;
  bool have_frame;
  unsigned tex_serial;         /* bumped on every uploaded frame */
  bool moved;                  /* rect/clip changed since the last pump */
};

static bool g_gst_inited = false;

/* Pull the most recent decoded frame (non-blocking) and upload it to the
   video texture.  No-op when no new sample is ready.  */
static void
gl_video_upload_latest (struct gl_video *v)
{
  if (!v || !v->appsink) return;
  GstSample *sample =
    gst_app_sink_try_pull_sample (GST_APP_SINK (v->appsink), 0);
  if (!sample) return;

  GstCaps *caps = gst_sample_get_caps (sample);
  GstBuffer *buf = gst_sample_get_buffer (sample);
  GstVideoInfo info;
  if (caps && buf && gst_video_info_from_caps (&info, caps))
    {
      GstVideoFrame vf;
      if (gst_video_frame_map (&vf, &info, buf, GST_MAP_READ))
        {
          int w = GST_VIDEO_FRAME_WIDTH (&vf);
          int h = GST_VIDEO_FRAME_HEIGHT (&vf);
          int stride = GST_VIDEO_FRAME_PLANE_STRIDE (&vf, 0);
          const guint8 *data = GST_VIDEO_FRAME_PLANE_DATA (&vf, 0);
          if (!v->tex)
            {
              glGenTextures (1, &v->tex);
              glBindTexture (GL_TEXTURE_2D, v->tex);
              glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
              glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
              glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
              glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
              v->vw = -1;       /* force a fresh allocation below */
            }
          glBindTexture (GL_TEXTURE_2D, v->tex);
          /* RGBA rows are 4-byte aligned; set the unpack row length so a
             padded stride still uploads correctly.  */
          glPixelStorei (GL_UNPACK_ALIGNMENT, 4);
          glPixelStorei (GL_UNPACK_ROW_LENGTH, stride / 4);
          if (w != v->vw || h != v->vh)
            {
              glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0,
                            GL_RGBA, GL_UNSIGNED_BYTE, data);
              v->vw = w; v->vh = h;
            }
          else
            glTexSubImage2D (GL_TEXTURE_2D, 0, 0, 0, w, h,
                             GL_RGBA, GL_UNSIGNED_BYTE, data);
          glPixelStorei (GL_UNPACK_ROW_LENGTH, 0);
          v->have_frame = true;
          v->tex_serial++;
          gst_video_frame_unmap (&vf);
        }
    }
  gst_sample_unref (sample);
}

/* Composite the current video frame over the on-screen default framebuffer
   at its rect, clipped to its window.  Called from gl_present_to_window
   with the window surface current (sw x sh = surface size).  */
static void
gl_video_overlay (struct gl_frame_data *fd, int sw, int sh)
{
  struct gl_video *v = fd->video;
  if (!v || !v->have_frame || !v->tex || v->rw <= 0 || v->rh <= 0) return;
  double s = fd->scale;

  bool clip = (v->cw > 0 && v->ch > 0);
  if (clip)
    {
      int x0 = (int) lround (v->cx * s);
      int x1 = (int) lround ((v->cx + v->cw) * s);
      int ytop = (int) lround (v->cy * s);
      int ybot = (int) lround ((v->cy + v->ch) * s);
      if (x0 < 0) x0 = 0;
      if (x1 > sw) x1 = sw;
      if (ytop < 0) ytop = 0;
      if (ybot > sh) ybot = sh;
      int scw = x1 - x0, sch = ybot - ytop;
      if (scw <= 0 || sch <= 0) return;          /* fully scrolled away */
      glEnable (GL_SCISSOR_TEST);
      glScissor (x0, sh - ybot, scw, sch);       /* default fb: bottom-left */
    }
  else
    glDisable (GL_SCISSOR_TEST);

  float x0 = (float) (v->rx * s), y0 = (float) (v->ry * s);
  float x1 = (float) ((v->rx + v->rw) * s), y1 = (float) ((v->ry + v->rh) * s);
  /* a_pos in top-left logical->physical px (VS_IMAGE flips to NDC); the RGBA
     frame is top-row-first, so texcoords are NOT v-flipped.  */
  float verts[] = {
    x0,y0, 0,0,   x1,y0, 1,0,   x0,y1, 0,1,
    x1,y0, 1,0,   x1,y1, 1,1,   x0,y1, 0,1,
  };
  glViewport (0, 0, sw, sh);
  glUseProgram (g_prog_image);
  glUniform2f (g_u_image_size, (float) sw, (float) sh);
  glActiveTexture (GL_TEXTURE0);
  glBindTexture (GL_TEXTURE_2D, v->tex);
  glUniform1i (g_u_image_tex, 0);
  glUniform1f (g_u_image_alpha, 1.0f);
  glBindBuffer (GL_ARRAY_BUFFER, g_vbo);
  glBufferData (GL_ARRAY_BUFFER, sizeof verts, verts, GL_STREAM_DRAW);
  glEnableVertexAttribArray (0);
  glVertexAttribPointer (0, 2, GL_FLOAT, GL_FALSE, 16, (void *) 0);
  glEnableVertexAttribArray (1);
  glVertexAttribPointer (1, 2, GL_FLOAT, GL_FALSE, 16, (void *) 8);
  glDrawArrays (GL_TRIANGLES, 0, 6);
  if (clip) glDisable (GL_SCISSOR_TEST);
}

static void
gl_video_free (struct gl_frame_data *fd)
{
  struct gl_video *v = fd->video;
  if (!v) return;
  if (v->pipeline)
    {
      gst_element_set_state (v->pipeline, GST_STATE_NULL);
      gst_object_unref (v->pipeline);
    }
  if (v->tex) glDeleteTextures (1, &v->tex);
  free (v);
  fd->video = NULL;
}

/* Restart at EOS when looping; harmless otherwise.  Polls the pipeline bus
   without blocking.  */
static void
gl_video_pump_bus (struct gl_video *v)
{
  GstBus *bus = gst_element_get_bus (v->pipeline);
  if (!bus) return;
  GstMessage *msg;
  while ((msg = gst_bus_pop_filtered (bus,
            GST_MESSAGE_EOS | GST_MESSAGE_ERROR)) != NULL)
    {
      if (GST_MESSAGE_TYPE (msg) == GST_MESSAGE_EOS && v->loop)
        gst_element_seek_simple (v->pipeline, GST_FORMAT_TIME,
                                 GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT,
                                 0);
      gst_message_unref (msg);
    }
  gst_object_unref (bus);
}

bool
gl_video_open (struct frame *f, const char *path, int x, int y,
               int w, int h, bool loop)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd) return false;
  if (!g_gst_inited) { gst_init (NULL, NULL); g_gst_inited = true; }

  if (fd->video) gl_video_free (fd);

  GstElement *pipeline = gst_element_factory_make ("playbin", NULL);
  GstElement *appsink = gst_element_factory_make ("appsink", NULL);
  if (!pipeline || !appsink)
    {
      if (pipeline) gst_object_unref (pipeline);
      if (appsink) gst_object_unref (appsink);
      return false;
    }

  GstCaps *caps = gst_caps_new_simple ("video/x-raw", "format",
                                       G_TYPE_STRING, "RGBA", NULL);
  g_object_set (appsink, "caps", caps, "sync", TRUE,
                "max-buffers", 1, "drop", TRUE, NULL);
  gst_caps_unref (caps);

  gchar *uri = gst_filename_to_uri (path, NULL);
  if (!uri) { gst_object_unref (pipeline); gst_object_unref (appsink); return false; }
  /* playbin takes ownership of the sink via the video-sink property.  */
  g_object_set (pipeline, "uri", uri, "video-sink", appsink, NULL);
  g_free (uri);

  struct gl_video *v = calloc (1, sizeof *v);
  if (!v) { gst_object_unref (pipeline); return false; }
  v->pipeline = pipeline;
  v->appsink = appsink;        /* owned by playbin; do not unref separately */
  v->rx = x; v->ry = y; v->rw = w; v->rh = h;
  v->vw = v->vh = -1;
  v->loop = loop;
  fd->video = v;

  if (gst_element_set_state (pipeline, GST_STATE_PLAYING)
      == GST_STATE_CHANGE_FAILURE)
    {
      gl_video_free (fd);
      return false;
    }
  return true;
}

bool
gl_video_close (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return false;
  gl_video_free (fd);
  return true;
}

bool
gl_video_set_paused (struct frame *f, bool paused)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return false;
  gst_element_set_state (fd->video->pipeline,
                         paused ? GST_STATE_PAUSED : GST_STATE_PLAYING);
  return true;
}

bool
gl_video_set_rect (struct frame *f, int x, int y, int w, int h)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return false;
  struct gl_video *v = fd->video;
  if (v->rx != x || v->ry != y || v->rw != w || v->rh != h)
    v->moved = true;
  v->rx = x; v->ry = y;
  v->rw = w; v->rh = h;
  return true;
}

bool
gl_video_set_clip (struct frame *f, int x, int y, int w, int h)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return false;
  struct gl_video *v = fd->video;
  if (v->cx != x || v->cy != y || v->cw != w || v->ch != h)
    v->moved = true;
  v->cx = x; v->cy = y;
  v->cw = w; v->ch = h;
  return true;
}

/* Pull pending bus messages and upload the newest decoded frame.  True
   when the on-screen video needs a present: a fresh frame arrived or
   the rect/clip moved since the last pump.  */
static bool
gl_video_pump (struct gl_video *v)
{
  gl_video_pump_bus (v);
  unsigned before = v->tex_serial;
  gl_video_upload_latest (v);
  bool fresh = v->tex_serial != before;
  if (getenv ("GL_LOG_PRESENT"))
    fprintf (stderr, "[glvideo] tick t=%.4f %s\n", gl_now (),
             fresh ? "new-frame" : "no-sample");
  bool need = fresh || v->moved;
  v->moved = false;
  return need;
}

bool
gl_video_tick (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return false;
  /* Present only what changed, under the same global throttle as the
     other animation sources (see last_swap): a paused video issues no
     presents, and a tick landing right after another present defers to
     it -- every present composites the video texture anyway.  */
  if (gl_video_pump (fd->video)
      && !fd->in_cycle && gl_swap_ok (fd))
    { gl_present_to_window (fd); fd->needs_present = false; }
  return true;
}

double
gl_video_duration (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return -1.0;
  gint64 dur = 0;
  if (gst_element_query_duration (fd->video->pipeline, GST_FORMAT_TIME, &dur)
      && dur > 0)
    return (double) dur / GST_SECOND;
  return -1.0;
}

double
gl_video_position (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return -1.0;
  gint64 pos = 0;
  if (gst_element_query_position (fd->video->pipeline, GST_FORMAT_TIME, &pos)
      && pos >= 0)
    return (double) pos / GST_SECOND;
  return -1.0;
}

bool
gl_video_seek (struct frame *f, double seconds)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return false;
  if (seconds < 0) seconds = 0;
  gst_element_seek_simple (fd->video->pipeline, GST_FORMAT_TIME,
                           GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT,
                           (gint64) (seconds * GST_SECOND));
  return true;
}

int
gl_video_playing (struct frame *f)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video) return -1;
  GstState st = GST_STATE_NULL;
  gst_element_get_state (fd->video->pipeline, &st, NULL, 0);
  return st == GST_STATE_PLAYING ? 1 : 0;
}

bool
gl_video_size (struct frame *f, double *w, double *h)
{
  struct gl_frame_data *fd = gl_get_frame_data (f);
  if (!fd || !fd->video || fd->video->vw <= 0) return false;
  *w = fd->video->vw; *h = fd->video->vh;
  return true;
}

#endif /* HAVE_GSTREAMER */

#endif /* HAVE_GFX_GL */
