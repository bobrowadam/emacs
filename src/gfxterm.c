/* gfxterm.c --- platform-neutral GPU drawing policy for GNU Emacs.
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


   The gfx backend split: everything the redisplay engine needs drawn
   (glyph strings with their backgrounds, boxes, reliefs and decorations;
   compositions; cursors; fringe bitmaps; window borders and dividers;
   scroll blits; the render-cycle policy with its deferred presents) lives
   here, written against the small driver vtable in gfxdrv.h.  The Metal
   driver (mtlterm.m) is the only implementation today; a future OpenGL
   driver plugs in underneath without touching this file.

   This logic was brought to pixel-parity with the NS (CoreGraphics)
   backend over many sessions; when modifying it, compare against
   nsterm.m's equivalent paths and re-run the comparison harness.  */

#include <config.h>

/* Built whenever a gfx driver exists: Metal (macOS) or OpenGL (X11).  */
#if defined (HAVE_MTL) || defined (HAVE_GFX_GL)

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "lisp.h"
#include "dispextern.h"
#include "frame.h"
#include "window.h"
#include "character.h"
#include "font.h"
#include "composite.h"

#include "gfxdrv.h"

/* The active driver, registered by the platform backend (mtl_setup_frame)
   before any policy function can run.  */
struct gfx_driver *gfx_drv = NULL;

/* Original platform implementations for frames the GPU backend is NOT
   enabled on (tooltips, child frames, frames made without mtl-enable):
   the patched rif/hooks are terminal-wide, so without this delegation
   those frames would render nothing at all.  Captured by the platform
   glue before patching (mtl_patch_terminal_rif).  */
struct gfx_fallback_fns gfx_fallback = { NULL, NULL, NULL, NULL, NULL };

/* Diagnostic counters surfaced by mtl-draw-stats.  */
int mtl_dgs_call_count   = 0;  /* total draw_glyph_string calls */
int mtl_dgs_nofd_count   = 0;  /* no driver data or no cycle */
int mtl_dgs_nofont_count = 0;  /* could not resolve a font */
int mtl_dgs_drawn_count  = 0;  /* glyphs actually drawn */

/* -----------------------------------------------------------------------
   Sequence tracing (MTL_LOG_SEQ=1): begin/clear/draw/end/present flow.
   This is what exposed the blank present behind the first-tab-switch
   flash; keep it cheap and gated.
   ----------------------------------------------------------------------- */

static bool
gfx_log_seq_p (void)
{
  static int on = -1;
  if (on < 0) on = getenv ("MTL_LOG_SEQ") != NULL;
  return on > 0;
}

