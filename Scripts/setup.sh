#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

python_bin="${PYTHON:-python3}"
venv_dir=".build/ub500-venv"
firmware_dir=".build/ub500-firmware"

mkdir -p .build "$firmware_dir"

if [ ! -x "$venv_dir/bin/python" ]; then
    "$python_bin" -m venv "$venv_dir"
fi

"$venv_dir/bin/python" -m pip install --upgrade pip
"$venv_dir/bin/python" -m pip install 'bumble==0.0.235' libusb-package

download_file() {
    local out="$1"
    shift

    if [ -s "$out" ]; then
        return 0
    fi

    local url
    for url in "$@"; do
        if curl -fL --retry 3 --connect-timeout 15 -o "$out.tmp" "$url"; then
            mv "$out.tmp" "$out"
            return 0
        fi
        rm -f "$out.tmp"
    done

    return 1
}

fw="$firmware_dir/rtl8761bu_fw.bin"
cfg="$firmware_dir/rtl8761bu_config.bin"

download_file "$fw" \
    "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rtl_bt/rtl8761bu_fw.bin" \
    "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/rtl_bt/rtl8761bu_fw.bin"

if ! download_file "$cfg" \
    "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rtl_bt/rtl8761bu_config.bin" \
    "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/rtl_bt/rtl8761bu_config.bin"; then
    printf '\000\000\000\000\000\000' > "$cfg"
fi

cat <<MSG
setup completed.

Next:
  ./Scripts/build-app.sh
MSG
