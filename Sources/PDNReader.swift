import Foundation
import Compression

/// Reader for Paint.NET's layered .pdn format (the "PDN3" container used by Paint.NET 3.x–5.x):
/// magic, XML header, a .NET BinaryFormatter (MS-NRBF) object graph, then the layer pixel
/// blocks as gzip-compressed chunks. Built from the public MS-NRBF spec and the documented
/// container layout; no Paint.NET code involved.
enum PDNReader {
    static func load(_ url: URL) throws -> Document {
        let data = try Data(contentsOf: url)
        var r = ByteReader(data)
        guard r.bytes(4) == Array("PDN3".utf8) else {
            throw SoothError(message: "“\(url.lastPathComponent)” isn't a Paint.NET 3–5 image (unknown .pdn version).")
        }
        let headerLen = Int(r.u8()) | Int(r.u8()) << 8 | Int(r.u8()) << 16
        r.skip(headerLen)
        guard r.u8() == 0x00, r.u8() == 0x01 else {
            throw SoothError(message: "This .pdn uses an older compressed layout Sooth can't read yet.")
        }
        var nr = NRBF(r)
        try nr.parse()
        r = nr.r

        guard let docObj = nr.objects.values.first(where: { $0.cls == "PaintDotNet.Document" }),
              let w = docObj.int("width"), let h = docObj.int("height"), w > 0, h > 0 else {
            throw SoothError(message: "Couldn't find the image inside this .pdn file.")
        }
        guard Limits.ok(w, h) else { throw SoothError(message: "This .pdn is \(w) × \(h), larger than Sooth can edit.") }

        // Pixel blocks follow the object stream, in the order their MemoryBlock records appeared.
        var blocks: [Int: [UInt8]] = [:]
        for mb in nr.order.compactMap({ nr.objects[$0] }) where mb.cls == "PaintDotNet.MemoryBlock" {
            let len = mb.int("length64") ?? mb.int("length") ?? 0
            if mb.bool("hasParent") == true { continue }
            if mb.bool("deferred") == false {
                if case .ref(let id)? = mb.members["pointerData"], let arr = nr.byteArrays[id] { blocks[mb.id] = arr }
                continue
            }
            // A layer's pixels are w×h×4 bytes; anything else is a corrupt file, not an allocation to try.
            guard len >= 0, len <= w * h * 4 else { throw SoothError(message: "Corrupt .pdn pixel block.") }
            blocks[mb.id] = try readBlock(&r, length: len)
        }

        // Layer list -> array of BitmapLayer refs.
        var layerIDs: [Int] = []
        if let listRef = docObj.ref("layers"), let list = nr.objects[listRef] {
            if let itemsRef = list.ref("ArrayList+_items"), let items = nr.arrays[itemsRef] {
                let n = list.int("ArrayList+_size") ?? items.count
                layerIDs = items.prefix(n).compactMap { if case .ref(let id) = $0 { return id } else { return nil } }
            }
        }
        if layerIDs.isEmpty {
            layerIDs = nr.order.filter { nr.objects[$0]?.cls == "PaintDotNet.BitmapLayer" }
        }

        var layers: [Layer] = []
        for lid in layerIDs {
            guard let lo = nr.objects[lid] else { continue }
            let l = Layer(width: w, height: h, name: "Layer \(layers.count + 1)")
            if let pRef = lo.ref("Layer+properties"), let props = nr.objects[pRef] {
                if let s = props.string("name", nr) { l.name = s }
                l.visible = props.bool("visible") ?? true
                l.opacity = CGFloat(props.int("opacity") ?? 255) / 255
                if let bm = props.ref("blendMode"), let o = nr.objects[bm] { l.blend = blend(from: o) }
            }
            if let bpRef = lo.ref("BitmapLayer+properties") ?? lo.ref("properties"), let bp = nr.objects[bpRef] {
                for (_, v) in bp.members {
                    if case .ref(let id) = v, let o = nr.objects[id], blend(from: o) != .normal { l.blend = blend(from: o) }
                }
            }
            if let sRef = lo.ref("BitmapLayer+surface") ?? lo.ref("surface"), let surf = nr.objects[sRef],
               let mbRef = surf.ref("scan0"), let px = blocks[mbRef] {
                // A row is at least w pixels; a damaged file's stride must not walk off (or before) the block.
                let stride = max(w * 4, surf.int("stride") ?? w * 4)
                for y in 0..<h {
                    for x in 0..<w {
                        let s = y * stride + x * 4
                        guard s >= 0, s + 3 < px.count else { continue }
                        let a = Int(px[s + 3])
                        let d = (y * w + x) * 4
                        l.bytes[d] = premul(Int(px[s + 2]), a)
                        l.bytes[d + 1] = premul(Int(px[s + 1]), a)
                        l.bytes[d + 2] = premul(Int(px[s]), a)
                        l.bytes[d + 3] = UInt8(a)
                    }
                }
            }
            layers.append(l)
        }
        guard !layers.isEmpty else { throw SoothError(message: "No layers found in this .pdn file.") }
        let doc = Document(layers: layers, active: layers.count - 1)
        doc.fileURL = url
        doc.fileFormat = nil  // Sooth writes .sooth, not .pdn; Save asks for a format.
        return doc
    }

