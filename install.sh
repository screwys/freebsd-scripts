#!/bin/sh

set -eu

INSTALL_URL=${INSTALL_URL:-https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh}
TARGET=/
INSTALL_USER=${INSTALL_USER:-}
PKG_BRANCH=${PKG_BRANCH:-latest}
GPU_MODULE=${GPU_MODULE:-auto}
COMPONENTS=${INSTALL_COMPONENTS-'tools dev gnome niri greeter browsers zed media kde apps japanese gpu'}
DRY_RUN=0
VALIDATE_ONLY=0
BSDINSTALL_GUIDED=0
TUI=0
EDITOR_CMD=nano
FAILED_INSTALLS=
# Native FreeBSD support lives on upstream's feat/freebsd branch.
NOCTALIA_REF=77552410fd1ca63811efc8960f11cf4765e0c9b1
GREETD_REF=d6733e983ff7821c3044007d5555345c7553188f
NOCTALIA_GREETER_REF=44337ecba043749c29de6f3d563315b91987a908
INSTALL_SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
INSTALL_PATCH_DIR=${INSTALL_PATCH_DIR:-$INSTALL_SOURCE_DIR/patches}
# This snapshot still includes Vesktop and Electron 40.
APP_PORTS_REF=596ce5964e00f1b40fb5bee30beea9268477a591
LAZYVIM_REF=803bc181d7c0d6d5eeba9274d9be49b287294d99

BASE_PACKAGES='
ca_root_nss
curl
git
jq
doas
nano
fish
'

CORE_PACKAGES='
gh
yq
fastfetch
just
ripgrep
fd-find
bat
eza
fzf
tree
wget
direnv
neovim
lazygit
tree-sitter-cli
unzip
socat
zoxide
starship
yazi
btop
duf
dust
hyperfine
tokei
shfmt
hs-ShellCheck
uv
node
npm
python3
py312-pip
'

DEV_PACKAGES='
gdb
ruff
py312-pipx
android-tools
openjdk25
go
rust
gcc
gmake
cmake
meson
ninja
pkgconf
talloc
openssl
freeglut
patch
lua-language-server
stylua
gopls
rust-analyzer
'

DESKTOP_PACKAGES='
xorg
gdm
ghostty
gnome-keyring
polkit
nautilus
xdg-desktop-portal
xdg-desktop-portal-gnome
xdg-desktop-portal-gtk
qt6ct
libnotify
xdg-user-dirs
xdg-utils
shared-mime-info
gvfs
mesa-demos
mesa-dri
nerd-fonts-jetbrainsmono
noto-basic
noto-emoji
noto-jp
noto-sans
'

NIRI_PACKAGES='
niri
xwayland-satellite
pipewire
wireplumber
upower
bash
freedesktop-sound-theme
wl-clipboard
grim
slurp
wf-recorder
cliphist
wtype
'

BROWSER_PACKAGES='
firefox
librewolf
chromium
'

MEDIA_PACKAGES='
showtime
mpv
vlc
obs-studio
ImageMagick7
tesseract
ffmpeg
gstreamer1
gstreamer1-plugins-all
'

KDE_PACKAGES='
kdeconnect-kde
okular
gwenview
dolphin
kate
konsole
ark
kcalc
plasma6-xdg-desktop-portal-kde
'

APP_PACKAGES='
libreoffice
qbittorrent
syncthing
'

JAPANESE_PACKAGES='
fcitx5
fcitx5-configtool
fcitx5-gtk3
fcitx5-gtk4
fcitx5-qt5
fcitx5-qt6
ja-fcitx5-anthy
'

NOCTALIA_BUILD_PACKAGES='
meson
ninja
pkgconf
wayland
wayland-protocols
libepoxy
freetype2
fontconfig
cairo
pango
harfbuzz
librsvg2-rust
libxkbcommon
glib
libsecret
libsodium
sdbus-cpp
libqalculate
libxml2
md4c
nlohmann-json
tomlplusplus
libical
libinotify
stb
webp
libjxl
libsndfile
'

GREETER_BUILD_PACKAGES='
meson
ninja
pkgconf
wayland
wayland-protocols
wlroots020
libinput
libepoxy
freetype2
fontconfig
cairo
pango
harfbuzz
librsvg2-rust
libxkbcommon
glib
tomlplusplus
nlohmann-json
stb
webp
libxml2
libepoll-shim
seatd
'

log()
{
	printf '%s\n' "==> $*"
}

warn()
{
	printf '%s\n' "warn: $*" >&2
}

die()
{
	printf '%s\n' "error: $*" >&2
	exit 1
}

usage()
{
	cat <<'EOF'
usage: sh install.sh [options]

With no options, install the full setup.

options:
  -u, --user NAME       desktop user to create/configure
  -g, --guided          install FreeBSD from the ISO shell
      --tui             choose components with [X] checkboxes
      --target PATH     configure a mounted root, default: /
  -n, --dry-run         print actions without changing the system
      --validate        check policy JSON and package manifests
  -h, --help            show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-u|--user)
			[ $# -ge 2 ] || die "--user needs a value"
			INSTALL_USER=$2
			shift 2
			;;
		-g|--guided)
			BSDINSTALL_GUIDED=1
			shift
			;;
		--tui)
			TUI=1
			shift
			;;
		--target)
			[ $# -ge 2 ] || die "--target needs a value"
			TARGET=$2
			shift 2
			;;
		-n|--dry-run)
			DRY_RUN=1
			shift
			;;
		--validate)
			VALIDATE_ONLY=1
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done
case "$PKG_BRANCH" in
	latest|quarterly) ;;
	*) die "PKG_BRANCH must be latest or quarterly" ;;
esac

valid_gpu_module()
{
	case "$1" in
		auto|none|i915kms|amdgpu|radeonkms|nvidia-drm|nvidia-modeset|nvidia)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

normalize_gpu_modules()
{
	printf '%s\n' "$1" |
		tr ',' ' ' |
		awk '
			{
				for (i = 1; i <= NF; i++) {
					if (!seen[$i]++) {
						if (out != "") out = out " "
						out = out $i
					}
				}
			}
			END { print out }
		'
}

GPU_MODULE=$(normalize_gpu_modules "$GPU_MODULE")
[ -n "$GPU_MODULE" ] || die "GPU_MODULE needs a value"
for module in $GPU_MODULE; do
	if ! valid_gpu_module "$module"; then
		die "unsupported GPU module: $module"
	fi
done
case " $GPU_MODULE " in
	*" auto "*)
		[ "$GPU_MODULE" = auto ] || die "auto cannot be combined with explicit GPU modules"
		;;
	*" none "*)
		[ "$GPU_MODULE" = none ] || die "none cannot be combined with explicit GPU modules"
		;;
esac

