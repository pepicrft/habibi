//! Interpreter-only QuickJS sandbox. The immutable Wasm module may be shared;
//! every call owns a new store, linear memory, QuickJS runtime and context.
//! No WASI, native JS, WebView, callbacks, module loader or job runner is used.
//!
//! ABI: @jitl/quickjs-singlefile-browser-release-sync 0.32.0, SHA-256
//! 105c3bed22d457e43e3d1c3c1c6959fda62a8fe06f0fc8a985303c3a2be72232.
//! Reproduce using native/resources/prepare_quickjs.mjs. Minified symbols below
//! correspond to the installed ffi.d.mts and Emscripten loader, not raw JSValue
//! layouts. QTS values are *pointers* to values, including argv entries.

use std::io::{self, Write};
use std::sync::OnceLock;
use wasmi::{
    Caller, Config, Engine, ExternType, Func, Instance, Linker, Memory, MemoryType, Module, Store,
    StoreLimits, StoreLimitsBuilder, WasmParams, WasmResults,
};

const SOURCE_LIMIT: usize = 24 * 1024;
pub(crate) const INPUT_LIMIT: usize = 256 * 1024;
const OUTPUT_LIMIT: usize = 16 * 1024;
const MEMORY_LIMIT: usize = 32 * 1024 * 1024;
const QUICKJS_MEMORY_LIMIT: i32 = 8 * 1024 * 1024;
const QUICKJS_STACK_LIMIT: i32 = 256 * 1024;
// A deterministic instruction budget, not a wall-clock deadline. Includes
// Emscripten constructors, QuickJS setup, user code and all Wasm conversions.
const FUEL: u64 = 25_000_000;
const FAILURE: &str = "Kit runtime failed";
const WASM: &[u8] = include_bytes!("../assets/quickjs.wasm");

type Result<T> = std::result::Result<T, String>;

struct Host {
    limits: StoreLimits,
    memory: Option<Memory>,
}

fn wasm_error(error: wasmi::Error) -> String {
    if error.as_trap_code() == Some(wasmi::core::TrapCode::OutOfFuel) {
        "Kit budget exceeded".into()
    } else {
        FAILURE.into()
    }
}

fn module() -> Result<&'static (Engine, Module)> {
    static MODULE: OnceLock<Result<(Engine, Module)>> = OnceLock::new();
    MODULE
        .get_or_init(|| {
            let mut config = Config::default();
            config.consume_fuel(true);
            let engine = Engine::new(&config);
            let module = Module::new(&engine, WASM).map_err(wasm_error)?;
            Ok((engine, module))
        })
        .as_ref()
        .map_err(Clone::clone)
}

struct Sandbox {
    store: Store<Host>,
    instance: Instance,
    memory: Memory,
}

