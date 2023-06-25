
#define _POSIX_C_SOURCE 200809L
#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#include <stdbool.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <err.h>
#include <unistd.h>
#include <limits.h>
#include <ctype.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>

#ifndef MAX_WORDS
#define MAX_WORDS 512
#endif
#ifndef MAX_CHARS
#define MAX_CHARS 1024
#endif

// command arguments
char *words[MAX_WORDS];

// functions
size_t wordsplit(char const *line);
char * expand(char const *word);

void getBG(char **words, size_t nwords);
size_t parse(char **words, size_t nwords, char ***child_arguments);
bool isNumber(const char *s);
void setResultCode(int rc);

// spec params
// $!
char bgpid[MAX_CHARS];
// $$
char pid[MAX_CHARS];
// $?
char status[MAX_CHARS];
int istatus = 0;
// &
bool isBgProcess = false;

// signals saves
struct sigaction oldInt		= {0};
struct sigaction oldStop	= {0};
struct sigaction ignor		= {0};


// disables signals in interactive mode
void signal_ignored(int sig) {}

int main(int argc, char *argv[])
{
    FILE *input = stdin; //set to standard in by default
    char *input_fn = "(stdin)";
    if (argc == 2) {
	  // setup input file as stdin
      input_fn = argv[1];
      input = fopen(input_fn, "re");
      if (!input) err(1, "%s", input_fn);
    } else if (argc > 2) {
      errx(1, "too many arguments");
    }
	
	// set $$ etc to defaults
	snprintf(pid, MAX_CHARS, "%jd", (intmax_t)getpid());
	strcpy(bgpid, "");
	strcpy(status, "0");

    if (input == stdin) {
      //Handle interactive. Setup ignoring of signals.
	  ignor.sa_handler = signal_ignored;
	  if (sigaction(SIGINT, &ignor, &oldInt) < 0) err(1, "sigaction(SIGINT)");
	  if (sigaction(SIGTSTP, &ignor, &oldStop) < 0) err(1, "sigaction(SIGTSTP)");
	}

	// main loop
    char *line = NULL;
    size_t n = 0;
    for (;;) {
prompt:;
      // Manage background processes
	  int chpid = 0;
	  do {
		// process background child processes
		int status;
		chpid = waitpid(0, &status, WNOHANG | WUNTRACED);
		if (chpid > 0) {
			// child signaled
			if (WIFSIGNALED(status)) {
				fprintf(stderr, "Child process %jd done. Signaled %d.\n", (intmax_t)chpid, WTERMSIG(status));
			}
			// child exited
			else if (WIFEXITED(status)) {
				fprintf(stderr, "Child process %jd done. Exit status %d.\n", (intmax_t)chpid, WEXITSTATUS(status));
			}
			// child stopped
			else if (WIFSTOPPED(status)) {
				// sends SIG_CONT and aborts the wait
				kill(chpid, SIGCONT);
				fprintf(stderr, "Child process %jd stopped. Continuing.\n", (intmax_t)chpid);
			}
		}
	  } while(chpid > 0);

      if (input == stdin) {
        //Handle interactive. Otherwise it is a file.
		char *PS1 = getenv("PS1");
		if (PS1 == NULL) PS1 = "$";
		fprintf(stderr, "%s", PS1);
      }

	  // read command line
	  errno = 0;
      ssize_t line_len = getline(&line, &n, input);
      if (line_len < 0) {
        if (errno == EINTR) {
		  // clear error and print a newline
		  clearerr(input);
		  errno = 0;
		  fprintf(stderr, "\n");
		  goto prompt;
		} else {
		  // It's EOF
		  if (errno) fprintf(stderr, "smallsh: %s: %s\n", input_fn, strerror(errno));
		  exit(istatus);
		}
      }

	  // split & expand command line
      size_t nwords = wordsplit(line);
      for (size_t i = 0; i < nwords; ++i) {
		char *exp_word = expand(words[i]);
		free(words[i]);
		words[i] = exp_word;
      } 
	  if (!nwords) goto prompt;

	  // process built-in commands
	  if (!strcmp(words[0], "exit")) {
		  if (nwords > 1) {
			  // check exit arguments
			  if ((nwords > 2) || !isNumber(words[1])) {
				fprintf(stderr, "smallsh: exit command: wrong arguments\n");
				setResultCode(1);
				for (size_t i = 0; i < nwords; ++i) free(words[i]);
				goto prompt;
			  }
			  exit(atoi(words[1]));
		  }
		  else {
			  // default return code of smallsh is $?
			  exit(istatus);
		  }
	  }
	  else if (!strcmp(words[0], "cd")) {
		  const char *path = 0;
		  if (nwords > 1) {
			  // check cd arguments
			  if (nwords > 2) {
				fprintf(stderr, "smallsh: cd command: wrong arguments\n");
				setResultCode(1);
				for (size_t i = 0; i < nwords; ++i) free(words[i]);
				goto prompt;
			  }
			  path = words[1];
		  }
		  else {
			// default path for cd is $HOME
			path = getenv("HOME");
			if (!path) path = "";
		  }
		  // changes directory
		  if (chdir(path)) {
			fprintf(stderr, "smallsh: cd command: %s\n", strerror(errno));
			setResultCode(1);
		  }
		  for (size_t i = 0; i < nwords; ++i) free(words[i]);
		  goto prompt;
	  }
	  
	  // Checks for '&'
	  getBG(words, nwords);

	  // creates child process
	  int pid = fork();
      if (pid == 0) 
	  {
		// reset signals
	    if (sigaction(SIGINT, &oldInt, NULL) < 0) err(1, "restore sigaction(SIGINT) in child");
	    if (sigaction(SIGTSTP, &oldStop, NULL) < 0) err(1, "restore sigaction(SIGTSTP) in child");

		// makes parameters list & redirects in/out
		char **args = 0;
		size_t nCmds = parse(words, nwords, &args);
		if (nCmds == INT_MAX) err(1, "Child: no filename for redirection");
		// executes external executable as child process
		if (nCmds) execvp(args[0], args);
		// execute failed
		err(errno, "Execute of '%s' failed.", args[0]);
		// free all parents vars
		//for (size_t i = 0; i < nwords; ++i) free(words[i]);
		//free(args);
	  }
      else {
		// free unused args
		for (size_t i = 0; i < nwords; ++i) free(words[i]);
		if (pid < 0) err(errno, "fork(): %s", strerror(errno));
	    if (isBgProcess) {
			// sets $!
			snprintf(bgpid, MAX_CHARS, "%jd", (intmax_t)pid);
		}
		else {
			// waits for foreground child process
			while(true) {
				// process current foreground child process
				int status;
				int ret = waitpid(pid, &status, WNOHANG | WUNTRACED);
				if (ret > 0) {
					// child signaled
					if (WIFSIGNALED(status)) {
						setResultCode(WTERMSIG(status) + 128);
						break;
					}
					// child exited
					else if (WIFEXITED(status)) {
						setResultCode(WEXITSTATUS(status));
						break;
					}
					// child stopped
					else if (WIFSTOPPED(status)) {
						// sends SIG_CONT and aborts the wait
						fprintf(stderr, "Child process %jd stopped. Continuing.\n", (intmax_t)pid);
						kill(pid, SIGCONT);
						// sets $!
						snprintf(bgpid, MAX_CHARS, "%jd", (intmax_t)pid);
						break;
					}
				}
				// gives a quantum of time to the system
				usleep(300000);
			}
		}
	  }
	}
}

