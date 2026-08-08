/* Lisp interface to the OpenGL (EGL/OpenGL ES) GPU display backend.
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


   This is the GNU/Linux counterpart of mtlfns.m.  It exposes the same
   `gpu-*' Lisp API names so the existing tooling (gpu.el, the comparison
   harness) works unchanged: enable the backend on a frame and read the
   off-screen render target back for pixel-parity testing.  The drawing
   itself lives in glterm.c (driver) and gfxterm.c (policy).  */

#include <config.h>

#ifdef HAVE_GFX_GL

#include <stdio.h>
#include <stdlib.h>

#include <GLES3/gl3.h>

#include "lisp.h"
#include "frame.h"
#include "window.h"
#include "dispextern.h"
#include "blockinput.h"
#include "coding.h"
#include "glterm.h"

/* The glyph-cache warm-up lives in the neutral policy (gfxterm.c).  */
extern void gfx_warm_glyph_cache (struct frame *f);

void syms_of_glfns (void);

/* -----------------------------------------------------------------------
   gpu-backend-p / gpu-device-name
   ----------------------------------------------------------------------- */

DEFUN ("gpu-backend-p", Fgl_backend_p, Sgl_backend_p, 0, 0, 0,
       doc: /* Return t if the OpenGL GPU backend can be initialized.  */)
  (void)
{
  bool ok;
  block_input ();
  ok = gl_backend_available ();
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-device-name", Fgl_device_name, Sgl_device_name, 0, 0, 0,
       doc: /* Return the OpenGL renderer string, or nil if unavailable.  */)
  (void)
{
  if (!gl_backend_available ()) return Qnil;
  const GLubyte *r = glGetString (GL_RENDERER);
  return r ? build_string ((const char *) r) : Qnil;
}

DEFUN ("gpu-display-type", Fgl_display_type, Sgl_display_type, 0, 0, 0,
       doc: /* Return the EGL display type as a string.
Possible values: \"surfaceless\", \"x11\", \"wayland\".
\"surfaceless\" means the GPU renders off-screen (FBO capture works but
no on-screen present); \"wayland\" means a real Wayland EGL window surface
is used for on-screen present.  */)
  (void)
{
  if (!gl_backend_available ()) return Qnil;
  return build_string (gl_display_type_name ());
}

/* -----------------------------------------------------------------------
   gpu-enable-for-frame
   ----------------------------------------------------------------------- */

DEFUN ("gpu-enable-for-frame", Fgl_enable_for_frame, Sgl_enable_for_frame,
       1, 1, 0,
       doc: /* Add OpenGL GPU rendering to an existing Emacs frame FRAME.
Brings up the EGL context and an off-screen render target, then patches
the terminal's redisplay hooks so redisplay paints through the GPU.
FRAME must be a live graphical frame (X11 or PGTK/Wayland).  Returns t on
success.  */)
  (Lisp_Object frame)
{
  CHECK_LIVE_FRAME (frame);
  struct frame *f = XFRAME (frame);

  if (!FRAME_X_P (f) && !FRAME_PGTK_P (f))
    error ("gpu-enable-for-frame: FRAME must be an X or PGTK (Wayland/X11) frame");

  block_input ();
  bool ok = gl_enable_for_frame (f);
  if (ok)
    {
      /* Images are shared by frames on the same display.  Move this frame to a
         GPU-specific cache before reloading SVGs with GPU transparency.  */
      image_cache_for_gpu_frame (f);
      clear_image_cache (f, Qt);
      gl_patch_terminal_rif (f);
      gfx_warm_glyph_cache (f);
    }
  unblock_input ();

  if (!ok)
    error ("gpu-enable-for-frame: failed to initialize the OpenGL backend");

  SET_FRAME_GARBAGED (f);
  return Qt;
}

/* -----------------------------------------------------------------------
   gpu-capture-frame: write the off-screen render target to a binary PPM
   (P6).  PPM keeps this dependency-free; PIL/ImageMagick in the harness
   read it natively.  Mirrors gpu-capture-frame on macOS (which writes
   PNG via CoreGraphics).
   ----------------------------------------------------------------------- */

