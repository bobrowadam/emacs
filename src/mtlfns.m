/* Lisp interface to the Metal GPU display backend.
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
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */


#include <config.h>

#ifdef HAVE_MTL

#include <float.h>
#include <math.h>

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>

#include "lisp.h"
#include "frame.h"
#include "window.h"
#include "buffer.h"
#include "dispextern.h"
#include "keyboard.h"
#include "blockinput.h"
#include "termhooks.h"
#include "fontset.h"
#include "font.h"
#include "character.h"
#include "coding.h"
#include "macfont.h"

#include "mtlterm.h"

/* Forward declaration for syms */
void syms_of_mtlfns (void);

/* -----------------------------------------------------------------------
   DEFUN: mtl-open-connection — initialize Metal terminal
   ----------------------------------------------------------------------- */

DEFUN ("gpu-open-connection", Fmtl_open_connection, Smtl_open_connection,
       3, 3, 0,
       doc: /* Initialize the Metal GPU backend.
DISPLAY, XRM-STRING and MUST-SUCCEED are ignored.  */)
  (Lisp_Object display, Lisp_Object xrm_string, Lisp_Object must_succeed)
{
  (void)xrm_string; (void)must_succeed;
  if (mtl_display_list) return Qt;
  block_input ();
  mtl_term_init (display);
  unblock_input ();
  return Qt;
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-backend-p — detect Metal GPU support
   ----------------------------------------------------------------------- */

DEFUN ("gpu-backend-p", Fmtl_backend_p, Smtl_backend_p, 0, 0, 0,
       doc: /* Return t if Metal GPU backend is available on this system.  */)
  (void)
{
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice ();
  return dev ? Qt : Qnil;
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-device-name
   ----------------------------------------------------------------------- */

DEFUN ("gpu-device-name", Fmtl_device_name, Smtl_device_name, 0, 0, 0,
       doc: /* Return the Metal GPU device name as a string.  */)
  (void)
{
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice ();
  if (!dev) return Qnil;
  return build_string ([[dev name] UTF8String]);
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-enable-for-frame — add Metal rendering to an existing NS frame.

   This is the core Phase 2 function.  It takes a live Emacs frame (created
   normally via `make-frame'), adds a CAMetalLayer as a sublayer on top of
   the EmacsView, and registers Metal hooks so subsequent redisplay cycles
   render via Metal instead of CoreGraphics.

   Usage: (mtl-enable-for-frame (selected-frame))
          (mtl-enable-for-frame (make-frame))
   ----------------------------------------------------------------------- */

DEFUN ("gpu-enable-for-frame", Fmtl_enable_for_frame, Smtl_enable_for_frame,
       1, 1, 0,
       doc: /* Add Metal GPU rendering to an existing Emacs frame FRAME.
Adds a CAMetalLayer sublayer on top of the NS EmacsView and registers
Metal hooks so redisplay uses the GPU.  Returns t on success.
FRAME must be a live graphical NS frame.  */)
  (Lisp_Object frame)
{
  CHECK_LIVE_FRAME (frame);
  struct frame *f = XFRAME (frame);

  if (!FRAME_NS_P (f))
    error ("gpu-enable-for-frame: FRAME must be an NS (macOS) frame");

  block_input ();
  MtlFrameData *fd = mtl_setup_frame (f);
  unblock_input ();

  if (!fd)
    error ("gpu-enable-for-frame: failed to set up Metal layer (Metal not available?)");

  /* Images are shared by frames on the same display.  Move this frame to a
     GPU-specific cache before reloading SVGs with GPU transparency.  */
  image_cache_for_gpu_frame (f);
  clear_image_cache (f, Qt);

  /* Replace the terminal's redisplay_interface (rif) with our Metal rif.
     This redirects all rendering calls (draw_glyph_string, draw_window_cursor,
     etc.) from NS CoreGraphics to our Metal pipeline.
     The NS terminal still handles events, menus, and scrollbars. */
  mtl_patch_terminal_rif (f);

  /* Warm the glyph atlas with printable ASCII for the default face so the
     first big redraw (e.g. first tab switch) doesn't rasterize everything at
     once, which showed as a visible blink. */
  mtl_warm_glyph_cache (f);

  /* Begin Metal rendering for this frame */
  [fd beginFrame];
  [fd endFrame];

  /* Trigger full redisplay so the new rif is used immediately */
  SET_FRAME_GARBAGED (f);

  return Qt;
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-open-test-window — standalone GPU test (no Emacs frame)
   ----------------------------------------------------------------------- */

DEFUN ("gpu-open-test-window", Fmtl_open_test_window, Smtl_open_test_window,
       0, 0, 0,
       doc: /* Open a standalone Metal GPU test window.
Creates a bare NSWindow with a CAMetalLayer, renders text, and displays it.
Returns t on success, nil if Metal is not available.  */)
  (void)
{
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice ();
  if (!dev) return Qnil;

  NSRect rect = NSMakeRect (200, 200, 800, 600);
  MtlWindow *win = [[MtlWindow alloc]
    initWithContentRect:rect
              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                         NSWindowStyleMaskResizable)
                backing:NSBackingStoreBuffered defer:NO];
  win->emacsframe = NULL;
  win.title = @"GNU Emacs — Metal GPU Test";
  win.backgroundColor = [NSColor colorWithRed:0x2E/255.0
                                        green:0x34/255.0
                                         blue:0x40/255.0 alpha:1.0];

  MtlView *view = [[MtlView alloc] initWithFrame:rect emacsFrame:NULL];
  if (!view.metalLayer) return Qnil;

  [win setContentView:view];
  [win makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];

  /* Render a test frame with text */
  [view beginFrame];
  if (view.frameEncoder)
    {
      /* Header bar */
      [view fillRect:NSMakeRect(0, 0, 800, 28) withColor:0x3B4252];

      /* Render "GNU Emacs — Metal" using Menlo 14pt */
      CTFontRef font = CTFontCreateWithName (CFSTR("Menlo"), 14.0, NULL);
      if (font)
        {
          [view drawText:@"GNU Emacs -- Metal GPU Backend (Phase 2)"
                      at:NSMakePoint(16, 48)
                  ctfont:font color:0xECEFF4];
          [view drawText:@"(mtl-enable-for-frame (selected-frame))"
                      at:NSMakePoint(16, 72)
                  ctfont:font color:0x88C0D0];
          [view drawText:@"GPU: Apple Metal | Atlas: 2048x2048 R8Unorm"
                      at:NSMakePoint(16, 96)
                  ctfont:font color:0xA3BE8C];
          [view drawText:@"CoreText -> R8Unorm -> MTLTexture -> textured quads"
                      at:NSMakePoint(16, 120)
                  ctfont:font color:0x81A1C1];
          CFRelease (font);
        }
    }
  [view endFrameAndPresent];

  return Qt;
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-render-to-png — GPU off-screen render to PNG file
   ----------------------------------------------------------------------- */

DEFUN ("gpu-render-to-png", Fmtl_render_to_png, Smtl_render_to_png, 1, 1, 0,
       doc: /* Render a Metal GPU frame off-screen and save it as PNG at PATH.
Rasterizes text via CoreText into the Metal glyph atlas and renders textured
quads to an off-screen MTLTexture.  Returns t on success.  */)
  (Lisp_Object path)
{
  CHECK_STRING (path);
  return mtl_render_text_png (SSDATA (path)) ? Qt : Qnil;
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-capture-frame — save the current Metal staticTexture to PNG.
   Used for visual regression testing and debugging rendering issues.
   ----------------------------------------------------------------------- */

DEFUN ("gpu-capture-frame", Fmtl_capture_frame, Smtl_capture_frame, 1, 3, 0,
       doc: /* Save the Metal staticTexture for FRAME (or selected frame) to PATH.
Returns t on success.  The PNG shows exactly what Metal has rendered into
the intermediate texture, before cursor/animation overlay.
With COMPOSITE non-nil, capture the full compositor, including decorations,
using the same Metal rendering code on an offscreen texture.  */)
  (Lisp_Object path, Lisp_Object frame, Lisp_Object composite)
{
  CHECK_STRING (path);
  struct frame *f = NILP (frame) ? XFRAME (selected_frame) : XFRAME (frame);
  if (!f) return Qnil;

  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.staticTexture) return Qnil;

  id<MTLTexture> src = fd.staticTexture;
  NSUInteger W = src.width, H = src.height;

  id<MTLDevice> dev = mtl_get_device();
  id<MTLCommandQueue> q = mtl_get_queue();
  if (!dev || !q) return Qnil;

  /* Blit from Private texture to Shared texture for CPU readback */
  MTLTextureDescriptor *td =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                       width:W height:H mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  td.storageMode = MTLStorageModeShared;
  id<MTLTexture> readback = [dev newTextureWithDescriptor:td];
  if (!readback) return Qnil;

  id<MTLCommandBuffer> cmd = [q commandBuffer];
  if (!NILP (composite))
    {
      if (fd.encoder) return Qnil;
      [fd encodeCompositeTextureOn:cmd texture:readback];
    }
  else
    {
      id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
      [blit copyFromTexture:src
                sourceSlice:0 sourceLevel:0
               sourceOrigin:MTLOriginMake(0,0,0)
                 sourceSize:MTLSizeMake(W,H,1)
                  toTexture:readback
         destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(0,0,0)];
      [blit endEncoding];
    }
  [cmd commit];
  [cmd waitUntilCompleted];

  /* Read pixels (BGRA) and swap to RGBA for PNG */
  NSUInteger bpr = W * 4;
  uint8_t *px = malloc (bpr * H);
  if (!px) return Qnil;
  [readback getBytes:px bytesPerRow:bpr
          fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];

  /* BGRA → RGBA */
  for (NSUInteger i = 0; i < W * H; i++)
    { uint8_t b=px[i*4]; px[i*4]=px[i*4+2]; px[i*4+2]=b; }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(px, W, H, 8, bpr, cs,
    (CGBitmapInfo)(kCGImageAlphaPremultipliedLast));
  CGColorSpaceRelease(cs);
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  NSString *nspath = [NSString stringWithUTF8String:SSDATA(path)];
  NSURL *url = [NSURL fileURLWithPath:nspath];
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
    (__bridge CFURLRef)url, kUTTypePNG, 1, NULL);
  CGImageDestinationAddImage(dst, img, NULL);
  bool ok = CGImageDestinationFinalize(dst);
  CFRelease(dst); CGImageRelease(img); free(px);

  return ok ? Qt : Qnil;
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-create-frame (stub — use mtl-enable-for-frame instead)
   ----------------------------------------------------------------------- */

DEFUN ("gpu-create-frame", Fmtl_create_frame, Smtl_create_frame, 1, 1, 0,
       doc: /* Create a new frame and enable Metal GPU rendering for it.
PARAMETERS is an alist of frame parameters, same as `make-frame'.
Returns the new frame with Metal rendering enabled.  */)
  (Lisp_Object parameters)
{
  /* Create a normal NS frame through the standard path */
  Lisp_Object frame = CALLN (Ffuncall, intern ("make-frame"), parameters);
  if (NILP (frame)) return Qnil;

  /* Enable Metal rendering on it */
  Fmtl_enable_for_frame (frame);
  return frame;
}

/* -----------------------------------------------------------------------
   Phase 4: Animation configuration Lisp functions
   ----------------------------------------------------------------------- */

DEFUN ("gpu-cursor-mode", Fmtl_cursor_mode, Smtl_cursor_mode, 1, 1, 0,
       doc: /* Set the Metal cursor animation mode.
MODE is an integer 0-7:
  0 = block (static filled rectangle)
  1 = spring (critically-damped spring, default)
  2 = torpedo (trail of past positions)
  3 = sonicboom (expanding ring on jump)
  4 = ripple (3 concentric expanding rings)
  5 = pixiedust (radial particle burst)
  6 = hollow (outline box)
  7 = beam (thin vertical bar)  */)
  (Lisp_Object mode)
{
  CHECK_FIXNAT (mode);
  NSUInteger m = (NSUInteger)XFIXNAT (mode);
  if (m > 7) error ("mtl-cursor-mode: mode must be 0-7");
  g_mtl_cursor_mode = (MtlCursorMode)m;

  /* Propagate to live animators: each MtlAnimator caches cursorMode at init,
     so without this a running frame keeps its old mode (e.g. the default
     spring) and the change only takes effect on the next (mtl-enable). */
  Lisp_Object tail, frame;
  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);
      if (!FRAME_LIVE_P (f) || !FRAME_NS_P (f))
        continue;
      MtlFrameData *fd = mtl_get_frame_data (f);
      if (fd && fd.animator)
        {
          fd.animator.cursorMode = g_mtl_cursor_mode;
          fd.animator.trailCount = 0;   /* drop any stale trail from old mode */
        }
    }
  return mode;
}

DEFUN ("gpu-scroll-effect", Fmtl_scroll_effect, Smtl_scroll_effect, 1, 1, 0,
       doc: /* Set the Metal scroll animation easing.
EFFECT is an integer 0-5:
  0 = none (instant)
  1 = linear
  2 = ease-out-quad (default)
  3 = ease-out-cubic
  4 = spring
  5 = ease-in-out-cubic  */)
  (Lisp_Object effect)
{
  CHECK_FIXNAT (effect);
  NSUInteger e = (NSUInteger)XFIXNAT (effect);
  if (e > 5) error ("mtl-scroll-effect: effect must be 0-5");
  g_mtl_scroll_easing = (MtlScrollEasing)e;

  /* Propagate to live animators (they cache scrollEasing at init). */
  Lisp_Object tail, frame;
  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);
      if (!FRAME_LIVE_P (f) || !FRAME_NS_P (f))
        continue;
      MtlFrameData *fd = mtl_get_frame_data (f);
      if (fd && fd.animator)
        fd.animator.scrollEasing = g_mtl_scroll_easing;
    }
  return effect;
}

