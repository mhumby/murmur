#include <stdlib.h>
#include <unistd.h>
#include <libgen.h>
#include <string.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
    /* Resolve the project directory from the symlink-free executable path */
    char path[4096];
    uint32_t size = sizeof(path);
    _NSGetExecutablePath(path, &size);

    /* Go to project dir */
    chdir("/Users/mtalukder/dev-projects/murmur");

    /* Exec Python */
    execl(".venv/bin/python", "python", "app.py", NULL);

    perror("execl failed");
    return 1;
}
