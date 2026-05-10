import Foundation

/// UDP packet format.
///
/// Header (10 bytes, little-endian):
/// ┌──────────────┬────────────┬────────────┬──────────┬──────────┐
/// │  frame_id    │  pkt_idx   │  pkt_total │  type    │  flags   │
/// │  uint32 LE   │  uint16 LE │  uint16 LE │  uint8   │  uint8   │
/// │  (4 bytes)   │  (2 bytes) │  (2 bytes) │  (1 byte)│  (1 byte)│
/// └──────────────┴────────────┴────────────┴──────────┴──────────┘
///
/// type = 0x01: video frame fragment (payload is raw H.265 NAL bytes, Annex-B framed)
/// type = 0x02: control event (payload is UTF-8 ASCII string)
///
/// flags bit 0 = 1 means this packet contains the start of a keyframe (IDR).
enum Packet {
    static let headerSize = 10
    static let mtuSafeTotal = 1400
    static let maxPayloadSize = mtuSafeTotal - headerSize

    static let typeVideo: UInt8 = 0x01
    static let typeControl: UInt8 = 0x02
    /// Raw PCM audio: 48 kHz · stereo · Float32 interleaved · little-endian.
    static let typeAudio: UInt8 = 0x04

    static let flagKeyframe: UInt8 = 0x01

    static func encodeVideo(frameId: UInt32,
                            pktIdx: UInt16,
                            pktTotal: UInt16,
                            isKeyframe: Bool,
                            payload: Data) -> Data {
        var buf = Data(capacity: headerSize + payload.count)
        writeHeader(into: &buf,
                    frameId: frameId,
                    pktIdx: pktIdx,
                    pktTotal: pktTotal,
                    type: typeVideo,
                    flags: isKeyframe ? flagKeyframe : 0)
        buf.append(payload)
        return buf
    }

    /// Build a UDP packet carrying a raw PCM audio chunk (type = 0x04).
    static func encodeAudio(frameId: UInt32, payload: Data) -> Data {
        var buf = Data(capacity: headerSize + payload.count)
        writeHeader(into: &buf,
                    frameId: frameId,
                    pktIdx: 0,
                    pktTotal: 1,
                    type: typeAudio,
                    flags: 0)
        buf.append(payload)
        return buf
    }

    static func encodeControl(frameId: UInt32, eventString: String) -> Data {
        let payload = eventString.data(using: .utf8) ?? Data()
        var buf = Data(capacity: headerSize + payload.count)
        writeHeader(into: &buf,
                    frameId: frameId,
                    pktIdx: 0,
                    pktTotal: 1,
                    type: typeControl,
                    flags: 0)
        buf.append(payload)
        return buf
    }

    private static func writeHeader(into buf: inout Data,
                                    frameId: UInt32,
                                    pktIdx: UInt16,
                                    pktTotal: UInt16,
                                    type: UInt8,
                                    flags: UInt8) {
        var fid = frameId.littleEndian
        var pi = pktIdx.littleEndian
        var pt = pktTotal.littleEndian
        withUnsafeBytes(of: &fid) { buf.append(contentsOf: $0) }
        withUnsafeBytes(of: &pi) { buf.append(contentsOf: $0) }
        withUnsafeBytes(of: &pt) { buf.append(contentsOf: $0) }
        buf.append(type)
        buf.append(flags)
    }

    struct Parsed {
        let frameId: UInt32
        let pktIdx: UInt16
        let pktTotal: UInt16
        let type: UInt8
        let flags: UInt8
        let payload: Data
    }

    static func parse(_ data: Data) -> Parsed? {
        guard data.count >= headerSize else { return nil }
        let frameId: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let pktIdx: UInt16 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }.littleEndian
        let pktTotal: UInt16 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }.littleEndian
        let type = data[8]
        let flags = data[9]
        let payload = data.count > headerSize ? data.subdata(in: headerSize..<data.count) : Data()
        return Parsed(frameId: frameId,
                      pktIdx: pktIdx,
                      pktTotal: pktTotal,
                      type: type,
                      flags: flags,
                      payload: payload)
    }
}
