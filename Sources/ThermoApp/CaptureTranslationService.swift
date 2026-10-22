import AppKit
import CaptureCore
import Security
import ThermoL10n

@MainActor protocol CaptureTranslationSecrets {
    func read(_ account:String)throws->CaptureTranslationCredential?
    func write(_ credential:CaptureTranslationCredential?,account:String)throws
}
@MainActor final class CaptureTranslationKeychain:CaptureTranslationSecrets {
    let service:String
    init(service:String="dev.thermo.capture.translation"){self.service=service}
    private func query(_ account:String)->[String:Any]{[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]}
    func read(_ account:String)throws->CaptureTranslationCredential? {
        var q=query(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound{return nil};guard status == errSecSuccess,let data=result as? Data else{throw CaptureTranslationFailure.keychain(status)}
        return try JSONDecoder().decode(CaptureTranslationCredential.self,from:data)
    }
    func write(_ credential:CaptureTranslationCredential?,account:String)throws {
        let q=query(account)
        guard let credential else{let status=SecItemDelete(q as CFDictionary);guard status == errSecSuccess || status == errSecItemNotFound else{throw CaptureTranslationFailure.keychain(status)};return}
        let data=try JSONEncoder().encode(credential)
        let updated=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if updated == errSecItemNotFound {
            var values=q;values[kSecValueData as String]=data;values[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status=SecItemAdd(values as CFDictionary,nil);guard status == errSecSuccess else{throw CaptureTranslationFailure.keychain(status)}
        }else if updated != errSecSuccess{throw CaptureTranslationFailure.keychain(updated)}
    }
}
@MainActor final class CaptureTranslationService:ObservableObject {
    static let preferenceKey="dev.thermo.capture.translation.v1"
    @Published private(set) var settings=CaptureTranslationSettings()
    @Published var issue:String?
    @Published private(set) var running=false
    private var lastFinished:Date?
    private var invalidStored=false
    let secrets:CaptureTranslationSecrets
    var client:CaptureTranslationClient
    private let save:(Data)throws->Void
    init(read:()->Data?={UserDefaults.standard.data(forKey:"dev.thermo.capture.translation.v1")},save:@escaping(Data)throws->Void={UserDefaults.standard.set($0,forKey:"dev.thermo.capture.translation.v1")},secrets:CaptureTranslationSecrets?=nil,client:CaptureTranslationClient = .init()) {
        self.save=save;self.secrets=secrets ?? CaptureTranslationKeychain();self.client=client
        if let data=read(){do{settings=try .decode(data)}catch{invalidStored=true;issue=captureFailureMessage(error)}}
    }
    func credential(for settings:CaptureTranslationSettings)throws->CaptureTranslationCredential?{try secrets.read(settings.credentialAccount)}
    @discardableResult func apply(_ next:CaptureTranslationSettings,newCredential:CaptureTranslationCredential?) -> Bool {
        do {
            let data=try next.data(),previous=(newCredential != nil || next.enabled) ? try credential(for:next) : nil,value=newCredential ?? previous
            if next.enabled {guard let value,value.valid(for:next.provider) else{throw CaptureTranslationFailure.missingCredential}}
            if let newCredential{guard newCredential.valid(for:next.provider) else{throw CaptureTranslationFailure.missingCredential};try secrets.write(newCredential,account:next.credentialAccount)}
            do{try save(data)}catch{if newCredential != nil{try secrets.write(previous,account:next.credentialAccount)};throw error}
            settings=next;invalidStored=false;issue=nil;return true
        }catch{issue=captureFailureMessage(error);return false}
    }
    @discardableResult func forgetCredential(for profile:CaptureTranslationSettings?=nil)->Bool {
        do {
            let target=profile ?? settings,before=try credential(for:target);var next=settings;if target.credentialAccount == settings.credentialAccount{next.enabled=false}
            try secrets.write(nil,account:target.credentialAccount)
            do{try save(next.data())}catch{try secrets.write(before,account:target.credentialAccount);throw error}
            settings=next;invalidStored=false;issue=nil;return true
        }catch{issue=captureFailureMessage(error);return false}
    }
    func translate(_ texts:[String],targetLanguage:String?=nil)async throws->[String] {
        guard !invalidStored else{throw CaptureTranslationFailure.invalidSettings}
        var selected=settings;if let targetLanguage{selected.targetLanguage=targetLanguage};guard selected.enabled else{throw CaptureTranslationFailure.disabled}
        guard !running else{throw CaptureTranslationFailure.busy};running=true;defer{running=false}
        guard let credential=try credential(for:selected) else{throw CaptureTranslationFailure.missingCredential}
        if selected.provider != .chatCompletions,let lastFinished {let remaining=1.1-Date().timeIntervalSince(lastFinished);if remaining>0{try await Task.sleep(nanoseconds:UInt64(remaining*1_000_000_000))}}
        defer{lastFinished=Date()}
        return try await client.translate(texts,settings:selected,credential:credential)
    }
}