#define GFX_SEQ(fmt, ...)                                               \
  do { if (gfx_log_seq_p ())                                            \
         fprintf (stderr, "[gfxseq] " fmt "\n", ##__VA_ARGS__); } while (0)

/* -----------------------------------------------------------------------
   Per-frame policy state.  Kept policy-side (the driver knows nothing
   about render-cycle policy), keyed by the frame pointer.
   ----------------------------------------------------------------------- */

#define GFX_MAX_PENDING_CLEARS 32

struct gfx_frame_state
{
  struct frame *f;

  /* Within the current update cycle: clear_frame ran / content was drawn.
     A cycle that only cleared (a garbaged frame, e.g. the first switch to
     a tab whose faces are not realized yet) must NOT present, or the user
     sees a blank flash before the follow-up cycle paints the real
     content.  The native backends do not flash there because their
     window-system coalesces backing-store flushes.  */
  bool cycle_saw_clear;
  bool cycle_saw_draw;

  /* Expose substitute: last known pixel height of the minibuffer window.
     When it changes, update_begin clears the affected bottom strip (NS
     relies on its drawRect: expose path for the uncovered pixels; the
     gfx backend has none).  */
  int last_mini_height;

  /* Scroll-bar gutter rects queued during the layout phase (no cycle
     open yet) and flushed to background when the next cycle opens.  */
  struct { int x, y, w, h; } pending_clears[GFX_MAX_PENDING_CLEARS];
  int n_pending_clears;

  struct gfx_frame_state *next;
};

static struct gfx_frame_state *gfx_frames = NULL;

static struct gfx_frame_state *
gfx_state (struct frame *f)
{
  struct gfx_frame_state *st;
  for (st = gfx_frames; st; st = st->next)
    if (st->f == f)
      return st;
  st = xzalloc (sizeof *st);
  st->f = f;
  st->next = gfx_frames;
  gfx_frames = st;
  return st;
}

void
gfx_free_frame_state (struct frame *f)
{
  struct gfx_frame_state **p = &gfx_frames;
  while (*p)
    {
      if ((*p)->f == f)
        {
          struct gfx_frame_state *dead = *p;
          *p = dead->next;
          xfree (dead);
          return;
        }
      p = &(*p)->next;
    }
}

/* Driver available and enabled on F?  Every entry point checks this: the
   patched rif is terminal-wide, but only frames the user enabled the GPU
   backend on have driver data.  */
static bool
gfx_ready (struct frame *f)
{
  return gfx_drv && gfx_drv->frame_ready (f);
}

/* Public predicate for the terminal glue (xterm.c): is the GPU backend
   enabled on F?  Lets the X input-time flush route through the GPU
   present instead of the X double-buffer swap.  */
bool
gfx_frame_gpu_p (struct frame *f)
{
  return gfx_ready (f);
}

/* Open a render cycle and flush any queued scroll-bar gutter clears (they
   were queued during layout, when no cycle was open).  Every place the
   policy opens a cycle goes through here.  */
static void
gfx_begin_frame (struct frame *f)
{
  struct gfx_frame_state *st = gfx_state (f);
  gfx_drv->begin_frame (f);
  if (st->n_pending_clears > 0)
    {
      unsigned long bg = gfx_drv->frame_background (f);
      for (int i = 0; i < st->n_pending_clears; i++)
        gfx_drv->fill_rect (f, st->pending_clears[i].x,
                            st->pending_clears[i].y,
                            st->pending_clears[i].w,
                            st->pending_clears[i].h, bg);
      st->n_pending_clears = 0;
    }
}

void
gfx_queue_clear (struct frame *f, int x, int y, int w, int h)
{
  if (w <= 0 || h <= 0 || !gfx_ready (f)) return;
  struct gfx_frame_state *st = gfx_state (f);
  if (st->n_pending_clears < GFX_MAX_PENDING_CLEARS)
    {
      st->pending_clears[st->n_pending_clears].x = x;
      st->pending_clears[st->n_pending_clears].y = y;
      st->pending_clears[st->n_pending_clears].w = w;
      st->pending_clears[st->n_pending_clears].h = h;
      st->n_pending_clears++;
    }
}

/* -----------------------------------------------------------------------
   Relief / box drawing.
   ----------------------------------------------------------------------- */

/* Fallback shade when the driver has no appearance-aware relief colors.  */
static unsigned long
gfx_shade_color (unsigned long c, double level, bool lighten)
{
  double r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
  if (lighten) { r += (255 - r) * level; g += (255 - g) * level; b += (255 - b) * level; }
  else         { r *= (1.0 - level);     g *= (1.0 - level);     b *= (1.0 - level); }
  return ((unsigned long) r << 16) | ((unsigned long) g << 8) | (unsigned long) b;
}

static void
gfx_relief_colors (struct glyph_string *s, unsigned long *light,
                   unsigned long *dark)
{
  if (gfx_drv->relief_colors)
    {
      gfx_drv->relief_colors (s, light, dark);
      return;
    }
  struct face *face = s->face;
  unsigned long base = face->use_box_color_for_shadows_p
                       ? face->box_color : face->background;
  if (s->hl == DRAW_CURSOR)
    base = gfx_drv->cursor_color (s->f);
  *light = gfx_shade_color (base, 0.4, true);
  *dark  = gfx_shade_color (base, 0.4, false);
}

/* Draw a relief inside the rect with axis-aligned edges.  Raised: light
   top/left + dark bottom/right; sunken: the inverse.  Ports the pixel
   policy shared by ns_draw_relief and x_draw_relief_rect: the light
   region is painted first so the corners shared with the dark region end
   up dark, and when an edge is thicker than one pixel its outermost line
   is drawn in the dark relief colour (the "draw the outermost line using
   the black relief" hack in both native backends).  The diagonal corner
   taper (bezel/trapezoid) and the corner erase those backends add are
   not expressible with fill_rect and stay as a sub-pixel residual.  */
static void
gfx_draw_relief (struct glyph_string *s, int x, int y, int w, int h,
                 int hth, int vth, bool raised_p,
                 bool top_p, bool bot_p, bool left_p, bool right_p)
{
  struct frame *f = s->f;
  unsigned long light, dark;
  gfx_relief_colors (s, &light, &dark);
  unsigned long tl = raised_p ? light : dark;
  unsigned long br = raised_p ? dark  : light;
  /* Light (top/left) region first, then the dark (bottom/right) region,
     matching the native draw order so the overlapping corners go dark.  */
  if (top_p)
    gfx_drv->fill_rect (f, x, y, w, hth, tl);
  if (left_p)
    gfx_drv->fill_rect (f, x, y, vth, h, tl);
  if (bot_p)
    gfx_drv->fill_rect (f, x, y + h - hth, w, hth, br);
  if (right_p)
    gfx_drv->fill_rect (f, x + w - vth, y, vth, h, br);
  /* Outermost top/left line in the dark relief colour when the edge is
     thicker than one pixel (no-op for the common 1px relief).  */
  if (top_p && hth > 1)
    gfx_drv->fill_rect (f, x, y, w, 1, br);
  if (left_p && vth > 1)
    gfx_drv->fill_rect (f, x, y, 1, h, br);
}

/* Draw the face box / relief around glyph string S (mode line, buttons,
   etc.).  Ports ns_dumpglyphs_box_or_relief + ns_draw_box/ns_draw_relief
   with simple rectangle edges (good enough for the typical 1px relief).  */
static void
gfx_draw_glyph_string_box (struct glyph_string *s)
{
  struct face *face = s->face;
  if (!face || face->box == FACE_NO_BOX) return;

  int hth = abs (face->box_horizontal_line_width);
  int vth = abs (face->box_vertical_line_width);
  if (hth == 0 && vth == 0) return;

  /* Image and composition strings have no usable nchars; their single
     glyph carries the box flags (mirrors xterm's x_draw_glyph_string_box).  */
  struct glyph *last_glyph = (s->cmp || s->img)
                             ? s->first_glyph
                             : s->first_glyph + s->nchars - 1;
  int last_x = (s->row->full_width_p && !s->w->pseudo_window_p)
               ? WINDOW_RIGHT_EDGE_X (s->w)
               : window_box_right (s->w, s->area);
  int right_x = (s->row->full_width_p && s->extends_to_end_of_line_p
                 ? last_x - 1
                 : min (last_x, s->x + s->background_width) - 1);
  /* A mouse-face run gets box edges at its own boundaries, like NS.  */
  bool left_p  = (s->first_glyph->left_box_line_p
                  || (s->hl == DRAW_MOUSE_FACE
                      && (s->prev == NULL || s->prev->hl != s->hl)));
  bool right_p = (last_glyph->right_box_line_p
                  || (s->hl == DRAW_MOUSE_FACE
                      && (s->next == NULL || s->next->hl != s->hl)));

  int x = s->x, y = s->y, w = right_x - s->x + 1, h = s->height;
  if (w <= 0 || h <= 0) return;

  if (face->box == FACE_SIMPLE_BOX)
    {
      unsigned long c = face->box_color;
      gfx_drv->fill_rect (s->f, x, y, w, hth, c);              /* top */
      gfx_drv->fill_rect (s->f, x, y + h - hth, w, hth, c);    /* bottom */
      if (left_p)
        gfx_drv->fill_rect (s->f, x, y, vth, h, c);            /* left */
      if (right_p)
        gfx_drv->fill_rect (s->f, x + w - vth, y, vth, h, c);  /* right */
    }
  else
    gfx_draw_relief (s, x, y, w, h, hth, vth,
                     face->box == FACE_RAISED_BOX,
                     true, true, left_p, right_p);
}

/* Draw the relief around image glyph string S (tab/tool bar buttons and
   images with :relief).  Port of ns_draw_image_relief.  */
static void
gfx_draw_image_relief (struct glyph_string *s)
{
  int x1, y1, thick;
  bool raised_p, top_p, bot_p, left_p, right_p;
  int extra_x, extra_y;
  int x = s->x;
  int y = s->ybase - image_ascent (s->img, s->face, &s->slice);

  if (s->face->box != FACE_NO_BOX
      && s->first_glyph->left_box_line_p
      && s->slice.x == 0)
    x += max (s->face->box_vertical_line_width, 0);

  if (s->slice.x == 0)
    x += s->img->hmargin;
  if (s->slice.y == 0)
    y += s->img->vmargin;

  if (s->hl == DRAW_IMAGE_SUNKEN || s->hl == DRAW_IMAGE_RAISED)
    {
      if (s->face->id == TAB_BAR_FACE_ID)
        thick = (tab_bar_button_relief < 0
                 ? DEFAULT_TAB_BAR_BUTTON_RELIEF
                 : min (tab_bar_button_relief, 1000000));
      else
        thick = (tool_bar_button_relief < 0
                 ? DEFAULT_TOOL_BAR_BUTTON_RELIEF
                 : min (tool_bar_button_relief, 1000000));
      raised_p = s->hl == DRAW_IMAGE_RAISED;
    }
  else
    {
      thick = eabs (s->img->relief);
      raised_p = s->img->relief > 0;
    }

  x1 = x + s->slice.width - 1;
  y1 = y + s->slice.height - 1;

  extra_x = extra_y = 0;
  if (s->face->id == TAB_BAR_FACE_ID)
    {
      if (CONSP (Vtab_bar_button_margin)
          && FIXNUMP (XCAR (Vtab_bar_button_margin))
          && FIXNUMP (XCDR (Vtab_bar_button_margin)))
        {
          extra_x = XFIXNUM (XCAR (Vtab_bar_button_margin)) - thick;
          extra_y = XFIXNUM (XCDR (Vtab_bar_button_margin)) - thick;
        }
      else if (FIXNUMP (Vtab_bar_button_margin))
        extra_x = extra_y = XFIXNUM (Vtab_bar_button_margin) - thick;
    }
  if (s->face->id == TOOL_BAR_FACE_ID)
    {
      if (CONSP (Vtool_bar_button_margin)
          && FIXNUMP (XCAR (Vtool_bar_button_margin))
          && FIXNUMP (XCDR (Vtool_bar_button_margin)))
        {
          extra_x = XFIXNUM (XCAR (Vtool_bar_button_margin));
          extra_y = XFIXNUM (XCDR (Vtool_bar_button_margin));
        }
      else if (FIXNUMP (Vtool_bar_button_margin))
        extra_x = extra_y = XFIXNUM (Vtool_bar_button_margin);
    }

  top_p = bot_p = left_p = right_p = false;

  if (s->slice.x == 0)
    x -= thick + extra_x, left_p = true;
  if (s->slice.y == 0)
    y -= thick + extra_y, top_p = true;
  if (s->slice.x + s->slice.width == s->img->width)
    x1 += thick + extra_x, right_p = true;
  if (s->slice.y + s->slice.height == s->img->height)
    y1 += thick + extra_y, bot_p = true;

  if (thick > 0)
    gfx_draw_relief (s, x, y, x1 - x + 1, y1 - y + 1,
                     thick, thick, raised_p, top_p, bot_p, left_p, right_p);
}

/* -----------------------------------------------------------------------
   Underline metrics.
   ----------------------------------------------------------------------- */

/* Compute the underline offset below the baseline and its thickness,
   mirroring ns_draw_text_decoration.  These depend on font metrics; the
   glyph string's underline_position/underline_thickness are otherwise
   left uninitialized, so the underline was being drawn at the baseline
   (offset 0), cutting through the bottom of the glyphs.  Honors the
   face's descent-line options and uses the default
   underline-minimum-offset (1) and x-use-underline-position-properties
   (t).  */
static void
gfx_underline_metrics (struct glyph_string *s, int *position, int *thickness)
{
  /* Match a previous underlined run so a continued underline stays
     seamless.  */
  if (s->prev
      && s->prev->face->underline != FACE_UNDERLINE_WAVE
      && s->prev->face->underline >= FACE_UNDERLINE_SINGLE
      && s->prev->underline_thickness > 0
      && (s->prev->face->underline_at_descent_line_p
          == s->face->underline_at_descent_line_p)
      && (s->prev->face->underline_pixels_above_descent_line
          == s->face->underline_pixels_above_descent_line))
    {
      *thickness = s->prev->underline_thickness;
      *position  = s->prev->underline_position;
      return;
    }

  struct font *font = font_for_underline_metrics (s);
  int descent = s->y + s->height - s->ybase;
  int minimum_offset = 1;
  int th = (font && font->underline_thickness > 0)
           ? font->underline_thickness : 1;
  int pos;

  if (s->face->underline_at_descent_line_p)
    pos = descent - th - s->face->underline_pixels_above_descent_line;
  else if (font && font->underline_position >= 0)
    pos = font->underline_position;
  else if (font)
    pos = lround (font->descent / 2.0);
  else
    pos = minimum_offset;

  if (!s->face->underline_pixels_above_descent_line)
    pos = max (pos, minimum_offset);

  /* Keep the underline inside the cell.  NS computes DESCENT as
     unsigned, so a :position larger than the descent UNDERFLOWS and the
     first clamp snaps it to the row bottom; mirror that (pos < 0 below)
     or a big :position would cross the glyphs instead.  */
  if (pos < 0 || descent <= pos) { pos = descent - 1; th = 1; }
  else if (descent < pos + th)     th = 1;

  *position = pos;
  *thickness = th;
}

/* -----------------------------------------------------------------------
   Composition glyph strings.
   ----------------------------------------------------------------------- */

/* Draw glyph IDs s->char2b[FROM..TO) sequentially from (X, Y baseline),
   advancing each glyph by its natural font advance (composition runs are
   laid out by font metrics, not by the Emacs column grid).  */
static void
gfx_draw_cmp_run (struct glyph_string *s, struct font *font,
                  unsigned long fg, int from, int to, int x, int y)
{
  bool color_font = gfx_drv->color_font_p (font);
  float pen = (float) x;
  for (int k = from; k < to; k++)
    {
      unsigned int g = s->char2b[k];
      if (color_font)
        pen += gfx_drv->draw_color_glyph (s->f, font, g, pen, (float) y);
      else
        {
          struct gfx_glyph *ge = gfx_drv->get_glyph (font, g);
          if (!ge) continue;
          if (ge->width > 0)
            gfx_drv->draw_glyph (s->f, ge, pen, (float) y, fg);
          pen += ge->advance_x;
        }
    }
}

/* Draw a composition glyph string: combining accents, ligatures and
   shaped scripts (Arabic, Indic).  Mirrors
   ns_draw_composite_glyph_string_foreground but renders through the
   driver's glyph atlas instead of font->driver->draw.  char2b[] holds
   glyph IDs indexed by the composition/gstring index (see
   fill_composite_glyph_string / fill_gstring_glyph_string) and s->font
   is the composition's font (it can differ from the face font).  */
static void
gfx_draw_composite_glyph_string (struct glyph_string *s, unsigned long fg)
{
  int x;
  if (s->face && s->face->box != FACE_NO_BOX && s->first_glyph->left_box_line_p)
    x = s->x + max (s->face->box_vertical_line_width, 0);
  else
    x = s->x;

  if (!s->font || !gfx_drv->font_ready_p (s->font) || s->font_not_found_p)
    {
      /* Placeholder outline when the composition's font is missing.  */
      if (s->cmp_from == 0)
        {
          unsigned long cc = gfx_drv->cursor_color (s->f);
          gfx_drv->fill_rect (s->f, s->x, s->y, s->width - 1, 1, cc);
          gfx_drv->fill_rect (s->f, s->x, s->y + s->height - 2,
                              s->width - 1, 1, cc);
          gfx_drv->fill_rect (s->f, s->x, s->y, 1, s->height - 1, cc);
          gfx_drv->fill_rect (s->f, s->x + s->width - 2, s->y,
                              1, s->height - 1, cc);
        }
      return;
    }

  if (!s->first_glyph->u.cmp.automatic)
    {
      /* Static composition: each glyph at an explicit offset from the
         table.  */
      int y = s->ybase;
      int i, j;
      for (i = 0, j = s->cmp_from; i < s->nchars; i++, j++)
        if (COMPOSITION_GLYPH (s->cmp, j) != '\t')
          {
            int xx = x + s->cmp->offsets[j * 2];
            int yy = y - s->cmp->offsets[j * 2 + 1];
            gfx_draw_cmp_run (s, s->font, fg, j, j + 1, xx, yy);
          }
    }
  else
    {
      /* Automatic composition (shaping): LGLYPHs, some with adjustments.  */
      Lisp_Object gstring = composition_gstring_from_id (s->cmp_id);
      int y = s->ybase;
      int width = 0, i, j;

      for (i = j = s->cmp_from; i < s->cmp_to; i++)
        {
          Lisp_Object glyph = LGSTRING_GLYPH (gstring, i);
          if (NILP (LGLYPH_ADJUSTMENT (glyph)))
            width += LGLYPH_WIDTH (glyph);
          else
            {
              if (j < i)
                {
                  gfx_draw_cmp_run (s, s->font, fg, j, i, x, y);
                  x += width;
                }
              gfx_draw_cmp_run (s, s->font, fg, i, i + 1,
                                x + LGLYPH_XOFF (glyph),
                                y + LGLYPH_YOFF (glyph));
              x += LGLYPH_WADJUST (glyph);
              width = 0;
              j = i + 1;
            }
        }
      if (j < i)
        gfx_draw_cmp_run (s, s->font, fg, j, i, x, y);
    }
}

/* -----------------------------------------------------------------------
   Glyph string drawing (the heart of the policy).
   ----------------------------------------------------------------------- */

static void
gfx_draw_glyph_string_impl (struct glyph_string *s)
{
  mtl_dgs_call_count++;

  struct frame *f = s->f;
  if (!gfx_ready (f) || !gfx_drv->in_cycle (f))
    { mtl_dgs_nofd_count++; return; }

  struct face *face = s->face;
  unsigned long fg = face ? face->foreground : 0x000000;
  unsigned long bg = face ? face->background : 0xFFFFFF;

  /* When this string is drawn as the cursor (via draw_phys_cursor_glyph),
     invert: fill the background with the cursor color and draw the glyph
     in the face's background color so the character stays readable.
     Mirrors the NS backend (FRAME_CURSOR_COLOR + FRAME_BACKGROUND for
     text).  */
  if (s->hl == DRAW_CURSOR)
    {
      bg = gfx_drv->cursor_color (f);
      fg = face ? face->background : 0xFFFFFF;
    }

  /* Background fill.  Inset vertically by the box line width, exactly
     like the NS backend (ns_maybe_dumpglyphs_background): for a boxed
     face (e.g. the selected tab-bar tab) this leaves the box edge rows
     untouched so the relief drawn afterwards is not overwritten and then
     redrawn.  For unboxed faces box_line_width is 0, so this is identical
     to filling the full height.  */
  if (!s->background_filled_p)
    {
      /* Images and stretch glyphs get the full cell height.  NS fills
         images without the box inset, and ns_draw_stretch_glyph_string
         also fills the complete stretch area before drawing its box.  */
      bool full_height_p = (s->first_glyph
                            && (s->first_glyph->type == IMAGE_GLYPH
                                || s->first_glyph->type == STRETCH_GLYPH));
      int blw = (face && !full_height_p)
                ? max (face->box_horizontal_line_width, 0) : 0;
      gfx_drv->fill_rect (f, s->x, s->y + blw,
                          s->background_width, s->height - 2 * blw, bg);
      s->background_filled_p = true;
    }

  if (!s->first_glyph) return;

  /* Inline images via the driver's texture pipeline.  */
  if (s->first_glyph->type == IMAGE_GLYPH)
    {
      struct image *img = s->img;
      if (img)
        {
          int tw = 0, th = 0;
          void *tex = gfx_drv->image_texture (f, img, &tw, &th);
          if (tex && tw > 0 && th > 0)
            {
              int x = s->x;
              int y = s->ybase - image_ascent (img, s->face, &s->slice);
              /* Start to the right of a left box line, like NS.  */
              if (face && face->box != FACE_NO_BOX
                  && s->first_glyph->left_box_line_p && s->slice.x == 0)
                x += max (face->box_vertical_line_width, 0);
              if (s->slice.x == 0) x += s->img->hmargin;
              if (s->slice.y == 0) y += s->img->vmargin;
              /* The texture holds the full display-size image; sample
                 only this glyph string's slice (insert-sliced-image).  */
              gfx_drv->draw_texture (f, tex,
                                     (float) x, (float) y,
                                     (float) s->slice.width,
                                     (float) s->slice.height,
                                     s->slice.x / (float) tw,
                                     s->slice.y / (float) th,
                                     (s->slice.x + s->slice.width)
                                       / (float) tw,
                                     (s->slice.y + s->slice.height)
                                       / (float) th,
                                     1.0f);
            }
          /* Relief around tab/tool bar buttons and :relief images.  */
          if (s->img->relief
              || s->hl == DRAW_IMAGE_RAISED || s->hl == DRAW_IMAGE_SUNKEN)
            gfx_draw_image_relief (s);
        }
      /* The face box is drawn after the image, like NS ("draw box if not
         done already" at the end of ns_draw_glyph_string).  */
      if (face && face->box != FACE_NO_BOX)
        gfx_draw_glyph_string_box (s);
      return;
    }

  bool stretch_p = s->first_glyph->type == STRETCH_GLYPH;

  if (s->first_glyph->type == COMPOSITE_GLYPH)
    {
      /* Combining accents, ligatures, shaped scripts.  */
      gfx_draw_composite_glyph_string (s, fg);
    }
  else if (!stretch_p)
    {
      /* Use s->font, NOT face->font: char2b holds glyph IDs encoded for
         s->font.  For a mouse-face highlight over text in a non-default
         font (e.g. shr / variable-pitch links in elfeed), Emacs swaps
         s->face to the highlight face while leaving s->font (and char2b)
         as the original font; looking those glyph IDs up in face->font
         then renders garbage.  The NS and X backends draw with s->font
         for the same reason.  */
      struct font *sfont = s->font ? s->font : (face ? face->font : NULL);
      if (!sfont || !gfx_drv->font_ready_p (sfont))
        { mtl_dgs_nofont_count++; return; }

      /* Color fonts (Apple Color Emoji) can't go through the coverage
         atlas; the driver draws them as small color textures.  */
      bool color_font = gfx_drv->color_font_p (sfont);

      /* Advance using Emacs's own integer glyph grid
         (first_glyph[i].pixel_width), NOT the font's float advance.
         Re-advancing by the fractional advance drifts away from the
         layout Emacs computed: glyphs land at fractional positions
         (linear sampling blurs them) and progressively overlap/clip
         across the line.  Keeping integer pen positions also makes the
         1:1 blit pixel-crisp.  */
      int pen_x = s->x;
      int baseline_y = s->ybase;

      for (int i = 0; i < s->nchars; i++)
        {
          /* char2b contains GLYPH IDs for the font backend -- NOT
             Unicode codepoints.  */
          unsigned int glyph_id = s->char2b ? s->char2b[i] : 0;
          int adv = s->first_glyph[i].pixel_width;

          if (glyph_id)
            {
              if (color_font)
                {
                  mtl_dgs_drawn_count++;
                  gfx_drv->draw_color_glyph (f, sfont, glyph_id,
                                             (float) pen_x,
                                             (float) baseline_y);
                }
              else
                {
                  struct gfx_glyph *ge = gfx_drv->get_glyph (sfont, glyph_id);
                  if (ge && ge->width > 0)
                    {
                      mtl_dgs_drawn_count++;
                      /* bearing_y: distance from glyph top-left to the
                         baseline; the driver places the box top at
                         baseline - bearing_y.  */
                      gfx_drv->draw_glyph (f, ge, (float) pen_x,
                                           (float) baseline_y, fg);
                    }
                }
            }

          pen_x += adv;
        }
    }

  /* NS draws a stretch glyph's box before its decorations.  This keeps
     a thick mode-line box from leaving its alignment stretch unpainted.  */
  if (stretch_p && face && face->box != FACE_NO_BOX)
    gfx_draw_glyph_string_box (s);

  int decoration_width = stretch_p ? s->background_width : s->width;
  unsigned long decoration_fg = (s->hl == DRAW_CURSOR
                                  ? gfx_drv->frame_background (f) : fg);

  /* Underline.  Wave FIRST: FACE_UNDERLINE_WAVE is above
     FACE_UNDERLINE_SINGLE in the enum, so the >= SINGLE branch would
     otherwise swallow it (NS checks wave first too).  */
  if (face && face->underline == FACE_UNDERLINE_WAVE)
    {
      /* Zigzag wave matching ns_draw_underwave: wave_height 3,
         wave_length 2, drawn at ybase..ybase+2 (y = ybase - wave_height
         + 3).  One 1px cell per column following the triangle pattern
         0,1,2,1; indexing by the absolute column keeps the wave
         continuous across adjacent strings, like NS's a.x = x - (x % dx)
         phase anchoring.  */
      unsigned long uc = face->underline_defaulted_p
                         ? decoration_fg : face->underline_color;
      static const int wave[4] = {0, 1, 2, 1};
      int wy = s->ybase;
      for (int cx = s->x; cx < s->x + decoration_width; cx++)
        gfx_drv->fill_rect (s->f, cx, wy + wave[cx & 3], 1, 1, uc);
    }
  else if (face && face->underline >= FACE_UNDERLINE_SINGLE)
    {
      int position, thickness;
      gfx_underline_metrics (s, &position, &thickness);
      s->underline_thickness = thickness;
      s->underline_position  = position;
      unsigned long uc = face->underline_defaulted_p
                         ? decoration_fg : face->underline_color;
      if (face->underline == FACE_UNDERLINE_DOTS
          || face->underline == FACE_UNDERLINE_DASHES)
        {
          /* Port of ns_draw_dash: [SEGMENT on, SEGMENT off] anchored at
             the absolute x (phase = s->x in NS), so the pattern stays
             continuous across adjacent glyph strings.  Dots use a
             segment of THICKNESS, dashes 3*THICKNESS.  */
          int seg = (face->underline == FACE_UNDERLINE_DOTS
                     ? thickness : thickness * 3);
          int cycle = seg * 2;
          int x0 = s->x, x1 = s->x + decoration_width;
          int cx = x0 - (((x0 % cycle) + cycle) % cycle);
          for (; cx < x1; cx += cycle)
            {
              int from = max (cx, x0);
              int to = min (cx + seg, x1);
              if (to > from)
                gfx_drv->fill_rect (f, from, s->ybase + position,
                                    to - from, thickness, uc);
            }
        }
      else
        {
          gfx_drv->fill_rect (f, s->x, s->ybase + position,
                              decoration_width, thickness, uc);
          /* Second line above the first for double underline.  */
          if (face->underline == FACE_UNDERLINE_DOUBLE_LINE)
            {
              int p2 = position - thickness - 1;
              gfx_drv->fill_rect (f, s->x, s->ybase + p2,
                                  decoration_width, thickness, uc);
            }
        }
    }

  /* Overline: 1px at the top of the string (NS ignores overline_margin
     too).  */
  if (face && face->overline_p)
    {
      unsigned long oc = face->overline_color_defaulted_p
                         ? decoration_fg : face->overline_color;
      gfx_drv->fill_rect (f, s->x, s->y, decoration_width, 1, oc);
    }

  /* Strike-through: a 1px line centered on the first glyph's body, like
     NS.  Using s->y/s->height would mis-center it when the row is taller
     than this string (e.g. a bigger font elsewhere on the line).  */
  if (face && face->strike_through_p)
    {
      int glyph_y = s->ybase - s->first_glyph->ascent;
      int glyph_height = s->first_glyph->ascent + s->first_glyph->descent;
      int dy = lrint ((glyph_height - 1) / 2.0);
      unsigned long sc = face->strike_through_color_defaulted_p
                         ? decoration_fg : face->strike_through_color;
      gfx_drv->fill_rect (f, s->x, glyph_y + dy, decoration_width, 1, sc);
    }

  /* Face box / 3D relief (mode line, buttons, etc.).  Stretch glyphs
     were boxed before their decorations, matching the NS backend.  */
  if (!stretch_p && face && face->box != FACE_NO_BOX)
    gfx_draw_glyph_string_box (s);
}

/* The redisplay engine also draws OUTSIDE the update_begin/end cycle:
   mouse-face highlight (note_mouse_highlight -> show_mouse_face) and
   other immediate draws call draw_glyph_string directly, with no render
   cycle open.  The NS backend draws immediately via lockFocus; we open a
   self-contained cycle, draw, COMMIT to the render target, but DEFER the
   on-screen present.  Presenting on every immediate draw flickered (a
   mouse move runs clear_mouse_face + show_mouse_face = several draws,
   each flashing the intermediate state); leaving the cycle open across
   draws instead leaked state into the next click/redisplay.  Committing
   per draw keeps the pipeline clean, and deferring the present lets
   gfx_flush_display show the whole sequence in one composite.  */
void
gfx_draw_glyph_string (struct glyph_string *s)
{
  if (!gfx_ready (s->f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->draw_glyph_string)
        gfx_fallback.rif->draw_glyph_string (s);
      return;
    }

  if (gfx_drv->in_cycle (s->f))
    {
      gfx_state (s->f)->cycle_saw_draw = true;
      gfx_drv->clip_to_glyph_string (s);
      gfx_draw_glyph_string_impl (s);
      gfx_drv->clear_clip (s->f);
    }
  else
    {
      GFX_SEQ ("immediate glyph draw x=%d y=%d w=%d", s->x, s->y, s->width);
      gfx_begin_frame (s->f);
      gfx_drv->clip_to_glyph_string (s);
      gfx_draw_glyph_string_impl (s);
      gfx_drv->clear_clip (s->f);
      gfx_drv->end_frame (s->f, false);
    }
}

/* -----------------------------------------------------------------------
   Frame clearing.
   ----------------------------------------------------------------------- */

void
gfx_clear_frame (struct frame *f)
{
  if (!gfx_ready (f))
    {
      if (gfx_fallback.clear_frame)
        gfx_fallback.clear_frame (f);
      return;
    }

  /* clear_garbaged_frames calls this BEFORE update_begin (no cycle), e.g.
     when the minibuffer resizes back after a two-line message.  The
     redraw that follows assumes the frame is really clear and only paints
     rows with content, so silently dropping this fill left stale pixels
     behind (a leftover continuation arrow in the echo area's fringe).
     Run it as a committed immediate cycle with a deferred present, like
     gfx_draw_glyph_string.  */
  bool immediate = !gfx_drv->in_cycle (f);
  GFX_SEQ ("clear_frame (immediate=%d)", immediate);
  gfx_state (f)->cycle_saw_clear = true;
  if (immediate) gfx_begin_frame (f);

  gfx_drv->fill_rect (f, 0, 0, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f),
                      gfx_drv->frame_background (f));

  if (immediate)
    gfx_drv->end_frame (f, false);
}

void
gfx_clear_frame_area (struct frame *f, int x, int y, int width, int height)
{
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->clear_frame_area)
        gfx_fallback.rif->clear_frame_area (f, x, y, width, height);
      return;
    }
  gfx_drv->fill_rect (f, x, y, width, height,
                      gfx_drv->frame_background (f));
}

