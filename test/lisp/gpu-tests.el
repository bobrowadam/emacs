;;; gpu-tests.el --- GPU frame lifecycle tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; Exercise native callbacks during GPU frame teardown.

;;; Code:

(require 'ert)
(require 'seq)

(ert-deftest gpu-pump-ignores-terminal-frame ()
  "The shared pump must safely ignore a live non-NS frame."
  (skip-unless (fboundp 'gpu-pump-tick))
  (let ((frame (seq-find (lambda (frame) (eq (framep frame) t)) (frame-list))))
    (skip-unless frame)
    (should (= 0 (gpu-pump-tick frame)))))

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

(ert-deftest gpu-border-style-validation ()
  "Reject malformed styles before touching a frame, including on a terminal."
  (skip-unless (fboundp 'gpu-border-set))
  (let ((rect '(10 10 100 40)))
    (dolist (style '(nil (:corner-radius 0 :stroke-width 1 :opacity 0.3
                         :cycle-duration 8 :runner-fraction 0.02 :glow-opacity 0)
                        (:runner-fraction 0) (:runner-fraction 1)))
      (should-not (gpu-border-set 1 rect rect 'running #xffffff
                                   'not-a-frame style)))
    (dolist (style '((:corner-radius -1) (:stroke-width 0) (:opacity -0.1)
                    (:opacity 1.1) (:cycle-duration 0) (:cycle-duration 1e-300)
                    (:runner-fraction -0.1) (:runner-fraction 1.1)
                    (:glow-opacity 1.1) (:glow-opacity "bright")
                    (:opacity 1.0e+INF) (:opacity 0.0e+NaN)
                    (:unknown 1) (:opacity) (:opacity . 1) not-a-list))
      (should-error (gpu-border-set 1 rect rect 'running #xffffff
                                     'not-a-frame style)))
    (let ((circular (list :opacity 1)))
      (setcdr (last circular) circular)
      (should-error (gpu-border-set 1 rect rect 'running #xffffff
                                     'not-a-frame circular)))))

(ert-deftest gpu-border-update-forwards-style ()
  "Forward optional styles without changing existing call defaults."
  (require 'gpu)
  (let ((gpu--border-frames nil) calls)
    (cl-letf (((symbol-function 'gpu-border-set)
               (lambda (&rest args) (push args calls) t))
              ((symbol-function 'gpu--pump-start) #'ignore))
      (should (gpu-border-update 1 '(0 0 100 40) '(0 0 100 40)
                                 'idle #xffffff))
      (should-not (nth 6 (car calls)))
      (should (gpu-border-update 1 '(0 0 100 40) '(0 0 100 40)
                                 'running #xffffff nil '(:opacity 0.2)))
      (should (equal (nth 6 (car calls)) '(:opacity 0.2)))
      (should (eq (nth 5 (car calls)) (selected-frame))))))

(ert-deftest gpu-border-style-native-lifecycle ()
  "Style-only updates take effect without replacing the native border."
  (skip-unless (and (eq window-system 'ns)
                    (fboundp 'gpu-border-set) (gpu-backend-p)))
  (let ((animations (alist-get 'animations (gpu-animation-status)))
        (frame (make-frame '((visibility . nil) (width . 40) (height . 12)))))
    (unwind-protect
        (progn
          (gpu-animations nil)
          (should (gpu-enable-for-frame frame))
          ;; Both the original arity and an explicit default style work.
          (should (gpu-border-set 1 '(10 10 100 40) '(0 0 300 200)
                                  'idle #xffffff frame))
          (should (gpu-border-set 1 '(10 10 100 40) '(0 0 300 200)
                                  'idle #xffffff frame
                                  '(:corner-radius 11 :stroke-width 1.5
                                    :opacity 1 :cycle-duration 3.6
                                    :runner-fraction 0.11 :glow-opacity 0.65)))
          (should (gpu-border-set 1 '(10 10 100 40) '(0 0 300 200)
                                  'running #xffffff frame
                                  '(:corner-radius 0 :stroke-width 4
                                    :opacity 0.2 :cycle-duration 8
                                    :runner-fraction 0.02 :glow-opacity 0)))
          ;; Validation must not remove or replace an accepted record.
          (should-error (gpu-border-set 1 '(10 10 100 40) '(0 0 300 200)
                                        'idle #xffffff frame '(:opacity 2)))
          (should (gpu-border-remove 1 frame))
          (should-not (gpu-border-remove 1 frame)))
      (when (frame-live-p frame) (delete-frame frame t))
      (gpu-animations animations))))


(ert-deftest gpu-decoration-validation ()
  "Malformed snapshots do not depend on a graphical frame."
  (skip-unless (fboundp 'gpu--decoration-create))
  (require 'gpu)
  (let ((base '(:rect (1 2 40 40) :clip (0 0 300 300))))
    (dolist (patch '((:shape line :rect (100 50 -20 -30))
                     (:shape line :rect (100 50 20 -30))
                     (:shape line :rect (0 0 0 0))
                     (:shape arc :sweep-angle -3.14) (:fill 0 :stroke nil)
                     (:opacity 0) (:clip (0 0 0 0))))
      (should-not (gpu--decoration-create (gpu--decoration-merge base patch) 'no-frame)))
    (dolist (patch '((:shape unknown) (:radius -1) (:radius -1e-300) (:opacity -1e-300) (:opacity 2)
                     (:stroke-width 0) (:fill -1) (:stroke "white")
                     (:rect (0 0 0 1)) (:rect (0 0 1))
                     (:clip (0 0 -1 1)) (:shape circle :rect (0 0 40 20))
                     (:shape arc :fill 0) (:shape line :fill 1)
                     (:sweep-angle 7) (:z 0.5) (:opacity 0.0e+NaN)
                     (:radius 1.0e+INF) (:unknown 1)))
      (should-error (gpu--decoration-create (gpu--decoration-merge base patch) 'no-frame)))
    (dolist (bad '((:rect) (:rect . 1) (:rect (0 0 1 1) :rect (0 0 2 2)) not-a-list))
      (should-error (gpu--decoration-create bad 'no-frame)))
    (let ((circular (list :rect '(0 0 1 1))))
      (setcdr (last circular) circular)
      (should-error (gpu--decoration-create circular 'no-frame)))))

(ert-deftest gpu-decoration-owner-and-transaction ()
  "Failed patches preserve state; owners release simultaneous users."
  (require 'gpu)
  (let ((gpu--decorations nil) (gpu--decoration-frames nil)
        (next 0) deleted snapshots)
    (cl-letf (((symbol-function 'gpu--decoration-create)
               (lambda (_properties _frame) (cl-incf next)))
              ((symbol-function 'gpu--decoration-set)
               (lambda (id properties _frame cancel)
                 (when (plist-get properties :bad) (error "Invalid"))
                 (push (list id properties cancel) snapshots) t))
              ((symbol-function 'gpu--decoration-remove)
               (lambda (id _frame) (push id deleted) t))
              ((symbol-function 'gpu--pump-start) #'ignore))
      (let ((buffer (generate-new-buffer " gpu-owner")) a b)
        (unwind-protect
            (progn
              (setq a (gpu-decoration-create '(:rect (0 0 10 10)) nil buffer)
                    b (gpu-decoration-create '(:rect (0 0 10 10)) nil buffer))
              (should-not (= (gpu--decoration-id a) (gpu--decoration-id b)))
              (should (gpu-decoration-update a '(:rect (2 3 10 10))))
              (should (= (nth 2 (car snapshots)) 1))
              (should (gpu-decoration-update a '(:stroke 123)))
              (should (= (nth 2 (car snapshots)) 0))
              (let ((before (copy-tree (gpu--decoration-properties a))))
                (should-error (gpu-decoration-update a '(:bad t)))
                (should (equal before (gpu--decoration-properties a))))
              (should-error (gpu-decoration-update a '(:opacity 1 :opacity 0)))
              (kill-buffer buffer)
              (should (= (length deleted) 2))
              (should-not gpu--decorations)
              (should-not (gpu-decoration-update a '(:opacity 1)))
              (should-not (gpu-decoration-delete a)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest gpu-decoration-anchor-lifecycle ()
  "Window reassignment releases markers and does not alter buffer text."
  (require 'gpu)
  (let ((gpu--decorations nil) (gpu--decoration-frames nil)
        (window (selected-window)) deleted)
    (save-window-excursion
      (let ((buffer (generate-new-buffer " gpu-anchor")))
        (unwind-protect
            (cl-letf (((symbol-function 'gpu--decoration-create) (lambda (&rest _) 1))
                      ((symbol-function 'gpu--decoration-set) (lambda (&rest _) t))
                      ((symbol-function 'gpu--decoration-remove)
                       (lambda (&rest _) (setq deleted t)))
                      ((symbol-function 'gpu--decoration-anchor) (lambda (&rest _) t))
                      ((symbol-function 'gpu--pump-start) #'ignore))
              (set-window-buffer window buffer)
              (with-current-buffer buffer
                (insert "one\ntwo\n")
                (let* ((text (buffer-string))
                       (handle (gpu-decoration-create '(:rect (0 0 10 10))))
                       start)
                  (gpu-decoration-anchor handle window 1 (point-max))
                  (setq start (gpu--decoration-start handle))
                  (gpu--decoration-redisplay window)
                  (should (equal text (buffer-string)))
                  (set-window-buffer window (get-buffer-create "*scratch*"))
                  (gpu--decoration-prune)
                  (should deleted)
                  (should-not (marker-buffer start))
                  (should-not gpu--decorations))))
          (kill-buffer buffer))))))

(ert-deftest gpu-decoration-native-anchors-follow-committed-rows ()
  "Resolve streaming anchors after wrapping, layout changes and pixel scrolling."
  (skip-unless (and (eq window-system 'ns) (gpu-backend-p)
                    (fboundp 'gpu--decoration-anchor)))
  (require 'gpu)
  (let ((frame (make-frame '((visibility . nil) (width . 42) (height . 20)
                             (no-accept-focus . t) (no-focus-on-map . t)
                             (z-group . below) (tool-bar-lines . 0))))
        (buffer (generate-new-buffer " *gpu-committed-anchor*"))
        handle)
    (unwind-protect
        (with-selected-frame frame
          (gpu-enable-for-frame frame)
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (setq mode-line-format nil)
            (insert "Before\n")
            (let ((start (copy-marker (point))) end)
              (insert "First response row\nSecond response row\n")
              (setq end (copy-marker (point)))
              (insert "Following activity\n")
              (set-marker-insertion-type end t)
              (goto-char (point-min))
              (setq handle (gpu-decoration-create '(:rect (0 0 1 1) :opacity 0.5)))
              (gpu-decoration-anchor handle (selected-window) start end '(0 3 0 4))
              (make-frame-visible frame)
              (lower-frame frame)
              (cl-labels
                  ((check ()
                     (redisplay t)
                     (let* ((window (selected-window))
                            (edges (window-inside-pixel-edges window))
                            (y1 (+ (nth 1 edges)
                                   (cdr (posn-x-y (posn-at-point start window)))))
                            (y2 (+ (nth 1 edges)
                                   (cdr (posn-x-y (posn-at-point end window)))))
                            (state (gpu--decoration-state
                                    (gpu--decoration-id handle) frame)))
                       (should (equal (car state)
                                      (list (float (nth 0 edges)) (float (- y1 3))
                                            (float (- (nth 2 edges) (nth 0 edges)))
                                            (float (+ (- y2 y1) 7)))))
                       (should (= (nth 1 state) 0.5)))))
                (check)
                (let ((before (car (gpu--decoration-state
                                   (gpu--decoration-id handle) frame))))
                  (goto-char end)
                  (insert "A streamed row long enough to wrap across the window edge.\n")
                  ;; Pending text must not alter the previous committed geometry.
                  (should (equal before (car (gpu--decoration-state
                                              (gpu--decoration-id handle) frame))))
                  (check))
                (setq-local line-spacing 7)
                (force-window-update (selected-window))
                (check)
                (set-window-vscroll (selected-window) 3 t)
                (check))
              (set-marker start nil)
              (set-marker end nil))))
      (gpu-decoration-delete handle)
      (when (frame-live-p frame) (delete-frame frame t))
      (kill-buffer buffer))))

(ert-deftest gpu-decoration-native-anchor-keeps-spacing-row-local ()
  "A large preceding gap must not shorten the following row's outline."
  (skip-unless (and (eq window-system 'ns) (gpu-backend-p)
                    (fboundp 'gpu--decoration-anchor)))
  (require 'gpu)
  (let ((frame (make-frame '((visibility . nil) (width . 50) (height . 12)
                             (no-accept-focus . t) (no-focus-on-map . t)
                             (z-group . below) (tool-bar-lines . 0))))
        (buffer (generate-new-buffer " *gpu-row-local-spacing*"))
        handle)
    (unwind-protect
        (with-selected-frame frame
          (gpu-enable-for-frame frame)
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (setq mode-line-format nil)
            (insert "Earlier response" (propertize "\n" 'line-spacing 42))
            (let ((start (point)) end)
              (insert "Final response")
              (setq end (point))
              (insert (propertize "\n" 'line-spacing 21) "Following prompt\n")
              (goto-char (point-min))
              (setq handle (gpu-decoration-create '(:rect (0 0 1 1))))
              (gpu-decoration-anchor handle (selected-window) start end)
              (make-frame-visible frame)
              (lower-frame frame)
              (redisplay t)
              (should (equal (car (gpu--decoration-state (gpu--decoration-id handle) frame))
                             (mapcar #'float (car (gpu-decoration-region
                                                   (selected-window) start end))))))))
      (gpu-decoration-delete handle)
      (when (frame-live-p frame) (delete-frame frame t))
      (kill-buffer buffer))))

(ert-deftest gpu-decoration-native-retained-tracks ()
  "Updates preserve other tracks and invalid input cannot replace accepted state."
  (skip-unless (and (eq window-system 'ns) (gpu-backend-p)
                    (fboundp 'gpu--decoration-create)))
  (require 'gpu)
  (let ((frame (make-frame '((visibility . nil) (width . 40) (height . 12)))) a b)
    (unwind-protect
        (progn
          (gpu-enable-for-frame frame)
          (setq a (gpu-decoration-create '(:rect (10 10 40 40)) frame)
                b (gpu-decoration-create '(:shape line :rect (100 100 -20 -30)) frame))
          (should a) (should b)
          (should (gpu-decoration-animate a :opacity 0 0.02 'ease-out))
          (sleep-for 0.03)
          (should (gpu-decoration-update a '(:rect (20 20 40 40))))
          (let ((state (gpu--decoration-state (gpu--decoration-id a) frame)))
            (should (= (nth 1 state) 0))
            ;; A hidden frame has not encoded the terminal value yet.
            (should (nth 3 state)))
          (should (gpu-decoration-animate b :rect '(150 120 20 -30) 0.02 'ease-in-out t))
          (should (nth 2 (gpu--decoration-state (gpu--decoration-id b) frame)))
          (should (gpu-decoration-animate a :rect '(40 50 60 60) 0.02 'linear))
          (sleep-for 0.03)
          (should (equal (car (gpu--decoration-state (gpu--decoration-id a) frame))
                         '(40.0 50.0 60.0 60.0)))
          (should (gpu-decoration-update a '(:stroke 0)))
          (should (nth 2 (gpu--decoration-state (gpu--decoration-id a) frame)))
          (should (gpu-decoration-update a '(:rect (30 30 40 40))))
          (should-not (nth 2 (gpu--decoration-state (gpu--decoration-id a) frame)))
          (should-error (gpu-decoration-update a '(:opacity 2)))
          (should-error (gpu-decoration-animate a :rect '(0 0 -1 1) 1))
          (should-error (gpu-decoration-animate a :opacity 1 0))
          (should (gpu-decoration-update a '(:opacity 0.6)))
          (should-not (nth 3 (gpu--decoration-state (gpu--decoration-id a) frame)))
          (should (gpu-decoration-delete b))
          (should-not (gpu-decoration-delete b))
          (delete-frame frame t)
          (should-not (gpu--decoration-id a)))
      (gpu-decoration-delete a)
      (gpu-decoration-delete b)
      (when (frame-live-p frame) (delete-frame frame t)))))

(ert-deftest gpu-region-first-row-overhang-terminal ()
  "A terminal window needs no physical-ascent adjustment."
  (skip-unless (eq (framep (selected-frame)) t))
  (should (= 0 (gpu--window-first-row-overhang (selected-window)))))

(ert-deftest gpu-region-first-row-overhang ()
  "Region geometry includes the first row's physical ascent, even stale."
  (require 'gpu)
  (skip-unless (eq window-system 'ns))
  (skip-unless (find-font (font-spec :family "CommitMonoV143")))
  (let ((frame (make-frame '((visibility . nil) (width . 50) (height . 12)
                             (no-accept-focus . t) (no-focus-on-map . t)
                             (z-group . below) (tool-bar-lines . 0))))
        (buffer (generate-new-buffer " *gpu-region-overhang*")))
    (unwind-protect
        (with-selected-frame frame
          (set-face-attribute 'default frame :family "CommitMonoV143" :height 210)
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (setq mode-line-format nil)
            (insert (propertize "x" 'display "┤") "\nThinking\n")
            (goto-char (point-min))
            (make-frame-visible frame)
            (lower-frame frame)
            (redisplay t)
            (let* ((window (selected-window))
                   (top (nth 1 (window-inside-pixel-edges window)))
                   (logical (cdr (window-text-pixel-size window 1 3 nil nil nil t)))
                   (extra (gpu--window-first-row-overhang window))
                   (height (car (window-line-height 0 window))))
              ;; Assert that the fixture actually exercises the mismatch.
              (should (> extra 0))
              (should (= height (+ logical extra)))
              (should (= (+ top height)
                         (nth 1 (car (gpu-decoration-region window 3 11)))))
              (should (= height
                         (nth 3 (car (gpu-decoration-region window 1 3)))))
              ;; Invalidate the glyph matrix, without allowing redisplay.
              (put-text-property 1 2 'display "x")
              (should-not (window-line-height 0 window))
              (should (= 0 (gpu--window-first-row-overhang window)))
              (should (= (+ top logical)
                         (nth 1 (car (gpu-decoration-region window 3 11)))))
              (put-text-property 1 2 'display "┤")
              (should-not (window-line-height 0 window))
              (should (= extra (gpu--window-first-row-overhang window)))
              (should (= (+ top height)
                         (nth 1 (car (gpu-decoration-region window 3 11)))))
              ;; Pixel scrolling hides part of the first row; the next
              ;; row still starts at its visible bottom.
              (redisplay t)
              (set-window-vscroll window logical t)
              (redisplay t)
              (should (= (+ top (car (window-line-height 0 window)))
                         (nth 1 (car (gpu-decoration-region window 3 11)))))
              (set-window-vscroll window 0 t)
              ;; A tall glyph that wraps to the second row must not
              ;; enlarge the first row.
              (erase-buffer)
              (insert (make-string (1- (window-max-chars-per-line window)) ?a)
                      (propertize "x" 'display
                                  (propertize "┤" 'face '(:height 2.0)))
                      "\nThinking\n")
              (redisplay t)
              (let ((next (save-excursion (goto-char 1) (forward-line 1) (point))))
                (should (= 0 (gpu--window-first-row-overhang window)))
                (should (= (+ top (cdr (nth 1 (window-lines-pixel-dimensions
                                               window nil nil t))))
                           (nth 1 (car (gpu-decoration-region
                                        window next (+ next 8))))))))))
      (when (frame-live-p frame) (delete-frame frame t))
      (kill-buffer buffer))))

(ert-deftest gpu-region-end-above-window-start ()
  "A region that ends above the window start ends above the window top."
  (require 'gpu)
  (let ((buffer (generate-new-buffer " *gpu-region-above*"))
        (window (selected-window))
        (old (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (with-current-buffer buffer
            (dotimes (i 8) (insert (format "line %d\n" i)))
            (let* ((line (lambda (n) (save-excursion (goto-char 1) (forward-line n) (point))))
                   (origin (funcall line 4))
                   (top (nth 1 (window-inside-pixel-edges window)))
                   (row (cdr (window-text-pixel-size
                              window (funcall line 3) origin nil nil nil t)))
                   (bottom (lambda (end) (let ((rect (car (gpu-decoration-region
                                                           window 1 end))))
                                           (+ (nth 1 rect) (nth 3 rect))))))
              (set-window-start window origin)
              (should (> row 0))
              ;; Line 2's text ends one row above the window, as does the
              ;; start of line 3.
              (should (= (- top row) (funcall bottom (1- (funcall line 3)))))
              (should (= (- top row) (funcall bottom (funcall line 3))))
              (when (display-graphic-p)
                (unwind-protect
                    (progn
                      (set-window-vscroll window 5 t)
                      (should (= 5 (window-vscroll window t)))
                      (should (= (- top row 5)
                                 (funcall bottom (1- (funcall line 3)))))
                      (should (= (- top row 5)
                                 (funcall bottom (funcall line 3))))
                      ;; Rows below the window start move up too.
                      (let ((rect (car (gpu-decoration-region
                                        window (funcall line 5)
                                        (funcall line 6)))))
                        (should (= (- (+ top row) 5) (nth 1 rect)))
                        (should (= (- (+ top (* 2 row)) 5)
                                   (+ (nth 1 rect) (nth 3 rect))))))
                  (set-window-vscroll window 0 t))))))
      (set-window-buffer window old)
      (kill-buffer buffer))))

(ert-deftest gpu-region-bidi-wrapped-rows ()
  "Region rows match drawn rows in wrapped mixed-direction text.
Logical-order measurement wraps such text at other positions."
  (require 'gpu)
  (skip-unless (eq window-system 'ns))
  (skip-unless (find-font (font-spec :family "CommitMonoV143")))
  (let ((frame (make-frame '((visibility . nil) (width . 60) (height . 12)
                             (no-accept-focus . t) (no-focus-on-map . t)
                             (z-group . below) (tool-bar-lines . 0))))
        (buffer (generate-new-buffer " *gpu-region-bidi*"))
        (logical-errors 0))
    (unwind-protect
        (with-selected-frame frame
          (set-face-attribute 'default frame :family "CommitMonoV143" :height 210)
          (set-window-buffer (selected-window) buffer)
          (make-frame-visible frame)
          (lower-frame frame)
          (with-current-buffer buffer
            (setq mode-line-format nil word-wrap t)
            (insert "שלום עולם this is a test של טקסט מעורב with English words"
                    " בתוך שורה ארוכה מאוד וגם עוד כמה מילים\nend\n")
            (let ((window (selected-window))
                  (next (save-excursion (goto-char 1) (forward-line 1) (point))))
              (dolist (columns (number-sequence 30 80))
                (set-frame-width frame columns)
                ;; Start the window at the line start and partway through it.
                (dolist (first-row '(0 1))
                  (let ((origin (save-excursion
                                  (goto-char 1)
                                  (vertical-motion first-row window)
                                  (point))))
                    (set-window-start window origin)
                    (redisplay t)
                    (let ((top (nth 1 (window-inside-pixel-edges window)))
                          (overhang (gpu--window-first-row-overhang window))
                          (drawn (cons 0 (mapcar #'cdr (window-lines-pixel-dimensions
                                                        window nil nil t)))))
                      (save-excursion
                        (goto-char origin)
                        (while (< (point) next)
                          (let ((logical (cdr (window-text-pixel-size
                                               window origin (point) nil nil nil t))))
                            (unless (= (car drawn)
                                       (if (> logical 0) (+ logical overhang) logical))
                              (setq logical-errors (1+ logical-errors))))
                          (should (equal (list columns origin (point) (+ top (pop drawn)))
                                         (list columns origin (point)
                                               (nth 1 (car (gpu-decoration-region
                                                            window (point) (1+ (point))))))))
                          (unless (= (vertical-motion 1 window) 1)
                            (goto-char next)))))))))
            ;; Assert that the fixture actually exercises the mismatch.
            (should (> logical-errors 0))))
      (when (frame-live-p frame) (delete-frame frame t))
      (kill-buffer buffer))))

(provide 'gpu-tests)
;;; gpu-tests.el ends here
