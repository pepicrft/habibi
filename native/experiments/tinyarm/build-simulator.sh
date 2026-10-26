#!/bin/bash
# Unshipped research prototype. Does not build or alter the production app.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
experiment="$root/native/experiments/tinyarm"
scratch="$root/.amp/in/tinyarm-sim"
upstream="$root/.amp/in/tinyarm-simulator-upstream"
revision=bac69aa0253b10fce6a93b3d2eccf134911ed231
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
git check-ignore -q "$scratch/ignore-check" || { echo 'Exclude /.amp/in/ in the repository-local info/exclude first' >&2; exit 1; }
mkdir -p "$scratch"
if [[ ! -d "$upstream/.git" ]]; then
    git clone --depth 1 --branch v1.1.0 https://trylle.com/xlab/tinyarm.git "$upstream"
fi
[[ $(git -C "$upstream" rev-parse HEAD) == "$revision" ]] || { echo "Unexpected TinyARM revision" >&2; exit 1; }
if git -C "$upstream" apply --check "$experiment/tinyarm-no-host-fs.patch" 2>/dev/null; then
    git -C "$upstream" apply "$experiment/tinyarm-no-host-fs.patch"
else
    git -C "$upstream" apply --reverse --check "$experiment/tinyarm-no-host-fs.patch"
fi
if [[ ! -d "$scratch/zig-lib" ]]; then
    zig=$(mise where zig@0.17.0)
    cp -cR "$zig/lib" "$scratch/zig-lib"
    patch -d "$scratch/zig-lib" -p1 < "$experiment/zig-ios-process-replace.patch"
fi
(cd "$upstream" && ZIG_LIB_DIR="$scratch/zig-lib" mise exec zig@0.17.0 -- zig build lib \
    -Dtarget=aarch64-ios.17.0-simulator --sysroot "$sdk" --prefix "$scratch/runtime-simulator" -j4)
python3 "$experiment/guest/prepare.py"
[[ -f "$scratch/bridge.json" ]] || { echo "Start bridge.mjs before building the app" >&2; exit 1; }
app="$scratch/HabibiLab.app"
mkdir -p "$app/pack"
cp "$scratch/pack/"* "$app/pack/"
cp "$scratch/bridge.json" "$app/bridge.json"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>fyi.habibi.tinyarmlab</string>
<key>CFBundleName</key><string>Habibi Lab</string>
<key>CFBundleExecutable</key><string>HabibiLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
xcrun derq query -f xml -i "$experiment/Simulator.entitlements" -o "$scratch/entitlements.der" --raw
xcrun swiftc -swift-version 5 -parse-as-library -Onone -g \
    -target arm64-apple-ios17.0-simulator -sdk "$sdk" \
    -Xclang-linker "-isysroot$sdk" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$experiment/Simulator.entitlements" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ents_der -Xlinker "$scratch/entitlements.der" \
    -I "$experiment/include" -Xcc "-I$scratch/runtime-simulator/include" \
    "$experiment/Sources/"*.swift "$scratch/runtime-simulator/lib/libtinyarm.a" \
    -o "$app/HabibiLab"
codesign --force --sign - "$app"
echo "$app"
