/* config.h.  Generated from config.h.in by configure.  */
/* config.h.in.  Generated from configure.in by autoheader.  */
/* Whether to use crypted passwords */
/* #undef USE_CRYPT */

/* Whether to use tcp_wrappers */
/* #undef HAVE_LIBWRAP */

/* User want readline */
/* #undef HAVE_LIBREADLINE */

/* Some systems have sys/syslog.h */
/* #undef NEED_SYS_SYSLOG_H */

/* Any threads around? */
#define HAVE_PTHREAD_H 1

/* Some systems don't have assert.h */
#define HAVE_ASSERT_H 1

/* Or here? */
/* #undef HAVE_PTHREAD_NP_H */

/* We might be the silly hpux */
/* #undef hpux */

/* Are we sysv? */
/* #undef SYSV */

/* Fucked up IRIX */
/* #undef IRIX */

/* Or svr4 perhaps? */
/* #undef SVR4 */

/* Some kind of Linux */
#define LINUX 1

/* Or perhaps some bsd variant? */
/* #undef __SOMEBSD__ */

/* UNIX98 and others want socklen_t */
#define HAVE_SOCKLEN_T 1

/* The complete version of ntripcaster */
#define VERSION "0.1.5"

/* Definately Solaris */
/* #undef SOLARIS */

/* directories that we use... blah blah blah */
/* #undef ICECAST_ETCDIR */
/* #undef ICECAST_LOGDIR */
/* #undef ICECAST_TEMPLATEDIR */

/* What the hell is this? */
#define PACKAGE "ntripcaster"

/* DAMN I HATE HATE HATE AUTOCONF */
#define HAVE_SOCKET 1
#define HAVE_CONNECT 1
#define HAVE_GETHOSTBYNAME 1
#define HAVE_NANOSLEEP 1
/* #undef HAVE_YP_GET_DEFAULT_DOMAIN */

/* Define to 1 if you have the <assert.h> header file. */
#define HAVE_ASSERT_H 1

/* Define to 1 if you have the 'basename' function. */
#define HAVE_BASENAME 1

/* Define to 1 if you have the 'connect' function. */
#define HAVE_CONNECT 1

/* Define to 1 if you have the <dirent.h> header file, and it defines 'DIR'.
   */
#define HAVE_DIRENT_H 1

/* Define to 1 if you don't have 'vprintf' but do have '_doprnt.' */
/* #undef HAVE_DOPRNT */

/* Define to 1 if you have the <fcntl.h> header file. */
#define HAVE_FCNTL_H 1

/* Define to 1 if you have the 'gethostbyaddr_r' function. */
#define HAVE_GETHOSTBYADDR_R 1

/* Define to 1 if you have the 'gethostbyname' function. */
#define HAVE_GETHOSTBYNAME 1

/* Define to 1 if you have the 'gethostbyname_r' function. */
#define HAVE_GETHOSTBYNAME_R 1

/* Define to 1 if you have the 'getrlimit' function. */
#define HAVE_GETRLIMIT 1

/* Define to 1 if you have the 'gettimeofday' function. */
#define HAVE_GETTIMEOFDAY 1

/* Define to 1 if you have the <history.h> header file. */
/* #undef HAVE_HISTORY_H */

/* Define to 1 if you have the 'inet_addr' function. */
#define HAVE_INET_ADDR 1

/* Define to 1 if you have the 'inet_aton' function. */
#define HAVE_INET_ATON 1

/* Define to 1 if you have the 'inet_ntoa' function. */
#define HAVE_INET_NTOA 1

/* Define to 1 if you have the <inttypes.h> header file. */
#define HAVE_INTTYPES_H 1

/* Define to 1 if you have the 'dl' library (-ldl). */
/* #undef HAVE_LIBDL */

/* Define to 1 if you have the 'readline' library (-lreadline). */
/* #undef HAVE_LIBREADLINE */

/* Define to 1 if you have the 'localtime_r' function. */
#define HAVE_LOCALTIME_R 1

/* Define to 1 if you have the 'log' function. */
#define HAVE_LOG 1

/* Define to 1 if you have the 'lseek' function. */
#define HAVE_LSEEK 1

/* Define to 1 if you have the <machine/soundcard.h> header file. */
/* #undef HAVE_MACHINE_SOUNDCARD_H */

/* Define to 1 if you have the 'mallinfo' function. */
/* #undef HAVE_MALLINFO */

/* Define to 1 if you have the <malloc.h> header file. */
#define HAVE_MALLOC_H 1

/* Define to 1 if you have the <math.h> header file. */
#define HAVE_MATH_H 1

/* Define to 1 if you have the 'mcheck' function. */
/* #undef HAVE_MCHECK */

/* Define to 1 if you have the <mcheck.h> header file. */
/* #undef HAVE_MCHECK_H */

/* Define to 1 if you have the 'mtrace' function. */
/* #undef HAVE_MTRACE */

/* Define to 1 if you have the 'nanosleep' function. */
#define HAVE_NANOSLEEP 1

/* Define to 1 if you have the <ndir.h> header file, and it defines 'DIR'. */
/* #undef HAVE_NDIR_H */

/* Define to 1 if you have the 'pthread_attr_setstacksize' function. */
#define HAVE_PTHREAD_ATTR_SETSTACKSIZE 1

/* Define to 1 if you have the 'pthread_create' function. */
/* #undef HAVE_PTHREAD_CREATE */

