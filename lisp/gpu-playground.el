;;; gpu-playground.el --- Disposable retained-decoration example -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; A small non-Mentat consumer.  Call `gpu-playground' on an already enabled
;; Metal frame.  It creates a buffer, not a frame, and never enables cursor
;; effects or rewires startup.  Killing the buffer releases all objects.

;;; Code:

(require 'gpu)

(defun gpu-playground ()
  "Show a disposable decoration playground on the selected Metal frame.
Rounded rectangle, circle, clockwise arc and both line directions are
independent owned objects.  The circle repeats a geometry animation.
Kill this buffer to release everything."
  (interactive)
  (unless (gpu-decoration-supported-p) (user-error "Enable Metal on this frame first"))
  (let ((buffer (generate-new-buffer "*GPU playground*")) handles)
    (condition-case err
        (progn
          (with-current-buffer buffer
            (insert "Retained GPU decorations\n\n"
                    "Shapes draw above cached text.  Kill this buffer to clean up.\n")
            (dolist (properties
                     '((:rect (30 100 130 60) :radius 14 :fill 2109520 :stroke 7857322)
                       (:shape circle :rect (190 100 60 60) :fill 7857322 :stroke nil)
                       (:shape arc :rect (280 100 60 60) :stroke 15506325
                               :stroke-width 4 :start-angle 0 :sweep-angle 4.7)
                       (:shape line :rect (30 210 120 50) :stroke 7857322 :stroke-width 3)
                       (:shape line :rect (190 260 120 -50) :stroke 15506325 :stroke-width 3)))
              (let ((handle (gpu-decoration-create properties nil buffer)))
                (unless handle (error "Frame rejected decoration"))
                (push handle handles)))
            ;; Exercise patching and deletion as well as creation and animation.
            (gpu-decoration-update (car handles) '(:opacity 0.8))
            (let ((temporary (gpu-decoration-create '(:rect (0 0 1 1)) nil buffer)))
              (gpu-decoration-delete temporary))
            (gpu-decoration-animate (nth 3 handles) :rect '(190 170 60 60)
                                    2 'ease-in-out t)
            (setq buffer-read-only t))
          (switch-to-buffer buffer)
          buffer)
      (error (kill-buffer buffer) (signal (car err) (cdr err))))))

(provide 'gpu-playground)
;;; gpu-playground.el ends here
