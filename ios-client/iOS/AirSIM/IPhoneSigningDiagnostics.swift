import CoreFoundation
import Foundation

/// A read-only snapshot of declarations on disk. iOS independently grants roles and access.
enum IPhoneSigningDiagnostics {
    private static let names = [
        ("默认通话", "calling-app"),
        ("默认拨号", "dialing-app")
    ]
    private static let prefix = "com.apple.developer."
    private static let fieldLimit = 4 * 1024 * 1024
    private enum ParseError: Error { case invalid }

    private struct Snapshot {
        let source: String
        let fields: [String: String]?
        func display(_ key: String) -> String {
            guard let fields else { return source }
            return "\(source) · \(fields[key] ?? "未声明")"
        }
    }

    static func rows(bundle: Bundle) -> [(String, String)] {
        let executable = bundle.executableURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        return rows(executable: executable, profile: profile)
    }

    static func rows(executable: Data?, profile: Data?) -> [(String, String)] {
        let main = executable.flatMap { try? signature($0) }
            ?? Snapshot(source: "不可读取（请用 Mac 复核安装包签名）", fields: nil)
        let provision = profile.flatMap { try? provisioningFields($0) }
            .map { Snapshot(source: "描述文件可读字段", fields: $0) }
            ?? Snapshot(source: "描述文件不可读取", fields: nil)
        return names.map { label, suffix in
            let key = prefix + suffix
            return ("\(label)（\(suffix)）", "主 App 签名 · \(main.display(key))\n\(provision.display(key))")
        }
    }

