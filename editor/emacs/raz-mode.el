;;; raz-mode.el --- a major mode for raz  -*- lexical-binding: t -*-

;; Colours raz's reserved words, basic types, built-in procedures,
;; numbers, characters, strings, raw strings over lines and nested
;; comments, and indents by
;; `raz-indent-offset': a block's statements one level in from the
;; word that opens it; end, until, else and elsif at that word's
;; level; match arms at the level of match; procedures, sections
;; (const, type, var) and module bodies at the left margin. The text
;; of a comment or of a raw string, and a line that goes on with the
;; expression of the line before, keep the indent they have.
;;
;; (add-to-list 'load-path "/path/to/raz/editor/emacs")
;; (require 'raz-mode)

;;; Code:

(defgroup raz nil "The raz programming language." :group 'languages)

(defcustom raz-indent-offset 4
  "Columns that a block's statements are indented by."
  :type 'integer :group 'raz)

(defconst raz-keywords
  '("and" "begin" "break" "by" "code" "const" "continue" "defer" "div" "do" "else"
    "elsif" "end" "extern" "for" "forward" "if" "import" "in" "link"
    "match" "mod" "module" "not" "of" "or" "packed" "proc" "record"
    "repeat" "return" "set" "shl" "shr" "then" "to" "try" "type" "until"
    "var" "variant" "VOLATILE" "while" "xor"))

(defconst raz-types
  '("I8" "I16" "I32" "I64" "INT" "UINT" "U8" "U16" "U32" "U64" "BOOL" "F32" "F64" "ERROR"))

(defconst raz-builtins
  '("SIZE" "ADR" "LEN" "PTR" "NEW" "MSG" "SYSCALL" "FENCE" "CAS" "XCHG" "XADD"
    "ARGC" "ARGV" "INC" "DEC" "COPY" "ROL" "ROR" "MIN" "MAX"))

(defvar raz-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; (* ... *), nested
    (modify-syntax-entry ?\( "()1n" st)
    (modify-syntax-entry ?\) ")(4n" st)
    (modify-syntax-entry ?* ". 23n" st)
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?\' "\"" st)
    (modify-syntax-entry ?\\ "\\" st)
    (modify-syntax-entry ?` "." st)
    (modify-syntax-entry ?_ "_" st)
    (dolist (c '(?+ ?- ?/ ?= ?# ?< ?> ?: ?\; ?, ?. ?^ ?| ?& ?~))
      (modify-syntax-entry c "." st))
    st)
  "Syntax table for `raz-mode'.")