case "$TARGET" in
	/) ;;
	/*) TARGET=${TARGET%/} ;;
	*) die "--target must be an absolute path" ;;
esac

selected()
{
	case " $COMPONENTS " in
		*" $1 "*) return 0 ;;
		*) return 1 ;;
	esac
}

select_components()
{
	command -v bsddialog >/dev/null 2>&1 || die "--tui needs FreeBSD's bsddialog"
	tty -s 2>/dev/null </dev/tty || die "--tui needs an interactive terminal"
	if choices=$(bsddialog --clear --title "FreeBSD desktop setup" \
		--output-fd 3 --separate-output \
		--checklist "Space toggles selections. Basic tools are always installed." \
		0 0 0 \
		tools "CLI tools + Neovim + LazyVim" on \
		dev "Compilers, language servers, Android tools" on \
		gnome "GNOME + Ghostty" on \
		niri "Niri + Noctalia v5 + Ghostty" on \
		greeter "Noctalia login screen" on \
		browsers "Firefox, LibreWolf, Chromium binaries" on \
		zed "Zed editor" on \
		media "Media and recording apps" on \
		kde "KDE utilities" on \
		apps "Office, messaging, and file sharing" on \
		japanese "Japanese input" on \
		gpu "GPU drivers and firmware" on \
		3>&1 1>/dev/tty 2>/dev/tty </dev/tty); then
		COMPONENTS=$(printf '%s\n' "$choices" | tr '\n' ' ')
	else
		status=$?
		case "$status" in
			1|5) log "cancelled"; exit 0 ;;
			*) die "component selection failed" ;;
		esac
	fi
}

resolve_install_user()
{
	[ -n "$INSTALL_USER" ] || INSTALL_USER=$(discover_user || true)
	if [ -z "$INSTALL_USER" ]; then
		if [ "$DRY_RUN" -eq 1 ]; then
			INSTALL_USER=desktop
		else
			printf '%s' "desktop user: " >/dev/tty || die "pass --user NAME"
			IFS= read -r INSTALL_USER </dev/tty || die "could not read desktop user"
		fi
	fi
	case "$INSTALL_USER" in
		''|*[!A-Za-z0-9._-]*) die "--user needs a valid username" ;;
	esac
}

is_freebsd()
{
	[ "$(uname -s 2>/dev/null || true)" = "FreeBSD" ]
}

need_root()
{
	if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
		die "run as root, or use --dry-run/--validate"
	fi
}

target_path()
{
	path=$1
	path=${path#/}
	if [ "$TARGET" = "/" ]; then
		printf '/%s\n' "$path"
	else
		printf '%s/%s\n' "$TARGET" "$path"
	fi
}

ensure_parent()
{
	path=$1
	dir=${path%/*}
	[ "$dir" = "$path" ] && dir=.
	[ "$DRY_RUN" -eq 1 ] && return 0
	mkdir -p "$dir"
}

write_file()
{
	path=$1
	mode=${2:-0644}
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would write $path"
		cat >/dev/null
		return 0
	fi
	ensure_parent "$path"
	_write_file_tmp="${path}.tmp.$$"
	cat >"$_write_file_tmp"
	chmod "$mode" "$_write_file_tmp"
	mv "$_write_file_tmp" "$path"
}

append_unique_line()
{
	file=$1
	line=$2
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would ensure line in $file: $line"
		return 0
	fi
	ensure_parent "$file"
	touch "$file"
	grep -Fqx "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

set_conf_value()
{
	file=$1
	key=$2
	value=$3
	style=${4:-quoted}

	case "$style" in
		plain) line="${key}=${value}" ;;
		quoted) line="${key}=\"${value}\"" ;;
		*) die "bad set_conf_value style: $style" ;;
	esac

	if [ "$DRY_RUN" -eq 1 ]; then
		log "would set $line in $file"
		return 0
	fi

	ensure_parent "$file"
	touch "$file"
	_set_conf_tmp="${file}.tmp.$$"
	awk -v k="$key" -v repl="$line" '
		BEGIN { done = 0 }
		{
			s = $0
			sub(/^[ \t]*/, "", s)
			if (index(s, k "=") == 1) {
				if (!done) print repl
				done = 1
				next
			}
			print
		}
		END {
			if (!done) print repl
		}
	' "$file" >"$_set_conf_tmp"
	mv "$_set_conf_tmp" "$file"
}

set_conf_word_list()
{
	file=$1
	key=$2
	words=$3

	if [ "$DRY_RUN" -eq 1 ]; then
		log "would set $key=\"$words\" in $file"
		return 0
	fi

	ensure_parent "$file"
	touch "$file"
	existing=$(awk -v k="$key" '
		{
			s = $0
			sub(/^[ \t]*/, "", s)
			if (index(s, k "=") == 1) {
				sub(k "=", "", s)
				gsub(/^"/, "", s)
				gsub(/"$/, "", s)
				print s
				exit
			}
		}
	' "$file")

	combined=$(printf '%s\n%s\n' "$existing" "$words" |
		awk '
			{
				for (i = 1; i <= NF; i++) {
					if (!seen[$i]++) {
						if (out != "") out = out " "
						out = out $i
					}
				}
			}
			END { print out }
		')
	set_conf_value "$file" "$key" "$combined"
}

run_in_target()
{
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would run in $TARGET: $*"
		return 0
	fi
	if [ "$TARGET" = "/" ]; then
		/bin/sh -c "$*"
	else
		chroot "$TARGET" /bin/sh -c "$*"
	fi
}

try_install()
{
	install_label=$1
	shift
	if "$@"; then
		return 0
	else
		install_status=$?
		warn "$install_label failed with exit $install_status; continuing"
		if [ -n "$FAILED_INSTALLS" ]; then
			FAILED_INSTALLS="$FAILED_INSTALLS
  $install_label"
		else
			FAILED_INSTALLS="  $install_label"
		fi
	fi
	return 0
}

pciconf_display_devices()
{
	is_freebsd || return 1
	pciconf -lv 2>/dev/null |
		awk '
			BEGIN { RS = ""; ORS = "\n\n" }
			/class[[:space:]]*=[[:space:]]*display/ || /class=0x03/ { print }
		'
}

detect_gpu_modules()
{
	devices=$(pciconf_display_devices || true)
	[ -n "$devices" ] || return 0

	modules=
	if printf '%s\n' "$devices" | grep -F "Intel Corporation" >/dev/null 2>&1; then
		modules="$modules i915kms"
	fi
	if printf '%s\n' "$devices" | grep -E "Advanced Micro Devices|AMD/ATI|ATI Technologies" >/dev/null 2>&1; then
		modules="$modules amdgpu"
	fi
	if printf '%s\n' "$devices" | grep -F "NVIDIA Corporation" >/dev/null 2>&1; then
		modules="$modules nvidia-drm"
	fi

	normalize_gpu_modules "$modules"
}

selected_gpu_modules()
{
	case "$GPU_MODULE" in
		auto)
			detect_gpu_modules
			;;
		none)
			printf '\n'
			;;
		*)
			printf '%s\n' "$GPU_MODULE"
			;;
	esac
}

gpu_package_manifest()
{
	modules=$(selected_gpu_modules || true)
	for module in $modules; do
		case "$module" in
			i915kms|amdgpu|radeonkms)
				printf '%s\n' drm-kmod
				;;
			nvidia-drm)
				printf '%s\n' nvidia-drm-kmod
				;;
			nvidia-modeset|nvidia)
				printf '%s\n' nvidia-driver
				;;
		esac
	done | awk 'NF && !seen[$0]++'
}