/* Define to 1 if you have the <pthread.h> header file. */
#define HAVE_PTHREAD_H 1

/* Define to 1 if you have the 'pthread_sigmask' function. */
#define HAVE_PTHREAD_SIGMASK 1

/* Define to 1 if you have the <Python.h> header file. */
/* #undef HAVE_PYTHON_H */

/* Define to 1 if you have the 'rename' function. */
#define HAVE_RENAME 1

/* Define to 1 if you have the 'select' function. */
#define HAVE_SELECT 1

/* Define to 1 if you have the 'setpgid' function. */
#define HAVE_SETPGID 1

/* Define to 1 if you have the 'setrlimit' function. */
#define HAVE_SETRLIMIT 1

/* Define to 1 if you have the 'setsockopt' function. */
#define HAVE_SETSOCKOPT 1

/* Define to 1 if you have the 'sigaction' function. */
#define HAVE_SIGACTION 1

/* Define to 1 if you have the <signal.h> header file. */
#define HAVE_SIGNAL_H 1

/* Define to 1 if you have the 'snprintf' function. */
#define HAVE_SNPRINTF 1

/* Define to 1 if you have the 'socket' function. */
#define HAVE_SOCKET 1

/* Define if socklen_t is available */
#define HAVE_SOCKLEN_T 1

/* Define to 1 if you have the <stdint.h> header file. */
#define HAVE_STDINT_H 1

/* Define to 1 if you have the <stdio.h> header file. */
#define HAVE_STDIO_H 1

/* Define to 1 if you have the <stdlib.h> header file. */
#define HAVE_STDLIB_H 1

/* Define to 1 if you have the <strings.h> header file. */
#define HAVE_STRINGS_H 1

/* Define to 1 if you have the <string.h> header file. */
#define HAVE_STRING_H 1

/* Define to 1 if you have the 'strstr' function. */
#define HAVE_STRSTR 1

/* Define to 1 if you have the <sys/dir.h> header file, and it defines 'DIR'.
   */
/* #undef HAVE_SYS_DIR_H */

/* Define to 1 if you have the <sys/ndir.h> header file, and it defines 'DIR'.
   */
/* #undef HAVE_SYS_NDIR_H */

/* Define to 1 if you have the <sys/resource.h> header file. */
#define HAVE_SYS_RESOURCE_H 1

/* Define to 1 if you have the <sys/signal.h> header file. */
#define HAVE_SYS_SIGNAL_H 1

/* Define to 1 if you have the <sys/soundcard.h> header file. */
/* #undef HAVE_SYS_SOUNDCARD_H */

/* Define to 1 if you have the <sys/stat.h> header file. */
#define HAVE_SYS_STAT_H 1

/* Define to 1 if you have the <sys/time.h> header file. */
#define HAVE_SYS_TIME_H 1

/* Define to 1 if you have the <sys/types.h> header file. */
#define HAVE_SYS_TYPES_H 1

/* Define to 1 if you have <sys/wait.h> that is POSIX.1 compatible. */
#define HAVE_SYS_WAIT_H 1

/* Define to 1 if you have the 'umask' function. */
#define HAVE_UMASK 1

/* Define to 1 if you have the <unistd.h> header file. */
#define HAVE_UNISTD_H 1

/* Define to 1 if you have the 'vprintf' function. */
#define HAVE_VPRINTF 1

/* Define to 1 if you have the 'vsnprintf' function. */
#define HAVE_VSNPRINTF 1

/* Define to 1 if you have the 'yp_get_default_domain' function. */
/* #undef HAVE_YP_GET_DEFAULT_DOMAIN */

/* Define if sys/syslog.h is needed */
/* #undef NEED_SYS_SYSLOG_H */

/* Relative path from install prefix to config directory */
#define NTRIPCASTER_ETCDIR "conf"

/* Relative path from install prefix to log directory */
#define NTRIPCASTER_LOGDIR "logs"

/* Name of package */
#define PACKAGE "ntripcaster"

/* Define to the address where bug reports for this package should be sent. */
#define PACKAGE_BUGREPORT ""

/* Define to the full name of this package. */
#define PACKAGE_NAME "ntripcaster"

/* Define to the full name and version of this package. */
#define PACKAGE_STRING "ntripcaster 0.1.5"

/* Define to the one symbol short name of this package. */
#define PACKAGE_TARNAME "ntripcaster"

/* Define to the home page for this package. */
#define PACKAGE_URL ""

/* Define to the version of this package. */
#define PACKAGE_VERSION "0.1.5"

/* Return type of signal handlers */
#define RETSIGTYPE void

/* Define to 1 if all of the C89 standard headers exist (not just the ones
   required in a freestanding environment). This macro is provided for
   backward compatibility; new code need not use it. */
#define STDC_HEADERS 1

/* Define to 1 if you can safely include both <sys/time.h> and <time.h>. This
   macro is obsolete. */
#define TIME_WITH_SYS_TIME 1

/* Define to 1 if your <sys/time.h> declares 'struct tm'. */
/* #undef TM_IN_SYS_TIME */

/* Package version string */
#define VERSION "0.1.5"

/* Define to empty if 'const' does not conform to ANSI C. */
/* #undef const */

/* Define as a signed integer type capable of holding a process identifier. */
/* #undef pid_t */

/* Define as 'unsigned int' if <stddef.h> doesn't define. */
/* #undef size_t */
