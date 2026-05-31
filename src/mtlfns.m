/* Metal backend Lisp interface — Phase 2.
   Copyright (C) 2026 Free Software Foundation, Inc.  (GPL-3+)  */

#include <config.h>

#ifdef HAVE_MTL

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
#include "macfont.h"

#include "mtlterm.h"

/* Forward declaration for syms */
void syms_of_mtlfns (void);

/* -----------------------------------------------------------------------
   DEFUN: mtl-open-connection — initialize Metal terminal
   ----------------------------------------------------------------------- */

DEFUN ("mtl-open-connection", Fmtl_open_connection, Smtl_open_connection,
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

DEFUN ("mtl-backend-p", Fmtl_backend_p, Smtl_backend_p, 0, 0, 0,
       doc: /* Return t if Metal GPU backend is available on this system.  */)
  (void)
{
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice ();
  return dev ? Qt : Qnil;
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-device-name
   ----------------------------------------------------------------------- */

DEFUN ("mtl-device-name", Fmtl_device_name, Smtl_device_name, 0, 0, 0,
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

DEFUN ("mtl-enable-for-frame", Fmtl_enable_for_frame, Smtl_enable_for_frame,
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
    error ("mtl-enable-for-frame: FRAME must be an NS (macOS) frame");

  block_input ();
  MtlFrameData *fd = mtl_setup_frame (f);
  unblock_input ();

  if (!fd)
    error ("mtl-enable-for-frame: failed to set up Metal layer (Metal not available?)");

  /* Replace the terminal's redisplay_interface (rif) with our Metal rif.
     This redirects all rendering calls (draw_glyph_string, draw_window_cursor,
     etc.) from NS CoreGraphics to our Metal pipeline.
     The NS terminal still handles events, menus, and scrollbars. */
  mtl_patch_terminal_rif (f);

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

DEFUN ("mtl-open-test-window", Fmtl_open_test_window, Smtl_open_test_window,
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

DEFUN ("mtl-render-to-png", Fmtl_render_to_png, Smtl_render_to_png, 1, 1, 0,
       doc: /* Render a Metal GPU frame off-screen and save it as PNG at PATH.
Rasterizes text via CoreText into the Metal glyph atlas and renders textured
quads to an off-screen MTLTexture.  Returns t on success.  */)
  (Lisp_Object path)
{
  CHECK_STRING (path);
  return mtl_render_text_png (SSDATA (path)) ? Qt : Qnil;
}

/* -----------------------------------------------------------------------
   DEFUN: mtl-create-frame (stub — use mtl-enable-for-frame instead)
   ----------------------------------------------------------------------- */

DEFUN ("mtl-create-frame", Fmtl_create_frame, Smtl_create_frame, 1, 1, 0,
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

DEFUN ("mtl-cursor-mode", Fmtl_cursor_mode, Smtl_cursor_mode, 1, 1, 0,
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
  return mode;
}

DEFUN ("mtl-scroll-effect", Fmtl_scroll_effect, Smtl_scroll_effect, 1, 1, 0,
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
  return effect;
}

DEFUN ("mtl-scroll-duration", Fmtl_scroll_duration, Smtl_scroll_duration,
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

DEFUN ("mtl-trail-length", Fmtl_trail_length, Smtl_trail_length, 1, 1, 0,
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

DEFUN ("mtl-animation-status", Fmtl_animation_status, Smtl_animation_status,
       0, 0, 0,
       doc: /* Return an alist with current Metal animation configuration.  */)
  (void)
{
  return list4 (
    Fcons (intern ("cursor-mode"),    make_fixnum ((EMACS_INT)g_mtl_cursor_mode)),
    Fcons (intern ("scroll-easing"),  make_fixnum ((EMACS_INT)g_mtl_scroll_easing)),
    Fcons (intern ("scroll-duration"),make_float (g_mtl_scroll_duration)),
    Fcons (intern ("trail-length"),   make_fixnum ((EMACS_INT)g_mtl_trail_len)));
}

/* -----------------------------------------------------------------------
   Initialization
   ----------------------------------------------------------------------- */

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
  defsubr (&Smtl_animation_status);
}

#endif /* HAVE_MTL */
