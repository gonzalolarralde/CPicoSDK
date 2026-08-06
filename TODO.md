# TODOs

- Reset `PICO_CMAKE_BUILD_TYPE` and `CFG_TUSB_DEBUG` based on build type. The
  compound header is currently wrong. This may not affect firmware assembly,
  because the automatic post-product finalizer configures CMake independently.
- Try to move out of the compound header maybe by adding a target for each pico-sdk library.
- Decide how the experimental relocatable Swift SDK should be distributed once
  SwiftPM's external-package APIs stabilize.

## Swift

- Package.swift.template: Define generated traits instead of relying on the
  checked-in generator section.
- Share the async `Process` helper currently duplicated across command plugins.

## Scripts

- Plugins/GenerateCPicoSDKPluginTool/build.sh:20: # // TODO: Figure out how to provide library selection at the dependecy level.
