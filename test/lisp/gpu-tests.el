;;; gpu-tests.el --- GPU frame lifecycle tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; Exercise native callbacks during GPU frame teardown.

;;; Code:

(require 'ert)

(ert-deftest gpu-frame-teardown ()
  "Deleting an animated GPU frame must leave the event loop usable."
  (skip-unless (and (eq window-system 'ns)
                    (fboundp 'gpu-enable-for-frame)
                    (gpu-backend-p)))
  (let ((animations (alist-get 'animations (gpu-animation-status))))
    (unwind-protect
        (progn
          (gpu-animations t)
          (dotimes (_ 3)
            (let ((frame (make-frame '((visibility . nil)
                                       (width . 40) (height . 12)))))
              (unwind-protect
                  (progn
                    (should (gpu-enable-for-frame frame))
                    ;; Re-enabling must not register duplicate observers.
                    (should (gpu-enable-for-frame frame))
                    (set-frame-size frame 44 14))
                (when (frame-live-p frame)
                  (delete-frame frame t)))
              (should-not (frame-live-p frame)))
            ;; Let queued display-link and deferred-present callbacks run.
            (sleep-for 0.1)))
      (gpu-animations animations))))

(provide 'gpu-tests)
;;; gpu-tests.el ends here
