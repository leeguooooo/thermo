// No real interface writes. "probe" only reads awdl0. The other modes operate
// a JSON-backed interface in an owned directory and intentionally crash one worker.
import Darwin
import Foundation
import ThermoKit

func emit(_ value: [String:Any]) throws {
    let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    print(String(decoding:data,as:UTF8.self));fflush(stdout)
}

@main struct AWDLRecoveryAcceptance {
    static func main() throws {
        guard CommandLine.arguments.count >= 2,getuid() != 0 else { exit(2) }
        let phase=CommandLine.arguments[1]
        if phase == "probe" {
            let value=try AWDLInterfaceIO.system.read()
            var result: [String:Any] = ["mode":"readOnlyProbe","present":value != nil,"bootIdentityAvailable":AWDLSystemClock.bootSession() != nil,
                                       "continuousClockAvailable":AWDLSystemClock.now().isFinite]
            if let value { result["index"]=value.index;result["up"]=value.up }
            try emit(result);return
        }
        guard CommandLine.arguments.count == 3,["arm-crash","prepared-crash","recover"].contains(phase) else { exit(2) }
        let root=URL(fileURLWithPath:CommandLine.arguments[2]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-awdl-recovery-"),
              FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-awdl-recovery-fixture").path) else { exit(3) }
        let interfaceFile=root.appendingPathComponent("interface.json")
        var writes=0
        let simulated=AWDLInterfaceIO(read:{
            try JSONDecoder().decode(AWDLInterfaceState.self,from:Data(contentsOf:interfaceFile))
        },write:{ index,up in
            if phase == "prepared-crash",!up {
                try emit(["mode":"simulatedPreparedCrash","interfaceUp":true,"recordSaved":FileManager.default.fileExists(atPath:root.appendingPathComponent("dev.thermo.awdl-lease").path)])
                kill(getpid(),SIGKILL);exit(5)
            }
            writes+=1
            let before=try JSONDecoder().decode(AWDLInterfaceState.self,from:Data(contentsOf:interfaceFile))
            guard before.index == index else { throw AWDLError("fixture interface changed") }
            try JSONEncoder().encode(AWDLInterfaceState(index:index,up:up)).write(to:interfaceFile,options:.atomic)
        })
        let file=AWDLLeaseFile(directory:root.path,owner:getuid())
        let controller=AWDLSessionController(io:simulated,store:file.io,boot:{ "22222222-2222-2222-2222-222222222222" })
        if phase == "arm-crash" || phase == "prepared-crash" {
            try controller.begin(owner:"11111111-1111-1111-1111-111111111111",seconds:60)
            guard controller.snapshot().phase == .active,try simulated.read()?.up == false else { exit(4) }
            try emit(["mode":"simulatedCrash","active":true,"interfaceUp":false])
            kill(getpid(),SIGKILL);exit(5)
        }
        let state=controller.snapshot()
        let gone = !FileManager.default.fileExists(atPath:root.appendingPathComponent("dev.thermo.awdl-lease").path)
        guard state.phase == .idle,try simulated.read()?.up == true,gone else { exit(6) }
        try emit(["mode":"simulatedRecovery","phase":state.phase.rawValue,"interfaceUp":true,"recordRemoved":gone,"writes":writes,"reason":state.lastEndReason ?? "unknown"])
    }
}
