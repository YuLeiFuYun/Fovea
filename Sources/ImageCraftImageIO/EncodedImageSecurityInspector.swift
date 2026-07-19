import Foundation
import ImageCraftCore

struct EncodedImageSecurityInspection: Sendable {
  let format: EncodedImageFormat
  let metadataByteCount: Int
}

enum EncodedImageSecurityInspector {
  static func inspect(_ data: Data) throws -> EncodedImageSecurityInspection {
    if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
      return try inspectPNG(data)
    }
    if data.starts(with: [0xFF, 0xD8]) {
      return try inspectJPEG(data)
    }
    if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
      return try inspectGIF(data)
    }
    throw ImageCraftError.unsupportedFormat
  }

  private static func inspectPNG(_ data: Data) throws -> EncodedImageSecurityInspection {
    var offset = 8
    var metadataBytes = 0
    var foundEnd = false
    let metadataChunks: Set<String> = ["iCCP", "eXIf", "iTXt", "tEXt", "zTXt"]
    while offset < data.count {
      guard let length = readUInt32BE(data, at: offset) else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let payloadLength = Int(length)
      let chunkEnd = offset.addingReportingOverflow(12 + payloadLength)
      guard !chunkEnd.overflow, chunkEnd.partialValue <= data.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let typeRange = (offset + 4)..<(offset + 8)
      guard let type = String(data: data[typeRange], encoding: .ascii) else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      if metadataChunks.contains(type) {
        metadataBytes = try adding(metadataBytes, payloadLength)
      }
      offset = chunkEnd.partialValue
      if type == "IEND" {
        foundEnd = true
        break
      }
    }
    guard foundEnd else { throw ImageCraftError.unsupportedOrCorruptImage }
    return EncodedImageSecurityInspection(format: .png, metadataByteCount: metadataBytes)
  }

  private static func inspectJPEG(_ data: Data) throws -> EncodedImageSecurityInspection {
    var offset = 2
    var metadataBytes = 0
    while offset < data.count {
      while offset < data.count, data[offset] == 0xFF { offset += 1 }
      guard offset < data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let marker = data[offset]
      offset += 1
      if marker == 0xD9 { break }
      if marker == 0xDA {
        return EncodedImageSecurityInspection(format: .jpeg, metadataByteCount: metadataBytes)
      }
      if marker == 0x01 || (0xD0...0xD8).contains(marker) { continue }
      guard let rawLength = readUInt16BE(data, at: offset), rawLength >= 2 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let segmentLength = Int(rawLength)
      let segmentEnd = offset.addingReportingOverflow(segmentLength)
      guard !segmentEnd.overflow, segmentEnd.partialValue <= data.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      if marker == 0xE1 || marker == 0xE2 || marker == 0xED || marker == 0xFE {
        metadataBytes = try adding(metadataBytes, segmentLength - 2)
      }
      offset = segmentEnd.partialValue
    }
    return EncodedImageSecurityInspection(format: .jpeg, metadataByteCount: metadataBytes)
  }

  private static func inspectGIF(_ data: Data) throws -> EncodedImageSecurityInspection {
    guard data.count >= 13 else { throw ImageCraftError.unsupportedOrCorruptImage }
    var offset = 13
    let packed = data[10]
    if packed & 0x80 != 0 {
      let tableSize = 3 * (1 << (Int(packed & 0x07) + 1))
      offset = try advancing(offset, by: tableSize, limit: data.count)
    }
    var metadataBytes = 0
    while offset < data.count {
      let marker = data[offset]
      offset += 1
      switch marker {
      case 0x3B:
        return EncodedImageSecurityInspection(format: .gif, metadataByteCount: metadataBytes)
      case 0x21:
        guard offset < data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
        offset += 1
        let result = try skipSubBlocks(data, from: offset)
        metadataBytes = try adding(metadataBytes, result.payloadBytes)
        offset = result.nextOffset
      case 0x2C:
        offset = try advancing(offset, by: 9, limit: data.count)
        let localPacked = data[offset - 1]
        if localPacked & 0x80 != 0 {
          let tableSize = 3 * (1 << (Int(localPacked & 0x07) + 1))
          offset = try advancing(offset, by: tableSize, limit: data.count)
        }
        offset = try advancing(offset, by: 1, limit: data.count)
        offset = try skipSubBlocks(data, from: offset).nextOffset
      default:
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }
    throw ImageCraftError.unsupportedOrCorruptImage
  }

  private static func skipSubBlocks(
    _ data: Data,
    from initialOffset: Int
  ) throws -> (nextOffset: Int, payloadBytes: Int) {
    var offset = initialOffset
    var payloadBytes = 0
    while true {
      guard offset < data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let length = Int(data[offset])
      offset += 1
      if length == 0 { return (offset, payloadBytes) }
      offset = try advancing(offset, by: length, limit: data.count)
      payloadBytes = try adding(payloadBytes, length)
    }
  }

  private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
  }

  private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }

  private static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw ImageCraftError.metadataLimitExceeded }
    return result.partialValue
  }

  private static func advancing(_ offset: Int, by count: Int, limit: Int) throws -> Int {
    let result = offset.addingReportingOverflow(count)
    guard !result.overflow, result.partialValue <= limit else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return result.partialValue
  }
}
