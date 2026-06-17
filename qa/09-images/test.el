;;; test.el --- Visual QA: Images -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/09-images/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/09-images/test.el

(defun qa-find-builtin-image (names)
  "Return path to first existing built-in image from NAMES list."
  (let ((dirs (list (expand-file-name "images/" data-directory)
                    (expand-file-name "images/icons/" data-directory)
                    data-directory)))
    (catch 'found
      (dolist (name names)
        (dolist (dir dirs)
          (let ((path (expand-file-name name dir)))
            (when (file-exists-p path)
              (throw 'found path))))))))

(let* ((buf (get-buffer-create "*QA: Images*"))
       ;; Locate built-in images
       (png-path  (qa-find-builtin-image '("icons/hicolor/32x32/apps/emacs.png"
                                           "splash.png" "gnu-emacs-logo.png")))
       (svg-path  (qa-find-builtin-image '("icons/hicolor/scalable/apps/emacs.svg"
                                           "splash.svg")))
       (xpm-path  (qa-find-builtin-image '("splash.xpm"))))

  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (insert (propertize "=== Images QA ===\n\n" 'face '(:weight bold :height 1.3)))

    ;; PNG
    (insert (propertize "── PNG (opaque, built-in) " 'face 'shadow) (make-string 38 ?─) "\n")
    (if png-path
        (progn
          (insert "Normal:  ")
          (insert-image (create-image png-path 'png nil :scale 1.0))
          (insert "  Next to text on the same line\n\n")

          (insert "Scale 2×: ")
          (insert-image (create-image png-path 'png nil :scale 2.0))
          (insert "\n\n")

          (insert "Rotation 90°: ")
          (insert-image (create-image png-path 'png nil :rotation 90))
          (insert "\n\n")

          (insert "Slice (top-left 32×32): ")
          (insert-image (create-image png-path 'png nil) nil nil '(0 0 32 32))
          (insert "\n\n")

          (insert "With :relief 3: ")
          (insert-image (create-image png-path 'png nil :relief 3))
          (insert "\n\n")

          (insert "Same image twice (cache test): ")
          (insert-image (create-image png-path 'png nil :scale 1.0))
          (insert "  ")
          (insert-image (create-image png-path 'png nil :scale 1.0))
          (insert "\n\n"))
      (insert "(PNG built-in image not found — add path manually)\n\n"))

    ;; SVG
    (insert (propertize "── SVG (built-in, vector) " 'face 'shadow) (make-string 38 ?─) "\n")
    (if (and svg-path (image-type-available-p 'svg))
        (progn
          (insert "SVG at 1×: ")
          (insert-image (create-image svg-path 'svg nil :scale 0.3))
          (insert "  SVG at 2×: ")
          (insert-image (create-image svg-path 'svg nil :scale 0.6))
          (insert "\n\n"))
      (insert "(SVG not available — install librsvg or provide path)\n\n"))

    ;; Adjacent to text (vertical alignment)
    (insert (propertize "── Images adjacent to text (alignment check) " 'face 'shadow)
            (make-string 18 ?─) "\n")
    (when png-path
      (insert "Text before ")
      (insert-image (create-image png-path 'png nil :scale 0.5))
      (insert " text after — baseline must be aligned\n"))

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
