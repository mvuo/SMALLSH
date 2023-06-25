#!/usr/bin/env bash

set +x
set -e
umask 077

trap 'printf "An error occured\n" >&2' ERR
readonly smallsh_exe="$(realpath "${1:-./smallsh}")"
readonly workdir=`mktemp -d -p ~/ smallsh_test.XXXXXX`
export TRACER_SIG_IGN=''

if [ ! -x "$smallsh_exe" ] ||
   [ ! -f "${smallsh_exe}" ]
then
  printf '%s does not appear to be an executable file\n' "${smallsh_exe}"
  printf 'Usage: %s [SMALLSH_PATH]\n' "$0"
  printf 'SMALLSH_PATH defaults to "./smallsh", if not provided\n'
  exit 1
fi

function microsleep() {
   sleep 0.1
}

###############################################################################
#
# Binaries
#
#
make_bin() {
  mkdir -p "${workdir}/src/" "${workdir}/bin" 
  cat >"${workdir}/src/$1.c"
  env -i PATH=`getconf PATH` cc -std=c99 -o "${workdir}/bin/$1" "${workdir}/src/$1.c"
}


make_bin _echo <<'EOF'
#define _POSIX_C_SOURCE 200809
#include <stdio.h>

int main(int argc, char *argv[]) {
  for (int i = 1; i < argc; ++i) printf("%s%c", argv[i], i + 1 < argc ? ' ' : '\n');
}
EOF


make_bin _exit <<'EOF'
#define _POSIX_C_SOURCE 200809
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
  return (argc > 1 ? atoi(argv[1]) : 0); 
}
EOF

make_bin _signal <<'EOF'
#define _POSIX_C_SOURCE 200809
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>

int main(int argc, char *argv[]) {
  kill(getpid(), argc > 1 ? atoi(argv[1]) : 0);
  sigset_t s;
  sigemptyset(&s);
  sigsuspend(&s);
  return 0;
}
EOF

make_bin _suspend <<'EOF'
#define _POSIX_C_SOURCE 200809
#include <signal.h>
#include <stdlib.h>
int main(int argc, char *argv[]) {
  for (int i = 1; i < argc; ++i) {
    signal(atoi(argv[i]), SIG_IGN);
  }
  sigset_t s;
  sigemptyset(&s);
  sigsuspend(&s);
}
EOF

make_bin _signal_disposition <<'EOF'
#define _POSIX_C_SOURCE 200809
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>

typedef void (*sighandler_t)(int);

int main(int argc, char *argv[]) {
  for (int i = 1; i < argc; ++i) {
    int signo = atoi(argv[i]);
    sighandler_t sh = signal(signo, SIG_DFL);
    if (sh == SIG_DFL) printf("SIG_DFL\n");
    else if (sh == SIG_IGN) printf("SIG_IGN\n");
    else printf("UNKNOWN\n");
  }
}
EOF

###############################################################################
#
# Utilities

make_util() {
  mkdir -p "${workdir}/utilsrc/" "${workdir}/util/" 
  cat >"${workdir}/utilsrc/$1.c"
  env -i PATH=`getconf PATH` cc -std=c99 -o "${workdir}/util/$1" "${workdir}/utilsrc/$1.c"
}

make_util head <<'EOF'
#include <stdlib.h>
#include <stdio.h>
int main(int argc, char *argv[])
{ 
  size_t n = argc > 1 ? atoi(argv[1]) * 1024 : BUFSIZ;
  setbuf(stdin, NULL); setbuf(stdout, NULL); 
  for (; n --> 0;) {
    int c = getchar();
    if (c == EOF) {
      if (feof(stdin)) exit(0);
      exit(1);
    }
    putchar(c);  
  }
}
EOF

make_util tracer <<'EOF'
#define _POSIX_C_SOURCE 200809L
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <unistd.h>
#include <wait.h>

#include <linux/ptrace.h> /* Additional ptrace consts; MUST be after sys/ptrace */

static pid_t fork_and_trace(void);
static FILE *open_log(char const *fn);

volatile sig_atomic_t exitnow = 0;

void sh(int sig)
{
  exitnow = 1;
}

