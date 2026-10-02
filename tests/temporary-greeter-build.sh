#!/bin/sh

# Temporary native FreeBSD build and login check.
set +x
set -eu

export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
mkdir -p ci-reports

save_reports()
{
	status=$?
	trap - EXIT
	if [ -d /tmp/freebsd-greeter-ci ]; then
		cp -R /tmp/freebsd-greeter-ci/. ci-reports/
	fi
	exit "$status"
}
trap save_reports EXIT

sh -n install.sh
sh install.sh --validate
sh tests/install-sh.sh
if ! id ci-login >/dev/null 2>&1; then
	pw useradd ci-login -u 2001 -m -s /bin/sh
fi
export BUILD_JOBS=2

mkfifo ci-reports/install.pipe
tee ci-reports/install.log <ci-reports/install.pipe &
log_pid=$!
INSTALL_COMPONENTS='niri greeter' GPU_MODULE=none INSTALL_PATCH_DIR="$repo_dir/patches" \
	sh install.sh --user ci-login >ci-reports/install.pipe 2>&1 &
install_pid=$!
if wait "$install_pid"; then
	install_status=0
else
	install_status=$?
fi
wait "$log_pid"
rm ci-reports/install.pipe
[ "$install_status" -eq 0 ] || exit "$install_status"

for binary in niri noctalia greetd noctalia-greeter noctalia-greeter-compositor; do
	test -x "/usr/local/bin/$binary"
done
test "$(sysrc -n greetd_enable)" = YES
test "$(sysrc -n gdm_enable)" = NO
test -f /etc/pam.d/greetd
test -f /etc/pam.d/greetd-greeter
test -f /var/lib/noctalia-greeter/greeter.toml
test -d /usr/local/share/noctalia-greeter/assets
service dbus onestart
# The cached VM has no physical GPU. The fixture starts greetd on its X server.
sysrc greetd_enable=NO gdm_enable=NO seatd_enable=NO
