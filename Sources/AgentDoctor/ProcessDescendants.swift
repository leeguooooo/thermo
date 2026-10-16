import AgentCore
import Foundation

/// Relationships from one process-table reading, rechecked before publication.
/// No arguments, cwd, signals, or original-launcher attribution are involved.
public struct ProcessDescendants: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case observed, noneObserved, unavailable }
    public struct Child: Codable, Sendable, Equatable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var parentPID: Int32
        public var uid: UInt32
        public var started: Date
        public var name: String
        public var executable: String
        public var depth: Int
    }
    public var state: State
    public var children: [Child]
    public var queryComplete: Bool
    public var inventoryComplete: Bool
    public var limited: Bool

    static var unavailable: Self { .init(state:.unavailable,children:[],queryComplete:false,inventoryComplete:false,limited:false) }

    static func capture(_ expected: ProcessIdentity, table: ProcessTable,
                        identity: (Int32) -> ProcessIdentity?, parent: (Int32) -> Int32?,
                        maximumNodes: Int = 128, maximumDepth: Int = 16,
                        clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) -> Self {
        guard table.available,expected.pid > 0,maximumNodes > 0,maximumNodes <= 512,
              maximumDepth > 0,maximumDepth <= 64,identity(expected.pid) == expected else { return unavailable }
        let started=clock()
        func inBudget() -> Bool { let now=clock();return now >= started && now-started < 500_000_000 }
        let grouped=Dictionary(grouping:table.entries,by:\.pid)
        guard grouped[expected.pid]?.count == 1,let target=grouped[expected.pid]?.first,target.sampledIdentity == expected,
              !target.executableFromArgv,target.uid == expected.uid,target.executable == expected.executable else { return unavailable }
        let byParent=Dictionary(grouping:table.entries.filter { $0.pid > 0 },by:\.ppid)
        var pending: [(Int32,Int)] = [(expected.pid,0)],index=0,examined=0,seen: Set<Int32>=[expected.pid]
        var candidates: [(AgentProcess,Int)] = [],complete=table.inventoryComplete && table.includesAllUsers,limited=false
        traversal: while index < pending.count {
            let (pid,depth)=pending[index];index+=1
            let children=(byParent[pid] ?? []).sorted { $0.pid < $1.pid }
            if depth >= maximumDepth {
                if !children.isEmpty { complete=false;limited=true };continue
            }
            for child in children {
                guard examined < maximumNodes*4,inBudget() else { complete=false;limited=true;break traversal }
                examined+=1
                guard seen.insert(child.pid).inserted,grouped[child.pid]?.count == 1 else { complete=false;continue }
                guard candidates.count < maximumNodes else { complete=false;limited=true;break traversal }
                guard let snapshot=child.sampledIdentity,!child.executableFromArgv,
                      snapshot.pid == child.pid,snapshot.uid == child.uid,snapshot.executable == child.executable,
                      identity(child.pid) == snapshot,parent(child.pid) == pid,identity(child.pid) == snapshot else { complete=false;continue }
                candidates.append((child,depth+1));pending.append((child.pid,depth+1))
            }
        }
        // Parents precede children, so an invalidated edge also discards its subtree.
        var accepted: Set<Int32>=[expected.pid],result: [Child]=[]
        for (child,depth) in candidates {
            guard inBudget() else { complete=false;limited=true;break }
            guard accepted.contains(child.ppid),let snapshot=child.sampledIdentity,
                  identity(child.pid) == snapshot,parent(child.pid) == child.ppid,identity(child.pid) == snapshot else { complete=false;continue }
            accepted.insert(child.pid)
            result.append(.init(pid:child.pid,parentPID:child.ppid,uid:child.uid,started:snapshot.started,
                                name:ProcessExplanation.displayed(child.name),executable:ProcessExplanation.displayed(snapshot.executable),depth:depth))
        }
        if !inBudget() { complete=false;limited=true }
        guard identity(expected.pid) == expected else { return unavailable }
        let acceptedByParent=Dictionary(grouping:result,by:\.parentPID)
        var stack=Array((acceptedByParent[expected.pid] ?? []).reversed()),ordered: [Child]=[]
        while let child=stack.popLast() {
            ordered.append(child);stack.append(contentsOf:(acceptedByParent[child.pid] ?? []).reversed())
        }
        return .init(state:result.isEmpty ? complete ? .noneObserved : .unavailable : .observed,
                     children:ordered,queryComplete:complete,inventoryComplete:table.inventoryComplete && table.includesAllUsers,limited:limited)
    }
}