DEFUN ("gpu-scroll-duration", Fmtl_scroll_duration, Smtl_scroll_duration,
       1, 1, 0,
       doc: /* Set scroll animation duration in seconds (default 0.15).  */)
  (Lisp_Object secs)
{
  CHECK_NUMBER (secs);
  double d = XFLOATINT (secs);
  if (d < 0.0 || d > 2.0) error ("mtl-scroll-duration: must be 0.0-2.0");
  g_mtl_scroll_duration = (float)d;
  return secs;
}

DEFUN ("gpu-trail-length", Fmtl_trail_length, Smtl_trail_length, 1, 1, 0,
       doc: /* Set torpedo cursor trail length (1-40, default 20).  */)
  (Lisp_Object len)
{
  CHECK_FIXNAT (len);
  NSUInteger l = (NSUInteger)XFIXNAT (len);
  if (l < 1 || l > MTL_TRAIL_LEN)
    error ("mtl-trail-length: must be 1-%d", MTL_TRAIL_LEN);
  g_mtl_trail_len = l;
  return len;
}

DEFUN ("gpu-cursor-suppress-effects", Fmtl_cursor_suppress_effects,
       Smtl_cursor_suppress_effects, 1, 1, 0,
       doc: /* Suppress motion cursor effects for the next redisplay when SUPPRESS.
When SUPPRESS is non-nil, the burst effects (sonicboom, ripple, pixiedust)
and the torpedo trail are not triggered by the next cursor placement.  This
lets Lisp distinguish typing from cursor movement: bind it from
`pre-command-hook' so that editing commands do not fire the effects while
movement commands still do.  */)
  (Lisp_Object suppress)
{
  g_mtl_cursor_suppress_effects = !NILP (suppress);
  return suppress;
}

DEFUN ("gpu-animations", Fmtl_animations, Smtl_animations, 0, 1, 0,
       doc: /* Enable or disable the Metal GPU animation layer.
With ENABLE non-nil, turn on the animated cursor effects, particles and the
CADisplayLink 60fps compositor overlay.  With ENABLE nil (the default state),
the cursor is drawn directly into the static texture like the NS backend and
no overlay is composited, which is the correct, flicker-free baseline.
Returns t when animations are enabled, nil otherwise.  */)
  (Lisp_Object enable)
{
  g_mtl_animations_enabled = !NILP (enable);

  /* Start or stop the per-frame animators on live Metal frames so the change
     takes effect immediately rather than only on the next (mtl-enable). */
  Lisp_Object tail, frame;
  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);
      if (!FRAME_LIVE_P (f) || !FRAME_NS_P (f))
        continue;
      MtlFrameData *fd = mtl_get_frame_data (f);
      if (!fd || !fd.animator)
        continue;
      if (g_mtl_animations_enabled)
        [fd.animator startAnimating];
      else
        [fd.animator stopAnimating];
    }

  return g_mtl_animations_enabled ? Qt : Qnil;
}

