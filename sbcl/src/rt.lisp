;;;; rt.lisp -- the run time: what the compiled code calls.
;;;;
;;;; A compiled program is Lisp code over raw memory. Every raz variable
;;;; lives at an address, as the report wants (ADR works on any of them):
;;;;
;;;;  - the module variables, the string literals, the constant arrays
;;;;    and records and the errors' messages lie in one block, the data,
;;;;    mapped at the fixed address +DATA-BASE+, so that each of their
;;;;    addresses is a number the compiler knows;
;;;;  - a procedure's parameters, variables and temporaries lie in its
;;;;    frame, on a raz stack of its thread: *SP* is the first free byte.
;;;;
;;;; Values in Lisp: an integer, pointer, ERROR or set is an integer,
;;;; kept within its type's range; a BOOL is T or NIL; a real a
;;;; DOUBLE-FLOAT or SINGLE-FLOAT; a procedure value a number, its index
;;;; in *PROCS*. An array, record, variant or slice is handled by its
;;;; address. This file holds the operations on these that are more than
;;;; a Lisp function the compiler can name directly.

(in-package :raz)

(defconstant +data-base+ #x200000000000
  "Where the data block is mapped, out of the way of SBCL's own memory.")

(sb-ext:defglobal *data-image* (make-array 0 :element-type '(unsigned-byte 8))
  "The data block's first contents, made by the compiler.")

(sb-ext:defglobal *procs* (vector nil)
  "The procedures that are values: a procedure value is an index here; 0 is nil.")

(sb-ext:defglobal *main* nil
  "The program: a function that runs the module bodies and main, and returns the status.")

(defvar *sp* 0 "The first free byte of this thread's raz stack.")
(defvar *stack-end* 0 "The end of this thread's raz stack.")

;;; Memory. LD reads a scalar of an access kind (types.lisp, ACCESS-KIND)
;;; at an address, ST writes one.

(defmacro ld (kind addr)
  (let ((sap `(sb-sys:int-sap ,addr)))
    (ecase kind
      (:i8 `(sb-sys:signed-sap-ref-8 ,sap 0))
      (:i16 `(sb-sys:signed-sap-ref-16 ,sap 0))
      (:i32 `(sb-sys:signed-sap-ref-32 ,sap 0))
      (:i64 `(sb-sys:signed-sap-ref-64 ,sap 0))
      (:u8 `(sb-sys:sap-ref-8 ,sap 0))
      (:u16 `(sb-sys:sap-ref-16 ,sap 0))
      (:u32 `(sb-sys:sap-ref-32 ,sap 0))
      (:u64 `(sb-sys:sap-ref-64 ,sap 0))
      (:bool `(/= 0 (sb-sys:sap-ref-8 ,sap 0)))
      (:f32 `(sb-sys:sap-ref-single ,sap 0))
      (:f64 `(sb-sys:sap-ref-double ,sap 0)))))

(defmacro st (kind addr value)
  (if (eq kind :bool)
      `(setf (sb-sys:sap-ref-8 (sb-sys:int-sap ,addr) 0) (if ,value 1 0))
      `(setf (ld ,kind ,addr) ,value)))

(defmacro c-call (name result &rest typed-args)
  "Calls the C function NAME; TYPED-ARGS alternate alien types and values."
  (let ((types (loop for (ty) on typed-args by #'cddr collect ty))
        (vals (loop for (nil v) on typed-args by #'cddr collect v)))
    `(sb-alien:alien-funcall
      (sb-alien:extern-alien ,name (function ,result ,@types)) ,@vals)))

(defun move (dst src n)
  "Copies N bytes from SRC to DST, which may overlap."
  (when (> n 0)
    (c-call "memmove" sb-alien:unsigned-long sb-alien:unsigned-long dst sb-alien:unsigned-long src
            sb-alien:unsigned-long n))
  dst)

(defun zero (dst n)
  (when (> n 0)
    (c-call "memset" sb-alien:unsigned-long sb-alien:unsigned-long dst sb-alien:int 0
            sb-alien:unsigned-long n))
  dst)

(defun bytes-equal (a b n)
  (or (= n 0)
      (= 0 (c-call "memcmp" sb-alien:int sb-alien:unsigned-long a sb-alien:unsigned-long b
                   sb-alien:unsigned-long n))))

(defun slice (addr ptr len)
  "Writes the slice (PTR, LEN) at ADDR, and gives ADDR."
  (st :u64 addr ptr)
  (st :i64 (+ addr 8) len)
  addr)

;;; Frames. ENTER is the first thing a procedure does: its frame is the
;;; SIZE bytes from FP, which must fit the stack, and start at zero.

(define-condition stack-overflow (error) ())

(defun enter (fp size)
  (when (> (+ fp size) *stack-end*)
    ;; stopped at the top of the stack, where there is room to stop
    (error 'stack-overflow))
  (zero fp size))

;;; Stopping (section 10). A failed check, and every fault, comes to
;;; STOP, which hands its message to the library's Rt.stop: it writes it,
;;; runs the procedures registered with Rt.atExit and ends with status 2.

(defvar *stopping* nil)

(defun stop (text)
  (let ((bytes (sb-ext:string-to-octets text :external-format :utf-8)))
    (when *stopping*
      ;; a stop while stopping: say it and end, with no more of the library
      (write-bytes 2 bytes)
      (write-bytes 2 #(10))
      (exit-now 2))
    (let ((*stopping* t)
          (buf (c-call "malloc" sb-alien:unsigned-long sb-alien:unsigned-long (+ 16 (length bytes)))))
      (loop for b across bytes for i from 16 do (st :u8 (+ buf i) b))
      (funcall 'razp::|Rt.stop| (slice buf (+ buf 16) (length bytes))))
    (exit-now 2)))

(defun write-bytes (fd bytes)
  (let ((buf (c-call "malloc" sb-alien:unsigned-long sb-alien:unsigned-long (max 1 (length bytes)))))
    (loop for b across bytes for i from 0 do (st :u8 (+ buf i) b))
    (c-call "write" sb-alien:long sb-alien:int fd sb-alien:unsigned-long buf
            sb-alien:unsigned-long (length bytes))))

(defun exit-now (status)
  "Ends the program at once: C's buffers flushed, then the process."
  (c-call "fflush" sb-alien:int sb-alien:unsigned-long 0)
  (c-call "_exit" sb-alien:void sb-alien:int (logand status #xFF)))

;;; The checks of section 6.5, and those of division (6.1). WHERE is the
;;; place, "file:line:col".

(defun check-index (i n where)
  (if (and (<= 0 i) (< i n))
      i
      (stop (format nil "~a: index ~d is out of range for a length of ~d" where i n))))

(defun check-slice (lo hi n where)
  (cond ((< lo 0) (stop (format nil "~a: slice bound ~d is below 0" where lo)))
        ((< hi lo) (stop (format nil "~a: slice [~d..~d] runs backwards" where lo hi)))
        ((and n (> hi n)) (stop (format nil "~a: slice bound ~d is beyond the length ~d" where hi n)))
        (t lo)))

(defun check-copy (ls ld where)
  (when (> ls ld)
    (stop (format nil "~a: COPY of ~d elements into ~d" where ls ld))))

(defun check-enum (i n where)
  (if (and (<= 0 i) (< i n))
      i
      (stop (format nil "~a: ~d is no position of the enumeration, which has ~d names" where i n))))

(defun divide (a b bits signed where mod)
  "A div B, or A mod B with MOD, of a BITS-wide integer type."
  (cond ((= b 0) (stop (format nil "~a: a division by zero" where)))
        ((and signed (= b -1) (= a (- (expt 2 (1- bits)))))
         (stop (format nil "~a: a division of the smallest ~d-bit integer by -1" where bits)))
        (mod (rem a b))
        (t (values (truncate a b)))))

;;; Conversions (6.7) that are more than a Lisp function.

(defun real-to-int (x bits signed)
  "Rounded toward zero; a NaN or a value out of I64's range is the smallest I64, then cut."
  (let ((i (if (and (= x x) (>= x -9223372036854775808d0) (< x 9223372036854775808d0))
               (truncate x)
               (- (expt 2 63)))))
    (if signed (sb-c::mask-signed-field bits i) (ldb (byte bits 0) i))))

;;; Procedure values.

(defun proc-fn (h)
  "The function of procedure value H; nil stops the program."
  (if (and (< 0 h) (< h (length *procs*)))
      (svref *procs* h)
      (stop (if (= h 0) "a call of a nil procedure" "a call of a bad procedure value"))))

;;; Procedures given to C: a C function for each, made once.

(sb-ext:defglobal *callbacks* (make-hash-table) "Procedure value -> the address of its C function.")
(sb-ext:defglobal *callbacks-lock* (sb-thread:make-mutex) "")

(defun c-callback (h make)
  (if (= h 0)
      0
      (sb-thread:with-mutex (*callbacks-lock*)
        (or (gethash h *callbacks*)
            (setf (gethash h *callbacks*) (sb-sys:sap-int (funcall make (proc-fn h))))))))

(defmacro in-raz-thread (&body body)
  "BODY, on a raz stack: a thread C started has none until it calls raz."
  `(flet ((run () ,@body))
     (if (= *stack-end* 0) (with-raz-thread (run)) (run))))

;;; The atomic built-ins (6.8), on INT, UINT and pointers. A CAS on a
;;; word is the one the machine has; XCHG and XADD loop on it.

(defun cas (addr old new signed)
  (declare (type (unsigned-byte 64) addr))
  (if signed
      (let ((old old) (new new))
        (declare (type (signed-byte 64) old new))
        (= old (sb-ext:cas (sb-sys:signed-sap-ref-64 (sb-sys:int-sap addr) 0) old new)))
      (let ((old old) (new new))
        (declare (type (unsigned-byte 64) old new))
        (= old (sb-ext:cas (sb-sys:sap-ref-64 (sb-sys:int-sap addr) 0) old new)))))

(defun xchg (addr x signed)
  (loop (let ((old (if signed (ld :i64 addr) (ld :u64 addr))))
          (when (cas addr old x signed) (return old)))))

(defun xadd (addr x signed)
  (loop (let* ((old (if signed (ld :i64 addr) (ld :u64 addr)))
               (new (if signed (sb-c::mask-signed-field 64 (+ old x)) (ldb (byte 64 0) (+ old x)))))
          (when (cas addr old new signed) (return old)))))

;;; SYSCALL, through the C library's syscall(), which gives -1 and errno
;;; where Linux gives minus the errno.

(defun syscall (n &optional (a 0) (b 0) (c 0) (d 0) (e 0) (f 0))
  (flet ((w (x) (ldb (byte 64 0) x)))
    (let ((r (c-call "syscall" sb-alien:long sb-alien:long n
                     sb-alien:unsigned-long (w a) sb-alien:unsigned-long (w b)
                     sb-alien:unsigned-long (w c) sb-alien:unsigned-long (w d)
                     sb-alien:unsigned-long (w e) sb-alien:unsigned-long (w f))))
      (if (= r -1) (- (sb-alien:get-errno)) r))))

;;; The command line: C's own argv, which SBCL's run time keeps.

(defun argv () (ld :u64 (sb-sys:find-foreign-symbol-address "posix_argv")))

(defun argc ()
  (loop with a = (argv) for i from 0 while (/= 0 (ld :u64 (+ a (* 8 i)))) finally (return i)))

;;; Raz stacks: memory mapped for each thread, not reserved, so that it
;;; costs only what it uses.

(defconstant +stack-size+ (* 256 1024 1024))

(defun map-memory (size &optional (at 0))
  ;; mmap(at, size, read|write, private|anonymous|noreserve, and
  ;; fixed_noreplace if AT is given)
  (let ((r (syscall 9 at size 3 (logior #x22 #x4000 (if (= at 0) 0 #x100000)) -1 0)))
    (when (or (< r 0) (and (/= at 0) (/= r at)))
      (write-bytes 2 (sb-ext:string-to-octets (format nil "can't map ~d bytes of memory~%" size)))
      (exit-now 2))
    r))

(defmacro with-raz-thread (&body body)
  "Runs BODY on a raz stack of its own, with the reals' traps off (6.3)."
  `(let* ((*sp* (map-memory +stack-size+))
          (*stack-end* (+ *sp* +stack-size+)))
     (sb-int:with-float-traps-masked (:overflow :invalid :inexact :divide-by-zero :underflow)
       (catching-faults ,@body))))

(defun raz-frames ()
  "The names of the raz procedures under way, the innermost first."
  (let ((names '()))
    (sb-debug:map-backtrace
     (lambda (frame)
       (let ((name (sb-di:debug-fun-name (sb-di:frame-debug-fun frame))))
         (when (and (symbolp name) (eq (symbol-package name) (find-package :razp)))
           (push (symbol-name name) names)))))
    (nreverse names)))

(defun trace-calls ()
  "Rt.trace: the calls under way, on standard error."
  (dolist (name (raz-frames))
    (write-bytes 2 (sb-ext:string-to-octets (format nil "  in ~a~%" name)))))

(defmacro catching-faults (&body body)
  "BODY, where a bad address or an exhausted stack stops the program,
from the bottom of the raz stack, where there is room to stop."
  `(let ((where nil) (base *sp*))
     (handler-case
         (handler-bind ((sb-sys:memory-fault-error
                          (lambda (c) (declare (ignore c)) (setf where (first (raz-frames))))))
           ,@body)
       (sb-sys:memory-fault-error (c)
         (setf *sp* base)
         (stop (format nil "in ~a: a nil pointer or a bad address (0x~(~x~))" where
                       (fault-address c))))
       ((or storage-condition stack-overflow) () (setf *sp* base) (stop "a stack overflow")))))

(defun fault-address (c)
  (let ((a (ignore-errors (slot-value c 'sb-kernel::address))))
    (if (integerp a) a 0)))

;;; Threads (the library's Thread): each a Lisp thread on a raz stack of
;;; its own. A thread is known to raz code by a number.

(sb-ext:defglobal *threads* (make-hash-table) "")
(sb-ext:defglobal *thread-count* 0 "")
(sb-ext:defglobal *threads-lock* (sb-thread:make-mutex) "")

(defun thread-spawn (proc arg)
  (let ((fn (proc-fn proc)))
    (sb-thread:with-mutex (*threads-lock*)
      (let ((id (incf *thread-count*)))
        (setf (gethash id *threads*)
              (sb-thread:make-thread (lambda () (with-raz-thread (funcall fn arg)))))
        id))))

(defun thread-join (id)
  (let ((th (sb-thread:with-mutex (*threads-lock*) (gethash id *threads*))))
    (when th
      (sb-thread:join-thread th :default nil)
      (sb-thread:with-mutex (*threads-lock*) (remhash id *threads*)))))

;;; Signals, for the library's Sys.catch and Sys.ignore: SBCL's run time
;;; handles each signal caught, writing its number to a pipe.

(sb-ext:defglobal *signal-pipe* nil "The fds of the pipe, read and write, once made.")

(defun catch-signal (sig)
  (unless *signal-pipe*
    (let ((buf (c-call "malloc" sb-alien:unsigned-long sb-alien:unsigned-long 8)))
      ;; pipe2(buf, O_CLOEXEC | O_NONBLOCK)
      (syscall 293 buf (logior #x80000 #x800))
      (setf *signal-pipe* (cons (ld :i32 buf) (ld :i32 (+ buf 4))))))
  (let ((w (cdr *signal-pipe*)))
    (sb-sys:enable-interrupt sig (lambda (&rest args)
                                   (declare (ignore args))
                                   (let ((b (c-call "malloc" sb-alien:unsigned-long sb-alien:unsigned-long 1)))
                                     (st :u8 b sig)
                                     (syscall 1 w b 1)
                                     (c-call "free" sb-alien:void sb-alien:unsigned-long b)))))
  (car *signal-pipe*))

(defun ignore-signal (sig yes)
  (sb-sys:enable-interrupt sig (if yes :ignore :default)))

;;; The start. The saved program begins here: the data block mapped and
;;; filled, then the program run on the main thread's raz stack, and its
;;; status given to Rt.exit.

(defun start ()
  ;; the signals SBCL handles for itself do what they do in any program
  (dolist (sig '(1 2 3 13 15)) (sb-sys:enable-interrupt sig :default))
  (let ((size (length *data-image*)))
    (when (> size 0)
      (map-memory (round-up size 4096) +data-base+)
      (sb-sys:with-pinned-objects (*data-image*)
        (move +data-base+ (sb-sys:sap-int (sb-sys:vector-sap *data-image*)) size))))
  (with-raz-thread
    (let ((status (funcall *main*)))
      (funcall 'razp::|Rt.exit| status)))
  (exit-now 0))
