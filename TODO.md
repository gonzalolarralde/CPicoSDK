# TODOs

- Reset PICO_CMAKE_BUILD_TYPE and CFG_TUSB_DEBUG based on build type. Compound header is wrong. May not be relevant as the finalizing script invokes cmake and won't pass the compound header, it assumes that calls are mostly equivalent.
- Try to move out of the compound header maybe by adding a target for each pico-sdk library.
- Investigate moving the embedded ARM toolchain into a swift toolchain instead.
- Decide if moving environment preparation logic to a tool makes sense. Figure out trade-offs and feasibility.

## Swift

- Package.swift:13: // TODO: This needs to be implemented.
- Plugins/FinalizeBinaryPlugin/FinalizeBinaryPlugin.swift:62: // TODO: Figure out how to expand this.
- Plugins/FinalizeBinaryPlugin/FinalizeBinaryPlugin.swift:67: // TODO: Rewrite all this as swift code.
- Plugins/FinalizeBinaryPlugin/FinalizeBinaryPlugin.swift:95: // TODO: Rewrite build.sh as swift code
- Plugins/FinalizeBinaryPlugin/FinalizeBinaryPlugin.swift:101: // TODO: Move to shared package
- Plugins/GenerateCPicoSDKPlugin/GenerateCPicoSDKPlugin.swift:57: // TODO: Rewrite build.sh as swift code
- Plugins/GenerateCPicoSDKPlugin/GenerateCPicoSDKPlugin.swift:63: // TODO: Move to shared package
- Plugins/PrepareEnvironmentPlugin/Extensions.swift:25: // TODO: Move to shared package

## Scripts

- Plugins/GenerateCPicoSDKPluginTool/build.sh:20: # // TODO: Figure out how to provide library selection at the dependecy level.
