// Actual installed tools through production scanning, review and cleanup in a marked test home.
@testable import CleanKit
@testable import ThermoApp
import CryptoKit
import Foundation
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func nativeCacheFixtureMenus() {}

enum NativeCacheFixture {
    static func files(_ roots: [String]) -> [String:String] {
        var result: [String:String]=[:]
        for root in roots {
            guard let entries=FileManager.default.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { continue }
            for case let url as URL in entries {
                guard let values=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),
                      values.isRegularFile == true,values.isSymbolicLink != true,
                      let data=try? Data(contentsOf:url) else { continue }
                result[url.path]=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
            }
        }
        return result
    }
}

@main struct NativeCacheToolAcceptance {
    @MainActor static func main() throws {
        guard getuid() != 0,CommandLine.arguments.count == 4 else { exit(2) }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        let id=CommandLine.arguments[2],mode=CommandLine.arguments[3]
        guard root.lastPathComponent.hasPrefix("thermo-native-tools-live-"),
              FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-native-tools-live").path),
              ["npm-cache","pip-cache","uv-cache","go-cache"].contains(id),["scan","clean"].contains(mode) else { exit(3) }
        let testHome=root.appendingPathComponent("home").path
        L10n.override = .english
        var options=ScanOptions();options.home=testHome;options.categories=[.devCaches];options.onlyIDs=[id]
        options.olderThanDays=0;options.exactSizes=true
        let scanner=DiskScanner(options:options);scanner.saveReport=false
        let report=scanner.scan()
        guard !report.cancelled,report.whitelistError == nil,let item=report.items.first(where:{$0.id==id}),
              item.blocked == nil,let native=item.native,!native.runs.isEmpty,
              item.paths.allSatisfy({$0.hasPrefix(testHome+"/")}),native.runs.allSatisfy({$0.folder.hasPrefix(testHome+"/")}) else {
            throw NSError(domain:"NativeCacheQA",code:4,userInfo:[NSLocalizedDescriptionKey:"No unblocked native item for "+id+": "+report.items.map { $0.id+"="+($0.blocked ?? "available") }.joined(separator:", ")])
        }
        let model=DiskModel(report:report);model.selected=[id]
        let preview=model.planLines
        let folders=native.runs.map(\.folder),before=NativeCacheFixture.files(folders)
        var output: [String:Any]=["id":id,"mode":mode,"home":testHome,"scannedBytes":item.bytes,
            "nativeFolders":folders,"nativeCommands":native.runs.map(\.commandLine),"preview":preview,
            "nativeExecutables":native.runs.compactMap(\.executable),
            "previewContainsEveryNativeFolder":folders.allSatisfy { folder in preview.contains { $0.contains(folder) } },
            "previewContainsEveryExecutable":native.runs.compactMap(\.executable).allSatisfy { program in preview.contains { $0.contains(program) } },
            "beforeFiles":before]
        if mode == "clean" {
            let live=RemovalOperations.live
            var operations=live,commands:[[String]]=[],rawRemovals:[String]=[],afterTool:[String:String]=[:]
            operations.run={ argv,timeout in
                commands.append(argv)
                let result=live.run(argv,timeout)
                afterTool=NativeCacheFixture.files(folders)
                return result
            }
            operations.remove={ path in rawRemovals.append(path);try live.remove(path) }
            let result=Cleaner.clean(item,mode:.auto,guard:Guard(home:testHome),scannedAt:report.started,
                processTable:nil,batchID:nil,operations:operations)
            let encoded=try JSONEncoder().encode(result)
            output["result"]=try JSONSerialization.jsonObject(with:encoded)
            output["commandsExecuted"]=commands;output["rawRemovalCalls"]=rawRemovals
            output["afterToolFiles"]=afterTool;output["afterCleanerFiles"]=NativeCacheFixture.files(folders)
            output["noRawDeletionInsideNativeFolders"]=rawRemovals.allSatisfy { path in !folders.contains { path == $0 || path.hasPrefix($0+"/") } }
        }
        let data=try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
        FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))
    }
}
