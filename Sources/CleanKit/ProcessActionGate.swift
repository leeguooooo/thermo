import AgentCore
import Foundation

/// Shared dispatch boundary. A checked identity is necessary, but never grants an exception
/// for a system process or Thermo's own executable/helper/module.
///
/// AI agent sessions are refused too, unless the caller passes `allowAgentSession`. Only the
/// Memory page does, for one process the user picked and confirmed by hand; one-click relief,
/// the CLI and modules keep the default and never end an agent session.
public enum ProcessActionGate {
    public enum Validation:Equatable {case allowed(ProcessIdentity),changed,protected,unavailable}
    public enum Outcome:Equatable {case requested,declined,changed,protected,unavailable}
    private static let ownBundle:String? = {
        let url=Bundle.main.bundleURL
        return url.pathExtension.lowercased()=="app" ? url.standardizedFileURL.path+"/":nil
    }()
    /// An AI coding agent's own process: the session, its launcher script or its app-server.
    public static func isAgent(_ process:SlowdownProcess)->Bool {
        let path=(process.executable ?? "").lowercased(),base=(path as NSString).lastPathComponent
        let names=ProcessTable.agentNames
        if names.contains(process.name.lowercased()) || names.contains(base) || path.contains("/claude/versions/"){return true}
        // Native agent launchers and interpreter entry scripts share the same protected rule.
        for value in process.argv.prefix(4) {
            let token=value.lowercased(),command=((token as NSString).lastPathComponent as NSString).deletingPathExtension
            if names.contains(command) || token.contains("/claude/versions/") || token.contains("/@anthropic-ai/claude-code/") || token.contains("/@openai/codex/"){return true}
        }
        return false
    }
    public static func mayControl(_ process:SlowdownProcess,allowApplication:Bool,allowAgentSession:Bool = false,uid:UInt32 = getuid(),me:Int32 = getpid())->Bool {
        guard process.pid>1,process.pid != me,process.uid==uid,!SlowdownDiagnosis.isSystem(process,me:uid),
              let executable=process.executable,!executable.isEmpty else{return false}
        let path=executable.lowercased(),base=(path as NSString).lastPathComponent
        if process.name.lowercased().hasPrefix("thermo") || base.hasPrefix("thermo") || base=="dev.thermo.helper"
            || path.contains("/thermo.app/contents/") || ownBundle.map({executable.hasPrefix($0)})==true {return false}
        if !allowAgentSession && isAgent(process){return false}
        return allowApplication || !executable.contains(".app/Contents/MacOS/")
    }
    public static func identityAllows(_ expected:ProcessIdentity,current:ProcessIdentity?,uid:UInt32 = getuid(),me:Int32 = getpid())->Bool {
        guard expected==current else{return false}
        return mayControl(.init(pid:expected.pid,ppid:1,uid:expected.uid,name:(expected.executable as NSString).lastPathComponent,
                                executable:expected.executable,started:expected.started),allowApplication:true,uid:uid,me:me)
    }
    public static func validate(_ expected:ProcessIdentity?,allowApplication:Bool,allowAgentSession:Bool = false,
        uid:UInt32 = getuid(),me:Int32 = getpid(),
        identity:(Int32)->ProcessIdentity? = ProcessTable.identity,
        details:(Int32)->ProcessDetails = ProcessTable.details)->Validation {
        guard let expected,let current=identity(expected.pid),current==expected else{return .changed}
        let info=details(current.pid)
        guard let executable=info.executable,executable==current.executable else{return .unavailable}
        let process=SlowdownProcess(pid:current.pid,ppid:1,uid:current.uid,name:(executable as NSString).lastPathComponent,
                                   executable:executable,argv:info.argv,cwd:info.cwd,started:current.started)
        guard mayControl(process,allowApplication:allowApplication,allowAgentSession:allowAgentSession,uid:uid,me:me) else{return .protected}
        // Details are a separate native read; refuse PID reuse or exec across that boundary too.
        guard identity(current.pid)==current else{return .changed}
        return .allowed(current)
    }
    public static func attempt(_ expected:ProcessIdentity?,allowApplication:Bool,allowAgentSession:Bool = false,
        uid:UInt32 = getuid(),me:Int32 = getpid(),
        identity:(Int32)->ProcessIdentity? = ProcessTable.identity,
        details:(Int32)->ProcessDetails = ProcessTable.details,
        request:(ProcessIdentity)->Bool)->Outcome {
        switch validate(expected,allowApplication:allowApplication,allowAgentSession:allowAgentSession,uid:uid,me:me,identity:identity,details:details) {
        case let .allowed(current):return request(current) ? .requested:.declined
        case .changed:return .changed
        case .protected:return .protected
        case .unavailable:return .unavailable
        }
    }
}
