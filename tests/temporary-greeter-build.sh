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
CI_LOGIN_PASSWORD=$(openssl rand -hex 20)
printf '%s\n' "$CI_LOGIN_PASSWORD" | pw usermod ci-login -h 0
export CI_LOGIN_PASSWORD BUILD_JOBS=2

INSTALL_COMPONENTS='niri greeter' GPU_MODULE=none INSTALL_PATCH_DIR="$repo_dir/patches" \
	sh install.sh --user ci-login >ci-reports/install.log 2>&1
cat ci-reports/install.log

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
sh tests/temporary-greeter-login.sh
