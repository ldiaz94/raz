;;; jed-mode.el --- a major mode for jed  -*- lexical-binding: t -*-

;; Colours jed's reserved words, basic types, built-in procedures,
;; numbers, characters, strings and nested comments, and indents by
;; `jed-indent-offset': a block's statements one level in from the
;; word that opens it; end, until, else and elsif at that word's
;; level; match arms at the level of match; procedures, sections
;; (const, type, var) and module bodies at the left margin. The text
;; of a comment, and a line that goes on with the expression of the
;; line before, keep the indent they have.
;;
;; (add-to-list 'load-path "/path/to/jed/editor/emacs")
;; (require 'jed-mode)

;;; Code:

(defgroup jed nil "The jed programming language." :group 'languages)

(defcustom jed-indent-offset 4
  "Columns that a block's statements are indented by."
  :type 'integer :group 'jed)

(defconst jed-keywords
  '("and" "begin" "break" "by" "code" "const" "defer" "div" "do" "else"
    "elsif" "end" "extern" "for" "forward" "if" "import" "in" "link"
    "match" "mod" "module" "not" "of" "or" "packed" "proc" "record"
    "repeat" "return" "set" "shl" "shr" "then" "to" "type" "until" "var"
    "variant" "VOLATILE" "while" "xor"))

(defconst jed-types
  '("I8" "I16" "I32" "I64" "U8" "U16" "U32" "U64" "BOOL" "F32" "F64" "ERROR"))

(defconst jed-builtins
  '("SIZE" "ADR" "LEN" "NEW" "MSG" "SYSCALL" "FENCE" "CAS" "XCHG" "XADD"
    "ARGC" "ARGV" "INC" "DEC"))

(defvar jed-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; (* ... *), nested
    (modify-syntax-entry ?\( "()1n" st)
    (modify-syntax-entry ?\) ")(4n" st)
    (modify-syntax-entry ?* ". 23n" st)
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?\' "\"" st)
    (modify-syntax-entry ?\\ "\\" st)
    (modify-syntax-entry ?_ "_" st)
    (dolist (c '(?+ ?- ?/ ?= ?# ?< ?> ?: ?\; ?, ?. ?^ ?|))
      (modify-syntax-entry c "." st))
    st)
  "Syntax table for `jed-mode'.")

(defvar jed-font-lock-keywords
  `((,(regexp-opt jed-keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt jed-types 'symbols) . font-lock-type-face)
    (,(regexp-opt jed-builtins 'symbols) . font-lock-builtin-face)
    (,(regexp-opt '("true" "false" "nil") 'symbols) . font-lock-constant-face)
    ;; 123, 0FFH, 1.5, 2.0E-3
    ("\\_<[0-9][0-9A-F]*H\\_>\\|\\_<[0-9]+\\(?:\\.[0-9]+\\(?:E[-+]?[0-9]+\\)?\\)?\\_>"
     . font-lock-constant-face))
  "What `jed-mode' colours, besides strings and comments.")

;;; Indenting

(defconst jed--decl
  "^[ \t]*\\(?:module\\|import\\|link\\|extern\\|proc\\|const\\|type\\|var\\|begin\\)\\_>")
(defconst jed--leading "^[ \t]*\\(?:or\\|and\\)\\_>")
(defconst jed--block-word
  "\\_<\\(if\\|while\\|for\\|match\\|record\\|variant\\|begin\\|repeat\\|end\\|until\\)\\_>")

(defun jed--line (n)
  "The text of line N."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun jed--indent-of (n)
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (current-indentation)))

(defun jed--in-comment (n)
  "Whether line N starts inside a comment that began before it."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (back-to-indentation)
    (and (nth 4 (syntax-ppss))
         (not (looking-at "(\\*")))))

(defun jed--prev (n)
  "The last line before N that isn't blank, or 0."
  (let ((l (1- n)))
    (while (and (> l 0) (string-match-p "\\`[ \t]*\\'" (jed--line l)))
      (setq l (1- l)))
    l))

(defun jed--code (n)
  "Line N's code, without strings, characters and comments."
  (let ((line (jed--line n)))
    (when (jed--in-comment n)
      (setq line (if (string-match "\\*)" line) (substring line (match-end 0)) "")))
    ;; one pattern, so that whichever comes first is taken
    (setq line (replace-regexp-in-string
                "\"\\(?:[^\"\\\\]\\|\\\\.\\)*\"\\|'\\(?:[^'\\\\]\\|\\\\.\\)*'\\|(\\*.*?\\*)"
                (lambda (m) (if (string-prefix-p "(" m) "" "0")) line t t))
    (setq line (replace-regexp-in-string "(\\*.*\\'" "" line t t))
    (string-trim line)))

(defun jed--count (re s)
  (let ((n 0) (i 0))
    (while (string-match re s i)
      (setq n (1+ n) i (match-end 0)))
    n))

