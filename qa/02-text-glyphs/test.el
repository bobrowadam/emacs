;;; test.el --- Visual QA: Text & Glyphs -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/02-text-glyphs/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/02-text-glyphs/test.el

(let ((buf (get-buffer-create "*QA: Text & Glyphs*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (insert (propertize "=== Text & Glyphs QA ===\n\n" 'face '(:weight bold :height 1.3)))

    ;; ASCII + weights
    (insert (propertize "── ASCII & weights " 'face 'shadow)
            (make-string 45 ?─) "\n")
    (insert "Regular:   The quick brown fox jumps over the lazy dog 0123456789\n")
    (insert (propertize "Bold:      The quick brown fox jumps over the lazy dog 0123456789\n"
                        'face '(:weight bold)))
    (insert (propertize "Italic:    The quick brown fox jumps over the lazy dog 0123456789\n"
                        'face '(:slant italic)))
    (insert (propertize "Bold+Ital: The quick brown fox jumps over the lazy dog 0123456789\n"
                        'face '(:weight bold :slant italic)))
    (insert "\n")

    ;; Latin extended
    (insert (propertize "── Latin extended " 'face 'shadow)
            (make-string 47 ?─) "\n")
    (insert "Lower: àáâãäåæçèéêëìíîïðñòóôõöùúûüýþÿ\n")
    (insert "Upper: ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖÙÚÛÜÝÞŸ\n\n")

    ;; CJK
    (insert (propertize "── CJK " 'face 'shadow)
            (make-string 57 ?─) "\n")
    (insert "日本語: 日本語のテキスト、漢字、ひらがな、カタカナ\n")
    (insert "中文:   中文文字测试，简体字与繁體字混合\n")
    (insert "한국어: 한글 텍스트 테스트 — Hangul\n\n")

    ;; Height
    (insert (propertize "── :height face attribute " 'face 'shadow)
            (make-string 38 ?─) "\n")
    (insert (propertize "0.75× small  " 'face '(:height 0.75)))
    (insert "1.00× normal  ")
    (insert (propertize "1.25× large  " 'face '(:height 1.25)))
    (insert (propertize "1.50× larger\n" 'face '(:height 1.5)))
    (insert "\n")

    ;; Box-drawing
    (insert (propertize "── Box-drawing characters " 'face 'shadow)
            (make-string 38 ?─) "\n")
    (insert "┌────────────┬────────────┬────────────┐\n")
    (insert "│   Cell A   │   Cell B   │   Cell C   │\n")
    (insert "├────────────┼────────────┼────────────┤\n")
    (insert "│   Cell D   │   Cell E   │   Cell F   │\n")
    (insert "└────────────┴────────────┴────────────┘\n\n")

    ;; Font-lock faces
    (insert (propertize "── Font-lock face colors " 'face 'shadow)
            (make-string 39 ?─) "\n")
    (insert (propertize "keyword   " 'face 'font-lock-keyword-face))
    (insert (propertize "builtin   " 'face 'font-lock-builtin-face))
    (insert (propertize "function  " 'face 'font-lock-function-name-face))
    (insert (propertize "variable  " 'face 'font-lock-variable-name-face))
    (insert "\n")
    (insert (propertize "string    " 'face 'font-lock-string-face))
    (insert (propertize "comment   " 'face 'font-lock-comment-face))
    (insert (propertize "constant  " 'face 'font-lock-constant-face))
    (insert (propertize "type      " 'face 'font-lock-type-face))
    (insert "\n\n")

    ;; Advance precision
    (insert (propertize "── Advance precision (cursor at end must be at correct column) " 'face 'shadow)
            "\n")
    (insert (make-string 200 ?x))
    (insert "\n")

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
