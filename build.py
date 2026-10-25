#!/usr/bin/env python3
"""Final device binaries must be built by build-macos.py on macOS/Xcode."""
import platform
if platform.system() != "Darwin":
    raise SystemExit(
        "build.py is disabled for final iOS arm64e binaries. "
        "Use macOS/Xcode: python3 build-macos.py"
    )
raise SystemExit(
    "build.py is retired. Use macOS/Xcode: python3 build-macos.py"
)
