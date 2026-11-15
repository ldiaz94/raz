/* cabi: writes lib/CAbi.OS-ARCH.raz, what the C library it is compiled
   against fixes for Sys over C (lib/Sys.raz): the numbers of flags,
   requests, signals, limits and errnos, where the fields Sys reads and
   writes lie in the C library's structs, and the procedures that differ
   between systems: errno and closeFrom, and the calls Linux has and
   another system makes otherwise (makePipe, accepted, random, memFile,
   sleepUntil, processors, peer and sendNow). Nothing in that file is typed by hand:
   it is all this program's output, from the system's own headers.

       cc -o build/cabi tools/cabi.c && build/cabi linux-x86_64 > lib/CAbi.linux-x86_64.raz

   make check compiles it with cc, and with musl-gcc where that is
   installed, and compares what each writes with lib/'s file, so that
   one file is known to serve glibc and musl alike.

   A field's place is its offset, ...At, and its width, ...Len: the
   field's own size for one Sys reads; for one it writes, the room up
   to the next field, so that a C library that keeps an int and a pad
   where another keeps a size_t gives the same file. Linux's errnos,
   which Sys gives on every system, are in the table below, and the
   file pairs each with the C library's own; on Linux,
   each is checked against the headers before anything is written.

   What a system hasn't, Linux's alone, is given a value that keeps Sys
   over C compiling there, and that it must not count on: a flag 0, no
   flag; an option -1, as saLenAt is -1 where a sockaddr has no sa_len.
   On macOS (darwin-arm64), st_mtim is st_mtimespec, a peer's
   credentials are struct xucred, which has no pid (0 bytes at 0), and
   the procedures are its own: no pipe2, accept4 or SOCK_CLOEXEC, so
   fcntl after; getentropy for getrandom; a shared memory object for
   memfd_create; nanosleep for clock_nanosleep; sysconf for
   sched_getaffinity; LOCAL_PEERCRED and LOCAL_PEERPID for SO_PEERCRED;
   and a socket made nonblocking for a send, whose MSG_DONTWAIT macOS
   doesn't keep on a Unix socket.

       cc -o build/cabi tools/cabi.c && build/cabi darwin-arm64 > lib/CAbi.darwin-arm64.raz

   Leaves out: systems but Linux and macOS, for the procedures; a
   port adds them where the #error is. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0
#endif
#ifndef TIMER_ABSTIME
#define TIMER_ABSTIME 0
#endif
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif
#ifndef SOCK_NONBLOCK
#define SOCK_NONBLOCK 0
#endif
#ifndef MSG_CMSG_CLOEXEC
#define MSG_CMSG_CLOEXEC 0
#endif
#ifndef SO_PEERCRED
#define SO_PEERCRED -1
#endif
#ifdef __APPLE__
#include <sys/ucred.h>
#define st_mtim st_mtimespec
#define CMSG_ALIGN(n) __DARWIN_ALIGN32(n)
#endif

/* Sys keeps a terminal's modes in 256 bytes, and struct rusage, whose
   size C libraries differ in, in 512 */
_Static_assert(sizeof(struct termios) <= 256, "struct termios is larger than Sys.Mode");
_Static_assert(sizeof(struct rusage) <= 512, "struct rusage is larger than Sys keeps");

#define K(name, value) printf("    %s* = %lld;\n", name, (long long)(value))
#define AT(name, type, field) K(name "At", offsetof(type, field))
#define READ(name, type, field) \
    (AT(name, type, field), K(name "Len", sizeof(((type *)0)->field)))
#define WRITE(name, type, field, next) \
    (AT(name, type, field), K(name "Len", offsetof(type, next) - offsetof(type, field)))
#define LAST(name, type, field) \
    (AT(name, type, field), K(name "Len", sizeof(type) - offsetof(type, field)))
#define SAY(s) printf("    (* %s *)\n", s)

