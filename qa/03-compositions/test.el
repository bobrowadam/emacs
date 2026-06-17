;;; test.el --- Visual QA: Compositions & Special Scripts -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/03-compositions/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/03-compositions/test.el

(let ((buf (get-buffer-create "*QA: Compositions*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (insert (propertize "=== Compositions & Special Scripts QA ===\n\n"
                        'face '(:weight bold :height 1.3)))

    ;; Combining characters
    (insert (propertize "── Combining characters (both lines must look identical) " 'face 'shadow)
            (make-string 8 ?─) "\n")
    (insert "Precomposed: café  naïve  résumé  Ångström  crème brûlée\n")
    ;; Same strings built from base + combining codepoints
    (insert (concat "Combined:    café"
                    "  naïve"
                    "  résumé"
                    "  A̋ngström"
                    "  crème brûlée\n\n"))

    ;; Arabic
    (insert (propertize "── Arabic — right-to-left, joined glyphs " 'face 'shadow)
            (make-string 22 ?─) "\n")
    (insert "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ\n")
    (insert "مرحبًا بالعالم — Hello World in Arabic\n\n")

    ;; Hebrew
    (insert (propertize "── Hebrew — right-to-left " 'face 'shadow)
            (make-string 38 ?─) "\n")
    (insert "שָׁלוֹם עוֹלָם — Shalom Olam (Hello World)\n")
    (insert "אבגדהוזחטיכלמנסעפצקרשת\n\n")

    ;; Mixed BiDi
    (insert (propertize "── Mixed BiDi — English + Arabic on same line " 'face 'shadow)
            (make-string 17 ?─) "\n")
    (insert "English left, ثُمَّ Arabic, then English again.\n")
    (insert "Item 1: سلام — Item 2: hello — Item 3: مرحبا\n\n")

    ;; Devanagari
    (insert (propertize "── Devanagari — conjunct forms " 'face 'shadow)
            (make-string 32 ?─) "\n")
    (insert "नमस्ते दुनिया — Namaste (Hindi)\n")
    (insert "संस्कृतम् — Sanskrit\n")
    (insert "क्ष  त्र  ज्ञ  (conjunct consonants)\n\n")

    ;; Greek
    (insert (propertize "── Greek " 'face 'shadow)
            (make-string 55 ?─) "\n")
    (insert "αβγδεζηθικλμνξοπρστυφχψω — lower\n")
    (insert "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ — upper\n")
    (insert "Ελληνικά — Greek (language name)\n\n")

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
