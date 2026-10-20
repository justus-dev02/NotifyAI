//
//  ZipArchive.swift
//  NotifyAIServices
//

import Foundation

/// Writes a ZIP archive with uncompressed ("stored") entries, as Office documents need it.
///
/// Office Open XML is a ZIP of XML parts. Storing without compression is valid for every
/// reader and keeps this writer small and exact: local headers, data, central directory and
/// end record, all little-endian, with a CRC-32 per entry.
struct ZipArchive {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []
    /// MS-DOS date and time of all entries.
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = .now) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((components.hour ?? 0) << 11 | (components.minute ?? 0) << 5 | (components.second ?? 0) / 2)
        dosDate = UInt16(max(0, (components.year ?? 1980) - 1980) << 9 | (components.month ?? 1) << 5 | (components.day ?? 1))
    }

    mutating func add(_ path: String, _ content: Data) {
        let name = Data(path.utf8)
        let crc = Self.crc32(content)
        entries.append(Entry(name: name, crc: crc, size: UInt32(content.count), offset: UInt32(data.count)))
        // Local file header.
        data.append(le32: 0x0403_4B50)
        data.append(le16: 20)          // version needed
        data.append(le16: 0x0800)      // UTF-8 names
        data.append(le16: 0)           // stored
        data.append(le16: dosTime)
        data.append(le16: dosDate)
        data.append(le32: crc)
        data.append(le32: UInt32(content.count))
        data.append(le32: UInt32(content.count))
        data.append(le16: UInt16(name.count))
        data.append(le16: 0)           // extra field length
        data.append(name)
        data.append(content)
    }

    mutating func add(_ path: String, _ text: String) {
        add(path, Data(text.utf8))
    }

    /// The archive: entries, central directory and end record.
    func finished() -> Data {
        var archive = data
        let directoryOffset = UInt32(archive.count)
        for entry in entries {
            archive.append(le32: 0x0201_4B50)
            archive.append(le16: 20)   // version made by
            archive.append(le16: 20)   // version needed
            archive.append(le16: 0x0800)
            archive.append(le16: 0)
            archive.append(le16: dosTime)
            archive.append(le16: dosDate)
            archive.append(le32: entry.crc)
            archive.append(le32: entry.size)
            archive.append(le32: entry.size)
            archive.append(le16: UInt16(entry.name.count))
            archive.append(le16: 0)    // extra
            archive.append(le16: 0)    // comment
            archive.append(le16: 0)    // disk
            archive.append(le16: 0)    // internal attributes
            archive.append(le32: 0)    // external attributes
            archive.append(le32: entry.offset)
            archive.append(entry.name)
        }
        let directorySize = UInt32(archive.count) - directoryOffset
        archive.append(le32: 0x0605_4B50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(entries.count))
        archive.append(le16: UInt16(entries.count))
        archive.append(le32: directorySize)
        archive.append(le32: directoryOffset)
        archive.append(le16: 0)
        return archive
    }

    /// CRC-32 (IEEE 802.3, reflected), as ZIP requires.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