package_manifest()
{
	{
		printf '%s\n' "$BASE_PACKAGES"
		if selected gnome || selected niri || selected greeter; then
			printf '%s\n' "$DESKTOP_PACKAGES"
		fi
		for component in $COMPONENTS; do
			case "$component" in
				tools) printf '%s\n' "$CORE_PACKAGES" ;;
				dev) printf '%s\n' "$DEV_PACKAGES" ;;
				gnome) printf '%s\n' gnome-lite gnome-control-center ;;
				niri) printf '%s\n' "$NIRI_PACKAGES" ;;
				browsers) printf '%s\n' "$BROWSER_PACKAGES" ;;
				media) printf '%s\n' "$MEDIA_PACKAGES" ;;
				kde) printf '%s\n' "$KDE_PACKAGES" ;;
				apps) printf '%s\n' "$APP_PACKAGES" ;;
				japanese) printf '%s\n' "$JAPANESE_PACKAGES" ;;
				gpu) gpu_package_manifest ;;
				zed) printf '%s\n' zed-editor ;;
				greeter) ;;
				*) die "unknown component: $component" ;;
			esac
		done
	} | awk 'NF { print $1 }'
}

ensure_pkg_repo()
{
	repo_dir=$(target_path /usr/local/etc/pkg/repos)
	repo_file=$(target_path /usr/local/etc/pkg/repos/FreeBSD.conf)
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would set FreeBSD pkg branch to $PKG_BRANCH"
		return 0
	fi
	mkdir -p "$repo_dir"
	cat >"$repo_file" <<EOF
FreeBSD: {
  url: "pkg+https://pkg.FreeBSD.org/\${ABI}/$PKG_BRANCH",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
}

freebsd_release()
{
	if [ "$TARGET" = "/" ]; then
		freebsd-version -u 2>/dev/null || uname -r
	else
		chroot "$TARGET" /bin/sh -c 'freebsd-version -u 2>/dev/null || uname -r'
	fi
}

kmods_flavor()
{
	release=$(freebsd_release)
	case "$release" in
		14.*-RELEASE*)
			minor=${release#14.}
			minor=${minor%%-*}
			printf 'kmods_%s_%s\n' "$PKG_BRANCH" "$minor"
			;;
		*)
			printf 'kmods_%s\n' "$PKG_BRANCH"
			;;
	esac
}

