;;; test.el --- Visual QA: Emacs Bars -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/11-bars/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/11-bars/test.el

;; Enable all bars
(tool-bar-mode 1)
(scroll-bar-mode 1)
(tab-bar-mode 1)

;; Open a few tabs to make the tab-bar useful
(tab-new)
(tab-rename "Tab-A")
(tab-new)
(tab-rename "Tab-B")
(tab-new)
(tab-rename "QA")
(tab-bar-select-tab 3)

(let ((buf (get-buffer-create "*QA: Bars*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    ;; Header-line
    (setq header-line-format
          (propertize " Header-line: verify it is above this text "
                      'face '(:background "steel blue" :foreground "white")))

    (insert (propertize "=== Emacs Bars QA ===\n\n" 'face '(:weight bold :height 1.3)))
    (insert "Bars enabled: tool-bar, scroll-bar, tab-bar, header-line.\n\n")

    (insert (propertize "Checklist:\n" 'face '(:weight bold)))
    (insert "  1. Mode-line shows buffer name + major mode + position\n")
    (insert "  2. C-x 2 to split — active mode-line brighter than inactive\n")
    (insert "  3. Hover mouse over mode-line buttons — highlight must appear\n")
    (insert "  4. Header-line visible in blue above this text\n")
    (insert "  5. Tab-bar shows Tab-A, Tab-B, QA — click to switch\n")
    (insert "  6. Hover over each tab — highlight on hover\n")
    (insert "  7. Tool-bar shows icons with raised relief\n")
    (insert "  8. Drag scroll-bar thumb — buffer scrolls to matching position\n\n")

    (insert (make-string 65 ?─) "\n")
    (insert "Padding content for the scroll-bar to be meaningful:\n\n")
    (dotimes (i 80)
      (insert (format "  Line %3d: The quick brown fox jumps over the lazy dog\n" (1+ i))))

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf)))
