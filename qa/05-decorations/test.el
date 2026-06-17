;;; test.el --- Visual QA: Face Decorations -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/05-decorations/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/05-decorations/test.el

(let ((buf (get-buffer-create "*QA: Decorations*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (insert (propertize "=== Face Decorations QA ===\n\n"
                        'face '(:weight bold :height 1.3)))

    ;; Underlines
    (insert (propertize "── Underline styles " 'face 'shadow) (make-string 44 ?─) "\n")
    (insert (propertize "Single (default color)       — The quick brown fox\n"
                        'face '(:underline t)))
    (insert (propertize "Single (cornflower blue)     — The quick brown fox\n"
                        'face '(:underline (:color "cornflower blue"))))
    (insert (propertize "Double (default color)       — The quick brown fox\n"
                        'face '(:underline (:style double))))
    (insert (propertize "Double (red)                 — The quick brown fox\n"
                        'face '(:underline (:style double :color "red"))))
    (insert (propertize "Wave   (orange)              — The quick brown fox\n"
                        'face '(:underline (:style wave :color "orange"))))
    (insert (propertize "Dots   (default color)       — The quick brown fox\n"
                        'face '(:underline (:style dots))))
    (insert (propertize "Dashes (default color)       — The quick brown fox\n"
                        'face '(:underline (:style dashes))))
    (insert "\n")

    ;; Continuity across face boundaries
    (insert (propertize "── Wave continuity across face changes (must not reset) " 'face 'shadow)
            (make-string 7 ?─) "\n")
    (insert (propertize "This is " 'face '(:underline (:style wave :color "red"))))
    (insert (propertize "one continuous " 'face '(:underline (:style wave :color "red") :weight bold)))
    (insert (propertize "wave-underlined " 'face '(:underline (:style wave :color "red") :slant italic)))
    (insert (propertize "line.\n" 'face '(:underline (:style wave :color "red"))))
    (insert "\n")

    ;; Overline
    (insert (propertize "── Overline " 'face 'shadow) (make-string 51 ?─) "\n")
    (insert (propertize "Overline (default color)     — The quick brown fox\n"
                        'face '(:overline t)))
    (insert (propertize "Overline (forest green)      — The quick brown fox\n"
                        'face '(:overline "forest green")))
    (insert "\n")

    ;; Strike-through
    (insert (propertize "── Strike-through " 'face 'shadow) (make-string 45 ?─) "\n")
    (insert (propertize "Strike-through (default)     — The quick brown fox\n"
                        'face '(:strike-through t)))
    (insert (propertize "Strike-through (red)         — The quick brown fox\n"
                        'face '(:strike-through "red")))
    (insert "\n")

    ;; Combined
    (insert (propertize "── Combined decorations " 'face 'shadow) (make-string 40 ?─) "\n")
    (insert (propertize "Underline + overline         — The quick brown fox\n"
                        'face '(:underline t :overline t)))
    (insert (propertize "All three (U + O + S)        — The quick brown fox\n"
                        'face '(:underline t :overline t :strike-through t)))
    (insert "\n")

    ;; Colors on colored text
    (insert (propertize "── Decorations on colored text " 'face 'shadow) (make-string 33 ?─) "\n")
    (insert (propertize "Red text, blue underline     — The quick brown fox\n"
                        'face '(:foreground "red" :underline (:color "cornflower blue"))))
    (insert (propertize "Green bold, wave red under   — The quick brown fox\n"
                        'face '(:foreground "forest green" :weight bold
                                :underline (:style wave :color "red"))))

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
