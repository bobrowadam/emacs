;;; mode-line-rows-tests.el --- Mode-line row tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; Check the window geometry when mode-line rows change.

;;; Code:

(require 'ert)

(defvar mode-line-rows-tests--rendered 0)
(defvar mode-line-rows-tests--fallback-rendered 0)
(defvar mode-line-rows-tests--help-called nil)

(defun mode-line-rows-tests--clear-format-help (window)
  (setq mode-line-rows-tests--help-called t)
  (with-current-buffer (window-buffer window)
    (setq-local mode-line-rows-format nil))
  "test")

(defun mode-line-rows-tests--enable-format-help (window)
  (unless mode-line-rows-tests--help-called
    (setq mode-line-rows-tests--help-called t)
    (with-current-buffer (window-buffer window)
      (setq-local mode-line-rows-format
                  (list "top" (propertize "bottom" 'face '(:height 2.0))))))
  "test")

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

(ert-deftest mode-line-rows-format-inactive-face-fallback ()
  "Render two active rows, then fall back for a tall inactive face."
  (skip-unless (and (display-graphic-p)
                    (frame-visible-p (selected-frame))))
  (let* ((frame (selected-frame))
         (active-height (face-attribute 'mode-line :height frame))
         (active-box (face-attribute 'mode-line :box frame))
         (inactive-height (face-attribute 'mode-line-inactive :height frame))
         (inactive-box (face-attribute 'mode-line-inactive :box frame))
         (window-min-height 2)
         (window-resize-pixelwise t)
         (mode-line-rows-tests--rendered 0)
         (mode-line-rows-tests--fallback-rendered 0))
    (unwind-protect
        (save-window-excursion
          (set-face-attribute 'mode-line frame :height 1.0 :box nil)
          (set-face-attribute 'mode-line-inactive frame :height 2.0 :box nil)
          (let* ((small (split-window (selected-window) -3 'below))
                 (original (window-buffer small))
                 (buffer (generate-new-buffer " *inactive-mode-line-test*")))
            (unwind-protect
                (progn
                  (set-window-buffer small buffer)
                  (with-current-buffer buffer
                    (setq-local mode-line-format
                                '(:eval (progn
                                          (setq mode-line-rows-tests--fallback-rendered
                                                (1+ mode-line-rows-tests--fallback-rendered))
                                          "fallback")))
                    (setq-local mode-line-rows-format
                                '((:eval (progn (setq mode-line-rows-tests--rendered
                                                    (1+ mode-line-rows-tests--rendered)) "top"))
                                  (:eval (progn (setq mode-line-rows-tests--rendered
                                                    (1+ mode-line-rows-tests--rendered)) "bottom")))))
                  (save-selected-window
                    (select-window small)
                    (setq mode-line-rows-tests--rendered 0)
                    (force-mode-line-update t)
                    (redisplay t)
                    (should (> mode-line-rows-tests--rendered 0)))
                  (setq mode-line-rows-tests--rendered 0
                        mode-line-rows-tests--fallback-rendered 0)
                  (force-mode-line-update t)
                  (redisplay t)
                  (should (> mode-line-rows-tests--fallback-rendered 0))
                  (should (= mode-line-rows-tests--rendered 0))
                  (should (>= (window-body-height small t)
                              (frame-char-height))))
              (set-window-buffer small original)
              (kill-buffer buffer))))
      (set-face-attribute 'mode-line frame :height active-height :box active-box)
      (set-face-attribute 'mode-line-inactive frame
                          :height inactive-height :box inactive-box))))

(ert-deftest mode-line-rows-format-short-window-decorations ()
  "A tall header and mode line must leave a complete text row."
  (skip-unless (and (display-graphic-p)
                    (frame-visible-p (selected-frame))))
  (let* ((frame (selected-frame))
         (old-height (face-attribute 'header-line :height frame))
         (old-box (face-attribute 'header-line :box frame))
         (window-min-height 2)
         (window-resize-pixelwise t))
    (unwind-protect
        (save-window-excursion
          (set-face-attribute 'header-line frame :height 2.0 :box nil)
          (let* ((small (split-window (selected-window) -4 'below))
                 (original (window-buffer small))
                 (buffer (generate-new-buffer " *decorated-mode-line-test*")))
            (unwind-protect
                (progn
                  (set-window-buffer small buffer)
                  (with-current-buffer buffer
                    (setq-local mode-line-format "fallback")
                    (setq-local mode-line-rows-format '("top" "bottom"))
                    (setq-local header-line-format "header"))
                  (force-mode-line-update t)
                  (redisplay t)
                  (should (> (window-header-line-height small)
                             (frame-char-height)))
                  (should (>= (window-body-height small t)
                              (frame-char-height))))
              (set-window-buffer small original)
              (kill-buffer buffer))))
      (set-face-attribute 'header-line frame :height old-height :box old-box))))

(ert-deftest mode-line-rows-format-help-echo-change ()
  "Recheck mode-line eligibility after the default help callback."
  (skip-unless (and (display-graphic-p)
                    (frame-visible-p (selected-frame))))
  (let* ((window (selected-window))
         (original (window-buffer window))
         (buffer (generate-new-buffer " *mode-line-help-change-test*"))
         (mode-line-rows-tests--help-called nil))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (with-current-buffer buffer
            (setq-local mode-line-format nil)
            (setq-local mode-line-rows-format '("top" "bottom"))
            (setq-local mode-line-default-help-echo
                        #'mode-line-rows-tests--clear-format-help))
          (force-mode-line-update t)
          (redisplay t)
          (should mode-line-rows-tests--help-called)
          (should-not (buffer-local-value 'mode-line-rows-format buffer))
          (should (= (window-mode-line-height window) 0)))
      (set-window-buffer window original)
      (kill-buffer buffer))))

(ert-deftest mode-line-rows-format-help-echo-enables-rows ()
  "Retry redisplay if the help callback enables two rows after sizing."
  (skip-unless (and (display-graphic-p)
                    (frame-visible-p (selected-frame))))
  (let* ((window (selected-window))
         (original (window-buffer window))
         (buffer (generate-new-buffer " *mode-line-help-enable-test*"))
         (mode-line-rows-tests--help-called nil))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (with-current-buffer buffer
            (setq-local mode-line-format "base")
            (let ((one (window-mode-line-height window)))
              (setq-local mode-line-default-help-echo
                          #'mode-line-rows-tests--enable-format-help)
              (force-mode-line-update t)
              (redisplay t)
              (should mode-line-rows-tests--help-called)
              (should (> (window-mode-line-height window) (* 2 one))))))
      (set-window-buffer window original)
      (kill-buffer buffer))))

(ert-deftest mode-line-rows-format-tab-eval-disables-itself ()
  "Keep the header row correct when a tab-line evaluation removes the tab."
  (skip-unless (and (display-graphic-p)
                    (frame-visible-p (selected-frame))))
  (let* ((window (selected-window))
         (original (window-buffer window))
         (buffer (generate-new-buffer " *mode-line-tab-eval-test*")))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (with-current-buffer buffer
            (setq-local tab-line-format
                        '(:eval (progn (setq-local tab-line-format nil) "tab")))
            (setq-local header-line-format "header")
            (setq-local mode-line-rows-format nil))
          (force-mode-line-update t)
          (redisplay t)
          (should-not (window-line-height 'tab-line window))
          (should (window-line-height 'header-line window)))
      (set-window-buffer window original)
      (kill-buffer buffer))))

(provide 'mode-line-rows-tests)
;;; mode-line-rows-tests.el ends here
