;; Example Thermo module (#48): counts running processes.
;;
;; It declares one capability, processes.read, in module.json. On every render it asks the kernel
;; for the process list, counts the "pid": keys in the answer and writes the number into the view's
;; {{n}} hole. If the kernel refuses, it shows views/refused.json instead. "Refresh" leaves the output
;; empty, which makes the kernel render the page again.
;;
;; `thermo dev build` replaces the @thermo-strings line with memory, the heap and every file in
;; views/ and strings/ (address in $view_main, length in $view_main_len, and so on).
(module
  (import "thermo" "request" (func $request (param i32 i32 i32 i32) (result i32)))
  (import "thermo" "answer" (func $answer (param i32 i32) (result i32)))
  (import "thermo" "output" (func $output (param i32 i32)))
  ;; @thermo-strings

  ;; The kernel calls this once at the start of every call: start the heap over.
  (func (export "thermo_alloc") (param $len i32) (result i32)
    (global.set $heap (global.get $heap_base))
    (call $alloc (local.get $len)))

  (func $alloc (param $len i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (local.get $len)))
    (local.get $p))

  ;; 1 when [p, p+n) starts with [needle, needle+len).
  (func $starts (param $p i32) (param $n i32) (param $needle i32) (param $len i32) (result i32)
    (local $j i32)
    (if (i32.lt_u (local.get $n) (local.get $len)) (then (return (i32.const 0))))
    (block $done
      (loop $compare
        (br_if $done (i32.ge_u (local.get $j) (local.get $len)))
        (if (i32.ne (i32.load8_u (i32.add (local.get $p) (local.get $j))) (i32.load8_u (i32.add (local.get $needle) (local.get $j))))
          (then (return (i32.const 0))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $compare)))
    (i32.const 1))

  ;; How many times the needle occurs in [p, p+n).
  (func $count (param $p i32) (param $n i32) (param $needle i32) (param $len i32) (result i32)
    (local $i i32) (local $found i32)
    (block $done
      (loop $scan
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (if (call $starts (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $n) (local.get $i)) (local.get $needle) (local.get $len))
          (then
            (local.set $found (i32.add (local.get $found) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (local.get $len))))
          (else (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $scan)))
    (local.get $found))

  ;; Writes $v in decimal at $out; returns how many bytes.
  (func $digits (param $v i32) (param $out i32) (result i32)
    (local $rest i32) (local $n i32) (local $i i32)
    (local.set $rest (local.get $v))
    (local.set $n (i32.const 1))
    (block $counted
      (loop $more
        (br_if $counted (i32.lt_u (local.get $rest) (i32.const 10)))
        (local.set $rest (i32.div_u (local.get $rest) (i32.const 10)))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (br $more)))
    (local.set $i (local.get $n))
    (local.set $rest (local.get $v))
    (loop $write
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (i32.store8 (i32.add (local.get $out) (local.get $i)) (i32.add (i32.const 48) (i32.rem_u (local.get $rest) (i32.const 10))))
      (local.set $rest (i32.div_u (local.get $rest) (i32.const 10)))
      (br_if $write (i32.gt_u (local.get $i) (i32.const 0))))
    (local.get $n))

  ;; Outputs the view [t, t+tn) with every {{n}} replaced by $value.
  (func $emit_filled (param $t i32) (param $tn i32) (param $value i32)
    (local $dst i32) (local $i i32) (local $o i32)
    (local.set $dst (call $alloc (i32.add (i32.mul (local.get $tn) (i32.const 2)) (i32.const 16))))
    (block $done
      (loop $copy
        (br_if $done (i32.ge_u (local.get $i) (local.get $tn)))
        (if (call $starts (i32.add (local.get $t) (local.get $i)) (i32.sub (local.get $tn) (local.get $i)) (global.get $str_hole) (global.get $str_hole_len))
          (then
            (local.set $o (i32.add (local.get $o) (call $digits (local.get $value) (i32.add (local.get $dst) (local.get $o)))))
            (local.set $i (i32.add (local.get $i) (global.get $str_hole_len))))
          (else
            (i32.store8 (i32.add (local.get $dst) (local.get $o)) (i32.load8_u (i32.add (local.get $t) (local.get $i))))
            (local.set $o (i32.add (local.get $o) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $copy)))
    (call $output (local.get $dst) (local.get $o)))

  ;; Asks the kernel for the process list; the number of processes, or -1 when refused.
  (func $processes (result i32)
    (local $len i32) (local $buffer i32)
    (local.set $len (call $request (global.get $str_capability) (global.get $str_capability_len) (global.get $str_list) (global.get $str_list_len)))
    (if (i32.lt_s (local.get $len) (i32.const 0)) (then (return (i32.const -1))))
    (local.set $buffer (call $alloc (local.get $len)))
    (call $count (local.get $buffer) (call $answer (local.get $buffer) (local.get $len)) (global.get $str_pid) (global.get $str_pid_len)))

  (func (export "thermo_render") (param $p i32) (param $n i32) (result i32)
    (local $count i32)
    (local.set $count (call $processes))
    (if (i32.lt_s (local.get $count) (i32.const 0))
      (then
        (call $output (global.get $view_refused) (global.get $view_refused_len))
        (return (i32.const 0))))
    (if (call $is_menu (local.get $p) (local.get $n))
      (then (call $emit_filled (global.get $view_menu) (global.get $view_menu_len) (local.get $count)))
      (else (call $emit_filled (global.get $view_main) (global.get $view_main_len) (local.get $count))))
    (i32.const 0))

  ;; 1 when the request is for the menu bar scene.
  (func $is_menu (param $p i32) (param $n i32) (result i32)
    (local $i i32)
    (block $done
      (loop $scan
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (if (call $starts (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $n) (local.get $i)) (global.get $str_scene_menu) (global.get $str_scene_menu_len))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan)))
    (i32.const 0))

  ;; "refresh": nothing to do; an empty output renders the page again with a fresh count.
  (func (export "thermo_action") (param $p i32) (param $n i32) (result i32)
    (i32.const 0))
)
