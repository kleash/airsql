/// A BSON decimal: IEEE 754-2008 decimal128 in its binary integer decimal (BID) encoding, as MongoDB stores it. The
/// raw bits are kept, so 1.0 and 1.00 stay different values; `description` and `init?(_:)` convert to and from text
/// as MongoDB's drivers do (the BSON corpus's decimal128 vectors), with no rounding: text that can't be stored exactly
/// is refused.
public struct BSONDecimal128: Hashable, Sendable, CustomStringConvertible {
    public let low: UInt64
    public let high: UInt64

    public init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    static let maxDigits = 34
    static let bias = 6176
    static let maxExponent = 6111  // the largest exponent of a 34-digit coefficient: 10^6144 is the largest magnitude
    static let minExponent = -6176

    var isNegative: Bool { high >> 63 == 1 }
    var isInfinity: Bool { (high >> 58) & 0x1F == 0x1E }
    public var isNaN: Bool { (high >> 58) & 0x1F == 0x1F }

    public var description: String {
        if isNaN { return "NaN" }
        let sign = isNegative ? "-" : ""
        if isInfinity { return sign + "Infinity" }
        let exponent: Int
        var coefficient: (hi: UInt64, lo: UInt64)
        if (high >> 61) & 3 == 3 {
            // The large-coefficient form always exceeds 34 digits: not canonical, read as zero.
            exponent = Int((high >> 47) & 0x3FFF) - Self.bias
            coefficient = (0, 0)
        } else {
            exponent = Int((high >> 49) & 0x3FFF) - Self.bias
            coefficient = (high & 0x1_FFFF_FFFF_FFFF, low)
        }
        var digits = Self.digits(of: coefficient)
        if digits.count > Self.maxDigits { digits = "0" }  // also not canonical
        let scientific = digits.count - 1 + exponent
        if exponent > 0 || scientific < -6 {
            let rest = digits.dropFirst()
            return sign + String(digits.prefix(1)) + (rest.isEmpty ? "" : "." + rest) + "E" + (scientific >= 0 ? "+" : "")
                + String(scientific)
        }
        if exponent == 0 { return sign + digits }
        let point = digits.count + exponent
        if point > 0 { return sign + digits.prefix(point) + "." + digits.dropFirst(point) }
        return sign + "0." + String(repeating: "0", count: -point) + digits
    }

    /// Decimal text: an optional sign, digits with an optional point, an optional exponent; or Infinity, Inf or NaN
    /// in any case. Nil for anything else, and for values decimal128 can't hold exactly.
    public init?(_ text: String) {
        var s = Substring(text)
        var negative = false
        if let first = s.first, first == "+" || first == "-" {
            negative = first == "-"
            s = s.dropFirst()
        }
        let sign: UInt64 = negative ? 1 << 63 : 0
        switch s.lowercased() {
        case "inf", "infinity": self.init(low: 0, high: sign | 0x7800_0000_0000_0000); return
        case "nan": self.init(low: 0, high: sign | 0x7C00_0000_0000_0000); return
        default: break
        }
        var digits: [UInt8] = []
        var sawPoint = false, fraction = 0
        var bytes = s.utf8
        while let c = bytes.first {
            if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                digits.append(c - UInt8(ascii: "0"))
                if sawPoint { fraction += 1 }
            } else if c == UInt8(ascii: "."), !sawPoint {
                sawPoint = true
            } else {
                break
            }
            bytes = bytes.dropFirst()
        }
        guard !digits.isEmpty else { return nil }
        var exponent = 0
        if let c = bytes.first, c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
            bytes = bytes.dropFirst()
            var expNegative = false
            if let c = bytes.first, c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                expNegative = c == UInt8(ascii: "-")
                bytes = bytes.dropFirst()
            }
            guard !bytes.isEmpty else { return nil }
            for c in bytes {
                guard c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") else { return nil }
                // Saturates: anything this large is out of range either way.
                exponent = min(exponent * 10 + Int(c - UInt8(ascii: "0")), 100_000_000)
            }
            bytes = bytes.suffix(0)
            if expNegative { exponent = -exponent }
        }
        guard bytes.isEmpty else { return nil }
        exponent -= fraction
        if let firstSignificant = digits.firstIndex(where: { $0 != 0 }) {
            digits.removeFirst(firstSignificant)
        } else {
            digits = []
        }
        if digits.isEmpty {
            exponent = Swift.min(Swift.max(exponent, Self.minExponent), Self.maxExponent)
        } else {
            // Exact changes only: trailing zeros move into the exponent and back.
            while digits.count > Self.maxDigits, digits.last == 0 { digits.removeLast(); exponent += 1 }
            while exponent > Self.maxExponent, digits.count < Self.maxDigits { digits.append(0); exponent -= 1 }
            while exponent < Self.minExponent, digits.last == 0 { digits.removeLast(); exponent += 1 }
            guard digits.count <= Self.maxDigits, exponent <= Self.maxExponent, exponent >= Self.minExponent else {
                return nil
            }
        }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for d in digits {
            let (carry, product) = lo.multipliedFullWidth(by: 10)
            let (sum, overflow) = product.addingReportingOverflow(UInt64(d))
            lo = sum
            hi = hi * 10 + carry + (overflow ? 1 : 0)
        }
        self.init(low: lo, high: sign | UInt64(exponent + Self.bias) << 49 | hi)
    }

    /// A 128-bit unsigned integer in decimal, by 9 digits at a time.
    static func digits(of value: (hi: UInt64, lo: UInt64)) -> String {
        var (hi, lo) = value
        var chunks: [UInt64] = []
        let billion: UInt64 = 1_000_000_000
        while hi != 0 || lo != 0 {
            let r1 = hi % billion
            hi /= billion
            let (q, r) = billion.dividingFullWidth((r1, lo))
            lo = q
            chunks.append(r)
        }
        guard let top = chunks.popLast() else { return "0" }
        return String(top) + chunks.reversed().map { chunk -> String in
            let s = String(chunk)
            return String(repeating: "0", count: 9 - s.count) + s
        }.joined()
    }
}
