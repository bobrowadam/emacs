;;; test.el --- Visual QA: Display Properties & Overlays -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/13-display-props/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/13-display-props/test.el

(let ((buf (get-buffer-create "*QA: Display Props*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (display-line-numbers-mode 1)
    (hl-line-mode 1)
    (setq left-margin-width 4)
    (set-window-margins (get-buffer-window buf) 4 0)

    (insert (propertize "=== Display Properties & Overlays QA ===\n\n"
                        'face '(:weight bold :height 1.3)))

    ;; Invisible text
    (insert (propertize "── Invisible text " 'face 'shadow) (make-string 46 ?─) "\n")
    (insert "Visible ")
    (let ((start (point)))
      (insert "INVISIBLE")
      (put-text-property start (point) 'invisible t))
    (insert " visible again — the word INVISIBLE must not appear.\n\n")

    ;; Display replacement
    (insert (propertize "── Display string replacement " 'face 'shadow) (make-string 34 ?─) "\n")
    (insert "This word: ")
    (let ((start (point)))
      (insert "ORIGINAL")
      (put-text-property start (point) 'display "REPLACED"))
    (insert " — must read 'REPLACED', not 'ORIGINAL'.\n\n")

    ;; Display space
    (insert (propertize "── Display space (:width alignment) " 'face 'shadow) (make-string 27 ?─) "\n")
    (insert "Col 1")
    (insert (propertize " " 'display '(space :align-to 20)))
    (insert "Col 2 (aligned to column 20)\n")
    (insert "Short")
    (insert (propertize " " 'display '(space :align-to 20)))
    (insert "Also at column 20\n\n")

    ;; Visual-line-mode wrapping
    (insert (propertize "── Visual-line-mode wrapping " 'face 'shadow) (make-string 35 ?─) "\n")
    (visual-line-mode 1)
    (insert "This is a very long line that should wrap at word boundaries and not in the middle of any word, demonstrating proper word-wrap behavior in the GPU backend.\n")
    (visual-line-mode -1)
    (insert "\n")

    ;; Truncate-lines
    (insert (propertize "── Truncate-lines (fringe arrow must appear) " 'face 'shadow)
            (make-string 18 ?─) "\n")
    (setq truncate-lines t)
    (insert "Truncated: ")
    (insert (make-string 180 ?X))
    (insert "\n")
    (setq truncate-lines nil)
    (insert "\n")

    ;; Overlays (applied after building buffer content)
    (let ((ov-start nil))
      (insert (propertize "── Overlay face + before/after strings " 'face 'shadow)
              (make-string 24 ?─) "\n")
      (setq ov-start (point))
      (insert "This region has an overlay with a yellow background.")
      (let ((ov (make-overlay ov-start (point))))
        (overlay-put ov 'face '(:background "lemon chiffon")))
      (insert "\n"))

    (let ((anchor (point)))
      (insert "before-string«anchor»after-string on this line.\n")
      (let ((ov (make-overlay anchor (1+ anchor))))
        (overlay-put ov 'before-string (propertize "«BEFORE» " 'face '(:foreground "red")))
        (overlay-put ov 'after-string  (propertize " «AFTER»" 'face '(:foreground "blue")))))
    (insert "\n")

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
