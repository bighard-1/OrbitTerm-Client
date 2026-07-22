import SwiftUI

struct TerminalRGB: Hashable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    var swiftUIColor: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    func brightened(multiplier: Double) -> TerminalRGB {
        TerminalRGB(
            r: UInt8(min(255, (Double(r) * multiplier).rounded())),
            g: UInt8(min(255, (Double(g) * multiplier).rounded())),
            b: UInt8(min(255, (Double(b) * multiplier).rounded()))
        )
    }
}

struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: TerminalRGB
    let foreground: TerminalRGB
    let ansi16: [TerminalRGB]

    /// Preserves each preset's canonical palette while improving the legibility
    /// of ANSI syntax colours in the live terminal viewport.
    var displayANSI16: [TerminalRGB] {
        ansi16.enumerated().map { index, color in
            index == 0 || index == 8 ? color : color.brightened(multiplier: 1.14)
        }
    }
}
enum TerminalThemeManager {
    static let storageKey = "orbitterm.terminal.theme.id"
    static let defaultThemeID = "dracula"
    static let presets: [TerminalTheme] = [
        .init(id:"dracula",name:"Dracula",background:.init(r:40,g:42,b:54),foreground:.init(r:248,g:248,b:242),ansi16:[.init(r:40,g:42,b:54),.init(r:255,g:85,b:85),.init(r:80,g:250,b:123),.init(r:241,g:250,b:140),.init(r:98,g:114,b:164),.init(r:255,g:121,b:198),.init(r:139,g:233,b:253),.init(r:248,g:248,b:242),.init(r:68,g:71,b:90),.init(r:255,g:110,b:110),.init(r:105,g:255,b:160),.init(r:255,g:255,b:170),.init(r:189,g:147,b:249),.init(r:255,g:146,b:213),.init(r:170,g:255,b:255),.init(r:255,g:255,b:255)]),
        .init(id:"solarized-dark",name:"Solarized Dark",background:.init(r:0,g:43,b:54),foreground:.init(r:131,g:148,b:150),ansi16:[.init(r:7,g:54,b:66),.init(r:220,g:50,b:47),.init(r:133,g:153,b:0),.init(r:181,g:137,b:0),.init(r:38,g:139,b:210),.init(r:211,g:54,b:130),.init(r:42,g:161,b:152),.init(r:238,g:232,b:213),.init(r:0,g:43,b:54),.init(r:203,g:75,b:22),.init(r:88,g:110,b:117),.init(r:101,g:123,b:131),.init(r:131,g:148,b:150),.init(r:108,g:113,b:196),.init(r:147,g:161,b:161),.init(r:253,g:246,b:227)]),
        .init(id:"nord",name:"Nord",background:.init(r:46,g:52,b:64),foreground:.init(r:216,g:222,b:233),ansi16:[.init(r:59,g:66,b:82),.init(r:191,g:97,b:106),.init(r:163,g:190,b:140),.init(r:235,g:203,b:139),.init(r:129,g:161,b:193),.init(r:180,g:142,b:173),.init(r:136,g:192,b:208),.init(r:229,g:233,b:240),.init(r:76,g:86,b:106),.init(r:191,g:97,b:106),.init(r:163,g:190,b:140),.init(r:235,g:203,b:139),.init(r:129,g:161,b:193),.init(r:180,g:142,b:173),.init(r:143,g:188,b:187),.init(r:236,g:239,b:244)]),
        .init(id:"homebrew",name:"Homebrew",background:.init(r:0,g:0,b:0),foreground:.init(r:0,g:255,b:102),ansi16:[.init(r:0,g:0,b:0),.init(r:0,g:221,b:0),.init(r:0,g:255,b:85),.init(r:85,g:255,b:85),.init(r:0,g:170,b:0),.init(r:0,g:204,b:0),.init(r:102,g:255,b:153),.init(r:170,g:255,b:187),.init(r:0,g:68,b:0),.init(r:51,g:255,b:51),.init(r:102,g:255,b:102),.init(r:153,g:255,b:153),.init(r:0,g:136,b:0),.init(r:51,g:204,b:51),.init(r:187,g:255,b:204),.init(r:221,g:255,b:221)])]
    static func theme(for id: String) -> TerminalTheme { presets.first(where:{$0.id==id}) ?? presets[0] }
}
