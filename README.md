# freebsd-scripts

Personal FreeBSD desktop bootstrap for a GNOME/Niri workstation.

```sh
fetch -o - https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh | sh
```

Guided installer:

```sh
fetch -o - https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh | sh -s -- --bsdinstall-guided --user screwy
```

The guided installer requires an explicit disk choice before ZFS setup.

Installs pkg `latest` plus release-matched kmods, sudo/doas, fish, dev tools, GNOME/GDM, Niri, Xwayland Satellite, Quickshell with staged Noctalia files, Ghostty, browsers, editors, media apps, KDE utilities, PipeWire, fcitx5 Japanese input, screenshot/clipboard tools, fonts, portals, GPU firmware, and desktop hardening defaults.
