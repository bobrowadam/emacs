/* glterm.h --- public interface of the OpenGL gfx driver (glterm.c).
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

#ifndef EMACS_GLTERM_H
#define EMACS_GLTERM_H

#include <stdbool.h>

struct frame;

/* Bring up the EGL context; true when the GL backend is usable.  */
extern bool gl_backend_available (void);

/* Return a static string naming the active EGL display type:
   "surfaceless", "x11", or "wayland".  */
extern const char *gl_display_type_name (void);

/* Enable the GL backend on F (context + per-frame target + driver).  */
extern bool gl_enable_for_frame (struct frame *f);

/* Patch the X terminal's redisplay hooks to the neutral gfx policy.  */
extern void gl_patch_terminal_rif (struct frame *f);

/* Read the off-screen render target of F back as RGBA8, top-left origin;
   the caller frees *OUT.  */
extern bool gl_capture_frame (struct frame *f, int *w, int *h,
                              unsigned char **out);

/* Drop F's per-frame GL data (call from the X frame teardown).  */
extern void gl_free_frame_data (struct frame *f);

/* Buffer-switch cross-fade: snapshot the previous frame and arm the fade
   (DURATION seconds), then advance it from a Lisp timer.  */
extern bool gl_transition_start (struct frame *f, double duration);
extern bool gl_transition_tick (struct frame *f);
extern bool gl_transition_active_p (struct frame *f);
extern bool gl_frame_active_p (struct frame *f);

/* Single animation pump (gpu-pump-tick): advance cursor effects, the
   cross-fade and the inline video together and present at most once.
   Returns a mask of the subsystems that still need pumping.  */
enum
{
  GL_PUMP_ANIM  = 1,            /* cursor animation layer enabled */
  GL_PUMP_FADE  = 2,            /* buffer cross-fade running */
  GL_PUMP_VIDEO = 4,            /* inline video open */
};
extern int gl_pump_tick (struct frame *f);

/* Cursor animation overlay (gpu-cursor-mode / gpu-animations / gpu-anim-tick).
   Spring glide, comet trail and particle bursts composited in the present.  */
extern bool gl_anim_tick (struct frame *f, double dt);
extern void gl_cursor_set_mode (int mode);
extern int  gl_cursor_get_mode (void);
extern void gl_cursor_set_trail_len (int len);
extern void gl_cursor_set_suppress (bool suppress);
extern void gl_animations_set_enabled (bool on);
extern bool gl_animations_get_enabled (void);

#ifdef HAVE_GSTREAMER
/* Inline video (gpu-video-*).  GStreamer decodes FILE into RGBA frames the
   present composites over the frame at the given rect (see glterm.c).  */
extern bool gl_video_open (struct frame *f, const char *path, int x, int y,
                           int w, int h, bool loop);
extern bool gl_video_close (struct frame *f);
extern bool gl_video_set_paused (struct frame *f, bool paused);
extern bool gl_video_set_rect (struct frame *f, int x, int y, int w, int h);
extern bool gl_video_set_clip (struct frame *f, int x, int y, int w, int h);
extern bool gl_video_tick (struct frame *f);
extern double gl_video_duration (struct frame *f);
extern double gl_video_position (struct frame *f);
extern bool gl_video_seek (struct frame *f, double seconds);
extern int gl_video_playing (struct frame *f);
extern bool gl_video_size (struct frame *f, double *w, double *h);
#endif /* HAVE_GSTREAMER */

#endif /* EMACS_GLTERM_H */
