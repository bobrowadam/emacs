;;; mtl.el --- compatibility shim for the renamed gpu.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.

;;; Commentary:

;; The GPU backend's user API moved from the mtl- prefix to gpu- in
;; 0.2 (gpu.el).  This shim keeps (require 'mtl) and the old function
;; names working; see the obsolete aliases in gpu.el.

;;; Code:

(require 'gpu)

;; gpu.el also does (provide 'mtl); this file exists so that
;; (require 'mtl) can still find a library by that name.

;;; mtl.el ends here