int
main(int argc, char *argv[])
{
  for (int i = 0; i < SIGRTMIN; ++i) signal(i, SIG_IGN);
  signal(SIGTERM, sh);
  if (argc < 3) errx(1, "too few arguments");
  pid_t const root = fork_and_trace();
  if (root == 0) {
    for (int i = 0; i < SIGRTMIN; ++i) signal(i, SIG_DFL);
    char const *sigs = getenv("TRACER_SIG_IGN");
    if (sigs) {
      for (;;) {
        char *end;
        long signo = strtol(sigs, &end, 10);
        if (*sigs && end == sigs) err(1, "Invalid signal number: %s", sigs);
        signal(signo, SIG_IGN);
        sigs = end;
        if (!end || *end == '\0') break;
      }
    }
    setpgid(0, 0);
    execvp(argv[3], &argv[3]);
    err(1, "%s", argv[3]);
  }
  close(0);
  FILE *logfile = open_log(argv[1]);
  FILE *diagfile = open_log(argv[2]);
  fprintf(logfile, "ROOT %jd %s\n", (intmax_t)root, argv[3]);
  pid_t descendants[5] = {root};
  size_t n_descendants = 1;
  for (;;) {
    if (exitnow) goto exit;
    int s;
    pid_t tracee_pid = waitpid(-1, &s, __WALL);
    if (tracee_pid <= 0) {
      if (errno == EINTR) {
        errno = 0;
        continue;
      } else if (errno == ECHILD) {
        fprintf(diagfile, "No children\n");
        goto errorexit;
      }
      goto exit;
    }
    if (WIFEXITED(s)) {
      fprintf(logfile, "EXIT %jd %d\n", (intmax_t)tracee_pid, WEXITSTATUS(s));
      if (tracee_pid == root) goto rootexit;
    } else if (WIFSIGNALED(s)) {
      fprintf(logfile, "TERM %jd %d\n", (intmax_t)tracee_pid, WTERMSIG(s));
      if (tracee_pid == root) goto rootexit;
    } else if (WIFSTOPPED(s)) {
      /* Check for a fork */
      if (s >> 8 == (SIGTRAP | (PTRACE_EVENT_CLONE << 8)) ||
          s >> 8 == (SIGTRAP | (PTRACE_EVENT_FORK << 8)) ||
          s >> 8 == (SIGTRAP | (PTRACE_EVENT_VFORK << 8))) {
        unsigned long tracee_child_pid;
        ptrace(PTRACE_GETEVENTMSG, tracee_pid, 0, &tracee_child_pid);
        fprintf(logfile, "FORK %jd %jd\n", (intmax_t)tracee_pid, (intmax_t)tracee_child_pid);
        descendants[n_descendants++] = tracee_child_pid;
        if (n_descendants >= sizeof descendants / sizeof *descendants) {
          fprintf(diagfile, "reached descendant maximum %zu\n",
                  sizeof descendants / sizeof *descendants);
          goto errorexit;
        }
        ptrace(PTRACE_CONT, tracee_pid, 0, 0);
      } else if (s >> 8 == (SIGTRAP | (PTRACE_EVENT_EXEC << 8))) {
        ptrace(PTRACE_CONT, tracee_pid, 0, 0);
      } else if (s >> 8 == (SIGTRAP | (PTRACE_EVENT_EXIT << 8))) {
        size_t i = 0;
        for (; i < n_descendants; ++i) {
          if (tracee_pid == descendants[i]) {
            break;
          }
        }
        if (i == n_descendants) {
          fprintf(diagfile, "untraced descendant %jd exited\n", (intmax_t)tracee_pid);
          goto errorexit;
        }
        --n_descendants;
        memcpy(&descendants[i], &descendants[i + 1], n_descendants - i);
        ptrace(PTRACE_CONT, tracee_pid, 0, 0);
      } else if (s >> 8 == (SIGTRAP | (PTRACE_EVENT_STOP << 8))) {
        ptrace(PTRACE_CONT, tracee_pid, 0, 0);
      } else {
        fprintf(logfile, "SIGNAL %jd %d\n", (intmax_t)tracee_pid, WSTOPSIG(s));
        ptrace(PTRACE_CONT, tracee_pid, 0, WSTOPSIG(s));
      }
    }
  }
errorexit:
  fprintf(logfile, "ERROR\n");
  goto exit;
rootexit:
  fprintf(logfile, "DIE %jd %s\n", (intmax_t)root, argv[3]);
  goto exit;
exit:;
  if (n_descendants) {
    fprintf(diagfile, "Killing %zu leftover processes:\n", n_descendants);
    for (size_t i = 0; i < n_descendants; ++i) {
      fprintf(logfile, "KILLED %jd\n", (intmax_t)descendants[i]);
      fprintf(diagfile, "%jd killed\n", (intmax_t)descendants[i]);
      kill(descendants[i], SIGKILL);
    }
  }
  return 0;
}