(defun jed--continues (n)
  "Whether the expression on line N goes on to the next line."
  (let ((code (jed--code n)))
    (or (> (jed--count "[([{]" code) (jed--count "[])}]" code))
        (string-match-p "\\(?:,\\|:=\\|[-+*/=#<>]\\|\\_<and\\|\\_<or\\)\\'" code))))

(defun jed--start (n)
  "The first line of the statement that ends on line N."
  (let ((l n) (done nil))
    (while (not done)
      (let ((p (jed--prev l)))
        (if (or (= p 0)
                (and (not (jed--continues p))
                     (not (string-match-p jed--leading (jed--line l)))))
            (setq done t)
          (setq l p))))
    l))

(defun jed--opens (code)
  "How many blocks CODE opens, less those it closes."
  (let ((n 0) (i 0) (case-fold-search nil))
    (while (string-match jed--block-word code i)
      (setq n (if (member (match-string 1 code) '("end" "until")) (1- n) (1+ n))
            i (match-end 0)))
    n))

(defun jed--opener (n)
  "The indent of the word that opens the block line N is in, or nil."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (let ((depth 0) (found nil) (case-fold-search nil))
      (while (and (not found) (re-search-backward jed--block-word nil t))
        (unless (nth 8 (syntax-ppss))
          (if (member (match-string 1) '("end" "until"))
              (setq depth (1+ depth))
            (if (= depth 0)
                (setq found (current-indentation))
              (setq depth (1- depth))))))
      found)))

(defun jed--comment-start (n)
  "Where the comment that line N, holding only comment, began."
  (let ((l n))
    (while (and (> l 1) (not (string-match-p "(\\*" (jed--line l))))
      (setq l (1- l)))
    l))

(defun jed-calculate-indent ()
  "The column line at point should start at, or nil to leave it."
  (let* ((case-fold-search nil)
         (n (line-number-at-pos))
         (cur (jed--line n))
         (prev (jed--prev n)))
    (catch 'done
      (when (jed--in-comment n) (throw 'done nil))
      (when (and (string-match-p jed--decl cur) (not (string-match-p "^[ \t]*proc[ \t]*(" cur)))
        (throw 'done 0))
      ;; a comment before a declaration goes with it, at the margin
      (when (string-match-p "^[ \t]*(\\*" cur)
        (let ((l n) (last (line-number-at-pos (point-max))))
          (while (and (< l last) (not (string-match-p "\\*)" (jed--line l))))
            (setq l (1+ l)))
          (setq l (1+ l))
          (while (and (<= l last) (string-match-p "\\`[ \t]*\\'" (jed--line l)))
            (setq l (1+ l)))
          (when (and (<= l last) (string-match-p jed--decl (jed--line l)))
            (throw 'done 0))))
      (when (string-match-p "^[ \t]*\\(?:end\\|until\\)\\_>" cur)
        (throw 'done (or (jed--opener n) 0)))
      (when (= prev 0) (throw 'done 0))
      (when (string-match-p "^[ \t]*\\(?:\\(?:else\\|elsif\\)\\_>\\||\\)" cur)
        (throw 'done (or (jed--opener n) (jed--indent-of prev))))
      (when (or (jed--continues prev) (string-match-p jed--leading cur))
        (throw 'done nil))
      (when (string= (jed--code prev) "")
        (throw 'done (jed--indent-of (jed--comment-start prev))))
      (let* ((start (jed--start prev))
             (ind (jed--indent-of start))
             (code (mapconcat #'jed--code (number-sequence start prev) " ")))
        (cond
         ((or (string-match-p "\\`\\(?:const\\|type\\|var\\)\\'" code)
              (and (string-match-p "\\`else\\_>" code) (>= (jed--opens code) 0))
              (string-match-p "\\`|.*:\\'" code)
              (string-match-p "\\`elsif\\_>.*\\_<then\\'" code))
          (+ ind jed-indent-offset))
         ((or (string-match-p "\\`|" code) (string-match-p "\\_<match\\_>.*\\_<of\\'" code))
          ind)
         ((> (jed--opens code) 0) (+ ind jed-indent-offset))
         (t ind))))))

(defun jed-indent-line ()
  "Indent the current line as jed's blocks say."
  (interactive)
  (let ((col (save-excursion (jed-calculate-indent)))
        (offset (- (current-column) (current-indentation))))
    (when col
      (indent-line-to col)
      (when (> offset 0) (move-to-column (+ col offset))))))

;;;###autoload
(define-derived-mode jed-mode prog-mode "jed"
  "Major mode for editing jed."
  :syntax-table jed-mode-syntax-table
  (setq-local font-lock-defaults '(jed-font-lock-keywords nil nil))
  (setq-local comment-start "(* ")
  (setq-local comment-end " *)")
  (setq-local comment-start-skip "(\\*+[ \t]*")
  (setq-local indent-tabs-mode nil)
  (setq-local indent-line-function #'jed-indent-line))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.jed\\'" . jed-mode))

(provide 'jed-mode)

;;; jed-mode.el ends here