DEFUN ("gpu-draw-stats", Fmtl_draw_stats, Smtl_draw_stats, 0, 0, 0,
       doc: /* Return diagnostic counters for Metal glyph rendering.
Returns an alist with: total-calls, no-fd (no encoder), no-font, glyphs-drawn.  */)
  (void)
{
  return list4 (
    Fcons (intern ("total-calls"),   make_fixnum (mtl_dgs_call_count)),
    Fcons (intern ("no-fd"),         make_fixnum (mtl_dgs_nofd_count)),
    Fcons (intern ("no-font"),       make_fixnum (mtl_dgs_nofont_count)),
    Fcons (intern ("glyphs-drawn"),  make_fixnum (mtl_dgs_drawn_count)));
}

DEFUN ("gpu-animation-status", Fmtl_animation_status, Smtl_animation_status,
       0, 0, 0,
       doc: /* Return an alist with current Metal animation configuration.  */)
  (void)
{
  return list5 (
    Fcons (intern ("animations"),     g_mtl_animations_enabled ? Qt : Qnil),
    Fcons (intern ("cursor-mode"),    make_fixnum ((EMACS_INT)g_mtl_cursor_mode)),
    Fcons (intern ("scroll-easing"),  make_fixnum ((EMACS_INT)g_mtl_scroll_easing)),
    Fcons (intern ("scroll-duration"),make_float (g_mtl_scroll_duration)),
    Fcons (intern ("trail-length"),   make_fixnum ((EMACS_INT)g_mtl_trail_len)));
}

/* -----------------------------------------------------------------------
   Initialization
   ----------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   Inline video
   --------------------------------------------------------------------------- */

DEFUN ("gpu-video-open", Fmtl_video_open, Smtl_video_open, 5, 7, 0,
       doc: /* Play video FILE over FRAME at X, Y sized WIDTH x HEIGHT pixels.
X and Y are frame-relative logical pixels (top-left origin).  The video
is decoded by AVFoundation straight into Metal textures and composited
over the frame content every present; redisplay underneath continues
normally.  If LOOP is non-nil, restart playback at the end.
FRAME defaults to the selected frame.  One video per frame: opening a
new one replaces the previous.  Returns t on success.  */)
  (Lisp_Object file, Lisp_Object x, Lisp_Object y, Lisp_Object width,
   Lisp_Object height, Lisp_Object loop, Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  CHECK_LIVE_FRAME (frame);
  struct frame *f = XFRAME (frame);
  CHECK_STRING (file);
  CHECK_FIXNUM (x); CHECK_FIXNUM (y);
  CHECK_FIXNUM (width); CHECK_FIXNUM (height);

  const char *raw = SSDATA (file);
  bool is_url = (strncmp (raw, "https://", 8) == 0
                 || strncmp (raw, "http://", 7) == 0);
  const char *path = is_url ? raw
                             : SSDATA (ENCODE_FILE (Fexpand_file_name (file, Qnil)));
  bool ok;
  block_input ();
  ok = mtl_video_open (f, path,
                       XFIXNUM (x), XFIXNUM (y),
                       XFIXNUM (width), XFIXNUM (height),
                       !NILP (loop));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-close", Fmtl_video_close, Smtl_video_close, 0, 1, 0,
       doc: /* Stop and remove the inline video on FRAME.
FRAME defaults to the selected frame.  Returns t if a video was open.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  CHECK_LIVE_FRAME (frame);
  bool ok;
  block_input ();
  ok = mtl_video_close (XFRAME (frame));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-pause", Fmtl_video_pause, Smtl_video_pause, 1, 2, 0,
       doc: /* Pause (PAUSED non-nil) or resume the inline video on FRAME.
FRAME defaults to the selected frame.  Returns t if a video is open.  */)
  (Lisp_Object paused, Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  CHECK_LIVE_FRAME (frame);
  bool ok;
  block_input ();
  ok = mtl_video_set_paused (XFRAME (frame), !NILP (paused));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-move", Fmtl_video_move, Smtl_video_move, 4, 6, 0,
       doc: /* Move/resize the inline video on FRAME to X, Y, WIDTH, HEIGHT.
Frame-relative logical pixels.  Optional CLIP is a list (LEFT TOP RIGHT
BOTTOM), also frame-relative, that confines the video to a window's
interior; nil removes clipping.  FRAME defaults to the selected frame.
Returns t if a video is open.  */)
  (Lisp_Object x, Lisp_Object y, Lisp_Object width, Lisp_Object height,
   Lisp_Object clip, Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  CHECK_LIVE_FRAME (frame);
  CHECK_FIXNUM (x); CHECK_FIXNUM (y);
  CHECK_FIXNUM (width); CHECK_FIXNUM (height);
  bool ok;
  block_input ();
  ok = mtl_video_set_rect (XFRAME (frame), XFIXNUM (x), XFIXNUM (y),
                           XFIXNUM (width), XFIXNUM (height));
  if (ok)
    {
      if (CONSP (clip))
        {
          int cl = XFIXNUM (Fnth (make_fixnum (0), clip));
          int ct = XFIXNUM (Fnth (make_fixnum (1), clip));
          int cr = XFIXNUM (Fnth (make_fixnum (2), clip));
          int cb = XFIXNUM (Fnth (make_fixnum (3), clip));
          mtl_video_set_clip (XFRAME (frame), cl, ct, cr - cl, cb - ct);
        }
      else
        mtl_video_set_clip (XFRAME (frame), 0, 0, 0, 0);
    }
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-tick", Fmtl_video_tick, Smtl_video_tick, 0, 1, 0,
       doc: /* Present a fresh frame of the inline video on FRAME.
Driven by a Lisp timer in mtl.el (Emacs's event loop starves the
CADisplayLink while idle).  Returns t while a video is open, nil
otherwise (letting the timer cancel itself).  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  bool ok;
  block_input ();
  ok = mtl_video_tick (XFRAME (frame));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-duration", Fmtl_video_duration, Smtl_video_duration, 0, 1, 0,
       doc: /* Return the inline video duration on FRAME in seconds.
FRAME defaults to the selected frame.  Returns nil if there is no video
or its duration is not known yet (the item is still loading).  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  double d;
  block_input ();
  d = mtl_video_duration (XFRAME (frame));
  unblock_input ();
  return d < 0 ? Qnil : make_float (d);
}

DEFUN ("gpu-video-position", Fmtl_video_position, Smtl_video_position, 0, 1, 0,
       doc: /* Return the inline video playback position on FRAME in seconds.
FRAME defaults to the selected frame.  Returns nil if there is no video.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  double p;
  block_input ();
  p = mtl_video_position (XFRAME (frame));
  unblock_input ();
  return p < 0 ? Qnil : make_float (p);
}

DEFUN ("gpu-video-seek", Fmtl_video_seek, Smtl_video_seek, 1, 2, 0,
       doc: /* Seek the inline video on FRAME to SECONDS.
FRAME defaults to the selected frame.  The seeked frame is shown at once,
even when the video is paused.  Returns t if a video is open.  */)
  (Lisp_Object seconds, Lisp_Object frame)
{
  CHECK_NUMBER (seconds);
  if (NILP (frame)) frame = Fselected_frame ();
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  bool ok;
  block_input ();
  ok = mtl_video_seek (XFRAME (frame), XFLOATINT (seconds));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-playing-p", Fmtl_video_playing_p, Smtl_video_playing_p, 0, 1, 0,
       doc: /* Return t if the inline video on FRAME is playing.
Return nil if it is paused or there is no video.  FRAME defaults to the
selected frame.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  int s;
  block_input ();
  s = mtl_video_playing (XFRAME (frame));
  unblock_input ();
  return s == 1 ? Qt : Qnil;
}

DEFUN ("gpu-video-size", Fmtl_video_size, Smtl_video_size, 0, 1, 0,
       doc: /* Return the natural size of the inline video on FRAME.
The value is a cons (WIDTH . HEIGHT) in pixels, or nil if there is no
video or its size is not known yet.  FRAME defaults to the selected
frame.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  double w = 0, h = 0;
  bool ok;
  block_input ();
  ok = mtl_video_size (XFRAME (frame), &w, &h);
  unblock_input ();
  return ok ? Fcons (make_float (w), make_float (h)) : Qnil;
}

DEFUN ("gpu-anim-tick", Fmtl_anim_tick, Smtl_anim_tick, 0, 2, 0,
       doc: /* Advance the GPU cursor animations one step and present.
DT is the step in seconds (default 0.033).  Driven by a Lisp timer while
animations are enabled: Emacs's event loop starves the CADisplayLink
when idle, so rings/trails would freeze between input events otherwise
(same mechanism as `gpu-video-tick').  FRAME defaults to the selected
frame.  Returns t while animations are enabled, nil otherwise.  */)
  (Lisp_Object dt, Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  MtlFrameData *fd = mtl_get_frame_data (XFRAME (frame));
  if (!fd || !fd.animator) return Qnil;
  if (!g_mtl_animations_enabled && !fd.transitionTexture && !fd.videoPlayer)
    return Qnil;

  float step = 0.033f;
  if (NUMBERP (dt))
    step = (float) XFLOATINT (dt);
  block_input ();
  if (!fd.encoder)
    [fd.animator tickWithDt:step];
  unblock_input ();
  return Qt;
}

