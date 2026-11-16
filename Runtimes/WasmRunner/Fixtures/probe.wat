;; Test module for the WebAssembly runner (#46). Build the .wasm next to it with
;;   swift run --package-path Runtimes/WasmRunner thermo-wat2wasm Runtimes/WasmRunner/Fixtures/probe.wat Runtimes/WasmRunner/Fixtures/probe.wasm
(module
  (import "thermo" "request" (func $request (param i32 i32 i32 i32) (result i32)))
  (import "thermo" "answer" (func $answer (param i32 i32) (result i32)))
  (import "thermo" "output" (func $output (param i32 i32)))
  (memory (export "memory") 1)
  (global $heap (mut i32) (i32.const 4096))
  (data (i32.const 16) "processes.read")
  (data (i32.const 64) "files.read:/etc/hosts")
  (data (i32.const 128) "{\"op\":\"list\"}")

  ;; Bump allocator for the input the host copies in.
  (func (export "thermo_alloc") (param $len i32) (result i32)
    (local $p i32)
    global.get $heap
    local.set $p
    global.get $heap
    local.get $len
    i32.add
    global.set $heap
    local.get $p)

  ;; Output = input.
  (func (export "echo") (param $p i32) (param $n i32) (result i32)
    local.get $p
    local.get $n
    call $output
    i32.const 0)

  ;; Asks for a declared capability and returns what the kernel answered.
  (func (export "allowed") (param i32 i32) (result i32)
    (local $len i32)
    i32.const 16
    i32.const 14
    i32.const 128
    i32.const 13
    call $request
    local.tee $len
    i32.const 0
    i32.lt_s
    if
      local.get $len
      return
    end
    i32.const 2048
    local.get $len
    call $answer
    drop
    i32.const 2048
    local.get $len
    call $output
    i32.const 0)

  ;; Asks for a capability the manifest does not declare; returns the request's result code.
  (func (export "denied") (param i32 i32) (result i32)
    i32.const 64
    i32.const 21
    i32.const 0
    i32.const 0
    call $request)

  ;; Never returns.
  (func (export "spin") (param i32 i32) (result i32)
    (loop $forever
      br $forever)
    i32.const 0)

  ;; Asks for 256 MiB more memory; returns -1 when refused.
  (func (export "grow") (param i32 i32) (result i32)
    i32.const 4096
    memory.grow)

  (func (export "trap") (param i32 i32) (result i32)
    unreachable))
