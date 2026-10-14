;;;; stmt.lisp -- statements (report, section 7), each turned into a list
;;;; of Lisp forms.
;;;;
;;;; A procedure's body is a Lisp BLOCK, left by RETURN-FROM; each loop is
;;;; a block of its own, which `break` leaves. Deferred statements (7.7)
;;;; are known where they are written, so the compiler puts a copy of each
;;;; wherever its statement list can be left: at its end, and before each
;;;; `return`, `try` and `break` that leaves it. The program never needs to
;;;; keep a list of them as it runs.

(in-package :raz)

(defun in-loop (fn)
  "The forms FN makes, given the name of the loop's block, within that
block, which `break` leaves."
  (let ((blk (gensym "LOOP")))
    (push (list blk (length (proc-defers *proc*))) (proc-loops *proc*))
    (let ((forms (unwind-protect (funcall fn blk) (pop (proc-loops *proc*)))))
      (list `(block ,blk ,@forms)))))

(defmacro with-loop ((blk) &body body) `(in-loop (lambda (,blk) ,@body)))

(defun statements (&rest enders)
  "Statements up to one of the tokens ENDERS: their forms, and after them
the statements deferred among them, the last first."
  (push '() (proc-defers *proc*))
  (let ((forms (loop until (member (kind) enders)
                     append (prog1 (statement) (expect :|;| "; after a statement")))))
    (append forms (pop (proc-defers *proc*)))))

(defun pending-defers (&optional (depth 0))
  "The deferred statements of the lists the program leaves, the innermost
first: all of them, or those inside the DEPTH outer lists."
  (let ((frames (proc-defers *proc*)))
    (apply #'append (subseq frames 0 (- (length frames) depth)))))

(defun statement ()
  (let ((tk (tok)))
    (case (kind)
      ((:ident :blank) (assignment-or-call))
      (:if (next-tok) (if-statement))
      (:while (next-tok)
       (let ((c (condition-form)))
         (expect :do)
         (with-loop (blk)
           (prog1 `((loop (unless ,c (return-from ,blk)) ,@(statements :end)))
             (expect :end)))))
      (:repeat (next-tok)
       (with-loop (blk)
         (let ((body (statements :until)))
           (expect :until)
           `((loop ,@body (when ,(condition-form) (return-from ,blk)))))))
      (:for (next-tok) (for-statement tk))
      (:match (next-tok) (match-statement tk))
      (:return (next-tok) (list (return-statement tk)))
      (:break (next-tok)
       (let ((l (first (proc-loops *proc*))))
         (unless l (fail-tok tk "break stands outside a loop~:[~; of the deferred statement~]"
                             (proc-in-defer *proc*)))
         `(,@(pending-defers (second l)) (return-from ,(first l)))))
      (:defer (next-tok) (defer-statement tk) '())
      (:try (let ((item (try-item (next-tok))))
              (list (item-form item))))
      (t (fail-here "a statement expected, not ~a" (describe-tok tk))))))

(defun condition-form ()
  (let* ((tk (tok)) (c (need-value (expression))))
    (unless (is (item-type c) :bool) (fail-tok tk "the condition is ~a, not a BOOL" (type-name (item-type c))))
    (value-form c)))

(defun if-statement ()
  (let ((clauses '()))
    (loop
      (let ((c (condition-form)))
        (expect :then)
        (push (cons c (statements :elsif :else :end)) clauses))
      (unless (accept :elsif) (return)))
    (when (accept :else)
      (push (cons t (statements :end)) clauses))
    (expect :end)
    (list `(cond ,@(reverse clauses)))))

;;; Assignments and calls (7.1).

(defun check-target (x tk)
  "X, which must be a variable that can be assigned."
  (unless (eq (item-mode x) :var) (fail-tok tk "only a variable can be assigned"))
  (check-writable x tk "assigned")
  (when (and (item-vol x) (aggregate-p (item-type x)))
    (fail-tok tk "a whole record or array can't be copied through a volatile pointer"))
  x)

(defun target ()
  "An assignment's target: a writable variable's item, or nil for `_`."
  (if (accept :blank) nil (let ((tk (tok))) (check-target (designator) tk))))

(defun assignment-or-call ()
  (let ((tk (tok)))
    (if (or (eq (kind) :blank) (multiple-targets-p))
        (assignment (loop collect (target) while (accept :|,|)))
        (let ((x (designator)))
          (if (eq (kind) :|:=|)
              (assignment (list (check-target x tk)))
              (list (call-statement x tk)))))))

(defun multiple-targets-p ()
  "Whether the statement is `a, b := ...`: a comma before the := at the
statement's own level."
  (let ((depth 0))
    (loop for k from 0
          for kd = (kind k)
          do (case kd
               ((:|(| :|[| :{) (incf depth))
               ((:|)| :|]| :}) (decf depth))
               (:|,| (when (= depth 0) (return t)))
               ((:|:=| :|;| :eof :end) (return nil))))))

(defun call-statement (x tk)
  "A designator standing alone: a call, whose results are dropped."
  (case (item-mode x)
    (:proc (item-form (call-proc (item-obj x) nil tk)))
    ((:none :multi) (item-form x))
    (t (if (consp (item-obj x))
           (item-form x)                ; a call with one result
           (if (and (member (item-mode x) '(:var :val)) (is (item-type x) :proc))
               (item-form (call-proc nil x tk))
               (fail-tok tk "this isn't a statement"))))))

(defun assignment (targets)
  (progn
    (expect :|:=|)
    (let* ((rtk (tok)) (e (expression)) (syms (loop repeat (length targets) collect (var-sym "T"))))
      (if (rest targets)
          ;; several results, of exactly the targets' types
          (progn
            (unless (eq (item-mode e) :multi)
              (fail-tok rtk "~d targets need a call with ~:*~d results" (length targets)))
            (unless (= (length (item-type e)) (length targets))
              (fail-tok rtk "~d targets for ~d results" (length targets) (length (item-type e))))
            (let ((vals (loop repeat (length targets) collect (var-sym "V"))))
              (list `(let ,(loop for s in syms for x in targets when x collect `(,s ,(item-form x)))
                       (multiple-value-bind ,vals ,(item-form e)
                         ,@(loop for s in syms for x in targets for v in vals for ty in (item-type e)
                                 when x
                                   collect (progn
                                             (unless (same-type-p (item-type x) ty)
                                               (fail-tok rtk "a result of ~a goes to ~a" (type-name ty) (type-name (item-type x))))
                                             (if (aggregate-p ty)
                                                 `(move ,s ,v ,(ty-size ty))
                                                 `(st ,(access-kind ty) ,s ,v)))))))))
          (let ((x (first targets)))
            (if x
                (list `(let ((,(first syms) ,(item-form x)))
                         ,(store-form (first syms) (item-type x) e rtk)))
                ;; `_ := e`: e evaluated, and dropped
                (list (if (member (item-mode e) '(:none :multi))
                          (fail-tok rtk "_ takes one value")
                          (value-form e)))))))))

;;; for (7.2).

(defun exact-form (item ty tk what)
  "ITEM's value as TY, which it must be, or an untyped constant that fits:
an INT doesn't widen here (5.10)."
  (let ((item (need-value item)))
    (unless (or (and (untyped-p item) (not (assign-error item ty)))
                (same-type-p (item-type item) ty))
      (fail-tok tk "~a is ~a, not ~a" what (type-name (item-type item)) (type-name ty)))
    (coerce-item item ty tk)))

(defun for-statement (tk)
  (let* ((vtk (tok)) (name (ident)) (obj (lookup name)))
    (unless (and obj (eq (obj-kind obj) :var)) (fail-tok vtk "~a isn't a variable" name))
    (unless (eq (kind) :|:=|) (fail-tok (tok) "the for variable is named by its name alone"))
    (expect :|:=|)
    (let* ((v (obj-item obj vtk)) (ty (item-type v)))
      (check-writable v vtk "a for variable")
      (unless (member (ty-kind ty) '(:int :enum))
        (fail-tok vtk "a for variable is an integer or an enumeration, not ~a" (type-name ty)))
      (let* ((a (exact-form (expression) ty tk "the start"))
             (b (progn (expect :to) (exact-form (expression) ty tk "the limit")))
             (s (if (accept :by)
                    (let* ((stk (tok)) (s (need-value (expression))))
                      (unless (and (const-p s) (member (ty-kind (item-type s)) '(:untyped-int :int)))
                        (fail-tok stk "a for loop's step is an integer constant"))
                      (when (= (item-val s) 0) (fail-tok stk "a for loop's step isn't 0"))
                      (item-val s))
                    1))
             (k (access-kind ty))
             (wrap (if (is ty :enum) (basic "U8") ty)))
        (expect :do)
        (with-loop (blk)
          (let ((body (statements :end)))
            (expect :end)
            ;; at a round's end: stop if one more step would pass the limit
            `((let* ((at ,(item-form v)) (lo ,a) (hi ,b))
                (st ,k at lo)
                (when ,(if (> s 0) '(<= lo hi) '(>= lo hi))
                  (loop ,@body
                        (let ((i (ld ,k at)))
                          (when ,(if (> s 0) `(and (<= i hi) (< (- hi i) ,s)) `(and (>= i hi) (< (- i hi) ,(- s))))
                            (return-from ,blk))
                          (st ,k at ,(wrap-form wrap `(+ i ,s)))
                          (unless ,(if (> s 0) `(<= (ld ,k at) hi) `(>= (ld ,k at) hi))
                            (return-from ,blk)))))))))))))

;;; match (7.4).

(defun match-statement (tk)
  (let* ((etk (tok)) (x (need-value (expression))) (ty (item-type x)))
    (expect :of)
    (case (ty-kind ty)
      (:variant (match-variant x ty tk))
      (:enum (match-enum x ty tk))
      ((:int :untyped-int) (match-int x (if (is ty :int) ty (basic "INT")) tk))
      (t (fail-tok etk "match takes a variant, an enumeration or an integer, not ~a" (type-name ty))))))

(defun arm-else-p () (and (eq (kind) :else) (eq (kind 1) :|:|)))

(defun match-variant (x ty tk)
  ;; the arms' names stand for the fields of x itself if it is a variable
  ;; that may change, else of a copy
  (let* ((s (var-sym "S"))
         (src (if (and (eq (item-mode x) :var) (not (item-ro x)))
                  (item-form x)
                  `(move ,(temp ty) ,(value-form x) ,(ty-size ty))))
         (arms '()) (seen '()) (else nil))
    (loop while (accept :|\||)
          do (let ((atk (tok)))
               (when else (fail-tok atk "else is the last arm"))
               (if (arm-else-p)
                   (progn (next-tok) (next-tok) (setf else (cons t (statements :|\|| :end))))
                   (let* ((name (ident))
                          (c (find name (ty-cases ty) :key #'vcase-name :test #'string=)))
                     (unless c (fail-tok atk "~a isn't a case of the variant" name))
                     (when (member c seen) (fail-tok atk "the case ~a has two arms" name))
                     (push c seen)
                     (let ((names (when (accept :|(|)
                                    (prog1 (loop collect (cons (tok) (ident)) while (accept :|,|))
                                      (expect :|)|)))))
                       (when (and names (/= (length names) (length (vcase-fields c))))
                         (fail-tok atk "the case ~a has ~d fields" name (length (vcase-fields c))))
                       (expect :|:|)
                       (let ((*scope* (make-scope :parent *scope*)))
                         (loop for (ntk . n) in names for f in (vcase-fields c)
                               do (declare-name (make-obj :name n :kind :var :type (field-type f) :tok ntk
                                                          :where (list :at `(+ ,s ,(field-offset f))))))
                         (push (cons (list (vcase-index c)) (statements :|\|| :end)) arms)))))))
    (expect :end)
    (unless (or else (= (length seen) (length (ty-cases ty))))
      (fail-tok tk "the case ~a has no arm" (vcase-name (find-if-not (lambda (c) (member c seen)) (ty-cases ty)))))
    (list `(let ((,s ,src))
             (case (ld :i64 ,s) ,@(reverse arms) ,@(when else `((t ,@(rest else)))))))))

(defun match-enum (x ty tk)
  (let ((arms '()) (seen '()) (else nil) (v (var-sym "V")))
    (loop while (accept :|\||)
          do (let ((atk (tok)))
               (when else (fail-tok atk "else is the last arm"))
               (if (arm-else-p)
                   (progn (next-tok) (next-tok) (setf else (cons t (statements :|\|| :end))))
                   (let ((positions
                           (loop collect (let* ((ntk (tok)) (name (ident))
                                                (i (position name (ty-names ty) :test #'string=)))
                                           (unless i (fail-tok ntk "~a isn't a name of the enumeration" name))
                                           (when (member i seen) (fail-tok ntk "~a has two arms" name))
                                           (push i seen)
                                           i)
                                 while (accept :|,|))))
                     (expect :|:|)
                     (push (cons positions (statements :|\|| :end)) arms)))))
    (expect :end)
    (unless (or else (= (length seen) (length (ty-names ty))))
      (fail-tok tk "the name ~a has no arm"
                (loop for n in (ty-names ty) for i from 0 unless (member i seen) return n)))
    (list `(let ((,v ,(value-form x)))
             (case ,v ,@(reverse arms) ,@(when else `((t ,@(rest else)))))))))

(defun match-int (x ty tk)
  (let ((arms '()) (ranges '()) (else nil) (v (var-sym "V")))
    (loop while (accept :|\||)
          do (let ((atk (tok)))
               (when else (fail-tok atk "else is the last arm"))
               (if (arm-else-p)
                   (progn (next-tok) (next-tok) (setf else (cons t (statements :|\|| :end))))
                   (let ((tests
                           (loop collect
                                 (let* ((ltk (tok)) (lo (label-value ty ltk))
                                        (hi (if (accept :..) (label-value ty ltk) lo)))
                                   (when (> lo hi) (fail-tok ltk "the label's range runs backwards"))
                                   (dolist (r ranges)
                                     (when (and (<= lo (cdr r)) (>= hi (car r)))
                                       (fail-tok ltk "a value is in two labels")))
                                   (push (cons lo hi) ranges)
                                   (if (= lo hi) `(= ,v ,lo) `(<= ,lo ,v ,hi)))
                                 while (accept :|,|))))
                     (expect :|:|)
                     (push `((or ,@tests) ,@(statements :|\|| :end)) arms)))))
    (expect :end)
    (unless else (fail-tok tk "a match on an integer has an else arm"))
    (list `(let ((,v ,(value-form x)))
             (cond ,@(reverse arms) (t ,@(rest else)))))))

(defun label-value (ty tk)
  (let ((x (need-value (expression))))
    (unless (and (const-p x) (member (ty-kind (item-type x)) '(:int :untyped-int)))
      (fail-tok tk "a label is an integer constant"))
    (let ((why (assign-error x ty)))
      (when why (fail-tok tk "~a" why)))
    (item-val x)))

;;; return (7.3), and the return that `try` makes (7.8).

(defun result-forms (forms)
  "The forms of the results to return: an aggregate one copied to its
destination first."
  (loop for f in forms for d in (proc-dests *proc*) for ty in (proc-results *proc*)
        collect (if d `(move ,d ,f ,(ty-size ty)) f)))

(defun leave-form (values-form)
  "Returns VALUES-FORM, evaluated before the pending deferred statements run."
  `(return-from ,(proc-block *proc*) (multiple-value-prog1 ,values-form ,@(pending-defers))))

(defun zeros-form (results)
  "Each result as a variable of its type starts (section 4)."
  `(values ,@(loop for ty in results for d in (proc-dests *proc*)
                   collect (if d `(zero ,d ,(ty-size ty)) (zero-value ty)))))

(defun return-zeros-form (err)
  "Return zeros and the error ERR, as try does."
  (let ((results (proc-results *proc*)))
    (leave-form `(values ,@(rest (zeros-form (butlast results))) ,err))))

(defun return-statement (tk)
  (when (proc-in-defer *proc*) (fail-tok tk "return can't leave a deferred statement"))
  (let ((results (proc-results *proc*)))
    (if (member (kind) '(:|;| :end :else :elsif :until :|\||))
        (progn
          (when results (fail-tok tk "the procedure returns ~d results" (length results)))
          (leave-form '(values)))
        (let ((items (loop collect (expression) while (accept :|,|))))
          (unless results (fail-tok tk "the procedure has no results to return"))
          (if (and (null (rest items)) (rest results))
              ;; return f(x): f's results, exactly the procedure's
              (let ((e (first items)))
                (unless (and (eq (item-mode e) :multi)
                             (= (length (item-type e)) (length results))
                             (every #'same-type-p (item-type e) results))
                  (fail-tok tk "the procedure returns ~d results, of its own types" (length results)))
                (let ((vals (loop repeat (length results) collect (var-sym "V"))))
                  (leave-form `(multiple-value-bind ,vals ,(item-form e)
                                 (values ,@(result-forms vals))))))
              (progn
                (unless (= (length items) (length results))
                  (fail-tok tk "~d results for a procedure of ~d" (length items) (length results)))
                (when (some (lambda (i) (member (item-mode i) '(:multi :none))) items)
                  (fail-tok tk "a call with several results or none returned among others"))
                (leave-form `(values ,@(result-forms
                                        (loop for i in items for ty in results
                                              collect (coerce-item i ty)))))))))))

;;; defer (7.7): the statement compiled now, run where the list is left.

(defun defer-statement (tk)
  (when (proc-in-defer *proc*) (fail-tok tk "a deferred statement can't defer"))
  (let ((forms (let ((saved-loops (proc-loops *proc*)))
                 (setf (proc-in-defer *proc*) t (proc-loops *proc*) '())
                 (push '() (proc-defers *proc*))
                 (unwind-protect (statement)
                   (pop (proc-defers *proc*))
                   (setf (proc-in-defer *proc*) nil (proc-loops *proc*) saved-loops)))))
    (push `(progn ,@forms) (first (proc-defers *proc*)))))