void
gfx_clear_under_internal_border (struct frame *f)
{
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->clear_under_internal_border)
        gfx_fallback.rif->clear_under_internal_border (f);
      return;
    }

  int border = FRAME_INTERNAL_BORDER_WIDTH (f);
  if (border <= 0 || !FRAME_LIVE_P (f)) return;

  /* Port of ns_clear_under_internal_border: the border is painted with
     the internal-border face background (child-frame-border for child
     frames), honoring face remapping, and skips the top margin rows
     (menu/tool/tab bars).  */
  int width = FRAME_PIXEL_WIDTH (f);
  int height = FRAME_PIXEL_HEIGHT (f);
  int margin = FRAME_TOP_MARGIN_HEIGHT (f);
  int bottom_margin = FRAME_BOTTOM_MARGIN_HEIGHT (f);
  int face_id =
    (FRAME_PARENT_FRAME (f)
     ? (!NILP (Vface_remapping_alist)
        ? lookup_basic_face (NULL, f, CHILD_FRAME_BORDER_FACE_ID)
        : CHILD_FRAME_BORDER_FACE_ID)
     : (!NILP (Vface_remapping_alist)
        ? lookup_basic_face (NULL, f, INTERNAL_BORDER_FACE_ID)
        : INTERNAL_BORDER_FACE_ID));
  struct face *face = FACE_FROM_ID_OR_NULL (f, face_id);
  if (!face)
    face = FACE_FROM_ID_OR_NULL (f, DEFAULT_FACE_ID);
  unsigned long bg = face ? face->background
                          : gfx_drv->frame_background (f);

  gfx_drv->fill_rect (f, 0, margin, width, border, bg);
  gfx_drv->fill_rect (f, 0, 0, border, height, bg);
  gfx_drv->fill_rect (f, width - border, 0, border, height, bg);
  gfx_drv->fill_rect (f, 0, height - bottom_margin - border,
                      width, border, bg);
}

