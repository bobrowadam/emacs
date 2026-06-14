;;; gl-bench.el --- redisplay throughput: stock vs GPU backend  -*- lexical-binding:t -*-

;; This file is part of the emacs-gpu benchmark harness.  It drives the
;; same five workloads with the GPU backend enabled or disabled and
;; appends the results to a per-mode log file.

;; Environment variables (all optional):
;;   GL_MODE        "gpu" | "vanilla"   selects which line to write and,
;;                  for "gpu", calls `gpu-enable-for-frame'.  Default
;;                  "vanilla".
;;   GL_BENCH_COLS  frame width in columns  (default 160).
;;   GL_BENCH_ROWS  frame height in rows    (default 48).
;;   GL_BENCH_OUT   directory for the log files (default the system
;;                  temporary directory).
;;
;; Results are appended to GL_BENCH_OUT/gl-bench-<mode>.txt, one line per
;; workload: "NAME frames=N sec=S fps=F ms=M".  The runner scripts
;; (run-bench.sh, run-bench-hires.sh) parse those lines.

;;; Code:

(require 'benchmark)

(defun gl-bench-out-dir ()
  "Directory where the per-mode result files are written."
  (or (getenv "GL_BENCH_OUT") temporary-file-directory))

(defun gl-bench-log (fmt &rest args)
  "Append the formatted line to the result file for the current mode."
  (let ((mode (or (getenv "GL_MODE") "vanilla")))
    (write-region (concat (apply #'format fmt args) "\n") nil
                  (expand-file-name (format "gl-bench-%s.txt" mode)
                                    (gl-bench-out-dir))
                  'append 'silent)))

(defun gl-bench-code-buffer ()
  "Return a buffer with 8000 lines of font-locked Emacs Lisp."
  (let ((buf (get-buffer-create "*bench-code*")))
    (with-current-buffer buf
      (emacs-lisp-mode) (erase-buffer)
      (dotimes (i 8000)
        (insert (format "(defun func-%d (a b c) ; line %d lorem ipsum dolor sit\n"
                        i i))
        (insert (format "  (let ((x (+ a b)) (y \"a string value %d\")) (* x c %d)))\n"
                        i i)))
      (font-lock-ensure) (goto-char (point-min)))
    buf))

(defun gl-bench-img-buffer (img)
  "Return a buffer with 60 copies of the PNG file IMG interleaved with text."
  (let ((buf (get-buffer-create "*bench-img*")))
    (with-current-buffer buf
      (fundamental-mode) (erase-buffer)
      (dotimes (i 60)
        (insert (format "image block %d of the scrolling benchmark\n" i))
        (insert-image (create-image img 'png nil))
        (insert "\n\n"))
      (goto-char (point-min)))
    buf))

(defun gl-bench-top ()
  "Scroll back to the top of the current buffer and redisplay."
  (goto-char (point-min))
  (set-window-start (selected-window) (point-min))
  (redisplay t))

(defun gl-bench-frames (n thunk)
  "Call THUNK N times, force a redisplay each, return elapsed seconds."
  (let ((t0 (float-time)))
    (dotimes (_ n) (funcall thunk) (redisplay t))
    (- (float-time) t0)))

(defun gl-bench-scroller ()
  "Scroll one line, wrapping to the top at end of buffer."
  (condition-case nil (scroll-up 1)
    (end-of-buffer (gl-bench-top))))

(defun gl-bench-run ()
  "Run the five workloads and log a result line for each."
  (condition-case err
      (let* ((f (selected-frame))
             (mode (or (getenv "GL_MODE") "vanilla"))
             (img (expand-file-name "bench-img.png" (gl-bench-out-dir))))
        (menu-bar-mode -1) (tool-bar-mode -1)
        (when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
        (blink-cursor-mode -1)
        (set-frame-size f
                        (string-to-number (or (getenv "GL_BENCH_COLS") "160"))
                        (string-to-number (or (getenv "GL_BENCH_ROWS") "48")))
        (switch-to-buffer (gl-bench-code-buffer))
        (delete-other-windows) (gl-bench-top) (message nil)
        (sit-for 0.5)
        (when (and (string= mode "gpu") (fboundp 'gpu-enable-for-frame))
          (gpu-enable-for-frame f) (redisplay t) (sit-for 0.3))
        (gl-bench-log "# mode=%s device=%s frame=%dx%d" mode
                      (and (fboundp 'gpu-device-name) (gpu-device-name))
                      (frame-pixel-width f) (frame-pixel-height f))
        ;; Warm-up: fill the glyph atlas and caches before measuring.
        (gl-bench-frames 80 #'gl-bench-scroller) (gl-bench-top)
        ;; 1. line scroll (1 line/frame) -- text-heavy, cairo is competitive
        (let* ((n 800) (s (gl-bench-frames n #'gl-bench-scroller)))
          (gl-bench-log "line-scroll frames=%d sec=%.3f fps=%.1f ms=%.3f"
                        n s (/ n s) (* 1000 (/ s n))))
        (gl-bench-top)
        ;; 2. page scroll (whole window/frame) -- more new glyphs per frame
        (let* ((n 400)
               (s (gl-bench-frames n (lambda ()
                    (condition-case nil (scroll-up) (end-of-buffer (gl-bench-top)))))))
          (gl-bench-log "page-scroll frames=%d sec=%.3f fps=%.1f ms=%.3f"
                        n s (/ n s) (* 1000 (/ s n))))
        (gl-bench-top)
        ;; 3. full-frame redraw (everything repainted each frame)
        (let* ((n 300)
               (s (gl-bench-frames n (lambda () (redraw-frame f)))))
          (gl-bench-log "full-redraw frames=%d sec=%.3f fps=%.1f ms=%.3f"
                        n s (/ n s) (* 1000 (/ s n))))
        ;; 4. typing (one self-insert + redisplay per frame)
        (let ((buf (get-buffer-create "*bench-type*")))
          (with-current-buffer buf (erase-buffer) (emacs-lisp-mode))
          (switch-to-buffer buf) (redisplay t)
          (let* ((n 600)
                 (s (gl-bench-frames n (lambda ()
                      (insert (char-to-string (+ ?a (random 26))))
                      (when (> (current-column) 150) (insert "\n"))))))
            (gl-bench-log "typing frames=%d sec=%.3f fps=%.1f ms=%.3f"
                          n s (/ n s) (* 1000 (/ s n)))))
        ;; 5. image scroll (GPU should win here)
        (when (file-exists-p img)
          (switch-to-buffer (gl-bench-img-buffer img)) (delete-other-windows)
          (gl-bench-top)
          (let* ((n 500) (s (gl-bench-frames n #'gl-bench-scroller)))
            (gl-bench-log "image-scroll frames=%d sec=%.3f fps=%.1f ms=%.3f"
                          n s (/ n s) (* 1000 (/ s n)))))
        (gl-bench-log "DONE"))
    (error (gl-bench-log "ERR %S" err)))
  (kill-emacs 0))

(run-with-timer 1.0 nil #'gl-bench-run)

;;; gl-bench.el ends here