DEFUN ("gpu-pump-tick", Fmtl_pump_tick, Smtl_pump_tick, 0, 1, 0,
       doc: /* Advance every continuous GPU animation on FRAME one step.
Single pump behind gpu.el's animation timer: the cursor effects, the
buffer-switch cross-fade and the inline video all advance together in
one deterministic tick (the animator presents are already coalesced by
the layer).  FRAME defaults to the selected frame.  Returns a mask of
the subsystems that still need pumping (1 = cursor or scroll effect in
motion, 2 = cross-fade running, 4 = video open, 8 = visible tool-card
borders, 16 = generic decorations, 32 = cursor animations enabled, which
needs only slow polling for blink changes); 0 lets the timer cancel
itself.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  if (!FRAME_LIVE_P (XFRAME (frame))) return make_fixnum (0);
  struct frame *f = XFRAME (frame);
  MtlFrameData *fd = mtl_get_frame_data (f);
  if (!fd || !fd.animator) return make_fixnum (0);

  int mask = (g_mtl_animations_enabled ? 32 : 0)
    | (fd.transitionTexture ? 2 : 0)
    | (fd.videoPlayer ? 4 : 0)
    | ([fd borderOverlaysNeedPump] ? 8 : 0)
    | ([fd decorationsNeedPump] ? 16 : 0);
  if (mask == 0) return make_fixnum (0);

  /* Real elapsed step: the pump re-paces between 30 and 60 Hz, so a
     fixed dt would speed the physics up and down with it.  */
  double now = CACurrentMediaTime ();
  double last = fd.lastPumpTime;
  float dt = (last > 0 && now - last < 0.1) ? (float) (now - last) : 0.033f;
  fd.lastPumpTime = now;

  block_input ();
  if (fd.videoPlayer)
    mtl_video_tick (f);                 /* pull the next decoded frame */
  if (!fd.encoder)
    {
      if ((mask & ~24) == 0)
        [fd presentCoalesced];
      else
        [fd.animator tickWithDt:dt];
    }
  /* Report cursor effects only while they move, so an idle cursor lets
     the pump slow to its polling rate.  */
  if (g_mtl_animations_enabled && [fd.animator isAnimating])
    mask |= 1;
  unblock_input ();
  return make_fixnum (mask);
}

/* -----------------------------------------------------------------------
   Native animated border API
   ----------------------------------------------------------------------- */

static double
mtl_border_number (Lisp_Object object, const char *label)
{
  CHECK_NUMBER (object);
  double value = XFLOATINT (object);
  /* Metal vertices and fragment math use single precision.  Keep conversions
     finite and leave ample headroom for endpoint and perimeter arithmetic. */
  if (!isfinite (value) || fabs (value) > FLT_MAX / 16.0)
    error ("%s values must be finite and representable", label);
  return value;
}

static NSRect
mtl_border_rect (Lisp_Object object, const char *label, BOOL positive_size)
{
  double values[4];
  Lisp_Object tail = object;
  for (int i = 0; i < 4; i++)
    {
      if (!CONSP (tail))
        error ("%s must be a four-number list", label);
      values[i] = mtl_border_number (XCAR (tail), label);
      tail = XCDR (tail);
    }
  if (!NILP (tail))
    error ("%s must be a four-number list", label);
  if ((positive_size && (values[2] <= 0 || values[3] <= 0))
      || (!positive_size && (values[2] < 0 || values[3] < 0)))
    error ("%s has invalid dimensions", label);
  if (!isfinite (values[0] + values[2])
      || !isfinite (values[1] + values[3]))
    error ("%s endpoints must be finite", label);
  return NSMakeRect (values[0], values[1], values[2], values[3]);
}

static MtlBorderStyle
mtl_border_style (Lisp_Object plist, MtlBorderState state)
{
  MtlBorderStyle style = {
    .cornerRadius = 11.0f,
    .strokeWidth = state == MTL_BORDER_RUNNING ? 1.8f : 1.5f,
    .opacity = 1.0f, .cycleDuration = 3.6f,
    .runnerFraction = 0.11f, .glowOpacity = 0.65f
  };
  struct {
    const char *name;
    float *target;
    double minimum, maximum;
  } options[] = {
    { ":corner-radius", &style.cornerRadius, 0, FLT_MAX / 16.0 },
    { ":stroke-width", &style.strokeWidth, 0.001, FLT_MAX / 16.0 },
    { ":opacity", &style.opacity, 0, 1 },
    { ":cycle-duration", &style.cycleDuration, 0.001, FLT_MAX / 16.0 },
    { ":runner-fraction", &style.runnerFraction, 0, 1 },
    { ":glow-opacity", &style.glowOpacity, 0, 1 }
  };
  if (NILP (Fproper_list_p (plist)))
    error ("STYLE must be a proper property list");
  while (CONSP (plist))
    {
      Lisp_Object key = XCAR (plist);
      plist = XCDR (plist);
      if (!CONSP (plist))
        error ("STYLE must have a value for each property");
      bool found = false;
      for (int i = 0; i < ARRAYELTS (options); i++)
        if (EQ (key, intern (options[i].name)))
          {
            double value = mtl_border_number (XCAR (plist), options[i].name);
            if (value < options[i].minimum || value > options[i].maximum)
              error ("%s must be between %g and %g", options[i].name,
                     options[i].minimum, options[i].maximum);
            *options[i].target = value;
            found = true;
            break;
          }
      if (!found)
        error ("Unknown border STYLE property");
      plist = XCDR (plist);
    }
  return style;
}

static MtlFrameData *
mtl_border_frame_data (Lisp_Object frame)
{
  if (NILP (frame))
    frame = Fselected_frame ();
  if (!FRAMEP (frame))
    return NULL;
  struct frame *f = XFRAME (frame);
  if (!FRAME_LIVE_P (f) || !FRAME_NS_P (f))
    return NULL;
  MtlFrameData *fd = mtl_get_frame_data (f);
  return fd && fd.metalLayer ? fd : NULL;
}

