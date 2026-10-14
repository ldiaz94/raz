;;;; decl.lisp -- modules, imports, generic instances, declarations,
;;;; types and procedures (report, sections 3, 4, 5, 8 and 9).

(in-package :raz)

;;; The scope around every module (section 2).

(defparameter *builtins*
  '("SIZE" "ADR" "LEN" "NEW" "MSG" "COPY" "SYSCALL" "INC" "DEC" "FENCE"
    "CAS" "XCHG" "XADD" "ARGC" "ARGV"))

(defun make-universe ()
  (let ((*scope* (make-scope)))
    (dolist (ty *basic-types*)
      (declare-name (make-obj :name (ty-name ty) :kind :type :type ty)))
    (declare-name (make-obj :name "true" :kind :const :type (basic "BOOL") :val t))
    (declare-name (make-obj :name "false" :kind :const :type (basic "BOOL") :val nil))
    (declare-name (make-obj :name "nil" :kind :const :type *nil-type* :val 0))
    (dolist (b *builtins*) (declare-name (make-obj :name b :kind :builtin)))
    *scope*))

;;; Names declared at the top of a module may be exported.

(defun ident-def (top)
  "An IdentDef: the name, and whether it is exported (only at the top)."
  (let ((tk (tok)) (name (ident)))
    (values name (when (accept :*)
                   (unless top (fail-tok tk "only a module's own names are exported"))
                   t)
            tk)))

(defun declare-top (obj)
  "Declares OBJ in the current scope, and among the module's exports if
it is exported."
  (declare-name obj)
  (when (obj-exported obj)
    (setf (gethash (obj-name obj) (module-exports *module*)) obj))
  obj)

;;; Types (section 5).

