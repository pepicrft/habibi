# Once owns Rust and ordering; Gradle owns AAR, resource and manifest merging.
def _habibi_android_impl(ctx):
    native = ctx["deps_by_role"]["deps"][0]["android_native_libraries"][0]
    nsh = ctx["deps_by_role"]["nsh"][0]["default_output"]
    apk = declare_output("HabibiAndroid.apk")
    run_action(
        argv = [
            host_which("gradle"), "--no-daemon", "--console=plain",
            "-p", execution_path("android"), "packageOnce",
            "-PonceNativeLibrary=" + execution_path(native["path"]),
            "-PonceNativeAbi=" + native["abi"],
            "-PonceOutputApk=" + execution_path(apk),
            "-PnshAndroidAar=" + execution_path(nsh),
            "-PnshBundleDirectory=" + execution_path("cards/assets/nsh"),
        ],
        inputs = glob(ctx["srcs"]) + [native["path"], nsh],
        outputs = [apk],
        sandbox = "off",
        cacheable = False,
        inherit_parent_env = True,
        identifier = ctx["label"]["id"] + ":material-android",
        display_name = "Build Habibi Material Android app",
    )
    return {"label_id": ctx["label"]["id"], "android_apk": apk, "default_output": apk}

habibi_android_application = target_kind(
    deps = [
        dep("deps", ["android_native_library"], "Once-built Rust JNI", min_count = 1, max_count = 1),
        dep("nsh", ["android_library"], "Checksum-pinned Native Shell AAR", min_count = 1, max_count = 1),
    ],
    providers = ["android_apk"],
    capabilities = [capability("build", ["default"])],
    tools = [tool("gradle", executables = ["gradle"])],
    impl = _habibi_android_impl,
)