/* -----------------------------------------------------------------------
   Render cycle hooks.
   ----------------------------------------------------------------------- */

void
gfx_flush_display (struct frame *f)
{
  /* Present the current cycle if one is in progress.  Do NOT start a new
     one here -- that is update_begin's responsibility (starting one here
     once left an orphaned encoder that never got closed).  */
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->flush_display)
        gfx_fallback.rif->flush_display (f);
      return;
    }
  GFX_SEQ ("flush_display (in_cycle=%d pending=%d)",
           (int) gfx_drv->in_cycle (f), (int) gfx_drv->pending_present (f));
  if (gfx_drv->in_cycle (f))
    gfx_drv->end_frame (f, true);
  else if (gfx_drv->pending_present (f))
    /* Present the deferred immediate draws (mouse-face highlight, etc.)
       that were committed to the render target without presenting.  */
    gfx_drv->present (f);
}

void
gfx_update_begin (struct frame *f)
{
  if (!gfx_ready (f))
    {
      if (gfx_fallback.update_begin)
        gfx_fallback.update_begin (f);
      return;
    }
  struct gfx_frame_state *st = gfx_state (f);

  /* Guard: if a cycle is already open (e.g. from a re-entrant redisplay),
     end it cleanly before starting a new one.  */
  if (gfx_drv->in_cycle (f))
    gfx_drv->end_frame (f, true);
  GFX_SEQ ("update_begin");
  st->cycle_saw_clear = false;
  st->cycle_saw_draw  = false;
  gfx_begin_frame (f);

  /* Expose substitute: when the minibuffer (echo area) changes height,
     the bottom of the layout shifts but the engine does not repaint every
     uncovered pixel -- it relies on an expose pass that NS gets via
     drawRect: and the gfx backend does not have.  (Seen as a stale
     wrap-arrow shard in the echo fringe after a multi-line message shrank
     back.)  Clear the affected bottom strip at the start of this same
     update; the update then redraws the real rows on top, all within one
     present, so nothing flashes.  */
  if (WINDOWP (FRAME_MINIBUF_WINDOW (f)))
    {
      struct window *mini = XWINDOW (FRAME_MINIBUF_WINDOW (f));
      int mh = WINDOW_PIXEL_HEIGHT (mini);
      if (st->last_mini_height > 0 && mh != st->last_mini_height)
        {
          int maxh = mh > st->last_mini_height ? mh : st->last_mini_height;
          int y0 = FRAME_PIXEL_HEIGHT (f) - maxh - FRAME_LINE_HEIGHT (f);
          if (y0 < 0) y0 = 0;
          gfx_drv->fill_rect (f, 0, y0, FRAME_PIXEL_WIDTH (f),
                              FRAME_PIXEL_HEIGHT (f) - y0,
                              gfx_drv->frame_background (f));
        }
      st->last_mini_height = mh;
    }
}