impl Sandbox {
    fn new() -> Result<Self> {
        let (engine, module) = module()?;
        let limits = StoreLimitsBuilder::new()
            .memory_size(MEMORY_LIMIT)
            .table_elements(4096)
            .instances(1)
            // wasmi counts the existing host allocation and the module's
            // imported memory against this limit; they alias the same memory.
            .memories(2)
            .tables(1)
            .build();
        let mut store = Store::new(
            engine,
            Host {
                limits,
                memory: None,
            },
        );
        store.limiter(|host| &mut host.limits);
        store.set_fuel(FUEL).map_err(wasm_error)?;
        // The original Emscripten loader supplies 16 MiB initially. A smaller
        // declared maximum is a valid subtype of the module's 2 GiB import.
        let memory = Memory::new(&mut store, MemoryType::new(256, Some(512)))
            .map_err(|_| FAILURE.to_owned())?;
        store.data_mut().memory = Some(memory);
        let mut linker = Linker::new(engine);
        linker
            .define("a", "a", memory)
            .map_err(|_| FAILURE.to_owned())?;

        // Link *only* the imports of the pinned binary. Even unused forbidden
        // imports trap, rather than pretend that a host operation succeeded.
        for import in module.imports() {
            let ExternType::Func(ty) = import.ty() else {
                if import.module() == "a" && import.name() == "a" {
                    continue;
                }
                return Err(FAILURE.into());
            };
            if import.module() != "a"
                || !matches!(
                    import.name(),
                    "b" | "c"
                        | "d"
                        | "e"
                        | "f"
                        | "g"
                        | "h"
                        | "i"
                        | "j"
                        | "k"
                        | "l"
                        | "m"
                        | "n"
                        | "o"
                        | "p"
                        | "q"
                        | "r"
                        | "s"
                        | "t"
                )
            {
                return Err(FAILURE.into());
            }
            let name = import.name().to_owned();
            let function = Func::new(&mut store, ty.clone(), move |mut caller, args, out| {
                match name.as_str() {
                    // emscripten_resize_heap(requested_bytes): dlmalloc needs
                    // this even though memory.grow is itself also restricted.
                    "k" => {
                        let bytes = args[0].i32().ok_or_else(denied)? as u32 as usize;
                        let memory = caller.data().memory.ok_or_else(denied)?;
                        let current = memory.data_size(&caller);
                        let success = bytes <= MEMORY_LIMIT
                            && (bytes <= current
                                || memory
                                    .grow(&mut caller, ((bytes - current).div_ceil(65536)) as u64)
                                    .is_ok());
                        out[0] = i32::from(success).into();
                        Ok(())
                    }
                    // environ_get/environ_sizes_get: an empty, deterministic
                    // environment, never the process environment.
                    "e" => {
                        out[0] = 0_i32.into();
                        Ok(())
                    }
                    "f" => {
                        write_word(&mut caller, args[0].i32().ok_or_else(denied)?, 0)?;
                        write_word(&mut caller, args[1].i32().ok_or_else(denied)?, 0)?;
                        out[0] = 0_i32.into();
                        Ok(())
                    }
                    // emscripten_date_now: do not reveal the device clock.
                    "p" => {
                        out[0] = wasmi::core::F64::from(0.0).into();
                        Ok(())
                    }
                    // Assertions, fd_write/close/seek, exit, timers, timezone/
                    // localtime, interrupts, JS host functions, host refs and
                    // module loading/normalization are deliberately forbidden.
                    _ => Err(denied()),
                }
            });
            linker
                .define("a", import.name(), function)
                .map_err(|_| FAILURE.to_owned())?;
        }
        let instance = linker
            .instantiate(&mut store, module)
            .map_err(wasm_error)?
            .start(&mut store)
            .map_err(wasm_error)?;
        let mut sandbox = Self {
            store,
            instance,
            memory,
        };
        sandbox.call::<(), ()>("u", ())?; // __wasm_call_ctors, like the JS loader.
        Ok(sandbox)
    }

    fn call<P: WasmParams, R: WasmResults>(&mut self, name: &str, args: P) -> Result<R> {
        let function = self
            .instance
            .get_typed_func::<P, R>(&self.store, name)
            .map_err(wasm_error)?;
        function.call(&mut self.store, args).map_err(wasm_error)
    }

    fn allocate(&mut self, bytes: &[u8]) -> Result<i32> {
        let pointer: i32 = self.call("v", (bytes.len() + 1) as i32)?; // malloc
        if pointer == 0 {
            return Err(FAILURE.into());
        }
        self.memory
            .write(&mut self.store, pointer as u32 as usize, bytes)
            .map_err(|_| FAILURE.to_owned())?;
        self.memory
            .write(&mut self.store, pointer as u32 as usize + bytes.len(), &[0])
            .map_err(|_| FAILURE.to_owned())?;
        Ok(pointer)
    }

    fn cstring(&self, pointer: i32, max_bytes: usize) -> Result<&str> {
        if pointer == 0 {
            return Err(FAILURE.into());
        }
        let bytes = self
            .memory
            .data(&self.store)
            .get(pointer as u32 as usize..)
            .ok_or(FAILURE)?;
        let end = bytes
            .iter()
            .take(max_bytes + 1)
            .position(|byte| *byte == 0)
            .ok_or(FAILURE)?;
        std::str::from_utf8(&bytes[..end]).map_err(|_| FAILURE.into())
    }

