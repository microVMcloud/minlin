/*
 * Starts a container image's program the way its config asks, for the things
 * an init.conf line can't express: a working directory, environment
 * variables, and a program found through the image's PATH.
 *
 *   run [-C dir] [NAME=value...] -- program [args...]
 *
 * Built static by apps/oci/install.sh so it runs whatever libc the image
 * has, or none.
 */
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SHM_DIR "/minlin/shm"

/*
 * Docker gives every container a /dev/shm, and shm_open() (pihole-FTL's
 * shared memory) is just a file opened there. The kernel has no tmpfs, and
 * init's RAM-backed /dev can't fallocate(), which FTL and musl's
 * posix_fallocate need, so point /dev/shm at a directory on the ext4 disk.
 * Shared mappings of those files work the same; the pages are written back to
 * the disk now and then. Segments are named after pids, which repeat from
 * boot to boot, so empty it first, as a fresh tmpfs would be.
 */
static void setup_shm(void)
{
	DIR *d = opendir(SHM_DIR);
	struct dirent *e;

	if (!d)
		return;
	while ((e = readdir(d)))
		if (strcmp(e->d_name, ".") && strcmp(e->d_name, ".."))
			unlinkat(dirfd(d), e->d_name, 0);
	closedir(d);
	chmod(SHM_DIR, 01777);
	if (symlink(SHM_DIR, "/dev/shm") < 0 && errno != EEXIST)
		fprintf(stderr, "run: symlink /dev/shm: %s\n", strerror(errno));
}

int main(int argc, char **argv)
{
	int i = 1;

	/*
	 * init mounts /tmp root-only (0755) over the image's, which images ship
	 * as 1777, as a program that drops privileges expects (pihole's gravity
	 * runs mktemp there as the pihole user). Restore what the image had.
	 */
	chmod("/tmp", 01777);
	setup_shm();

	if (i + 1 < argc && strcmp(argv[i], "-C") == 0) {
		if (chdir(argv[i + 1]) < 0) {
			fprintf(stderr, "run: chdir %s: %s\n", argv[i + 1], strerror(errno));
			return 126;
		}
		i += 2;
	}
	for (; i < argc && strcmp(argv[i], "--") != 0; i++) {
		if (!strchr(argv[i], '=') || putenv(argv[i]) != 0) {
			fprintf(stderr, "run: bad variable '%s'\n", argv[i]);
			return 126;
		}
	}
	if (i + 1 >= argc) {
		fprintf(stderr, "usage: run [-C dir] [NAME=value...] -- program [args...]\n");
		return 126;
	}
	/* execvp searches the PATH just set above, as the image expects. */
	execvp(argv[i + 1], &argv[i + 1]);
	fprintf(stderr, "run: exec %s: %s\n", argv[i + 1], strerror(errno));
	return 127;
}
