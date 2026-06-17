;;; test.el --- Visual QA: Boxes & Reliefs -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/06-boxes-reliefs/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/06-boxes-reliefs/test.el

(let ((buf (get-buffer-create "*QA: Boxes & Reliefs*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (insert (propertize "=== Boxes & Reliefs QA ===\n\n"
                        'face '(:weight bold :height 1.3)))

    ;; Simple boxes
    (insert (propertize "── Simple boxes " 'face 'shadow) (make-string 48 ?─) "\n\n")
    (insert "  ")
    (insert (propertize "  Box 1px  " 'face '(:box 1)))
    (insert "   ")
    (insert (propertize "  Box 2px  " 'face '(:box 2)))
    (insert "   ")
    (insert (propertize "  Box 3px  " 'face '(:box 3)))
    (insert "\n\n")

    (insert "  ")
    (insert (propertize "  Blue box 1px  " 'face '(:box (:line-width 1 :color "cornflower blue"))))
    (insert "   ")
    (insert (propertize "  Red box 2px  " 'face '(:box (:line-width 2 :color "red"))))
    (insert "\n\n")

    ;; Asymmetric line widths
    (insert "  ")
    (insert (propertize "  H=1 V=4  " 'face '(:box (:line-width (1 . 4)))))
    (insert "   ")
    (insert (propertize "  H=4 V=1  " 'face '(:box (:line-width (4 . 1)))))
    (insert "\n\n")

    ;; Reliefs
    (insert (propertize "── Reliefs " 'face 'shadow) (make-string 53 ?─) "\n\n")
    (insert "  ")
    (insert (propertize "  Raised (default)  " 'face '(:box (:line-width 2 :style released-button))))
    (insert "   ")
    (insert (propertize "  Sunken (pressed)  " 'face '(:box (:line-width 2 :style pressed-button))))
    (insert "\n\n")

    (insert "  ")
    (insert (propertize "  Raised 3px  " 'face '(:box (:line-width 3 :style released-button))))
    (insert "   ")
    (insert (propertize "  Sunken 3px  " 'face '(:box (:line-width 3 :style pressed-button))))
    (insert "\n\n")

    ;; On colored backgrounds
    (insert (propertize "── Reliefs on colored backgrounds " 'face 'shadow) (make-string 30 ?─) "\n\n")
    (insert "  ")
    (insert (propertize "  Raised on blue  "
                        'face '(:background "steel blue" :foreground "white"
                                :box (:line-width 2 :style released-button))))
    (insert "   ")
    (insert (propertize "  Sunken on blue  "
                        'face '(:background "steel blue" :foreground "white"
                                :box (:line-width 2 :style pressed-button))))
    (insert "\n\n")

    ;; Mode-line style simulation
    (insert (propertize "── Mode-line button simulation " 'face 'shadow) (make-string 33 ?─) "\n\n")
    (let ((ml-face `(:background ,(face-background 'mode-line nil t)
                     :foreground ,(face-foreground 'mode-line nil t)
                     :box (:line-width 1 :style released-button))))
      (insert "  ")
      (insert (propertize "  [Button 1]  " 'face ml-face))
      (insert " ")
      (insert (propertize "  [Button 2]  " 'face ml-face))
      (insert " ")
      (insert (propertize "  [Pressed]  "
                          'face `(:background ,(face-background 'mode-line nil t)
                                  :foreground ,(face-foreground 'mode-line nil t)
                                  :box (:line-width 1 :style pressed-button)))))
    (insert "\n")

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
