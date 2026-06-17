;;; test.el --- Visual QA: Fringe -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/08-fringe/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/08-fringe/test.el

;; Custom bitmap: ">>" chevron, 8px wide, 10px tall
(define-fringe-bitmap 'qa-chevron
  [#x00 #x18 #x3C #x7E #x3C #x18 #x00 #x00 #x00 #x00]
  10 8 'center)

;; Face for the custom bitmap
(defface qa-fringe-mark
  '((t :foreground "orange red"))
  "Face for QA fringe markers.")

(let ((buf (get-buffer-create "*QA: Fringe*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    ;; Yellow fringe background
    (set-face-background 'fringe "lemon chiffon")

    (insert (propertize "=== Fringe QA ===\n\n" 'face '(:weight bold :height 1.3)))

    ;; Truncation arrows: enable truncate-lines and add long lines
    (insert (propertize "── Truncation arrows (truncate-lines is ON below) " 'face 'shadow)
            (make-string 13 ?─) "\n")
    (setq truncate-lines t)
    (insert (make-string 200 ?A))
    (insert "\n")
    (insert (make-string 200 ?B))
    (insert "\n")
    (setq truncate-lines nil)
    (insert "\n")

    ;; Custom bitmap markers
    (insert (propertize "── Custom bitmap markers (orange chevron in left fringe) " 'face 'shadow)
            (make-string 6 ?─) "\n")
    (let ((start (point)))
      (insert "Marked line 1\n")
      (put-text-property start (point) 'display
                         `(left-fringe qa-chevron qa-fringe-mark)))
    (let ((start (point)))
      (insert "Marked line 2\n")
      (put-text-property start (point) 'display
                         `(left-fringe qa-chevron qa-fringe-mark)))
    (insert "Unmarked line\n")
    (let ((start (point)))
      (insert "Marked line 3\n")
      (put-text-property start (point) 'display
                         `(left-fringe qa-chevron qa-fringe-mark)))
    (insert "\n")

    ;; Empty-line indicators: go past the content
    (insert (propertize "── Empty-line indicators (tildes after last line) " 'face 'shadow)
            (make-string 13 ?─) "\n")
    (setq indicate-empty-lines t)
    (insert "Last content line — scroll down to see tildes below.\n")

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
