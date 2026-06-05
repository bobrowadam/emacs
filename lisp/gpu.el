;;; gpu.el --- Metal GPU backend configuration for GNU Emacs on macOS -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Andros Fenollosa
;; Version: 0.1.2
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

(defcustom gpu-cursor-animation 'block
  "Cursor animation mode for the Metal GPU backend.
Possible values:
  `block'      Static filled rectangle, no effect (default)
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
;; Public API

(defun gpu-enable (&optional frame)
  "Enable Metal GPU rendering on FRAME (default: selected frame).
Adds a CAMetalLayer on top of the EmacsView and replaces the
CoreGraphics rendering pipeline with Metal shaders.

After this call, all redisplay for FRAME goes through the Metal GPU.
The NS backend still handles events, menus, and scrollbars."
  (interactive)
  (unless (fboundp 'gpu-backend-p)
    (error "gpu-enable: Metal backend not compiled in (--with-mtl missing)"))
  (unless (gpu-backend-p)
    (error "gpu-enable: Metal is not available on this system"))
  (let ((f (or frame (selected-frame))))
    (unless (framep f)
      (error "Mtl-enable: argument is not a frame"))
    (gpu-enable-for-frame f)
    ;; Apply current configuration
    (gpu-cursor-mode (gpu--cursor-mode-number gpu-cursor-animation))
    (gpu-scroll-effect (gpu--scroll-easing-number gpu-scroll-easing))
    (gpu-scroll-duration gpu-scroll-duration)
    (gpu-trail-length gpu-trail-length)
    (gpu-animations gpu-animations-enabled)
    (when gpu-animations-enabled (gpu--anim-pump-start))
    (add-hook 'pre-redisplay-functions #'gpu--transition-watch)
    (message "Metal GPU enabled on frame: %s (device: %s, animations: %s)"
             f (gpu-device-name) (if gpu-animations-enabled "on" "off"))))

(defun gpu-toggle-animations ()
  "Toggle the Metal GPU animation layer on or off."
  (interactive)
  (setopt gpu-animations-enabled (not gpu-animations-enabled))
  (when gpu-animations-enabled (gpu--anim-pump-start))
  (message "Metal animations %s" (if gpu-animations-enabled "enabled" "disabled")))

(defun gpu-status ()
  "Display current Metal GPU backend status in the minibuffer."
  (interactive)
  (if (not (fboundp 'gpu-backend-p))
      (message "Metal backend not compiled (--with-mtl required)")
    (if (not (gpu-backend-p))
        (message "Metal not available on this system")
      (let ((status (gpu-animation-status)))
        (message "Metal GPU: %s | Animations: %s | Cursor: %s | Scroll: %s (%.2fs)"
                 (gpu-device-name)
                 (if (cdr (assq 'animations status)) "on" "off")
                 (nth (cdr (assq 'cursor-mode status))
                      '(block spring torpedo sonicboom ripple pixiedust hollow beam))
                 (nth (cdr (assq 'scroll-easing status))
                      '(none linear ease-out-quad ease-out-cubic spring ease-in-out-cubic))
                 (cdr (assq 'scroll-duration status)))))))

(defun gpu-set-cursor (mode)
  "Interactively set cursor animation MODE."
  (interactive
   (list (intern (completing-read "Cursor mode: "
                                  '("block" "spring" "torpedo" "sonicboom"
                                    "ripple" "pixiedust" "hollow" "beam")
                                  nil t))))
  (setopt gpu-cursor-animation mode)
  (message "GPU cursor mode: %s" mode))

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
            (gpu--anim-pump-start))))
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
      (error "gpu-video-open failed for %s" file))
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