void
gfx_update_end (struct frame *f)
{
  if (!gfx_ready (f))
    {
      if (gfx_fallback.update_end)
        gfx_fallback.update_end (f);
      return;
    }
  struct gfx_frame_state *st = gfx_state (f);

  /* A cycle that only cleared the garbaged frame (no content drawn)
     commits to the render target but defers the present: presenting it
     would flash a blank frame for the tens of ms the follow-up cycle
     needs to realize faces/fonts and repaint (seen on the first switch
     to a new tab).  The deferred present is picked up by the next cycle
     or by flush_display.  */
  bool clear_only = st->cycle_saw_clear && !st->cycle_saw_draw;
  GFX_SEQ ("update_end%s", clear_only ? " (clear-only, present deferred)" : "");
  gfx_drv->end_frame (f, !clear_only);
}

void
gfx_frame_up_to_date (struct frame *f)
{
  /* Called when the frame display is fully up to date.  If a cycle was
     begun but not ended (unusual), end it now.  */
  if (!gfx_ready (f))
    {
      if (gfx_fallback.frame_up_to_date)
        gfx_fallback.frame_up_to_date (f);
      return;
    }
  if (gfx_drv->in_cycle (f))
    gfx_drv->end_frame (f, true);
}

/* -----------------------------------------------------------------------
   Scrolling.
   ----------------------------------------------------------------------- */