    fn check_exception(&mut self, context: i32, value: i32) -> Result<i32> {
        if value == 0 {
            return Err(FAILURE.into());
        }
        let error: i32 = self.call("na", (context, value))?; // QTS_ResolveException
        // Do not stringify or inspect guest exceptions: even their toString,
        // message and stack properties can execute arbitrary user code.
        if error != 0 {
            return Err(FAILURE.into());
        }
        Ok(value)
    }

    fn has_type(&mut self, context: i32, value: i32, expected: &str) -> Result<bool> {
        let pointer = self.call("ra", (context, value))?; // QTS_Typeof (not coercion)
        Ok(self.cstring(pointer, 16)? == expected)
    }

    fn run(&mut self, source: &str, input: &[u8]) -> Result<serde_json::Value> {
        let runtime: i32 = self.call("K", ())?; // QTS_NewRuntime
        if runtime == 0 {
            return Err(FAILURE.into());
        }
        self.call::<_, ()>("y", (runtime, QUICKJS_MEMORY_LIMIT))?;
        self.call::<_, ()>("D", (runtime, QUICKJS_STACK_LIMIT))?;
        let context: i32 = self.call("N", (runtime, 0_i32))?; // default intrinsics
        if context == 0 {
            return Err(FAILURE.into());
        }
        let code = format!("{source}\n;summarize");
        let code_pointer = self.allocate(code.as_bytes())?;
        let filename = self.allocate(b"kit.js")?;
        let function = self.call(
            "pa",
            (
                context,
                code_pointer,
                code.len() as i32,
                filename,
                0_i32,
                0_i32,
            ),
        )?;
        let function = self.check_exception(context, function)?;
        if !self.has_type(context, function, "function")? {
            return Err(FAILURE.into());
        }

        let input_pointer = self.allocate(input)?;
        let argument = self.call("_", (context, input_pointer))?; // QTS_NewString
        let argument = self.check_exception(context, argument)?;
        let argv = self.allocate(&argument.to_le_bytes())?;
        let undefined: i32 = self.call("E", ())?;
        let output = self.call("ma", (context, function, undefined, 1_i32, argv))?;
        let output = self.check_exception(context, output)?;
        if !self.has_type(context, output, "string")? {
            return Err(FAILURE.into());
        }

        // Primitive strings have an own immutable length: no prototype getter
        // can run here. Bound the engine-side UTF-8 allocation before GetString.
        let key = self.allocate(b"length")?;
        let key: i32 = self.call("_", (context, key))?;
        let key = self.check_exception(context, key)?;
        let length = self.call("ha", (context, output, key))?;
        let length = self.check_exception(context, length)?;
        if !self.has_type(context, length, "number")? {
            return Err(FAILURE.into());
        }
        let length: f64 = self.call("Z", (context, length))?;
        if !length.is_finite() || length < 0.0 || length.fract() != 0.0 {
            return Err(FAILURE.into());
        }
        if length > OUTPUT_LIMIT as f64 {
            return Err("Kit output exceeds 16 KiB".into());
        }
        let pointer = self.call("$", (context, output))?; // QTS_GetString
        let text = self.cstring(pointer, 3 * OUTPUT_LIMIT)?;
        // Reject C-string NUL truncation and malformed UTF-16/UTF-8 conversion.
        if text.encode_utf16().count() != length as usize {
            return Err(FAILURE.into());
        }
        if text.len() > OUTPUT_LIMIT {
            return Err("Kit output exceeds 16 KiB".into());
        }
        serde_json::from_str(text).map_err(|_| FAILURE.into())
        // Dropping the entire store reclaims everything, even after a trap.
        // No guest cleanup/finalizers run outside the fuel budget.
    }
}

fn denied() -> wasmi::Error {
    wasmi::Error::new("Forbidden QuickJS host capability")
}

fn write_word(
    caller: &mut Caller<'_, Host>,
    pointer: i32,
    value: u32,
) -> std::result::Result<(), wasmi::Error> {
    let memory = caller.data().memory.ok_or_else(denied)?;
    memory
        .write(caller, pointer as u32 as usize, &value.to_le_bytes())
        .map_err(|_| denied())
}