DEFUN ("gpu-border-set", Fmtl_border_set, Smtl_border_set, 5, 7, 0,
       doc: /* Set or update an animated border on a live Metal frame.
ID is a positive fixnum.  RECT and CLIP are (X Y WIDTH HEIGHT) lists in
logical frame pixels.  STATE is running, complete, failed, or idle; COLOR is
0xRRGGBB.  FRAME defaults to the selected frame.  Returns t when FRAME
accepts the overlay, including for an empty clip that removes/skips it.

STYLE is an optional property list.  Omitted properties use these defaults:
  :corner-radius    11 logical pixels, clamped to half the shorter side
  :stroke-width     1.8 logical pixels for running, 1.5 otherwise
  :opacity          1, a multiplier for the entire border including glow
  :cycle-duration   3.6 seconds for one running highlight circuit
  :runner-fraction  0.11 of the perimeter; 0 leaves a static running outline
  :glow-opacity     0.65; 0 disables the running highlight halo
Opacity, runner fraction, and glow opacity must be between 0 and 1.
Corner radius must be nonnegative; width and duration must be at least 0.001.
All values must be finite numbers.  Unknown properties signal an error.
Each call supplies a complete style, not a patch to the previous style.
Updating geometry or style without changing STATE preserves animation time.  */)
  (Lisp_Object id, Lisp_Object rect_value, Lisp_Object clip_value,
   Lisp_Object state_value, Lisp_Object color_value, Lisp_Object frame,
   Lisp_Object style_value)
{
  CHECK_FIXNUM (id);
  if (XFIXNUM (id) <= 0)
    error ("gpu-border-set: ID must be a positive fixnum");
  NSRect rect = mtl_border_rect (rect_value, "RECT", YES);
  NSRect clip = mtl_border_rect (clip_value, "CLIP", NO);

  MtlBorderState state;
  if (EQ (state_value, intern ("running")))
    state = MTL_BORDER_RUNNING;
  else if (EQ (state_value, intern ("complete")))
    state = MTL_BORDER_COMPLETE;
  else if (EQ (state_value, intern ("failed")))
    state = MTL_BORDER_FAILED;
  else if (EQ (state_value, intern ("idle")))
    state = MTL_BORDER_IDLE;
  else
    error ("gpu-border-set: STATE must be running, complete, failed, or idle");

  CHECK_FIXNUM (color_value);
  if (XFIXNUM (color_value) < 0 || XFIXNUM (color_value) > 0xFFFFFF)
    error ("gpu-border-set: COLOR must be an integer from 0x000000 to 0xFFFFFF");

  MtlBorderStyle style = mtl_border_style (style_value, state);
  MtlFrameData *fd = mtl_border_frame_data (frame);
  if (!fd)
    return Qnil;
  return [fd setBorderWithID:(unsigned long long) XFIXNUM (id)
                        rect:rect clip:clip state:state
                       color:(unsigned long) XFIXNUM (color_value)
                       style:style] ? Qt : Qnil;
}

DEFUN ("gpu-border-remove", Fmtl_border_remove, Smtl_border_remove, 1, 2, 0,
       doc: /* Remove border ID from FRAME.  FRAME defaults to the selected frame.
Returns non-nil only if a border was removed.  */)
  (Lisp_Object id, Lisp_Object frame)
{
  CHECK_FIXNUM (id);
  if (XFIXNUM (id) <= 0)
    error ("gpu-border-remove: ID must be a positive fixnum");
  MtlFrameData *fd = mtl_border_frame_data (frame);
  return fd && [fd removeBorderWithID:(unsigned long long) XFIXNUM (id)]
    ? Qt : Qnil;
}

DEFUN ("gpu-border-supported-p", Fmtl_border_supported_p,
       Smtl_border_supported_p, 0, 1, 0,
       doc: /* Return non-nil if FRAME is a live Metal-enabled frame.
FRAME defaults to the selected frame.  */)
  (Lisp_Object frame)
{
  return mtl_border_frame_data (frame) ? Qt : Qnil;
}


/* Generic retained decoration primitives.  Validation completes before mutation. */
static double
mtl_decoration_number (Lisp_Object object)
{
  double value = mtl_border_number (object, "Decoration");
  if (fabs (value) > 1000000) error ("Decoration coordinate/style exceeds 1000000");
  return value;
}

static NSRect
mtl_decoration_rect (Lisp_Object object, BOOL line)
{
  float values[4];
  Lisp_Object tail = object;
  for (int i = 0; i < 4; i++)
    { if (!CONSP (tail)) error ("Decoration rect requires four numbers");
      values[i] = mtl_decoration_number (XCAR (tail)); tail = XCDR (tail); }
  if (!NILP (tail)) error ("Decoration rect requires four numbers");
  if (!line && (values[2] <= 0 || values[3] <= 0)) error ("Dimensions must be positive");
  return NSMakeRect (values[0], values[1], values[2], values[3]);
}

static unsigned long
mtl_decoration_color (Lisp_Object object)
{
  CHECK_FIXNUM (object);
  if (XFIXNUM (object) < 0 || XFIXNUM (object) > 0xffffff)
    error ("Decoration color must be 0xRRGGBB or nil");
  return XFIXNUM (object);
}

static const char *const mtl_decoration_extra_keys[] = {
  ":image", ":path", ":view-box", ":line-cap", ":line-join", ":dash",
  ":stroke-start", ":stroke-end", ":rotation", ":scale", ":translate", NULL
};

static bool
mtl_decoration_extra_key_p (Lisp_Object key)
{
  for (int i = 0; mtl_decoration_extra_keys[i]; i++)
    if (EQ (key, intern (mtl_decoration_extra_keys[i]))) return true;
  return false;
}

static CGPathRef
mtl_decoration_svg_path (Lisp_Object data)
{
  CHECK_STRING (data);
  CGPathRef path = mtl_svg_path_create (SSDATA (ENCODE_UTF_8 (data)));
  if (!path) error ("Invalid SVG path data");
  return path;
}

/* Parse PLIST's properties beyond the native record for frame F.  Return
   an autoreleased dictionary, empty when there are none.  */
static NSDictionary *
mtl_decoration_extras (Lisp_Object plist, struct frame *f)
{
  NSMutableDictionary *extras = [NSMutableDictionary dictionary];
  for (; CONSP (plist) && CONSP (XCDR (plist)); plist = XCDR (XCDR (plist)))
    {
      Lisp_Object key = XCAR (plist), value = XCAR (XCDR (plist));
      if (NILP (value)) continue;
      if (EQ (key, intern (":image")))
        {
          if (!f) continue;
          ptrdiff_t image_id = lookup_image (f, value, -1);
          struct image *img = IMAGE_FROM_ID (f, image_id);
          prepare_image_for_display (f, img);
          if (!img->pixmap) error ("Image could not be loaded");
          extras[@"image"] = (id) img->pixmap;
        }
      else if (EQ (key, intern (":path")))
        {
          CGPathRef path = mtl_decoration_svg_path (value);
          extras[@"path"] = (id) path;
          CGPathRelease (path);
        }
      else if (EQ (key, intern (":view-box")))
        {
          NSRect box = mtl_decoration_rect (value, NO);
          extras[@"viewBox"] = [NSValue valueWithRect:box];
        }
      else if (EQ (key, intern (":line-cap")) || EQ (key, intern (":line-join")))
        {
          CHECK_SYMBOL (value);
          extras[EQ (key, intern (":line-cap")) ? @"lineCap" : @"lineJoin"]
            = [NSString stringWithUTF8String:SSDATA (SYMBOL_NAME (value))];
        }
      else if (EQ (key, intern (":dash")))
        {
          NSMutableArray *dash = [NSMutableArray array];
          for (Lisp_Object tail = value; CONSP (tail); tail = XCDR (tail))
            [dash addObject:@(mtl_decoration_number (XCAR (tail)))];
          extras[@"dash"] = dash;
        }
      else if (EQ (key, intern (":stroke-start")) || EQ (key, intern (":stroke-end")))
        {
          double number = mtl_decoration_number (value);
          if (number < 0 || number > 1) error ("Stroke start and end must be in 0..1");
          extras[EQ (key, intern (":stroke-start")) ? @"strokeStart" : @"strokeEnd"] = @(number);
        }
      else if (EQ (key, intern (":rotation")))
        extras[@"rotation"] = @(mtl_decoration_number (value));
      else if (EQ (key, intern (":scale")))
        {
          double number = mtl_decoration_number (value);
          if (number <= 0) error ("Scale must be positive");
          extras[@"scale"] = @(number);
        }
      else if (EQ (key, intern (":translate")))
        {
          if (!CONSP (value) || !CONSP (XCDR (value))) error ("Translate requires (DX DY)");
          extras[@"translate"] = [NSValue valueWithPoint:
                                    NSMakePoint (mtl_decoration_number (XCAR (value)),
                                                 mtl_decoration_number (XCAR (XCDR (value))))];
        }
    }
  return extras;
}

/* Whether decoration VALUE with EXTRAS needs Core Animation, which draws
   images, paths and every property beyond the native record.  */
static bool
mtl_decoration_needs_layers (MtlDecoration value, NSDictionary *extras)
{
  return value.shape == MTL_DECORATION_IMAGE || value.shape == MTL_DECORATION_PATH
    || extras.count > 0;
}

