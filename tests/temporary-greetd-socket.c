#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
	int sockets[2], barrier[2];
	char marker;
	signal(SIGPIPE, SIG_IGN);
	if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) != 0 || pipe(barrier) != 0)
		return 1;
	pid_t pid = fork();
	if (pid < 0)
		return 1;
	if (pid == 0) {
		close(sockets[0]);
		close(barrier[1]);
		if (send(sockets[1], "p", 1, 0) != 1 || read(barrier[0], &marker, 1) != 1)
			return 1;
		int result = shutdown(sockets[1], SHUT_RDWR);
		int error = errno;
		printf("Completed worker exchange: shutdown=%d errno=%d (%s)\n", result, error, strerror(error));
#ifdef __FreeBSD__
		if (result != -1 || error != ENOTCONN)
			return 1;
#endif
		result = send(sockets[1], "e", 1, 0);
		error = errno;
		printf("Error transport after peer closure: send=%d errno=%d (%s)\n", result, error, strerror(error));
		return result == -1 && error == EPIPE ? 0 : 1;
	}
	close(sockets[1]);
	close(barrier[0]);
	if (recv(sockets[0], &marker, 1, 0) != 1 || shutdown(sockets[0], SHUT_RDWR) != 0)
		return 1;
	close(sockets[0]);
	if (write(barrier[1], "c", 1) != 1)
		return 1;
	int status;
	if (waitpid(pid, &status, 0) != pid)
		return 1;
	return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
