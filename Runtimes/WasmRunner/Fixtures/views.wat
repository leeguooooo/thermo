;; Declarative UI fixture (#47): renders every kind of section and a menu bar item, runs an action
;; that asks the kernel for processes.read, and has an "evil" export with an unknown section type.
;; The kernel sends sorted-key JSON: {"language":"…","scene":"…"}. Built with
;;   swift run --package-path Runtimes/WasmRunner thermo-wat2wasm Runtimes/WasmRunner/Fixtures/views.wat Runtimes/WasmRunner/Fixtures/views.wasm
(module
  (import "thermo" "request" (func $request (param i32 i32 i32 i32) (result i32)))
  (import "thermo" "output" (func $output (param i32 i32)))
  (memory (export "memory") 2)
  (global $heap (mut i32) (i32.const 4096))
  (data (i32.const 16) "processes.read")
  (data (i32.const 46) "{\22op\22:\22list\22}")
  (data (i32.const 75) "{\22version\22:1,\22title\22:\22Probe\22,\22subtitle\22:\22Declarative fixture\22,\22sections\22:[{\22type\22:\22card\22,\22title\22:\22Processes\22,\22value\22:\223\22,\22caption\22:\22Read through processes.read\22,\22symbol\22:\22cpu\22,\22actions\22:[{\22action\22:\22refresh\22,\22title\22:\22Refresh\22}]},{\22type\22:\22list\22,\22id\22:\22items\22,\22title\22:\22Items\22,\22rows\22:[{\22id\22:\22a\22,\22title\22:\22Alpha\22,\22value\22:\221\22,\22symbol\22:\22star\22,\22action\22:\22open.a\22},{\22id\22:\22b\22,\22title\22:\22Beta\22,\22subtitle\22:\22Second row\22}]},{\22type\22:\22detail\22,\22title\22:\22About\22,\22fields\22:[{\22label\22:\22Version\22,\22value\22:\221\22}]},{\22type\22:\22form\22,\22id\22:\22prefs\22,\22title\22:\22Settings\22,\22fields\22:[{\22id\22:\22name\22,\22label\22:\22Name\22,\22input\22:\22text\22,\22value\22:\22probe\22},{\22id\22:\22count\22,\22label\22:\22Count\22,\22input\22:\22number\22,\22value\22:2},{\22id\22:\22on\22,\22label\22:\22Enabled\22,\22input\22:\22toggle\22,\22value\22:true},{\22id\22:\22mode\22,\22label\22:\22Mode\22,\22input\22:\22choice\22,\22value\22:\22fast\22,\22options\22:[{\22id\22:\22fast\22,\22title\22:\22Fast\22},{\22id\22:\22slow\22,\22title\22:\22Slow\22}]}],\22submit\22:{\22action\22:\22save\22,\22title\22:\22Save\22}}]}")
  (data (i32.const 984) "{\22version\22:1,\22title\22:\22Probe\22,\22sections\22:[{\22type\22:\22detail\22,\22title\22:\22Result\22,\22fields\22:[{\22label\22:\22Kernel answered\22,\22value\22:\22processes.read allowed\22}]}]}")
  (data (i32.const 1149) "{\22version\22:1,\22title\22:\22Probe\22,\22sections\22:[{\22type\22:\22detail\22,\22title\22:\22Result\22,\22fields\22:[{\22label\22:\22Kernel answered\22,\22value\22:\22refused\22}]}]}")
  (data (i32.const 1299) "{\22version\22:1,\22menuBarItem\22:{\22title\22:\22Probe\22,\22value\22:\223\22,\22symbol\22:\22cpu\22}}")
  (data (i32.const 1387) "{\22version\22:1,\22menuBarItem\22:{\22title\22:\22\e6\8e\a2\e9\92\88\22,\22value\22:\223\22,\22symbol\22:\22cpu\22}}")
  (data (i32.const 1476) "{\22version\22:1,\22sections\22:[{\22type\22:\22html\22,\22id\22:\22x\22,\22body\22:\22<script>\22}]}")
  (func (export "thermo_alloc") (param $len i32) (result i32)
    (local $p i32)
    global.get $heap
    local.set $p
    global.get $heap
    local.get $len
    i32.add
    global.set $heap
    local.get $p)
  ;; Scene "menu" ends the input with u"}; byte 13 is the language's first letter.
  (func (export "thermo_render") (param $p i32) (param $n i32) (result i32)
    local.get $p
    local.get $n
    i32.add
    i32.const 3
    i32.sub
    i32.load8_u
    i32.const 117
    i32.eq
    if
      local.get $p
      i32.load8_u offset=13
      i32.const 122
      i32.eq
      if
        i32.const 1387
    i32.const 73
    call $output
      else
        i32.const 1299
    i32.const 72
    call $output
      end
    else
      i32.const 75
    i32.const 893
    call $output
    end
    i32.const 0)
  (func (export "thermo_action") (param i32 i32) (result i32)
    i32.const 16
    i32.const 14
    i32.const 46
    i32.const 13
    call $request
    i32.const 0
    i32.lt_s
    if
      i32.const 1149
    i32.const 134
    call $output
    else
      i32.const 984
    i32.const 149
    call $output
    end
    i32.const 0)
  (func (export "evil") (param i32 i32) (result i32)
    i32.const 1476
    i32.const 69
    call $output
    i32.const 0))