static struct frame *
mtl_decoration_frame (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  return FRAMEP (frame) && FRAME_LIVE_P (XFRAME (frame)) ? XFRAME (frame) : NULL;
}

static MtlDecoration
mtl_decoration_value (Lisp_Object plist)
{
  MtlDecoration v = { .shape = MTL_DECORATION_RECT, .hasStroke = YES,
    .stroke = 0xffffff, .strokeWidth = 1, .opacity = 1,
    .sweepAngle = 2 * M_PI };
  Lisp_Object rect = Qnil, seen = Qnil, plist_start = plist;
  bool clip_seen = false;
  if (NILP (Fproper_list_p (plist))) error ("Decoration must be a proper plist");
  while (CONSP (plist))
    {
      Lisp_Object key = XCAR (plist);
      if (!NILP (Fmemq (key, seen))) error ("Duplicate decoration property");
      seen = Fcons (key, seen);
      plist = XCDR (plist);
      if (!CONSP (plist)) error ("Decoration property lacks a value");
      Lisp_Object value = XCAR (plist);
      if (EQ (key, intern (":shape")))
        {
          if (EQ (value, intern ("rounded-rectangle"))) v.shape = MTL_DECORATION_RECT;
          else if (EQ (value, intern ("circle"))) v.shape = MTL_DECORATION_CIRCLE;
          else if (EQ (value, intern ("arc"))) v.shape = MTL_DECORATION_ARC;
          else if (EQ (value, intern ("line"))) v.shape = MTL_DECORATION_LINE;
          else if (EQ (value, intern ("text"))) v.shape = MTL_DECORATION_TEXT;
          else if (EQ (value, intern ("image"))) v.shape = MTL_DECORATION_IMAGE;
          else if (EQ (value, intern ("path"))) v.shape = MTL_DECORATION_PATH;
          else error ("Unknown decoration shape");
        }
      else if (EQ (key, intern (":rect"))) rect = value;
      else if (EQ (key, intern (":clip")))
        { v.clip = mtl_border_rect (value, "CLIP", NO); clip_seen = true; }
      else if (EQ (key, intern (":fill")))
        { v.hasFill = !NILP (value); if (v.hasFill) v.fill = mtl_decoration_color (value); }
      else if (EQ (key, intern (":stroke")))
        { v.hasStroke = !NILP (value); if (v.hasStroke) v.stroke = mtl_decoration_color (value); }
      else if (EQ (key, intern (":z"))) { CHECK_FIXNUM (value); v.z = XFIXNUM (value); }
      else if (EQ (key, intern (":opacity")))
        { double number = mtl_decoration_number (value);
          if (number < 0 || number > 1) error ("Opacity must be in 0..1");
          v.opacity = number; }
      else if (EQ (key, intern (":radius")))
        { double number = mtl_decoration_number (value);
          if (number < 0) error ("Radius must be nonnegative");
          v.radius = number; }
      else if (EQ (key, intern (":stroke-width")))
        { double number = mtl_decoration_number (value);
          if (number < 0.001) error ("Stroke width must be at least 0.001");
          v.strokeWidth = number; }
      else if (EQ (key, intern (":start-angle"))) v.startAngle = mtl_decoration_number (value);
      else if (EQ (key, intern (":sweep-angle"))) v.sweepAngle = mtl_decoration_number (value);
      /* Parsed by mtl_decoration_extras.  */
      else if (mtl_decoration_extra_key_p (key)) ;
      else error ("Unknown decoration property");
      plist = XCDR (plist);
    }
  /* Line width/height are signed endpoint deltas, including horizontal lines. */
  if (v.shape == MTL_DECORATION_LINE)
    {
      v.rect = mtl_decoration_rect (rect, YES);
    }
  else v.rect = mtl_decoration_rect (rect, NO);
  if (!clip_seen) error ("Decoration requires :clip");
  if (v.radius < 0 || v.strokeWidth < 0.001 || v.opacity < 0 || v.opacity > 1)
    error ("Invalid decoration radius, stroke width, or opacity");
  if ((v.shape == MTL_DECORATION_CIRCLE || v.shape == MTL_DECORATION_ARC)
      && v.rect.size.width != v.rect.size.height)
    error ("Circle/arc requires square :rect");
  if (fabs (v.sweepAngle) > 2 * M_PI + 0.000001)
    error ("Arc sweep must be within -2pi..2pi");
  if ((v.shape == MTL_DECORATION_ARC || v.shape == MTL_DECORATION_LINE) && v.hasFill)
    error ("Arc/line does not support fill");
  if (v.shape == MTL_DECORATION_TEXT && !v.hasFill)
    error ("Text requires a :fill highlight color");
  if (v.shape == MTL_DECORATION_PATH && NILP (Fplist_get (plist_start, intern (":path"), Qnil)))
    error ("Path requires :path data");
  /* Normalize before shader fmod to keep angular arithmetic well conditioned. */
  v.startAngle = fmod (v.startAngle, 2 * M_PI);
  return v;
}

static void
mtl_decoration_id (Lisp_Object id)
{
  CHECK_FIXNUM (id);
  if (XFIXNUM (id) <= 0) error ("Decoration ID must be positive");
}

DEFUN ("gpu--decoration-create", Fmtl_decoration_create, Smtl_decoration_create, 1, 2, 0,
       doc: /* Create a retained decoration from complete PROPERTIES on FRAME.
Internal primitive for gpu.el.  Return a process-unique ID, or nil if unsupported.
Validation precedes mutation even on unsupported frames.  */)
  (Lisp_Object properties, Lisp_Object frame)
{
  MtlDecoration value = mtl_decoration_value (properties);
  MtlFrameData *fd = mtl_border_frame_data (frame);
  if (!fd) return Qnil;
  NSDictionary *extras = mtl_decoration_extras (properties, mtl_decoration_frame (frame));
  if (mtl_decoration_needs_layers (value, extras) && !fd.decorationLayer) return Qnil;
  static EMACS_INT next = 0;
  if (next == MOST_POSITIVE_FIXNUM) error ("Decoration IDs exhausted");
  EMACS_INT id = ++next;
  [fd setDecorationExtras:extras identifier:id];
  return [fd setDecoration:value identifier:id cancel:7] ? make_fixnum (id) : Qnil;
}

DEFUN ("gpu--decoration-set", Fmtl_decoration_set, Smtl_decoration_set, 3, 4, 0,
       doc: /* Replace decoration ID with complete PROPERTIES on FRAME.
CANCEL is a bitmask: 1 cancels geometry animation, 2 cancels opacity animation,
4 cancels start-angle animation.  Omitted CANCEL means 7.  A missing ID is not recreated.  */)
  (Lisp_Object id, Lisp_Object properties, Lisp_Object frame, Lisp_Object cancel)
{
  mtl_decoration_id (id);
  MtlDecoration value = mtl_decoration_value (properties);
  if (NILP (cancel)) cancel = make_fixnum (7);
  CHECK_FIXNUM (cancel);
  if (XFIXNUM (cancel) < 0 || XFIXNUM (cancel) > 7) error ("Invalid cancellation mask");
  MtlFrameData *fd = mtl_border_frame_data (frame);
  MtlDecorationRecord record;
  if (!fd || ![fd getDecoration:XFIXNUM (id) record:&record]) return Qnil;
  NSDictionary *extras = mtl_decoration_extras (properties, mtl_decoration_frame (frame));
  if (mtl_decoration_needs_layers (value, extras) && !fd.decorationLayer) return Qnil;
  [fd setDecorationExtras:extras identifier:XFIXNUM (id)];
  return [fd setDecoration:value identifier:XFIXNUM (id) cancel:XFIXNUM (cancel)] ? Qt : Qnil;
}

DEFUN ("gpu--decoration-remove", Fmtl_decoration_remove, Smtl_decoration_remove, 1, 2, 0,
       doc: /* Remove retained decoration ID from FRAME.  Return t if removed.  */)
  (Lisp_Object id, Lisp_Object frame)
{
  mtl_decoration_id (id);
  MtlFrameData *fd = mtl_border_frame_data (frame);
  return fd && [fd removeDecoration:XFIXNUM (id)] ? Qt : Qnil;
}