    private static func blend(from o: NRObject) -> BlendMode {
        let n = o.cls
        let table: [(String, BlendMode)] = [
            ("Multiply", .multiply), ("Additive", .additive), ("ColorBurn", .colorBurn), ("ColorDodge", .colorDodge),
            ("Reflect", .colorDodge), ("Glow", .colorDodge), ("Overlay", .overlay), ("Difference", .difference),
            ("Negation", .exclusion), ("Lighten", .lighten), ("Darken", .darken), ("Screen", .screen), ("Xor", .exclusion),
            ("HardLight", .hardLight), ("SoftLight", .softLight), ("Luminosity", .luminosity), ("Saturation", .saturation),
            ("Hue", .hue), ("Color", .color),
        ]
        if n.contains("BlendOp") {
            for (k, m) in table where n.contains("+\(k)BlendOp") { return m }
            return .normal
        }
        if n.contains("BlendMode"), let v = o.int("value__") {
            let order: [BlendMode] = [.normal, .multiply, .colorBurn, .colorDodge, .colorDodge, .colorDodge, .overlay,
                                      .difference, .exclusion, .lighten, .darken, .screen, .exclusion]
            return v >= 0 && v < order.count ? order[v] : .normal
        }
        return .normal
    }

    private static func readBlock(_ r: inout ByteReader, length: Int) throws -> [UInt8] {
        let format = r.u8()
        let chunkSize = Int(r.u32be())
        guard chunkSize > 0 else { throw SoothError(message: "Corrupt .pdn pixel block.") }
        var out = [UInt8](repeating: 0, count: length)
        let chunks = (length + chunkSize - 1) / chunkSize
        for _ in 0..<chunks {
            guard !r.atEnd else { throw SoothError(message: "This .pdn file is cut short.") }
            let num = Int(r.u32be())
            let size = Int(r.u32be())
            let raw = r.bytes(size)
            let (off, overflow) = num.multipliedReportingOverflow(by: chunkSize)
            guard !overflow, off >= 0, off < length else { continue }
            let want = min(chunkSize, length - off)
            guard want > 0 else { continue }
            let chunk = format == 0 ? try gunzip(raw, expected: want) : raw
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<min(want, chunk.count) { o[off + i] = chunk[i] }
            }
        }
        return out
    }

    private static func gunzip(_ g: [UInt8], expected: Int) throws -> [UInt8] {
        guard g.count > 18, g[0] == 0x1f, g[1] == 0x8b else { throw SoothError(message: "Bad gzip chunk in .pdn.") }
        let flags = g[3]
        var p = 10
        if flags & 4 != 0 { p += 2 + Int(g[p]) | Int(g[p + 1]) << 8 }
        if flags & 8 != 0 { while p < g.count && g[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < g.count && g[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        guard p < g.count - 8 else { throw SoothError(message: "Bad gzip chunk in .pdn.") }
        let body = Array(g[p..<(g.count - 8)])
        var out = [UInt8](repeating: 0, count: expected)
        let n = body.withUnsafeBufferPointer { b in
            out.withUnsafeMutableBufferPointer { o in
                compression_decode_buffer(o.baseAddress!, expected, b.baseAddress!, b.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { throw SoothError(message: "Couldn't decompress a .pdn chunk.") }
        return out
    }
}

// MARK: - Byte reader

struct ByteReader {
    let d: [UInt8]
    var p = 0
    init(_ data: Data) { d = [UInt8](data) }

    mutating func u8() -> UInt8 { guard p < d.count else { p += 1; return 0 }; defer { p += 1 }; return d[p] }
    mutating func bytes(_ n: Int) -> [UInt8] {
        let e = min(d.count, p + max(0, n)); defer { p += max(0, n) }
        return p < e ? Array(d[p..<e]) : []
    }
    mutating func skip(_ n: Int) { p += n }
    mutating func i32() -> Int32 { Int32(bitPattern: UInt32(u8()) | UInt32(u8()) << 8 | UInt32(u8()) << 16 | UInt32(u8()) << 24) }
    mutating func u32be() -> UInt32 { UInt32(u8()) << 24 | UInt32(u8()) << 16 | UInt32(u8()) << 8 | UInt32(u8()) }
    mutating func i64() -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(u8()) << (8 * UInt64(i)) }
        return Int64(bitPattern: v)
    }
    mutating func string() -> String {
        var len = 0, shift = 0
        while true {
            let b = u8()
            len |= Int(b & 0x7f) << shift
            if b & 0x80 == 0 || shift > 28 { break }
            shift += 7
        }
        return String(decoding: bytes(len), as: UTF8.self)
    }
    var atEnd: Bool { p >= d.count }
    var remaining: Int { max(0, d.count - p) }
}

// MARK: - MS-NRBF

enum NRValue {
    case int(Int64), double(Double), bool(Bool), string(String), ref(Int), null
}

final class NRObject {
    let id: Int
    let cls: String
    var members: [String: NRValue] = [:]
    init(id: Int, cls: String) { self.id = id; self.cls = cls }

    func int(_ k: String) -> Int? {
        switch members[k] {
        case .int(let v)?: Int(v)
        case .double(let v)?: v.isFinite && abs(v) < 1e15 ? Int(v) : nil
        default: nil
        }
    }
    func bool(_ k: String) -> Bool? { if case .bool(let b)? = members[k] { return b }; return nil }
    func ref(_ k: String) -> Int? { if case .ref(let r)? = members[k] { return r }; return nil }
    func string(_ k: String, _ nr: NRBF) -> String? {
        switch members[k] {
        case .string(let s)?: s
        case .ref(let id)?: nr.strings[id]
        default: nil
        }
    }
}

struct NRBF {
    struct ClassMeta {
        let name: String
        let members: [String]
        let types: [UInt8]?      // BinaryTypeEnum per member, nil if untyped
        let prims: [UInt8?]      // PrimitiveTypeEnum for primitive members
    }

    var r: ByteReader
    var objects: [Int: NRObject] = [:]
    var arrays: [Int: [NRValue]] = [:]
    var byteArrays: [Int: [UInt8]] = [:]
    var strings: [Int: String] = [:]
    var order: [Int] = []
    private var metas: [Int: ClassMeta] = [:]
    private var pendingNulls = 0

    init(_ r: ByteReader) { self.r = r }

    mutating func parse() throws {
        var guardCount = 0
        while !r.atEnd {
            guardCount += 1
            if guardCount > 5_000_000 { throw SoothError(message: "Malformed .pdn object stream.") }
            let t = r.u8()
            if t == 11 { return }  // MessageEnd
            _ = try record(t)
        }
        throw SoothError(message: "Unexpected end of .pdn object stream.")
    }

    private mutating func prim(_ t: UInt8) throws -> NRValue {
        switch t {
        case 1: return .bool(r.u8() != 0)
        case 2: return .int(Int64(r.u8()))
        case 3:
            let b = r.u8()
            let extra = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : b >= 0xC0 ? 1 : 0
            r.skip(extra)
            return .int(Int64(b))
        case 5: return .string(r.string())
        case 6: return .double(Double(bitPattern: UInt64(bitPattern: r.i64())))
        case 7: return .int(Int64(Int16(bitPattern: UInt16(r.u8()) | UInt16(r.u8()) << 8)))
        case 8: return .int(Int64(r.i32()))
        case 9, 12, 13, 16: return .int(r.i64())
        case 10: return .int(Int64(Int8(bitPattern: r.u8())))
        case 11:
            let bits = UInt32(bitPattern: r.i32())
            return .double(Double(Float(bitPattern: bits)))
        case 14: return .int(Int64(UInt16(r.u8()) | UInt16(r.u8()) << 8))
        case 15: return .int(Int64(UInt32(bitPattern: r.i32())))
        case 17: return .null
        case 18: return .string(r.string())
        default: throw SoothError(message: "Unknown primitive type \(t) in .pdn.")
        }
    }

    /// A count read from the file, refused if it's negative or more than the bytes left could hold.
    private func checked(_ n: Int, perItem: Int = 1) throws -> Int {
        guard n >= 0, perItem == 0 ? n <= 50_000_000 : n <= r.remaining / perItem else {
            throw SoothError(message: "Malformed .pdn object stream.")
        }
        return n
    }

    private mutating func classInfo() throws -> (Int, String, [String]) {
        let id = Int(r.i32())
        let name = r.string()
        let n = try checked(Int(r.i32()))
        let names = (0..<n).map { _ in r.string() }
        return (id, name, names)
    }

    private mutating func memberTypes(_ n: Int) -> ([UInt8], [UInt8?]) {
        let types = r.bytes(n)
        var prims: [UInt8?] = []
        for t in types {
            switch t {
            case 0, 7: prims.append(r.u8())
            case 3: _ = r.string(); prims.append(nil)
            case 4: _ = r.string(); _ = r.i32(); prims.append(nil)
            default: prims.append(nil)
            }
        }
        return (types, prims)
    }

    /// Reads the record whose type byte is `t`; returns the value it represents.
    private mutating func record(_ t: UInt8) throws -> NRValue {
        switch t {
        case 0:
            r.skip(16); return .null
        case 1:
            let id = Int(r.i32()), metaId = Int(r.i32())
            guard let m = metas[metaId] else { throw SoothError(message: "Bad class reference in .pdn.") }
            metas[id] = m
            return try readObject(id: id, meta: m)
        case 2, 3:
            let (id, name, names) = try classInfo()
            if t == 3 { _ = r.i32() }
            let m = ClassMeta(name: name, members: names, types: nil, prims: [])
            metas[id] = m
            return try readObject(id: id, meta: m)
        case 4, 5:
            let (id, name, names) = try classInfo()
            let (types, prims) = memberTypes(names.count)
            if t == 5 { _ = r.i32() }
            let m = ClassMeta(name: name, members: names, types: types, prims: prims)
            metas[id] = m
            return try readObject(id: id, meta: m)
        case 6:
            let id = Int(r.i32())
            strings[id] = r.string()
            return .ref(id)
        case 7:
            let id = Int(r.i32())
            let kind = r.u8()
            let rank = Int(r.i32())
            var total = 1
            for _ in 0..<(try checked(rank, perItem: 4)) {
                let (t2, overflow) = total.multipliedReportingOverflow(by: Int(r.i32()))
                guard !overflow, t2 >= 0 else { throw SoothError(message: "Malformed .pdn array.") }
                total = t2
            }
            if kind == 3 || kind == 4 || kind == 5 { r.skip(4 * rank) }
            let et = r.u8()
            var primType: UInt8?
            switch et {
            case 0, 7: primType = r.u8()
            case 3: _ = r.string()
            case 4: _ = r.string(); _ = r.i32()
            default: break
            }
            if et == 0, let pt = primType {
                if pt == 2 { byteArrays[id] = r.bytes(total); return .ref(id) }
                var vals: [NRValue] = []
                for _ in 0..<(try checked(total, perItem: pt == 17 ? 0 : 1)) { vals.append(try prim(pt)) }
                arrays[id] = vals
            } else {
                arrays[id] = try readElements(try checked(total, perItem: 0))
            }
            return .ref(id)
        case 8:
            return try prim(r.u8())
        case 9:
            return .ref(Int(r.i32()))
        case 10:
            return .null
        case 12:
            _ = r.i32(); _ = r.string()
            return try record(r.u8())
        case 13:
            pendingNulls = Int(r.u8()) - 1
            return .null
        case 14:
            pendingNulls = Int(r.i32()) - 1
            return .null
        case 15:
            let id = Int(r.i32()), n = Int(r.i32()), pt = r.u8()
            if pt == 2 { byteArrays[id] = r.bytes(n); return .ref(id) }
            var vals: [NRValue] = []
            for _ in 0..<(try checked(n, perItem: pt == 17 ? 0 : 1)) { vals.append(try prim(pt)) }
            arrays[id] = vals
            return .ref(id)
        case 16, 17:
            let id = Int(r.i32()), n = Int(r.i32())
            arrays[id] = try readElements(try checked(n, perItem: 0))
            return .ref(id)
        default:
            throw SoothError(message: "Unsupported record type \(t) in .pdn.")
        }
    }

    private mutating func readElements(_ n: Int) throws -> [NRValue] {
        var out: [NRValue] = []
        out.reserveCapacity(min(n, r.remaining + 1))
        while out.count < n {
            if pendingNulls == 0 && r.atEnd { throw SoothError(message: "This .pdn file is cut short.") }
            if pendingNulls > 0 { pendingNulls -= 1; out.append(.null); continue }
            out.append(try nextValue())
        }
        return out
    }

    private mutating func nextValue() throws -> NRValue {
        var t = r.u8()
        while t == 12 { _ = r.i32(); _ = r.string(); t = r.u8() }
        return try record(t)
    }

    private mutating func readObject(id: Int, meta m: ClassMeta) throws -> NRValue {
        let o = NRObject(id: id, cls: m.name)
        objects[id] = o
        order.append(id)
        for (i, name) in m.members.enumerated() {
            if pendingNulls > 0 { pendingNulls -= 1; o.members[name] = .null; continue }
            if let types = m.types, i < types.count, i < m.prims.count, types[i] == 0, let pt = m.prims[i] {
                o.members[name] = try prim(pt)
            } else {
                o.members[name] = try nextValue()
            }
        }
        return .ref(id)
    }
}