    private static func plistFields(_ data: Data, fromProfile: Bool) throws -> [String: String] {
        guard data.count <= fieldLimit,
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let dictionary = fromProfile ? plist["Entitlements"] as? [String: Any] : plist
        else { throw ParseError.invalid }
        var fields: [String: String] = [:]
        for (_, suffix) in names {
            let key = prefix + suffix
            guard let value = dictionary[key] else { continue }
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                fields[key] = number.boolValue ? "true" : "false"
            } else { fields[key] = "字段类型异常" }
        }
        return fields
    }

    // All offsets in a Mach-O load command or signing blob are relative to its beginning.
    private static func word(_ data: Data, _ offset: Int, littleEndian: Bool = false) throws -> Int {
        guard offset >= 0, offset <= data.count - 4 else { throw ParseError.invalid }
        let i = data.startIndex + offset
        let a = Int(data[i]), b = Int(data[i + 1]), c = Int(data[i + 2]), d = Int(data[i + 3])
        return littleEndian ? a | b << 8 | c << 16 | d << 24 : a << 24 | b << 16 | c << 8 | d
    }

    private static func slice(_ data: Data, _ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= data.count - length else { throw ParseError.invalid }
        let i = data.startIndex + offset
        return data[i..<(i + length)]
    }

    private static func signature(_ image: Data) throws -> Snapshot {
        guard try word(image, 0, littleEndian: true) == 0xfeedfacf,
              try word(image, 4, littleEndian: true) == 0x0100000c else { throw ParseError.invalid }
        let count = try word(image, 16, littleEndian: true)
        let commands = try slice(image, 32, word(image, 20, littleEndian: true))
        guard count <= commands.count / 8 else { throw ParseError.invalid }
        var offset = 0
        var embedded: Data?
        for _ in 0..<count {
            let kind = try word(commands, offset, littleEndian: true)
            let size = try word(commands, offset + 4, littleEndian: true)
            guard size >= 8, size.isMultiple(of: 8), size <= commands.count - offset else { throw ParseError.invalid }
            if kind == 0x1d { // LC_CODE_SIGNATURE
                guard embedded == nil, size == 16 else { throw ParseError.invalid }
                let location = try word(commands, offset + 8, littleEndian: true)
                let length = try word(commands, offset + 12, littleEndian: true)
                guard location >= 32 + commands.count else { throw ParseError.invalid }
                embedded = try slice(image, location, length)
            }
            offset += size
        }
        guard offset == commands.count, let embedded,
              try word(embedded, 0) == 0xfade0cc0 else { throw ParseError.invalid }
        let blob = try slice(embedded, 0, word(embedded, 4))
        let entries = try word(blob, 8)
        guard entries <= (blob.count - 12) / 8 else { throw ParseError.invalid }
        var der: Data?
        var xml: Data?
        for i in 0..<entries {
            let slot = try word(blob, 12 + i * 8)
            guard slot == 5 || slot == 7 else { continue }
            let location = try word(blob, 16 + i * 8)
            let magic = try word(blob, location)
            let length = try word(blob, location + 4)
            guard location >= 12 + 8 * entries, (8...(fieldLimit + 8)).contains(length) else { throw ParseError.invalid }
            let bytes = try slice(blob, location + 8, length - 8)
            if slot == 7 {
                guard der == nil, magic == 0xfade7172 else { throw ParseError.invalid }
                der = bytes
            } else {
                guard xml == nil, magic == 0xfade7171 else { throw ParseError.invalid }
                xml = bytes
            }
        }
        if let der, let fields = try? derFields(der) { return Snapshot(source: "DER", fields: fields) }
        if let xml {
            let source = der == nil ? "XML（无 DER 槽）" : "XML（DER 不可读取）"
            return Snapshot(source: source, fields: try plistFields(xml, fromProfile: false))
        }
        if der != nil { throw ParseError.invalid }
        return Snapshot(source: "未找到权限槽", fields: nil)
    }

    /// Bounded ASN.1 content reader. DER entitlements require definite, minimal lengths.
    /// CMS additionally permits BER indefinite-length wrappers, delimited by end-of-content.
    private struct TLVReader {
        var remaining: Data
        var ber = false
        mutating func read(_ expected: UInt8? = nil, depth: Int = 0) throws -> (tag: UInt8, bytes: Data) {
            guard remaining.count >= 2, depth <= 24 else { throw ParseError.invalid }
            let tag = remaining.removeFirst()
            let header = remaining.removeFirst()
            guard tag != 0, tag & 0x1f != 0x1f, expected == nil || expected == tag else { throw ParseError.invalid }
            if header == 0x80 {
                guard ber, tag & 0x20 != 0 else { throw ParseError.invalid }
                let start = remaining
                while !remaining.starts(with: [0, 0]) { _ = try read(depth: depth + 1) }
                let value = start.prefix(start.count - remaining.count)
                remaining = remaining.dropFirst(2)
                return (tag, value)
            }
            var length = Int(header)
            if header > 0x80 {
                let width = length & 0x7f
                guard width <= 4, remaining.count >= width, ber || remaining.first != 0 else { throw ParseError.invalid }
                length = 0
                for _ in 0..<width { length = (length << 8) | Int(remaining.removeFirst()) }
                guard ber || length >= 128 else { throw ParseError.invalid }
            }
            guard length <= remaining.count else { throw ParseError.invalid }
            let value = remaining.prefix(length)
            remaining = remaining.dropFirst(length)
            return (tag, value)
        }

        mutating func only(_ expected: UInt8) throws -> Data {
            let content = try read(expected).bytes
            guard remaining.isEmpty else { throw ParseError.invalid }
            return content
        }
    }

    private static func derFields(_ bytes: Data) throws -> [String: String] {
        var root = TLVReader(remaining: bytes)
        var entries: TLVReader
        if bytes.first == 0x70 {
            var wrapped = try TLVReader(remaining: root.only(0x70))
            guard try wrapped.read(0x02).bytes.elementsEqual([1]) else { throw ParseError.invalid }
            entries = try TLVReader(remaining: wrapped.only(0xb0))
        } else { entries = try TLVReader(remaining: root.only(0x31)) }
        let wanted = Set(names.map { prefix + $0.1 })
        var fields: [String: String] = [:]
        while !entries.remaining.isEmpty {
            var entry = try TLVReader(remaining: entries.read(0x30).bytes)
            let keyData = try entry.read(0x0c).bytes
            guard let key = String(data: keyData, encoding: .utf8) else { throw ParseError.invalid }
            let value = try entry.read()
            guard entry.remaining.isEmpty else { throw ParseError.invalid }
            guard wanted.contains(key) else { continue }
            guard fields[key] == nil else { throw ParseError.invalid }
            if value.tag != 0x01 {
                fields[key] = "字段类型异常"
            } else {
                guard value.bytes.count == 1, let byte = value.bytes.first, byte == 0 || byte == 0xff
                else { throw ParseError.invalid }
                fields[key] = byte == 0xff ? "true" : "false"
            }
        }
        return fields
    }

    // Read the plist only from the CMS SignedData encapsulated content. This is not signature validation.
    private static func provisioningFields(_ bytes: Data) throws -> [String: String] {
        guard bytes.count <= fieldLimit else { throw ParseError.invalid }
        var document = TLVReader(remaining: bytes, ber: true)
        var info = try TLVReader(remaining: document.only(0x30), ber: true)
        let pkcs7: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07]
        guard try info.read(0x06).bytes.elementsEqual(pkcs7 + [2]) else { throw ParseError.invalid }
        var explicit = try TLVReader(remaining: info.only(0xa0), ber: true)
        var signed = try TLVReader(remaining: explicit.only(0x30), ber: true)
        _ = try signed.read(0x02)
        _ = try signed.read(0x31)
        var content = try TLVReader(remaining: signed.read(0x30).bytes, ber: true)
        guard try content.read(0x06).bytes.elementsEqual(pkcs7 + [1]) else { throw ParseError.invalid }
        var wrapper = try TLVReader(remaining: content.only(0xa0), ber: true)
        let payload = try wrapper.read()
        guard wrapper.remaining.isEmpty else { throw ParseError.invalid }
        if payload.tag == 0x04 { return try plistFields(payload.bytes, fromProfile: true) }
        guard payload.tag == 0x24 else { throw ParseError.invalid }
        var chunks = TLVReader(remaining: payload.bytes, ber: true)
        var plist = Data()
        while !chunks.remaining.isEmpty { try plist.append(chunks.read(0x04).bytes) }
        return try plistFields(plist, fromProfile: true)
    }
}
