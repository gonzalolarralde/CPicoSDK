#!/usr/bin/env /bin/bash
set -euxo pipefail

PICOTOOL_VERSION=2.2.0-a4
cat env.json.tmpl | sed "s#<HOME>#$( dirname ~/. )#g" > env.json
rm -rf .build

~/.swiftly/bin/swiftly run swift build -v \
    --build-system native \
    --configuration release \
    --toolset toolset.json \
    --triple armv7em-none-none-eabi

~/.swiftly/bin/swiftly run swift package finalize-pi-binary "$1"

# Only flash if second arg is exactly "--flash"
if [[ "${2:-}" == "--flash" ]]; then
    while true; do
        if ~/.pico-sdk/picotool/$PICOTOOL_VERSION/picotool/picotool info >/dev/null 2>&1; then
            echo "Device found!"
            break
        fi

        echo "Waiting for device in BOOTSEL mode to become available. Connect the device while pushing the BOOT button... (trying again in 2 seconds)"
        sleep 2
    done

    ~/.pico-sdk/picotool/$PICOTOOL_VERSION/picotool/picotool load ".build/armv7em-none-none-eabi/release/$1.uf2"
    ~/.pico-sdk/picotool/$PICOTOOL_VERSION/picotool/picotool reboot
fi

#~/.pico-sdk/openocd/0.12.0+dev/openocd.exe -c "gdb_port 50000" -c "tcl_port 50001" -c "telnet_port 50002" -s ~/.pico-sdk/openocd/0.12.0+dev/scripts -f ~/.vscode/extensions/marus25.cortex-debug-1.12.1/support/openocd-helpers.tcl -f interface/cmsis-dap.cfg -f target/rp2350.cfg -c "adapter speed 5000" -c "program .build/armv7em-none-none-eabi/release/$1.elf verify reset exit"
