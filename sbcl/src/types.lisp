;;;; types.lisp -- raz's types: what they are, their layout, and when two
;;;; are the same or one is assignable to another.
;;;;
;;;; Report, section 5. A type is a TY. Every type the program writes out
;;;; is a fresh TY; a declaration `type P = ^Node` makes one with a name,
;;;; and `type Count = I64` makes no type at all, only another name for
;;;; I64's. Sameness (5.10) is then a matter of NAME and of what the type
;;;; is built of.

(in-package :raz)

;;; KIND is one of
;;;   :int :bool :real :error   the basic types (BITS and SIGNED for :int, BITS for :real)
;;;   :ptr      BASE, the type pointed at, and VOL for ^VOLATILE
;;;   :array    LEN elements of ELEM;  :slice  elements of ELEM
;;;   :record   FIELDS, PACKED;  :variant  CASES
;;;   :enum     NAMES, strings in order;  :set  ENUM, an :enum
;;;   :proc     SIG, a SIG
;;; and, for the values that have no type of their own yet,
;;;   :untyped-int, :untyped-real, :string (a string literal), :nil.
;;; MODULE is the module that declared the type, which decides who may
;;; see its unexported fields.

(defstruct (ty (:print-function (lambda (ty s d) (declare (ignore d))
                                  (write-string (type-name ty) s))))
  kind name (size 0) (align 1)
  bits signed base vol len elem fields packed cases names enum sig module)

;;; A field of a record, or of a case of a variant: its OFFSET from the
;;; record's start (from the variant's, for a case).
(defstruct field name type offset exported)

;;; A case of a variant: its INDEX, which is its tag, and its FIELDS.
(defstruct vcase name index fields variant)

;;; A procedure's signature: PARAMS are (name type var-p) lists, RESULTS
;;; types; VARARGS for an extern's `...`.
(defstruct sig params results varargs)

(defun word-size () 8)

;;; The basic types, made once.

(defun make-int-type (name bits signed)
  (make-ty :kind :int :name name :bits bits :signed signed
           :size (/ bits 8) :align (/ bits 8)))

(defparameter *basic-types*
  (list (make-int-type "I8" 8 t) (make-int-type "I16" 16 t)
        (make-int-type "I32" 32 t) (make-int-type "I64" 64 t)
        (make-int-type "U8" 8 nil) (make-int-type "U16" 16 nil)
        (make-int-type "U32" 32 nil) (make-int-type "U64" 64 nil)
        (make-int-type "INT" 64 t) (make-int-type "UINT" 64 nil)
        (make-ty :kind :bool :name "BOOL" :size 1 :align 1)
        (make-ty :kind :real :name "F32" :bits 32 :size 4 :align 4)
        (make-ty :kind :real :name "F64" :bits 64 :size 8 :align 8)
        (make-ty :kind :error :name "ERROR" :size 8 :align 8)))

