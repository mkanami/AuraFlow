#ifndef AURA_TERMINAL_PTY_H
#define AURA_TERMINAL_PTY_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

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
);

int aura_terminal_pty_set_nonblocking(int master_fd);
int aura_terminal_pty_resize(int master_fd, pid_t child_pid, uint16_t columns, uint16_t rows);
int aura_terminal_pty_terminate(pid_t child_pid, int signal_number);
int aura_terminal_pty_close(int master_fd);

#endif
