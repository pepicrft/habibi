#!/usr/bin/env bash
#MISE description="Distribution-sign and package the built device app using Infisical-injected secrets"
set -euo pipefail
set +x
umask 077

ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
VERSION=${1:?Usage: bundle.sh VERSION BUILD_NUMBER [OUTPUT_IPA]}
BUILD=${2:?Usage: bundle.sh VERSION BUILD_NUMBER [OUTPUT_IPA]}
OUTPUT=${3:-$ROOT/native/.once/distribution/Habibi.ipa}
# Local bootstrap builds 1.0.N precede CI's first run/attempt build 1.1.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[1-9][0-9]*(\.[0-9]+){0,2}$ ]] || {
  echo "Expected a stable version and a positive build number (CI: RUN_NUMBER.RUN_ATTEMPT)." >&2; exit 1;
}
[[ "$OUTPUT" == /* && ! -e "$OUTPUT" ]] || {
  echo "The output IPA must be a new absolute path." >&2; exit 1;
}
: "${IOS_DISTRIBUTION_P12_BASE64:?Missing signing identity}"
: "${IOS_DISTRIBUTION_P12_PASSWORD:?Missing signing identity password}"
: "${IOS_APP_STORE_PROFILE_BASE64:?Missing App Store provisioning profile}"

temporary=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/habibi-ios.XXXXXX")
keychain="$temporary/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT
printf '%s' "$IOS_DISTRIBUTION_P12_BASE64" | base64 --decode > "$temporary/distribution.p12"
printf '%s' "$IOS_APP_STORE_PROFILE_BASE64" | base64 --decode > "$temporary/profile.mobileprovision"
unset IOS_DISTRIBUTION_P12_BASE64 IOS_APP_STORE_PROFILE_BASE64
security cms -D -i "$temporary/profile.mobileprovision" > "$temporary/profile.plist"
profile="$temporary/profile.plist"
team=$(plutil -extract TeamIdentifier.0 raw -o - "$profile")
bundle_id=fyi.habibi.app
if [[ $(plutil -extract Entitlements.application-identifier raw -o - "$profile") != "$team.$bundle_id" ||
      $(plutil -extract Entitlements.get-task-allow raw -o - "$profile") != false ||
      $(plutil -extract Entitlements.beta-reports-active raw -o - "$profile") != true ]]; then
  echo "Expected an App Store distribution profile for $bundle_id with debugging disabled." >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$profile" >/dev/null 2>&1 ||
   /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$profile" >/dev/null 2>&1; then
  echo "Expected an App Store profile, not Ad Hoc, development or enterprise." >&2
  exit 1
fi
expires=$(plutil -extract ExpirationDate raw -o - "$profile")
[[ $(date -ju -f '%Y-%m-%dT%H:%M:%SZ' "$expires" +%s) -gt $(date -u +%s) ]] || {
  echo "The App Store provisioning profile has expired." >&2; exit 1;
}
plutil -extract DeveloperCertificates.0 raw -o - "$profile" | base64 --decode > "$temporary/certificate.cer"
identity=$(openssl x509 -inform DER -in "$temporary/certificate.cer" -noout -fingerprint -sha1 |
  cut -d= -f2 | tr -d ':')

# Never mutate Once's cached bundle or the checked-in development plist.
app="$temporary/package/Payload/Habibi.app"
mkdir -p "$(dirname "$app")"
ditto "$ROOT/native/.once/out/HabibiIOSDevice/Habibi.app" "$app"
if [[ -d "$app/PlugIns" ]]; then
  echo "App extensions need their own distribution profiles before packaging." >&2; exit 1
fi
plist="$app/Info.plist"
[[ $(plutil -extract CFBundleIdentifier raw -o - "$plist") == "$bundle_id" ]]
plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
plutil -replace CFBundleVersion -string "$BUILD" "$plist"
# Once copies custom plists without Xcode's SDK/platform metadata processing.
sdk=$(xcrun --sdk iphoneos --show-sdk-version)
sdk_build=$(xcrun --sdk iphoneos --show-sdk-build-version)
xcode_build=$(xcodebuild -version | awk '/Build version/ {print $3}')
xcode_version=$(xcodebuild -version | awk '/^Xcode / {split($2,v,"."); printf "%02d%d%d",v[1],v[2],v[3]}')
plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$plist"
plutil -replace DTPlatformName -string iphoneos "$plist"
plutil -replace DTPlatformVersion -string "$sdk" "$plist"
plutil -replace DTPlatformBuild -string "$sdk_build" "$plist"
plutil -replace DTSDKName -string "iphoneos$sdk" "$plist"
plutil -replace DTSDKBuild -string "$sdk_build" "$plist"
plutil -replace DTXcode -string "$xcode_version" "$plist"
plutil -replace DTXcodeBuild -string "$xcode_build" "$plist"
plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$plist"
plutil -replace BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$plist"
cp "$temporary/profile.mobileprovision" "$app/embedded.mobileprovision"
plutil -extract Entitlements xml1 -o "$temporary/entitlements.plist" "$profile"
# A profile permits TEAM.*; this app must claim only its own Keychain group.
plutil -replace keychain-access-groups -json "[\"$team.$bundle_id\"]" "$temporary/entitlements.plist"

keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$temporary/distribution.p12" -k "$keychain" -P "$IOS_DISTRIBUTION_P12_PASSWORD" -T /usr/bin/codesign
unset IOS_DISTRIBUTION_P12_PASSWORD
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
# Include Apple's intermediate even on a clean CI runner.
curl --fail --silent --show-error --retry 3 https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer \
  -o "$temporary/wwdr.cer"
security import "$temporary/wwdr.cer" -k "$keychain"
security find-identity -v -p codesigning "$keychain" | grep -Fq "$identity" || {
  echo "The imported signing identity does not match the profile's valid certificate." >&2; exit 1;
}

mkdir -p "$app/Frameworks" "$temporary/package/SwiftSupport"
xcrun swift-stdlib-tool --copy --platform iphoneos --scan-executable "$app/Habibi" \
  --scan-folder "$app/Frameworks" --destination "$app/Frameworks" \
  --unsigned-destination "$temporary/package/SwiftSupport" --strip-bitcode
# Apps using only the OS Swift runtime need no empty SwiftSupport directory.
find "$temporary/package" -depth -type d -empty -delete
while IFS= read -r -d '' code; do
  codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$code"
done < <(find "$app" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none \
  --generate-entitlement-der --entitlements "$temporary/entitlements.plist" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
plutil -lint "$plist" "$temporary/entitlements.plist"
mkdir -p "$(dirname "$OUTPUT")"
ditto --norsrc --noextattr -c -k "$temporary/package" "$OUTPUT"
printf 'Signed Habibi %s (%s) for %s: %s\n' "$VERSION" "$BUILD" "$team" "$OUTPUT"