char *words[MAX_WORDS] = {0};

/* Splits a string into words delimtied by whitespace. Recognizes
 * comments as '#' at the beginning of the word, and backslash escapes.
 *
 * Returns number of words parsed, and updates the words[] array
 * with pointers to the words, each as an allocated string.
 */
size_t wordsplit(char const *line) {
  size_t wlen = 0;
  size_t wind = 0;
  words[wind] = 0;

  char const *c = line;
  for (;*c && isspace(*c); ++c); /* discard leading space */

  for (; *c;) {
    if (wind == MAX_WORDS) break;
    /* read a word */
    if (*c == '#') break;
    for (;*c && !isspace(*c); ++c) {
      if  (*c == '\\') ++c;
      void *tmp = realloc(words[wind], sizeof **words * (wlen + 2));
      if (!tmp) err(1, "realloc");
      words[wind] = tmp;
      words[wind][wlen++] = *c;
      words[wind][wlen] = '\0';
    }
    ++wind;
	words[wind] = 0;
    wlen = 0;
    for (;*c && isspace(*c); ++c);
  }
  return wind;
}


/* Find next instance of a parameter within a word. Sets
 * start and end pointers to the start and end of the parameter
 * token.
 */
char param_scan(char const *word, char **start, char **end)
{
  static char *prev;
  if (!word) word = prev;

  char ret = 0;
  *start = NULL;
  *end = NULL;
  char *s = strchr(word, '$');
  if (s) {
    char *c = strchr("$!?", s[1]);
    if (c) {
      ret = *c;
      *start = s;
      *end = s + 2;
    }
    else if (s[1] == '{') {
      char *e = strchr(s + 2, '}');
      if (e) {
        ret = '{';
	*start = s;
	*end = e + 1;
      }
    }
  }
  prev = *end;
  return ret;
}

