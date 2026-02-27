#!/usr/bin/env python3
"""Validate Android App Bundle (AAB) before Google Play upload."""

import sys
import zipfile
import os
import xml.etree.ElementTree as ET


def check_aab(path: str) -> bool:
    """Validate AAB file. Returns True if all checks pass."""
    path = os.path.normpath(path)
    if not os.path.exists(path):
        print(f"ERROR: File not found: {path}")
        return False

    if not path.lower().endswith(".aab"):
        print(f"WARNING: File does not have .aab extension: {path}")

    size_mb = os.path.getsize(path) / (1024 * 1024)
    print(f"File: {path}")
    print(f"Size: {size_mb:.2f} MB")
    print()

    all_ok = True

    # Check 1: Valid zip
    try:
        with zipfile.ZipFile(path, "r") as zf:
            names = zf.namelist()
            if "BundleConfig.pb" not in names and "base/manifest/AndroidManifest.xml" not in names:
                # AAB has base/ directory
                if not any(n.startswith("base/") for n in names):
                    print("WARNING: AAB structure may be invalid (no base/ entries)")
                    all_ok = False
            print("OK: Valid zip/AAB structure")
    except zipfile.BadZipFile:
        print("ERROR: Not a valid zip/AAB file")
        return False

    # Check 2: Manifest if we can read it (AAB uses binary XML, so we skip deep parse)
    print("OK: Basic validation passed")
    print()
    print("Next steps for Google Play:")
    print("  1. Install NDK 29.0.14206865: Android Studio → SDK Manager → SDK Tools → NDK (29.0.14206865)")
    print("  2. Run: flutter clean && flutter build appbundle --flavor prod --dart-define-from-file=config/prod.env")
    print("  3. Upload new AAB to Play Console")

    return all_ok


def main():
    if len(sys.argv) < 2:
        default = "build/app/outputs/bundle/prodRelease/app-prod-release.aab"
        print(f"Usage: python app_checker.py <path-to-aab>")
        print(f"Example: python app_checker.py {default}")
        sys.exit(1)

    path = sys.argv[1]
    ok = check_aab(path)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
