;;;; package.lisp -- the packages of the compiler.
;;;;
;;;; RAZ holds the compiler and the run time that compiled programs call.
;;;; RAZP holds the names the compiler makes for a program's procedures,
;;;; such as |Out.str|, so that they never meet the compiler's own.

(defpackage :raz
  (:use :common-lisp)
  (:shadow #:import #:*modules*)
  (:export #:main))

(defpackage :razp
  (:use))