(defun basic (name) (find name *basic-types* :key #'ty-name :test #'string=))

(defparameter *untyped-int* (make-ty :kind :untyped-int :name "an integer constant"))
(defparameter *untyped-real* (make-ty :kind :untyped-real :name "a real constant"))
(defparameter *nil-type* (make-ty :kind :nil :name "nil"))

(defun string-type (len)
  (make-ty :kind :string :name "a string" :len len))

(defun type-name (ty)
  (or (ty-name ty)
      (case (ty-kind ty)
        (:ptr (format nil "^~:[~;VOLATILE ~]~a" (ty-vol ty) (type-name* (ty-base ty))))
        (:array (format nil "[~d]~a" (ty-len ty) (type-name (ty-elem ty))))
        (:slice (format nil "[]~a" (type-name (ty-elem ty))))
        (:record "a record") (:variant "a variant") (:enum "an enumeration")
        (:set (format nil "set of ~a" (type-name (ty-enum ty))))
        (:proc "a procedure type")
        (t (string-downcase (ty-kind ty))))))

(defun type-name* (x) (if (ty-p x) (type-name x) (format nil "~a" (second x))))

;;; Kinds of types, as the rules ask about them.

(defun int-p (ty) (eq (ty-kind ty) :int))
(defun real-p (ty) (eq (ty-kind ty) :real))
(defun ptr-p (ty) (eq (ty-kind ty) :ptr))
(defun aggregate-p (ty)
  "A type whose values the compiled code handles by address."
  (member (ty-kind ty) '(:array :slice :record :variant :string)))
(defun is (ty kind) (eq (ty-kind ty) kind))

;;; A pointer's base may name a type declared later in its `type`
;;; section (section 4): until then BASE is (:forward name), and the
;;; section's end puts the type in its place.
(defun ptr-base (ty)
  (let ((b (ty-base ty)))
    (when (consp b) (error "pointer base still forward"))
    b))

;;; Layout (5.5, 5.6). Each field at the next multiple of its alignment,
;;; the whole padded to the largest; a packed record has no padding.

(defun round-up (n align) (* align (ceiling n align)))

(defun lay-out-fields (fields start packed)
  "Sets each field's offset, from START; returns the end and the largest alignment."
  (let ((off start) (align 1))
    (dolist (f fields)
      (let ((ft (field-type f)))
        (unless packed (setf off (round-up off (ty-align ft))))
        (setf (field-offset f) off)
        (incf off (ty-size ft))
        (setf align (max align (if packed 1 (ty-align ft))))))
    (values off align)))

(defun make-record-type (fields packed module)
  (multiple-value-bind (end align) (lay-out-fields fields 0 packed)
    (make-ty :kind :record :fields fields :packed packed :module module
             :size (round-up end align) :align align)))

(defun make-variant-type (cases module)
  ;; an INT tag, then each case's fields as a record's after it
  (let ((size 8) (align 8) (ty (make-ty :kind :variant :cases cases :module module)))
    (dolist (c cases)
      (setf (vcase-variant c) ty)
      (multiple-value-bind (end a) (lay-out-fields (vcase-fields c) 8 nil)
        (setf size (max size end) align (max align a))))
    (setf (ty-size ty) (round-up size align) (ty-align ty) align)
    ty))

(defun make-enum-type (names module)
  (make-ty :kind :enum :names names :size 1 :align 1 :module module))

(defun make-set-type (enum)
  (let ((n (length (ty-names enum))))
    (let ((size (cond ((<= n 8) 1) ((<= n 16) 2) ((<= n 32) 4) (t 8))))
      (make-ty :kind :set :enum enum :size size :align size))))

(defun make-ptr-type (base vol)
  (make-ty :kind :ptr :base base :vol vol :size 8 :align 8))

(defun make-array-type (len elem)
  (make-ty :kind :array :len len :elem elem
           :size (* len (ty-size elem)) :align (ty-align elem)))

(defun make-slice-type (elem)
  (make-ty :kind :slice :elem elem :size 16 :align 8))

(defun make-proc-type (sig)
  (make-ty :kind :proc :sig sig :size 8 :align 8))

;;; Sameness (5.10). Two named types are the same only if they are one
;;; declaration. A record, variant or enumeration is its own type
;;; wherever it is written. Anonymous pointers, arrays, slices, sets and
;;; procedure types are the same if built alike, and a named type is the
;;; same as an anonymous one it is built like.

(defun same-type-p (a b)
  (cond ((eq a b) t)
        ((and (ty-name a) (ty-name b)) nil)
        ((not (eq (ty-kind a) (ty-kind b))) nil)
        (t (case (ty-kind a)
             (:ptr (and (eq (ty-vol a) (ty-vol b)) (same-type-p (ptr-base a) (ptr-base b))))
             (:array (and (= (ty-len a) (ty-len b)) (same-type-p (ty-elem a) (ty-elem b))))
             (:slice (same-type-p (ty-elem a) (ty-elem b)))
             (:set (same-type-p (ty-enum a) (ty-enum b)))
             (:proc (sig-alike-p (ty-sig a) (ty-sig b)))
             (t nil)))))

(defun sig-alike-p (a b)
  "Two signatures are alike: their parameters' types, each var or not
alike, and their results' types (5.9)."
  (and (= (length (sig-params a)) (length (sig-params b)))
       (= (length (sig-results a)) (length (sig-results b)))
       (eq (sig-varargs a) (sig-varargs b))
       (every (lambda (p q) (and (eq (third p) (third q)) (same-type-p (second p) (second q))))
              (sig-params a) (sig-params b))
       (every #'same-type-p (sig-results a) (sig-results b))))

;;; Integer ranges.

(defun int-min (ty) (if (ty-signed ty) (- (expt 2 (1- (ty-bits ty)))) 0))
(defun int-max (ty) (if (ty-signed ty) (1- (expt 2 (1- (ty-bits ty)))) (1- (expt 2 (ty-bits ty)))))
(defun fits-p (v ty) (<= (int-min ty) v (int-max ty)))

(defun wrap-int (v ty)
  "V cut to TY's width, as the program's arithmetic wraps."
  (if (ty-signed ty)
      (sb-c::mask-signed-field (ty-bits ty) v)
      (ldb (byte (ty-bits ty) 0) v)))

;;; What can hold a nil, and what compares only for equality.
(defun nil-able-p (ty) (member (ty-kind ty) '(:ptr :proc :error)))

;;; Elements whose arrays compare with = and # (6.5).
(defun bytewise-comparable-p (ty)
  (member (ty-kind ty) '(:int :bool :enum :set :ptr)))

;;; The kind of memory access a scalar type needs: a keyword the run
;;; time's LD and ST take (rt.lisp).
(defun access-kind (ty)
  (ecase (ty-kind ty)
    (:int (intern (format nil "~:[U~;I~]~d" (ty-signed ty) (ty-bits ty)) :keyword))
    (:bool :bool)
    (:real (if (= (ty-bits ty) 32) :f32 :f64))
    ((:ptr :proc :error) :u64)
    (:enum :u8)
    (:set (intern (format nil "U~d" (* 8 (ty-size ty))) :keyword))))

(defun zero-value (ty)
  "The Lisp value a scalar of TY starts at."
  (case (ty-kind ty)
    (:bool nil)
    (:real (if (= (ty-bits ty) 32) 0f0 0d0))
    (t 0)))