DEFUN ("gpu--decoration-text", Fmtl_decoration_text, Smtl_decoration_text, 6, 7, 0,
       doc: /* Give text decoration ID its LABEL, FONT family, SIZE, ADVANCE and PERIOD.
Internal primitive for gpu.el, for FRAME.  SIZE is the font's pixel size,
and ADVANCE the pixel width of each character cell.  A highlight
band sweeps through LABEL every PERIOD seconds, or stays still when PERIOD
is zero.  Return t, or nil when FRAME cannot draw text decorations.  */)
  (Lisp_Object id, Lisp_Object label, Lisp_Object font, Lisp_Object size,
   Lisp_Object advance, Lisp_Object period, Lisp_Object frame)
{
  mtl_decoration_id (id);
  CHECK_STRING (label);
  CHECK_STRING (font);
  double pixels = mtl_decoration_number (size);
  double seconds = mtl_decoration_number (period);
  if (pixels <= 0) error ("Text size must be positive");
  if (seconds < 0) error ("Sweep period must be nonnegative");
  MtlFrameData *fd = mtl_border_frame_data (frame);
  if (!fd) return Qnil;
  NSDictionary *text = @{ @"text": [NSString stringWithUTF8String:SSDATA (ENCODE_UTF_8 (label))],
                          @"font": [NSString stringWithUTF8String:SSDATA (ENCODE_UTF_8 (font))],
                          @"size": @(pixels), @"advance": @(mtl_decoration_number (advance)),
                          @"period": @(seconds) };
  return [fd setDecorationText:text identifier:XFIXNUM (id)] ? Qt : Qnil;
}

/* Key paths and value kinds of the keyframe properties.  */
static NSString *
mtl_decoration_key_path (Lisp_Object property, int *kind)
{
  static const struct { const char *name, *path; int kind; } table[] = {
    { ":opacity", "opacity", 0 }, { ":rotation", "transform.rotation.z", 0 },
    { ":scale", "transform.scale", 0 }, { ":translate-x", "transform.translation.x", 0 },
    { ":translate-y", "transform.translation.y", 0 }, { ":stroke-start", "strokeStart", 0 },
    { ":stroke-end", "strokeEnd", 0 }, { ":stroke-width", "lineWidth", 0 },
    { ":fill", "fillColor", 1 }, { ":stroke", "strokeColor", 1 }, { ":path", "path", 2 },
  };
  for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
    if (EQ (property, intern (table[i].name)))
      {
        *kind = table[i].kind;
        return [NSString stringWithUTF8String:table[i].path];
      }
  error ("Property cannot animate with keyframes");
}

static NSString *
mtl_decoration_easing_name (Lisp_Object easing)
{
  if (NILP (easing)) return @"linear";
  CHECK_SYMBOL (easing);
  if (EQ (easing, intern ("linear")) || EQ (easing, intern ("ease-in"))
      || EQ (easing, intern ("ease-out")) || EQ (easing, intern ("ease-in-out")))
    return [NSString stringWithUTF8String:SSDATA (SYMBOL_NAME (easing))];
  error ("Unknown keyframe easing");
}

DEFUN ("gpu--decoration-keyframes", Fmtl_decoration_keyframes, Smtl_decoration_keyframes,
       5, 6, 0,
       doc: /* Animate decoration ID's PROPERTY through VALUES over DURATION seconds.
Internal primitive for gpu.el, for FRAME.  OPTIONS is a plist of :times,
:easing (a symbol, a list with one per step, or spring for two values),
:repeat (t or a count), :autoreverse and :delay.  Return t, or nil when
FRAME cannot draw decorations with Core Animation.  */)
  (Lisp_Object id, Lisp_Object property, Lisp_Object values, Lisp_Object duration,
   Lisp_Object options, Lisp_Object frame)
{
  mtl_decoration_id (id);
  int kind;
  NSString *key = mtl_decoration_key_path (property, &kind);
  double seconds = mtl_decoration_number (duration);
  if (seconds < 0.001) error ("Animation duration must be at least 0.001 seconds");
  NSMutableArray *list = [NSMutableArray array];
  for (Lisp_Object tail = values; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object value = XCAR (tail);
      if (kind == 1)
        {
          unsigned long rgb = mtl_decoration_color (value);
          CGColorRef color = CGColorCreateSRGB (((rgb >> 16) & 0xff) / 255.0,
                                                ((rgb >> 8) & 0xff) / 255.0,
                                                (rgb & 0xff) / 255.0, 1.0);
          [list addObject:(NSObject *) color];
          CGColorRelease (color);
        }
      else if (kind == 2)
        {
          CGPathRef path = mtl_decoration_svg_path (value);
          [list addObject:(NSObject *) path];
          CGPathRelease (path);
        }
      else
        [list addObject:@(mtl_decoration_number (value))];
    }
  if (list.count < 2) error ("Keyframes need at least two values");
  NSMutableDictionary *spec = [NSMutableDictionary dictionary];
  spec[@"keyPath"] = key;
  spec[@"values"] = list;
  spec[@"duration"] = @(seconds);
  Lisp_Object times = Fplist_get (options, intern (":times"), Qnil);
  if (!NILP (times))
    {
      NSMutableArray *array = [NSMutableArray array];
      for (Lisp_Object tail = times; CONSP (tail); tail = XCDR (tail))
        [array addObject:@(mtl_decoration_number (XCAR (tail)))];
      if (array.count != list.count) error ("Keyframe :times must match the values");
      spec[@"times"] = array;
    }
  Lisp_Object easing = Fplist_get (options, intern (":easing"), Qnil);
  if (EQ (easing, intern ("spring")))
    {
      if (list.count != 2) error ("Spring easing needs exactly two values");
      spec[@"spring"] = @YES;
    }
  else if (CONSP (easing))
    {
      NSMutableArray *array = [NSMutableArray array];
      for (Lisp_Object tail = easing; CONSP (tail); tail = XCDR (tail))
        [array addObject:mtl_decoration_easing_name (XCAR (tail))];
      if (array.count != list.count - 1) error ("Keyframe :easing needs one per step");
      spec[@"easings"] = array;
    }
  else
    spec[@"easings"] = @[mtl_decoration_easing_name (easing)];
  Lisp_Object repeat = Fplist_get (options, intern (":repeat"), Qnil);
  spec[@"repeat"] = @(EQ (repeat, Qt) ? -1.0 : NILP (repeat) ? 0.0
                      : mtl_decoration_number (repeat));
  spec[@"autoreverse"] = @(!NILP (Fplist_get (options, intern (":autoreverse"), Qnil)));
  Lisp_Object delay = Fplist_get (options, intern (":delay"), Qnil);
  spec[@"delay"] = @(NILP (delay) ? 0.0 : mtl_decoration_number (delay));
  MtlFrameData *fd = mtl_border_frame_data (frame);
  return fd && fd.decorationLayer && [fd setDecorationKeyframes:spec identifier:XFIXNUM (id)]
    ? Qt : Qnil;
}

DEFUN ("gpu-decoration-capabilities", Fmtl_decoration_capabilities,
       Smtl_decoration_capabilities, 0, 1, 0,
       doc: /* Return what decorations FRAME can draw, or nil without decorations.
The value is a plist.  :shapes lists the shapes and :animate the properties
`gpu-decoration-animate' accepts.  :keyframes and :layers are t when Core
Animation draws the frame's decorations, which adds images, paths, text,
paint and transform properties, and `gpu-decoration-keyframes'.  */)
  (Lisp_Object frame)
{
  MtlFrameData *fd = mtl_border_frame_data (frame);
  if (!fd) return Qnil;
  bool layers = fd.decorationLayer != nil;
  Lisp_Object shapes = list4 (intern ("rounded-rectangle"), intern ("circle"),
                              intern ("arc"), intern ("line"));
  Lisp_Object animate = list3 (intern (":rect"), intern (":opacity"), intern (":start-angle"));
  if (layers)
    {
      shapes = nconc2 (shapes, list3 (intern ("text"), intern ("image"), intern ("path")));
      animate = nconc2 (animate, list (intern (":rotation"), intern (":scale"),
                                       intern (":translate-x"), intern (":translate-y"),
                                       intern (":stroke-start"), intern (":stroke-end"),
                                       intern (":stroke-width"), intern (":fill"),
                                       intern (":stroke"), intern (":path")));
    }
  return list (intern (":shapes"), shapes, intern (":animate"), animate,
               intern (":keyframes"), layers ? Qt : Qnil,
               intern (":layers"), layers ? Qt : Qnil);
}

