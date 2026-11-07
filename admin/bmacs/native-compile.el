;;; native-compile.el --- Batch worker for Bmacs package compilation -*- lexical-binding: t; -*-

;;; Commentary:
;; Run only in a separate batch Emacs, never in the interactive session.

;;; Code:

(require 'comp)
(require 'comp-run)
(require 'bob-elpaca)

(defun bmacs-update--print-native-output (start end _old-length)
  "Print inserted compiler text between START and END to stdout."
  (when (< start end)
    (princ (buffer-substring-no-properties start end))))

(defun bmacs-update--native-compile (packages)
  "Compile PACKAGES with background workers and wait for their output."
  (unless noninteractive
    (error "Package compilation must run in a separate batch Emacs"))
  (with-current-buffer (get-buffer-create comp-async-buffer-name)
    (unless (derived-mode-p 'compilation-mode)
      (emacs-lisp-compilation-mode))
    (add-hook 'after-change-functions #'bmacs-update--print-native-output nil t))
  (let (failed)
    (add-hook 'native-comp-async-cu-done-functions
              (lambda (file)
                (when-let* ((process (gethash file comp-async-compilations)))
                  (unless (zerop (process-exit-status process))
                    (push file failed)))))
    (let ((files (bob/elpaca-native-compile packages)))
      (while (or comp-files-queue (> (comp--async-runnings) 0))
        (accept-process-output nil 0.1))
      (dolist (file files)
        (let ((native (comp-el-to-eln-filename file)))
          (unless (and (file-exists-p native)
                       (not (file-newer-than-file-p (concat file "c") native)))
            (push file failed))))
      (when failed
        (error "Native compilation failed: %s"
               (mapconcat #'identity (delete-dups failed) ", ")))
      (message "NATIVE COMPILED: %d package files" (length files)))))

(provide 'bmacs-update-native-compile)
;;; native-compile.el ends here
