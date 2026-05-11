import Foundation

/// UDP 包格式，与 Mac Packet.swift / Android Packet.kt 完全对齐
///
/// 包头 (10字节, little-endian):
///   frame_id  : uint32  (4字节)
///   pkt_idx   : uint16  (2字节)
///   pkt_total : uint16  (2字节)
///   type      : uint8   (1字节)
///   flags     : uint8   (1字节)
enum Packet {

    static let headerSize    = 10
    static let mtuSafeTotal  = 1400
    static let maxPayload    = mtuSafeTotal - headerSize

    // MARK: - 包类型
    static let typeVideo:       UInt8 = 0x01
    static let typeControl:     UInt8 = 0x02
    static let typeAudio:       UInt8 = 0x03   // Android 麦克风 → Mac
    static let typeSystemAudio: UInt8 = 0x04   // Mac 系统音 → iOS

    static let flagKeyframe: UInt8 = 0x01

    // MARK: - 编码
    static func encodeControl(frameId: UInt32, eventString: String) -> Data {
        let payload = eventString.data(using: .utf8) ?? Data()
        return encode(frameId: frameId, pktIdx: 0, pktTotal: 1,
                      type: typeControl, flags: 0, payload: payload)
    }

    static func encodeAudio(frameId: UInt32, payload: Data) -> Data {
        encode(frameId: frameId, pktIdx: 0, pktTotal: 1,
               type: typeAudio, flags: 0, payload: payload)
    }

    private static func encode(frameId: UInt32, pktIdx: UInt16, pktTotal: UInt16,
                                type: UInt8, flags: UInt8, payload: Data) -> Data {
        var buf = Data(capacity: headerSize + payload.count)
        var fid = frameId.littleEndian
        var pi  = pktIdx.littleEndian
        var pt  = pktTotal.littleEndian
        withUnsafeBytes(of: &fid) { buf.append(contentsOf: $0) }
        withUnsafeBytes(of: &pi)  { buf.append(contentsOf: $0) }
        withUnsafeBytes(of: &pt)  { buf.append(contentsOf: $0) }
        buf.append(type)
        buf.append(flags)
        buf.append(payload)
        return buf
    }

    // MARK: - 解析
    struct Parsed {
        let frameId:    UInt32
        let pktIdx:     UInt16
        let pktTotal:   UInt16
        let type:       UInt8
        let flags:      UInt8
        let payload:    Data

        var isKeyframe: Bool { (flags & Packet.flagKeyframe) != 0 }
    }

    static func parse(_ data: Data) -> Parsed? {
        guard data.count >= headerSize else { return nil }
        let frameId  = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let pktIdx   = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }.littleEndian
        let pktTotal = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }.littleEndian
        let type     = data[8]
        let flags    = data[9]
        let payload  = data.count > headerSize ? data.subdata(in: headerSize..<data.count) : Data()
        return Parsed(frameId: frameId, pktIdx: pktIdx, pktTotal: pktTotal,
                      type: type, flags: flags, payload: payload)
    }
}