DEFUN ("gpu--decoration-animate", Fmtl_decoration_animate, Smtl_decoration_animate, 4, 7, 0,
       doc: /* Animate ID's PROPERTY to TARGET over DURATION seconds on FRAME.
PROPERTY is :rect, :opacity or :start-angle.  EASING is linear, ease-out, or ease-in-out.
REPEAT is nil or t.  Retarget from the current native value, not the last Lisp
snapshot.  Hidden objects use elapsed time when next presented.  */)
  (Lisp_Object id, Lisp_Object property, Lisp_Object target, Lisp_Object duration,
   Lisp_Object easing, Lisp_Object repeat, Lisp_Object frame)
{
  mtl_decoration_id (id);
  double seconds = mtl_decoration_number (duration);
  if (seconds < 0.001) error ("Animation duration must be at least 0.001 seconds");
  int curve = 0, prop;
  if (NILP (easing) || EQ (easing, intern ("linear"))) curve = 0;
  else if (EQ (easing, intern ("ease-out"))) curve = 1;
  else if (EQ (easing, intern ("ease-in-out"))) curve = 2;
  else error ("Unknown decoration easing");
  if (!NILP (repeat) && !EQ (repeat, Qt)) error ("Repeat must be nil or t");
  float values[4] = { 0 };
  if (EQ (property, intern (":opacity")))
    {
      prop = 2;
      double number = mtl_decoration_number (target);
      if (number < 0 || number > 1) error ("Opacity must be in 0..1");
      values[0] = number;
    }
  else if (EQ (property, intern (":rect")))
    {
      prop = 1;
      /* Dimensions are checked against the retained shape after lookup. */
      Lisp_Object tail = target;
      for (int i = 0; i < 4; i++)
        { if (!CONSP (tail)) error ("Target rect requires four numbers");
          values[i] = mtl_decoration_number (XCAR (tail)); tail = XCDR (tail); }
      if (!NILP (tail)) error ("Target rect requires four numbers");
    }
  else if (EQ (property, intern (":start-angle")))
    {
      prop = 3;
      values[0] = mtl_decoration_number (target);
    }
  else error ("Only :rect, :opacity and :start-angle can animate");
  MtlFrameData *fd = mtl_border_frame_data (frame);
  MtlDecorationRecord record;
  if (!fd || ![fd getDecoration:XFIXNUM (id) record:&record]) return Qnil;
  if (prop == 1 && record.value.shape != MTL_DECORATION_LINE)
    {
      if (values[2] <= 0 || values[3] <= 0) error ("Target dimensions must be positive");
      if ((record.value.shape == MTL_DECORATION_CIRCLE || record.value.shape == MTL_DECORATION_ARC)
          && values[2] != values[3]) error ("Target circle/arc must be square");
    }
  return [fd animateDecoration:XFIXNUM (id) property:prop target:values
                     duration:seconds easing:curve repeat:!NILP (repeat)] ? Qt : Qnil;
}

DEFUN ("gpu--decoration-state", Fmtl_decoration_state, Smtl_decoration_state, 1, 2, 0,
       doc: /* Return sampled native geometry, opacity and animation flags for ID.
Return nil for a missing decoration.  Does not retire animation tracks.  */)
  (Lisp_Object id, Lisp_Object frame)
{
  mtl_decoration_id (id);
  MtlFrameData *fd = mtl_border_frame_data (frame);
  MtlDecorationRecord r;
  if (!fd || ![fd getDecoration:XFIXNUM (id) record:&r]) return Qnil;
  return list4 (list4 (make_float (r.value.rect.origin.x), make_float (r.value.rect.origin.y),
                       make_float (r.value.rect.size.width), make_float (r.value.rect.size.height)),
                make_float (r.value.opacity), r.geometry.active ? Qt : Qnil,
                r.opacity.active ? Qt : Qnil);
}

DEFUN ("gpu-vsync", Fmtl_vsync, Smtl_vsync, 1, 2, 0,
       doc: /* Enable (non-nil) or disable display sync for FRAME's GPU layer.
With vsync on (default) presents wait for the display refresh: redisplay
is capped at the panel rate, which keeps CPU/GPU use minimal.  With it
off, presents return immediately (lower latency, uncapped, more power).
FRAME defaults to the selected frame.  */)
  (Lisp_Object enable, Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  CHECK_LIVE_FRAME (frame);
  g_mtl_vsync_enabled = !NILP (enable);
  MtlFrameData *fd = mtl_get_frame_data (XFRAME (frame));
  if (fd && fd.metalLayer)
    {
      block_input ();
      fd.metalLayer.displaySyncEnabled = g_mtl_vsync_enabled;
      unblock_input ();
    }
  return enable;
}

DEFUN ("gpu-transition-start", Fmtl_transition_start, Smtl_transition_start,
       1, 2, 0,
       doc: /* Crossfade the current frame content over the next redraw.
Snapshot what FRAME shows now and fade it out over DURATION seconds
while the new content appears underneath.  Driven by mtl.el's
buffer-switch hook; callable directly for custom effects.  FRAME
defaults to the selected frame.  Returns t if the snapshot was taken.  */)
  (Lisp_Object duration, Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  CHECK_LIVE_FRAME (frame);
  CHECK_NUMBER (duration);
  bool ok;
  block_input ();
  ok = mtl_transition_start (XFRAME (frame), (float) XFLOATINT (duration));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-transition-active-p", Fmtl_transition_active_p,
       Smtl_transition_active_p, 0, 1, 0,
       doc: /* Return t while a buffer-switch cross-fade is running on FRAME.
Unlike the tick primitives this does not present a frame or advance the
fade; it only reports its state.  FRAME defaults to the selected frame.
Test harnesses use it to wait for a quiescent frame before capturing
the screen.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = Fselected_frame ();
  CHECK_LIVE_FRAME (frame);
  MtlFrameData *fd = mtl_get_frame_data (XFRAME (frame));
  return (fd && fd.transitionTexture) ? Qt : Qnil;
}

void
syms_of_mtlfns (void)
{
  defsubr (&Smtl_open_connection);
  defsubr (&Smtl_backend_p);
  defsubr (&Smtl_device_name);
  defsubr (&Smtl_enable_for_frame);
  defsubr (&Smtl_open_test_window);
  defsubr (&Smtl_render_to_png);
  defsubr (&Smtl_create_frame);
  /* Phase 4: animation configuration */
  defsubr (&Smtl_cursor_mode);
  defsubr (&Smtl_scroll_effect);
  defsubr (&Smtl_scroll_duration);
  defsubr (&Smtl_trail_length);
  defsubr (&Smtl_cursor_suppress_effects);
  defsubr (&Smtl_animation_status);
  defsubr (&Smtl_animations);
  defsubr (&Smtl_capture_frame);
  defsubr (&Smtl_draw_stats);
  /* Inline video */
  defsubr (&Smtl_video_open);
  defsubr (&Smtl_video_close);
  defsubr (&Smtl_video_pause);
  defsubr (&Smtl_video_move);
  defsubr (&Smtl_video_tick);
  defsubr (&Smtl_video_duration);
  defsubr (&Smtl_video_position);
  defsubr (&Smtl_video_seek);
  defsubr (&Smtl_video_playing_p);
  defsubr (&Smtl_video_size);
  defsubr (&Smtl_anim_tick);
  defsubr (&Smtl_pump_tick);
  defsubr (&Smtl_border_set);
  defsubr (&Smtl_border_remove);
  defsubr (&Smtl_border_supported_p);
  defsubr (&Smtl_decoration_create);
  defsubr (&Smtl_decoration_set);
  defsubr (&Smtl_decoration_remove);
  defsubr (&Smtl_decoration_animate);
  defsubr (&Smtl_decoration_text);
  defsubr (&Smtl_decoration_keyframes);
  defsubr (&Smtl_decoration_capabilities);
  defsubr (&Smtl_decoration_state);
  defsubr (&Smtl_vsync);
  defsubr (&Smtl_transition_start);
  defsubr (&Smtl_transition_active_p);
}

#endif /* HAVE_MTL */
