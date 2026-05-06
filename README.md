# freebsd-scripts

FreeBSD installation script for Niri + Noctalia and GNOME, plus browsers and other core utils.

```sh
fetch -o - https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh | sh
```

Guided installer:

```sh
fetch -o - https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh | sh -s -- --bsdinstall-guided --user screwy
```

Shorter ISO shell flow:

```sh
fetch https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh
sh install.sh -g -u screwy
```

Installs and configures doas for the desktop user, plus fish, dev tools, GNOME/GDM, Niri, Xwayland Satellite, Quickshell with staged Noctalia files, Ghostty, browsers, Zed from the FreeBSD port package (`zedit`), Vesktop, media apps, KDE utilities, fcitx5 Japanese input, screenshot/clipboard tools, fonts, portals, GPU firmware, and desktop hardening defaults.
