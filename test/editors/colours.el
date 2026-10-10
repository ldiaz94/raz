;; Checks each token of Colours.expect has the face it should.
(let ((wants (split-string (with-temp-buffer
                             (insert-file-contents "test/editors/Colours.expect")
                             (buffer-string))
                           "\n" t)))
  (find-file "test/editors/Colours.jed")
  (font-lock-ensure)
  (dolist (want wants)
    (let* ((w (split-string want))
           (face (save-excursion
                   (goto-char (point-min))
                   (forward-line (1- (string-to-number (nth 0 w))))
                   (forward-char (1- (string-to-number (nth 1 w))))
                   (get-text-property (point) 'face)))
           (face (if (listp face) (car face) face))
           (kind (pcase face
                   ((or 'font-lock-comment-face 'font-lock-comment-delimiter-face) "comment")
                   ('font-lock-keyword-face "keyword")
                   ('font-lock-string-face "string")
                   ('font-lock-type-face "type")
                   ('font-lock-builtin-face "builtin")
                   ('font-lock-constant-face "constant"))))
      ;; numbers and constants share a face
      (unless (or (equal kind (nth 2 w))
                  (and (equal kind "constant") (equal (nth 2 w) "number")))
        (message "%s: %s" want face)
        (kill-emacs 3)))))
