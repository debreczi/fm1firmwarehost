// SPDX-License-Identifier: GPL-3.0-only
// Ported from the FM-1 Firmware Hub (Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments).
//
// FM-1 .fwsc packages: the package identity and the image the device reads during an update.

import Foundation
import CryptoKit

struct FWSCPackage {
    static let blocks = 20
    static let blockSize = 0x30
    static let keep = 0x2F

    /// The official FM-1 V15 (the recovery image M-VAVE publishes). Only that exact file is accepted for
    /// "back to official": its SHA-256 pins every byte.
    static let stockV15SHA256 = "db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a"
    static let stockV15Size = 699_956
    static let stockV15Product = "FM-1_015"

    let bytes: [UInt8]
    let product: String
    let sha256: String

    init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= FWSCPackage.blocks * FWSCPackage.blockSize else {
            throw FM1Error.package("Not an FM-1 package (too short).")
        }
        bytes = b
        product = FWSCPackage.productOf(b)
        sha256 = FWSCPackage.sha256Hex(data)
        guard product.hasPrefix("FM-1_") || product.hasPrefix("SMK") || !product.isEmpty else {
            throw FM1Error.package("Not an FM-1 package (no identity).")
        }
    }

    /// The package identity ("FM-1_904"): one marker byte after each of the first 20 blocks.
    static func productOf(_ fwsc: [UInt8]) -> String {
        var s = ""
        for i in 0..<blocks {
            let m = Int(fwsc[i * blockSize + keep])
            if m != 0x7D {
                let c = UInt8((m - i - 1) & 0xFF)
                s.append(Character(UnicodeScalar(c)))
            }
        }
        return s
    }

    /// The image the device addresses during an update: the .fwsc without the 20 marker bytes.
    var logicalImage: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count - FWSCPackage.blocks)
        for i in 0..<FWSCPackage.blocks {
            let start = i * FWSCPackage.blockSize
            out.append(contentsOf: bytes[start..<(start + FWSCPackage.keep)])
        }
        out.append(contentsOf: bytes[(FWSCPackage.blocks * FWSCPackage.blockSize)...])
        return out
    }

    var isStockV15: Bool {
        bytes.count == FWSCPackage.stockV15Size && sha256 == FWSCPackage.stockV15SHA256 && product == FWSCPackage.stockV15Product
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