ensure_kmods_repo()
{
	repo_dir=$(target_path /usr/local/etc/pkg/repos)
	repo_file=$(target_path /usr/local/etc/pkg/repos/kmods.conf)
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would set FreeBSD kmods pkg branch to match $TARGET and $PKG_BRANCH"
		return 0
	fi
	flavor=$(kmods_flavor)
	mkdir -p "$repo_dir"
	cat >"$repo_file" <<EOF
FreeBSD-kmods: {
  url: "pkg+https://pkg.FreeBSD.org/\${ABI}/$flavor",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
}

install_gpu_firmware_kmods()
{
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would install gpu-firmware-* kmods from FreeBSD-kmods"
		return 0
	fi

	try_install "GPU firmware" run_in_target "
set -eu
firmware_pkgs=\$(pkg search -r FreeBSD-kmods -q '^gpu-firmware-.*-kmod-')
failed=0
for firmware_pkg in \$firmware_pkgs; do
	if env ASSUME_ALWAYS_YES=yes pkg install -y -r FreeBSD-kmods \"\$firmware_pkg\"; then
		:
	else
		printf '%s\\n' \"warn: \$firmware_pkg failed; continuing\" >&2
		failed=1
	fi
done
exit \$failed
"
}

install_packages()
{
	if ! is_freebsd && [ "$DRY_RUN" -eq 0 ]; then
		die "package installation must run on FreeBSD"
	fi

	ensure_pkg_repo
	if selected gpu; then
		ensure_kmods_repo
	fi

	try_install "pkg bootstrap" run_in_target "env ASSUME_ALWAYS_YES=yes pkg bootstrap -f"
	try_install "pkg update" run_in_target "env ASSUME_ALWAYS_YES=yes pkg update -f"
	for pkg in $(package_manifest); do
		try_install "$pkg" run_in_target "env ASSUME_ALWAYS_YES=yes pkg install -y $pkg"
	done

	if selected gpu; then
		install_gpu_firmware_kmods
	fi
}

install_ports()
{
	ports_ref=$1
	app_ports=$2
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would build and install $app_ports from FreeBSD ports revision $ports_ref"
		return 0
	fi

	set -- /bin/sh -s -- "$ports_ref" "$app_ports"
	if [ "$TARGET" != "/" ]; then
		set -- chroot "$TARGET" "$@"
	fi
	try_install "FreeBSD ports: $app_ports" "$@" <<'EOF'
set -eu
set -f
ref=$1
app_ports=$2
build_root=$(mktemp -d)
trap 'rm -rf "$build_root"' EXIT HUP INT TERM
git init "$build_root/ports"
git -C "$build_root/ports" remote add origin https://github.com/freebsd/freebsd-ports.git
git -C "$build_root/ports" fetch --depth 1 origin "$ref"
git -C "$build_root/ports" checkout --detach FETCH_HEAD
failed_ports=
for origin in $app_ports; do
	if make -C "$build_root/ports/$origin" PORTSDIR="$build_root/ports" \
		BATCH=yes USE_PACKAGE_DEPENDS=yes install clean; then
		:
	else
		printf '%s\n' "warn: $origin failed; continuing" >&2
		failed_ports="$failed_ports $origin"
	fi
done
if [ -n "$failed_ports" ]; then
	printf '%s\n' "warn: failed app ports:$failed_ports" >&2
	exit 1
fi
EOF
}

install_greetd()
{
	selected greeter || return 0
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would build and install greetd revision $GREETD_REF for FreeBSD"
		return 0
	fi
	set -- /bin/sh -s -- "$GREETD_REF" "$INSTALL_PATCH_DIR/greetd-freebsd.patch" \
		"${INSTALL_URL%/*}/patches/greetd-freebsd.patch"
	if [ "$TARGET" != "/" ]; then
		set -- chroot "$TARGET" "$@"
	fi
	try_install "greetd" "$@" <<'EOF'
set -eu
env ASSUME_ALWAYS_YES=yes pkg install -y rust
build_root=$(mktemp -d)
trap 'rm -rf "$build_root"' EXIT HUP INT TERM
git init "$build_root/source"
git -C "$build_root/source" remote add origin https://github.com/kennylevinsen/greetd.git
git -C "$build_root/source" fetch --depth 1 origin "$1"
git -C "$build_root/source" checkout --detach FETCH_HEAD
patch_file=$2
if [ ! -r "$patch_file" ]; then
	patch_file="$build_root/freebsd.patch"
	fetch -o "$patch_file" "$3"
fi
git -C "$build_root/source" apply "$patch_file"
cd "$build_root/source"
cargo build --locked --release -p greetd -p agreety -j "${BUILD_JOBS:-2}"
install -m 0755 target/release/greetd target/release/agreety /usr/local/bin/
EOF
}

install_noctalia_greeter()
{
	selected greeter || return 0
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would build and install Noctalia Greeter revision $NOCTALIA_GREETER_REF for FreeBSD"
		return 0
	fi
	set -- /bin/sh -s -- "$NOCTALIA_GREETER_REF" "$GREETER_BUILD_PACKAGES" \
		"$INSTALL_PATCH_DIR/noctalia-greeter-freebsd.patch" \
		"${INSTALL_URL%/*}/patches/noctalia-greeter-freebsd.patch"
	if [ "$TARGET" != "/" ]; then
		set -- chroot "$TARGET" "$@"
	fi
	try_install "Noctalia Greeter" "$@" <<'EOF'
set -eu
set -f
# shellcheck disable=SC2086
env ASSUME_ALWAYS_YES=yes pkg install -y $2
build_root=$(mktemp -d)
trap 'rm -rf "$build_root"' EXIT HUP INT TERM
git init "$build_root/source"
git -C "$build_root/source" remote add origin https://github.com/noctalia-dev/noctalia-greeter.git
git -C "$build_root/source" fetch --depth 1 origin "$1"
git -C "$build_root/source" checkout --detach FETCH_HEAD
patch_file=$3
if [ ! -r "$patch_file" ]; then
	patch_file="$build_root/freebsd.patch"
	fetch -o "$patch_file" "$4"
fi
git -C "$build_root/source" apply "$patch_file"
meson setup "$build_root/build" "$build_root/source" --prefix=/usr/local --buildtype=plain
meson compile -C "$build_root/build" -j "${BUILD_JOBS:-2}"
meson install -C "$build_root/build"
EOF
}

configure_rc_conf()
{
	rc=$(target_path /etc/rc.conf)

	set_conf_value "$rc" dbus_enable YES
	if selected gnome || selected niri || selected greeter; then
		set_conf_value "$rc" gdm_enable YES
		set_conf_value "$rc" xdg_runtime_base_enable YES
	fi
	if selected niri || selected greeter; then
		set_conf_value "$rc" seatd_enable YES
	fi
	set_conf_value "$rc" powerd_enable YES
	set_conf_value "$rc" ntpd_enable YES
	set_conf_value "$rc" ntpd_sync_on_start YES
	set_conf_value "$rc" zfs_enable YES
	set_conf_value "$rc" sshd_enable NO
	set_conf_value "$rc" clear_tmp_enable YES
	set_conf_value "$rc" syslogd_flags -ss
	set_conf_value "$rc" sendmail_enable NONE
	set_conf_value "$rc" sendmail_submit_enable NO
	set_conf_value "$rc" sendmail_outbound_enable NO
	set_conf_value "$rc" sendmail_msp_queue_enable NO
	set_conf_value "$rc" dumpdev NO
}

configure_gpu_driver()
{
	selected gpu || return 0
	modules=$(selected_gpu_modules || true)
	if [ -z "$modules" ]; then
		if [ "$GPU_MODULE" = auto ]; then
			warn "could not auto-detect a GPU module; set GPU_MODULE to choose a driver"
		fi
		return 0
	fi

	case " $modules " in
		*" amdgpu "*)
			if [ "$GPU_MODULE" = auto ]; then
				warn "auto-selected amdgpu; set GPU_MODULE=radeonkms for older pre-HD7000/Tahiti Radeon hardware"
			fi
			;;
	esac

	set_conf_word_list "$(target_path /etc/rc.conf)" kld_list "$modules"

	case " $modules " in
		*" nvidia-drm "*)
			set_conf_value "$(target_path /boot/loader.conf)" hw.nvidiadrm.modeset 1
			;;
	esac
}

configure_hardening()
{
	sysctl_file=$(target_path /etc/sysctl.conf)
	loader_file=$(target_path /boot/loader.conf)

	set_conf_value "$sysctl_file" security.bsd.see_other_uids 0 plain
	set_conf_value "$sysctl_file" security.bsd.see_other_gids 0 plain
	set_conf_value "$sysctl_file" security.bsd.see_jail_proc 0 plain
	set_conf_value "$sysctl_file" security.bsd.unprivileged_read_msgbuf 0 plain
	set_conf_value "$sysctl_file" security.bsd.unprivileged_proc_debug 0 plain
	set_conf_value "$sysctl_file" kern.randompid 1 plain
	set_conf_value "$loader_file" security.bsd.allow_destructive_dtrace 0
}

configure_mounts()
{
	fstab=$(target_path /etc/fstab)
	append_unique_line "$fstab" "proc	/proc	procfs	rw	0	0"

	if [ "$DRY_RUN" -eq 1 ]; then
		log "would create /var/run/user with mode 1777"
	else
		mkdir -p "$(target_path /var/run/user)"
		chmod 1777 "$(target_path /var/run/user)"
	fi
}

configure_doas_and_editor()
{
	doas_file=$(target_path /usr/local/etc/doas.conf)
	profile_file=$(target_path /usr/local/etc/profile.d/freebsd-scripts.sh)

	write_file "$doas_file" 0600 <<'EOF'
permit persist :wheel
EOF

	{
		printf 'export EDITOR=%s\nexport VISUAL=%s\n' "$EDITOR_CMD" "$EDITOR_CMD"
		cat <<'EOF'
export PAGER=${PAGER:-less}
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	XDG_RUNTIME_DIR="/var/run/user/$(id -u)"
	export XDG_RUNTIME_DIR
	if [ ! -d "$XDG_RUNTIME_DIR" ]; then
		mkdir -p -m 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
	fi
	chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
EOF
	} | write_file "$profile_file" 0644
}

