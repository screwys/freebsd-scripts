#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail()
{
	printf '%s\n' "fail: $*" >&2
	exit 1
}

assert_contains()
{
	haystack=$1
	needle=$2
	printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null ||
		fail "expected output to contain: $needle"
}

run_script()
{
	(
		cd "$ROOT"
		sh install.sh "$@"
	)
}

fakebin=$(mktemp -d)
trap 'rm -rf "$fakebin"' EXIT

cat >"$fakebin/uname" <<'EOF'
#!/bin/sh
case "$1" in
	-s) printf '%s\n' FreeBSD ;;
	-r) printf '%s\n' 14.3-RELEASE ;;
	*) printf '%s\n' FreeBSD ;;
esac
EOF
chmod +x "$fakebin/uname"

cat >"$fakebin/pciconf" <<'EOF'
#!/bin/sh
case "${FAKE_GPU:-}" in
	intel)
		cat <<'GPU'
vgapci0@pci0:0:2:0: class=0x030000 rev=0x00 hdr=0x00 vendor=0x8086 device=0x0000
    vendor     = 'Intel Corporation'
    class      = display
GPU
		;;
	amd)
		cat <<'GPU'
vgapci0@pci0:1:0:0: class=0x030000 rev=0x00 hdr=0x00 vendor=0x1002 device=0x0000
    vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
    class      = display
GPU
		;;
	nvidia)
		cat <<'GPU'
vgapci0@pci0:1:0:0: class=0x030000 rev=0x00 hdr=0x00 vendor=0x10de device=0x0000
    vendor     = 'NVIDIA Corporation'
    class      = display
GPU
		;;
esac
EOF
chmod +x "$fakebin/pciconf"

out=$(run_script --bsdinstall-guided --user screwy --dry-run)
assert_contains "$out" 'export ZFSBOOT_DISKS="DISK_YOU_CONFIRM"'
assert_contains "$out" 'export ZFSBOOT_VDEV_TYPE="stripe"'
assert_contains "$out" 'export ZFSBOOT_SWAP_SIZE="2g"'
assert_contains "$out" 'export ZFSBOOT_CONFIRM_LAYOUT="1"'

out=$(run_script -g -u screwy -n)
assert_contains "$out" 'sh /tmp/freebsd-install.sh --from-installer --pkg-branch latest --user screwy'

out=$(
	cd "$ROOT"
	GPU_MODULE=i915kms sh install.sh --dry-run --user screwy
)
assert_contains "$out" 'would set kld_list="i915kms" in /etc/rc.conf'

out=$(
	cd "$ROOT"
	GPU_MODULE=amdgpu sh install.sh --dry-run --user screwy
)
assert_contains "$out" 'would set kld_list="amdgpu" in /etc/rc.conf'

out=$(
	cd "$ROOT"
	GPU_MODULE=nvidia-drm sh install.sh --dry-run --user screwy
)
assert_contains "$out" 'would set kld_list="nvidia-drm" in /etc/rc.conf'
assert_contains "$out" 'would set hw.nvidiadrm.modeset="1" in /boot/loader.conf'

out=$(
	cd "$ROOT"
	PATH="$fakebin:$PATH" FAKE_GPU=intel sh install.sh --dry-run --user screwy
)
assert_contains "$out" 'drm-kmod'
assert_contains "$out" 'would set kld_list="i915kms" in /etc/rc.conf'

out=$(
	cd "$ROOT"
	PATH="$fakebin:$PATH" FAKE_GPU=amd sh install.sh --dry-run --user screwy
)
assert_contains "$out" 'drm-kmod'
assert_contains "$out" 'would set kld_list="amdgpu" in /etc/rc.conf'

out=$(
	cd "$ROOT"
	PATH="$fakebin:$PATH" FAKE_GPU=nvidia sh install.sh --dry-run --user screwy
)
assert_contains "$out" 'nvidia-drm-kmod'
assert_contains "$out" 'would set kld_list="nvidia-drm" in /etc/rc.conf'
assert_contains "$out" 'would set hw.nvidiadrm.modeset="1" in /boot/loader.conf'

printf '%s\n' 'install-sh tests passed'
