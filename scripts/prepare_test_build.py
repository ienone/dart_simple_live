#!/usr/bin/env python3
"""Prepare a disposable CI checkout for side-by-side test-Slive packages.

Run once before Flutter dependency resolution/build. Formal builds never invoke
this script. Android release APKs use the CI runner's debug signing key.
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "simple_live_app"
APP_ID = "com.ienone.testslive"
LINUX_ID = "io.github.ienone.testSlive"
NAME = "test-Slive"
pending: dict[Path, str] = {}


def replace(relative: str, old: str, new: str) -> None:
    path = APP / relative
    text = pending.get(path, path.read_text(encoding="utf-8"))
    if old not in text:
        raise RuntimeError(f"Expected build configuration missing: {relative}: {old!r}")
    pending[path] = text.replace(old, new)


def main() -> None:
    # Keep the Kotlin namespace unchanged so relative manifest activities and
    # native source packages still resolve. Only the installed application ID changes.
    gradle = "android/app/build.gradle.kts"
    replace(gradle, 'applicationId = "com.slotsun.slive"', f'applicationId = "{APP_ID}"')
    for plugin in ("com.google.gms.google-services", "com.google.firebase.crashlytics"):
        replace(gradle, f'    id("{plugin}")\n', "")
    path = APP / gradle
    pending[path], count = re.subn(
        r'    signingConfigs \{\n        create\("release"\) \{.*?\n        \}\n    \}\n',
        "", pending[path], flags=re.S,
    )
    if count != 1:
        raise RuntimeError("Android release signing configuration changed")
    replace(gradle, 'signingConfigs.getByName("release")', 'signingConfigs.getByName("debug")')
    replace("android/app/src/main/AndroidManifest.xml", 'android:label="Slive"', f'android:label="{NAME}"')

    replace("ios/Runner.xcodeproj/project.pbxproj", "com.slotsun.slive", APP_ID)
    replace("ios/Runner/Info.plist", "<string>Simple Live</string>", f"<string>{NAME}</string>")
    replace("ios/Runner/Info.plist", "<string>simple_live_app</string>", f"<string>{NAME}</string>")
    replace("macos/Runner/Configs/AppInfo.xcconfig", "PRODUCT_NAME = Simple Live", f"PRODUCT_NAME = {NAME}")
    replace("macos/Runner/Configs/AppInfo.xcconfig", "com.xycz.simpleLiveApp", APP_ID)
    replace("macos/packaging/dmg/make_config.yaml", "Simple Live", NAME)

    replace("windows/CMakeLists.txt", 'set(BINARY_NAME "slive")', 'set(BINARY_NAME "test-slive")')
    replace("windows/runner/main.cpp", 'L"Slive"', f'L"{NAME}"')
    replace("windows/runner/Runner.rc", '"slive"', f'"{NAME}"')
    replace("windows/runner/Runner.rc", '"slive.exe"', '"test-slive.exe"')
    replace("windows/packaging/exe/make_config.yaml", "display_name: Slive", f"display_name: {NAME}")
    replace("windows/packaging/exe/make_config.yaml", "45F6FA98-DA23-4795-8685-60F607317A1F", "CFE3FD57-5651-4C56-9AC3-EE0571CA56AB")
    replace("windows/packaging/exe/make_config.yaml", 'install_dir_name: "D:\\\\Program Files (x86)\\\\simple_live"', 'install_dir_name: "{autopf}\\\\test-Slive"')
    replace("windows/packaging/msix/make_config.yaml", "display_name: Slive", f"display_name: {NAME}")
    replace("windows/packaging/msix/make_config.yaml", "com.slotsun.slive", APP_ID)

    replace("linux/CMakeLists.txt", 'set(BINARY_NAME "io.github.SlotSun.Slive")', 'set(BINARY_NAME "test-slive")')
    replace("linux/CMakeLists.txt", 'set(APPLICATION_ID "io.github.SlotSun.Slive")', f'set(APPLICATION_ID "{LINUX_ID}")')
    replace("linux/runner/my_application.cc", '"Slive"', f'"{NAME}"')
    replace("linux/packaging/deb/make_config.yaml", "display_name: Slive", f"display_name: {NAME}")
    replace("linux/packaging/deb/make_config.yaml", "package_name: Slive", "package_name: test-slive")
    # Keep source asset filenames stable; their installed identities are changed.
    for desktop in ("assets/io.github.SlotSun.Slive.desktop", "linux/packaging/aur/slive.desktop"):
        replace(desktop, "Name=Slive", f"Name={NAME}")
        replace(desktop, "Exec=io.github.SlotSun.Slive", "Exec=test-slive")
        replace(desktop, "Icon=io.github.SlotSun.Slive", f"Icon={LINUX_ID}")
    replace("assets/io.github.SlotSun.Slive.metainfo.xml", "io.github.SlotSun.Slive", LINUX_ID)
    replace("assets/io.github.SlotSun.Slive.metainfo.xml", "<name>Slive</name>", f"<name>{NAME}</name>")
    replace("lib/services/media_session/mpris_session.dart", "com.slotsun.slive.instance", f"{APP_ID}.instance")
    replace("lib/services/media_session/mpris_session.dart", "DBusString('Slive')", f"DBusString('{NAME}')")
    replace("lib/services/media_session/mpris_session.dart", "io.github.SlotSun.Slive", LINUX_ID)
    replace("lib/services/window_service.dart", 'title: "Slive"', f'title: "{NAME}"')
    replace("lib/main.dart", 'title: "Slive"', f'title: "{NAME}"')
    # Explicitly isolate desktop storage, including portable launches beside a
    # formal executable. Mobile storage is isolated by the application IDs.
    replace("lib/main.dart", "var path = (await getApplicationSupportDirectory()).path;", "var path = p.join((await getApplicationSupportDirectory()).path, 'test-Slive');")
    replace("lib/main.dart", "'data_hive_ce'", "'test_data_hive_ce'")

    # No production Firebase app/configuration belongs to this test identity.
    for import_line in (
        "import 'package:firebase_core/firebase_core.dart';\n",
        "import 'package:simple_live_app/firebase_options.dart';\n",
        "import 'package:simple_live_app/services/firebase_service.dart' as app;\n",
        "import 'package:simple_live_app/routes/app_analytics_observer.dart';\n",
    ):
        replace("lib/main.dart", import_line, "")
    replace("lib/main.dart", "  // only android use firebase\n  if (Platform.isAndroid) {\n    await Firebase.initializeApp(\n      options: DefaultFirebaseOptions.currentPlatform,\n    );\n    Get.put(app.FirebaseService());\n  }", "  // Firebase is disabled in the independently installed test build.")
    replace("lib/main.dart", ", if (Platform.isAndroid) AppAnalyticsObserver.observer", "")
    # The existing settings toggle can still call this service; make that call
    # harmless without initializing a nonexistent Firebase application.
    pending[APP / "lib/services/firebase_service.dart"] = """import 'package:get/get.dart';

class FirebaseService extends GetxService {
  static Future<void> setCrashlytics(bool enable) async {}
}
"""

    # Validate every expected source fragment before changing any file.
    for path, text in pending.items():
        path.write_text(text, encoding="utf-8")
    print(f"Prepared {NAME}: {APP_ID}; Linux {LINUX_ID}; {len(pending)} files")


if __name__ == "__main__":
    main()