(defvar raz-font-lock-keywords
  `((,(regexp-opt raz-keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt raz-types 'symbols) . font-lock-type-face)
    (,(regexp-opt raz-builtins 'symbols) . font-lock-builtin-face)
    (,(regexp-opt '("true" "false" "nil") 'symbols) . font-lock-constant-face)
    ;; 123, 0FFH, 1.5, 2.0E-3
    ("\\_<[0-9][0-9A-F]*H\\_>\\|\\_<[0-9]+\\(?:\\.[0-9]+\\(?:E[-+]?[0-9]+\\)?\\)?\\_>"
     . font-lock-constant-face))
  "What `raz-mode' colours, besides strings and comments.")

;;; Raw strings

(defun raz--raw-string ()
  "Make the backquote just matched open a raw string, if it isn't in a
comment or string: it and the closing one string fences, and the
backslashes between them nothing special, since a raw string has no
escapes."
  (let ((open (match-beginning 0)))
    (unless (nth 8 (save-excursion (syntax-ppss open)))
      (put-text-property open (1+ open) 'syntax-table (string-to-syntax "|"))
      (when (search-forward "`" nil t)
        (put-text-property (1- (point)) (point) 'syntax-table (string-to-syntax "|"))
        (save-excursion
          (let ((close (1- (point))))
            (goto-char open)
            (while (search-forward "\\" close t)
              (put-text-property (1- (point)) (point) 'syntax-table (string-to-syntax ".")))))))))

(defconst raz--syntax-propertize
  (syntax-propertize-rules ("`" (0 (ignore (raz--raw-string))))))

;;; Indenting

(defconst raz--decl
  "^[ \t]*\\(?:module\\|import\\|link\\|extern\\|proc\\|const\\|type\\|var\\|begin\\|code\\)\\_>")
(defconst raz--leading "^[ \t]*\\(?:or\\|and\\)\\_>")
(defconst raz--block-word
  "\\_<\\(if\\|while\\|for\\|match\\|record\\|variant\\|begin\\|repeat\\|code\\|end\\|until\\)\\_>")

(defun raz--line (n)
  "The text of line N."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun raz--indent-of (n)
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (current-indentation)))

(defun raz--in-comment (n)
  "Whether line N starts inside a comment that began before it."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (back-to-indentation)
    (and (nth 4 (syntax-ppss))
         (not (looking-at "(\\*")))))

(defun raz--in-raw (n)
  "Whether line N starts inside a raw string, which only a raw string
can, since it alone runs over lines."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (eq (nth 3 (syntax-ppss)) t)))

(defun raz--prev (n)
  "The last line before N that isn't blank, or 0."
  (let ((l (1- n)))
    (while (and (> l 0) (string-match-p "\\`[ \t]*\\'" (raz--line l)))
      (setq l (1- l)))
    l))

(defun raz--code (n)
  "Line N's code, without strings, characters and comments."
  (let ((line (raz--line n)))
    (when (raz--in-comment n)
      (setq line (if (string-match "\\*)" line) (substring line (match-end 0)) "")))
    ;; and inside a raw string, after the string
    (when (raz--in-raw n)
      (setq line (if (string-match "`" line) (concat "0" (substring line (match-end 0))) "")))
    ;; one pattern, so that whichever comes first is taken
    (setq line (replace-regexp-in-string
                "\"\\(?:[^\"\\\\]\\|\\\\.\\)*\"\\|'\\(?:[^'\\\\]\\|\\\\.\\)*'\\|`[^`]*`\\|(\\*.*?\\*)"
                (lambda (m) (if (string-prefix-p "(" m) "" "0")) line t t))
    (setq line (replace-regexp-in-string "(\\*.*\\'" "" line t t))
    (setq line (replace-regexp-in-string "`.*\\'" "0" line t t))
    (string-trim line)))

(defun raz--count (re s)
  (let ((n 0) (i 0))
    (while (string-match re s i)
      (setq n (1+ n) i (match-end 0)))
    n))

(defun raz--continues (n)
  "Whether the expression on line N goes on to the next line."
  (let ((code (raz--code n)))
    (or (> (raz--count "[([{]" code) (raz--count "[])}]" code))
        (string-match-p "\\(?:,\\|:=\\|[-+*/&|=#<>]\\|\\_<and\\|\\_<or\\)\\'" code))))

(defun raz--start (n)
  "The first line of the statement that ends on line N."
  (let ((l n) (done nil))
    (while (not done)
      (let ((p (raz--prev l)))
        (if (or (= p 0)
                (and (not (raz--continues p))
                     (not (string-match-p raz--leading (raz--line l)))
                     (not (raz--in-raw l))))
            (setq done t)
          (setq l p))))
    l))

(defun raz--opens (code)
  "How many blocks CODE opens, less those it closes."
  (let ((n 0) (i 0) (case-fold-search nil))
    (while (string-match raz--block-word code i)
      (setq n (if (member (match-string 1 code) '("end" "until")) (1- n) (1+ n))
            i (match-end 0)))
    n))

(defun raz--opener (n)
  "The indent of the word that opens the block line N is in, or nil."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (let ((depth 0) (found nil) (case-fold-search nil))
      (while (and (not found) (re-search-backward raz--block-word nil t))
        (unless (nth 8 (syntax-ppss))
          (if (member (match-string 1) '("end" "until"))
              (setq depth (1+ depth))
            (if (= depth 0)
                (setq found (current-indentation))
              (setq depth (1- depth))))))
      found)))

(defun raz--comment-start (n)
  "Where the comment that line N, holding only comment, began."
  (let ((l n))
    (while (and (> l 1) (not (string-match-p "(\\*" (raz--line l))))
      (setq l (1- l)))
    l))

(defun raz-calculate-indent ()
  "The column line at point should start at, or nil to leave it."
  (let* ((case-fold-search nil)
         (n (line-number-at-pos))
         (cur (raz--line n))
         (prev (raz--prev n)))
    (catch 'done
      (when (or (raz--in-comment n) (raz--in-raw n)) (throw 'done nil))
      (when (and (string-match-p raz--decl cur) (not (string-match-p "^[ \t]*proc[ \t]*(" cur)))
        (throw 'done 0))
      ;; a comment before a declaration goes with it, at the margin
      (when (string-match-p "^[ \t]*(\\*" cur)
        (let ((l n) (last (line-number-at-pos (point-max))))
          (while (and (< l last) (not (string-match-p "\\*)" (raz--line l))))
            (setq l (1+ l)))
          (setq l (1+ l))
          (while (and (<= l last) (string-match-p "\\`[ \t]*\\'" (raz--line l)))
            (setq l (1+ l)))
          (when (and (<= l last) (string-match-p raz--decl (raz--line l)))
            (throw 'done 0))))
      (when (string-match-p "^[ \t]*\\(?:end\\|until\\)\\_>" cur)
        (throw 'done (or (raz--opener n) 0)))
      (when (= prev 0) (throw 'done 0))
      (when (string-match-p "^[ \t]*\\(?:\\(?:else\\|elsif\\)\\_>\\||\\)" cur)
        (throw 'done (or (raz--opener n) (raz--indent-of prev))))
      (when (or (raz--continues prev) (string-match-p raz--leading cur))
        (throw 'done nil))
      (when (string= (raz--code prev) "")
        (throw 'done (raz--indent-of (raz--comment-start prev))))
      (let* ((start (raz--start prev))
             (ind (raz--indent-of start))
             (code (mapconcat #'raz--code (number-sequence start prev) " ")))
        (cond
         ((or (string-match-p "\\`\\(?:const\\|type\\|var\\)\\'" code)
              (and (string-match-p "\\`else\\_>" code) (>= (raz--opens code) 0))
              (string-match-p "\\`|.*:\\'" code)
              (string-match-p "\\`elsif\\_>.*\\_<then\\'" code))
          (+ ind raz-indent-offset))
         ((or (string-match-p "\\`|" code) (string-match-p "\\_<match\\_>.*\\_<of\\'" code))
          ind)
         ((> (raz--opens code) 0) (+ ind raz-indent-offset))
         (t ind))))))

(defun raz-indent-line ()
  "Indent the current line as raz's blocks say."
  (interactive)
  (let ((col (save-excursion (raz-calculate-indent)))
        (offset (- (current-column) (current-indentation))))
    (when col
      (indent-line-to col)
      (when (> offset 0) (move-to-column (+ col offset))))))

;;;###autoload
(define-derived-mode raz-mode prog-mode "raz"
  "Major mode for editing raz."
  :syntax-table raz-mode-syntax-table
  (setq-local font-lock-defaults '(raz-font-lock-keywords nil nil))
  (setq-local syntax-propertize-function raz--syntax-propertize)
  (setq-local comment-start "(* ")
  (setq-local comment-end " *)")
  (setq-local comment-start-skip "(\\*+[ \t]*")
  (setq-local indent-tabs-mode nil)
  (setq-local indent-line-function #'raz-indent-line))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.raz\\'" . raz-mode))

(provide 'raz-mode)

;;; raz-mode.el ends here
