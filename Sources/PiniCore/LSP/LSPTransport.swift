import Foundation

/// LSP Content-Length 帧传输层。
/// 从 stdin 读字节流 → 按 Content-Length 头拆帧 → 出 Data；
/// 收 Data → 拼 Content-Length 头 → 写 stdout。
public final class LSPTransport {
 private let inputHandle: FileHandle
 private let outputHandle: FileHandle
 private let decoder = JSONDecoder()
 private let encoder: JSONEncoder = {
 let e = JSONEncoder()
 e.outputFormatting = []
 return e
 }()
 
 public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
 self.inputHandle = input
 self.outputHandle = output
 // FileHandle is unbuffered on Unix — no explicit flush needed
 }

 /// 阻塞读取一条完整消息
 public func readMessage() throws -> Data? {
 // 读取所有 header 行（以空行结束），在全部 header 中定位 Content-Length。
 // 支持 Content-Length 不在首行、以及 Content-Type 等多 header 的严格 LSP 帧。
 var contentLength: Int?
 while true {
 guard let headerLine = readHeaderLine() else {
 // EOF：header 段中途或流结束，统一按流结束处理（nil）
 return nil
 }
 if headerLine.isEmpty {
 break // 空行：header 段结束
 }
 if headerLine.lowercased().hasPrefix("content-length") {
 contentLength = try parseContentLength(headerLine)
 }
 }
 guard let length = contentLength else {
 throw TransportError.missingContentLength
 }
 // 读 body
 return try readBody(length: length)
 }

 /// 写入一条完整消息（自动加 Content-Length 头）
 public func writeMessage(_ data: Data) throws {
 let header = "Content-Length: \(data.count)\r\n\r\n"
 guard let headerData = header.data(using: .utf8) else {
 throw TransportError.encodingFailed
 }
 outputHandle.write(headerData)
 outputHandle.write(data)
 // 确保写入完成（LSP over stdio 依赖同步刷新）
 // FileHandle.write 默认同步，无需额外 flush
 }

 /// JSON 编码 + 写入通知
 public func sendNotification<T: Encodable>(method: String, params: T) throws {
 let notif = NotificationMessage(jsonrpc: "2.0", method: method, params: nil)
 // Encode params via JSONEncoder, then merge into notification dict
 let notifData = try encoder.encode(notif)
 let paramsData = try encoder.encode(params)
 var notifDict = try JSONSerialization.jsonObject(with: notifData) as! [String: Any]
 notifDict["params"] = try JSONSerialization.jsonObject(with: paramsData)
 let data = try JSONSerialization.data(withJSONObject: notifDict)
 try writeMessage(data)
 }

 /// JSON 编码 + 写入响应
 public func sendResponse(id: JSONValue, result: JSONValue) throws {
 let response = ResponseMessage(id: id, result: result)
 let data = try encoder.encode(response)
 try writeMessage(data)
 }
 
 public func sendError(id: JSONValue, error: ResponseError) throws {
 let response = ResponseMessage(id: id, error: error)
 let data = try encoder.encode(response)
 try writeMessage(data)
 }

 public func decodeRequest(_ data: Data) throws -> RequestMessage {
 return try decoder.decode(RequestMessage.self, from: data)
 }
 
 public func decodeNotification(_ data: Data) throws -> NotificationMessage {
 return try decoder.decode(NotificationMessage.self, from: data)
 }

 // MARK: - Private

 private func readHeaderLine() -> String? {
 var line = ""
 while true {
 guard let byte = readByte() else { return line.isEmpty ? nil : line }
 if byte == 0x0A { break } // \n
 if byte == 0x0D { continue } // 跳过 \r
 let scalar = UnicodeScalar(byte)
 line.append(Character(scalar))
 }
 return line
 }

 private func readByte() -> UInt8? {
 let data = inputHandle.readData(ofLength: 1)
 guard data.count == 1 else { return nil }
 return data[0]
 }

 private func parseContentLength(_ line: String) throws -> Int {
 let parts = line.split(separator: ":", maxSplits: 1)
 guard parts.count == 2,
 parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
 let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
 throw TransportError.invalidHeader(line)
 }
 return length
 }

 private func readBody(length: Int) throws -> Data {
 // 流式读取，累积到满 length 字节为止。
 // 单次 readData(ofLength:) 在 pipe/socket 上可能只返回部分字节，
 // 必须循环累加，否则会误判为 incompleteBody 并终止服务器。
 var remaining = length
 var result = Data()
 result.reserveCapacity(length)
 while remaining > 0 {
 let chunk = inputHandle.readData(ofLength: remaining)
 if chunk.isEmpty {
 // 未读满即遇到 EOF
 throw TransportError.incompleteBody(expected: length, got: length - remaining)
 }
 result.append(chunk)
 remaining -= chunk.count
 }
 return result
 }
}

// MARK: - Transport Error

public enum TransportError: Error {
 case invalidHeader(String)
 case incompleteBody(expected: Int, got: Int)
 case encodingFailed
 case missingContentLength
}
