;;; test.el --- Visual QA: Render Cycle & Present -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/01-render-cycle/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/01-render-cycle/test.el

(let ((buf (get-buffer-create "*QA: Render Cycle*")))
  (with-current-buffer buf
    (erase-buffer)
    (insert (propertize "=== Render Cycle & Present QA ===\n\n"
                        'face '(:weight bold :height 1.3)))
    (insert "Perform each step below and check for visual artifacts.\n\n")

    (insert (propertize "Steps:\n" 'face '(:weight bold)))
    (insert "  1. Note: did this window appear cleanly? (no black flash on startup)\n")
    (insert "  2. C-x t t   — toggle tab-bar (must not flash white)\n")
    (insert "  3. M-x C-g   — open and close minibuffer (no flash below text area)\n")
    (insert "  4. Drag the window border with the mouse (no black band during resize)\n")
    (insert "  5. C-x b RET — switch to *scratch* then back (no old content flicker)\n")
    (insert "  6. Move mouse over mode-line buttons (mouse-face must not flicker)\n")
    (insert "  7. Minimize and restore the window (content must redraw correctly)\n\n")

    (insert (make-string 65 ?─) "\n")
    (insert "Background content (to make content flicker visible):\n\n")
    (dotimes (i 30)
      (insert (format "  Line %3d │ The quick brown fox jumps over the lazy dog 1234567890\n" i)))

    (goto-char (point-min)))
  (switch-to-buffer buf)
  (setq buffer-read-only t))