static pid_t
fork_and_trace(void)
{
  pid_t pid = fork();
  if (pid < 0) {
    err(1, "fork");
  } else if (pid == 0) {
    raise(SIGSTOP);
    return pid;
  }
  for (;;) {
    pid_t wait_res;
    int status;
    wait_res = waitpid(pid, &status, WUNTRACED);

    if (wait_res <= 0) {
      if (errno == EINTR) {
        errno = 0;
        continue;
      } else {
        err(1, "child lost");
      }
    }

    if (WIFSTOPPED(status)) {
      break;
    } else if (WIFEXITED(status)) {
      errx(1, "child exited %d before it could be traced", WEXITSTATUS(status));
    } else if (WIFSIGNALED(status)) {
      errx(1, "child terminated by signal %d before it could be traced", WTERMSIG(status));
    }
  }
  if (ptrace(PTRACE_SEIZE, pid, 0,
             PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACEEXIT | PTRACE_O_TRACEEXEC | PTRACE_O_TRACECLONE |
                 PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK) < 0)
    err(1, "setting trace options");
  if (ptrace(PTRACE_CONT, pid, 0, 0) < 0) err(1, "starting trace");
  return pid;
}

static FILE *
open_log(char const *fn)
{
  int fd = open(fn, O_WRONLY | O_TRUNC | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) err(1, "%s", fn);
  FILE *logfile = fdopen(fd, "w");
  if (!logfile) err(1, "%s", fn);
  setbuf(logfile, 0);
  return logfile;
}
EOF

cat <<'EOF' >"${workdir}/util/expand"
#!/usr/bin/env python3
import sys
import re
import os
pid=sys.argv[1]
stat=sys.argv[2]
bgpid=sys.argv[3]
word=sys.argv[4]
res = re.split(r'(\$(?:\$|\?|!|\{[^}\s]*\}))', word)
for i in range(1, len(res), 2):
    if res[i] == "$$":
        res[i] = pid
    elif res[i] == "$?":
        res[i] = stat
    elif res[i] == "$!":
        res[i] = bgpid
    elif res[i][:2] == "${":
        name = res[i][2:-1]
        res[i] = os.getenv(name) or ""
print(''.join(res))
EOF
chmod +x "${workdir}/util/expand"

###############################################################################
#
# I/O pipes
mkdir -p "${workdir}/pipes"
for pipe in stdin_pipe stdout_pipe stderr_pipe 
do
  readonly "${pipe}=${workdir}/pipes/${pipe}"
  mkfifo "${!pipe}"
done

###############################################################################
#
# I/O File backing
mkdir -p "${workdir}/output"
for file in stdout stderr combined trace_log trace_diag
do
  readonly "${file}=${workdir}/output/${file}"
  : > "${!file}"
done

###############################################################################
#
# Smallsh Manager
declare -i smallsh_sid smallsh_status tracer_pid
declare smallsh_disposition

smallsh_running() {
  return test -n "${smallsh_sid+x}" &&
         kill -0 "${smallsh_sid}" &>/dev/null
}

smallsh_update_status() {
  smallsh_disposition=RUNNING
  while read tevt tpid tinfo
  do
    if [ "${tpid}" = "${smallsh_sid}" ]
    then
      if [ "${tevt}" = EXIT ]
      then
        smallsh_status=${tinfo}
      elif [ "${tevt}" = TERM ]
      then
        smallsh_status=-${tinfo}
      elif [ "${tevt}" = KILLED ]
      then
        smallsh_status=-9
      else
        continue
      fi
      smallsh_disposition=${tevt}
      break
    fi
  done <${trace_log}
}

