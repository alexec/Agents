@testable import CodeText
import Foundation
import Testing

/// Every code colour can be read on the paper it is printed on, and none reads as red
/// (041 SC-007, research R4; contract invariant 6).
struct PaletteContrastTests {
    @Test func everyRoleHasBothColoursExceptPlain() {
        for role in CodeRole.allCases where role != .plain {
            #expect(InkValues.light[role] != nil, "\(role) has no light colour")
            #expect(InkValues.dark[role] != nil, "\(role) has no dark colour")
        }
    }

    @Test func everyColourMeetsFourAndAHalfToOne() {
        for (palette, grounds) in [(InkValues.light, InkValues.backgrounds.light),
                                   (InkValues.dark, InkValues.backgrounds.dark)] {
            for (role, ink) in palette {
                for ground in grounds {
                    let ratio = Self.contrast(ink, ground)
                    #expect(ratio >= 4.5, "\(role) #\(String(ink, radix: 16)) on #\(String(ground, radix: 16)) is \(ratio)")
                }
            }
        }
    }

    @Test func nothingReadsAsRed() {
        for palette in [InkValues.light, InkValues.dark] {
            for (role, ink) in palette {
                let (hue, saturation) = Self.hueAndSaturation(ink)
                let fromRed = min(hue, 360 - hue)
                #expect(!(fromRed < 30 && saturation > 0.4), "\(role) reads as red")
            }
        }
    }

    // WCAG 2 relative luminance.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    static func hueAndSaturation(_ hex: UInt32) -> (Double, Double) {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255,
            b = Double(hex & 0xFF) / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        let lightness = (high + low) / 2
        guard delta > 0 else { return (0, 0) }
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        if high == r { hue = (g - b) / delta + (g < b ? 6 : 0) }
        else if high == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        return (hue * 60, saturation)
    }
}
