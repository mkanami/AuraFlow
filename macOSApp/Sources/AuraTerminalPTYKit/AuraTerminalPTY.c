#include "AuraTerminalPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static void set_error(char *buffer, size_t length, const char *message) {
    if (buffer == NULL || length == 0) {
        return;
    }
    snprintf(buffer, length, "%s: %s", message, strerror(errno));
}

static char **decode_blob(const uint8_t *blob, size_t count) {
    char **values = calloc(count + 1, sizeof(char *));
    if (values == NULL) {
        return NULL;
    }

    const uint8_t *cursor = blob;
    for (size_t index = 0; index < count; index++) {
        values[index] = (char *)cursor;
        cursor += strlen((const char *)cursor) + 1;
    }
    values[count] = NULL;
    return values;
}

int aura_terminal_pty_spawn(
    const char *executable,
    const uint8_t *argv_blob,
    size_t argv_count,
    const uint8_t *environment_blob,
    size_t environment_count,
    const char *working_directory,
    uint16_t columns,
    uint16_t rows,
    pid_t *child_pid,
    int *master_fd,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (executable == NULL || argv_blob == NULL || argv_count == 0 ||
        child_pid == NULL || master_fd == NULL) {
        errno = EINVAL;
        set_error(error_buffer, error_buffer_length, "invalid spawn arguments");
        return -1;
    }

    struct winsize size = {
        .ws_row = rows > 0 ? rows : 24,
        .ws_col = columns > 0 ? columns : 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    int local_master = -1;
    pid_t pid = forkpty(&local_master, NULL, NULL, &size);
    if (pid < 0) {
        set_error(error_buffer, error_buffer_length, "forkpty failed");
        return -1;
    }

    if (pid == 0) {
        // forkpty()'s child setup calls login_tty(), which creates the new
        // session and controlling terminal. Do not change the process group
        // before or during that setup: making the child a group leader first
        // can make setsid() fail, leaving /dev/tty unavailable to TUI apps.
        if (working_directory != NULL && working_directory[0] != '\0') {
            (void)chdir(working_directory);
        }

        char **argv = decode_blob(argv_blob, argv_count);
        char **environment = decode_blob(environment_blob, environment_count);
        if (argv == NULL || environment == NULL) {
            _exit(127);
        }
        execve(executable, argv, environment);
        _exit(127);
    }

    if (aura_terminal_pty_set_nonblocking(local_master) != 0) {
        close(local_master);
        (void)kill(-pid, SIGTERM);
        (void)waitpid(pid, NULL, 0);
        set_error(error_buffer, error_buffer_length, "failed to configure PTY");
        return -1;
    }

    *child_pid = pid;
    *master_fd = local_master;
    return 0;
}

int aura_terminal_pty_set_nonblocking(int master_fd) {
    int flags = fcntl(master_fd, F_GETFL, 0);
    if (flags < 0) {
        return -1;
    }
    return fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);
}

int aura_terminal_pty_resize(int master_fd, pid_t child_pid, uint16_t columns, uint16_t rows) {
    struct winsize size = {
        .ws_row = rows > 0 ? rows : 24,
        .ws_col = columns > 0 ? columns : 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    if (ioctl(master_fd, TIOCSWINSZ, &size) != 0) {
        return -1;
    }
    if (child_pid > 0 && kill(-child_pid, SIGWINCH) != 0 && errno != ESRCH) {
        return -1;
    }
    return 0;
}

int aura_terminal_pty_terminate(pid_t child_pid, int signal_number) {
    if (child_pid <= 0) {
        errno = EINVAL;
        return -1;
    }
    int result = kill(-child_pid, signal_number);
    if (result != 0 && errno == ESRCH) {
        result = kill(child_pid, signal_number);
    }
    return result;
}

int aura_terminal_pty_close(int master_fd) {
    if (master_fd < 0) {
        return 0;
    }
    return close(master_fd);
}
