# How to Start

1. **Clone the repository** and navigate to the Example project:
   ```bash
   cd Example/
   ```

2. **Install swiftly** and other dependencies if using linux:
   **Linux:** First, install required system dependencies:
   ```bash
   sudo apt install build-essential libhidapi-hidraw0 libhidapi-libusb0
   ```

   **Linux and macOS:** Install Swiftly from [swift.org](https://www.swift.org/install/) and ensure all dependencies mentioned at the end of the build script are installed.

3. **Run the build script** for the first time:
   ```bash
   bash build.sh
   ```
   > ⏱️ **Note**: The first run will take a couple of minutes as it downloads all dependencies (Pico SDK, toolchains, and Swift packages).

4. **Open in VSCode** (optional but recommended):
   Install the recommended extensions when prompted. This enables full IDE integration with debugging and flashing capabilities.

## Programming the Device

Once your project is built, you have two options for programming your RP2xxx device:

- **Using cortex-debug** (with debug probe): Connect an SWD debug probe (like a Raspberry Pi Debug Probe or Picoprobe) to your device. This enables full debugging with breakpoints, variable inspection, and step-through execution.

- **Using picotool** (USB flashing): Hold down the **BOOTSEL** button while connecting your device via USB (or press it while pressing the reset button). The device will appear as a USB mass storage device, and picotool can directly write the firmware without needing a debug probe.

<img width="1092" height="888" alt="Screenshot 2026-01-03 at 10 38 38 PM" src="https://github.com/user-attachments/assets/a32ef610-16fc-4141-b718-558960bc492f" />