void
gfx_scroll_run (struct window *w, struct run *run)
{
  struct frame *f = WINDOW_XFRAME (w);
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->scroll_run_hook)
        gfx_fallback.rif->scroll_run_hook (w, run);
      return;
    }

  /* Move the already-rendered block of pixels inside the render target,
     the same geometry the NS backend uses (ns_scroll_run): the text area
     box of W including fringes, clamped so we never copy over the mode
     line.  */
  int x, y, width, height, from_y, to_y, bottom_y;
  window_box (w, ANY_AREA, &x, &y, &width, &height);
  from_y = WINDOW_TO_FRAME_PIXEL_Y (w, run->current_y);
  to_y   = WINDOW_TO_FRAME_PIXEL_Y (w, run->desired_y);
  bottom_y = y + height;

  if (to_y < from_y)
    height = (from_y + run->height > bottom_y) ? bottom_y - from_y : run->height;
  else
    height = (to_y + run->height > bottom_y) ? bottom_y - to_y : run->height;

  if (height <= 0) return;

  gfx_drv->copy_region (f, x, from_y, width, height, x, to_y);
}

void
gfx_shift_glyphs_for_insert (struct frame *f, int x, int y,
                             int w, int h, int by)
{
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->shift_glyphs_for_insert)
        gfx_fallback.rif->shift_glyphs_for_insert (f, x, y, w, h, by);
      return;
    }
  if (by == 0) return;
  gfx_drv->copy_region (f, x, y, w, h, x + by, y);
}