smallsh_update_children() {
  smallsh_children=() 
  while read tevt tpid tinfo
  do
    if [ "${tevt}" = FORK ] 
    then
      smallsh_children+=("${tinfo}")
    fi
  done <${trace_log}
}

kill_smallsh() {
  exec 3>&-
  end=$((EPOCHSECONDS + 5))
  smallsh_update_status
  while
    [ "${smallsh_disposition}" = RUNNING ] &&
    [ "${EPOCHSECONDS}" -le "$end" ]
  do
    microsleep
    smallsh_update_status
  done
  if [ "${smallsh_disposition}" = RUNNING ]
  then
    {
      kill -SIGTERM "$tracer_pid"
      wait "${tracer_pid}"
    } &>/dev/null
    smallsh_update_status
  fi
  smallsh_update_children
  unset tracer_pid 
  return 0
}


trap 'trap - ERR EXIT
exec 3>&-
[ -n "${tracer_pid}" ] && kill -SIGTERM "$tracer_pid" &>/dev/null
while ! rm -rf "${workdir}" &>/dev/null 
do 
  sleep 0.5 
done 
exit 1' EXIT SIGINT

# ROOT pid fn
# TERM pid sig
# EXIT pid status
# FORK pid child
# SIGNAL pid sig
# ERROR
# DIE pid fn
# KILLED pid

smallsh() {
  if [ -n "${tracer_pid}" ]
  then
    kill_smallsh
  fi
  { : >"${combined}" \
      >"${stdout}" \
      >"${stderr}" \
      <>"${stdin_pipe}" \
      <>"${stdout_pipe}" \
      <>"${stderr_pipe}"  \
      >"${trace_log}" \
      >"${trace_diag}"
  } &>/dev/null
  if [ "$1" = "-i" ]
  then
    PATH="${workdir}/bin:${PATH}" "${workdir}/util/tracer" "${trace_log}" "${trace_diag}" \
          "${smallsh_exe}" 0<"${stdin_pipe}" \
          1>"${stdout_pipe}" 2>"${stderr_pipe}" &
  else
    PATH="${workdir}/bin:${PATH}" "${workdir}/util/tracer" "${trace_log}" "${trace_diag}" \
          "${smallsh_exe}" "${stdin_pipe}" \
          1>"${stdout_pipe}" 2>"${stderr_pipe}" &
  fi
  tracer_pid="$!"
  "${workdir}/util/head" 512 <"${stdout_pipe}" | 
    tee -a "${stdout}" >>"${combined}" &
  "${workdir}/util/head" 512 <"${stderr_pipe}" | 
    tee -a "${stderr}" >>"${combined}" &
  exec  3>"${stdin_pipe}"
  end="$((EPOCHSECONDS + 5))"
  while
    ! read -r tevt tpid tinfo <"${trace_log}"
  do
    microsleep
    if [ "${EPOCHSECONDS}" -gt "${end}" ]
    then
      printf 'Error: tracer did not report smallsh process id\n' >&2
      exit 1
    fi
  done
  if [ ! "${tevt}" = "ROOT" ]
  then
    printf 'Error executing smallsh\n' >&2
    exit 1
  fi
  smallsh_sid=${tpid}
  if [ "${smallsh_sid}" -le 0 ]
  then
    printf 'Error: smallsh sid = %s\n' "${smallsh_sid}"
    exit 1
  fi
  return 0
}

smallsh_cmd() {
  for cmd
  do
    tput bold >>"${combined}"
    printf '%s\n' "$cmd" >>"${combined}"
    tput sgr0 >>"${combined}"
    printf '%s\n' "$cmd" >&3
  done
}

set +e

###############################################################################
#
# Randomized environment variables
declare -a params
for i in {0..5}
do
  params+=('P_'$(shuf -rn $((RANDOM % 10 + 5)) -e {A..Z} {a..z} {0..9} _ | paste -sd ''))
  braced_params=("${params[@]/#/$\{}")
  braced_params=("${braced_params[@]/%/\}}")
  if [ "${i}" -lt 5 ]
  then
    export "${params[-1]}"="$(shuf -rn $((RANDOM % 40 + 5)) -e {A..Z} {a..z} ' ' | paste -sd '')"
  fi
