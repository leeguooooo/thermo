import Foundation

public final class CaptureTranslationHTTP:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    public override init(){}
    public func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
    public func send(_ request:URLRequest)async throws->Data {
        let config=URLSessionConfiguration.ephemeral;config.urlCache=nil;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.httpShouldSetCookies=false;config.timeoutIntervalForResource=90
        let session=URLSession(configuration:config,delegate:self,delegateQueue:nil);defer{session.invalidateAndCancel()}
        do {
            let (bytes,response)=try await session.bytes(for:request)
            guard let http=response as? HTTPURLResponse else{throw CaptureTranslationFailure.invalidResponse}
            guard (200..<300).contains(http.statusCode) else{throw CaptureTranslationFailure.http(http.statusCode)}
            guard response.expectedContentLength<=1_048_576 else{throw CaptureTranslationFailure.tooLarge}
            var data=Data();for try await byte in bytes {try Task.checkCancellation();guard data.count<1_048_576 else{throw CaptureTranslationFailure.tooLarge};data.append(byte)};return data
        }catch is CancellationError{throw CancellationError()}
        catch let error as CaptureTranslationFailure{throw error}
        catch{try Task.checkCancellation();throw CaptureTranslationFailure.network((error as NSError).code)}
    }
}
public struct CaptureTranslationClient:Sendable {
    public let send:@Sendable(URLRequest)async throws->Data
    public let pause:@Sendable()async throws->Void
    public init(send:@escaping @Sendable(URLRequest)async throws->Data={try await CaptureTranslationHTTP().send($0)},pause:@escaping @Sendable()async throws->Void={try await Task.sleep(nanoseconds:1_100_000_000)}){self.send=send;self.pause=pause}
    public func translate(_ texts:[String],settings:CaptureTranslationSettings,credential:CaptureTranslationCredential)async throws->[String] {
        guard settings.valid else{throw CaptureTranslationFailure.invalidSettings};guard settings.enabled else{throw CaptureTranslationFailure.disabled};guard credential.valid(for:settings.provider) else{throw CaptureTranslationFailure.missingCredential}
        guard !texts.isEmpty,texts.count<=256,texts.reduce(0,{$0+$1.utf8.count})<=64_000,texts.contains(where:{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else{throw CaptureTranslationFailure.invalidInput}
        struct Unit {var index:Int;var text:String;var translated:String?}
        var units:[Unit]=[]
        for (index,text) in texts.enumerated() {
            let lines=settings.provider == .baidu ? text.components(separatedBy:"\n") : [text]
            for (number,line) in lines.enumerated() {
                if number>0{units.append(.init(index:index,text:"\n",translated:"\n"))}
                var chunk=""
                for character in line {
                    let value=String(character);guard value.utf8.count<=5000 else{throw CaptureTranslationFailure.tooLarge}
                    if chunk.utf8.count+value.utf8.count>5000{units.append(.init(index:index,text:chunk));chunk=""};chunk += value
                }
                if !chunk.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{units.append(.init(index:index,text:chunk))}else if !chunk.isEmpty{units.append(.init(index:index,text:chunk,translated:chunk))}
            }
        }
        guard units.count<=512 else{throw CaptureTranslationFailure.tooLarge}
        let pending=units.indices.filter{units[$0].translated == nil};var offset=0,outputBytes=0
        while offset<pending.count {
            try Task.checkCancellation();if offset>0{try await pause()}
            var batch:[Int]=[],size=0
            while offset<pending.count,batch.count<64 {
                let index=pending[offset],added=units[index].text.utf8.count+(batch.isEmpty ? 0 : 1)
                if size+added>5800{break};batch.append(index);size += added;offset += 1
            }
            guard !batch.isEmpty else{throw CaptureTranslationFailure.tooLarge}
            let source=batch.map{units[$0].text},request=try CaptureTranslationProtocol.request(texts:source,settings:settings,credential:credential)
            let result=try CaptureTranslationProtocol.response(try await send(request),texts:source,provider:settings.provider)
            try Task.checkCancellation()
            for (index,value) in zip(batch,result){outputBytes += value.utf8.count;guard outputBytes<=256_000 else{throw CaptureTranslationFailure.tooLarge};units[index].translated=value}
        }
        var result=[String](repeating:"",count:texts.count)
        for unit in units{guard let value=unit.translated else{throw CaptureTranslationFailure.invalidResponse};result[unit.index] += value};return result
    }
}
