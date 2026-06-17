;;; test.el --- Visual QA: Emoji & Color Glyphs -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/04-emoji/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/04-emoji/test.el

(let ((buf (get-buffer-create "*QA: Emoji & Color Glyphs*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (insert (propertize "=== Emoji & Color Glyphs QA ===\n\n"
                        'face '(:weight bold :height 1.3)))

    (insert (propertize "── Basic emoji (must appear in color) " 'face 'shadow)
            (make-string 26 ?─) "\n")
    (insert "Faces:   😀 😁 😂 🤣 😃 😄 😅 😆 😉 😊 😋 😎 🤩 🥳\n")
    (insert "Animals: 🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸\n")
    (insert "Food:    🍎 🍊 🍋 🍇 🍓 🍒 🍑 🥭 🍍 🥥 🍆 🥦 🥕 🌽\n\n")

    (insert (propertize "── Symbol emoji — must be in color (with VS16) " 'face 'shadow)
            (make-string 16 ?─) "\n")
    (insert "❤️  💙  💚  💛  💜  🖤  🤍  🤎\n")
    (insert "⭐  🌟  💫  ✨  🌈  ☀️  🌙  ⚡  ☔  ❄️\n\n")

    (insert (propertize "── Wide emoji — each occupies two columns " 'face 'shadow)
            (make-string 22 ?─) "\n")
    (insert "🎯 🎨 🎭 🎪 🎤 🎧 🎵 🎶 🎸 🎹 🥁 🎺 🎻 🪕\n")
    (insert "🌍 🌎 🌏 🗺️  🧭 🏔️  🌋 🏕️  🏖️  🏜️  🏝️\n\n")

    (insert (propertize "── Emoji in mixed text — text must not shift " 'face 'shadow)
            (make-string 19 ?─) "\n")
    (insert "File 📁 opened — status: ✅ — errors: ❌ — warnings: ⚠️\n")
    (insert "Mode 🔴 stopped | 🟡 paused | 🟢 running\n")
    (insert "Score: 💯  Rank: 🥇  Time: ⏰  Memory: 💾\n\n")

    (insert (propertize "── ZWJ sequences — must render as a single glyph " 'face 'shadow)
            (make-string 13 ?─) "\n")
    (insert "👨‍💻  👩‍💻  👨‍🎨  👩‍🎤  👨‍🍳  👩‍🚀  👨‍🔬  👩‍🏫\n\n")

    (insert (propertize "── Flag emoji " 'face 'shadow)
            (make-string 50 ?─) "\n")
    (insert "🇺🇸 🇬🇧 🇩🇪 🇫🇷 🇯🇵 🇰🇷 🇨🇳 🇪🇸 🇧🇷 🇮🇳 🇲🇽 🇮🇹\n\n")

    (insert (propertize "── Emoji with face attributes " 'face 'shadow)
            (make-string 33 ?─) "\n")
    (insert "Normal: 🔥  ")
    (insert (propertize "Bold: 🔥  " 'face '(:weight bold)))
    (insert (propertize "2.0×: 🌍" 'face '(:height 2.0)))
    (insert "\n")

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
