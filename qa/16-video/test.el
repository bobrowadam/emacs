;;; test.el --- Visual QA: Inline Video (macOS Metal only) -*- lexical-binding: t; -*-
;;
;; GPU Metal: emacs --no-init-file -l qa/16-video/test.el
;; Linux/GL:  All items in this test are SKIP.
;;
;; Press v to insert a video file, s to stop playback.

(defun qa-video-insert ()
  (interactive)
  (if (not (fboundp 'gpu-video-insert))
      (message "gpu-video-insert not available (not Metal, or GPU disabled)")
    (let ((path (read-file-name "Video file (.mp4/.mov): " "~/" nil t)))
      (when (file-exists-p path)
        (gpu-video-insert path)
        (message "Video inserted. Scroll the buffer to test tracking.")))))

(defun qa-video-stop ()
  (interactive)
  (if (fboundp 'gpu-video-stop)
      (progn (gpu-video-stop) (message "Video stopped."))
    (message "gpu-video-stop not available")))

(let ((buf (get-buffer-create "*QA: Video*")))
  (with-current-buffer buf
    (erase-buffer)

    (insert (propertize "=== Inline Video QA (macOS Metal only) ===\n\n"
                        'face '(:weight bold :height 1.3)))

    (if (not (fboundp 'gpu-video-insert))
        (insert (propertize "gpu-video-insert is not available.\nAll items in this test are SKIP.\n"
                            'face '(:foreground "orange red")))
      (insert (propertize "Keys:\n" 'face '(:weight bold)))
      (insert "  v — insert a video file at point\n")
      (insert "  s — stop the current video\n\n")
      (insert "Steps:\n")
      (insert "  1. Press v and select a .mp4 or .mov file\n")
      (insert "  2. Verify the video appears at the insertion point below\n")
      (insert "  3. Scroll down — video must follow the text\n")
      (insert "  4. Open a split (C-x 2) — video must not bleed into the other window\n")
      (insert "  5. Press s — video overlay must disappear, placeholder stays\n\n"))

    (insert (make-string 65 ?─) "\n")
    (insert "[ video will be inserted below this line ]\n\n")
    (insert (make-string 65 ?─) "\n\n")
    (dotimes (i 40)
      (insert (format "  Line %3d: padding so you can scroll to test video tracking\n" (1+ i))))

    (use-local-map (make-sparse-keymap))
    (local-set-key "v" #'qa-video-insert)
    (local-set-key "s" #'qa-video-stop)

    ;; Position point at the insertion line
    (goto-char (point-min))
    (search-forward "[ video will be inserted" nil t)
    (forward-line 1))
  (switch-to-buffer buf))
