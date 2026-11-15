import AppKit
import CaptureCore
import ThermoL10n
import UniformTypeIdentifiers

/// Manual saves remember only a successfully written destination. Automatic saves use their own settings.
@MainActor final class CaptureManualImageSave:NSObject {
    private struct Selection:Codable {
        let directory:String
        let format:CaptureSaveFormat
        var valid:Bool { directory.hasPrefix("/") && directory.utf8.count <= 4096 && !directory.contains("\0") }
    }
    nonisolated static let preferenceKey="dev.thermo.capture.manual-save.v1"
    private let write:(Data)->Void
    private(set) var format:CaptureSaveFormat = .png
    private(set) var directory:URL?
    private weak var panel:NSSavePanel?
    init(read:()->Data?={UserDefaults.standard.data(forKey:preferenceKey)},write:@escaping(Data)->Void={UserDefaults.standard.set($0,forKey:preferenceKey)}) {
        self.write=write
        super.init()
        if let data=read(),data.count <= 8192,let value=try? JSONDecoder().decode(Selection.self,from:data),value.valid {
            format=value.format
            var isDirectory:ObjCBool=false
            if FileManager.default.fileExists(atPath:value.directory,isDirectory:&isDirectory),isDirectory.boolValue {
                directory=URL(fileURLWithPath:value.directory,isDirectory:true)
            }
        }
    }
    func configure(_ panel:NSSavePanel,name:String) {
        self.panel=panel
        panel.allowsOtherFileTypes=false
        panel.directoryURL=directory
        panel.nameFieldStringValue=name+"."+format.fileExtension
        let label=NSTextField(labelWithString:tr("Image format"))
        let popup=NSPopUpButton(frame:NSRect(x:0,y:0,width:130,height:26),pullsDown:false)
        popup.addItems(withTitles:["PNG","JPEG","TIFF"])
        popup.selectItem(at:CaptureSaveFormat.allCases.firstIndex(of:format) ?? 0)
        popup.target=self;popup.action=#selector(changeFormat(_:))
        popup.setAccessibilityLabel(tr("Image format"))
        let stack=NSStackView(views:[label,popup]);stack.orientation = .horizontal;stack.spacing=10
        stack.frame=NSRect(x:0,y:0,width:260,height:32)
        panel.accessoryView=stack
        select(format)
    }
    @objc private func changeFormat(_ sender:NSPopUpButton) {
        guard CaptureSaveFormat.allCases.indices.contains(sender.indexOfSelectedItem) else {return}
        select(CaptureSaveFormat.allCases[sender.indexOfSelectedItem])
    }
    func select(_ next:CaptureSaveFormat) {
        format=next
        guard let panel else {return}
        let name=panel.nameFieldStringValue as NSString
        let known=["png","jpg","jpeg","tif","tiff"].contains(name.pathExtension.lowercased())
        panel.allowedContentTypes=[next == .png ? .png : (next == .jpeg ? .jpeg : .tiff)]
        panel.nameFieldStringValue=(known ? name.deletingPathExtension : name as String)+"."+next.fileExtension
    }
    func save(_ document:CaptureDocument,to url:URL,quality:Double) throws {
        try CaptureImageSave.encode(document,format:format,quality:quality).write(to:url,options:.atomic)
        let selection=Selection(directory:url.deletingLastPathComponent().path,format:format)
        if selection.valid,let data=try? JSONEncoder().encode(selection) {write(data)}
    }
}
