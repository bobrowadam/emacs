;;; gpu.el --- Metal GPU backend configuration for GNU Emacs on macOS -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Andros Fenollosa
;; Version: 0.3.1
;; Package-Requires: ((emacs "30.1"))
;; Keywords: hardware, display, macos, metal, gpu
;; URL: https://github.com/tanrax/emacs-gpu

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.

;;; Commentary:

;; This module provides user-facing configuration for the Metal GPU
;; display backend (emacs-gpu).
;;
;; The Metal backend replaces CoreGraphics rendering with Apple Metal
;; for GPU-accelerated text, cursor animations, and scroll effects.
;;
;; Usage:
;;
;;   ;; Enable Metal on the current frame
;;   (gpu-enable)
;;
;;   ;; Configure cursor animation
;;   (setq gpu-cursor-animation 'spring)  ;; or 'torpedo, 'pixiedust, etc.
;;
;;   ;; Configure scroll easing
;;   (setq gpu-scroll-easing 'ease-out-quad)
;;
;; Cursor modes:
;;   block       Static filled rectangle (fastest)
;;   spring      Critically-damped spring (smooth, default)
;;   torpedo     Trail of past positions
;;   sonicboom   Expanding ring on jump
;;   ripple      3 concentric expanding rings
;;   pixiedust   Radial particle burst
;;   hollow      Outline box
;;   beam        Thin vertical bar
;;
;; Scroll easing:
;;   none         Instant jump
;;   linear       Constant speed
;;   ease-out-quad Decelerate (default)
;;   ease-out-cubic Stronger deceleration
;;   spring        Spring physics
;;   ease-in-out-cubic S-curve

;;; Code:

;; Primitives implemented in C (src/mtlfns.m); declared here so the byte
;; compiler knows their arity when this file is built without the backend.
(declare-function gpu-backend-p "mtlfns.m" ())
(declare-function gpu-device-name "mtlfns.m" ())
(declare-function gpu-enable-for-frame "mtlfns.m" (frame))
(declare-function gpu-cursor-mode "mtlfns.m" (mode))
(declare-function gpu-scroll-effect "mtlfns.m" (effect))
(declare-function gpu-scroll-duration "mtlfns.m" (duration))
(declare-function gpu-trail-length "mtlfns.m" (length))
(declare-function gpu-animations "mtlfns.m" (&optional enable))
(declare-function gpu-animation-status "mtlfns.m" ())

(defgroup gpu nil
  "Metal GPU display backend for GNU Emacs on macOS."
  :group 'display
  :prefix "gpu-"
  :link '(url-link "https://github.com/tanrax/emacs-gpu"))

;; ---------------------------------------------------------------------------
;; Helper functions (must be defined before defcustom :set functions use them)

(defun gpu--cursor-mode-number (mode)
  "Convert cursor MODE symbol to integer for `gpu-cursor-mode'."
  (pcase mode
    ('block    0)
    ('spring   1)
    ('torpedo  2)
    ('sonicboom 3)
    ('ripple   4)
    ('pixiedust 5)
    ('hollow   6)
    ('beam     7)
    (_ 1)))

(defun gpu--scroll-easing-number (easing)
  "Convert EASING symbol to integer for `gpu-scroll-effect'."
  (pcase easing
    ('none            0)
    ('linear          1)
    ('ease-out-quad   2)
    ('ease-out-cubic  3)
    ('spring          4)
    ('ease-in-out-cubic 5)
    (_ 2)))

(defvar gpu--anim-timer nil
  "30fps timer driving cursor animations while they are enabled.")

(defun gpu--anim-pump ()
  "Advance GPU cursor animations; cancel the timer when they turn off."
  (unless (and (fboundp 'gpu-anim-tick) (gpu-anim-tick))
    (when (timerp gpu--anim-timer) (cancel-timer gpu--anim-timer))
    (setq gpu--anim-timer nil)))

(defun gpu--anim-pump-start ()
  "Start the animation pump timer (idempotent).
Emacs's event loop starves the CADisplayLink while idle, so without
this Lisp timer the cursor effects only animate during user input."
  (unless (timerp gpu--anim-timer)
    (setq gpu--anim-timer (run-at-time 0 0.033 #'gpu--anim-pump))))

;; Old names (pre-0.2) for the customs defined below.
(define-obsolete-variable-alias 'mtl-animations-enabled 'gpu-animations-enabled "0.2")
(define-obsolete-variable-alias 'mtl-buffer-transitions 'gpu-buffer-transitions "0.2")
(define-obsolete-variable-alias 'mtl-buffer-transition-duration 'gpu-buffer-transition-duration "0.2")
(define-obsolete-variable-alias 'mtl-cursor-animation 'gpu-cursor-animation "0.2")
(define-obsolete-variable-alias 'mtl-enable-on-startup 'gpu-enable-on-startup "0.2")

;; ---------------------------------------------------------------------------
;; Customizable variables

(defcustom gpu-cursor-animation (if (fboundp 'gpu-opengl-p) 'sonicboom 'block)
  "Cursor animation mode for the GPU backend.
Defaults to `sonicboom' on the OpenGL (GNU/Linux) backend and `block'
on Metal (macOS).
Possible values:
  `block'      Static filled rectangle, no effect
  `spring'     Critically-damped spring physics
  `torpedo'    Trail of last N cursor positions
  `sonicboom'  Expanding ring when cursor jumps far
  `ripple'     Three concentric expanding rings
  `pixiedust'  Radial particle burst on jump
  `hollow'     Hollow outline box
  `beam'       Thin vertical bar"
  :type '(choice (const :tag "Block (static, default)" block)
                 (const :tag "Spring (smooth)" spring)
                 (const :tag "Torpedo (trail)" torpedo)
                 (const :tag "Sonicboom (ring)" sonicboom)
                 (const :tag "Ripple (3 rings)" ripple)
                 (const :tag "Pixiedust (particles)" pixiedust)
                 (const :tag "Hollow (outline)" hollow)
                 (const :tag "Beam (bar)" beam))
  :set (lambda (sym val)
         (set-default sym val)
         ;; Propagate to the live driver so the change takes effect at
         ;; runtime, not only on the next `gpu-enable'.
         (when (fboundp 'gpu-cursor-mode)
           (gpu-cursor-mode (gpu--cursor-mode-number val))))
  :group 'gpu)

(defcustom gpu-scroll-easing 'ease-out-quad
  "Scroll animation easing for the Metal GPU backend."
  :type '(choice (const :tag "None (instant)" none)
                 (const :tag "Linear" linear)
                 (const :tag "Ease out quad (default)" ease-out-quad)
                 (const :tag "Ease out cubic" ease-out-cubic)
                 (const :tag "Spring" spring)
                 (const :tag "Ease in-out cubic" ease-in-out-cubic))
  :set #'set-default
  :group 'gpu)

(defcustom gpu-scroll-duration 0.15
  "Scroll animation duration in seconds (0.0 to 2.0).
Lower values are snappier; higher values are more fluid."
  :type 'float
  :set #'set-default
  :group 'gpu)

(defcustom gpu-trail-length 20
  "Length of the cursor trail in torpedo mode (1-40)."
  :type 'integer
  :set #'set-default
  :group 'gpu)

(defcustom gpu-cursor-effects-while-typing nil
  "If non-nil, the cursor effects also fire while typing.
By default they are suppressed during text-editing commands (see
`gpu-cursor-typing-commands'), so only cursor movement and jumps
trigger the rings, bursts and trail.  This keeps the effects from
flashing on every inserted or deleted character."
  :type 'boolean
  :set #'set-default
  :group 'gpu)

(defcustom gpu-cursor-typing-commands
  '(self-insert-command
    org-self-insert-command
    newline newline-and-indent electric-newline-and-maybe-indent
    open-line
    delete-char delete-backward-char backward-delete-char
    backward-delete-char-untabify delete-forward-char
    yank yank-pop)
  "Commands treated as typing/editing for cursor effects.
When `gpu-cursor-effects-while-typing' is nil, the motion cursor
effects do not fire after these commands.  A command also counts as
typing when its symbol has a non-nil `gpu-typing-command' property."
  :type '(repeat function)
  :set #'set-default
  :group 'gpu)

(defcustom gpu-animations-enabled t
  "If non-nil, enable the Metal GPU animation layer.
When nil (the default), the cursor is drawn directly into the static
texture like the NS backend and no compositor overlay is drawn, which is
the correct, flicker-free baseline.  Enable this to turn on the animated
cursor effects, particles and the 60fps compositor."
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'gpu-animations)
           (gpu-animations val)
           (when val (gpu--anim-pump-start))))
  :group 'gpu)

(defcustom gpu-enable-on-startup nil
  "If non-nil, enable Metal GPU rendering on the initial frame at startup."
  :type 'boolean
  :group 'gpu)

;; ---------------------------------------------------------------------------
;; Typing vs. movement detection for the cursor effects

(defun gpu--cursor-typing-p ()
  "Non-nil if `this-command' is a typing/editing command.
See `gpu-cursor-typing-commands'."
  (let ((cmd this-command))
    (and (symbolp cmd)
         (or (memq cmd gpu-cursor-typing-commands)
             (get cmd 'gpu-typing-command)))))

(defun gpu--cursor-pre-command ()
  "Tell the driver whether the upcoming command is typing or movement.
Runs from `pre-command-hook' so the next cursor placement knows whether
to fire the motion effects.  See `gpu-cursor-effects-while-typing'."
  (when (fboundp 'gpu-cursor-suppress-effects)
    (gpu-cursor-suppress-effects
     (and (not gpu-cursor-effects-while-typing)
          (gpu--cursor-typing-p)))))

;; ---------------------------------------------------------------------------
;; Public API

;;;###autoload
(defun gpu-enable (&optional frame)
  "Enable Metal GPU rendering on FRAME (default: selected frame).
Adds a CAMetalLayer on top of the EmacsView and replaces the
CoreGraphics rendering pipeline with Metal shaders.

After this call, all redisplay for FRAME goes through the Metal GPU.
The NS backend still handles events, menus, and scrollbars."
  (interactive)
  (unless (fboundp 'gpu-backend-p)
    (error "gpu-enable: GPU backend not compiled in (build with --with-gpu)"))
  (unless (gpu-backend-p)
    (error "gpu-enable: GPU backend is not available on this system"))
  (let ((f (or frame (selected-frame))))
    (unless (framep f)
      (error "gpu-enable: argument is not a frame"))
    (gpu-enable-for-frame f)
    ;; Buffer-switch cross-fade: both backends expose `gpu-transition-start',
    ;; so wire the watcher whenever it is available.
    (when (fboundp 'gpu-transition-start)
      (add-hook 'pre-redisplay-functions #'gpu--transition-watch))
    ;; Cursor effects, scroll easing and the animation layer; apply only
    ;; when the backend exposes their primitives (Metal and OpenGL both do).
    (if (fboundp 'gpu-cursor-mode)
        (progn
          (gpu-cursor-mode (gpu--cursor-mode-number gpu-cursor-animation))
          (gpu-scroll-effect (gpu--scroll-easing-number gpu-scroll-easing))
          (gpu-scroll-duration gpu-scroll-duration)
          (gpu-trail-length gpu-trail-length)
          (gpu-animations gpu-animations-enabled)
          (when gpu-animations-enabled (gpu--anim-pump-start))
          ;; Distinguish typing from cursor movement for the effects.
          (add-hook 'pre-command-hook #'gpu--cursor-pre-command)
          (message "GPU enabled on frame: %s (device: %s, animations: %s)"
                   f (gpu-device-name) (if gpu-animations-enabled "on" "off")))
      (message "GPU enabled on frame: %s (device: %s)" f (gpu-device-name)))))

;;;###autoload
(defun gpu-toggle-animations ()
  "Toggle the Metal GPU animation layer on or off."
  (interactive)
  (setopt gpu-animations-enabled (not gpu-animations-enabled))
  (when gpu-animations-enabled (gpu--anim-pump-start))
  (message "Metal animations %s" (if gpu-animations-enabled "enabled" "disabled")))

;;;###autoload
(defun gpu-status ()
  "Display current Metal GPU backend status in the minibuffer."
  (interactive)
  (if (not (fboundp 'gpu-backend-p))
      (message "GPU backend not compiled (build with --with-gpu)")
    (if (not (gpu-backend-p))
        (message "GPU backend not available on this system")
      ;; The OpenGL backend has no animation layer, so report just the
      ;; device; the Metal backend reports the full animation state.
      (if (not (fboundp 'gpu-animation-status))
          (message "GPU backend: %s" (gpu-device-name))
        (let ((status (gpu-animation-status)))
          (message "Metal GPU: %s | Animations: %s | Cursor: %s | Scroll: %s (%.2fs)"
                   (gpu-device-name)
                   (if (cdr (assq 'animations status)) "on" "off")
                   (nth (cdr (assq 'cursor-mode status))
                        '(block spring torpedo sonicboom ripple pixiedust hollow beam))
                   (nth (cdr (assq 'scroll-easing status))
                        '(none linear ease-out-quad ease-out-cubic spring ease-in-out-cubic))
                   (cdr (assq 'scroll-duration status))))))))

;;;###autoload
(defun gpu-set-cursor (mode)
  "Interactively set cursor animation MODE."
  (interactive
   (list (intern (completing-read "Cursor mode: "
                                  '("block" "spring" "torpedo" "sonicboom"
                                    "ripple" "pixiedust" "hollow" "beam")
                                  nil t))))
  (setopt gpu-cursor-animation mode)
  (message "GPU cursor mode: %s" mode))

;;;###autoload
(defun gpu-set-scroll (easing)
  "Interactively set scroll EASING."
  (interactive
   (list (intern (completing-read "Scroll easing: "
                                  '("none" "linear" "ease-out-quad"
                                    "ease-out-cubic" "spring" "ease-in-out-cubic")
                                  nil t))))
  (setopt gpu-scroll-easing easing))

;; ---------------------------------------------------------------------------
;; Buffer-switch transitions

(defcustom gpu-buffer-transitions t
  "When non-nil, cross-fade the old content when a window changes buffer.
The previous frame content fades out over
`gpu-buffer-transition-duration' seconds while the new buffer appears
underneath.  Rendered entirely by the GPU compositor."
  :type 'boolean
  :group 'gpu)

(defcustom gpu-buffer-transition-duration 0.15
  "Seconds a buffer-switch cross-fade takes."
  :type 'number
  :group 'gpu)

(defvar gpu--transition-armed nil
  "Non-nil while a snapshot was already taken for the ongoing redisplay.")

(defvar gpu--gl-trans-timer nil
  "Timer presenting the OpenGL backend's cross-fade while it runs.")

(defun gpu--gl-trans-pump (frame)
  "Advance the OpenGL cross-fade on FRAME; cancel the timer when it ends.
The Metal backend has its own display-link pump (`gpu--anim-pump'); the
OpenGL backend has none, so a Lisp timer re-presents each fade frame."
  (unless (and (frame-live-p frame)
               (fboundp 'gpu-transition-tick)
               (gpu-transition-tick frame))
    (when (timerp gpu--gl-trans-timer) (cancel-timer gpu--gl-trans-timer))
    (setq gpu--gl-trans-timer nil)))

(defun gpu--transition-pump-start (frame)
  "Start the right cross-fade pump for the active backend on FRAME."
  (cond
   ((fboundp 'gpu-anim-tick) (gpu--anim-pump-start))   ; Metal
   ((fboundp 'gpu-transition-tick)                     ; OpenGL
    (unless (timerp gpu--gl-trans-timer)
      (setq gpu--gl-trans-timer
            (run-at-time 0 0.016 #'gpu--gl-trans-pump frame))))))

(defun gpu--transition-watch (window)
  "Start a cross-fade when WINDOW is about to display another buffer.
Runs from `pre-redisplay-functions', before the new content is painted,
so the GPU snapshot still holds the old pixels."
  (when (and gpu-buffer-transitions
             (not (window-minibuffer-p window))
             (fboundp 'gpu-transition-start))
    (let ((old (window-parameter window 'gpu--last-buffer))
          (new (window-buffer window)))
      (when (and old (not (eq old new)) (not gpu--transition-armed))
        (setq gpu--transition-armed t)
        (run-at-time 0 nil (lambda () (setq gpu--transition-armed nil)))
        (ignore-errors
          (when (gpu-transition-start (float gpu-buffer-transition-duration)
                                      (window-frame window))
            (gpu--transition-pump-start (window-frame window)))))
      (set-window-parameter window 'gpu--last-buffer new))))

;; ---------------------------------------------------------------------------
;; Inline video

(defvar gpu--video-state nil
  "Active inline video: (MARKER WIDTH HEIGHT TIMER FRAME), or nil.")

(defun gpu--video-sync ()
  "Track the video placeholder: move/clip the GPU rect and present a frame.
Runs on a 30fps timer started by `gpu-video-insert'.  Follows scrolling
and window changes; hides the video while its position is off-screen."
  (when gpu--video-state
    (pcase-let ((`(,marker ,w ,h ,_timer ,frame) gpu--video-state))
      (if (not (and (frame-live-p frame) (marker-buffer marker)))
          (gpu-video-stop)
        (let* ((win (get-buffer-window (marker-buffer marker) frame))
               (vis (and win (pos-visible-in-window-p marker win t))))
          (if (not (and vis (listp vis)))
              ;; Not visible: park the rect off-screen but keep decoding.
              (gpu-video-move 0 -32768 w h nil frame)
            (let* ((edges (window-inside-pixel-edges win))
                   (x (+ (nth 0 edges) (nth 0 vis)))
                   (y (+ (nth 1 edges) (nth 1 vis))))
              (gpu-video-move x y w h edges frame)))
          (gpu-video-tick frame))))))

;;;###autoload
(defun gpu-video-insert (file width height &optional loop)
  "Insert a WIDTH x HEIGHT placeholder at point and play video FILE over it.
The placeholder is a space with a pixel-sized display spec; the GPU
composites the video at its position every frame, following scrolling
\(clipped to the window interior).  With LOOP non-nil, restart playback
at the end.  One video per frame; a previous one is replaced."
  (interactive "fVideo file: \nnWidth (px): \nnHeight (px): ")
  (gpu-video-stop)
  (insert (propertize " "
                      'display `(space :width (,width) :height (,height))
                      'gpu-video file))
  (let ((marker (copy-marker (1- (point)))))
    ;; Park off-screen; the first sync tick positions it for real.
    (unless (gpu-video-open file 0 -32768 width height loop)
      (error "Cannot open video file %s" file))
    (setq gpu--video-state
          (list marker width height
                (run-at-time 0 0.033 #'gpu--video-sync)
                (selected-frame)))))

;;;###autoload
(defun gpu-video-stop ()
  "Stop and remove the inline video, canceling its sync timer."
  (interactive)
  (when gpu--video-state
    (pcase-let ((`(,_marker ,_w ,_h ,timer ,frame) gpu--video-state))
      (when (timerp timer) (cancel-timer timer))
      (when (frame-live-p frame) (gpu-video-close frame)))
    (setq gpu--video-state nil)))

;; ---------------------------------------------------------------------------
;; Video file buffers (gpu-video-mode)

(require 'svg)

(declare-function gpu-video-open "mtlfns.m"
                  (file x y width height &optional loop frame))
(declare-function gpu-video-close "mtlfns.m" (&optional frame))
(declare-function gpu-video-pause "mtlfns.m" (paused &optional frame))
(declare-function gpu-video-move "mtlfns.m"
                  (x y width height &optional clip frame))
(declare-function gpu-video-tick "mtlfns.m" (&optional frame))
(declare-function gpu-video-duration "mtlfns.m" (&optional frame))
(declare-function gpu-video-position "mtlfns.m" (&optional frame))
(declare-function gpu-video-seek "mtlfns.m" (seconds &optional frame))
(declare-function gpu-video-playing-p "mtlfns.m" (&optional frame))
(declare-function gpu-video-size "mtlfns.m" (&optional frame))

(defcustom gpu-video-file-extensions '("mp4" "mov" "m4v" "3gp")
  "File extensions opened in `gpu-video-mode'.
These are the container formats decoded by the active backend (AVFoundation
on macOS, GStreamer on GNU/Linux).  Changing this takes effect on the next
call to `gpu-video-register-auto-mode'."
  :type '(repeat string)
  :group 'gpu)

(defcustom gpu-video-seek-step 5
  "Seconds to jump with `gpu-video-seek-forward' and `gpu-video-seek-backward'."
  :type 'number
  :group 'gpu)

(defvar-local gpu-video--file nil
  "Path of the video played in this buffer.")
(defvar-local gpu-video--frame nil
  "Frame that owns this buffer's video player.")
(defvar-local gpu-video--timer nil
  "Per-buffer sync timer for `gpu-video-mode'.")
(defvar-local gpu-video--vid-marker nil
  "Marker at the video placeholder character.")
(defvar-local gpu-video--ctrl-start nil
  "Marker where the control area begins.")
(defvar-local gpu-video--width 16
  "Current width in pixels of the video rectangle.")
(defvar-local gpu-video--height 16
  "Current height in pixels of the video rectangle.")
(defvar-local gpu-video--paused nil
  "Non-nil when the user has paused this buffer's video.")
(defvar-local gpu-video--last-draw 0.0
  "`float-time' of the last control redraw (throttling).")

(defun gpu-video--format-time (secs)
  "Format SECS as MM:SS, or \"--:--\" when SECS is nil or negative."
  (if (and (numberp secs) (>= secs 0))
      (let ((s (floor secs)))
        (format "%02d:%02d" (/ s 60) (% s 60)))
    "--:--"))

(defun gpu-video--bar-svg (width fraction)
  "Return an SVG progress bar WIDTH pixels wide, FRACTION (0..1) filled."
  (let* ((w (max 1 width))
         (h 16)
         (cy (/ h 2))
         (track 4)
         (fillw (max 0 (min w (round (* w (or fraction 0))))))
         (svg (svg-create w h)))
    (svg-rectangle svg 0 (- cy (/ track 2)) w track
                   :rx 2 :fill "#808080" :fill-opacity 0.4)
    (when (> fillw 0)
      (svg-rectangle svg 0 (- cy (/ track 2)) fillw track
                     :rx 2 :fill "#4ea1ff"))
    (svg-circle svg fillw cy 5 :fill "#4ea1ff")
    (svg-image svg :scale 1 :ascent 'center)))

(defvar gpu-video--button-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'gpu-video-toggle-play)
    (define-key m [follow-link] 'mouse-face)
    m)
  "Keymap on the play/pause button.")

(defvar gpu-video--bar-map
  (let ((m (make-sparse-keymap)))
    (define-key m [down-mouse-1] #'gpu-video--bar-drag)
    m)
  "Keymap on the timeline bar.")

(defun gpu-video--draw-controls (buf)
  "Rebuild the control area (play/pause, time, timeline) of BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and gpu-video--ctrl-start
                 (marker-position gpu-video--ctrl-start))
        (let* ((inhibit-read-only t)
               (frame gpu-video--frame)
               (pos (and (frame-live-p frame) (gpu-video-position frame)))
               (dur (and (frame-live-p frame) (gpu-video-duration frame)))
               (playing (and (frame-live-p frame) (gpu-video-playing-p frame)))
               (frac (if (and pos dur (> dur 0)) (/ pos dur) 0)))
          (save-excursion
            (goto-char gpu-video--ctrl-start)
            (delete-region gpu-video--ctrl-start (point-max))
            (insert (propertize (if playing " ⏸ " " ▶ ")
                                'face 'mode-line-emphasis
                                'mouse-face 'highlight
                                'pointer 'hand
                                'keymap gpu-video--button-map
                                'help-echo "Play/pause (SPC)"))
            (insert "   "
                    (gpu-video--format-time pos) " / "
                    (gpu-video--format-time dur)
                    "\n")
            (if (and (display-graphic-p) (image-type-available-p 'svg))
                (let ((start (point)))
                  (insert-image (gpu-video--bar-svg gpu-video--width frac) "-")
                  (put-text-property start (point) 'keymap gpu-video--bar-map)
                  (put-text-property start (point) 'pointer 'hand)
                  (put-text-property start (point)
                                     'help-echo "Click or drag to seek"))
              ;; Text fallback (no pixel-precise seeking).
              (let ((cols (max 1 (/ gpu-video--width
                                    (max 1 (frame-char-width frame))))))
                (insert (make-string (round (* cols frac)) ?=)
                        (make-string (- cols (round (* cols frac))) ?-)))))
          (set-buffer-modified-p nil))))))

(defun gpu-video--seek-posn (posn)
  "Seek the video to the timeline position described by POSN."
  (let* ((xy (posn-object-x-y posn))
         (dur (and (frame-live-p gpu-video--frame)
                   (gpu-video-duration gpu-video--frame))))
    (when (and xy dur (> gpu-video--width 0))
      (let ((frac (max 0.0 (min 1.0 (/ (float (car xy)) gpu-video--width)))))
        (gpu-video-seek (* frac dur) gpu-video--frame)))))

(defun gpu-video--bar-drag (event)
  "Seek on click and follow the pointer while dragging the timeline.
EVENT is the initiating down-mouse event."
  (interactive "e")
  (gpu-video--seek-posn (event-start event))
  (track-mouse
    (let (ev)
      (while (and (setq ev (read-event))
                  (mouse-movement-p ev))
        (gpu-video--seek-posn (event-start ev)))))
  (gpu-video--draw-controls (current-buffer)))

(defun gpu-video-toggle-play ()
  "Toggle play/pause of the video in the current buffer."
  (interactive)
  (let* ((frame gpu-video--frame)
         (playing (and (frame-live-p frame) (gpu-video-playing-p frame))))
    (setq gpu-video--paused playing)
    (when (frame-live-p frame)
      (gpu-video-pause playing frame))
    (gpu-video--draw-controls (current-buffer))))

(defun gpu-video--relative-seek (delta)
  "Seek DELTA seconds relative to the current position."
  (let ((pos (and (frame-live-p gpu-video--frame)
                  (gpu-video-position gpu-video--frame))))
    (when pos
      (gpu-video-seek (max 0 (+ pos delta)) gpu-video--frame)
      (gpu-video--draw-controls (current-buffer)))))

(defun gpu-video-seek-forward (&optional n)
  "Jump forward by N times `gpu-video-seek-step' seconds (N defaults to 1)."
  (interactive "p")
  (gpu-video--relative-seek (* (or n 1) gpu-video-seek-step)))

(defun gpu-video-seek-backward (&optional n)
  "Jump backward by N times `gpu-video-seek-step' seconds (N defaults to 1)."
  (interactive "p")
  (gpu-video--relative-seek (- (* (or n 1) gpu-video-seek-step))))

(defun gpu-video-seek-start ()
  "Seek to the beginning of the video."
  (interactive)
  (when (frame-live-p gpu-video--frame)
    (gpu-video-seek 0 gpu-video--frame)
    (gpu-video--draw-controls (current-buffer))))

(defun gpu-video--fit (buf win frame)
  "Size and position BUF's video rectangle inside WIN on FRAME.
Fits the window width, reserving room for the controls and keeping the
video's natural aspect ratio when known."
  (with-current-buffer buf
    (let* ((edges (window-inside-pixel-edges win))
           (wpix (- (nth 2 edges) (nth 0 edges)))
           (hpix (- (nth 3 edges) (nth 1 edges)))
           (ch (frame-char-height frame))
           (avail-h (max 16 (- hpix (* 3 ch))))
           (natural (gpu-video-size frame))
           (aspect (if (and natural (> (cdr natural) 0))
                       (/ (float (car natural)) (cdr natural))
                     (/ 16.0 9.0)))
           (tw (max 1 wpix))
           (th (max 1 (round (/ tw aspect)))))
      (when (> th avail-h)
        (setq th avail-h
              tw (max 1 (round (* th aspect)))))
      (unless (and (= tw gpu-video--width) (= th gpu-video--height))
        (setq gpu-video--width tw
              gpu-video--height th)
        (let ((inhibit-read-only t)
              (p (marker-position gpu-video--vid-marker)))
          (when p
            (put-text-property p (1+ p) 'display
                               `(space :width (,tw) :height (,th))))))
      (let ((vis (pos-visible-in-window-p gpu-video--vid-marker win t)))
        (if (and vis (listp vis))
            (gpu-video-move (+ (nth 0 edges) (nth 0 vis))
                            (+ (nth 1 edges) (nth 1 vis))
                            tw th edges frame)
          (gpu-video-move 0 -32768 tw th nil frame))))))

(defun gpu-video--claim (buf frame)
  "Open BUF's video on FRAME and record BUF as the frame's video owner."
  (with-current-buffer buf
    (gpu-video-open gpu-video--file 0 -32768
                    (max 1 gpu-video--width) (max 1 gpu-video--height)
                    t frame)
    (set-frame-parameter frame 'gpu-video-owner buf)
    (setq gpu-video--paused nil)))

(defun gpu-video--sync (buf)
  "Drive playback for BUF: claim, position, tick and redraw as needed.
Runs on the per-buffer timer.  Only the buffer shown in its frame's
selected window plays (one video player per frame)."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((frame gpu-video--frame)
             (win (and (frame-live-p frame) (get-buffer-window buf frame))))
        (cond
         ((not (frame-live-p frame))
          (gpu-video--teardown buf))
         ((and win (eq buf (window-buffer (frame-selected-window frame))))
          (unless (eq (frame-parameter frame 'gpu-video-owner) buf)
            (gpu-video--claim buf frame))
          (gpu-video--fit buf win frame)
          (gpu-video-tick frame)
          (let ((now (float-time)))
            (when (> (- now gpu-video--last-draw) 0.2)
              (setq gpu-video--last-draw now)
              (gpu-video--draw-controls buf))))
         ((eq (frame-parameter frame 'gpu-video-owner) buf)
          ;; We own the player but are not focused: park it off-screen.
          (gpu-video-move 0 -32768
                          (max 1 gpu-video--width) (max 1 gpu-video--height)
                          nil frame)
          (gpu-video-tick frame)))))))

(defun gpu-video--teardown (buf)
  "Stop playback and free the player for BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (timerp gpu-video--timer)
        (cancel-timer gpu-video--timer))
      (setq gpu-video--timer nil)
      (let ((frame gpu-video--frame))
        (when (and (frame-live-p frame)
                   (eq (frame-parameter frame 'gpu-video-owner) buf))
          (gpu-video-close frame)
          (set-frame-parameter frame 'gpu-video-owner nil))))))

(defun gpu-video--setup ()
  "Lay out the video buffer and start playback."
  (let ((inhibit-read-only t)
        (file (buffer-file-name)))
    (unless file
      (error "Buffer is not visiting a file"))
    (setq gpu-video--file file
          gpu-video--frame (selected-frame)
          gpu-video--width 16
          gpu-video--height 16)
    (erase-buffer)
    (buffer-disable-undo)
    (insert (propertize " "
                        'display '(space :width (16) :height (16))
                        'gpu-video t))
    (setq gpu-video--vid-marker (copy-marker (1- (point))))
    (insert "\n\n")
    (setq gpu-video--ctrl-start (copy-marker (point) nil))
    (gpu-video--draw-controls (current-buffer))
    (set-buffer-modified-p nil)
    (setq gpu-video--timer
          (run-at-time 0 0.04 #'gpu-video--sync (current-buffer)))))

(defun gpu-video--setup-unsupported ()
  "Show a notice when inline video playback is not available."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (and (fboundp 'gpu-backend-p) (gpu-backend-p))
        ;; Backend is on, but this platform's driver has no video player.
        (insert "Inline video playback is only available on the macOS\n"
                "(Metal) backend; the OpenGL backend has no video decoder.")
      (insert "Video playback requires the GPU backend.\n\n"
              "Enable it with M-x gpu-enable, then revert this buffer\n"
              "with M-x revert-buffer."))
    (set-buffer-modified-p nil)))

(defvar gpu-video-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "SPC") #'gpu-video-toggle-play)
    (define-key m (kbd "<left>") #'gpu-video-seek-backward)
    (define-key m (kbd "<right>") #'gpu-video-seek-forward)
    (define-key m (kbd "<") #'gpu-video-seek-start)
    (define-key m (kbd "M-<") #'gpu-video-seek-start)
    m)
  "Keymap for `gpu-video-mode'.")

;;;###autoload
(define-derived-mode gpu-video-mode special-mode "GPU-Video"
  "Major mode that plays a video file on the GPU.
The video autoplays and loops, with play/pause and a clickable timeline.

\\{gpu-video-mode-map}"
  (setq-local cursor-type nil
              truncate-lines t
              create-lockfiles nil
              buffer-offer-save nil)
  (auto-save-mode -1)
  (add-hook 'kill-buffer-hook
            (lambda () (gpu-video--teardown (current-buffer))) nil t)
  ;; Inline video needs the AVFoundation player primitives, which only the
  ;; macOS (Metal) backend provides; the OpenGL backend has no decoder.
  (if (and (fboundp 'gpu-video-open) (fboundp 'gpu-backend-p) (gpu-backend-p)
           (display-graphic-p))
      (gpu-video--setup)
    (gpu-video--setup-unsupported)))

(defun gpu-video-register-auto-mode ()
  "Register `gpu-video-mode' in `auto-mode-alist'.
Uses the extensions in `gpu-video-file-extensions'."
  (setq auto-mode-alist
        (rassq-delete-all 'gpu-video-mode auto-mode-alist))
  (when gpu-video-file-extensions
    (push (cons (concat "\\.\\(?:"
                        (mapconcat #'regexp-quote gpu-video-file-extensions "\\|")
                        "\\)\\'")
                'gpu-video-mode)
          auto-mode-alist)))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("\\.\\(?:mp4\\|mov\\|m4v\\|3gp\\)\\'" . gpu-video-mode))

;; Refresh the mapping from `gpu-video-file-extensions' when this file loads.
(gpu-video-register-auto-mode)

;; ---------------------------------------------------------------------------
;; Startup integration

(defun gpu--maybe-enable-on-startup (&optional frame)
  "Enable Metal on FRAME (or the selected frame) per `gpu-enable-on-startup'."
  (when (and gpu-enable-on-startup
             (fboundp 'gpu-backend-p)
             (gpu-backend-p))
    (let ((f (or frame (selected-frame))))
      ;; New frames pass through here mid-creation; tooltip/child/TTY
      ;; frames must not abort frame creation with an error.
      (when (display-graphic-p f)
        (ignore-errors (gpu-enable f))))))

(add-hook 'after-make-frame-functions #'gpu--maybe-enable-on-startup)

;; ---------------------------------------------------------------------------
;; Minor mode

(defvar gpu-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c m e") #'gpu-enable)
    (define-key map (kbd "C-c m s") #'gpu-status)
    (define-key map (kbd "C-c m c") #'gpu-set-cursor)
    (define-key map (kbd "C-c m S") #'gpu-set-scroll)
    (define-key map (kbd "C-c m a") #'gpu-toggle-animations)
    map)
  "Keymap for `gpu-mode'.")

;;;###autoload
(define-minor-mode gpu-mode
  "Minor mode for Metal GPU backend configuration.
Provides keybindings and ensures the Metal backend is configured.

\\{gpu-mode-map}"
  :lighter " Metal"
  :keymap gpu-mode-map
  :global t
  (if gpu-mode
      (when gpu-enable-on-startup
        (gpu--maybe-enable-on-startup))
    nil))


;; ---------------------------------------------------------------------------
;; Backward compatibility: the public API used the mtl- prefix up to 0.1.0.

(define-obsolete-function-alias 'mtl-enable #'gpu-enable "0.2")
(define-obsolete-function-alias 'mtl-status #'gpu-status "0.2")
(define-obsolete-function-alias 'mtl-toggle-animations #'gpu-toggle-animations "0.2")
(define-obsolete-function-alias 'mtl-set-cursor #'gpu-set-cursor "0.2")
(define-obsolete-function-alias 'mtl-set-scroll #'gpu-set-scroll "0.2")
(define-obsolete-function-alias 'mtl-video-insert #'gpu-video-insert "0.2")
(define-obsolete-function-alias 'mtl-video-stop #'gpu-video-stop "0.2")

(provide 'mtl)   ;; (require 'mtl) keeps working
(provide 'gpu)

;;; gpu.el ends here
