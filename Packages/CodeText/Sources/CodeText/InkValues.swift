/// The palette's numbers, in the package so `swift test` can check them (041 SC-007).
///
/// `Shared/UI/CodeInk.swift` turns these into colours; this file is the one to change.
/// Every value is checked by `PaletteContrastTests`: at least 4.5:1 against the page and the
/// well it sits on, light and dark, and nothing that reads as red, which the app keeps for
/// something having gone wrong (035 FR-013).
///
///     ROLE          LIGHT     DARK      WEIGHT
///     comment       #6E675B   #9C9486   italic
///     keyword       #2B4C8C   #8FB0E8   semibold
///     string        #4E6420   #A9C27A
///     number        #7A3E7A   #D5A3D5
///     type          #1F6A6A   #7CC4C0
///     function      #5B4BB5   #B3A6F0
///     property      #6B5A2E   #C9B27E
///     punctuation   #5F5A52   #A8A196
public enum InkValues {
    public static let light: [CodeRole: UInt32] = [
        .comment: 0x6E675B,
        .keyword: 0x2B4C8C,
        .string: 0x4E6420,
        .number: 0x7A3E7A,
        .type: 0x1F6A6A,
        .function: 0x5B4BB5,
        .property: 0x6B5A2E,
        .punctuation: 0x5F5A52,
    ]

    public static let dark: [CodeRole: UInt32] = [
        .comment: 0x9C9486,
        .keyword: 0x8FB0E8,
        .string: 0xA9C27A,
        .number: 0xD5A3D5,
        .type: 0x7CC4C0,
        .function: 0xB3A6F0,
        .property: 0xC9B27E,
        .punctuation: 0xA8A196,
    ]

    /// `Paper.ground` and `Paper.well`, which code is drawn on. Mirrored here for the test;
    /// `Shared/UI/Paper.swift` is where they are defined.
    public static let backgrounds: (light: [UInt32], dark: [UInt32]) = (
        light: [0xFBF9F4, 0xF1EDE4],
        dark: [0x1C1B19, 0x2A2825]
    )
}
