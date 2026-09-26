;;; mode-line-rows-tests.el --- Mode-line row tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; Check the window geometry when mode-line rows change.

;;; Code:

(require 'ert)

(ert-deftest mode-line-rows-format-window-height ()
  "Two mode-line formats reserve two rows and honor window overrides."
  (skip-unless (not window-system))
  (let* ((window (selected-window))
         (original (window-buffer window))
         (buffer (generate-new-buffer " *mode-line-rows-test*")))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (with-current-buffer buffer
            (setq-local mode-line-format "base")
            ;; Read the original height first to exercise the window cache.
            (should (= (window-body-height window)
                       (- (window-total-height window) 1)))
            (setq-local mode-line-rows-format '(("top") ("bottom")))
            (should (= (window-body-height window)
                       (- (window-total-height window) 2)))
            (set-window-parameter window 'mode-line-format "override")
            (should (= (window-body-height window)
                       (- (window-total-height window) 1)))
            (set-window-parameter window 'mode-line-format nil)
            (should (= (window-body-height window)
                       (- (window-total-height window) 2)))
            (setq-local mode-line-rows-format nil)
            (should (= (window-body-height window)
                       (- (window-total-height window) 1)))))
      (set-window-parameter window 'mode-line-format nil)
      (set-window-buffer window original)
      (kill-buffer buffer))))

(ert-deftest mode-line-rows-format-small-window ()
  "Keep one text row when a window cannot fit two mode-line rows."
  (skip-unless (not window-system))
  (let ((window-min-height 2))
    (save-window-excursion
      (let* ((small (split-window (selected-window) -2 'below))
             (original (window-buffer small))
             (buffer (generate-new-buffer " *small-mode-line-rows-test*")))
        (unwind-protect
            (progn
              (set-window-buffer small buffer)
              (with-current-buffer buffer
                (setq-local mode-line-rows-format '("top" "bottom"))
                (should (= (window-total-height small) 2))
                (should (= (window-body-height small) 1))
                (should (= (window-mode-line-height small) 1))
                (setq-local mode-line-format nil)
                (should (= (window-body-height small) 2))
                (should (= (window-mode-line-height small) 0))))
          (set-window-buffer small original)
          (kill-buffer buffer))))))

(ert-deftest mode-line-rows-format-graphical-height ()
  "Measure both mode-line rows on a graphical frame."
  (skip-unless (display-graphic-p))
  (let* ((window (selected-window))
         (original (window-buffer window))
         (buffer (generate-new-buffer " *graphical-mode-line-rows-test*")))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (with-current-buffer buffer
            (setq-local mode-line-format "base")
            (let ((one (window-mode-line-height window))
                  (body (window-body-height window t)))
              (setq-local mode-line-rows-format
                          '(("left" mode-line-format-right-align "right")
                            "bottom"))
              (should (= (window-mode-line-height window) (* 2 one)))
              (should (= (window-body-height window t) (- body one)))
              (should (= (- (cdr (window-text-pixel-size
                                   window nil nil nil nil 'mode-line))
                            (cdr (window-text-pixel-size window)))
                         (* 2 one)))
              (setq-local mode-line-rows-format nil)
              (should (= (window-mode-line-height window) one))
              (should (= (window-body-height window t) body)))))
      (set-window-buffer window original)
      (kill-buffer buffer))))

(ert-deftest mode-line-rows-format-graphical-small-window ()
  "Keep one mode-line row in a pixelwise short graphical window."
  (skip-unless (display-graphic-p))
  (let ((window-min-height 2)
        (window-resize-pixelwise t))
    (save-window-excursion
      (let* ((small (split-window (selected-window) -2 'below))
             (original (window-buffer small))
             (buffer (generate-new-buffer
                      " *small-graphical-mode-line-rows-test*")))
        (unwind-protect
            (progn
              (window-resize small 1 nil nil t)
              (set-window-buffer small buffer)
              (with-current-buffer buffer
                (setq-local mode-line-format "base")
                (let ((one (window-mode-line-height small)))
                  (setq-local mode-line-rows-format '("top" "bottom"))
                  (should (= (window-pixel-height small)
                             (1+ (* 2 (frame-char-height)))))
                  (should (= (window-mode-line-height small) one))
                  (should (= (window-body-height small t)
                             (- (window-pixel-height small) one)))))
          (set-window-buffer small original)
          (kill-buffer buffer)))))))

(provide 'mode-line-rows-tests)
;;; mode-line-rows-tests.el ends here
