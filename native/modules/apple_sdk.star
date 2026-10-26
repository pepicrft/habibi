# Once 0.68.2 needs Darwin Clang's spelling to stamp the SDK, not the deployment minimum.
def _habibi_apple_sdk_impl(ctx):
    path = host_command([host_which("xcrun"), "--sdk", ctx["attr"]["sdk"], "--show-sdk-path"]).strip()
    return {
        "label_id": ctx["label"]["id"],
        "transitive_linkopts": ["-Xclang-linker", "-isysroot" + path],
    }

habibi_apple_sdk = target_kind(
    attrs = [attr("sdk", "string", required = True, configurable = False, allowed_values = ["iphoneos", "iphonesimulator"])],
    providers = ["apple_linkable"],
    capabilities = [capability("build", ["default"])],
    impl = _habibi_apple_sdk_impl,
)
