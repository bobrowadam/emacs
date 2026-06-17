;;; test.el --- Visual QA: Buffer Transitions & HiDPI -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/15-transitions/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/15-transitions/test.el
;;
;; Press t to cycle buffers with crossfade, T to toggle crossfade on/off.

(defvar qa-trans--buffers nil)
(defvar qa-trans--index 0)

(defun qa-trans-cycle ()
  (interactive)
  (setq qa-trans--index (mod (1+ qa-trans--index) (length qa-trans--buffers)))
  (switch-to-buffer (nth qa-trans--index qa-trans--buffers)))

(defun qa-trans-toggle ()
  (interactive)
  (if (boundp 'gpu-buffer-transitions)
      (progn
        (setq gpu-buffer-transitions (not gpu-buffer-transitions))
        (message "gpu-buffer-transitions: %s" gpu-buffer-transitions))
    (message "gpu-buffer-transitions not available (vanilla mode)")))

;; Build a set of visually distinct buffers to fade between
(let ((colors '(("cornflower blue" . "white")
                ("forest green"   . "white")
                ("firebrick"      . "white")
                ("dark orange"    . "black")))
      bufs)
  (dolist (pair colors)
    (let* ((bg (car pair)) (fg (cdr pair))
           (name (format "*QA: Transition %s*" bg))
           (buf (get-buffer-create name)))
      (with-current-buffer buf
        (erase-buffer)
        (face-remap-add-relative 'default `(:background ,bg :foreground ,fg))
        (insert (format "\n\n  Buffer: %s\n\n" name))
        (insert "  This buffer has a distinct background color.\n")
        (insert "  When crossfade is ON (press t), the previous buffer\n")
        (insert "  must fade out smoothly as this one fades in.\n\n")
        (insert "  Press t to cycle to the next buffer.\n")
        (insert "  Press T to toggle crossfade on/off.\n\n")
        (dotimes (i 20)
          (insert (format "  Line %d: padding content\n" (1+ i))))
        (use-local-map (make-sparse-keymap))
        (local-set-key "t" #'qa-trans-cycle)
        (local-set-key "T" #'qa-trans-toggle))
      (push buf bufs)))

  (setq qa-trans--buffers (nreverse bufs))
  (setq qa-trans--index 0)

  ;; Enable transitions if available
  (when (boundp 'gpu-buffer-transitions)
    (setq gpu-buffer-transitions t)
    (setq gpu-buffer-transition-duration 0.4))

  (switch-to-buffer (car qa-trans--buffers))
  (message "Crossfade QA ready. t = cycle buffers, T = toggle crossfade"))