/* the errnos POSIX names, with their numbers on Linux */
static const struct { const char *name; int here, onLinux; } errnos[] = {
#define E(name, onLinux) {#name, name, onLinux}
    E(EPERM, 1), E(ENOENT, 2), E(ESRCH, 3), E(EINTR, 4), E(EIO, 5),
    E(ENXIO, 6), E(E2BIG, 7), E(ENOEXEC, 8), E(EBADF, 9), E(ECHILD, 10),
    E(EAGAIN, 11), E(ENOMEM, 12), E(EACCES, 13), E(EFAULT, 14),
    E(EBUSY, 16), E(EEXIST, 17), E(EXDEV, 18), E(ENODEV, 19),
    E(ENOTDIR, 20), E(EISDIR, 21), E(EINVAL, 22), E(ENFILE, 23),
    E(EMFILE, 24), E(ENOTTY, 25), E(ETXTBSY, 26), E(EFBIG, 27),
    E(ENOSPC, 28), E(ESPIPE, 29), E(EROFS, 30), E(EMLINK, 31),
    E(EPIPE, 32), E(EDOM, 33), E(ERANGE, 34), E(EDEADLK, 35),
    E(ENAMETOOLONG, 36), E(ENOLCK, 37), E(ENOSYS, 38), E(ENOTEMPTY, 39),
    E(ELOOP, 40), E(ENOMSG, 42), E(EIDRM, 43), E(ENOLINK, 67),
    E(EPROTO, 71), E(EMULTIHOP, 72), E(EBADMSG, 74), E(EOVERFLOW, 75),
    E(EILSEQ, 84), E(ENOTSOCK, 88), E(EDESTADDRREQ, 89), E(EMSGSIZE, 90),
    E(EPROTOTYPE, 91), E(ENOPROTOOPT, 92), E(EPROTONOSUPPORT, 93),
    E(ENOTSUP, 95), E(EOPNOTSUPP, 95), E(EAFNOSUPPORT, 97),
    E(EADDRINUSE, 98), E(EADDRNOTAVAIL, 99), E(ENETDOWN, 100),
    E(ENETUNREACH, 101), E(ENETRESET, 102), E(ECONNABORTED, 103),
    E(ECONNRESET, 104), E(ENOBUFS, 105), E(EISCONN, 106),
    E(ENOTCONN, 107), E(ETIMEDOUT, 110), E(ECONNREFUSED, 111),
    E(EHOSTUNREACH, 113), E(EALREADY, 114), E(EINPROGRESS, 115),
    E(ESTALE, 116), E(EDQUOT, 122), E(ECANCELED, 125),
    E(EOWNERDEAD, 130), E(ENOTRECOVERABLE, 131),
#undef E
};