configure_xdg_runtime_rc()
{
	rc_script=$(target_path /usr/local/etc/rc.d/xdg_runtime_base)
	write_file "$rc_script" 0755 <<'EOF'
#!/bin/sh

# PROVIDE: xdg_runtime_base
# REQUIRE: LOGIN
# BEFORE: gdm greetd

. /etc/rc.subr

name=xdg_runtime_base
rcvar=xdg_runtime_base_enable
start_cmd="${name}_start"

: ${xdg_runtime_base_enable:=NO}

xdg_runtime_base_start()
{
	install -d -m 1777 /var/run/user
}

load_rc_config $name
run_rc_command "$1"
EOF
}

configure_niri_session()
{
	session_bin=$(target_path /usr/local/bin/freebsd-niri-session)
	session_desktop=$(target_path /usr/local/share/wayland-sessions/niri.desktop)

	write_file "$session_bin" 0755 <<'EOF'
#!/bin/sh

export XDG_CURRENT_DESKTOP=niri
export XDG_SESSION_DESKTOP=niri
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland,x11

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	export XDG_RUNTIME_DIR="/var/run/user/$(id -u)"
	mkdir -p -m 700 "$XDG_RUNTIME_DIR"
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	exec dbus-run-session -- /usr/local/bin/niri --session
fi
exec /usr/local/bin/niri --session
EOF

	write_file "$session_desktop" 0644 <<'EOF'
[Desktop Entry]
Name=Niri
Comment=Run Niri
Exec=/usr/local/bin/freebsd-niri-session
Type=Application
DesktopNames=niri
EOF
}

configure_greeter()
{
	selected greeter || return 0

	write_file "$(target_path /usr/local/etc/greetd/config.toml)" 0644 <<'EOF'
[terminal]
vt = 9

[general]
source_profile = true
runfile = "/var/run/greetd.run"
service = "greetd"

[default_session]
command = "/usr/local/bin/freebsd-noctalia-greeter-session"
user = "greetd"
service = "greetd-greeter"
EOF

	write_file "$(target_path /etc/pam.d/greetd)" 0644 <<'EOF'
auth      requisite pam_nologin.so
auth      include   system
account   include   system
session   include   system
password  include   system
EOF

	write_file "$(target_path /etc/pam.d/greetd-greeter)" 0644 <<'EOF'
auth      required  pam_permit.so
account   include   system
session   include   system
EOF

	write_file "$(target_path /usr/local/bin/freebsd-noctalia-greeter-session)" 0755 <<'EOF'
#!/bin/sh
set -eu
export GREETD_CONFIG=/usr/local/etc/greetd/config.toml
export GREETER_USER=greetd
exec /usr/local/bin/noctalia-greeter-session "$@"
EOF

	write_file "$(target_path /usr/local/etc/rc.d/greetd)" 0755 <<'EOF'
#!/bin/sh

# PROVIDE: greetd
# REQUIRE: LOGIN dbus seatd xdg_runtime_base
# KEYWORD: shutdown

. /etc/rc.subr

name=greetd
rcvar=greetd_enable
command=/usr/sbin/daemon
procname=/usr/local/bin/greetd
pidfile=/var/run/greetd.pid
command_args="-p $pidfile -f -S -T greetd /usr/local/bin/greetd -c /usr/local/etc/greetd/config.toml"

load_rc_config $name
: ${greetd_enable:=NO}
run_rc_command "$1"
EOF

	greeter_config=$(target_path /var/lib/noctalia-greeter/greeter.toml)
	if [ ! -e "$greeter_config" ]; then
		write_file "$greeter_config" 0644 <<'EOF'
[session]
default = "Niri"
EOF
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		log "would create greetd account and prepare Noctalia Greeter state"
	else
		if ! user_record greetd >/dev/null 2>&1; then
			run_in_target "pw useradd greetd -m -d /var/lib/greetd -s /usr/sbin/nologin -c 'Noctalia Greeter'"
		fi
		for group in video operator seatd _seatd; do
			if group_exists "$group"; then
				run_in_target "pw groupmod '$group' -m greetd"
			fi
		done
		greeter_uid=$(user_field greetd 3)
		greeter_gid=$(user_field greetd 4)
		mkdir -p "$(target_path /var/lib/greetd)" "$(target_path /var/lib/noctalia-greeter)"
		chown "$greeter_uid:$greeter_gid" "$(target_path /var/lib/greetd)" \
			"$(target_path /var/lib/noctalia-greeter)" "$greeter_config"
	fi

	# Keep the existing login manager when a greeter build failed.
	if [ "$DRY_RUN" -eq 1 ] ||
		{ [ -x "$(target_path /usr/local/bin/greetd)" ] &&
		  [ -x "$(target_path /usr/local/bin/noctalia-greeter)" ] &&
		  [ -x "$(target_path /usr/local/bin/noctalia-greeter-compositor)" ]; }; then
		set_conf_value "$(target_path /etc/rc.conf)" greetd_enable YES
		set_conf_value "$(target_path /etc/rc.conf)" gdm_enable NO
		if [ "$DRY_RUN" -eq 1 ]; then
			log "would disable getty on ttyv8 for Noctalia Greeter"
		else
			ttys=$(target_path /etc/ttys)
			ttys_tmp="$ttys.tmp.$$"
			awk '
				$1 == "ttyv8" {
					for (i = 2; i <= NF; i++) {
						if ($i == "on" || $i == "onifexists" || $i == "onifconsole") $i = "off"
					}
				}
				{ print }
			' "$ttys" >"$ttys_tmp"
			mv "$ttys_tmp" "$ttys"
		fi
	else
		warn "Noctalia Greeter is not installed; keeping GDM enabled"
	fi
}

passwd_file()
{
	target_path /etc/passwd
}

group_file()
{
	target_path /etc/group
}

discover_user()
{
	[ -f "$(passwd_file)" ] || return 1
	awk -F: '$3 >= 1000 && $6 ~ /^\/(usr\/)?home\// { print $1; exit }' "$(passwd_file)"
}

user_record()
{
	user=$1
	[ -f "$(passwd_file)" ] || return 1
	awk -F: -v u="$user" '$1 == u { print; found = 1; exit } END { exit found ? 0 : 1 }' "$(passwd_file)"
}

group_exists()
{
	group=$1
	[ -f "$(group_file)" ] || return 1
	awk -F: -v g="$group" '$1 == g { found = 1; exit } END { exit found ? 0 : 1 }' "$(group_file)"
}

existing_groups_csv()
{
	out=
	for group in wheel operator video webcamd seatd _seatd; do
		if group_exists "$group"; then
			if [ -n "$out" ]; then
				out="$out,$group"
			else
				out=$group
			fi
		fi
	done
	printf '%s\n' "$out"
}

