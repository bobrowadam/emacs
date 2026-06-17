;;; test.el --- Visual QA: Edge Cases & Performance -*- lexical-binding: t; -*-
;;
;; GPU:     emacs --no-init-file -l qa/17-edge-cases/test.el
;; Vanilla: EMACS_GPU_DISABLE=1 emacs --no-init-file -l qa/17-edge-cases/test.el
;;
;; Keys: l=large buffer, f=font stress, m=dark theme, o=light theme,
;;       r=rapid cycling, x=overlays, q=stop cycling

(defvar qa-edge--cycle-timer nil)

(defun qa-edge-large-buffer ()
  (interactive)
  (let ((buf (get-buffer-create "*QA: Large Buffer*")))
    (with-current-buffer buf
      (erase-buffer)
      (setq buffer-read-only nil)
      (dotimes (i 5000)
        (insert (format "%5d │ " (1+ i)))
        (cond
         ((zerop (mod i 10))
          (insert (propertize "CHECKPOINT — bold blue marker\n"
                              'face '(:weight bold :foreground "cornflower blue"))))
         ((zerop (mod i 7))
          (insert (propertize "italic line — The quick brown fox\n"
                              'face '(:slant italic))))
         (t
          (insert "The quick brown fox jumps over the lazy dog 1234567890\n"))))
      (goto-char (point-min))
      (setq buffer-read-only t))
    (switch-to-buffer buf)
    (message "Large buffer ready — scroll with C-v/M-v")))

(defun qa-edge-font-stress ()
  (interactive)
  (let ((buf (get-buffer-create "*QA: Font Stress*")))
    (with-current-buffer buf
      (erase-buffer)
      (setq buffer-read-only nil)
      (insert (propertize "Font stress test — many sizes and weights\n\n"
                          'face '(:weight bold)))
      (dolist (height '(0.6 0.7 0.8 0.9 1.0 1.1 1.2 1.4 1.6 1.8 2.0 2.5))
        (insert (propertize (format "Height %.1f: The quick brown fox ABC 0123\n" height)
                            'face `(:height ,height))))
      (insert "\n")
      (dolist (weight '(thin ultralight light normal medium semibold bold extra-bold black))
        (insert (propertize (format "Weight %-12s: The quick brown fox\n" weight)
                            'face `(:weight ,weight))))
      (goto-char (point-min))
      (setq buffer-read-only t))
    (switch-to-buffer buf)
    (message "Font stress test — verify all glyphs render correctly")))

(defun qa-edge-dark-theme ()
  (interactive)
  (when (locate-library "modus-themes")
    (load-theme 'modus-vivendi t)
    (message "Loaded modus-vivendi (dark)")))

(defun qa-edge-light-theme ()
  (interactive)
  (when (locate-library "modus-themes")
    (load-theme 'modus-operandi t)
    (message "Loaded modus-operandi (light)")))

(defun qa-edge-rapid-cycle ()
  (interactive)
  (let* ((bufs (list (get-buffer-create "*QA: Cycle-A*")
                     (get-buffer-create "*QA: Cycle-B*")))
         (idx 0))
    (dolist (b bufs)
      (with-current-buffer b
        (erase-buffer)
        (insert (format "Rapid cycle buffer %s\n" (buffer-name b)))
        (dotimes (i 20) (insert (format "Line %d\n" i)))))
    (setq qa-edge--cycle-timer
          (run-with-timer 0 0.1
                          (lambda ()
                            (setq idx (mod (1+ idx) 2))
                            (switch-to-buffer (nth idx bufs)))))))

(defun qa-edge-stop-cycle ()
  (interactive)
  (when qa-edge--cycle-timer
    (cancel-timer qa-edge--cycle-timer)
    (setq qa-edge--cycle-timer nil)
    (message "Rapid cycling stopped")))

(defun qa-edge-add-overlays ()
  (interactive)
  (let ((buf (get-buffer-create "*QA: Overlays*")))
    (with-current-buffer buf
      (erase-buffer)
      (setq buffer-read-only nil)
      (hl-line-mode 1)
      (dotimes (i 60)
        (insert (format "Line %3d: The quick brown fox jumps over the lazy dog\n" (1+ i))))
      (setq buffer-read-only t)
      ;; Add 50 overlays at random positions
      (dotimes (_ 50)
        (let* ((start (+ (point-min) (random (- (point-max) (point-min) 5))))
               (end   (min (+ start (1+ (random 20))) (point-max)))
               (ov    (make-overlay start end))
               (bg    (nth (random 5) '("lemon chiffon" "lavender" "honeydew"
                                        "misty rose" "azure"))))
          (overlay-put ov 'face `(:background ,bg)))))
    (switch-to-buffer buf)
    (message "50 overlays added — verify hl-line still works")))

(let ((buf (get-buffer-create "*QA: Edge Cases*")))
  (with-current-buffer buf
    (erase-buffer)
    (insert (propertize "=== Edge Cases & Performance QA ===\n\n"
                        'face '(:weight bold :height 1.3)))
    (insert (propertize "Keys:\n" 'face '(:weight bold)))
    (insert "  l — load 5000-line buffer\n")
    (insert "  f — font size/weight stress test\n")
    (insert "  m — switch to dark theme (modus-vivendi)\n")
    (insert "  o — switch to light theme (modus-operandi)\n")
    (insert "  r — start rapid buffer cycling (10/s)\n")
    (insert "  q — stop rapid cycling\n")
    (insert "  x — add 50 overlays (+ hl-line test)\n\n")

    (use-local-map (make-sparse-keymap))
    (local-set-key "l" #'qa-edge-large-buffer)
    (local-set-key "f" #'qa-edge-font-stress)
    (local-set-key "m" #'qa-edge-dark-theme)
    (local-set-key "o" #'qa-edge-light-theme)
    (local-set-key "r" #'qa-edge-rapid-cycle)
    (local-set-key "q" #'qa-edge-stop-cycle)
    (local-set-key "x" #'qa-edge-add-overlays))
  (switch-to-buffer buf))
