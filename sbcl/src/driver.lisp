;;;; driver.lisp -- the command line, and a program's modules made into
;;;; one executable.
;;;;
;;;;   raz [-I dir]... [-o exe] [-S] file.raz
;;;;
;;;; The compiler reads the main module and, through their imports, every
;;;; module it needs, Rt always among them. It then compiles the Lisp it
;;;; made with SBCL, into this very image, and saves the image as the
;;;; executable, to start at the run time's START (rt.lisp). -S also
;;;; writes the Lisp to exe.lisp, for whoever wants to read it.

(in-package :raz)

(defparameter *version* "raz-sbcl 0.1.0, report 2026-10.23")

(defun body-order (roots)
  "The modules whose bodies run, in order (section 3): each after those
it imports, in the order of its imports."
  (let ((seen '()) (order '()))
    (labels ((visit (m)
               (unless (member m seen)
                 (push m seen)
                 (dolist (imp (reverse (module-imports m)))
                   (let ((target (if (module-generic (import-target imp))
                                     (import-instance imp)
                                     (import-target imp))))
                     (when target (visit target))))
                 (push m order))))
      (mapc #'visit roots))
    (nreverse order)))

(defun all-modules ()
  "Every module of the program, each generic module's instances in its place."
  (let ((ms '()))
    (maphash (lambda (name m) (declare (ignore name))
               (if (module-generic m)
                   (dolist (i (module-instances m)) (push (cdr i) ms))
                   (push m ms)))
             *modules*)
    ms))

(defun main-form (main)
  "The program's function: every body, then main; its value the status."
  (let* ((obj (gethash "main" (module-exports main)))
         (call (cond ((null obj) 0)
                     ((not (eq (obj-kind obj) :proc))
                      (fail-tok (obj-tok obj) "main is a procedure"))
                     ((and (null (sig-params (obj-sig obj))) (null (sig-results (obj-sig obj))))
                      `(progn (,(obj-sym obj)) 0))
                     ((and (null (sig-params (obj-sig obj)))
                           (equal (sig-results (obj-sig obj)) (list (basic "INT"))))
                      `(,(obj-sym obj)))
                     (t (fail-tok (obj-tok obj) "main is proc main*; or proc main*: INT;")))))
    `(lambda ()
       ,@(loop for m in (body-order (list (gethash "Rt" *modules*) main))
               when (module-body m) collect `(,(module-body m)))
       ,call)))

(defun compile-forms (forms)
  "Compiles FORMS into this image, quietly."
  (handler-bind ((warning #'muffle-warning)
                 (sb-ext:compiler-note #'muffle-warning))
    (let ((*error-output* (make-broadcast-stream)))
      (with-compilation-unit ()
        (dolist (f forms)
          (let ((*package* (find-package :raz)))
            (funcall (compile nil `(lambda () ,f)))))))))

(defun compile-program (file out includes dump)
  (let* ((path (probe-file file))
         (name (pathname-name file))
         (*search-dirs* (append (list (directory-namestring (or path #p"./")))
                                includes
                                (list (namestring (merge-pathnames "lib/" (directory-namestring sb-ext:*runtime-pathname*))))))
         (*file* file))
    (unless path (error 'raz-error :text (format nil "~a: no such file" file)))
    (setf *universe* (make-universe))
    (let* ((none (make-tok :eof nil 1 1))
           (main (progn (load-module "Rt" none) (load-module name none (namestring path))))
           (modules (all-modules)))
      (when (module-generic main)
        (error 'raz-error :text (format nil "~a: ~a is generic: it is compiled where a module imports it"
                                        file name)))
      (when (and (some #'module-static modules) (some #'module-uses-c modules))
        (error 'raz-error
               :text (format nil "~a: the program uses C (~{~a~^, ~}), which ~{~a~^, ~} doesn't allow by link static"
                             file (mapcar #'module-name (remove-if-not #'module-uses-c modules))
                             (mapcar #'module-name (remove-if-not #'module-static modules)))))
      (let ((forms (reverse *forms*)) (entry (let ((*file* file)) (main-form main))))
        (when dump
          (with-open-file (s (format nil "~a.lisp" out) :direction :output :if-exists :supersede)
            (let ((*package* (find-package :raz)) (*print-circle* t) (*print-right-margin* 110))
              (dolist (f (append forms (list entry))) (pprint f s) (terpri s)))))
        (compile-forms forms)
        (setf *main* (let ((*package* (find-package :raz))) (compile nil entry)))
        (setf *procs* (let ((v (make-array (1+ (length *proc-values*)) :initial-element nil)))
                        (loop for (h . sym) in *proc-values* do (setf (svref v h) (symbol-function sym)))
                        v))
        (setf *data-image* (coerce *data* '(simple-array (unsigned-byte 8) (*))))))))

(defun usage ()
  (format *error-output* "usage: raz [-I dir]... [-o exe] [-S] file.raz~%")
  (sb-ext:exit :code 2 :abort t))

(defun main ()
  "The compiler's command line."
  (let ((args (rest sb-ext:*posix-argv*)) (includes '()) (out nil) (dump nil) (file nil))
    (loop while args
          do (let ((a (pop args)))
               (cond ((string= a "-I") (unless args (usage)) (setf includes (append includes (list (pop args)))))
                     ((string= a "-o") (unless args (usage)) (setf out (pop args)))
                     ((string= a "-S") (setf dump t))
                     ((string= a "-Werror"))           ; this compiler gives no warnings
                     ((string= a "--version") (format t "~a~%" *version*) (sb-ext:exit :code 0))
                     ((and (> (length a) 1) (char= (char a 0) #\-)) (usage))
                     (file (usage))
                     (t (setf file a)))))
    (unless file (usage))
    (let ((out (or out (pathname-name file))))
      (handler-case
          ;; with RAZ_DEBUG set, the compiler's own mistakes come with a backtrace
          (handler-bind ((error (lambda (e)
                                  (when (and (sb-ext:posix-getenv "RAZ_DEBUG") (not (typep e 'raz-error)))
                                    (sb-debug:print-backtrace :count 25)
                                    (format *error-output* "~a~%" e)
                                    (sb-ext:exit :code 3 :abort t)))))
          (sb-int:with-float-traps-masked (:overflow :invalid :inexact :divide-by-zero :underflow)
            (compile-program file out includes dump)))
        (raz-error (e)
          (format *error-output* "~a~%" (raz-error-text e))
          (sb-ext:exit :code 1 :abort t))
        (error (e)
          ;; a mistake of the compiler's own, not the program's
          (format *error-output* "raz: internal error: ~a~%" e)
          (sb-ext:exit :code 3 :abort t)))
      (sb-ext:save-lisp-and-die out :executable t :toplevel #'start :save-runtime-options t))))
