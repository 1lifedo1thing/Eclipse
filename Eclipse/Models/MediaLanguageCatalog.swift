import Foundation

enum MediaLanguageCatalog {
    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        let nativeName: String
        let aliases: [String]
        let filterValue: String

        func matches(query: String) -> Bool {
            let terms = MediaLanguageCatalog.searchKey(query).split(whereSeparator: { $0.isWhitespace })
            let searchable = MediaLanguageCatalog.searchKey(([id, name, nativeName] + aliases).joined(separator: " "))
            return terms.allSatisfy { searchable.contains($0) }
        }
    }

    static let languages: [Entry] = {
        var entries = baseData.split(separator: "\n").compactMap { line -> Entry? in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { return nil }
            let names = fields[3].components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            let name = preferredBaseNames[fields[0]] ?? names.first ?? fields[0]
            let native = Locale(identifier: fields[0]).localizedString(forLanguageCode: fields[0]) ?? name
            return entry(id: fields[0], name: name, nativeName: native, aliases: [fields[1], fields[2]] + names)
        }
        entries.append(contentsOf: [
            entry(id: "en-US", name: "American English", nativeName: "English (United States)", aliases: ["US English", "English US", "eng-US"]),
            entry(id: "en-GB", name: "British English", nativeName: "English (United Kingdom)", aliases: ["UK English", "English UK", "eng-GB"]),
            entry(id: "es-ES", name: "Spanish (Spain)", nativeName: "Español (España)", aliases: ["Castilian Spanish", "European Spanish", "spa-ES"]),
            entry(id: "es-419", name: "Latin American Spanish", nativeName: "Español latinoamericano", aliases: ["Latino", "Latin", "lat", "latam", "es-419", "spa-LATAM", "Spanish (Latino)", "Spanish (Latin America)", "Spanish Latino", "Latinoamericano"]),
            entry(id: "pt-BR", name: "Brazilian Portuguese", nativeName: "Português (Brasil)", aliases: ["Portuguese (Brazil)", "Portuguese BR", "por-BR"]),
            entry(id: "pt-PT", name: "European Portuguese", nativeName: "Português (Portugal)", aliases: ["Portuguese (Portugal)", "Portuguese PT", "por-PT"]),
            entry(id: "zh-Hans", name: "Simplified Chinese", nativeName: "简体中文", aliases: ["Chinese Simplified", "zho-Hans", "chi-Hans"]),
            entry(id: "zh-Hant", name: "Traditional Chinese", nativeName: "繁體中文", aliases: ["Chinese Traditional", "zho-Hant", "chi-Hant"]),
            entry(id: "cmn", name: "Mandarin Chinese", nativeName: "普通话", aliases: ["Mandarin", "cmn", "国语", "國語"]),
            entry(id: "yue", name: "Cantonese", nativeName: "粵語", aliases: ["Cantonese Chinese", "yue", "广东话", "廣東話"]),
            entry(id: "fil", name: "Filipino", nativeName: "Filipino", aliases: ["fil", "Pilipino"])
        ])
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func language(for value: String) -> Entry? {
        let key = lookupKey(value)
        let unwrapped = key.hasPrefix("language:") ? String(key.dropFirst("language:".count)) : key
        if let entry = entriesByAlias[unwrapped] { return entry }
        let components = unwrapped.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1, components.count <= 4,
              let base = entriesByAlias[components[0]], base.id.count == 2,
              components.dropFirst().allSatisfy({
                  (2...8).contains($0.count)
                    && !["audio", "dub", "dubbed", "dubs", "track", "tracks", "sub", "subs", "subtitle", "captions"].contains($0)
                    && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
              }) else { return nil }
        let suffixes = components.dropFirst().map { component -> String in
            if component.count == 2 || component.allSatisfy({ $0.isNumber }) { return component.uppercased() }
            if component.count == 4 { return component.prefix(1).uppercased() + component.dropFirst() }
            return component
        }
        let id = ([base.id] + suffixes).joined(separator: "-")
        if let entry = entriesByAlias[lookupKey(id)] { return entry }
        let name = Locale(identifier: "en").localizedString(forIdentifier: id) ?? "\(base.name) (\(suffixes.joined(separator: "-")))"
        let native = Locale(identifier: id).localizedString(forIdentifier: id) ?? name
        return entry(id: id, name: name, nativeName: native, aliases: [value])
    }

    static func canonicalID(for value: String) -> String? { language(for: value)?.id }

    static func displayName(for value: String) -> String {
        language(for: value)?.name ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func filterLanguage(for value: String) -> Entry? {
        let key = lookupKey(value)
        if key.hasPrefix("language:") { return language(for: value) }
        let tokens = Set(key.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let latinoMarkers: Set<String> = ["lat", "latin", "latino", "latam", "419", "latinoamerican", "latinamerican"]
        if !tokens.isDisjoint(with: latinoMarkers),
           !tokens.isDisjoint(with: ["es", "spa", "spanish", "lat", "latin", "latino", "latam"]) {
            return language(for: "es-419")
        }
        if ["cantonese", "mandarin"].contains(key) { return language(for: "zh") }
        if ["fil", "filipino", "pilipino"].contains(key) { return language(for: "tl") }
        if ["nb", "nob", "nn", "nno"].contains(key) { return language(for: "no") }
        if let prefix = key.split(separator: "-").first, prefix.count < key.count,
           let base = filterLanguage(for: String(prefix)), base.id.count == 2 {
            return base
        }
        return language(for: value)
    }

    static func filterCanonicalID(for value: String) -> String? { filterLanguage(for: value)?.id }

    static func filterDisplayName(for value: String) -> String {
        filterLanguage(for: value)?.name ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canonicalFilterValue(for value: String) -> String? { filterLanguage(for: value)?.filterValue }

    static func search(query: String) -> [Entry] { languages.filter { $0.matches(query: query) } }

    static func matches(ruleID: String, languageID: String) -> Bool {
        guard let rule = language(for: ruleID), let language = language(for: languageID) else { return false }
        if rule.id == language.id { return true }
        guard rule.id.count == 2, language.id != "es-419" else { return false }
        if language.id.hasPrefix(rule.id + "-") { return true }
        if rule.id == "zh", ["cmn", "yue"].contains(language.id) { return true }
        if rule.id == "no", ["nb", "nn"].contains(language.id) { return true }
        return rule.id == "tl" && language.id == "fil"
    }

    private static func entry(id: String, name: String, nativeName: String, aliases: [String]) -> Entry {
        Entry(id: id, name: name, nativeName: nativeName, aliases: aliases.filter { !$0.isEmpty }, filterValue: id.count == 2 && !["nb", "nn"].contains(id) ? id : "language:" + id)
    }

    private static func lookupKey(_ value: String) -> String {
        searchKey(value.trimmingCharacters(in: .whitespacesAndNewlines)).replacingOccurrences(of: "_", with: "-")
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    private static let entriesByAlias: [String: Entry] = {
        var result: [String: Entry] = [:]
        for entry in languages {
            for alias in [entry.id, entry.name, entry.nativeName] + entry.aliases {
                let key = lookupKey(alias)
                if result[key] == nil { result[key] = entry }
            }
        }
        for (alias, id) in ["jp": "ja", "iw": "he", "ji": "yi", "in": "id", "mo": "ro", "esp": "es", "farsi": "fa", "lat": "la", "latin": "la"] {
            result[alias] = languages.first { $0.id == id }
        }
        return result
    }()

    private static let preferredBaseNames = [
        "bh": "Bihari", "cu": "Church Slavonic", "el": "Greek", "gd": "Scottish Gaelic",
        "ht": "Haitian Creole", "ia": "Interlingua", "km": "Khmer", "nb": "Norwegian Bokmål", "nn": "Norwegian Nynorsk",
        "ny": "Chichewa", "tl": "Tagalog / Filipino"
    ]

    private static let baseData = """
aa|aar||Afar
ab|abk||Abkhazian
ae|ave||Avestan
af|afr||Afrikaans
ak|aka||Akan
am|amh||Amharic
an|arg||Aragonese
ar|ara||Arabic
as|asm||Assamese
av|ava||Avaric
ay|aym||Aymara
az|aze||Azerbaijani
ba|bak||Bashkir
be|bel||Belarusian
bg|bul||Bulgarian
bh|bih||Bihari
bi|bis||Bislama
bm|bam||Bambara
bn|ben||Bengali
bo|tib|bod|Tibetan
br|bre||Breton
bs|bos||Bosnian
ca|cat||Catalan; Valencian
ce|che||Chechen
ch|cha||Chamorro
co|cos||Corsican
cr|cre||Cree
cs|cze|ces|Czech
cu|chu||Church Slavic; Old Slavonic; Church Slavonic; Old Bulgarian; Old Church Slavonic
cv|chv||Chuvash
cy|wel|cym|Welsh
da|dan||Danish
de|ger|deu|German
dv|div||Divehi; Dhivehi; Maldivian
dz|dzo||Dzongkha
ee|ewe||Ewe
el|gre|ell|Modern Greek (1453-)
en|eng||English
eo|epo||Esperanto
es|spa||Spanish; Castilian
et|est||Estonian
eu|baq|eus|Basque
fa|per|fas|Persian
ff|ful||Fulah
fi|fin||Finnish
fj|fij||Fijian
fo|fao||Faroese
fr|fre|fra|French
fy|fry||Western Frisian
ga|gle||Irish
gd|gla||Gaelic; Scottish Gaelic
gl|glg||Galician
gn|grn||Guarani
gu|guj||Gujarati
gv|glv||Manx
ha|hau||Hausa
he|heb||Hebrew
hi|hin||Hindi
ho|hmo||Hiri Motu
hr|hrv||Croatian
ht|hat||Haitian; Haitian Creole
hu|hun||Hungarian
hy|arm|hye|Armenian
hz|her||Herero
ia|ina||Interlingua (International Auxiliary Language Association)
id|ind||Indonesian
ie|ile||Interlingue; Occidental
ig|ibo||Igbo
ii|iii||Sichuan Yi; Nuosu
ik|ipk||Inupiaq
io|ido||Ido
is|ice|isl|Icelandic
it|ita||Italian
iu|iku||Inuktitut
ja|jpn||Japanese
jv|jav||Javanese
ka|geo|kat|Georgian
kg|kon||Kongo
ki|kik||Kikuyu; Gikuyu
kj|kua||Kuanyama; Kwanyama
kk|kaz||Kazakh
kl|kal||Kalaallisut; Greenlandic
km|khm||Central Khmer
kn|kan||Kannada
ko|kor||Korean
kr|kau||Kanuri
ks|kas||Kashmiri
ku|kur||Kurdish
kv|kom||Komi
kw|cor||Cornish
ky|kir||Kirghiz; Kyrgyz
la|lat||Latin
lb|ltz||Luxembourgish; Letzeburgesch
lg|lug||Ganda
li|lim||Limburgan; Limburger; Limburgish
ln|lin||Lingala
lo|lao||Lao
lt|lit||Lithuanian
lu|lub||Luba-Katanga
lv|lav||Latvian
mg|mlg||Malagasy
mh|mah||Marshallese
mi|mao|mri|Maori
mk|mac|mkd|Macedonian
ml|mal||Malayalam
mn|mon||Mongolian
mr|mar||Marathi
ms|may|msa|Malay
mt|mlt||Maltese
my|bur|mya|Burmese
na|nau||Nauru
nb|nob||Norwegian Bokmål
nd|nde||North Ndebele
ne|nep||Nepali
ng|ndo||Ndonga
nl|dut|nld|Dutch; Flemish
nn|nno||Norwegian Nynorsk
no|nor||Norwegian
nr|nbl||South Ndebele
nv|nav||Navajo; Navaho
ny|nya||Chichewa; Chewa; Nyanja
oc|oci||Occitan (post 1500)
oj|oji||Ojibwa
om|orm||Oromo
or|ori||Oriya
os|oss||Ossetian; Ossetic
pa|pan||Panjabi; Punjabi
pi|pli||Pali
pl|pol||Polish
ps|pus||Pushto; Pashto
pt|por||Portuguese
qu|que||Quechua
rm|roh||Romansh
rn|run||Rundi
ro|rum|ron|Romanian; Moldavian; Moldovan
ru|rus||Russian
rw|kin||Kinyarwanda
sa|san||Sanskrit
sc|srd||Sardinian
sd|snd||Sindhi
se|sme||Northern Sami
sg|sag||Sango
si|sin||Sinhala; Sinhalese
sk|slo|slk|Slovak
sl|slv||Slovenian
sm|smo||Samoan
sn|sna||Shona
so|som||Somali
sq|alb|sqi|Albanian
sr|srp||Serbian
ss|ssw||Swati
st|sot||Sotho, Southern
su|sun||Sundanese
sv|swe||Swedish
sw|swa||Swahili
ta|tam||Tamil
te|tel||Telugu
tg|tgk||Tajik
th|tha||Thai
ti|tir||Tigrinya
tk|tuk||Turkmen
tl|tgl||Tagalog
tn|tsn||Tswana
to|ton||Tonga (Tonga Islands)
tr|tur||Turkish
ts|tso||Tsonga
tt|tat||Tatar
tw|twi||Twi
ty|tah||Tahitian
ug|uig||Uighur; Uyghur
uk|ukr||Ukrainian
ur|urd||Urdu
uz|uzb||Uzbek
ve|ven||Venda
vi|vie||Vietnamese
vo|vol||Volapük
wa|wln||Walloon
wo|wol||Wolof
xh|xho||Xhosa
yi|yid||Yiddish
yo|yor||Yoruba
za|zha||Zhuang; Chuang
zh|chi|zho|Chinese
zu|zul||Zulu
"""
}
