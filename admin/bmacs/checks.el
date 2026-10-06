;;; checks.el --- Isolated Bmacs packaging checks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Loaded only by admin/bmacs/manage.py in a batch process or private daemon.
;; Hidden frames exercise geometry and lifecycle, not visible painting.

;;; Code:

(require 'ert)
(require 'json)

(defconst bmacs-checks--root
  (expand-file-name "../../" (file-name-directory load-file-name)))

(load (expand-file-name "test/src/xdisp-tests.el" bmacs-checks--root) nil t)
(load (expand-file-name "test/lisp/gpu-tests.el" bmacs-checks--root) nil t)

(defun bmacs-checks-run (graphical output)
  "Run isolated checks, using a hidden NS frame when GRAPHICAL is non-nil.
Write ERT counts as JSON to OUTPUT.  The caller checks failures and skips."
  (let ((frame (if graphical
                   (make-frame '((window-system . ns) (visibility . nil)
                                 (width . 80) (height . 24)))
                 (selected-frame)))
        stats)
    (unwind-protect
        (with-selected-frame frame
          (setq stats (ert-run-tests-batch
                       '(or "^xdisp-test" "^gpu-frame-teardown$"))))
      (when (and graphical (frame-live-p frame))
        (delete-frame frame t)))
    ;; Allow deferred native callbacks to run after frame deletion.
    (sleep-for 0.2)
    (with-temp-file output
      (insert (json-encode
               `((passed . ,(ert-stats-completed-expected stats))
                 (failed . ,(ert-stats-completed-unexpected stats))
                 (skipped . ,(ert-stats-skipped stats))))))))

(provide 'bmacs-checks)
;;; checks.el ends here
