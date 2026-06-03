;;; mtl.el --- Metal GPU backend configuration for GNU Emacs on macOS -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Andros Fenollosa
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: hardware, display, macos, metal, gpu
;; URL: https://github.com/eval-exec/emacs-gl

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.

;;; Commentary:

;; This module provides user-facing configuration for the Metal GPU
;; display backend (emacs-gl).
;;
;; The Metal backend replaces CoreGraphics rendering with Apple Metal
;; for GPU-accelerated text, cursor animations, and scroll effects.
;;
;; Usage:
;;
;;   ;; Enable Metal on the current frame
;;   (mtl-enable)
;;
;;   ;; Configure cursor animation
;;   (setq mtl-cursor-animation 'spring)  ;; or 'torpedo, 'pixiedust, etc.
;;
;;   ;; Configure scroll easing
;;   (setq mtl-scroll-easing 'ease-out-quad)
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

(defgroup mtl nil
  "Metal GPU display backend for GNU Emacs on macOS."
  :group 'display
  :prefix "mtl-"
  :link '(url-link "https://github.com/eval-exec/emacs-gl"))

;; ---------------------------------------------------------------------------
;; Helper functions (must be defined before defcustom :set functions use them)

(defun mtl--cursor-mode-number (mode)
  "Convert cursor MODE symbol to integer for `mtl-cursor-mode'."
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

(defun mtl--scroll-easing-number (easing)
  "Convert EASING symbol to integer for `mtl-scroll-effect'."
  (pcase easing
    ('none            0)
    ('linear          1)
    ('ease-out-quad   2)
    ('ease-out-cubic  3)
    ('spring          4)
    ('ease-in-out-cubic 5)
    (_ 2)))

;; ---------------------------------------------------------------------------
;; Customizable variables

(defcustom mtl-cursor-animation 'spring
  "Cursor animation mode for the Metal GPU backend.
Possible values:
  `block'      Static filled rectangle (no animation)
  `spring'     Critically-damped spring physics (default)
  `torpedo'    Trail of last N cursor positions
  `sonicboom'  Expanding ring when cursor jumps far
  `ripple'     Three concentric expanding rings
  `pixiedust'  Radial particle burst on jump
  `hollow'     Hollow outline box
  `beam'       Thin vertical bar"
  :type '(choice (const :tag "Block (static)" block)
                 (const :tag "Spring (smooth)" spring)
                 (const :tag "Torpedo (trail)" torpedo)
                 (const :tag "Sonicboom (ring)" sonicboom)
                 (const :tag "Ripple (3 rings)" ripple)
                 (const :tag "Pixiedust (particles)" pixiedust)
                 (const :tag "Hollow (outline)" hollow)
                 (const :tag "Beam (bar)" beam))
  :set #'set-default
  :group 'mtl)

(defcustom mtl-scroll-easing 'ease-out-quad
  "Scroll animation easing for the Metal GPU backend."
  :type '(choice (const :tag "None (instant)" none)
                 (const :tag "Linear" linear)
                 (const :tag "Ease out quad (default)" ease-out-quad)
                 (const :tag "Ease out cubic" ease-out-cubic)
                 (const :tag "Spring" spring)
                 (const :tag "Ease in-out cubic" ease-in-out-cubic))
  :set #'set-default
  :group 'mtl)

(defcustom mtl-scroll-duration 0.15
  "Scroll animation duration in seconds (0.0 to 2.0).
Lower values are snappier; higher values are more fluid."
  :type 'float
  :set #'set-default
  :group 'mtl)

(defcustom mtl-trail-length 20
  "Length of the cursor trail in torpedo mode (1-40)."
  :type 'integer
  :set #'set-default
  :group 'mtl)

(defcustom mtl-animations-enabled nil
  "If non-nil, enable the Metal GPU animation layer.
When nil (the default), the cursor is drawn directly into the static
texture like the NS backend and no compositor overlay is drawn, which is
the correct, flicker-free baseline.  Enable this to turn on the animated
cursor effects, particles and the 60fps compositor."
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'mtl-animations)
           (mtl-animations val)))
  :group 'mtl)

(defcustom mtl-enable-on-startup nil
  "If non-nil, enable Metal GPU rendering on the initial frame at startup."
  :type 'boolean
  :group 'mtl)

;; ---------------------------------------------------------------------------
;; Public API

(defun mtl-enable (&optional frame)
  "Enable Metal GPU rendering on FRAME (default: selected frame).
Adds a CAMetalLayer on top of the EmacsView and replaces the
CoreGraphics rendering pipeline with Metal shaders.

After this call, all redisplay for FRAME goes through the Metal GPU.
The NS backend still handles events, menus, and scrollbars."
  (interactive)
  (unless (fboundp 'mtl-backend-p)
    (error "mtl-enable: Metal backend not compiled in (--with-mtl missing)"))
  (unless (mtl-backend-p)
    (error "mtl-enable: Metal is not available on this system"))
  (let ((f (or frame (selected-frame))))
    (unless (framep f)
      (error "Mtl-enable: argument is not a frame"))
    (mtl-enable-for-frame f)
    ;; Apply current configuration
    (mtl-cursor-mode (mtl--cursor-mode-number mtl-cursor-animation))
    (mtl-scroll-effect (mtl--scroll-easing-number mtl-scroll-easing))
    (mtl-scroll-duration mtl-scroll-duration)
    (mtl-trail-length mtl-trail-length)
    (mtl-animations mtl-animations-enabled)
    (message "Metal GPU enabled on frame: %s (device: %s, animations: %s)"
             f (mtl-device-name) (if mtl-animations-enabled "on" "off"))))

(defun mtl-toggle-animations ()
  "Toggle the Metal GPU animation layer on or off."
  (interactive)
  (setopt mtl-animations-enabled (not mtl-animations-enabled))
  (message "Metal animations %s" (if mtl-animations-enabled "enabled" "disabled")))

(defun mtl-status ()
  "Display current Metal GPU backend status in the minibuffer."
  (interactive)
  (if (not (fboundp 'mtl-backend-p))
      (message "Metal backend not compiled (--with-mtl required)")
    (if (not (mtl-backend-p))
        (message "Metal not available on this system")
      (let ((status (mtl-animation-status)))
        (message "Metal GPU: %s | Animations: %s | Cursor: %s | Scroll: %s (%.2fs)"
                 (mtl-device-name)
                 (if (cdr (assq 'animations status)) "on" "off")
                 (nth (cdr (assq 'cursor-mode status))
                      '(block spring torpedo sonicboom ripple pixiedust hollow beam))
                 (nth (cdr (assq 'scroll-easing status))
                      '(none linear ease-out-quad ease-out-cubic spring ease-in-out-cubic))
                 (cdr (assq 'scroll-duration status)))))))

(defun mtl-set-cursor (mode)
  "Interactively set cursor animation MODE."
  (interactive
   (list (intern (completing-read "Cursor mode: "
                                  '("block" "spring" "torpedo" "sonicboom"
                                    "ripple" "pixiedust" "hollow" "beam")
                                  nil t))))
  (setopt mtl-cursor-animation mode))

(defun mtl-set-scroll (easing)
  "Interactively set scroll EASING."
  (interactive
   (list (intern (completing-read "Scroll easing: "
                                  '("none" "linear" "ease-out-quad"
                                    "ease-out-cubic" "spring" "ease-in-out-cubic")
                                  nil t))))
  (setopt mtl-scroll-easing easing))

;; ---------------------------------------------------------------------------
;; Inline video (Fase H2)

(defvar mtl--video-state nil
  "Active inline video: (MARKER WIDTH HEIGHT TIMER FRAME), or nil.")

(defun mtl--video-sync ()
  "Track the video placeholder: move/clip the GPU rect and present a frame.
Runs on a 30fps timer started by `mtl-video-insert'.  Follows scrolling
and window changes; hides the video while its position is off-screen."
  (when mtl--video-state
    (pcase-let ((`(,marker ,w ,h ,_timer ,frame) mtl--video-state))
      (if (not (and (frame-live-p frame) (marker-buffer marker)))
          (mtl-video-stop)
        (let* ((win (get-buffer-window (marker-buffer marker) frame))
               (vis (and win (pos-visible-in-window-p marker win t))))
          (if (not (and vis (listp vis)))
              ;; Not visible: park the rect off-screen but keep decoding.
              (mtl-video-move 0 -32768 w h nil frame)
            (let* ((edges (window-inside-pixel-edges win))
                   (x (+ (nth 0 edges) (nth 0 vis)))
                   (y (+ (nth 1 edges) (nth 1 vis))))
              (mtl-video-move x y w h edges frame)))
          (mtl-video-tick frame))))))

;;;###autoload
(defun mtl-video-insert (file width height &optional loop)
  "Insert a WIDTH x HEIGHT placeholder at point and play video FILE over it.
The placeholder is a space with a pixel-sized display spec; the GPU
composites the video at its position every frame, following scrolling
\(clipped to the window interior).  With LOOP non-nil, restart playback
at the end.  One video per frame; a previous one is replaced."
  (interactive "fVideo file: \nnWidth (px): \nnHeight (px): ")
  (mtl-video-stop)
  (insert (propertize " "
                      'display `(space :width (,width) :height (,height))
                      'mtl-video file))
  (let ((marker (copy-marker (1- (point)))))
    ;; Park off-screen; the first sync tick positions it for real.
    (unless (mtl-video-open file 0 -32768 width height loop)
      (error "mtl-video-open failed for %s" file))
    (setq mtl--video-state
          (list marker width height
                (run-at-time 0 0.033 #'mtl--video-sync)
                (selected-frame)))))

;;;###autoload
(defun mtl-video-stop ()
  "Stop and remove the inline video, canceling its sync timer."
  (interactive)
  (when mtl--video-state
    (pcase-let ((`(,_marker ,_w ,_h ,timer ,frame) mtl--video-state))
      (when (timerp timer) (cancel-timer timer))
      (when (frame-live-p frame) (mtl-video-close frame)))
    (setq mtl--video-state nil)))

;; ---------------------------------------------------------------------------
;; Startup integration

(defun mtl--maybe-enable-on-startup (&optional _frame)
  "Enable Metal on the initial frame if `mtl-enable-on-startup' is set."
  (when (and mtl-enable-on-startup
             (fboundp 'mtl-backend-p)
             (mtl-backend-p))
    (mtl-enable (selected-frame))))

(add-hook 'after-make-frame-functions #'mtl--maybe-enable-on-startup)

;; ---------------------------------------------------------------------------
;; Minor mode

(defvar mtl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c m e") #'mtl-enable)
    (define-key map (kbd "C-c m s") #'mtl-status)
    (define-key map (kbd "C-c m c") #'mtl-set-cursor)
    (define-key map (kbd "C-c m S") #'mtl-set-scroll)
    (define-key map (kbd "C-c m a") #'mtl-toggle-animations)
    map)
  "Keymap for `mtl-mode'.")

;;;###autoload
(define-minor-mode mtl-mode
  "Minor mode for Metal GPU backend configuration.
Provides keybindings and ensures the Metal backend is configured.

\\{mtl-mode-map}"
  :lighter " Metal"
  :keymap mtl-mode-map
  :global t
  (if mtl-mode
      (when mtl-enable-on-startup
        (mtl--maybe-enable-on-startup))
    nil))

(provide 'mtl)
;;; mtl.el ends here
