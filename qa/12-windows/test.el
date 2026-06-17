;;; test.el --- Visual QA: Windows & Splits -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/12-windows/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/12-windows/test.el
;;
;; Keys: 2 = vertical split, 3 = horizontal split, n = new frame, p = popup child frame

(setq window-divider-default-bottom-width 6
      window-divider-default-right-width 6
      window-divider-default-places t)
(window-divider-mode 1)

(set-frame-parameter nil 'internal-border-width 6)

(defun qa-windows-new-frame ()
  (interactive)
  (make-frame '((name . "QA Second Frame")
                (width . 60) (height . 30))))

(defun qa-windows-child-popup ()
  (interactive)
  (let* ((parent (selected-frame))
         (pw (frame-pixel-width parent))
         (ph (frame-pixel-height parent))
         (fw 400) (fh 200)
         (child (make-frame
                 `((parent-frame . ,parent)
                   (left . ,(/ (- pw fw) 2))
                   (top  . ,(/ (- ph fh) 2))
                   (width . 50) (height . 8)
                   (undecorated . t)
                   (background-color . "lightyellow")
                   (name . "QA Popup")))))
    (with-selected-frame child
      (switch-to-buffer (get-buffer-create "*QA Popup*"))
      (erase-buffer)
      (insert "\n  This is a child frame popup.\n")
      (insert "  Verify: clean edges, correct position.\n")
      (insert "  Press q to close.\n")
      (local-set-key "q" (lambda () (interactive) (delete-frame))))))

(let ((buf (get-buffer-create "*QA: Windows*")))
  (with-current-buffer buf
    (erase-buffer)
    (setq buffer-read-only nil)

    (insert (propertize "=== Windows & Splits QA ===\n\n" 'face '(:weight bold :height 1.3)))
    (insert (propertize "Keys:\n" 'face '(:weight bold)))
    (insert "  C-x 2  — vertical split\n")
    (insert "  C-x 3  — horizontal split\n")
    (insert "  C-x 1  — back to single window\n")
    (insert "  n       — open a second frame\n")
    (insert "  p       — open a child-frame popup\n\n")

    (insert (propertize "Window divider: 6px (should show first/last pixel colors)\n"
                        'face '(:foreground "cornflower blue")))
    (insert (propertize "Internal border: 6px around the frame edges\n\n"
                        'face '(:foreground "cornflower blue")))

    (insert (make-string 65 ?─) "\n")
    (dotimes (i 40)
      (insert (format "  Line %3d: content for window resize and split testing\n" (1+ i))))

    (use-local-map (make-sparse-keymap))
    (local-set-key "n" #'qa-windows-new-frame)
    (local-set-key "p" #'qa-windows-child-popup)

    (goto-char (point-min))
    (setq buffer-read-only t))
  (switch-to-buffer buf))
