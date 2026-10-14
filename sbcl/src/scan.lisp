;;;; scan.lisp -- the scanner: a file's bytes into a vector of tokens.
;;;;
;;;; Report, section 2. The whole file is checked to be UTF-8 first, then
;;;; cut into tokens, each with its line and column (counted in
;;;; characters), which the parser reads by index. Reading the whole file
;;;; at once lets the parser go back, as it does to read a generic
;;;; module's type arguments where the instance is made (section 3).
;;;;
;;;; A code procedure's body (section 8) isn't raz: after the word `code`
;;;; the scanner takes each instruction, up to its `;`, as raw text, until
;;;; an instruction that starts with `end`.

(in-package :raz)

;;; Errors. Every error the compiler finds is a RAZ-ERROR, whose text
;;; already says where it is; the driver prints it and stops (appendix A
;;; lets an implementation report as few errors as one).

(define-condition raz-error (error)
  ((text :initarg :text :reader raz-error-text))
  (:report (lambda (c s) (write-string (raz-error-text c) s))))

(defvar *file* "?" "The name of the file being read, for messages.")

(defun fail-at (line col fmt &rest args)
  (error 'raz-error
         :text (format nil "~a:~d:~d: ~?" *file* line col fmt args)))

;;; Tokens. KIND is :ident, :int, :real, :char, :string, :code, :blank,
;;; :eof, or a keyword naming a reserved word or an operator, such as
;;; :begin or :|:=|. VAL is an identifier's text, a number's value, a
;;; string's bytes, or a code body's instructions.

(defstruct (tok (:constructor make-tok (kind val line col)))
  kind val line col)

(defparameter *reserved*
  '("and" "begin" "break" "by" "code" "const" "defer" "div" "do" "else"
    "elsif" "end" "extern" "for" "forward" "if" "import" "in" "link"
    "match" "mod" "module" "not" "of" "or" "packed" "proc" "record"
    "repeat" "return" "set" "shl" "shr" "then" "to" "try" "type" "until"
    "var" "variant" "VOLATILE" "while" "xor"))

;;; Operators, longest first, so that `:=` is found before `:`.
(defparameter *operators*
  '("..." ".." ":=" "<=" ">=" "+" "-" "*" "/" "&" "|" "~" "=" "#" "<" ">"
    ":" ";" "," "." "(" ")" "[" "]" "{" "}" "^"))

(defun keyword-of (text) (intern text :keyword))

;;; UTF-8. Section 2: no malformed or overlong sequence, no surrogate,
;;; nothing past 10FFFFH, and no NUL byte anywhere.