struct BoundedInput(Vec<u8>);

impl Write for BoundedInput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > INPUT_LIMIT - self.0.len() {
            return Err(io::Error::other("Kit input exceeds 256 KiB"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Run global JS declaring `summarize(inputJson)` in a fresh sandbox. Only a
/// primitive string containing valid JSON is accepted. This function validates
/// the transport, NOT the metrics schema; the caller must validate that schema.
/// Promises are not awaited and pending jobs are never executed. Date.now() is
/// fixed at Unix epoch; local-time/timezone imports fail closed.
pub fn summarize(
    source: &str,
    input: &serde_json::Value,
) -> std::result::Result<serde_json::Value, String> {
    if source.len() > SOURCE_LIMIT {
        return Err("Kit source exceeds 24 KiB".into());
    }
    let mut input_json = BoundedInput(Vec::new());
    serde_json::to_writer(&mut input_json, input)
        .map_err(|_| "Kit input exceeds 256 KiB".to_owned())?;
    Sandbox::new()?.run(source, &input_json.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const HEALTHY: &str = r#"function summarize(inputJson) {
        const input = JSON.parse(inputJson);
        return JSON.stringify({metrics:[{label:input.label, value:input.values.reduce((a,b)=>a+b,0),unit:'步 🐪'}]});
    }"#;

    fn healthy() {
        assert_eq!(
            summarize(
                HEALTHY,
                &json!({"label":"صباح café 中 🦀", "values":[2,3,7]})
            )
            .unwrap(),
            json!({"metrics":[{"label":"صباح café 中 🦀","value":12,"unit":"步 🐪"}]})
        );
    }

    #[test]
    fn healthy_unicode_and_fresh_instances() {
        healthy();
        let source = "globalThis.n = (globalThis.n || 0) + 1; function summarize() { return JSON.stringify(n); }";
        assert_eq!(summarize(source, &json!(null)).unwrap(), json!(1));
        assert_eq!(summarize(source, &json!(null)).unwrap(), json!(1));
    }

    #[test]
    fn initialization_and_function_loops_exhaust_fuel() {
        for source in [
            "while(true) {}",
            "function summarize() { while(true) {} }",
            "function summarize() { return String({toString(){while(true){}}}); }",
        ] {
            assert_eq!(
                summarize(source, &json!(null)).unwrap_err(),
                "Kit budget exceeded"
            );
            healthy();
        }
    }

    #[test]
    fn never_coerces_objects_or_errors_or_runs_jobs() {
        for source in [
            "function summarize(){ return {toString(){while(true){}}}; }",
            "throw { get stack(){while(true){}}, toString(){while(true){}} };",
            "function summarize(){ throw {toString(){while(true){}}}; }",
            "async function summarize(){ return '{}'; }",
        ] {
            assert_eq!(summarize(source, &json!(null)).unwrap_err(), FAILURE);
        }
        assert_eq!(
            summarize(
                "Promise.resolve().then(()=>{while(true){}}); function summarize(){return '{}'}",
                &json!(null)
            )
            .unwrap(),
            json!({})
        );
        healthy();
    }

    #[test]
    fn no_ambient_host_capabilities_or_module_loader() {
        for name in [
            "fetch",
            "XMLHttpRequest",
            "WebSocket",
            "require",
            "process",
            "Deno",
            "Bun",
            "window",
            "document",
            "console",
            "setTimeout",
            "WebAssembly",
            "std",
            "os",
        ] {
            let source = format!("function summarize(){{return JSON.stringify(typeof {name})}}");
            assert_eq!(
                summarize(&source, &json!(null)).unwrap(),
                json!("undefined"),
                "{name}"
            );
        }
        for source in [
            "function summarize(){return fetch('https://example.com')}",
            "import x from 'file:///etc/passwd'; function summarize(){return '{}'}",
            "function summarize(){return require('fs').readFileSync('/etc/passwd')}",
        ] {
            assert!(summarize(source, &json!(null)).is_err());
        }
        assert_eq!(
            summarize(
                "function summarize(){return JSON.stringify(Date.now())}",
                &json!(null)
            )
            .unwrap(),
            json!(0)
        );
        // A forbidden runtime import aborts even inside a guest try/catch.
        assert!(
            summarize(
                "function summarize(){try {new Date().toString()} catch {} return '{}'}",
                &json!(null)
            )
            .is_err()
        );
        assert_eq!(summarize("let loaded=false; import('https://example.com/x.js').then(()=>loaded=true); function summarize(){return JSON.stringify(loaded)}", &json!(null)).unwrap(), json!(false));
        healthy();
    }

    #[test]
    fn output_limits_and_invalid_json() {
        for body in ["return 'x'.repeat(16385)", "return '中'.repeat(6000)"] {
            assert_eq!(
                summarize(&format!("function summarize(){{{body}}}"), &json!(null)).unwrap_err(),
                "Kit output exceeds 16 KiB"
            );
        }
        for body in [
            "return 'not json'",
            "return '{}' + String.fromCharCode(0) + 'junk'",
            "return '{}' + String.fromCharCode(0)",
            "return undefined",
            "return new String('{}')",
            "return 42",
        ] {
            assert!(summarize(&format!("function summarize(){{{body}}}"), &json!(null)).is_err());
        }
        assert_eq!(
            summarize(
                "function summarize(){return JSON.stringify('x'.repeat(16382))}",
                &json!(null)
            )
            .unwrap(),
            json!("x".repeat(16382))
        );
        assert_eq!(
            summarize(
                "String.prototype.toString=()=>{while(true){}}; function summarize(){return '{}'}",
                &json!(null)
            )
            .unwrap(),
            json!({})
        );
        healthy();
    }

    #[test]
    fn source_and_input_limits_count_utf8_bytes() {
        assert_eq!(
            summarize(&"中".repeat(SOURCE_LIMIT / 3 + 1), &json!(null)).unwrap_err(),
            "Kit source exceeds 24 KiB"
        );
        assert_eq!(
            summarize(HEALTHY, &json!("中".repeat(INPUT_LIMIT / 3 + 1))).unwrap_err(),
            "Kit input exceeds 256 KiB"
        );
        let source = "function summarize(){return '{}'}";
        let source = format!("{}{}", " ".repeat(SOURCE_LIMIT - source.len()), source);
        assert_eq!(summarize(&source, &json!(null)).unwrap(), json!({}));
        assert_eq!(
            summarize(
                "function summarize(input){return JSON.stringify(JSON.parse(input).length)}",
                &json!("x".repeat(INPUT_LIMIT - 2)),
            )
            .unwrap(),
            json!(INPUT_LIMIT - 2),
        );
        healthy();
    }

    #[test]
    fn memory_exhaustion_and_stack_overflow_do_not_poison_next_call() {
        // Prove that the allocation was denied, not merely that the return
        // value had the wrong type. This exceeds the QuickJS 8 MiB budget.
        assert_eq!(summarize("function summarize(){try {new ArrayBuffer(9*1024*1024); return 'false'} catch {return 'true'}}", &json!(null)).unwrap(), json!(true));
        for body in [
            "let arrays=[]; for(;;) arrays.push(new Uint8Array(1024*1024))",
            "function recurse(){return recurse()+1}; return recurse()",
        ] {
            assert!(summarize(&format!("function summarize(){{{body}}}"), &json!(null)).is_err());
            healthy();
        }
    }

    #[test]
    fn wasm_linear_memory_has_a_hard_cap() {
        let mut sandbox = Sandbox::new().unwrap();
        assert_eq!(sandbox.memory.data_size(&sandbox.store), 16 * 1024 * 1024);
        assert!(sandbox.memory.grow(&mut sandbox.store, 257).is_err());
        assert!(sandbox.memory.grow(&mut sandbox.store, 256).is_ok());
        assert_eq!(sandbox.memory.data_size(&sandbox.store), MEMORY_LIMIT);
        assert!(sandbox.memory.grow(&mut sandbox.store, 1).is_err());
        healthy();
    }
}
