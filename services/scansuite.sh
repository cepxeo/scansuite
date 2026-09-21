#!/bin/bash
#
# First-run bootstrap: the script a new client runs in the folder holding the
# licence file they were sent.  It clones the installation repository, puts the
# licence in place and hands over to ./scansuite.
#
# CLIENT_REPO and APP_DIR below are filled in by build.sh from the product
# manifest; do not edit them here.

set -uo pipefail

REPO="https://github.com/cepxeo/scansuite"
# An absolute path, or one relative to the home directory (the product decides).
APP_DIR="/opt/scansuite"
case "$APP_DIR" in /*) ;; *) APP_DIR="$HOME/$APP_DIR" ;; esac

if ! ls ./*.lic >/dev/null 2>&1; then
    echo "No licence file (*.lic) in this folder. Copy the one sent with your"
    echo "order next to this script and run it again."
    exit 1
fi

for file in ./*.lic; do
    code=$(basename "$file" | sed 's/.*_\(.*\)\.lic$/\1/')
    if [ "${#code}" -ne 6 ]; then
        echo "Unexpected licence file name: $(basename "$file")"
        echo "It should look like <name>_<6 character code>.lic"
        exit 1
    fi
    lic_path=$(realpath "$file")

    # Under /opt only root can write. Create the directory once and hand it to
    # whoever runs the installation, so every later command works without sudo.
    if [ ! -d "$APP_DIR" ]; then
        if ! mkdir -p "$APP_DIR" 2>/dev/null; then
            echo "[*] Creating $APP_DIR (needs sudo)"
            sudo mkdir -p "$APP_DIR" && sudo chown "$(id -u):$(id -g)" "$APP_DIR" || {
                echo "Could not create $APP_DIR."
                exit 1
            }
        fi
    fi
    if [ ! -w "$APP_DIR" ]; then
        echo "$APP_DIR is not writable by $(id -un). Run this as the account that owns it."
        exit 1
    fi
    if [ -d "$APP_DIR/.git" ]; then
        echo "[*] Updating the existing installation in $APP_DIR"
        git -C "$APP_DIR" pull --ff-only || {
            echo "Could not update $APP_DIR. Resolve the git state there and run:"
            echo "  cd $APP_DIR && ./scansuite update $code"
            exit 1
        }
    else
        git clone "$REPO" "$APP_DIR" || exit 1
    fi

    mkdir -p "$APP_DIR/key"
    cp "$lic_path" "$APP_DIR/key/"

    cd "$APP_DIR" || exit 1
    if ./scansuite install "$code"; then
        rm -f "$lic_path"
        echo ""
        echo "Manage the installation from $APP_DIR:"
        echo "  ./scansuite status          what is running"
        echo "  ./scansuite logs web        recent log lines"
        echo "  ./scansuite doctor          check the host and the installation"
        echo "  ./scansuite update          fetch and apply a new release"
        echo ""
        exit 0
    fi

    echo ""
    echo "Installation failed. The reason is usually in:"
    echo "  cd $APP_DIR && ./scansuite doctor"
    exit 1
done
