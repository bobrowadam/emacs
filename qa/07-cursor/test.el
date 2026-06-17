;;; test.el --- Visual QA: Cursor -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/07-cursor/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/07-cursor/test.el
;;
;; The test cycles cursor types automatically every 2 seconds.
;; Press q to stop the cycle.

(defvar qa-cursor--types '(box hollow bar hbar)
  "Cursor types to cycle through.")

(defvar qa-cursor--index 0)
(defvar qa-cursor--timer nil)

(defun qa-cursor--advance ()
  (let* ((types qa-cursor--types)
         (type (nth (mod qa-cursor--index (length types)) types)))
    (setq cursor-type type)
    (setq qa-cursor--index (1+ qa-cursor--index))
    (force-mode-line-update)
    (message "Cursor type: %s (press q to stop)" type)))

(defun qa-cursor-stop ()
  (interactive)
  (when qa-cursor--timer
    (cancel-timer qa-cursor--timer)
    (setq qa-cursor--timer nil))
  (message "Cursor cycle stopped. Current type: %s" cursor-type))

(let ((buf (get-buffer-create "*QA: Cursor*")))
  (with-current-buffer buf
    (erase-buffer)

    (insert (propertize "=== Cursor QA ===\n\n" 'face '(:weight bold :height 1.3)))
    (insert "Cursor type cycles automatically every 2 seconds.\n")
    (insert "Current type is shown in the echo area.\n")
    (insert "Press q to stop the cycle.\n\n")

    (insert (propertize "── Test content (move point around with arrow keys) " 'face 'shadow)
            (make-string 12 ?─) "\n\n")

    ;; Regular ASCII for cursor positioning
    (dotimes (i 8)
      (insert (format "  Line %d: The quick brown fox jumps over the lazy dog\n" (1+ i))))
    (insert "\n")

    ;; R2L line for BAR cursor direction test
    (insert (propertize "── R2L test for BAR cursor (bar must be on RIGHT side) " 'face 'shadow)
            (make-string 7 ?─) "\n")
    (insert "  مرحبا بالعالم — move cursor into Arabic text and verify BAR position\n\n")

    ;; Empty lines for fringe cursor test
    (insert (propertize "── Empty lines — cursor must be visible here too " 'face 'shadow)
            (make-string 13 ?─) "\n")
    (dotimes (_ 5) (insert "\n"))

    (use-local-map (make-sparse-keymap))
    (local-set-key "q" #'qa-cursor-stop)
    (goto-char (point-min))
    (forward-line 7))

  (switch-to-buffer buf)
  (blink-cursor-mode 1)

  ;; Start the cycle timer
  (setq qa-cursor--index 0)
  (qa-cursor--advance)
  (setq qa-cursor--timer
        (run-with-timer 2 2 #'qa-cursor--advance)))
