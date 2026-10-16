/* cabi: writes lib/CAbi.OS-ARCH.raz, what the C library it is compiled
   against fixes for Sys over C (lib/Sys.raz): the numbers of flags,
   requests, signals, limits and errnos, where the fields Sys reads and
   writes lie in the C library's structs, and the two procedures whose
   names differ between systems. Nothing in that file is typed by hand:
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

   Leaves out: systems but Linux, for errno and closeFrom; a port adds
   them where the #error is. */
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
           "   its errnos beside Linux's, and errno and closeFrom.\n\n"
           "   Written by tools/cabi.c, from the system's own headers; not to be\n"
           "   edited, but written again. *)\n", target);
    printf("module CAbi;\n\nconst\n");

    SAY("open's flags, fcntl's requests, seek, flock, mmap, access");
    K("oRdonly", O_RDONLY); K("oWronly", O_WRONLY); K("oRdwr", O_RDWR);
    K("oCreat", O_CREAT); K("oExcl", O_EXCL); K("oTrunc", O_TRUNC);
    K("oAppend", O_APPEND); K("oNonblock", O_NONBLOCK);
    K("oCloexec", O_CLOEXEC); K("oNoctty", O_NOCTTY);
    K("fGetfd", F_GETFD); K("fSetfd", F_SETFD); K("fGetfl", F_GETFL);
    K("fSetfl", F_SETFL); K("fDupfdCloexec", F_DUPFD_CLOEXEC);
    K("fdCloexec", FD_CLOEXEC);
    K("seekSet", SEEK_SET); K("seekCur", SEEK_CUR); K("seekEnd", SEEK_END);
    K("lockEx", LOCK_EX); K("lockNb", LOCK_NB);
    K("protRead", PROT_READ); K("protWrite", PROT_WRITE);
    K("mapShared", MAP_SHARED); K("mapPrivate", MAP_PRIVATE);
    K("mapAnonymous", MAP_ANONYMOUS); K("mfdCloexec", MFD_CLOEXEC);
    K("fOk", F_OK); K("rOk", R_OK); K("wOk", W_OK); K("xOk", X_OK);

    SAY("struct stat, statvfs and dirent");
    K("statLen", sizeof(struct stat));
    READ("stDev", struct stat, st_dev); READ("stIno", struct stat, st_ino);
    READ("stNlink", struct stat, st_nlink); READ("stMode", struct stat, st_mode);
    READ("stSize", struct stat, st_size);
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
    K("pollin", POLLIN); K("pollout", POLLOUT);
    K("clockRealtime", CLOCK_REALTIME); K("clockMonotonic", CLOCK_MONOTONIC);
    K("timerAbstime", TIMER_ABSTIME);

    SAY("sockets, their addresses, and a message with fds");
    K("afUnix", AF_UNIX); K("afInet", AF_INET); K("afInet6", AF_INET6);
    K("sockStream", SOCK_STREAM); K("sockDgram", SOCK_DGRAM);
    K("sockCloexec", SOCK_CLOEXEC); K("sockNonblock", SOCK_NONBLOCK);
    K("solSocket", SOL_SOCKET); K("soReuseaddr", SO_REUSEADDR);
    K("soError", SO_ERROR); K("msgNosignal", MSG_NOSIGNAL);
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
    K("sockaddrInLen", sizeof(struct sockaddr_in));
    AT("sinPort", struct sockaddr_in, sin_port);
    AT("sinAddr", struct sockaddr_in, sin_addr);
    K("sockaddrIn6Len", sizeof(struct sockaddr_in6));
    AT("sin6Port", struct sockaddr_in6, sin6_port);
    AT("sin6Addr", struct sockaddr_in6, sin6_addr);
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
           "extern proc syscall(n: INT; ...): INT;\n\n"
           "(* errno, this thread's *)\n"
           "proc errno*: ^I32;\n"
           "begin\n"
           "    return __errno_location();\n"
           "end;\n\n"
           "(* Closes the fds from lo to hi, or every one from lo if hi < 0: by\n"
           "   close_range's system call, since musl has no close_range. *)\n"
           "proc closeFrom*(lo, hi: INT);\n"
           "begin\n"
           "    if hi < 0 then hi := 0FFFFFFFFH; end;\n"
           "    _ := syscall(436, lo, hi, 0);\n"
           "end;\n\n");
#else
#error "a CAbi for this system needs its errno and closeFrom: add them here"
#endif
    printf("end CAbi.\n");
    return 0;
}