DEFUN ("gpu-capture-frame", Fgl_capture_frame, Sgl_capture_frame, 1, 2, 0,
       doc: /* Save the OpenGL render target for FRAME to PATH as a PPM image.
FRAME defaults to the selected frame.  Returns t on success.  The image
shows exactly what the GPU has rendered into the off-screen target.  */)
  (Lisp_Object path, Lisp_Object frame)
{
  CHECK_STRING (path);
  struct frame *f = NILP (frame) ? XFRAME (selected_frame) : XFRAME (frame);
  if (!f) return Qnil;

  int w = 0, h = 0;
  unsigned char *rgba = NULL;
  bool ok;
  block_input ();
  ok = gl_capture_frame (f, &w, &h, &rgba);
  unblock_input ();
  if (!ok || !rgba) return Qnil;

  Lisp_Object encoded = ENCODE_FILE (path);
  FILE *fp = emacs_fopen (SSDATA (encoded), "wb");
  if (!fp) { free (rgba); return Qnil; }

  fprintf (fp, "P6\n%d %d\n255\n", w, h);
  /* RGBA -> RGB, row by row (top-left origin already).  */
  for (int i = 0; i < w * h; i++)
    {
      putc (rgba[i * 4 + 0], fp);
      putc (rgba[i * 4 + 1], fp);
      putc (rgba[i * 4 + 2], fp);
    }
  bool wrote = (ferror (fp) == 0);
  fclose (fp);
  free (rgba);

  return wrote ? Qt : Qnil;
}

/* -----------------------------------------------------------------------
   gpu-transition-start / gpu-transition-tick: buffer-switch cross-fade.
   Same Lisp API names as the Metal backend so gpu.el drives both.
   ----------------------------------------------------------------------- */

