import Foundation
import JavaScriptCore
import Darwin
import CaptureScriptCore

// No AppKit, user preferences, root helper, file/network or process API is exposed to JavaScript.
signal(SIGPIPE,SIG_IGN)
var coreLimit=rlimit(rlim_cur:0,rlim_max:0),cpuLimit=rlimit(rlim_cur:10,rlim_max:11)
let limitsApplied=setrlimit(RLIMIT_CORE,&coreLimit) == 0 && setrlimit(RLIMIT_CPU,&cpuLimit) == 0
let reader=CaptureScriptWire(descriptor:STDIN_FILENO)
func send(_ message:CaptureScriptMessage){do{try CaptureScriptWire.write(message,to:STDOUT_FILENO)}catch{exit(2)}}
do {
    guard limitsApplied else{throw CaptureScriptFailure.execution("Could not apply capture script process limits.")}
    let start=try reader.read()
    guard start.kind == "start",let source=start.source,!source.isEmpty,source.utf8.count<=16384,let context=JSContext() else {throw CaptureScriptFailure.invalidSource}
    var identifier=0,failed:String?
    let call:@convention(block)(String)->String={action in
        identifier += 1
        do {
            guard action.utf8.count<=64,identifier<=1000 else {throw CaptureScriptFailure.protocolError}
            send(.init("call",id:identifier,action:action))
            let reply=try reader.read();guard reply.kind == "reply",reply.id == identifier else {throw CaptureScriptFailure.protocolError}
            let data=try JSONEncoder().encode(reply);return String(decoding:data,as:UTF8.self)
        } catch {return "{\"text\":\"Capture script connection closed.\"}"}
    }
    let log:@convention(block)(String)->Void={text in send(.init("log",text:String(text.prefix(1024))))}
    context.setObject(call,forKeyedSubscript:"__thermoCall" as NSString);context.setObject(log,forKeyedSubscript:"__thermoLog" as NSString)
    context.exceptionHandler={_,value in failed=String((value?.toString() ?? "Script failed.").prefix(4096))}
    let bootstrap="""
    (function(call,log) {
      Object.defineProperty(globalThis, 'thermo', {value:Object.freeze({perform:function(action) {
        if (typeof action !== 'string') throw new TypeError('An action ID string is required.');
        var reply=JSON.parse(call(action));if(reply.text)throw new Error(reply.text);return reply.value;
      }}), writable:false, configurable:false});
      Object.defineProperty(globalThis,'console',{value:Object.freeze({log:function(){log(Array.from(arguments).map(String).join(' '));}}),writable:false});
    })(__thermoCall,__thermoLog);
    delete globalThis.__thermoCall;delete globalThis.__thermoLog;
    """
    context.evaluateScript(bootstrap)
    let output=context.evaluateScript("""
    (function(){'use strict'; var result=(function(){
    \(source)
    })();if(result && typeof result.then === 'function')throw new Error('Return a synchronous result; Promise scripts are not supported.');return JSON.stringify(result === undefined ? null : result);})();
    """,withSourceURL:URL(string:"thermo-script://configured-action"))
    if let failed {throw CaptureScriptFailure.execution(failed)}
    guard let json=output?.toString(),json.utf8.count<=32768,let data=json.data(using:.utf8) else {throw CaptureScriptFailure.protocolError}
    send(.init("done",value:try JSONDecoder().decode(CaptureScriptValue.self,from:data)))
} catch {send(.init("failure",text:String(error.localizedDescription.prefix(4096))));exit(1)}
