use std::ffi::{CStr, CString, c_char};

/// Borrows a valid NUL-terminated UTF-8 input; the caller owns and frees the result.
///
/// # Safety
/// `input` must remain readable until this call returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn habibi_core_execute(input: *const c_char) -> *mut c_char {
    let output = if input.is_null() {
        crate::execute("")
    } else {
        crate::execute(unsafe { CStr::from_ptr(input) }.to_str().unwrap_or(""))
    };
    CString::new(output)
        .expect("JSON never contains an unescaped NUL")
        .into_raw()
}

/// # Safety
/// Free exactly one non-null result returned by `habibi_core_execute`, once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn habibi_core_free(output: *mut c_char) {
    if !output.is_null() {
        drop(unsafe { CString::from_raw(output) });
    }
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_fyi_habibi_app_HabibiCore_execute(
    mut env: jni::JNIEnv,
    _class: jni::objects::JClass,
    input: jni::objects::JString,
) -> jni::sys::jstring {
    let output = match env.get_string(&input) {
        Ok(value) => crate::execute(&value.to_string_lossy()),
        Err(_) => crate::execute(""),
    };
    env.new_string(output)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}