ensure_user()
{
	if user_record "$INSTALL_USER" >/dev/null 2>&1; then
		log "configuring existing user $INSTALL_USER"
	else
		groups=$(existing_groups_csv)
		shell=/bin/sh
		if [ "$DRY_RUN" -eq 1 ] || [ -x "$(target_path /usr/local/bin/fish)" ]; then
			shell=/usr/local/bin/fish
		fi
		cmd="pw useradd '$INSTALL_USER' -m -s '$shell'"
		[ -n "$groups" ] && cmd="$cmd -G '$groups'"
		run_in_target "$cmd"
		if [ "$DRY_RUN" -eq 0 ]; then
			warn "set a password for $INSTALL_USER"
			if [ "$TARGET" = "/" ]; then
				passwd "$INSTALL_USER"
			else
				chroot "$TARGET" passwd "$INSTALL_USER"
			fi
		fi
	fi

	for group in wheel operator video webcamd seatd _seatd; do
		if [ "$DRY_RUN" -eq 1 ] || group_exists "$group"; then
			run_in_target "pw groupmod '$group' -m '$INSTALL_USER'"
		fi
	done

	if [ "$DRY_RUN" -eq 1 ] || [ -x "$(target_path /usr/local/bin/fish)" ]; then
		run_in_target "pw usermod '$INSTALL_USER' -s /usr/local/bin/fish"
	fi
}

user_field()
{
	user=$1
	field=$2
	record=$(user_record "$user" 2>/dev/null || true)
	if [ -n "$record" ]; then
		printf '%s\n' "$record" | awk -F: -v f="$field" '{ print $f }'
		return 0
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		case "$field" in
			3|4) printf '%s\n' 1001 ;;
			6) printf '/home/%s\n' "$user" ;;
			*) printf '\n' ;;
		esac
		return 0
	fi

	return 1
}

user_path()
{
	home=$1
	rel=$2
	path="${home%/}/$rel"
	if [ "$TARGET" = "/" ]; then
		printf '%s\n' "$path"
	else
		printf '%s/%s\n' "$TARGET" "${path#/}"
	fi
}

write_user_file()
{
	user=$1
	rel=$2
	mode=$3
	home=$(user_field "$user" 6)
	uid=$(user_field "$user" 3)
	gid=$(user_field "$user" 4)
	path=$(user_path "$home" "$rel")

	write_file "$path" "$mode"

	if [ "$DRY_RUN" -eq 0 ]; then
		chown "$uid:$gid" "$(user_path "$home" .config)" "${path%/*}" "$path"
	fi
}

configure_user_files()
{
	{
		printf 'set -gx EDITOR %s\nset -gx VISUAL %s\n' "$EDITOR_CMD" "$EDITOR_CMD"
		cat <<'EOF'
set -g fish_greeting
set -gx PAGER less

if test -z "$XDG_RUNTIME_DIR"
    set -gx XDG_RUNTIME_DIR /var/run/user/(id -u)
    mkdir -p -m 700 "$XDG_RUNTIME_DIR" 2>/dev/null
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
end

if command -q zoxide
    zoxide init fish | source
end

if command -q yazi
    function y
        set -l tmp (mktemp)
        command yazi $argv --cwd-file="$tmp"
        if read -z cwd < "$tmp"; and test "$cwd" != "$PWD"; and test -d "$cwd"
            builtin cd -- "$cwd"
        end
        command rm -f -- "$tmp"
    end
end

if status is-interactive
    if command -q starship
        starship init fish | source
    end
    if command -q direnv
        direnv hook fish | source
    end
    if command -q fzf
        fzf --fish | source
    end
end
EOF
	} | write_user_file "$INSTALL_USER" .config/fish/config.fish 0644

	if selected gnome || selected niri; then
		write_user_file "$INSTALL_USER" .config/ghostty/config 0644 <<'EOF'
font-family = JetBrainsMono Nerd Font
command = /usr/local/bin/fish
confirm-close-surface = false
copy-on-select = clipboard
EOF
	fi

	selected niri || return 0

	{
		cat <<'EOF'
environment {
    SHELL "/usr/local/bin/fish"
EOF
		printf '    EDITOR "%s"\n    VISUAL "%s"\n' "$EDITOR_CMD" "$EDITOR_CMD"
		cat <<'EOF'
    XDG_CURRENT_DESKTOP "niri"
    XDG_SESSION_TYPE "wayland"
    QT_QPA_PLATFORM "wayland"
    QT_QPA_PLATFORMTHEME "qt6ct"
    GDK_BACKEND "wayland,x11"
EOF
		if selected japanese; then
			cat <<'EOF'
    GTK_IM_MODULE "fcitx"
    QT_IM_MODULE "fcitx"
    XMODIFIERS "@im=fcitx"
EOF
		fi
		cat <<'EOF'
}

input {
    keyboard {
        xkb {
            layout "us"
        }
    }
    touchpad {
        tap
        natural-scroll
    }
}

layout {
    gaps 16
    center-focused-column "never"
    background-color "transparent"
    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }
    default-column-width { proportion 0.5; }
    focus-ring { width 3; }
    border { off; }
}

layer-rule {
    match namespace="^noctalia-wallpaper.*"
    place-within-backdrop true
}

spawn-at-startup "dbus-update-activation-environment" "DISPLAY" "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP" "XDG_SESSION_TYPE" "XDG_RUNTIME_DIR"
spawn-at-startup "gnome-keyring-daemon" "--start" "--components=secrets"
EOF
		if selected japanese; then
			printf '%s\n' 'spawn-at-startup "fcitx5" "-d"'
		fi
		cat <<'EOF'
// The FreeBSD WirePlumber package starts its daemon with PipeWire.
spawn-at-startup "pipewire"
spawn-at-startup "noctalia"

prefer-no-csd
screenshot-path "~/Pictures/Screenshots/%Y-%m-%d_%H-%M-%S.png"

binds {
    Mod+Return { spawn "ghostty"; }
EOF
		if selected browsers; then
			printf '%s\n' '    Mod+B { spawn "librewolf"; }'
		fi
		cat <<'EOF'
    Mod+E { spawn "nautilus"; }
    Mod+D { spawn "noctalia" "msg" "panel-toggle" "launcher"; }
    Mod+V { spawn "noctalia" "msg" "panel-toggle" "clipboard"; }
    Mod+Comma { spawn "noctalia" "msg" "settings-toggle"; }
    Mod+Alt+L { spawn "noctalia" "msg" "session" "lock"; }
    Mod+Escape { spawn "noctalia" "msg" "panel-toggle" "session"; }
    Mod+Q { close-window; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+H { focus-column-left; }
    Mod+L { focus-column-right; }
    Mod+J { focus-window-down; }
    Mod+K { focus-window-up; }
    Mod+Shift+H { move-column-left; }
    Mod+Shift+L { move-column-right; }
    Mod+Shift+J { move-window-down; }
    Mod+Shift+K { move-window-up; }
    Print { spawn "sh" "-c" "grim -g \"$(slurp)\" - | wl-copy"; }
    XF86AudioRaiseVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-up"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-down"; }
    XF86AudioMute allow-when-locked=true { spawn "noctalia" "msg" "volume-mute"; }
    XF86AudioMicMute allow-when-locked=true { spawn "noctalia" "msg" "mic-mute"; }
    XF86AudioPlay allow-when-locked=true { spawn "noctalia" "msg" "media" "toggle"; }
    XF86AudioPrev allow-when-locked=true { spawn "noctalia" "msg" "media" "previous"; }
    XF86AudioNext allow-when-locked=true { spawn "noctalia" "msg" "media" "next"; }
    Mod+Shift+E { quit; }
}
EOF
	} | write_user_file "$INSTALL_USER" .config/niri/config.kdl 0644
}

