import Foundation

/// Fonts offered in the font library: free fonts with Cyrillic (SIL Open Font License, from the Google Fonts
/// repository) that are downloaded with one click, plus commercial fonts that are bought from their foundry.
public struct CatalogFont: Identifiable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case sans, condensed, serif, script, display, commercial
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .sans: return L("Гротески")
            case .condensed: return L("Узкие и плотные")
            case .serif: return L("С засечками")
            case .script: return L("Рукописные")
            case .display: return L("Необычные")
            case .commercial: return L("Платные")
            }
        }
    }

    public enum Source: Hashable, Sendable {
        /// Downloaded from github.com/google/fonts (`ofl/<dir>/<file>`).
        case googleFonts(dir: String, files: [String])
        /// Bought on the foundry's site, then added as files.
        case commercial(url: URL, vendor: String)
    }

    public let id: String
    public let family: String
    public let category: Category
    public let details: String
    public let source: Source
    /// Shipped inside the app.
    public let bundled: Bool
    public let popular: Bool
    public let cyrillic: Bool

    public var isCommercial: Bool {
        if case .commercial = source { return true }
        return false
    }

    public var installDir: URL { AppPaths.userFontsDir.appendingPathComponent(id, isDirectory: true) }

    /// Downloadable files (font files and the license).
    public var downloads: [(url: URL, name: String)] {
        guard case .googleFonts(let dir, let files) = source else { return [] }
        let base = "https://raw.githubusercontent.com/google/fonts/main/ofl/\(dir)/"
        var result: [(URL, String)] = []
        for file in files + ["OFL.txt"] {
            let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "[]"))) ?? file
            if let url = URL(string: base + encoded) { result.append((url, file)) }
        }
        return result
    }
}

public enum FontCatalog {
    private static func free(_ id: String, _ family: String, _ category: CatalogFont.Category, _ details: String,
                             dir: String, files: [String], bundled: Bool, popular: Bool) -> CatalogFont {
        CatalogFont(id: id, family: family, category: category, details: details,
                    source: .googleFonts(dir: dir, files: files), bundled: bundled, popular: popular, cyrillic: true)
    }