void
gfx_after_update_window_line (struct window *w, struct glyph_row *desired_row)
{
  struct frame *f = WINDOW_XFRAME (w);
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->after_update_window_line_hook)
        gfx_fallback.rif->after_update_window_line_hook (w, desired_row);
      return;
    }

  /* Arm fringe drawing for this row.  This flag is what makes
     draw_window_fringes call draw_fringe_bitmap later; without it the
     fringe bitmaps (buffer-boundary angles, empty-line marks, truncation
     and continuation arrows) are never drawn.  Both x_after_update_window_line
     and ns_after_update_window_line do exactly this.  */
  if (!desired_row->mode_line_p && !w->pseudo_window_p)
    desired_row->redraw_fringe_bitmaps_p = 1;

  /* When a window has disappeared, repaint the internal-border strips at
     this row so no rest of a full-width row stays visible there.  Mirrors
     the same block in the X and NS backends, drawn through the driver.  */
  int width, height;
  if (windows_or_buffers_changed
      && desired_row->full_width_p
      && (width = FRAME_INTERNAL_BORDER_WIDTH (f), width != 0)
      && (height = desired_row->visible_height, height > 0))
    {
      int y = WINDOW_TO_FRAME_PIXEL_Y (w, max (0, desired_row->y));
      int face_id =
        (FRAME_PARENT_FRAME (f)
         ? (!NILP (Vface_remapping_alist)
            ? lookup_basic_face (NULL, f, CHILD_FRAME_BORDER_FACE_ID)
            : CHILD_FRAME_BORDER_FACE_ID)
         : (!NILP (Vface_remapping_alist)
            ? lookup_basic_face (NULL, f, INTERNAL_BORDER_FACE_ID)
            : INTERNAL_BORDER_FACE_ID));
      struct face *face = FACE_FROM_ID_OR_NULL (f, face_id);
      unsigned long bg = face ? face->background
                              : gfx_drv->frame_background (f);
      gfx_drv->fill_rect (f, 0, y, width, height, bg);
      gfx_drv->fill_rect (f, FRAME_PIXEL_WIDTH (f) - width, y,
                          width, height, bg);
    }
}

/* -----------------------------------------------------------------------
   Cursor.
   ----------------------------------------------------------------------- */

void
gfx_draw_window_cursor (struct window *w,
                        struct glyph_row *row, int x, int y,
                        enum text_cursor_kinds cursor_type,
                        int cursor_width, bool on_p, bool active_p)
{
  (void) x; (void) y; (void) active_p;

  struct frame *f = WINDOW_XFRAME (w);
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->draw_window_cursor)
        gfx_fallback.rif->draw_window_cursor (w, row, x, y, cursor_type,
                                              cursor_width, on_p, active_p);
      return;
    }
  if (!on_p)
    {
      /* Blink-off phase: hide the animated overlay too, or a GPU cursor
         would never blink (the overlay persists across presents).  */
      if (gfx_drv->note_cursor)
        gfx_drv->note_cursor (f, 0, 0, 0, 0, 0);
      return;
    }

  w->phys_cursor_type = cursor_type;
  w->phys_cursor_on_p = on_p;

  if (cursor_type == NO_CURSOR)
    {
      w->phys_cursor_width = 0;
      return;
    }

  /* Resolve the glyph and geometry exactly like the NS backend so the
     cursor box lines up with the character cell.  See
     ns_draw_window_cursor.  */
  struct glyph *phys_cursor_glyph = get_phys_cursor_glyph (w);
  if (phys_cursor_glyph == NULL)
    {
      if (row->exact_window_width_line_p
          && w->phys_cursor.hpos >= row->used[TEXT_AREA])
        {
          row->cursor_in_fringe_p = 1;
          draw_fringe_bitmap (w, row, 0);
        }
      return;
    }

  int fx, fy, h, cursor_height;
  get_phys_cursor_geometry (w, row, phys_cursor_glyph, &fx, &fy, &h);

  if (cursor_type == BAR_CURSOR)
    {
      struct glyph *cursor_glyph;
      if (cursor_width < 1)
        cursor_width = max (FRAME_CURSOR_WIDTH (f), 1);
      if (cursor_width < w->phys_cursor_width)
        w->phys_cursor_width = cursor_width;
      /* For R2L glyphs draw the bar on the right edge.  */
      cursor_glyph = get_phys_cursor_glyph (w);
      if ((cursor_glyph->resolved_level & 1) != 0)
        fx += cursor_glyph->pixel_width - w->phys_cursor_width;
    }
  else if (cursor_type == HBAR_CURSOR)
    {
      cursor_height = (cursor_width < 1) ? lrint (0.25 * h) : cursor_width;
      if (cursor_height > row->height)
        cursor_height = row->height;
      if (h > cursor_height)
        fy += h - cursor_height;
      h = cursor_height;
    }

  unsigned long cc = gfx_drv->cursor_color (f);
  int cwidth = w->phys_cursor_width;

  /* Let the driver know where the cursor landed (cursor animations).
     When it reports that an animated overlay will draw the cursor, skip
     the static one here to avoid a double cursor.  */
  bool animated = gfx_drv->note_cursor
                  && gfx_drv->note_cursor (f, fx, fy, cwidth, h, cc);

  if (!animated)
    switch (cursor_type)
      {
      case DEFAULT_CURSOR:
      case NO_CURSOR:
        break;
      case FILLED_BOX_CURSOR:
        /* Re-draw the glyph with DRAW_CURSOR highlight: fills the cell
           with the cursor color and draws the character in the
           background color, keeping it readable (gfx_draw_glyph_string
           handles DRAW_CURSOR).  */
        draw_phys_cursor_glyph (w, row, DRAW_CURSOR);
        break;
      case HOLLOW_BOX_CURSOR:
        /* Outline only: four 1px edges.  */
        gfx_drv->fill_rect (f, fx, fy, cwidth, 1, cc);
        gfx_drv->fill_rect (f, fx, fy + h - 1, cwidth, 1, cc);
        gfx_drv->fill_rect (f, fx, fy, 1, h, cc);
        gfx_drv->fill_rect (f, fx + cwidth - 1, fy, 1, h, cc);
        break;
      case HBAR_CURSOR:
      case BAR_CURSOR:
        gfx_drv->fill_rect (f, fx, fy, cwidth, h, cc);
        break;
      }
}

/* -----------------------------------------------------------------------
   Window borders, dividers, fringes.
   ----------------------------------------------------------------------- */

void
gfx_draw_vertical_window_border (struct window *w, int x, int y0, int y1)
{
  struct frame *f = WINDOW_XFRAME (w);
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->draw_vertical_window_border)
        gfx_fallback.rif->draw_vertical_window_border (w, x, y0, y1);
      return;
    }
  bool immediate = !gfx_drv->in_cycle (f);
  if (immediate) gfx_begin_frame (f);
  struct face *face = FACE_FROM_ID_OR_NULL (f, VERTICAL_BORDER_FACE_ID);
  unsigned long color = face ? face->foreground
                             : gfx_drv->frame_foreground (f);
  gfx_drv->fill_rect (f, x, y0, 1, y1 - y0, color);
  if (immediate)
    gfx_drv->end_frame (f, false);
}