int main(int argc, char **argv) {
    const char *target = argc > 1 ? argv[1] : "linux-x86_64";
    int i, n;

#ifdef __linux__
    for (i = 0; i < (int)(sizeof errnos / sizeof errnos[0]); i++)
        if (errnos[i].here != errnos[i].onLinux) {
            fprintf(stderr, "cabi: %s is %d here, not Linux's %d\n",
                errnos[i].name, errnos[i].here, errnos[i].onLinux);
            return 1;
        }
#endif
    printf("(* CAbi: what the C library fixes for Sys over C on %s: the\n"
           "   numbers of its flags, requests, signals and limits, where the\n"
           "   fields of its structs lie, an At the offset and a Len the width,\n"
           "   its errnos beside Linux's, and the procedures that differ.\n\n"
           "   Written by tools/cabi.c, from the system's own headers; not to be\n"
           "   edited, but written again. *)\n", target);
    printf("module CAbi;\nimport SYSTEM;\n\nconst\n");

    SAY("open's flags, fcntl's requests, seek, flock, mmap, access");
    K("oRdonly", O_RDONLY); K("oWronly", O_WRONLY); K("oRdwr", O_RDWR);
    K("oCreat", O_CREAT); K("oExcl", O_EXCL); K("oTrunc", O_TRUNC);
    K("oAppend", O_APPEND); K("oNonblock", O_NONBLOCK);
    K("oCloexec", O_CLOEXEC); K("oNoctty", O_NOCTTY);
    K("fGetfd", F_GETFD); K("fSetfd", F_SETFD); K("fGetfl", F_GETFL);
    K("fSetfl", F_SETFL); K("fDupfdCloexec", F_DUPFD_CLOEXEC);
    K("fdCloexec", FD_CLOEXEC);
    K("seekSet", SEEK_SET); K("seekCur", SEEK_CUR); K("seekEnd", SEEK_END);
    K("lockEx", LOCK_EX); K("lockSh", LOCK_SH); K("lockNb", LOCK_NB);
    K("protRead", PROT_READ); K("protWrite", PROT_WRITE);
    K("mapShared", MAP_SHARED); K("mapPrivate", MAP_PRIVATE);
    K("mapAnonymous", MAP_ANONYMOUS); K("mfdCloexec", MFD_CLOEXEC);
    K("atFdcwd", AT_FDCWD);
    K("fOk", F_OK); K("rOk", R_OK); K("wOk", W_OK); K("xOk", X_OK);

    SAY("struct stat, statvfs and dirent");
    K("statLen", sizeof(struct stat));
    READ("stDev", struct stat, st_dev); READ("stIno", struct stat, st_ino);
    READ("stNlink", struct stat, st_nlink); READ("stMode", struct stat, st_mode);
    READ("stSize", struct stat, st_size);
    READ("stUid", struct stat, st_uid); READ("stGid", struct stat, st_gid);
    READ("stMtime", struct stat, st_mtim.tv_sec);
    READ("stMtimeNs", struct stat, st_mtim.tv_nsec);
    K("sIfmt", S_IFMT); K("sIfdir", S_IFDIR); K("sIfreg", S_IFREG);
    K("sIflnk", S_IFLNK);
    K("statvfsLen", sizeof(struct statvfs));
    READ("fFrsize", struct statvfs, f_frsize);
    READ("fBlocks", struct statvfs, f_blocks);
    READ("fBavail", struct statvfs, f_bavail);
    AT("dName", struct dirent, d_name); AT("dType", struct dirent, d_type);
    K("dtUnknown", DT_UNKNOWN); K("dtDir", DT_DIR); K("dtReg", DT_REG);
    K("dtLnk", DT_LNK);

    SAY("the terminal, poll and the clocks");
    K("tcsanow", TCSANOW); K("tcsadrain", TCSADRAIN);
    K("tiocgwinsz", TIOCGWINSZ); K("tiocswinsz", TIOCSWINSZ);
    K("tiocsctty", TIOCSCTTY);
#ifdef __APPLE__
    K("ptyHeld", 1);   /* a pseudo-terminal's controlling side works only while its terminal is open */
#else
    K("ptyHeld", 0);
#endif
    K("pollin", POLLIN); K("pollout", POLLOUT);
    K("clockRealtime", CLOCK_REALTIME); K("clockMonotonic", CLOCK_MONOTONIC);
    K("timerAbstime", TIMER_ABSTIME);

    SAY("sockets, their addresses, and a message with fds");
    K("afUnix", AF_UNIX); K("afInet", AF_INET); K("afInet6", AF_INET6);
    K("sockStream", SOCK_STREAM); K("sockDgram", SOCK_DGRAM);
    K("sockCloexec", SOCK_CLOEXEC); K("sockNonblock", SOCK_NONBLOCK);
    K("solSocket", SOL_SOCKET); K("soReuseaddr", SO_REUSEADDR);
    K("soError", SO_ERROR); K("soPeercred", SO_PEERCRED);   /* Linux's */
    K("shutWr", SHUT_WR); K("msgNosignal", MSG_NOSIGNAL);
    K("msgDontwait", MSG_DONTWAIT);
    K("msgCmsgCloexec", MSG_CMSG_CLOEXEC); K("scmRights", SCM_RIGHTS);
    K("sockaddrLen", sizeof(struct sockaddr_storage));
    READ("saFamily", struct sockaddr, sa_family);
#ifdef SIN6_LEN
    AT("saLen", struct sockaddr, sa_len);   /* the BSDs: the address's length first */
#else
    K("saLenAt", -1);
#endif
    K("sockaddrUnLen", sizeof(struct sockaddr_un));
    READ("sunPath", struct sockaddr_un, sun_path);
#ifdef __linux__
    K("unixAbstract", 1);   /* a Unix socket's name may start with a zero: no file */
#else
    K("unixAbstract", 0);
#endif
    K("sockaddrInLen", sizeof(struct sockaddr_in));
    AT("sinPort", struct sockaddr_in, sin_port);
    AT("sinAddr", struct sockaddr_in, sin_addr);
    K("sockaddrIn6Len", sizeof(struct sockaddr_in6));
    AT("sin6Port", struct sockaddr_in6, sin6_port);
    AT("sin6Addr", struct sockaddr_in6, sin6_addr);
#ifdef __linux__
    READ("ucPid", struct ucred, pid); READ("ucUid", struct ucred, uid);
#else
    K("ucPidAt", 0); K("ucPidLen", 0);
    READ("ucUid", struct xucred, cr_uid);
#endif
    K("msghdrLen", sizeof(struct msghdr));
    AT("msgIov", struct msghdr, msg_iov);
    WRITE("msgIovlen", struct msghdr, msg_iovlen, msg_control);
    AT("msgControl", struct msghdr, msg_control);
    WRITE("msgControllen", struct msghdr, msg_controllen, msg_flags);
    WRITE("cmsgLen", struct cmsghdr, cmsg_len, cmsg_level);
    AT("cmsgLevel", struct cmsghdr, cmsg_level);
    AT("cmsgType", struct cmsghdr, cmsg_type);
    K("cmsgDataAt", CMSG_LEN(0));
    K("cmsgAlign", CMSG_ALIGN(1));

    SAY("signals, sigaction and sigprocmask");
    K("sigHup", SIGHUP); K("sigInt", SIGINT); K("sigQuit", SIGQUIT);
    K("sigFpe", SIGFPE); K("sigKill", SIGKILL); K("sigUsr1", SIGUSR1);
    K("sigSegv", SIGSEGV); K("sigUsr2", SIGUSR2); K("sigPipe", SIGPIPE);
    K("sigAlrm", SIGALRM); K("sigTerm", SIGTERM); K("sigChld", SIGCHLD);
    K("sigCont", SIGCONT); K("sigStop", SIGSTOP); K("sigTstp", SIGTSTP);
    K("sigTtin", SIGTTIN); K("sigTtou", SIGTTOU); K("sigWinch", SIGWINCH);
    K("sigMax", NSIG - 1);
    K("sigactionLen", sizeof(struct sigaction));
    AT("saHandler", struct sigaction, sa_handler);
    AT("saMask", struct sigaction, sa_mask);
    READ("saFlags", struct sigaction, sa_flags);
    K("sigsetLen", sizeof(sigset_t));
    K("saRestart", SA_RESTART); K("sigSetmask", SIG_SETMASK);

    SAY("limits, time used, and wait");
    K("rlimitCpu", RLIMIT_CPU); K("rlimitFsize", RLIMIT_FSIZE);
    K("rlimitData", RLIMIT_DATA); K("rlimitStack", RLIMIT_STACK);
    K("rlimitCore", RLIMIT_CORE); K("rlimitNproc", RLIMIT_NPROC);
    K("rlimitNofile", RLIMIT_NOFILE); K("rlimitAs", RLIMIT_AS);
    K("rlimInfinity", RLIM_INFINITY);
    K("rusageSelf", RUSAGE_SELF); K("rusageChildren", RUSAGE_CHILDREN);
    AT("ruUtime", struct rusage, ru_utime); AT("ruStime", struct rusage, ru_stime);
    READ("tvSec", struct timeval, tv_sec); READ("tvUsec", struct timeval, tv_usec);
    K("wNohang", WNOHANG); K("wUntraced", WUNTRACED);

    SAY("errnos: EINTR; and each POSIX names, the C library's number, then Linux's");
    K("eIntr", EINTR);
    n = sizeof errnos / sizeof errnos[0];
    printf("    errnos*: [%d]I32 = [", 2 * n);
    for (i = 0; i < n; i++)
        printf("%s%s%d, %d", i ? "," : "", i % 6 ? " " : "\n        ", errnos[i].here, errnos[i].onLinux);
    printf("];\n\n");

#ifdef __linux__
    printf("extern proc __errno_location: ^I32;\n"
           "extern proc syscall(n: INT; ...): INT;\n"
           "extern proc pipe2(fds: ^I32; flags: I32): I32;\n"
           "extern proc accept4(fd: I32; addr: ^U8; len: ^U32; flags: I32): I32;\n"
           "extern proc getrandom(buf: ^U8; n: UINT; flags: U32): INT;\n"
           "extern proc memfd_create(name: ^U8; flags: U32): I32;\n"
           "extern proc clock_nanosleep(clock, flags: I32; t, left: ^U8): I32;\n"
           "extern proc sched_getaffinity(pid: I32; size: UINT; mask: ^U8): I32;\n"
           "extern proc getsockopt(fd, level, name: I32; value: ^U8; len: ^U32): I32;\n"
           "extern proc send(fd: I32; buf: ^U8; n: UINT; flags: I32): INT;\n"
           "\n"
           "(* errno, this thread's *)\n"
           "proc errno*: ^I32;\n"
           "begin\n"
           "    return __errno_location();\n"
           "end;\n"
           "\n"
           "(* Closes the fds from lo to hi, or every one from lo if hi < 0: by\n"
           "   close_range's system call, since musl has no close_range. *)\n"
           "proc closeFrom*(lo, hi: INT);\n"
           "begin\n"
           "    if hi < 0 then hi := 0FFFFFFFFH; end;\n"
           "    _ := syscall(436, lo, hi, 0);\n"
           "end;\n"
           "\n"
           "(* A pipe, its two fds put at fds, taking flags, oCloexec and\n"
           "   oNonblock, at once: 0, or -1 with errno set, as C's calls are. *)\n"
           "proc makePipe*(fds: ^I32; flags: I32): I32;\n"
           "begin\n"
           "    return pipe2(fds, flags);\n"
           "end;\n"
           "\n"
           "(* The next connection to the socket fd, closed on exec; or -1. *)\n"
           "proc accepted*(fd: I32): I32;\n"
           "begin\n"
           "    return accept4(fd, nil, nil, sockCloexec);\n"
           "end;\n"
           "\n"
           "(* The kernel's random bytes, at most n, put at buf: how many, or -1. *)\n"
           "proc random*(buf: ^U8; n: UINT): INT;\n"
           "begin\n"
           "    return getrandom(buf, n, 0);\n"
           "end;\n"
           "\n"
           "(* A file in memory, of no bytes, with no name, closed on exec: its\n"
           "   fd, or -1. *)\n"
           "proc memFile*: I32;\n"
           "begin\n"
           "    return memfd_create(SYSTEM.PTR(\"raz\\0\"), mfdCloexec);   (* the name /proc shows *)\n"
           "end;\n"
           "\n"
           "(* Waits until t, a struct timespec of the monotonic clock, again\n"
           "   after EINTR. *)\n"
           "proc sleepUntil*(t: ^U8);\n"
           "begin\n"
           "    repeat until clock_nanosleep(clockMonotonic, timerAbstime, t, nil) # eIntr;\n"
           "end;\n"
           "\n"
           "(* The number of processors this program may run on, or 0 if the\n"
           "   system doesn't say. *)\n"
           "proc processors*: INT;\n"
           "var mask: [1024]U8; i, b, count: INT;\n"
           "begin\n"
           "    for i := 0 to LEN(mask) - 1 do mask[i] := 0; end;   (* the C library fills in as many bytes as the system has processors' bits *)\n"
           "    if sched_getaffinity(0, UINT(LEN(mask)), SYSTEM.ADR(mask[0])) # 0 then return 0; end;\n"
           "    count := 0;\n"
           "    for i := 0 to LEN(mask) - 1 do\n"
           "        for b := 0 to 7 do\n"
           "            if (INT(mask[i]) shr b) & 1 = 1 then INC(count); end;\n"
           "        end;\n"
           "    end;\n"
           "    return count;\n"
           "end;\n"
           "\n"
           "(* The process and the user at the other end of the Unix socket fd,\n"
           "   as the system recorded them when it connected, and 0; or -1. *)\n"
           "proc peer*(fd: I32; var pid, uid: INT): I32;\n"
           "var cred: [16]U64; size: U32; p: ^U8; q: ^U32;\n"
           "begin\n"
           "    p := ^U8(SYSTEM.ADR(cred[0]));\n"
           "    size := U32(SIZE([16]U64));\n"
           "    if getsockopt(fd, solSocket, soPeercred, p, SYSTEM.ADR(size)) # 0 then return -1; end;\n"
           "    q := ^U32(p + ucPidAt);\n"
           "    pid := INT(I32(q^));\n"
           "    q := ^U32(p + ucUidAt);\n"
           "    uid := INT(q^);\n"
           "    return 0;\n"
           "end;\n"
           "\n"
           "(* Sends n bytes at buf on the socket fd, without waiting, and without\n"
           "   SIGPIPE where the other end is gone: how many were sent, or -1. *)\n"
           "proc sendNow*(fd: I32; buf: ^U8; n: UINT): INT;\n"
           "begin\n"
           "    return send(fd, buf, n, msgNosignal | msgDontwait);\n"
           "end;\n"
           "\n");
#elif defined(__APPLE__)
    printf("extern proc __error: ^I32;\n"
           "extern proc close(fd: I32): I32;\n"
           "extern proc getdtablesize: I32;\n"
           "extern proc pipe(fds: ^I32): I32;\n"
           "extern proc fcntl(fd, cmd: I32; ...): I32;\n"
           "extern proc accept(fd: I32; addr: ^U8; len: ^U32): I32;\n"
           "extern proc getentropy(buf: ^U8; n: UINT): I32;\n"
           "extern proc getpid: I32;\n"
           "extern proc shm_open(name: ^U8; flags: I32; ...): I32;\n"
           "extern proc shm_unlink(name: ^U8): I32;\n"
           "extern proc clock_gettime(clock: I32; t: ^U8): I32;\n"
           "extern proc nanosleep(t, left: ^U8): I32;\n"
           "extern proc sysconf(name: I32): INT;\n"
           "extern proc getsockopt(fd, level, name: I32; value: ^U8; len: ^U32): I32;\n"
           "extern proc send(fd: I32; buf: ^U8; n: UINT; flags: I32): INT;\n"
           "\n"
           "var shmCount: INT;   (* the shared memory objects memFile has made *)\n"
           "\n"
           "(* errno, this thread's *)\n"
           "proc errno*: ^I32;\n"
           "begin\n"
           "    return __error();\n"
           "end;\n"
           "\n"
           "(* Closes the fds from lo to hi, or every one from lo if hi < 0: one\n"
           "   by one, as macOS has no close_range. *)\n"
           "proc closeFrom*(lo, hi: INT);\n"
           "var fd: INT;\n"
           "begin\n"
           "    if hi < 0 then hi := INT(getdtablesize()) - 1; end;\n"
           "    for fd := lo to hi do _ := close(I32(fd)); end;\n"
           "end;\n"
           "\n"
           "(* fd closed on exec, and nonblocking, as flags, oCloexec and\n"
           "   oNonblock, say: macOS has no flags for them where a pipe or a\n"
           "   socket is made, so another thread's exec in between keeps the fd\n"
           "   open, a gap Linux hasn't. *)\n"
           "proc setFlags(fd, flags: I32);\n"
           "begin\n"
           "    if flags & oCloexec # 0 then _ := fcntl(fd, fSetfd, fdCloexec); end;\n"
           "    if flags & oNonblock # 0 then _ := fcntl(fd, fSetfl, fcntl(fd, fGetfl) | oNonblock); end;\n"
           "end;\n"
           "\n"
           "(* A pipe, its two fds put at fds, taking flags, oCloexec and\n"
           "   oNonblock: 0, or -1 with errno set, as C's calls are. *)\n"
           "proc makePipe*(fds: ^I32; flags: I32): I32;\n"
           "begin\n"
           "    if pipe(fds) # 0 then return -1; end;\n"
           "    setFlags(fds[0], flags);\n"
           "    setFlags(fds[1], flags);\n"
           "    return 0;\n"
           "end;\n"
           "\n"
           "(* The next connection to the socket fd, closed on exec; or -1. *)\n"
           "proc accepted*(fd: I32): I32;\n"
           "var r: I32;\n"
           "begin\n"
           "    r := accept(fd, nil, nil);\n"
           "    if r >= 0 then setFlags(r, oCloexec); end;\n"
           "    return r;\n"
           "end;\n"
           "\n"
           "(* The kernel's random bytes, at most n, put at buf: how many, or -1.\n"
           "   getentropy gives 256 at most at a time. *)\n"
           "proc random*(buf: ^U8; n: UINT): INT;\n"
           "begin\n"
           "    if n > 256 then n := 256; end;\n"
           "    if getentropy(buf, n) # 0 then return -1; end;\n"
           "    return INT(n);\n"
           "end;\n"
           "\n"
           "(* v in hexadecimal into name from i on: where its digits end *)\n"
           "proc hex(var name: [32]U8; i, v: INT): INT;\n"
           "var n, k, d: INT;\n"
           "begin\n"
           "    n := v;\n"
           "    repeat INC(i); n := n shr 4; until n = 0;\n"
           "    k := i;\n"
           "    repeat\n"
           "        DEC(k);\n"
           "        d := v & 15;\n"
           "        if d < 10 then name[k] := U8(d) + '0'; else name[k] := U8(d - 10) + 'a'; end;\n"
           "        v := v shr 4;\n"
           "    until v = 0;\n"
           "    return i;\n"
           "end;\n"
           "\n"
           "(* A file in memory, of no bytes, with no name, closed on exec: its\n"
           "   fd, or -1. macOS has no memfd_create: it is a POSIX shared memory\n"
           "   object, made with a name of its own, /raz.PID.N, which is removed\n"
           "   at once. Such an object can be given its size once, and mapped, but\n"
           "   not read or written. *)\n"
           "proc memFile*: I32;\n"
           "var name: [32]U8; fd: I32; i: INT;\n"
           "begin\n"
           "    COPY(name[0..5], \"/raz.\");\n"
           "    i := hex(name, 5, INT(getpid()));\n"
           "    name[i] := '.';\n"
           "    i := hex(name, i + 1, XADD(shmCount, 1));\n"
           "    name[i] := 0;\n"
           "    fd := shm_open(SYSTEM.ADR(name[0]), oRdwr | oCreat | oExcl, 384);   (* rw------- *)\n"
           "    if fd < 0 then return -1; end;\n"
           "    _ := shm_unlink(SYSTEM.ADR(name[0]));\n"
           "    setFlags(fd, oCloexec);\n"
           "    return fd;\n"
           "end;\n"
           "\n"
           "(* Waits until t, a struct timespec of the monotonic clock: macOS has\n"
           "   no clock_nanosleep, so nanosleep sleeps what is left, again after\n"
           "   EINTR. *)\n"
           "proc sleepUntil*(t: ^U8);\n"
           "var now, left: [2]I64; at: ^I64; d: I64;\n"
           "begin\n"
           "    at := ^I64(t);\n"
           "    repeat\n"
           "        _ := clock_gettime(clockMonotonic, ^U8(SYSTEM.ADR(now[0])));\n"
           "        d := (at[0] - now[0]) * 1000000000 + at[1] - now[1];\n"
           "        if d <= 0 then return; end;\n"
           "        left := [d div 1000000000, d mod 1000000000];\n"
           "        _ := nanosleep(^U8(SYSTEM.ADR(left[0])), nil);\n"
           "    until false;\n"
           "end;\n"
           "\n"
           "(* The number of processors this program may run on, or 0 if the\n"
           "   system doesn't say: those online, as macOS binds a program to none\n"
           "   of them. *)\n"
           "proc processors*: INT;\n"
           "begin\n"
           "    return sysconf(%d);   (* _SC_NPROCESSORS_ONLN *)\n"
           "end;\n"
           "\n"
           "(* The process and the user at the other end of the Unix socket fd,\n"
           "   as the system recorded them when it connected, and 0; or -1. The\n"
           "   user is in a struct xucred, LOCAL_PEERCRED's, and the process is\n"
           "   asked for alone, LOCAL_PEERPID. *)\n"
           "proc peer*(fd: I32; var pid, uid: INT): I32;\n"
           "var cred: [16]U64; size: U32; p: ^U8; q: ^U32; id: I32;\n"
           "begin\n"
           "    p := ^U8(SYSTEM.ADR(cred[0]));\n"
           "    size := U32(SIZE([16]U64));\n"
           "    if getsockopt(fd, %d, %d, p, SYSTEM.ADR(size)) # 0 then return -1; end;\n"
           "    q := ^U32(p + ucUidAt);\n"
           "    uid := INT(q^);\n"
           "    size := 4;\n"
           "    if getsockopt(fd, %d, %d, ^U8(SYSTEM.ADR(id)), SYSTEM.ADR(size)) # 0 then return -1; end;\n"
           "    pid := INT(id);\n"
           "    return 0;\n"
           "end;\n"
           "\n"
           "(* Sends n bytes at buf on the socket fd, without waiting, and without\n"
           "   SIGPIPE where the other end is gone: how many were sent, or -1.\n"
           "   macOS's send waits on a Unix socket though MSG_DONTWAIT is given, so\n"
           "   the socket is made nonblocking for it, as it was before after. *)\n"
           "proc sendNow*(fd: I32; buf: ^U8; n: UINT): INT;\n"
           "var f: I32; r: INT; e: ^I32; err: I32;\n"
           "begin\n"
           "    f := fcntl(fd, fGetfl);\n"
           "    if (f >= 0) and (f & oNonblock = 0) then _ := fcntl(fd, fSetfl, f | oNonblock); end;\n"
           "    r := send(fd, buf, n, msgNosignal | msgDontwait);\n"
           "    e := __error();\n"
           "    err := e^;\n"
           "    if (f >= 0) and (f & oNonblock = 0) then _ := fcntl(fd, fSetfl, f); end;\n"
           "    e^ := err;\n"
           "    return r;\n"
           "end;\n"
           "\n",
           _SC_NPROCESSORS_ONLN, SOL_LOCAL, LOCAL_PEERCRED, SOL_LOCAL, LOCAL_PEERPID);
#else
#error "a CAbi for this system needs its procedures: add them here"
#endif
    printf("end CAbi.\n");
    return 0;
}
