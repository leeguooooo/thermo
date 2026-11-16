import Darwin
import WasmRunnerCore

// Started by Thermo's kernel with the module on stdin. Never reads arguments or the environment:
// all it gets is the pipe, and once the module is loaded it cannot open anything else.
signal(SIGPIPE, SIG_IGN)
exit(RunnerSession(io: FrameIO(input: STDIN_FILENO, output: STDOUT_FILENO)).run())