/* Simple string-builder function. Builds up a base
 * string by appending supplied strings/character ranges
 * to it.
 */
char *build_str(char const *start, char const *end)
{
  static size_t base_len = 0;
  static char *base = 0;

  if (!start) {
    char *ret = base;
    base = NULL;
    base_len = 0;
    return ret;
  }
  /* Append [start, end) to base string
   * If end is NULL, append whole start string to base string.
   * Returns a newly allocated string that the caller must free.
   */
  size_t n = end ? end - start : strlen(start);
  size_t newsize = sizeof *base *(base_len + n + 1);
  void *tmp = realloc(base, newsize);
  if (!tmp) err(1, "realloc");
  base = tmp;
  memcpy(base + base_len, start, n);
  base_len = newsize-1;
  base[base_len] = '\0';

  return base;
}

/* Expands all instances of $! $$ $? and ${param} in a string
 * Returns a newly allocated string that the caller must free
 */
char *expand(char const *word)
{
  char const *pos = word;
  char *start, *end;
  char c = param_scan(pos, &start, &end);
  build_str(NULL, NULL);
  build_str(pos, start);
  while (c) {
    if (c == '!') build_str(bgpid, NULL);
    else if (c == '$') build_str(pid, NULL);
    else if (c == '?') build_str(status, NULL);
    else if (c == '{') {
	  //build_str(start + 2, end - 1);
	  *(end-1) = 0;
	  char *evar = getenv(start+2);
	  if (!evar) evar = "";
	  *(end-1) = '}';
	  build_str(evar, NULL);
    }
    pos = end;
    c = param_scan(pos, &start, &end);
    build_str(pos, start);
  }
  return build_str(start, NULL);
}

/* Checks the words array for background symbol '&'.
 * Returns the presence of '&' in isBgProcess variable.
 */
void getBG(char **words, size_t nwords)
{
  isBgProcess = false;
  for (size_t i = 0; i < nwords; ++i) {
    if (strcmp(words[i], "&") == 0) isBgProcess = true;
  }
}

/* Parses the words array and builds a list of child arguments by copying pointers to words into the list.
 * Returns the number of child arguments.
 */
size_t parse(char **words, size_t nwords, char ***child_arguments)
{
  size_t child_arguments_counter = 0;
  *child_arguments = calloc(nwords + 1, sizeof(char*));

  isBgProcess = false;
  for (size_t i = 0; i < nwords; ++i) {
    if (strcmp(words[i], "&") == 0) isBgProcess = true;
  }

  for (size_t i = 0; i < nwords; ++i) {
    if (strcmp(words[i], "&") == 0) {
      //background process
	  if (!freopen("/dev/null", "r", stdin)) err(errno, "bg to /dev/null redirect");
      continue;
    } else if (strcmp(words[i], ">") == 0) {
      //Output redirection
	  if (isBgProcess) continue;
      if (i + 1 < nwords) {
		if (!freopen(words[i + 1], "w", stdout)) err(errno, ">'%s' redirect", words[i + 1]);
		fchmod(fileno(stdout), 0777);
		++i;
      } else return INT_MAX; // error - no filename
      continue;
    } else if (strcmp(words[i], "<") == 0) {
      //Input redirection
	  if (isBgProcess) continue;
      if (i + 1 < nwords) {
		if (!freopen(words[i + 1], "r", stdin)) err(errno, "<'%s' redirect", words[i + 1]);
		++i;
      } else return INT_MAX; // error - no filename
      continue;
    } else if (strcmp(words[i], ">>") == 0) {
      //Output redirection, append mode
	  if (isBgProcess) continue;
      if (i + 1 < nwords) {
		if (!freopen(words[i + 1], "a", stdout)) err(errno, ">>'%s' redirect", words[i + 1]);
		fchmod(fileno(stdout), 0777);
		++i;
      } else return INT_MAX; // error - no filename
      continue;
    }
    (*child_arguments)[child_arguments_counter++] = words[i];
  }
  // Terminate the child arguments list with NULL
  (*child_arguments)[child_arguments_counter] = NULL;
  return child_arguments_counter;
}

/* Checks if the passed string is a valid integer.
 * Returns 1 - Check Success   0 - Wrong string
 */
bool isNumber(const char *s)
{
    char* c;
    strtol(s, &c, 10);
    return *c == 0;
}

/* Sets istatus & status as $?
 */
void setResultCode(int rc)
{
	istatus = rc;
	snprintf(status, MAX_CHARS, "%d", rc);
}

