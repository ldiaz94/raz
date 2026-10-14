;;;; build.lisp -- builds the compiler: `sbcl --script build.lisp` writes
;;;; ./raz, an SBCL image holding the compiler, which it saves again, with
;;;; the program added, as each executable it makes.

(require :sb-introspect)

(defparameter *sources* '("package" "scan" "types" "rt" "comp" "expr" "stmt" "decl" "driver"))

(let ((*compile-verbose* nil) (*compile-print* nil))
  (handler-bind ((warning (lambda (w)
                            ;; style warnings about the order of definitions are no matter
                            (when (typep w 'style-warning) (muffle-warning w)))))
    (with-compilation-unit ()
      (dolist (f *sources*)
        (let ((src (format nil "src/~a.lisp" f))
              (fasl (format nil "build/~a.fasl" f)))
          (ensure-directories-exist fasl)
          (load (compile-file src :output-file (merge-pathnames fasl))))))))

(sb-ext:save-lisp-and-die "raz" :executable t :toplevel (intern "MAIN" :raz)
                          :save-runtime-options t)