void
gfx_draw_window_divider (struct window *w, int x0, int x1, int y0, int y1)
{
  struct frame *f = WINDOW_XFRAME (w);
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->draw_window_divider)
        gfx_fallback.rif->draw_window_divider (w, x0, x1, y0, y1);
      return;
    }

  /* Bottom dividers are drawn outside the update cycle (the vertical
     ones come in-cycle); open a self-contained one or the fill is
     silently dropped.  */
  bool immediate = !gfx_drv->in_cycle (f);
  if (immediate) gfx_begin_frame (f);

  struct face *face = FACE_FROM_ID_OR_NULL (f, WINDOW_DIVIDER_FACE_ID);
  struct face *face_first
    = FACE_FROM_ID_OR_NULL (f, WINDOW_DIVIDER_FIRST_PIXEL_FACE_ID);
  struct face *face_last
    = FACE_FROM_ID_OR_NULL (f, WINDOW_DIVIDER_LAST_PIXEL_FACE_ID);
  unsigned long fg = gfx_drv->frame_foreground (f);
  unsigned long color       = face ? face->foreground : fg;
  unsigned long color_first = face_first ? face_first->foreground : fg;
  unsigned long color_last  = face_last ? face_last->foreground : fg;

  if ((y1 - y0 > x1 - x0) && (x1 - x0 >= 3))
    {
      /* Vertical divider >= 3px wide: distinct first/last columns.  */
      gfx_drv->fill_rect (f, x0, y0, 1, y1 - y0, color_first);
      gfx_drv->fill_rect (f, x0 + 1, y0, x1 - x0 - 2, y1 - y0, color);
      gfx_drv->fill_rect (f, x1 - 1, y0, 1, y1 - y0, color_last);
    }
  else if ((x1 - x0 > y1 - y0) && (y1 - y0 >= 3))
    {
      /* Horizontal divider >= 3px high: distinct first/last rows.  */
      gfx_drv->fill_rect (f, x0, y0, x1 - x0, 1, color_first);
      gfx_drv->fill_rect (f, x0, y0 + 1, x1 - x0, y1 - y0 - 2, color);
      gfx_drv->fill_rect (f, x0, y1 - 1, x1 - x0, 1, color_last);
    }
  else
    gfx_drv->fill_rect (f, x0, y0, x1 - x0, y1 - y0, color);

  if (immediate)
    gfx_drv->end_frame (f, false);
}

void
gfx_draw_fringe_bitmap (struct window *w, struct glyph_row *row,
                        struct draw_fringe_bitmap_params *p)
{
  struct frame *f = WINDOW_XFRAME (w);
  if (!gfx_ready (f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->draw_fringe_bitmap)
        gfx_fallback.rif->draw_fringe_bitmap (w, row, p);
      return;
    }

  /* Like gfx_draw_glyph_string: fringe updates can arrive outside the
     update_begin/end cycle (e.g. clearing the continuation arrow when
     the echo area shrinks back to one line).  Dropping them left stale
     bitmaps behind; wrap the draw in its own committed cycle with a
     deferred present.  */
  bool immediate = !gfx_drv->in_cycle (f);
  if (immediate) gfx_begin_frame (f);

  struct face *face = p->face;
  unsigned long bg = face ? face->background
                          : gfx_drv->frame_background (f);

  /* Clip every fringe draw to the row's visible band, like the GC clip
     x_draw_fringe_bitmap sets via x_clip_to_row (and the NS focus rect).
     The empty-line indicator is defined 72px tall with a 3px period, so
     a single call asks to draw the full 72px; without this clip the
     bitmap spills past the row bottom -- harmless mid-buffer (the next
     row repaints over it) but at the last row it bleeds over the mode
     line and overwrites the bottom buffer-boundary marker.  */
  int cy0 = p->by;
  int cy1 = p->by + p->ny;

  /* Clear the fringe background (and the wider bx area) unless this is
     an overlay bitmap.  Mirrors ns_draw_fringe_bitmap.  */
  if (!p->overlay_p)
    {
      if (p->bx >= 0)
        gfx_drv->fill_rect (f, p->bx, p->by, p->nx, p->ny, bg);
      int fy0 = max (p->y, cy0), fy1 = min (p->y + p->h, cy1);
      if (fy1 > fy0)
        gfx_drv->fill_rect (f, p->x, fy0, p->wd, fy1 - fy0, bg);
    }

  if (p->bits && p->wd > 0 && p->h > 0)
    {
      unsigned long color;
      if (!p->cursor_p)
        color = face ? face->foreground : gfx_drv->frame_foreground (f);
      else if (p->overlay_p)
        color = bg;
      else
        color = gfx_drv->cursor_color (f);

      /* The params carry the CLIPPED display width; the bits stay
         MSB-aligned within the bitmap's own width.  Fetch it so a
         fringe narrower than the bitmap shows its left-aligned part
         (the native backends draw the full bitmap and clip).  */
      int fbw = fringe_bitmap_width (p->which);
      int bw = fbw >= p->wd ? fbw : p->wd;

      /* Clip the bitmap rows to the visible band, shifting the source
         offset (dh) and height together so the periodic phase stays
         aligned.  */
      int top = max (p->y, cy0), bot = min (p->y + p->h, cy1);
      int dh = p->dh + (top - p->y);
      int h  = bot - top;
      if (h > 0)
        gfx_drv->draw_bitmap (f, p->bits, dh, bw, p->wd, h, p->x, top,
                              color);
    }

  if (immediate)
    gfx_drv->end_frame (f, false);
}

void
gfx_define_fringe_bitmap (int which, unsigned short *bits, int h, int wd)
{
  /* Bitmap definitions are GLOBAL: keep the platform backend's registry
     alive for the frames that still render through it.  (The gfx policy
     itself reads the bits and true width via get_fringe_bitmap_data.)  */
  if (gfx_fallback.rif && gfx_fallback.rif->define_fringe_bitmap)
    gfx_fallback.rif->define_fringe_bitmap (which, bits, h, wd);
}

void
gfx_destroy_fringe_bitmap (int which)
{
  if (gfx_fallback.rif && gfx_fallback.rif->destroy_fringe_bitmap)
    gfx_fallback.rif->destroy_fringe_bitmap (which);
}

void
gfx_compute_glyph_string_overhangs (struct glyph_string *s)
{
  if (!gfx_ready (s->f))
    {
      if (gfx_fallback.rif && gfx_fallback.rif->compute_glyph_string_overhangs)
        gfx_fallback.rif->compute_glyph_string_overhangs (s);
      return;
    }
  s->left_overhang = s->right_overhang = 0;
}

void
gfx_warm_glyph_cache (struct frame *f)
{
  if (!gfx_ready (f) || !gfx_drv->warm_glyph_cache) return;
  gfx_drv->warm_glyph_cache (f);
}

#endif /* HAVE_MTL || HAVE_GFX_GL */