(defvar *forward-types* nil
  "In a `type` section, the pointers whose base is declared later in it,
(type name tok) for each; elsewhere :none.")
(defvar *type-exported* nil "Whether the type being declared is exported: its case and enumeration names are too.")
(defvar *top* nil "Whether the declarations being read are a module's own.")

(defun parse-type ()
  (let ((tk (tok)))
    (case (kind)
      (:ident (named-type))
      (:|[| (next-tok)
       (if (accept :|]|)
           (make-slice-type (parse-type))
           (let ((n (constant-int "an array's length")))
             (unless (> n 0) (fail-tok tk "an array's length is greater than 0"))
             (expect :|]|)
             (check-size (make-array-type n (parse-type)) tk))))
      (:^ (next-tok) (pointer-type-rest))
      (:packed (next-tok) (expect :record) (record-type t tk))
      (:record (next-tok) (record-type nil tk))
      (:variant (next-tok) (variant-type))
      (:|(| (next-tok) (enum-type))
      (:set (next-tok) (expect :of)
       (let ((e (named-type)))
         (unless (is e :enum) (fail-tok tk "a set is of an enumeration"))
         (when (> (length (ty-names e)) 64) (fail-tok tk "a set's enumeration has at most 64 names"))
         (make-set-type e)))
      (:proc (next-tok) (make-proc-type (signature nil)))
      (t (fail-here "a type expected, not ~a" (describe-tok tk))))))

(defun check-size (ty tk)
  (when (> (ty-size ty) (int-max (basic "INT"))) (fail-tok tk "the type is too big"))
  ty)

(defun named-type ()
  (multiple-value-bind (obj tk) (qualified-obj)
    (unless (eq (obj-kind obj) :type) (fail-tok tk "~a isn't a type" (obj-name obj)))
    (obj-type obj)))

(defun pointer-type-rest ()
  "A pointer type, after its ^."
  (let ((vol (and (accept :volatile) t)))
    (if (and (listp *forward-types*) (eq (kind) :ident) (not (eq (kind 1) :|.|))
             (not (lookup (tok-val (tok)))))
        ;; a type declared later in this section (section 4)
        (let* ((tk (next-tok)) (ty (make-ptr-type (list :forward (tok-val tk)) vol)))
          (push (list ty (tok-val tk) tk) *forward-types*)
          ty)
        (make-ptr-type (parse-type) vol))))

(defun resolve-forward-types ()
  (dolist (f *forward-types*)
    (destructuring-bind (ty name tk) f
      (let ((obj (lookup name)))
        (unless (and obj (eq (obj-kind obj) :type))
          (fail-tok tk "~a isn't declared as a type" name))
        (setf (ty-base ty) (obj-type obj))))))

(defun field-list (fields &key exports)
  "IdentList : Type, the names added to FIELDS (each name new)."
  (let ((names (loop collect (multiple-value-list (if exports (ident-def *top*) (values (ident) nil (tok 0))))
                     while (accept :|,|))))
    (expect :|:|)
    (let ((ty (parse-type)))
      (dolist (n names fields)
        (destructuring-bind (name exported tk) n
          (when (find name fields :key #'field-name :test #'string=)
            (fail-tok tk "the field ~a is declared twice" name))
          (setf fields (append fields (list (make-field :name name :type ty :exported exported)))))))))

(defun record-type (packed tk)
  (let ((fields '()))
    (loop until (accept :end)
          do (setf fields (field-list fields :exports t)) (expect :|;|))
    (check-size (make-record-type fields packed *module*) tk)))

(defun declare-member (name kind type val tk)
  "A name a type declares in the scope around it: a case or an enumeration's name."
  (declare-top (make-obj :name name :kind kind :type type :val val :tok tk
                         :exported *type-exported* :module *module*)))

(defun variant-type ()
  (let ((cases '()) (toks '()))
    (loop until (accept :end)
          do (let* ((tk (tok)) (name (ident)) (fields '()))
               (when (accept :|(|)
                 (loop (setf fields (field-list fields)) (unless (accept :|;|) (return)))
                 (expect :|)|))
               (when (find name cases :key #'vcase-name :test #'string=)
                 (fail-tok tk "the case ~a is declared twice" name))
               (setf cases (append cases (list (make-vcase :name name :index (length cases) :fields fields))))
               (push tk toks))
             (expect :|;|))
    ;; the cases are named in the scope around the type (5.6)
    (let ((v (make-variant-type cases *module*)))
      (loop for c in cases for tk in (reverse toks)
            do (declare-member (vcase-name c) :case v c tk))
      v)))

(defun enum-type ()
  (let ((names (loop collect (cons (tok) (ident)) while (accept :|,|))))
    (expect :|)|)
    (when (> (length names) 256) (fail-tok (car (first names)) "an enumeration has at most 256 names"))
    (let ((ty (make-enum-type (mapcar #'cdr names) *module*)))
      (loop for (tk . name) in names for i from 0
            do (declare-member name :const ty i tk))
      ty)))

(defun signature (extern)
  "A Signature: its parameters, `...` for an EXTERN, and its results."
  (let ((params '()) (varargs nil))
    (when (accept :|(|)
      (unless (eq (kind) :|)|)
        (loop
          (when (eq (kind) :...)
            (unless (and extern params) (fail-here "... is for an extern, after its parameters"))
            (next-tok) (setf varargs t) (return))
          (let* ((var (accept :var))
                 (names (loop collect (cons (tok) (ident)) while (accept :|,|))))
            (expect :|:|)
            (let ((ty (parse-type)))
              (dolist (n names)
                (when (find (cdr n) params :key #'first :test #'string=)
                  (fail-tok (car n) "the parameter ~a is declared twice" (cdr n)))
                (setf params (append params (list (list (cdr n) ty (and var t))))))))
          (unless (accept :|;|) (return))))
      (expect :|)|))
    (make-sig :params params :varargs varargs
              :results (when (accept :|:|)
                         (if (accept :|(|)
                             (prog1 (loop collect (parse-type) while (accept :|,|)) (expect :|)|))
                             (list (parse-type)))))))

;;; Constants (section 4).

(defun constant-int (what)
  (let* ((tk (tok)) (x (need-value (expression))))
    (unless (and (const-p x) (member (ty-kind (item-type x)) '(:int :untyped-int)))
      (fail-tok tk "~a is an integer constant" what))
    (item-val x)))

(defun write-const (addr ty item tk)
  "Writes the constant ITEM, as a TY, at ADDR in the data block."
  (let ((why (assign-error item ty)))
    (when why (fail-tok tk "~a" why)))
  (case (item-mode item)
    (:literal
     (destructuring-bind (kind elems) (item-val item)
       (ecase kind
         (:empty)
         (:array (if (is ty :slice)
                     (let ((arr (data-alloc (* (length elems) (ty-size (ty-elem ty))) (ty-align (ty-elem ty)))))
                       (loop for e in elems for i from 0
                             do (write-const (+ arr (* i (ty-size (ty-elem ty)))) (ty-elem ty) e tk))
                       (data-put-int addr arr 8) (data-put-int (+ addr 8) (length elems) 8))
                     (loop for e in elems for i from 0
                           do (write-const (+ addr (* i (ty-size (ty-elem ty)))) (ty-elem ty) e tk))))
         (:record (loop for (name . e) in elems
                        for f = (find-field ty name tk)
                        do (write-const (+ addr (field-offset f)) (field-type f) e tk)))
         (:set (write-const addr ty (const-item ty (build-literal item ty)) tk)))))
    (:proc (data-put-int addr (proc-handle (item-obj item)) 8))
    (:const
     (let ((v (item-val item)) (from (item-type item)))
       (case (ty-kind ty)
         ((:int :enum :set :error :ptr :proc) (data-put-int addr v (ty-size ty)))
         (:bool (data-put-int addr (if v 1 0) 1))
         (:real (if (= (ty-bits ty) 32)
                    (data-put-int addr (sb-kernel:single-float-bits (coerce v 'single-float)) 4)
                    (data-put-int addr (sb-kernel:double-float-bits (coerce v 'double-float)) 8)))
         (:slice (data-put-int addr (string-address v) 8) (data-put-int (+ addr 8) (length v) 8))
         (:array (data-put addr v))
         (t (fail-tok tk "~a isn't a constant of ~a" (type-name from) (type-name ty))))))
    (:var
     (unless (eq (item-ro item) :const) (fail-tok tk "this isn't a constant"))
     (let ((src (item-form item)) (from (item-type item)))
       (if (is ty :slice)
           (progn (data-put-int addr src 8) (data-put-int (+ addr 8) (ty-len from) 8))
           (let ((off (- src +data-base+)))
             (data-put addr (subseq *data* off (+ off (ty-size ty))))))))
    (t (fail-tok tk "this isn't a constant"))))

(defun const-section ()
  (loop while (eq (kind) :ident)
        do (multiple-value-bind (name exported tk) (ident-def *top*)
             (let ((ty (when (accept :|:|) (parse-type))))
               (expect :=)
               (let* ((etk (tok)) (x (expression)))
                 (declare-top
                  (cond
                    ((null ty)
                     (unless (or (const-p x) (and (eq (item-mode x) :var) (eq (item-ro x) :const)))
                       (fail-tok etk "a constant's value is a constant"))
                     (make-obj :name name :kind :const :type (item-type x) :tok tk :exported exported
                               :val (if (const-p x) (item-val x) (item-form x))))
                    ((is ty :error)
                     (unless (and (const-p x) (is (item-type x) :string))
                       (fail-tok etk "an ERROR is made by a string"))
                     (make-obj :name name :kind :const :type ty :tok tk :exported exported
                               :val (error-value (item-val x))))
                    ((member (ty-kind ty) '(:array :record))
                     (let ((addr (data-alloc (ty-size ty) (ty-align ty))))
                       (write-const addr ty x etk)
                       (make-obj :name name :kind :const :type ty :tok tk :exported exported :val addr)))
                    (t (fail-tok tk "a constant with a type is an ERROR, an array or a record")))))))
           (expect :|;|)))

(defun type-section ()
  (let ((*forward-types* '()))
    (loop while (eq (kind) :ident)
          do (multiple-value-bind (name exported tk) (ident-def *top*)
               (expect :=)
               (let* ((alias (and (eq (kind) :ident) (member (kind (if (eq (kind 1) :|.|) 3 1)) '(:|;|))))
                      (ty (let ((*type-exported* exported)) (parse-type))))
                 ;; `type A = B` names B's type; anything else makes a new one
                 (unless (or alias (ty-name ty)) (setf (ty-name ty) name))
                 (declare-top (make-obj :name name :kind :type :type ty :tok tk :exported exported))))
             (expect :|;|))
    (resolve-forward-types)))

(defun var-section ()
  (loop while (eq (kind) :ident)
        do (let ((names (loop collect (multiple-value-list (ident-def *top*)) while (accept :|,|))))
             (expect :|:|)
             (let ((ty (parse-type)))
               (dolist (n names)
                 (destructuring-bind (name exported tk) n
                   (declare-top
                    (make-obj :name name :kind :var :type ty :tok tk :exported exported
                              :module (when *top* *module*)
                              :where (if *top*
                                         (list :global (data-alloc (ty-size ty) (ty-align ty)))
                                         (list :local (alloc-offset (ty-size ty) (ty-align ty)))))))))
             (expect :|;|))))

(defun alloc-offset (size align)
  (third (alloc size align)))

(defun declarations ()
  "Const, type and var sections, and at a module's top procedures and externs."
  (loop
    (case (kind)
      (:const (next-tok) (const-section))
      (:type (next-tok) (type-section))
      (:var (next-tok) (var-section))
      (:proc (if *top* (progn (next-tok) (proc-declaration)) (fail-here "procedures don't nest")))
      (:extern (if *top* (progn (next-tok) (extern-declaration)) (fail-here "an extern is a module's")))
      (t (return)))))

;;; Procedures (section 8).

(defun proc-declaration ()
  (multiple-value-bind (name exported tk) (ident-def t)
    (let* ((sig (signature nil))
           (old (gethash name (scope-table *scope*)))
           (obj (if (and old (eq (obj-kind old) :proc) (obj-forward old) (not (obj-defined old)))
                    (progn
                      (unless (sig-alike-p sig (obj-sig old))
                        (fail-tok tk "~a's signature isn't its forward declaration's" name))
                      (setf (obj-sig old) sig)
                      old)
                    (declare-top (make-obj :name name :kind :proc :sig sig :tok tk :exported exported
                                           :sym (lisp-name name))))))
      (expect :|;|)
      (cond ((accept :forward)
             (when (eq obj old) (fail-tok tk "~a is declared forward twice" name))
             (setf (obj-forward obj) t))
            (*interface-only* (skip-body) (setf (obj-defined obj) t))
            ((eq (kind) :code) (next-tok) (code-procedure obj))
            (t (procedure-body obj)
               (setf (obj-defined obj) t)))
      (when (eq (kind) :ident)
        (unless (string= (tok-val (tok)) name)
          (fail-here "the procedure ends with its own name, ~a" name))
        (next-tok))
      (expect :|;|))))

(defun skip-body ()
  "Reads past a procedure's body unchecked, for a file read only for its
interface: its local declarations and statements, or its code."
  (if (accept :code)
      (expect :end)
      (let ((depth 0))
        (loop (let ((k (kind)))
                (next-tok)
                (case k
                  ((:begin :if :while :for :match :record :variant) (incf depth))
                  (:end (when (= (decf depth) 0) (return)))
                  (:eof (fail-here "the procedure never ends"))))))))

(defun procedure-body (obj)
  "Compiles a procedure's declarations and statements into a DEFUN."
  (let* ((sig (obj-sig obj))
         (*scope* (make-scope :parent *scope*))
         (*proc* (make-proc :obj obj :sig sig :block (gensym "PROC") :results (sig-results sig)))
         (*top* nil)
         (psyms '()) (stores '()))
    (setf (proc-dests *proc*) (loop for r in (sig-results sig) collect (when (aggregate-p r) (var-sym "D"))))
    (dolist (p (sig-params sig))
      (destructuring-bind (name ty var) p
        (let ((s (var-sym "P")))
          (push s psyms)
          (if var
              (let ((off (alloc-offset 8 8)))
                (push `(st :u64 (+ fp ,off) ,s) stores)
                (declare-name (make-obj :name name :kind :var :type ty :where (list :var-param off) :tok (tok))))
              (let ((off (alloc-offset (ty-size ty) (ty-align ty))))
                (push (if (aggregate-p ty) `(move (+ fp ,off) ,s ,(ty-size ty)) `(st ,(access-kind ty) (+ fp ,off) ,s))
                      stores)
                (declare-name (make-obj :name name :kind :var :type ty :where (list :local off) :tok (tok))))))))
    (declarations)
    (expect :begin)
    (let ((body (statements :end)))
      (expect :end)
      (emit (procedure-defun (obj-sym obj) (reverse psyms) (remove nil (proc-dests *proc*))
                             (reverse stores) body (zeros-form (sig-results sig)))))))

(defun procedure-defun (sym params dests stores body end)
  ;; The frame is pushed by moving *SP*, and popped by moving it back as
  ;; the procedure returns, by RETURN-FROM or by its end. (Binding *SP*
  ;; with LET would be simpler, but each binding takes room on SBCL's
  ;; binding stack, which a deep recursion soon fills.)
  `(defun ,sym (,@params ,@dests)
     (let ((fp *sp*))
       (declare (ignorable fp))
       (enter fp ,(proc-size *proc*))
       (setf *sp* (+ fp ,(proc-size *proc*)))
       ,@stores
       (multiple-value-prog1 (block ,(proc-block *proc*) ,@body ,end)
         (setf *sp* fp)))))

(defun code-procedure (obj)
  "A code procedure (section 8). This implementation's target is SBCL's
Lisp, so its instructions are Lisp forms, one to each `;`, which see the
parameters by their names; the value of the last is the result."
  (let ((code (tok)) (sig (obj-sig obj)))
    (expect :code)
    (when (some #'aggregate-p (sig-results sig))
      (fail-tok code "a code procedure here returns no aggregate"))
    (let* ((params (mapcar (lambda (p) (intern (string-upcase (first p)) :raz)) (sig-params sig)))
           (forms (loop for (text line col) in (tok-val code)
                        collect (handler-case (let ((*package* (find-package :raz))) (read-from-string text))
                                  (error (e) (fail-at line col "the instruction isn't Lisp: ~a" e))))))
      (emit `(defun ,(obj-sym obj) ,params (declare (ignorable ,@params)) ,@forms))
      (setf (obj-defined obj) t (obj-code obj) t))
    (expect :end)))

;;; Calling C (section 9).

(defun extern-declaration ()
  (setf (module-uses-c *module*) t)
  (cond ((accept :proc)
         (multiple-value-bind (name exported tk) (ident-def t)
           (let ((sig (signature t)))
             (dolist (p (sig-params sig))
               (unless (and (not (third p)) (member (ty-kind (second p)) '(:int :bool :real :ptr :proc)))
                 (fail-tok tk "~a's parameter ~a isn't of a type C takes" name (first p))))
             (when (or (rest (sig-results sig))
                       (and (sig-results sig)
                            (not (member (ty-kind (first (sig-results sig))) '(:int :bool :real :ptr :proc)))))
               (fail-tok tk "~a's result isn't of a type C gives" name))
             (let ((obj (declare-top (make-obj :name name :kind :proc :sig sig :tok tk :exported exported
                                               :sym (lisp-name name) :extern name :defined t))))
               (unless (sig-varargs sig) (emit (extern-wrapper obj)))))))
        ((accept :var)
         (multiple-value-bind (name exported tk) (ident-def t)
           (expect :|:|)
           (declare-top (make-obj :name name :kind :var :type (parse-type) :tok tk :exported exported
                                  :module *module* :where (list :extern name)))))
        (t (fail-here "extern proc or extern var expected")))
  (expect :|;|))

;;; A Lisp function calling a C procedure, for calls and for its value.
(defun extern-wrapper (obj)
  (let* ((sig (obj-sig obj)) (result (first (sig-results sig)))
         (ps (loop for p in (sig-params sig) collect (var-sym "P"))))
    `(defun ,(obj-sym obj) ,ps
       ,(c-result-form
         result
         `(sb-alien:alien-funcall
           (sb-alien:extern-alien ,(obj-extern obj)
                                  (function ,(if result (alien-type result) 'sb-alien:void)
                                            ,@(mapcar (lambda (p) (alien-type (second p))) (sig-params sig))))
           ,@(loop for p in (sig-params sig) for s in ps collect (c-value-form (second p) s)))))))

;;; Modules (section 3).

(defvar *search-dirs* '() "Where modules are looked for, in order.")
(defvar *interface-only* nil "Whether the module being read is another target's file, read for its interface.")
(defvar *target-names* '("linux-sbcl" "linux" "sbcl"))

(defun find-module-file (name tk)
  "The file of module NAME: in the first directory that has one, which
must be the only one, or the same file through a symbolic link."
  (let ((found '()))
    (dolist (dir *search-dirs*)
      (let ((f (loop for suffix in (append (mapcar (lambda (s) (format nil ".~a" s)) *target-names*) '(""))
                     for path = (format nil "~a/~a~a.raz" dir name suffix)
                     when (probe-file path) return path)))
        (when f (push f found))))
    (setf found (nreverse found))
    (unless found (fail-tok tk "the module ~a can't be found" name))
    (unless (every (lambda (f) (equal (truename f) (truename (first found)))) found)
      (fail-tok tk "the module ~a has files in more than one directory: ~{~a~^, ~}" name found))
    (namestring (truename (first found)))))

(defun load-module (name tk &optional file)
  "Module NAME, read if it hasn't been; a generic module only as far as
its parameters."
  (let ((m (gethash name *modules*)))
    (cond ((null m)
           (let* ((file (or file (find-module-file name tk)))
                  (toks (let ((*file* file)) (scan (read-bytes file)))))
             (setf m (make-module :name name :file file :toks toks :lisp-name name))
             (setf (gethash name *modules*) m)
             (if (and (eq (tok-kind (aref toks 2)) :|(|))
                 (read-generic-header m)
                 (progn (read-module m) (check-other-files m)))))
          ((eq (module-state m) :compiling)
           (fail-tok tk "the module ~a imports itself" name)))
    m))

(defmacro with-module ((m) &body body)
  "BODY reading module M from its start."
  `(let ((*module* ,m) (*toks* (module-toks ,m)) (*pos* 0) (*file* (module-file ,m))
         (*scope* (make-scope :parent *universe*)) (*proc* nil) (*top* t) (*forward-types* :none))
     (setf (module-scope ,m) *scope*)
     ,@body))

(defun module-header ()
  "module Name ( and the name's check against the file's."
  (expect :module)
  (let ((tk (tok)) (name (ident)))
    (unless (string= name (module-name *module*))
      (fail-tok tk "the module ~a is in the file of ~a" name (module-name *module*)))))

(defun read-generic-header (m)
  "A generic module's parameters, counted: the module is compiled only for
each list of arguments."
  (with-module (m)
    (module-header)
    (expect :|(|)
    (let ((types (loop collect (ident) while (accept :|,|))) (procs '()))
      (loop while (accept :|;|)
            do (push (ident) procs) (expect :|:|) (expect :proc)
               ;; skip the signature: its types are known only in an instance
               (let ((depth 0))
                 (loop until (and (= depth 0) (member (kind) '(:|;| :|)|)))
                       do (case (kind) (:|(| (incf depth)) (:|)| (decf depth)))
                          (next-tok))))
      (setf (module-generic m) (cons types (nreverse procs)) (module-state m) :done))))

(defun read-module (m &optional args)
  "Reads and compiles module M; for an instance, ARGS are its arguments."
  (setf (module-state m) :compiling)
  (with-module (m)
    (module-header)
    (when (accept :|(|) (bind-module-params args))
    (expect :|;|)
    (loop while (accept :import) do (import-list))
    (loop while (and (eq (kind) :link))
          do (next-tok)
             (cond ((eq (kind) :string)
                    (let ((lib (sb-ext:octets-to-string (tok-val (next-tok)) :external-format :utf-8)))
                      (handler-case (sb-alien:load-shared-object lib)
                        (error () (fail-tok (tok -1) "the library ~a can't be loaded" lib)))
                      (push lib (module-links m))
                      (setf (module-uses-c m) t)))
                   ((and (eq (kind) :ident) (string= (tok-val (tok)) "static"))
                    (next-tok) (setf (module-static m) t))
                   (t (fail-here "link takes a library's name or static")))
             (expect :|;|))
    (when (and (eq (kind) :ident) (string= (tok-val (tok)) "check"))
      (next-tok)
      (unless (and (eq (kind) :ident) (string= (tok-val (tok)) "off")) (fail-here "check off expected"))
      (next-tok) (expect :|;|)
      (setf (module-check-off m) t))
    (declarations)
    (when *interface-only* (return-from read-module m))
    (when (eq (kind) :begin)
      (next-tok)
      (let* ((sym (lisp-name "(body)"))
             (*proc* (make-proc :block (gensym "BODY")))
             (*scope* (make-scope :parent *scope*))
             (body (statements :end)))
        (emit (procedure-defun sym '() '() '() body nil))
        (setf (module-body m) sym)))
    (expect :end)
    (let ((tk (tok)))
      (unless (equal (ident) (module-name m)) (fail-tok tk "the module ends with its own name, ~a" (module-name m))))
    (expect :|.|)
    (unless (eq (kind) :eof) (fail-here "nothing follows the module's end"))
    (maphash (lambda (name o)
               (when (and (eq (obj-kind o) :proc) (not (obj-defined o)))
                 (fail-tok (obj-tok o) "~a is declared forward and never defined" name)))
             (scope-table *scope*)))
  (setf (module-state m) :done)
  m)

(defun import-list ()
  (loop
    (let* ((tk (tok)) (alias (ident)) (name alias) (args nil))
      (when (accept :|:=|)
        (setf name (ident))
        (when (eq (kind) :|(|)
          ;; the arguments are read where the instance is made
          (setf args *pos*)
          (let ((depth 0))
            (loop do (case (kind) (:|(| (incf depth)) (:|)| (decf depth)) (:eof (fail-here "the import isn't closed")))
                     (next-tok)
                  until (= depth 0)))))
      (when (string= name (module-name *module*)) (fail-tok tk "the module ~a imports itself" name))
      (let* ((target (load-module name tk))
             (imp (make-import :alias alias :target target :args args :tok tk)))
        (cond ((and args (not (module-generic target)))
               (fail-tok tk "~a isn't generic and takes no arguments" name))
              ((and (module-generic target) (not args))
               (fail-tok tk "~a is generic: give its arguments" name)))
        (push imp (module-imports *module*))
        (declare-name (make-obj :name alias :kind :module :val imp :tok tk))))
    (unless (accept :|,|) (return)))
  (expect :|;|))

(defun import-module (imp tk)
  "The module an import stands for: for a generic module, the instance
for its arguments, made now if it hasn't been (section 3)."
  (cond ((import-instance imp))
        ((not (module-generic (import-target imp))) (import-target imp))
        (t (setf (import-instance imp) (make-instance-module imp tk)))))

(defun read-type-args ()
  "A generic module's arguments, after its (: each a type, or (:proc obj)."
  (loop collect (let ((start *pos*))
                  (if (eq (kind) :ident)
                      (let ((obj (qualified-obj)))
                        (if (eq (obj-kind obj) :proc)
                            (list :proc obj)
                            (progn (setf *pos* start) (parse-type))))
                      (parse-type)))
        while (accept :|,|)))

(defun same-args-p (a b)
  (and (= (length a) (length b))
       (every (lambda (x y)
                (if (consp x)
                    (and (consp y) (eq (second x) (second y)))
                    (and (ty-p y) (same-type-p x y))))
              a b)))

(defun make-instance-module (imp tk)
  (let* ((g (import-target imp))
         (args (let ((saved *pos*))
                 (setf *pos* (1+ (import-args imp)))
                 (prog1 (read-type-args) (setf *pos* saved))))
         (ntypes (length (car (module-generic g))))
         (nprocs (length (cdr (module-generic g)))))
    (unless (and (= (length args) (+ ntypes nprocs))
                 (notany #'consp (subseq args 0 (min ntypes (length args))))
                 (every #'consp (nthcdr ntypes args)))
      (fail-tok tk "~a takes ~d types and ~d procedures" (module-name g) ntypes nprocs))
    (let ((old (assoc args (module-instances g) :test #'same-args-p)))
      (if old
          (cdr old)
          (let ((m (make-module :name (module-name g) :file (module-file g) :toks (module-toks g)
                                :lisp-name (format nil "~a(~d)" (module-name g) (1+ (length (module-instances g))))
                                :args args)))
            (push (cons args m) (module-instances g))
            (read-module m args))))))

(defun bind-module-params (args)
  "An instance's parameters: each type parameter names its argument, and
each procedure parameter its procedure, whose signature must be the
parameter's with the types put in."
  (let ((types (loop collect (cons (tok) (ident)) while (accept :|,|))))
    (loop for (tk . name) in types for a in args
          do (declare-name (make-obj :name name :kind :type :type a :tok tk)))
    (let ((procs (nthcdr (length types) args)))
      (loop while (accept :|;|)
            do (let ((tk (tok)) (name (ident)))
                 (expect :|:|) (expect :proc)
                 (let ((sig (signature nil)) (actual (second (pop procs))))
                   (unless (sig-alike-p sig (obj-sig actual))
                     (fail-tok tk "~a's signature isn't the parameter ~a's" (obj-name actual) name))
                   (setf (gethash name (scope-table *scope*)) actual)))))
    (expect :|)|)))

;;; One interface to a module's files (section 3): each file of the
;;; module beside the one taken, Name.*.raz and Name.raz, is read for its
;;; declarations alone, and must export what the one taken does.

(defun other-files (m)
  (let* ((file (module-file m)) (dir (directory-namestring file)))
    (remove-if (lambda (f) (equal (namestring f) file))
               (append (directory (format nil "~a~a.*.raz" dir (module-name m)))
                       (directory (format nil "~a~a.raz" dir (module-name m)))))))

(defun check-other-files (m)
  (loop for f in (other-files m) for i from 1
        do (let* ((file (namestring f))
                  (other (make-module :name (module-name m) :file file
                                      :toks (let ((*file* file)) (scan (read-bytes file)))
                                      :lisp-name (format nil "~a{~d}" (module-name m) i))))
             (let ((*interface-only* t)) (read-module other))
             (compare-interfaces m other))))

(defun iface-type-p (a b)
  "Whether types A and B, of two files of one module, are built alike, a
name in one standing for the same name in the other."
  (cond ((eq a b) t)
        ((or (ty-name a) (ty-name b))
         (and (ty-name a) (ty-name b) (string= (ty-name a) (ty-name b))
              (eq (ty-kind a) (ty-kind b))))
        ((not (eq (ty-kind a) (ty-kind b))) nil)
        (t (case (ty-kind a)
             (:ptr (and (eq (ty-vol a) (ty-vol b)) (iface-type-p (ptr-base a) (ptr-base b))))
             (:array (and (= (ty-len a) (ty-len b)) (iface-type-p (ty-elem a) (ty-elem b))))
             (:slice (iface-type-p (ty-elem a) (ty-elem b)))
             (:set (iface-type-p (ty-enum a) (ty-enum b)))
             (:proc (iface-sig-p (ty-sig a) (ty-sig b)))
             (t (iface-shape-p a b))))))

(defun iface-fields-p (as bs)
  "The exported fields of two records, or the fields of two cases, alike."
  (and (= (length as) (length bs))
       (every (lambda (f g) (and (string= (field-name f) (field-name g))
                                 (iface-type-p (field-type f) (field-type g))))
              as bs)))

(defun iface-shape-p (a b)
  "What a record, variant or enumeration shows another module, alike:
its exported fields, its cases, its names."
  (ecase (ty-kind a)
    (:record (iface-fields-p (remove-if-not #'field-exported (ty-fields a))
                             (remove-if-not #'field-exported (ty-fields b))))
    (:variant (and (= (length (ty-cases a)) (length (ty-cases b)))
                   (every (lambda (c d) (and (string= (vcase-name c) (vcase-name d))
                                             (iface-fields-p (vcase-fields c) (vcase-fields d))))
                          (ty-cases a) (ty-cases b))))
    (:enum (equal (ty-names a) (ty-names b)))
    ((:int :bool :real :error) t)))

(defun iface-sig-p (a b)
  (and (= (length (sig-params a)) (length (sig-params b)))
       (= (length (sig-results a)) (length (sig-results b)))
       (eq (sig-varargs a) (sig-varargs b))
       (every (lambda (p q) (and (eq (third p) (third q)) (iface-type-p (second p) (second q))))
              (sig-params a) (sig-params b))
       (every #'iface-type-p (sig-results a) (sig-results b))))

(defun compare-interfaces (m other)
  (flet ((differ (name file)
           (error 'raz-error :text (format nil "~a: ~a isn't exported as in ~a" file name (module-file m)))))
    (maphash (lambda (name o)
               (let ((p (gethash name (module-exports other))))
                 (unless (and p (eq (obj-kind o) (obj-kind p))
                              (ecase (obj-kind o)
                                ((:const :var :case) (iface-type-p (obj-type o) (obj-type p)))
                                (:type (and (eq (ty-kind (obj-type o)) (ty-kind (obj-type p)))
                                            (if (member (ty-kind (obj-type o)) '(:record :variant :enum))
                                                (iface-shape-p (obj-type o) (obj-type p))
                                                (iface-type-p (obj-type o) (obj-type p)))))
                                (:proc (iface-sig-p (obj-sig o) (obj-sig p)))))
                   (differ name (module-file other)))))
             (module-exports m))
    (maphash (lambda (name p) (declare (ignore p))
               (unless (gethash name (module-exports m)) (differ name (module-file other))))
             (module-exports other))))
