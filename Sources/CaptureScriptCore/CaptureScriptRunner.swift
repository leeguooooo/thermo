import Foundation
import Darwin

public struct CaptureScriptResult:Sendable,Equatable {
    public var value:CaptureScriptValue
    public var logs:[String]
    public init(value:CaptureScriptValue,logs:[String]){self.value=value;self.logs=logs}
}
public enum CaptureScriptRunner {
    public static func run(source:String,worker:URL,timeout:TimeInterval=300,memoryBytes:UInt64=256*1024*1024,
                           perform:@escaping @Sendable(String) async throws -> CaptureScriptValue) async throws -> CaptureScriptResult {
        guard !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,source.utf8.count<=16384,timeout.isFinite,timeout>0,memoryBytes>0 else {throw CaptureScriptFailure.invalidSource}
        let controller=ScriptProcessController()
        let task=Task.detached(priority:.userInitiated) { () throws -> CaptureScriptResult in
            let child:ScriptChild
            do {child=try controller.launch(worker)} catch {throw controller.failure ?? CaptureScriptFailure.unavailable}
            defer {controller.finish();close(child.input);close(child.output)}
            let timer=DispatchSource.makeTimerSource(queue:.global(qos:.utility));let start=DispatchTime.now().uptimeNanoseconds
            timer.schedule(deadline:.now(),repeating:.milliseconds(50))
            timer.setEventHandler {
                if Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000_000 > timeout {controller.stop(.timedOut);return}
                var info=proc_taskinfo()
                if proc_pidinfo(child.pid,PROC_PIDTASKINFO,0,&info,Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size,info.pti_resident_size > memoryBytes {controller.stop(.memoryLimit)}
            };timer.resume();defer{timer.cancel()}
            _=fcntl(child.input,F_SETNOSIGPIPE,1)
            do {
                try CaptureScriptWire.write(.init("start",source:source),to:child.input)
                let reader=CaptureScriptWire(descriptor:child.output)
                var logs:[String]=[],calls=0,bytes=0,lastID=0
                while true {
                    if let failure=controller.failure {throw failure}
                    let message=try reader.read();bytes += (message.text?.utf8.count ?? 0)+128
                    guard bytes <= 1_048_576 else {throw CaptureScriptFailure.protocolError}
                    switch message.kind {
                    case "call":
                        guard let id=message.id,id == lastID+1,let action=message.action,action.utf8.count<=64,calls<1000 else {throw CaptureScriptFailure.protocolError}
                        calls += 1;lastID=id
                        let response:CaptureScriptMessage
                        do {
                            let value=try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<CaptureScriptValue,Error>) in
                                let gate=ScriptReplyGate(continuation)
                                let actionTask=Task {
                                    do {try Task.checkCancellation();gate.finish(.success(try await perform(action)))}
                                    catch {gate.finish(.failure(error))}
                                }
                                controller.handler({actionTask.cancel();gate.finish(.failure(controller.failure ?? CaptureScriptFailure.cancelled))})
                            }
                            response = .init("reply",id:id,value:value)
                        } catch {response = .init("reply",id:id,text:String(error.localizedDescription.prefix(2048)))}
                        controller.handler(nil)
                        if let failure=controller.failure {throw failure}
                        try CaptureScriptWire.write(response,to:child.input)
                    case "log":
                        guard logs.count<256,let text=message.text,text.utf8.count<=4096 else {throw CaptureScriptFailure.protocolError};logs.append(text)
                    case "done":
                        guard let value=message.value else {throw CaptureScriptFailure.protocolError}
                        if let failure=controller.failure {throw failure};return .init(value:value,logs:logs)
                    case "failure":throw CaptureScriptFailure.execution(String((message.text ?? "Script failed.").prefix(4096)))
                    default:throw CaptureScriptFailure.protocolError
                    }
                }
            } catch {throw controller.failure ?? error}
        }
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{controller.stop(.cancelled)})
    }
}
private struct ScriptChild {
    let pid:pid_t
    let input:Int32
    let output:Int32
    static func spawn(_ executable:URL) throws -> Self {
        guard executable.isFileURL else {throw CaptureScriptFailure.unavailable}
        var input:[Int32]=[0,0],output:[Int32]=[0,0]
        guard pipe(&input) == 0 else {throw CaptureScriptFailure.unavailable}
        guard pipe(&output) == 0 else {close(input[0]);close(input[1]);throw CaptureScriptFailure.unavailable}
        var keep=false
        defer {close(input[0]);close(output[1]);if !keep{close(input[1]);close(output[0])}}
        for fd in input+output {_=fcntl(fd,F_SETFD,FD_CLOEXEC)}
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {throw CaptureScriptFailure.unavailable}
        defer{posix_spawn_file_actions_destroy(&actions)}
        guard posix_spawnattr_init(&attributes) == 0 else {throw CaptureScriptFailure.unavailable}
        defer{posix_spawnattr_destroy(&attributes)}
        var mask=sigset_t();sigemptyset(&mask)
        guard posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK)) == 0,
              posix_spawnattr_setsigmask(&attributes,&mask) == 0,
              posix_spawn_file_actions_adddup2(&actions,input[0],STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions,output[1],STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0) == 0 else {throw CaptureScriptFailure.unavailable}
        var arguments:[UnsafeMutablePointer<CChar>?]=[strdup(executable.path),nil],environment:[UnsafeMutablePointer<CChar>?]=[nil],pid:pid_t=0
        defer{free(arguments[0])}
        guard posix_spawn(&pid,executable.path,&actions,&attributes,&arguments,&environment) == 0 else {throw CaptureScriptFailure.unavailable}
        keep=true;return .init(pid:pid,input:input[1],output:output[0])
    }
}
private final class ScriptProcessController:@unchecked Sendable {
    private let lock=NSLock()
    private var child:ScriptChild?
    private var reason:CaptureScriptFailure?
    private var cancelHandler:(@Sendable()->Void)?
    var failure:CaptureScriptFailure? {lock.lock();defer{lock.unlock()};return reason}
    func launch(_ executable:URL) throws -> ScriptChild {
        lock.lock();defer{lock.unlock()};if let reason{throw reason};let value=try ScriptChild.spawn(executable);child=value;return value
    }
    func handler(_ value:(@Sendable()->Void)?) {
        lock.lock();cancelHandler=value;let stopped=reason != nil;lock.unlock();if stopped{value?()}
    }
    func stop(_ value:CaptureScriptFailure) {
        lock.lock();if reason == nil {reason=value};let handler=cancelHandler
        // PID remains owned and unreaped until finish, so it cannot be recycled under a cancellation.
        if let child{kill(child.pid,SIGKILL)}
        lock.unlock();handler?()
    }
    func finish() {
        lock.lock();let child=self.child;self.child=nil;cancelHandler=nil
        if let child{kill(child.pid,SIGKILL)}
        lock.unlock()
        if let child{var status:Int32=0;while waitpid(child.pid,&status,0)<0 && errno == EINTR{}}
    }
}

private final class ScriptReplyGate:@unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<CaptureScriptValue,Error>?
    init(_ value:CheckedContinuation<CaptureScriptValue,Error>){continuation=value}
    func finish(_ value:Result<CaptureScriptValue,Error>) {
        lock.lock();let next=continuation;continuation=nil;lock.unlock();next?.resume(with:value)
    }
}