    public static let fonts: [CatalogFont] = [
        free("montserrat", "Montserrat", .sans, L("Геометрический гротеск от тонкого до чёрного начертания, хорошо читается на телефоне."), dir: "montserrat", files: ["Montserrat[wght].ttf", "Montserrat-Italic[wght].ttf"], bundled: true, popular: true),
        free("manrope", "Manrope", .sans, L("Спокойный геометрический гротеск."), dir: "manrope", files: ["Manrope[wght].ttf"], bundled: true, popular: false),
        free("inter", "Inter", .sans, L("Нейтральный шрифт для экранов, остаётся чётким даже в мелком размере."), dir: "inter", files: ["Inter[opsz,wght].ttf", "Inter-Italic[opsz,wght].ttf"], bundled: false, popular: true),
        free("geologica", "Geologica", .sans, L("Гротеск с переменным наклоном и резкостью углов."), dir: "geologica", files: ["Geologica[CRSV,SHRP,slnt,wght].ttf"], bundled: false, popular: true),
        free("golostext", "Golos Text", .sans, L("Спокойный российский гротеск."), dir: "golostext", files: ["GolosText[wght].ttf"], bundled: false, popular: false),
        free("onest", "Onest", .sans, L("Мягкий гротеск для блогов и экспертных роликов."), dir: "onest", files: ["Onest[wght].ttf"], bundled: false, popular: false),
        free("rubik", "Rubik", .sans, L("Гротеск со скруглёнными углами."), dir: "rubik", files: ["Rubik[wght].ttf", "Rubik-Italic[wght].ttf"], bundled: false, popular: true),
        free("jost", "Jost", .sans, L("Геометрический, в духе Futura."), dir: "jost", files: ["Jost[wght].ttf", "Jost-Italic[wght].ttf"], bundled: false, popular: false),
        free("raleway", "Raleway", .sans, L("Гротеск с очень тонкими начертаниями."), dir: "raleway", files: ["Raleway[wght].ttf", "Raleway-Italic[wght].ttf"], bundled: false, popular: false),
        free("nunito", "Nunito", .sans, L("Гротеск со скруглёнными концами штрихов."), dir: "nunito", files: ["Nunito[wght].ttf", "Nunito-Italic[wght].ttf"], bundled: false, popular: false),
        free("exo2", "Exo 2", .sans, L("Угловатый гротеск для роликов про технику и игры."), dir: "exo2", files: ["Exo2[wght].ttf", "Exo2-Italic[wght].ttf"], bundled: false, popular: false),
        free("wixmadefordisplay", "Wix Madefor Display", .sans, L("Гротеск для заголовков."), dir: "wixmadefordisplay", files: ["WixMadeforDisplay[wght].ttf"], bundled: false, popular: false),
        free("commissioner", "Commissioner", .sans, L("Гротеск с переменной формой штрихов."), dir: "commissioner", files: ["Commissioner[FLAR,VOLM,slnt,wght].ttf"], bundled: false, popular: false),
        free("tenorsans", "Tenor Sans", .sans, L("Гротеск с лёгким контрастом, одно начертание."), dir: "tenorsans", files: ["TenorSans-Regular.ttf"], bundled: false, popular: false),
        free("montserratalternates", "Montserrat Alternates", .sans, L("Montserrat с необычными формами букв."), dir: "montserratalternates", files: ["MontserratAlternates-Regular.ttf", "MontserratAlternates-Medium.ttf", "MontserratAlternates-SemiBold.ttf", "MontserratAlternates-Bold.ttf", "MontserratAlternates-ExtraBold.ttf", "MontserratAlternates-Black.ttf", "MontserratAlternates-Italic.ttf", "MontserratAlternates-BoldItalic.ttf"], bundled: false, popular: false),
        free("oswald", "Oswald", .condensed, L("Узкий плотный гротеск, в строку помещается больше слов."), dir: "oswald", files: ["Oswald[wght].ttf"], bundled: true, popular: true),
        free("unbounded", "Unbounded", .condensed, L("Широкий гротеск с округлыми формами."), dir: "unbounded", files: ["Unbounded[wght].ttf"], bundled: true, popular: true),
        free("delagothicone", "Dela Gothic One", .condensed, L("Очень жирный акцидентный шрифт для коротких фраз."), dir: "delagothicone", files: ["DelaGothicOne-Regular.ttf"], bundled: true, popular: true),
        free("russoone", "Russo One", .condensed, L("Жирный шрифт в спортивном стиле."), dir: "russoone", files: ["RussoOne-Regular.ttf"], bundled: false, popular: true),
        free("robotocondensed", "Roboto Condensed", .condensed, L("Узкая версия Roboto, много начертаний."), dir: "robotocondensed", files: ["RobotoCondensed[wght].ttf", "RobotoCondensed-Italic[wght].ttf"], bundled: false, popular: false),
        free("yanonekaffeesatz", "Yanone Kaffeesatz", .condensed, L("Узкий гротеск с мягкими формами."), dir: "yanonekaffeesatz", files: ["YanoneKaffeesatz[wght].ttf"], bundled: false, popular: false),
        free("ptsansnarrow", "PT Sans Narrow", .condensed, L("Узкий PT Sans от ParaType (бесплатный)."), dir: "ptsansnarrow", files: ["PT_Sans-Narrow-Web-Regular.ttf", "PT_Sans-Narrow-Web-Bold.ttf"], bundled: false, popular: false),
        free("rubikmonoone", "Rubik Mono One", .condensed, L("Жирный моноширинный шрифт."), dir: "rubikmonoone", files: ["RubikMonoOne-Regular.ttf"], bundled: false, popular: false),
        free("tektur", "Tektur", .condensed, L("Угловатый шрифт в техническом стиле."), dir: "tektur", files: ["Tektur[wdth,wght].ttf"], bundled: false, popular: false),
        free("playfairdisplay", "Playfair Display", .serif, L("Контрастная антиква для заголовков."), dir: "playfairdisplay", files: ["PlayfairDisplay[wght].ttf", "PlayfairDisplay-Italic[wght].ttf"], bundled: true, popular: true),
        free("cormorantgaramond", "Cormorant Garamond", .serif, L("Тонкая контрастная антиква в духе Гарамона."), dir: "cormorantgaramond", files: ["CormorantGaramond[wght].ttf", "CormorantGaramond-Italic[wght].ttf"], bundled: true, popular: true),
        free("prata", "Prata", .serif, L("Дидона с сильным контрастом штрихов."), dir: "prata", files: ["Prata-Regular.ttf"], bundled: false, popular: true),
        free("yesevaone", "Yeseva One", .serif, L("Жирная декоративная антиква."), dir: "yesevaone", files: ["YesevaOne-Regular.ttf"], bundled: false, popular: true),
        free("lora", "Lora", .serif, L("Мягкая книжная антиква."), dir: "lora", files: ["Lora[wght].ttf", "Lora-Italic[wght].ttf"], bundled: false, popular: false),
        free("merriweather", "Merriweather", .serif, L("Антиква, сделанная для чтения с экрана."), dir: "merriweather", files: ["Merriweather[opsz,wdth,wght].ttf", "Merriweather-Italic[opsz,wdth,wght].ttf"], bundled: false, popular: false),
        free("ptserif", "PT Serif", .serif, L("Классическая антиква ParaType (бесплатная)."), dir: "ptserif", files: ["PT_Serif-Web-Regular.ttf", "PT_Serif-Web-Bold.ttf", "PT_Serif-Web-Italic.ttf", "PT_Serif-Web-BoldItalic.ttf"], bundled: false, popular: false),
        free("oldstandardtt", "Old Standard TT", .serif, L("Антиква в духе старых книг."), dir: "oldstandardtt", files: ["OldStandard-Regular.ttf", "OldStandard-Bold.ttf", "OldStandard-Italic.ttf"], bundled: false, popular: false),
        free("spectral", "Spectral", .serif, L("Светлая антиква для экранов."), dir: "spectral", files: ["Spectral-Regular.ttf", "Spectral-Medium.ttf", "Spectral-SemiBold.ttf", "Spectral-Bold.ttf", "Spectral-ExtraBold.ttf", "Spectral-Italic.ttf", "Spectral-BoldItalic.ttf"], bundled: false, popular: false),
        free("alice", "Alice", .serif, L("Сказочная антиква."), dir: "alice", files: ["Alice-Regular.ttf"], bundled: false, popular: false),
        free("caveat", "Caveat", .script, L("Рукописный шрифт, похож на надпись маркером."), dir: "caveat", files: ["Caveat[wght].ttf"], bundled: true, popular: true),
        free("marckscript", "Marck Script", .script, L("Каллиграфический курсив."), dir: "marckscript", files: ["MarckScript-Regular.ttf"], bundled: false, popular: true),
        free("lobster", "Lobster", .script, L("Жирный рукописный шрифт со слитными буквами."), dir: "lobster", files: ["Lobster-Regular.ttf"], bundled: false, popular: true),
        free("pacifico", "Pacifico", .script, L("Ретро-скрипт в стиле серфинга."), dir: "pacifico", files: ["Pacifico-Regular.ttf"], bundled: false, popular: false),
        free("badscript", "Bad Script", .script, L("Небрежный почерк."), dir: "badscript", files: ["BadScript-Regular.ttf"], bundled: false, popular: false),
        free("amaticsc", "Amatic SC", .script, L("Узкий рисованный капслок."), dir: "amaticsc", files: ["AmaticSC-Regular.ttf", "AmaticSC-Bold.ttf"], bundled: false, popular: false),
        free("greatvibes", "Great Vibes", .script, L("Свадебная каллиграфия."), dir: "greatvibes", files: ["GreatVibes-Regular.ttf"], bundled: false, popular: false),
        free("shantellsans", "Shantell Sans", .script, L("Неровный гротеск, будто написан маркером."), dir: "shantellsans", files: ["ShantellSans[BNCE,INFM,SPAC,wght].ttf", "ShantellSans-Italic[BNCE,INFM,SPAC,wght].ttf"], bundled: false, popular: false),
        free("neucha", "Neucha", .script, L("Простой рукописный."), dir: "neucha", files: ["Neucha.ttf"], bundled: false, popular: false),
        free("comfortaa", "Comfortaa", .display, L("Круглый геометрический."), dir: "comfortaa", files: ["Comfortaa[wght].ttf"], bundled: false, popular: true),
        free("pressstart2p", "Press Start 2P", .display, L("Пиксельный, как в старых играх."), dir: "pressstart2p", files: ["PressStart2P-Regular.ttf"], bundled: false, popular: false),
        free("rubikglitch", "Rubik Glitch", .display, L("Буквы с эффектом цифровых помех."), dir: "rubikglitch", files: ["RubikGlitch-Regular.ttf"], bundled: false, popular: false),
        free("rubikwetpaint", "Rubik Wet Paint", .display, L("Буквы со стекающей краской."), dir: "rubikwetpaint", files: ["RubikWetPaint-Regular.ttf"], bundled: false, popular: false),
        free("rubikdirt", "Rubik Dirt", .display, L("Буквы с потёртой фактурой."), dir: "rubikdirt", files: ["RubikDirt-Regular.ttf"], bundled: false, popular: false),
        free("trainone", "Train One", .display, L("Буквы с объёмным двойным контуром."), dir: "trainone", files: ["TrainOne-Regular.ttf"], bundled: false, popular: false),
        free("kellyslab", "Kelly Slab", .display, L("Брусковый акцидентный."), dir: "kellyslab", files: ["KellySlab-Regular.ttf"], bundled: false, popular: false),
        free("ruslandisplay", "Ruslan Display", .display, L("Буквы в старорусском стиле."), dir: "ruslandisplay", files: ["RuslanDisplay-Regular.ttf"], bundled: false, popular: false),
        CatalogFont(id: "stapel", family: "Stapel", category: .commercial,
                    details: L("Узкий плотный гротеск Александра Любовенко (ParaType), 18 начертаний с кириллицей. Шрифт платный, купите его на сайте ParaType и добавьте файлы."),
                    source: .commercial(url: URL(string: "https://www.paratype.ru/fonts/pt/stapel")!, vendor: "ParaType"),
                    bundled: false, popular: true, cyrillic: true),
        CatalogFont(id: "akkordeon", family: "Akkordeon", category: .commercial,
                    details: L("Акцидентный гротеск Эдуардо Мансо (Emtype Foundry), ширины от узкой до широкой. В шрифте только латиница, русские буквы будут набраны другим шрифтом."),
                    source: .commercial(url: URL(string: "https://emtype.net/fonts/akkordeon")!, vendor: "Emtype Foundry"),
                    bundled: false, popular: false, cyrillic: false),
    ]

    public static func font(id: String) -> CatalogFont? { fonts.first { $0.id == id } }
}