done


###############################################################################
#
# Test numbering

scores=(5 5 7 8 15 5 5 10 15 10 5 15 10 10 5 10 5 10 5 5 5 5 5)
declare -i testno=0 score=0 maxscore=0 crashed=0
dotest() {
  ((testno++))
  ! [[ " ${SMALLSH_SKIP} " =~ " ${testno} " ]]
}

declare -i passed=1
printscore() {
  if [ "${passed}" -ne 0 ]
  then
    tput setaf 2 bold
    printf 'Passed\n'
    score+="${scores[$((testno-1))]}"
    tput sgr0
  else 
    tput setaf 1 bold
    printf 'Failed\n'
    tput sgr0
  fi
  tput setaf 4 bold
  maxscore+="${scores[$((testno-1))]}"
  printf 'Total score %d out of %d\n\n' "${score}" "${maxscore}"
  tput sgr0
  return 0
}

check_child_count() {
  if [ ${#smallsh_children[@]} -ne "${1:-0}" ]
  then
    passed=0
    printdiag 'Expected %d children but observed %d\n' "${1:-0}" "${#smallsh_children[@]}"
  fi
  return 0
}

check_status() {
  if [ "${1:-0}" = KILLED ]
  then
    if [ ! "${smallsh_disposition}" = KILLED ]
    then
      passed=0
      tput setaf 1
      printf 'Expected smallsh to be killed (timed out), instead got '
      if [ "${smallsh_status}" -ge 0 ]
      then
        printf 'exit status %d' "${smallsh_status}"
      else
        printf 'termination signal %d' "$((-${smallsh_status}))"
      fi
      printf '.\n'
    fi
  elif [ "${smallsh_disposition}" = KILLED ]
  then
    passed=0
    printdiag 'Smallsh was killed (timed out)\n'
    printdiag 'This will be recorded as a crash event\n'
    ((++crashed))
  elif 
    [ "${smallsh_status}" -ne "${1:-0}" ]
  then
    passed=0
    tput setaf 1
    printf 'Expected '
    if [ "${1:-0}" -ge 0 ]
    then
      printf 'exit status %d' "${1:-0}"
    else
      printf 'termination signal %d' "$((-${1:-0}))"
    fi
    printf ', instead got '
    if [ "${smallsh_status}" -ge 0 ]
    then
      printf 'exit status %d' "${smallsh_status}"
    else
      printf 'termination signal %d' "$((-${smallsh_status}))"
    fi
    printf '.\n'
    if [ "${1:-0}" -ge 0 ] && [ "${smallsh_status}" -lt 0 ]
    then
      printf 'This will be recorded as a crash event\n'
      ((++crashed))
    fi
    tput sgr0
  fi
  return 0
}

check_stderr() {
  cat > reference
  if
    ! cmp -s "${stderr}" reference >&/dev/null
  then
    passed=0
    tput setaf 1
    printf 'Unexpected output on stderr\n'
    if [ -s reference ]
    then
      printf 'Expected:\n'
      paste reference
    fi
    tput sgr0
  fi
  return 0
}

check_stdout() {
  cat > reference
  if
    ! cmp -s "${stdout}" reference >&/dev/null
  then
    passed=0
    tput setaf 1
    printf 'Unexpected output on stdout\n'
    if [ -s reference ]
    then
      printf 'Expected:\n'
      paste reference
    fi
    tput sgr0
  fi
  return 0
}

check_file() {
  if [ "$#" -lt 1 ]
  then
    printf 'Error in grading script. Missing filename in check_file\n'
    exit 1
  fi
  cat > reference
  if
    ! cmp -s "$1" reference >&/dev/null
  then
    passed=0
    tput setaf 1
    printf 'Unexpected contents of `%s`\n' "$1"
    if [ -s reference ]
    then
      printf 'Expected:\n'
      paste reference
    fi
    tput sgr0
  fi
  return 0
}

printheader() {
  tput setaf 3 bold
  printf '== Test number %d (%d points) ==\n' "$((testno))" "${scores[$((testno-1))]}"
  if [ "$#" -gt 0 ]
  then
    printf 'Description: %s\n' "$1"
    shift
  fi
  if [ "$#" -gt 0 ]
  then
    printf '             %s\n' "$@"
  fi
  tput sgr0
  passed=1
}

printdiag() {
  tput setaf 1
  printf "$@"
  tput sgr0
}

exec 0</dev/null
cd "${workdir}"

# =================== BEGIN GRADING SCRIPT PROPER =================== #
# ___________________________________________________________________ 

if dotest
then
  printheader '# comments'
  smallsh
  smallsh_cmd '_echo Hello World! #this is a comment!'
  kill_smallsh
  paste "${combined}"
  check_child_count 1
  check_status
  check_stdout < <(printf 'Hello World!\n')
  check_stderr
  printscore
fi

if dotest
then
  printheader '$$'
  smallsh
  smallsh_cmd '_echo $$'
  kill_smallsh
  paste "${combined}"
  check_child_count 1
  check_status
  check_stdout < <(printf '%d\n' "${smallsh_sid}")
  check_stderr
  printscore
fi

if dotest
then
  printheader '$?'
  for exit_val in $(shuf -i1-127 -n5)
  do
    if [ "${passed}" -eq 0 ]
    then
      break
    fi
    smallsh
    smallsh_cmd "_exit ${exit_val}" '_echo $?'
    kill_smallsh
    paste "${combined}"
    check_child_count 2
    check_status
    check_stdout < <(printf '%s\n' "${exit_val}") 
    check_stderr
  done
  for sig_val in 1 2 3 6 9 15
  do
    if [ "${passed}" -eq 0 ]
    then
      break
    fi
    smallsh
    smallsh_cmd "_signal ${sig_val}" '_echo $?'
    kill_smallsh
    paste "${combined}"
    check_child_count 2
    check_status
    check_stdout < <(printf '%d\n' "$((sig_val + 128))")
    check_stderr
    if [ $passed -eq 0 ]
    then
      paste "${trace_log}"
      exit 1
    fi
  done
  printscore
fi

if dotest
then
  printheader '$!'
  for i in {1..5}
  do
    if [ "${passed}" -eq 0 ]
    then
      break
    fi
    smallsh
    smallsh_cmd "_suspend &" 
    smallsh_cmd '_echo $!' 
    kill_smallsh
    paste "${combined}"
    check_status
    check_stderr
    check_child_count 2
    check_stdout < <(printf '%d\n' "${smallsh_children[0]:-<PID>}")
  done
  printscore
fi

if dotest
then
  printheader '${parameter}'
  for i in  {0..5}
  do
    if [ "${passed}" -eq 0 ]
    then
      break
    fi
    smallsh
    smallsh_cmd '_echo '"${braced_params[${i}]}"
    kill_smallsh
    paste "${combined}"
    check_child_count 1
    check_status
    check_stderr
    check_stdout < <(printf '%s\n' "${!params[${i}]}") 
  done
  printscore
fi

if dotest
then
  printheader 'Multiple parameters in one command'
  smallsh
  declare -a words expwords
  for i in {1..5}
  do
    word="$(shuf -rn 20 -e "${braced_params[@]}" '$!' '$'{,,,} '!'{,,} '?'{,,} '{' '}' | paste -sd ''))"
    words+=("${word}")
    expwords+=("$(util/expand "${smallsh_sid}" 0 '' "${word}")")
  done
  smallsh_cmd '_echo '"${words[*]}"
  kill_smallsh
  paste "${combined}"
  check_child_count 1
  check_status
  check_stderr
  check_stdout < <(bin/_echo "${expwords[@]}") 
  printscore
fi

if dotest
then
  printheader '`exit`'
  exit_val=$((RANDOM % 127 + 1))
  smallsh
  smallsh_cmd 'exit '"${exit_val}"
  kill_smallsh
  paste "${combined}"
  check_child_count 0
  check_status "${exit_val}"
  check_stdout
  check_stderr
  printscore
fi

if dotest
then
  printheader '`cd`'
  smallsh
  smallsh_cmd 'cd /tmp' 'pwd' 'cd' 'pwd'
  kill_smallsh
  paste "${combined}"
  check_child_count 2
  check_status
  check_stderr
  check_stdout < <(( cd /tmp; pwd; cd; pwd; ))
  printscore
fi

if dotest
then
  printheader '`<` operator'
  printf 'Hello World!\n' > testfile
  smallsh
  smallsh_cmd 'cat < testfile'
  kill_smallsh
  paste "${combined}"
  check_child_count 1
  check_status
  check_stderr
  check_stdout < <(printf 'Hello World!\n')
  check_file testfile < <(printf 'Hello World!\n')
  printscore
fi

if dotest
then
  rm -f testfile &>/dev/null
  printheader '`>` operator'
  smallsh
  smallsh_cmd 'printf Goodbye\ World!\\n > testfile' 'cat testfile'
  kill_smallsh
  paste "${combined}"
  check_child_count 2
  check_status
  check_stderr
  check_stdout < <(printf 'Goodbye World!\n')
  check_file testfile < <(printf 'Goodbye World!\n')
  printscore
fi

if dotest
then
  printf 'Hello ' > testfile
  printheader '`>>` operator'
  smallsh
  smallsh_cmd 'cat testfile' 'printf World!\\n >> testfile' 'cat testfile'
  kill_smallsh
  paste "${combined}"
  check_child_count 3
  check_status
  check_stderr
  check_stdout < <(printf 'Hello Hello World!\n')
  check_file testfile < <(printf 'Hello World!\n')
  printscore
fi

if dotest
then
  rm -f testfile &>/dev/null
  printheader 'Multiple redirection operators'
  smallsh
  smallsh_cmd 'printf test\\n > testfile' \
              'printf Hello\ World!\\n > infile' \
              'printf asdfhjkl > garbagefile' \
              'cat < infile >> testfile > garbagefile > outfile' \
              'cat testfile infile garbagefile outfile'
  kill_smallsh
  paste "${combined}"
  check_child_count 5
  check_status
  check_stderr
  check_file testfile < <(printf 'test\n')
  check_file garbagefile < <(printf '')
  check_file infile < <(printf 'Hello World!\n')
  check_file outfile < <(printf 'Hello World!\n')
  check_stdout < <(printf 'test\nHello World!\nHello World!\n')
  printscore
fi

if dotest
then
  printheader 'background process `&`'
  smallsh
  smallsh_cmd '_suspend &' '_suspend &' 
  kill_smallsh
  paste "${combined}"
  check_child_count 2
  check_status
  check_stderr
  printscore
fi

if dotest
then
  printheader 'background exit status'
  for exit_val in $(shuf -i1-127 -n5)
  do
    if [ "${passed}" -eq 0 ]
    then
      break
    fi
    smallsh
    smallsh_cmd "_exit ${exit_val} &"
    microsleep
    printf '\n' >&3
    kill_smallsh
    paste "${combined}"
    check_child_count 1
    check_status
    check_stdout
    check_child_count 1
    check_stderr < <(printf 'Child process %d done. Exit status %d.\n' "${smallsh_children[0]:-<PID>}" "${exit_val}")
  done
  printscore
fi

if dotest
then
  printheader 'signaled status'
  for sig_val in 1 2 3 6 9 15
  do
    if [ "${passed}" -eq 0 ]
    then
      break
    fi
    smallsh
    smallsh_cmd "_signal ${sig_val} &"
    microsleep
    printf '\n' >&3
    kill_smallsh
    paste "${combined}"
    check_status
    check_stdout
    check_child_count 1
    check_stderr < <(printf 'Child process %d done. Signaled %d.\n' "${smallsh_children[0]:-<PID>}" "${sig_val}")
  done
  printscore
fi

if dotest
then
  printheader 'SIGCONT to stopped *BACKGROUND* process'
  smallsh
  smallsh_cmd "_signal $(kill -l SIGSTOP) &"
  microsleep
  printf '\n' >&3
  kill_smallsh
  paste "${combined}"
  check_status
  check_stdout
  check_child_count 1
  check_stderr < <(printf 'Child process %d stopped. Continuing.\n' "${smallsh_children[0]:-<PID>}")
  printscore
fi

if dotest
then
  printheader 'SIGCONT to stopped *FOREGROUND* process'
  smallsh
  smallsh_cmd "_signal $(kill -l SIGSTOP)" '_echo $!'
  kill_smallsh
  paste "${combined}"
  check_status
  check_child_count 2
  check_stdout < <(bin/_echo "${smallsh_children[0]:-<PID>}")
  check_stderr < <(printf 'Child process %d stopped. Continuing.\n' "${smallsh_children[0]:-<PID>}")
  printscore
fi

if dotest
then
  randprompt="$(shuf -rn20 -e {a..z} {A..Z} | paste -sd '';): "
  printheader 'Prints PS1 prompt' '(Interactive Mode)' 'PS1="'"$randprompt"'"'
  PS1="${randprompt}" smallsh -i
  smallsh_cmd exit
  kill_smallsh
  paste "${combined}"
  check_status
  check_stdout
  check_stderr < <(printf '%s' "${randprompt}")
  PS1='' smallsh -i
  kill_smallsh
  paste "${combined}"
  check_status
  check_stdout
  check_stderr
  printscore
fi

if dotest
then
  printheader 'Correctly ignores SIGTSTP' '(Interactive Mode)'
  PS1='$_' smallsh -i
  tput bold >>"${combined}"
  printf '%s' '_echo Hello World!^Z' >>"${combined}"
  tput sgr0 >>"${combined}"
  printf '%s' '_echo Hello World!' >&3
  microsleep
  kill -SIGTSTP "${smallsh_sid}"
  microsleep
  printf '\n' >&3
  microsleep
  kill_smallsh
  paste "${combined}"
  check_status
  check_stdout < <(bin/_echo Hello World!)
  check_stderr < <(printf '$_$_')
  printscore
fi


if dotest
then
  printheader 'Correctly resets signals in child process' '(Interactive Mode) PS1="$_"' 
  PS1='$_' smallsh -i
  smallsh_cmd '_signal_disposition '"$(kill -l SIGINT) $(kill -l SIGTSTP)" 
  kill_smallsh
  paste "${combined}"
  check_status
  check_stdout < <(printf 'SIG_DFL\nSIG_DFL\n')
  check_stderr < <(printf '$_$_')
  check_child_count 1

  PS1='$_' TRACER_SIG_IGN="$(kill -l SIGINT) $(kill -l SIGTSTP)" smallsh -i
  smallsh_cmd '_signal_disposition '"$(kill -l SIGINT) $(kill -l SIGTSTP)" 
  kill_smallsh
  paste "${combined}"
  check_status
  check_stdout < <(printf 'SIG_IGN\nSIG_IGN\n')
  check_stderr < <(printf '$_$_')
  check_child_count 1
  printscore
fi


if dotest
then
  printheader 'Correctly ignores SIGINT when NOT reading input' '(Interactive Mode) PS1="$_"'
  PS1='$_' smallsh -i
  smallsh_cmd '_suspend '"$(kill -l SIGINT)"
  for i in {1..5}
  do
    tput bold >>"${combined}"
    printf '%s' '^C' >>"${combined}"
    tput sgr0 >>"${combined}"
    kill -SIGINT "-${smallsh_sid}"
    microsleep
  done
  kill -SIGTERM "${tracer_pid}"
  kill_smallsh
  paste "${combined}"
  check_status KILLED
  check_stdout
  check_stderr < <(printf '$_')
  printscore
fi

if dotest
then
  printheader 'Correctly reacts to SIGINT when reading input' '(Interactive Mode) PS1="$_"'
  PS1='$_' smallsh -i
  for i in {1..5}
  do
    tput bold >>"${combined}"
    printf '%s' '^C' >>"${combined}"
    tput sgr0 >>"${combined}"
    kill -SIGINT "-${smallsh_sid}" &>/dev/null
    microsleep
  done
  kill_smallsh
  paste "${combined}"
  check_status 0
  check_stdout
  check_stderr < <(printf '$_\n$_\n$_\n$_\n$_\n$_')
  printscore
fi

if dotest
then
  printheader 'Never crashed'
  if [ "${crashed}" -ne 0 ]
  then
    passed=0
    printdiag 'Crashed %d times\n' "${crashed}"
  fi
  printscore
fi