DEFUN ("gpu-transition-start", Fgl_transition_start, Sgl_transition_start,
       1, 2, 0,
       doc: /* Crossfade the current frame content over the next redraw.
Snapshot what FRAME shows now and fade it out over DURATION seconds while
the new content appears underneath.  Driven by gpu.el's buffer-switch hook.
FRAME defaults to the selected frame.  Returns t if the snapshot was taken.
The argument order matches the Metal backend so gpu.el drives both.  */)
  (Lisp_Object duration, Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  CHECK_NUMBER (duration);
  struct frame *f = XFRAME (frame);
  if (!FRAME_X_P (f) && !FRAME_PGTK_P (f)) return Qnil;
  bool ok;
  block_input ();
  ok = gl_transition_start (f, XFLOATINT (duration));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-transition-tick", Fgl_transition_tick, Sgl_transition_tick,
       0, 1, 0,
       doc: /* Advance FRAME's buffer-switch cross-fade by presenting a frame.
FRAME defaults to the selected frame.  Returns t while the fade is still
running, nil once it is done.  Meant to be called from a short repeating
timer (the OpenGL backend has no display-link to drive it otherwise).  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  struct frame *f = XFRAME (frame);
  if (!FRAME_X_P (f) && !FRAME_PGTK_P (f)) return Qnil;
  bool active;
  block_input ();
  active = gl_transition_tick (f);
  unblock_input ();
  return active ? Qt : Qnil;
}

DEFUN ("gpu-transition-active-p", Fgl_transition_active_p,
       Sgl_transition_active_p, 0, 1, 0,
       doc: /* Return t while a buffer-switch cross-fade is running on FRAME.
Unlike `gpu-transition-tick' this does not present a frame or advance
the fade; it only reports its state.  FRAME defaults to the selected
frame.  Test harnesses use it to wait for a quiescent frame before
capturing the screen.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  struct frame *f = XFRAME (frame);
  if (!FRAME_X_P (f) && !FRAME_PGTK_P (f)) return Qnil;
  return gl_transition_active_p (f) ? Qt : Qnil;
}

/* -----------------------------------------------------------------------
   gpu-video-*: inline video.  Same Lisp API names as the Metal backend so
   gpu.el (gpu-video-insert, gpu-video-mode) drives both.  Only built when
   GStreamer is available.
   ----------------------------------------------------------------------- */

#ifdef HAVE_GSTREAMER

DEFUN ("gpu-video-open", Fgl_video_open, Sgl_video_open, 5, 7, 0,
       doc: /* Play video FILE over FRAME at X, Y sized WIDTH x HEIGHT pixels.
X and Y are frame-relative logical pixels (top-left origin).  GStreamer
decodes the file into RGBA frames the OpenGL driver uploads as a texture and
composites over the frame content every present; redisplay underneath
continues normally.  If LOOP is non-nil, restart playback at the end.
FRAME defaults to the selected frame.  One video per frame: opening a new
one replaces the previous.  Returns t on success.  */)
  (Lisp_Object file, Lisp_Object x, Lisp_Object y, Lisp_Object width,
   Lisp_Object height, Lisp_Object loop, Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  struct frame *f = XFRAME (frame);
  if (!FRAME_X_P (f) && !FRAME_PGTK_P (f)) return Qnil;
  CHECK_STRING (file);
  CHECK_FIXNUM (x); CHECK_FIXNUM (y);
  CHECK_FIXNUM (width); CHECK_FIXNUM (height);

  Lisp_Object expanded = Fexpand_file_name (file, Qnil);
  bool ok;
  block_input ();
  ok = gl_video_open (f, SSDATA (ENCODE_FILE (expanded)),
                      XFIXNUM (x), XFIXNUM (y),
                      XFIXNUM (width), XFIXNUM (height), !NILP (loop));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-close", Fgl_video_close, Sgl_video_close, 0, 1, 0,
       doc: /* Stop and remove the inline video on FRAME.
FRAME defaults to the selected frame.  Returns t if a video was open.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  bool ok;
  block_input ();
  ok = gl_video_close (XFRAME (frame));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-pause", Fgl_video_pause, Sgl_video_pause, 1, 2, 0,
       doc: /* Pause (PAUSED non-nil) or resume the inline video on FRAME.
FRAME defaults to the selected frame.  Returns t if a video is open.  */)
  (Lisp_Object paused, Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  bool ok;
  block_input ();
  ok = gl_video_set_paused (XFRAME (frame), !NILP (paused));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-move", Fgl_video_move, Sgl_video_move, 4, 6, 0,
       doc: /* Move/resize the inline video on FRAME to X, Y, WIDTH, HEIGHT.
Frame-relative logical pixels.  Optional CLIP is a list (LEFT TOP RIGHT
BOTTOM), also frame-relative, that confines the video to a window's
interior; nil removes clipping.  FRAME defaults to the selected frame.
Returns t if a video is open.  */)
  (Lisp_Object x, Lisp_Object y, Lisp_Object width, Lisp_Object height,
   Lisp_Object clip, Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  CHECK_FIXNUM (x); CHECK_FIXNUM (y);
  CHECK_FIXNUM (width); CHECK_FIXNUM (height);
  bool ok;
  block_input ();
  ok = gl_video_set_rect (XFRAME (frame), XFIXNUM (x), XFIXNUM (y),
                          XFIXNUM (width), XFIXNUM (height));
  if (ok)
    {
      if (CONSP (clip))
        {
          int cl = XFIXNUM (Fnth (make_fixnum (0), clip));
          int ct = XFIXNUM (Fnth (make_fixnum (1), clip));
          int cr = XFIXNUM (Fnth (make_fixnum (2), clip));
          int cb = XFIXNUM (Fnth (make_fixnum (3), clip));
          gl_video_set_clip (XFRAME (frame), cl, ct, cr - cl, cb - ct);
        }
      else
        gl_video_set_clip (XFRAME (frame), 0, 0, 0, 0);
    }
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-tick", Fgl_video_tick, Sgl_video_tick, 0, 1, 0,
       doc: /* Present a fresh frame of the inline video on FRAME.
Driven by a Lisp timer in gpu.el (the OpenGL backend has no display link to
advance it while idle).  Returns t while a video is open, nil otherwise.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  bool ok;
  block_input ();
  ok = gl_video_tick (XFRAME (frame));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-duration", Fgl_video_duration, Sgl_video_duration, 0, 1, 0,
       doc: /* Return the inline video duration on FRAME in seconds.
FRAME defaults to the selected frame.  Returns nil if there is no video or
its duration is not known yet.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  double d;
  block_input ();
  d = gl_video_duration (XFRAME (frame));
  unblock_input ();
  return d < 0 ? Qnil : make_float (d);
}

DEFUN ("gpu-video-position", Fgl_video_position, Sgl_video_position, 0, 1, 0,
       doc: /* Return the inline video playback position on FRAME in seconds.
FRAME defaults to the selected frame.  Returns nil if there is no video.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  double p;
  block_input ();
  p = gl_video_position (XFRAME (frame));
  unblock_input ();
  return p < 0 ? Qnil : make_float (p);
}

DEFUN ("gpu-video-seek", Fgl_video_seek, Sgl_video_seek, 1, 2, 0,
       doc: /* Seek the inline video on FRAME to SECONDS.
FRAME defaults to the selected frame.  Returns t if a video is open.  */)
  (Lisp_Object seconds, Lisp_Object frame)
{
  CHECK_NUMBER (seconds);
  if (NILP (frame)) frame = selected_frame;
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  bool ok;
  block_input ();
  ok = gl_video_seek (XFRAME (frame), XFLOATINT (seconds));
  unblock_input ();
  return ok ? Qt : Qnil;
}

DEFUN ("gpu-video-playing-p", Fgl_video_playing_p, Sgl_video_playing_p,
       0, 1, 0,
       doc: /* Return t if the inline video on FRAME is playing.
Return nil if it is paused or there is no video.  FRAME defaults to the
selected frame.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  int s;
  block_input ();
  s = gl_video_playing (XFRAME (frame));
  unblock_input ();
  return s == 1 ? Qt : Qnil;
}

DEFUN ("gpu-video-size", Fgl_video_size, Sgl_video_size, 0, 1, 0,
       doc: /* Return the natural size of the inline video on FRAME.
The value is a cons (WIDTH . HEIGHT) in pixels, or nil if there is no video
or its size is not known yet.  FRAME defaults to the selected frame.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  double w = 0, h = 0;
  bool ok;
  block_input ();
  ok = gl_video_size (XFRAME (frame), &w, &h);
  unblock_input ();
  return ok ? Fcons (make_float (w), make_float (h)) : Qnil;
}

#endif /* HAVE_GSTREAMER */

/* -----------------------------------------------------------------------
   gpu-cursor-* / gpu-animations: cursor animation overlay.  Same Lisp API
   names as the Metal backend so gpu.el drives both.
   ----------------------------------------------------------------------- */

DEFUN ("gpu-opengl-p", Fgl_opengl_p, Sgl_opengl_p, 0, 0, 0,
       doc: /* Return t: this build uses the OpenGL GPU backend.
Lets gpu.el pick GNU/Linux-specific defaults (e.g. the cursor effect).  */)
  (void)
{
  return Qt;
}

DEFUN ("gpu-cursor-mode", Fgl_cursor_mode, Sgl_cursor_mode, 1, 1, 0,
       doc: /* Set the cursor animation MODE (an integer 0..7).
0 block, 1 spring, 2 torpedo, 3 sonicboom, 4 ripple, 5 pixiedust,
6 hollow, 7 beam.  Returns MODE.  */)
  (Lisp_Object mode)
{
  CHECK_FIXNUM (mode);
  gl_cursor_set_mode (XFIXNUM (mode));
  return mode;
}

DEFUN ("gpu-scroll-effect", Fgl_scroll_effect, Sgl_scroll_effect, 1, 1, 0,
       doc: /* Accept a scroll-easing EFFECT for API parity with Metal.
The OpenGL backend's scroll_run is an instant pixel-exact blit (no eased
scroll animation yet), so this is a no-op; returns EFFECT.  */)
  (Lisp_Object effect)
{
  return effect;
}

DEFUN ("gpu-scroll-duration", Fgl_scroll_duration, Sgl_scroll_duration, 1, 1, 0,
       doc: /* Accept a scroll DURATION for API parity with Metal (no-op).  */)
  (Lisp_Object duration)
{
  return duration;
}

DEFUN ("gpu-trail-length", Fgl_trail_length, Sgl_trail_length, 1, 1, 0,
       doc: /* Set the torpedo cursor trail LENGTH (1..40).  Returns LENGTH.  */)
  (Lisp_Object length)
{
  CHECK_FIXNUM (length);
  gl_cursor_set_trail_len (XFIXNUM (length));
  return length;
}

DEFUN ("gpu-cursor-suppress-effects", Fgl_cursor_suppress, Sgl_cursor_suppress,
       1, 1, 0,
       doc: /* When SUPPRESS is non-nil, skip cursor effects on the next
placement (set per-command so typing does not spray bursts/trails).  */)
  (Lisp_Object suppress)
{
  gl_cursor_set_suppress (!NILP (suppress));
  return suppress;
}

DEFUN ("gpu-animations", Fgl_animations, Sgl_animations, 0, 1, 0,
       doc: /* Enable (ENABLE non-nil) or disable the cursor animation layer.
With no argument, return the current state.  */)
  (Lisp_Object enable)
{
  if (!NILP (enable) || EQ (enable, Qnil))
    gl_animations_set_enabled (!NILP (enable));
  return gl_animations_get_enabled () ? Qt : Qnil;
}

DEFUN ("gpu-anim-tick", Fgl_anim_tick, Sgl_anim_tick, 0, 2, 0,
       doc: /* Advance the cursor animations one step and present.
DT is the step in seconds (default 0.033).  Driven by a Lisp timer (EGL
has no display link).  FRAME defaults to the selected frame.  Returns t
while animations are enabled, nil otherwise.  */)
  (Lisp_Object dt, Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  if (!FRAME_LIVE_P (XFRAME (frame))) return Qnil;
  struct frame *f = XFRAME (frame);
  if (!FRAME_X_P (f) && !FRAME_PGTK_P (f)) return Qnil;
  double step = NILP (dt) ? 0.033 : XFLOATINT (dt);
  bool on;
  block_input ();
  on = gl_anim_tick (f, step);
  unblock_input ();
  return on ? Qt : Qnil;
}

DEFUN ("gpu-pump-tick", Fgl_pump_tick, Sgl_pump_tick, 0, 1, 0,
       doc: /* Advance every continuous GPU animation on FRAME one step.
Single pump behind gpu.el's animation timer: the cursor effects, the
buffer-switch cross-fade and the inline video all advance together and
the driver presents at most one frame per tick, which keeps the present
rate bounded no matter how many animation sources run at once.  FRAME
defaults to the selected frame.  Returns a mask of the subsystems that
still need pumping (1 = cursor animations enabled, 2 = cross-fade
running, 4 = video open); 0 lets the timer cancel itself.  */)
  (Lisp_Object frame)
{
  if (NILP (frame)) frame = selected_frame;
  if (!FRAME_LIVE_P (XFRAME (frame))) return make_fixnum (0);
  struct frame *f = XFRAME (frame);
  if (!FRAME_X_P (f) && !FRAME_PGTK_P (f)) return make_fixnum (0);
  int mask;
  block_input ();
  mask = gl_pump_tick (f);
  unblock_input ();
  return make_fixnum (mask);
}

DEFUN ("gpu-animation-status", Fgl_animation_status, Sgl_animation_status,
       0, 0, 0,
       doc: /* Return a description of the cursor animation state.  */)
  (void)
{
  return list2 (Fcons (Qt, gl_animations_get_enabled () ? Qt : Qnil),
                make_fixnum (gl_cursor_get_mode ()));
}

/* -----------------------------------------------------------------------
   Initialization
   ----------------------------------------------------------------------- */

void
syms_of_glfns (void)
{
  defsubr (&Sgl_backend_p);
  defsubr (&Sgl_device_name);
  defsubr (&Sgl_display_type);
  defsubr (&Sgl_enable_for_frame);
  defsubr (&Sgl_capture_frame);
  defsubr (&Sgl_transition_start);
  defsubr (&Sgl_transition_tick);
  defsubr (&Sgl_transition_active_p);
  defsubr (&Sgl_opengl_p);
  defsubr (&Sgl_cursor_mode);
  defsubr (&Sgl_scroll_effect);
  defsubr (&Sgl_scroll_duration);
  defsubr (&Sgl_trail_length);
  defsubr (&Sgl_cursor_suppress);
  defsubr (&Sgl_animations);
  defsubr (&Sgl_anim_tick);
  defsubr (&Sgl_pump_tick);
  defsubr (&Sgl_animation_status);
#ifdef HAVE_GSTREAMER
  defsubr (&Sgl_video_open);
  defsubr (&Sgl_video_close);
  defsubr (&Sgl_video_pause);
  defsubr (&Sgl_video_move);
  defsubr (&Sgl_video_tick);
  defsubr (&Sgl_video_duration);
  defsubr (&Sgl_video_position);
  defsubr (&Sgl_video_seek);
  defsubr (&Sgl_video_playing_p);
  defsubr (&Sgl_video_size);
#endif
}

#endif /* HAVE_GFX_GL */