install_noctalia()
{
	selected niri || return 0

	if [ "$DRY_RUN" -eq 1 ]; then
		log "would build and install Noctalia v5 revision $NOCTALIA_REF in $TARGET"
		log "source build packages: $(printf '%s' "$NOCTALIA_BUILD_PACKAGES" | tr '\n' ' ')"
		return 0
	fi

	log "building Noctalia v5 upstream FreeBSD revision $NOCTALIA_REF"
	set -- /bin/sh -s -- "$NOCTALIA_REF" "$NOCTALIA_BUILD_PACKAGES"
	set -- "$@" "$INSTALL_PATCH_DIR/noctalia-freebsd-runtime.patch" \
		"${INSTALL_URL%/*}/patches/noctalia-freebsd-runtime.patch"
	if [ "$TARGET" != "/" ]; then
		set -- chroot "$TARGET" "$@"
	fi
	try_install "Noctalia v5" "$@" <<'EOF'
set -eu
set -f
ref=$1
build_packages=$2
# These names form the package list, not a single pkg argument.
# shellcheck disable=SC2086
env ASSUME_ALWAYS_YES=yes pkg install -y $build_packages

build_root=$(mktemp -d)
trap 'rm -rf "$build_root"' EXIT HUP INT TERM
git init "$build_root/source"
git -C "$build_root/source" remote add origin https://github.com/noctalia-dev/noctalia.git
git -C "$build_root/source" fetch --depth 1 origin "$ref"
git -C "$build_root/source" checkout --detach FETCH_HEAD
patch_file=$3
if [ ! -r "$patch_file" ]; then
	patch_file="$build_root/freebsd.patch"
	fetch -o "$patch_file" "$4"
fi
git -C "$build_root/source" apply "$patch_file"
meson setup "$build_root/build" "$build_root/source" --prefix=/usr/local \
	--buildtype=release -Dtests=disabled -Djemalloc=disabled
meson compile -C "$build_root/build" -j "${BUILD_JOBS:-2}"
meson install -C "$build_root/build"
EOF
}

configure_noctalia()
{
	selected niri || return 0

	home=$(user_field "$INSTALL_USER" 6)
	config=$(user_path "$home" .config/noctalia/config.toml)
	# Seed v5 defaults once. Later runs keep the user's TOML and GUI settings.
	if [ ! -e "$config" ]; then
		write_user_file "$INSTALL_USER" .config/noctalia/config.toml 0644 <<'EOF'
[plugins]
auto_update = "none"
enabled = [
    "noctalia/notes",
    "noctalia/screen_recorder",
    "noctalia/kaomoji",
    "noctalia/wallhaven",
]

[[plugins.source]]
kind = "git"
location = "https://github.com/noctalia-dev/official-plugins"
name = "official"

[[plugins.source]]
kind = "git"
location = "https://github.com/noctalia-dev/community-plugins"
name = "community"

[shell]
polkit_agent = true

[shell.greeter_sync]
auto_sync = false

[theme.templates]
builtin_ids = ["niri"]

[wallpaper]
directory = "~/Pictures"
fill_mode = "crop"
EOF
	fi
}

configure_lazyvim()
{
	selected tools || return 0
	home=$(user_field "$INSTALL_USER" 6)
	config=$(user_path "$home" .config/nvim)
	if [ -e "$config" ]; then
		log "keeping existing Neovim config for $INSTALL_USER"
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would install LazyVim starter revision $LAZYVIM_REF for $INSTALL_USER"
		return 0
	fi

	uid=$(user_field "$INSTALL_USER" 3)
	gid=$(user_field "$INSTALL_USER" 4)
	set -- /bin/sh -s -- "$home" "$uid:$gid" "$LAZYVIM_REF"
	if [ "$TARGET" != "/" ]; then
		set -- chroot "$TARGET" "$@"
	fi
	try_install "LazyVim starter" "$@" <<'EOF'
set -eu
home=$1
owner=$2
ref=$3
mkdir -p "$home/.config"
seed=$(mktemp -d "$home/.config/.nvim.XXXXXX")
trap 'rm -rf "$seed"' EXIT HUP INT TERM
git init "$seed"
git -C "$seed" remote add origin https://github.com/LazyVim/starter.git
git -C "$seed" fetch --depth 1 origin "$ref"
git -C "$seed" checkout --detach FETCH_HEAD
rm -rf "$seed/.git"
chown -R "$owner" "$seed"
chown "$owner" "$home/.config"
mv "$seed" "$home/.config/nvim"
EOF
}

write_firefox_policy()
{
	path=$1
	write_file "$path" 0644 <<'EOF'
{
  "policies": {
    "DisableAppUpdate": false,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableTelemetry": true,
    "DontCheckDefaultBrowser": true,
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi",
        "private_browsing": true
      },
      "jid1-BoFifL9Vbdl2zQ@jetpack": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/decentraleyes/latest.xpi",
        "private_browsing": true
      },
      "78272b6fa58f4a1abaac99321d503a20@proton.me": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/proton-pass/latest.xpi",
        "private_browsing": true
      },
      "vpn@proton.ch": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/proton-vpn-firefox-extension/latest.xpi",
        "private_browsing": true
      }
    },
    "FirefoxHome": {
      "Highlights": false,
      "Pocket": false,
      "Search": true,
      "Snippets": false,
      "SponsoredPocket": false,
      "SponsoredTopSites": false,
      "TopSites": true
    },
    "FirefoxSuggest": {
      "ImproveSuggest": false,
      "SponsoredSuggestions": false,
      "WebSuggestions": false
    },
    "NoDefaultBookmarks": true,
    "OfferToSaveLoginsDefault": false,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "SearchEngines": {
      "Default": "DuckDuckGo",
      "Add": [
        {
          "Name": "DuckDuckGo",
          "URLTemplate": "https://duckduckgo.com/?q={searchTerms}",
          "Method": "GET",
          "IconURL": "https://duckduckgo.com/favicon.ico",
          "Alias": "@ddg",
          "SuggestURLTemplate": ""
        }
      ]
    },
    "SearchSuggestEnabled": false,
    "SkipTermsOfUse": true,
    "UserMessaging": {
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "MoreFromMozilla": false,
      "SkipOnboarding": true,
      "UrlbarInterventions": false
    }
  }
}
EOF
}

