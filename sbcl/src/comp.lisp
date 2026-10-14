;;;; comp.lisp -- what the parts of the compiler share: modules, the
;;;; names they declare, the items an expression compiles to, procedures'
;;;; frames, the data block and reading tokens.
;;;;
;;;; The compiler reads each module once, from front to back, checking it
;;;; and turning it into Lisp as it goes, as Wirth's compilers do: an
;;;; expression becomes an ITEM, which says what it is (a constant, a
;;;; variable, a value, a procedure...) and holds the Lisp form that
;;;; computes it. Each procedure becomes a DEFUN, kept in *FORMS*; the
;;;; driver compiles them all with SBCL and saves the result as the
;;;; executable.

(in-package :raz)

;;; Modules.
;;;
;;; A generic module (section 3) is read only up to its parameters when
;;; it is imported; each distinct list of arguments then makes an
;;; INSTANCE, a module of its own, compiled from the same tokens with the
;;; parameters standing for the arguments.

(defstruct module
  name                  ; as written, "Out"
  file toks             ; its file and tokens
  (exports (make-hash-table :test 'equal))  ; name -> obj, the exported names
  scope                 ; its scope, for its own code
  imports               ; IMPORTs, in order, which decide the order of bodies
  generic               ; for a generic module: its parameters, (names . proc-params)
  (instances '())       ; for a generic module: (args . module) for each instance
  args                  ; for an instance: its arguments
  lisp-name             ; the prefix of its procedures' Lisp names, "Out" or "List(2)"
  check-off             ; it says `check off;`
  static                ; it says `link static;`
  uses-c                ; it has an extern or links a library
  links                 ; the libraries it links
  body                  ; the Lisp symbol of its body's function, if it has a body
  (state :new))         ; :compiling while its declarations are read, then :done

;;; An import: ALIAS is the name the importer uses; TARGET the module,
;;; or the generic module; ARGS the position of its arguments' tokens,
;;; read when the instance is made; INSTANCE then the instance.
(defstruct import alias target args instance tok)

;;; A declared name. KIND is :const :type :var :proc :module :builtin or
;;; :case. For a :var, WHERE says where it lives:
;;;   (:global address)   a module variable, in the data block
;;;   (:local offset)     a procedure's, in its frame
;;;   (:var-param offset) a var parameter: its frame holds the address
;;;   (:at form)          a match arm's name: FORM is the address
;;;   (:extern name)      a C variable
;;; For a :const, VAL is its value (for an array or record constant, its
;;; address in the data block). For a :proc, SYM is its Lisp function,
;;; SIG its signature, and EXTERN, CODE and FORWARD say what kind it is.

(defstruct obj
  name kind type val where exported module
  sym sig extern code forward defined (handle nil) tok import)

;;; The state of the compilation. Each is rebound while a module is read,
;;; since an instance of a generic module may be read in the middle of
;;; another module's procedure.

(defvar *module* nil "The module being read.")
(defvar *scope* nil "The innermost scope.")
(defvar *toks* #() "The tokens of the module being read.")
(defvar *pos* 0 "The index of the next token.")
(defvar *proc* nil "The PROC being compiled, or nil outside procedures.")
(defvar *forms* '() "The program's top-level Lisp forms, the last first.")
(defvar *modules* (make-hash-table :test 'equal) "Every module read, by name.")

;;; Scopes: a table of names and the scope around it.

(defstruct scope (table (make-hash-table :test 'equal)) parent)

(defvar *universe* nil "The scope around every module: the predeclared names.")

(defun lookup (name &optional (scope *scope*))
  (loop for s = scope then (scope-parent s) while s
        do (let ((o (gethash name (scope-table s)))) (when o (return o)))))

(defun declare-name (obj &optional (scope *scope*))
  (when (gethash (obj-name obj) (scope-table scope))
    (fail-tok (obj-tok obj) "~a is declared twice" (obj-name obj)))
  (setf (gethash (obj-name obj) (scope-table scope)) obj)
  obj)

;;; A procedure (or a module body) being compiled. Its frame grows by
;;; ALLOC as variables and temporaries are given places in it. DEFERS
;;; holds, for each statement list it is in, the innermost first, the
;;; forms of the statements deferred there, the last first (section 7.7).
;;; LOOPS holds, for each loop it is in, its block name and the DEFERS
;;; outside it.

(defstruct proc
  obj sig (size 0) block (defers '()) (loops '()) dests in-defer results)

(defun alloc (size align)
  "A place of SIZE bytes in the current frame: the form of its address."
  (let ((off (round-up (proc-size *proc*) (max align 1))))
    (setf (proc-size *proc*) (+ off size))
    `(+ fp ,off)))

(defun temp (ty) (alloc (ty-size ty) (ty-align ty)))

;;; Items. MODE is
;;;   :const    a constant; VAL is its value
;;;   :var      a variable; FORM is its address
;;;   :val      a value; FORM computes it (the address of a copy, for an aggregate)
;;;   :literal  an array, record or set literal, waiting for the type it
;;;             must have (6.5): VAL is (kind elements)
;;;   :proc     a procedure, OBJ; :builtin, VAL its name; :type, TYPE;
;;;   :case     a variant's case, VAL; :module, OBJ the import
;;;   :multi    a call with several results, TYPE their list
;;;   :none     a call with no result
;;; RO says why a variable can't be changed: :export (another module's,
;;; section 3), :const (a constant's part or a string's byte) or :value
;;; (a part of a value). VOL marks a volatile variable (7.6); NOADDR a
;;; field of a packed record that has no address (5.5).

(defstruct item mode type form val ro vol noaddr obj tok)

;;; Reading tokens.

(defun tok (&optional (k 0)) (aref *toks* (min (+ *pos* k) (1- (length *toks*)))))
(defun kind (&optional (k 0)) (tok-kind (tok k)))
(defun next-tok () (prog1 (tok) (incf *pos*)))

(defun fail-tok (tok fmt &rest args)
  (apply #'fail-at (tok-line tok) (tok-col tok) fmt args))

(defun fail-here (fmt &rest args) (apply #'fail-tok (tok) fmt args))

(defun accept (kind) (when (eq (kind) kind) (next-tok)))

(defun describe-tok (tok)
  (case (tok-kind tok)
    (:ident (format nil "~a" (tok-val tok)))
    (:eof "the end of the file")
    ((:int :real :char) "a number")
    (:string "a string")
    (:blank "_")
    (t (format nil "~(~a~)" (tok-kind tok)))))

(defun expect (kind &optional what)
  (or (accept kind)
      (fail-here "~a expected, not ~a" (or what (format nil "~(~a~)" kind)) (describe-tok (tok)))))

(defun ident ()
  (let ((tk (tok)))
    (unless (eq (tok-kind tk) :ident)
      (fail-here "a name expected, not ~a" (describe-tok tk)))
    (next-tok)
    (tok-val tk)))

(defun where (tok)
  "TOK's place, as a stopping program says it."
  (format nil "~a:~d:~d" *file* (tok-line tok) (tok-col tok)))

;;; The data block (rt.lisp): the module variables, strings, constants
;;; and errors' messages, each at an address the compiler gives.

(defvar *data* (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
(defvar *strings* (make-hash-table :test 'equalp) "Bytes -> the address of a copy, with a 0 after it.")
(defvar *string-slices* (make-hash-table :test 'equalp) "Bytes -> the address of a slice of them.")

(defun data-alloc (size align)
  (loop until (zerop (mod (fill-pointer *data*) (max align 1))) do (vector-push-extend 0 *data*))
  (prog1 (+ +data-base+ (fill-pointer *data*))
    (loop repeat size do (vector-push-extend 0 *data*))))

(defun data-put (addr bytes)
  (loop for b across bytes for i from (- addr +data-base+) do (setf (aref *data* i) b)))

(defun data-put-int (addr value size)
  (loop for i below size do (setf (aref *data* (+ (- addr +data-base+) i)) (ldb (byte 8 (* 8 i)) value))))

(defun string-address (bytes)
  "The address of BYTES in the data block, followed by a zero byte, as C wants."
  (or (gethash bytes *strings*)
      (let ((a (data-alloc (1+ (length bytes)) 1)))
        (data-put a bytes)
        (setf (gethash bytes *strings*) a))))

(defun string-slice (bytes)
  "The address of a slice of BYTES."
  (or (gethash bytes *string-slices*)
      (let ((s (data-alloc 16 8)))
        (data-put-int s (string-address bytes) 8)
        (data-put-int (+ s 8) (length bytes) 8)
        (setf (gethash bytes *string-slices*) s))))

(defun error-value (message)
  "A new ERROR (5.8): the address of a slice of its message, unique to
the declaration that makes it, so that MSG reads it there."
  (let ((s (data-alloc 16 8)))
    (data-put-int s (string-address message) 8)
    (data-put-int (+ s 8) (length message) 8)
    s))

;;; Procedure values: each procedure used as a value gets its index in
;;; the run time's *PROCS*.

(defvar *proc-values* '() "(index . symbol) for each procedure value, the last first.")

(defun proc-handle (obj)
  (or (obj-handle obj)
      (setf (obj-handle obj)
            (let ((h (1+ (length *proc-values*))))
              (push (cons h (obj-sym obj)) *proc-values*)
              h))))

;;; Emitting.

(defun emit (form) (push form *forms*))

(defun lisp-name (name)
  "The Lisp symbol of the current module's NAME."
  (intern (format nil "~a.~a" (module-lisp-name *module*) name) :razp))

(defvar *gensym-count* 0)
(defun var-sym (prefix) (make-symbol (format nil "~a~d" prefix (incf *gensym-count*))))