(defun check-utf8 (bytes)
  (let ((i 0) (n (length bytes)) (line 1))
    (flet ((bad () (fail-at line 1 "the file isn't valid UTF-8")))
      (loop while (< i n) do
        (let* ((b (aref bytes i))
               (len (cond ((< b #x80) 1) ((< b #xC2) 0) ((< b #xE0) 2)
                          ((< b #xF0) 3) ((< b #xF5) 4) (t 0))))
          (when (= b 0) (fail-at line 1 "the file has a NUL byte"))
          (when (= b 10) (incf line))
          (when (or (= len 0) (> (+ i len) n)) (bad))
          (let ((cp (if (= len 1) b (logand b (ash #x7F (- len))))))
            (loop for k from 1 below len
                  for c = (aref bytes (+ i k))
                  do (unless (= (logand c #xC0) #x80) (bad))
                     (setf cp (logior (ash cp 6) (logand c #x3F))))
            ;; the least code point each length may hold, against overlong forms
            (when (or (< cp (aref #(0 0 #x80 #x800 #x10000) len))
                      (<= #xD800 cp #xDFFF) (> cp #x10FFFF))
              (bad)))
          (incf i len))))))

(defun utf8-encode (cp)
  "The UTF-8 bytes of code point CP, as a list."
  (cond ((< cp #x80) (list cp))
        ((< cp #x800) (list (logior #xC0 (ash cp -6)) (logior #x80 (logand cp #x3F))))
        ((< cp #x10000) (list (logior #xE0 (ash cp -12))
                              (logior #x80 (logand (ash cp -6) #x3F))
                              (logior #x80 (logand cp #x3F))))
        (t (list (logior #xF0 (ash cp -18))
                 (logior #x80 (logand (ash cp -12) #x3F))
                 (logior #x80 (logand (ash cp -6) #x3F))
                 (logior #x80 (logand cp #x3F))))))

;;; The scanner proper. It walks the bytes with POS, keeping LINE and the
;;; column COL of the byte at POS, in characters.

(defun scan (bytes)
  "The tokens of BYTES, a file's contents, ending in an :eof token."
  (check-utf8 bytes)
  (let ((pos 0) (line 1) (col 1) (toks '()) (n (length bytes)))
    (labels ((peek (&optional (k 0))
               (if (< (+ pos k) n) (aref bytes (+ pos k)) 0))
             (next ()
               (let ((b (aref bytes pos)))
                 (incf pos)
                 (cond ((= b 10) (incf line) (setf col 1))
                       ;; a continuation byte doesn't start a character
                       ((/= (logand b #xC0) #x80) (incf col)))
                 b))
             (err (fmt &rest args) (apply #'fail-at line col fmt args))
             (letter-p (b) (or (<= 65 b 90) (<= 97 b 122) (= b 95)))
             (digit-p (b) (<= 48 b 57))
             (hex-p (b) (or (digit-p b) (<= 65 b 70)))
             (any-hex-p (b) (or (hex-p b) (<= 97 b 102)))
             (hex-value (b) (digit-char-p (code-char b) 16))
             (skip-space-and-comments ()
               (loop
                 (cond ((member (peek) '(32 9 10 13)) (next))
                       ((and (= (peek) 40) (= (peek 1) 42)) (comment))
                       (t (return)))))
             (comment ()
               ;; comments nest: `(*` opens one more, `*)` closes one
               (let ((l line) (c col) (depth 0))
                 (loop
                   (cond ((>= pos n) (fail-at l c "the comment never ends"))
                         ((and (= (peek) 40) (= (peek 1) 42)) (next) (next) (incf depth))
                         ((and (= (peek) 42) (= (peek 1) 41)) (next) (next)
                          (when (= (decf depth) 0) (return)))
                         (t (next))))))
             (add (kind val l c) (push (make-tok kind val l c) toks))
             (word (l c)
               (let ((start pos))
                 (loop while (or (letter-p (peek)) (digit-p (peek))) do (next))
                 (let ((text (map 'string #'code-char (subseq bytes start pos))))
                   (when (> (length text) 63)
                     (fail-at l c "the name ~a... is longer than 63 characters" (subseq text 0 20)))
                   (cond ((string= text "_") (add :blank nil l c))
                         ((member text *reserved* :test #'string=)
                          (add (keyword-of (string-upcase text)) nil l c)
                          (when (string= text "code") (code-body)))
                         (t (add :ident text l c))))))
             (number (l c)
               ;; digits and capitals A-F; then H for hexadecimal, or a
               ;; point and a digit for a real
               (let ((start pos))
                 (loop while (hex-p (peek)) do (next))
                 (let ((text (map 'string #'code-char (subseq bytes start pos))))
                   (cond ((= (peek) 72) ; H
                          (next)
                          (let ((v (parse-integer text :radix 16)))
                            (when (>= v (expt 2 64))
                              (fail-at l c "the number ~aH is above the largest U64" text))
                            (add :int v l c)))
                         ((find-if (lambda (ch) (char<= #\A ch #\F)) text)
                          (fail-at l c "a hexadecimal number ends in H: ~a" text))
                         ((and (= (peek) 46) (digit-p (peek 1)))
                          (real-number text l c))
                         ((or (letter-p (peek)))
                          (err "a number is followed by a letter"))
                         (t (let ((v (parse-integer text)))
                              (when (>= v (expt 2 63))
                                (fail-at l c "the number ~a is above the largest I64" text))
                              (add :int v l c)))))))
             (real-number (whole l c)
               ;; the value as an exact fraction, rounded once to an F64
               (next)                   ; the point
               (let ((start pos) (exp 0))
                 (loop while (digit-p (peek)) do (next))
                 (let* ((frac (map 'string #'code-char (subseq bytes start pos)))
                        (mant (parse-integer (concatenate 'string whole frac))))
                   (when (= (peek) 69)  ; E
                     (next)
                     (let ((sign 1) (s pos))
                       (cond ((= (peek) 43) (next)) ((= (peek) 45) (next) (setf sign -1)))
                       (setf s pos)
                       (unless (digit-p (peek)) (err "an exponent needs digits"))
                       (loop while (digit-p (peek)) do (next))
                       (setf exp (* sign (parse-integer (map 'string #'code-char (subseq bytes s pos)))))))
                   (when (or (letter-p (peek)) (digit-p (peek)))
                     (err "a real is followed by ~a" (code-char (peek))))
                   ;; an exponent too far out either way needn't be computed
                   (let ((value (cond ((= mant 0) 0d0)
                                      ((> (+ exp (length whole)) 400) nil)
                                      ((< (+ exp (length whole)) -400) 0d0)
                                      (t (let ((r (* mant (expt 10 (- exp (length frac))))))
                                           (if (> r most-positive-double-float)
                                               nil
                                               (coerce r 'double-float)))))))
                     (unless value (fail-at l c "the real is above the largest F64"))
                     (add :real value l c)))))
             (escape (in-string)
               ;; after a backslash: the code point, or (:byte b) for \xHH
               (let ((b (if (< pos n) (next) 0)))
                 (case (code-char b)
                   (#\n 10) (#\t 9) (#\r 13) (#\0 0) (#\\ 92) (#\' 39) (#\" 34)
                   (#\x (unless in-string (err "\\x is for strings only"))
                    (unless (and (any-hex-p (peek)) (any-hex-p (peek 1)))
                      (err "\\x takes two hexadecimal digits"))
                    (list :byte (+ (* 16 (hex-value (next))) (hex-value (next)))))
                   (#\u (unless (= (next) 123) (err "\\u is followed by {"))
                    (let ((v 0) (k 0))
                      (loop while (any-hex-p (peek))
                            do (setf v (+ (* v 16) (hex-value (next)))) (incf k)
                               (when (> v #x10FFFF) (err "\\u{...} is above 10FFFFH")))
                      (unless (and (> k 0) (= (peek) 125)) (err "\\u{...} wants hexadecimal digits and }"))
                      (next)
                      (when (<= #xD800 v #xDFFF) (err "\\u{...} is a surrogate"))
                      v))
                   (t (err "unknown escape \\~a" (code-char b))))))
             (char-code-at ()
               ;; the code point of the UTF-8 character at pos
               (let* ((b (next)) (len (cond ((< b #x80) 1) ((< b #xE0) 2) ((< b #xF0) 3) (t 4)))
                      (cp (if (= len 1) b (logand b (ash #x7F (- len))))))
                 (loop repeat (1- len) do (setf cp (logior (ash cp 6) (logand (next) #x3F))))
                 cp))
             (char-literal (l c)
               (next)
               (when (member (peek) '(39 10 0)) (fail-at l c "a character literal holds one character"))
               (let ((v (if (= (peek) 92) (progn (next) (escape nil)) (char-code-at))))
                 (unless (= (peek) 39) (fail-at l c "the character literal isn't closed"))
                 (next)
                 (add :char v l c)))
             (string-literal (l c)
               (next)
               (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
                 (loop
                   (let ((b (peek)))
                     (cond ((or (>= pos n) (= b 10)) (fail-at l c "the string isn't closed on its line"))
                           ((= b 34) (next) (return))
                           ((= b 92) (next)
                            (let ((e (escape t)))
                              (if (consp e)
                                  (vector-push-extend (second e) out)
                                  (dolist (x (utf8-encode e)) (vector-push-extend x out)))))
                           (t (vector-push-extend (next) out)))))
                 (add :string (coerce out '(simple-array (unsigned-byte 8) (*))) l c)))
             (code-body ()
               ;; raw instructions up to the one that starts with `end`
               (let ((instrs '()))
                 (loop
                   ;; only spaces: `(*` here is Lisp's multiplication
                   (loop while (member (peek) '(32 9 10 13)) do (next))
                   (when (>= pos n) (err "the code procedure never ends"))
                   (let ((l line) (c col) (start pos) (depth 0) (in-str nil))
                     (loop while (< pos n)
                           do (let ((b (peek)))
                                (cond (in-str (when (= b 92) (next)) (when (= b 34) (setf in-str nil)))
                                      ((= b 34) (setf in-str t))
                                      ((= b 40) (incf depth))
                                      ((= b 41) (decf depth))
                                      ((and (= b 59) (= depth 0)) (return)))
                                (next)))
                     (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return)
                                              (sb-ext:octets-to-string (subseq bytes start pos) :external-format :utf-8))))
                       (when (and (>= (length text) 3) (string= "end" text :end2 3)
                                  (or (= (length text) 3) (not (alphanumericp (char text 3)))))
                         ;; give back the `end` for the parser
                         (setf pos start line l col c)
                         (return))
                       (push (list text l c) instrs)
                       (when (< pos n) (next)))))
                 (add :code (nreverse instrs) line col)))
             (operator (l c)
               (dolist (op *operators* (err "unknown character ~a" (code-char (peek))))
                 (when (loop for k below (length op)
                             always (= (peek k) (char-code (char op k))))
                   (loop repeat (length op) do (next))
                   (return (add (keyword-of op) nil l c))))))
      (loop
        (skip-space-and-comments)
        (when (>= pos n) (return))
        (let ((b (peek)) (l line) (c col))
          (cond ((letter-p b) (word l c))
                ((digit-p b) (number l c))
                ((= b 39) (char-literal l c))
                ((= b 34) (string-literal l c))
                ((>= b 128) (err "a character outside ASCII, outside a string or a comment"))
                (t (operator l c)))))
      (add :eof nil line col)
      (coerce (nreverse toks) 'vector))))

(defun read-bytes (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))
