#!/usr/bin/env bash
set -euo pipefail
bundle="simple_live_app/build/linux/$BUILD_ARCH/release/bundle"
mkdir -p dist
archive="test-Slive-linux-$BUILD_ARCH"
tar -czf "dist/$archive.tar.gz" -C "$bundle" .
pkg=$(mktemp -d)
trap 'rm -rf "$pkg"' EXIT
mkdir -p "$pkg/opt/test-slive" "$pkg/usr/bin" "$pkg/usr/share/applications" "$pkg/DEBIAN"
cp -a "$bundle/." "$pkg/opt/test-slive/"
ln -s /opt/test-slive/test-slive "$pkg/usr/bin/test-slive"
arch=amd64
if [ "$BUILD_ARCH" = arm64 ]; then arch=arm64; fi
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: test-slive
Version: 1.0.${GITHUB_RUN_NUMBER}
Architecture: $arch
Maintainer: ienone
Depends: libgtk-3-0t64, libmpv2, libayatana-appindicator3-1
Description: test-Slive live stream player preview
CONTROL
cat > "$pkg/usr/share/applications/io.github.ienone.testSlive.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=test-Slive
Exec=/opt/test-slive/test-slive
Terminal=false
Categories=AudioVideo;
DESKTOP
dpkg-deb --build --root-owner-group "$pkg" "dist/$archive.deb"
