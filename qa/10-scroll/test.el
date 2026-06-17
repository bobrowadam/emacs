;;; test.el --- Visual QA: Scroll & copy_region -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/10-scroll/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/10-scroll/test.el
;;
;; Press s to start auto-scroll, S to stop.

(defvar qa-scroll--timer nil)

(defun qa-scroll-start ()
  (interactive)
  (setq qa-scroll--timer
        (run-with-timer 0 0.06
                        (lambda ()
                          (with-current-buffer "*QA: Scroll*"
                            (condition-case nil
                                (scroll-up 1)
                              (end-of-buffer
                               (goto-char (point-min)))))))))

(defun qa-scroll-stop ()
  (interactive)
  (when qa-scroll--timer
    (cancel-timer qa-scroll--timer)
    (setq qa-scroll--timer nil)))

(let ((buf (get-buffer-create "*QA: Scroll*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (insert (propertize "=== Scroll & copy_region QA ===\n" 'face '(:weight bold :height 1.3)))
    (insert "s = start auto-scroll    S = stop\n")
    (insert (make-string 65 ?─) "\n\n")

    ;; Numbered content lines for scroll verification
    (dotimes (i 200)
      (insert (format "%4d │ " (1+ i)))
      ;; Vary content to make artifact detection easy
      (cond
       ((zerop (mod i 5))
        (insert (propertize (format "CHECKPOINT %d — bold marker line" (/ i 5))
                            'face '(:weight bold :foreground "cornflower blue"))))
       ((zerop (mod i 3))
        (insert (propertize "The quick brown fox jumps over the lazy dog"
                            'face '(:slant italic))))
       (t
        (insert "The quick brown fox jumps over the lazy dog 1234567890")))
      (insert "\n"))

    (insert "\n")
    (insert (propertize "── Long lines for hscroll test " 'face 'shadow)
            (make-string 33 ?─) "\n")
    (setq truncate-lines t)
    (dotimes (i 5)
      (insert (format "HSCROLL-%d: " (1+ i)))
      (insert (make-string 200 (+ ?a i)))
      (insert "\n"))
    (setq truncate-lines nil)

    (use-local-map (make-sparse-keymap))
    (local-set-key "s" #'qa-scroll-start)
    (local-set-key "S" #'qa-scroll-stop)

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