write_browser_policies()
{
	write_firefox_policy "$(target_path /usr/local/lib/firefox/distribution/policies.json)"
	write_firefox_policy "$(target_path /usr/local/lib/librewolf/distribution/policies.json)"
	write_firefox_policy "$(target_path /usr/local/share/librewolf/distribution/policies.json)"
}
validate_json_files()
{
	root=$1
	files=$(find "$root" -name '*.json' -type f | sort)
	[ -n "$files" ] || die "no JSON files generated"

	if command -v python3 >/dev/null 2>&1; then
		python3 - "$root" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted(root.rglob("*.json")):
    with path.open("r", encoding="utf-8") as handle:
        json.load(handle)
    print(path.relative_to(root))
PY
	elif command -v jq >/dev/null 2>&1; then
		for file in $files; do
			jq empty "$file"
			printf '%s\n' "${file#$root/}"
		done
	else
		die "python3 or jq is required to validate JSON"
	fi
}

validate_manifest()
{
	for component in $COMPONENTS; do
		case "$component" in
			tools|dev|gnome|niri|greeter|browsers|zed|media|kde|apps|japanese|gpu) ;;
			*) die "unknown component: $component" ;;
		esac
	done
	dupes=$(package_manifest | sort | uniq -d)
	if [ -n "$dupes" ]; then
		printf '%s\n' "$dupes" >&2
		die "package manifest contains duplicates"
	fi

	printf '%s\n%s\n%s\n' "$(package_manifest)" "$NOCTALIA_BUILD_PACKAGES" "$GREETER_BUILD_PACKAGES" | awk '
		!NF { next }
		$0 !~ /^[A-Za-z0-9_.+@-]+$/ {
			printf "bad package name: %s\n", $0 > "/dev/stderr"
			bad = 1
		}
		END { exit bad ? 1 : 0 }
	'
}

validate_only()
{
	validate_manifest
	validate_root=$(mktemp -d)
	old_target=$TARGET
	old_dry=$DRY_RUN
	TARGET=$validate_root
	DRY_RUN=0
	write_browser_policies >/dev/null
	validate_json_files "$validate_root"
	TARGET=$old_target
	DRY_RUN=$old_dry
	rm -rf "$validate_root"
	log "validation passed"
}

select_install_disk()
{
	if ! is_freebsd; then
		die "--guided must be run from the FreeBSD installer"
	fi
	if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
		die "--guided needs an interactive tty"
	fi

	disks=$(sysctl -n kern.disks 2>/dev/null || true)
	[ -n "$disks" ] || die "could not discover disks from kern.disks"

	printf '%s\n' "available disks:" >/dev/tty
	for disk in $disks; do
		printf '  %s\n' "$disk" >/dev/tty
	done

	printf '%s' "disk to install FreeBSD on: " >/dev/tty
	IFS= read -r disk </dev/tty
	case " $disks " in
		*" $disk "*) ;;
		*) die "disk '$disk' is not in kern.disks" ;;
	esac

	printf '%s\n' "this will let bsdinstall create a ZFS layout on $disk." >/dev/tty
	printf '%s\n' "bsdinstall will show its own final destructive confirmation too." >/dev/tty
	printf '%s' "type the disk name again to continue: " >/dev/tty
	IFS= read -r confirm </dev/tty
	[ "$confirm" = "$disk" ] || die "confirmation did not match"

	printf '%s\n' "$disk"
}

write_bsdinstall_config()
{
	cfg=$1
	disk=$2
	install_args="--user $INSTALL_USER"

	cat >"$cfg" <<EOF
DISTRIBUTIONS="kernel.txz base.txz"
export ZFSBOOT_DISKS="$disk"
export ZFSBOOT_VDEV_TYPE="stripe"
export ZFSBOOT_SWAP_SIZE="2g"
export ZFSBOOT_CONFIRM_LAYOUT="1"

#!/bin/sh
set -eu

export INSTALL_COMPONENTS="$COMPONENTS"
export PKG_BRANCH="$PKG_BRANCH"
export GPU_MODULE="$GPU_MODULE"

if command -v fetch >/dev/null 2>&1; then
	fetch -o /tmp/freebsd-install.sh "$INSTALL_URL"
else
	curl -L -o /tmp/freebsd-install.sh "$INSTALL_URL"
fi

sh /tmp/freebsd-install.sh $install_args
EOF
}

run_bsdinstall_guided()
{
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then
		cfg=$(mktemp)
		write_bsdinstall_config "$cfg" "DISK_YOU_CONFIRM"
		log "would prompt for a disk and run: bsdinstall script $cfg"
		cat "$cfg"
		rm -f "$cfg"
		return 0
	fi

	disk=$(select_install_disk)
	cfg=$(mktemp /tmp/freebsd-scripts-bsdinstall.XXXXXX)
	write_bsdinstall_config "$cfg" "$disk"
	log "running bsdinstall script $cfg"
	bsdinstall script "$cfg"
}

main()
{
	if [ "$TUI" -eq 1 ]; then
		select_components
	fi

	if [ "$VALIDATE_ONLY" -eq 1 ]; then
		validate_only
		return 0
	fi

	validate_manifest
	resolve_install_user
	if selected tools; then
		EDITOR_CMD=nvim
	fi

	if [ "$BSDINSTALL_GUIDED" -eq 1 ]; then
		run_bsdinstall_guided
		return 0
	fi

	need_root

	install_packages
	if selected apps; then
		install_ports "$APP_PORTS_REF" "net-im/signal-desktop net-im/vesktop"
	fi
	install_noctalia
	install_greetd
	install_noctalia_greeter
	configure_rc_conf
	configure_gpu_driver
	configure_hardening
	configure_mounts
	configure_doas_and_editor
	if selected gnome || selected niri || selected greeter; then
		configure_xdg_runtime_rc
	fi
	if selected niri; then
		configure_niri_session
	fi
	if selected browsers; then
		write_browser_policies
	fi
	ensure_user
	configure_user_files
	configure_lazyvim
	configure_noctalia
	configure_greeter

	if [ -n "$FAILED_INSTALLS" ]; then
		log "finished with install failures:"
		printf '%s\n' "$FAILED_INSTALLS"
	else
		log "done"
	fi
	if selected gnome || selected niri || selected greeter; then
		log "reboot, then choose your desktop at the login screen"
	fi
}

main "$@"
