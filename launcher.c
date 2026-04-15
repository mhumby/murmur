#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

int main(int argc, char *argv[]) {
    chdir("/Users/mtalukder/dev-projects/murmur");

    char *child_argv[] = {".venv/bin/python", "app.py", NULL};
    pid_t pid;

    int err = posix_spawn(&pid, child_argv[0], NULL, NULL, child_argv, environ);
    if (err != 0) {
        fprintf(stderr, "Murmur: failed to launch (%d)\n", err);
        return 1;
    }

    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
