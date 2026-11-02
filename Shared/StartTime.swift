import Foundation

/// When the active task started, as a short Turkish date:
/// "02.11'de başladın", "02.11'den beri".
/// Used by the app, the widget and the Live Activity so they all say the same thing.
enum StartTime {
    /// "09:40"
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Now screen: "02.11'de başladın".
    static func sentence(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        "\(phrase(date, calendar: calendar, case: .locative)) başladın"
    }

    /// Widgets and Lock Screen: "02.11'den beri".
    static func since(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        "\(phrase(date, calendar: calendar, case: .ablative)) beri"
    }

    /// VoiceOver: "2 Kasım'da başladın".
    static func spoken(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month], from: date)
        let month = months[(c.month ?? 1) - 1]
        return "\(c.day ?? 1) \(month.full)'\(month.sound.suffix(.locative)) başladın"
    }

    /// The next moment the wording changes (midnight), for widget timelines.
    static func nextChange(after now: Date = .now, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)).addingTimeInterval(1)
    }

    // MARK: - Turkish suffixes

    enum Case { case locative, ablative }

    /// The sound a word ends in decides the suffix: back or front vowel, hard consonant or not.
    struct Sound {
        let back: Bool
        let hard: Bool

        func suffix(_ c: Case) -> String {
            let d = hard ? "t" : "d"
            let v = back ? "a" : "e"
            return c == .locative ? "\(d)\(v)" : "\(d)\(v)n"
        }
    }

    /// "02.11'de": day.month, the suffix follows the month number as read aloud.
    private static func phrase(_ date: Date, calendar: Calendar, case c: Case) -> String {
        let comps = calendar.dateComponents([.day, .month], from: date)
        let day = comps.day ?? 1, month = comps.month ?? 1
        return String(format: "%02d.%02d", day, month) + "'" + numberSound(month).suffix(c)
    }

    /// How a number 0–59 ends when read aloud.
    static func numberSound(_ n: Int) -> Sound {
        if n == 0 { return Sound(back: true, hard: false) }                 // sıfır
        switch n % 10 {
        case 1: return Sound(back: false, hard: false)                        // bir
        case 2: return Sound(back: false, hard: false)                        // iki
        case 3, 4, 5: return Sound(back: false, hard: true)                   // üç, dört, beş
        case 6: return Sound(back: true, hard: false)                         // altı
        case 7, 8: return Sound(back: false, hard: false)                     // yedi, sekiz
        case 9: return Sound(back: true, hard: false)                         // dokuz
        default: break
        }
        switch n / 10 {
        case 1, 3: return Sound(back: true, hard: false)                      // on, otuz
        case 4: return Sound(back: true, hard: true)                          // kırk
        default: return Sound(back: false, hard: false)                       // yirmi, elli
        }
    }

    private static let months: [(short: String, full: String, sound: Sound)] = [
        ("Oca", "Ocak", Sound(back: true, hard: true)),
        ("Şub", "Şubat", Sound(back: true, hard: true)),
        ("Mar", "Mart", Sound(back: true, hard: true)),
        ("Nis", "Nisan", Sound(back: true, hard: false)),
        ("May", "Mayıs", Sound(back: true, hard: true)),
        ("Haz", "Haziran", Sound(back: true, hard: false)),
        ("Tem", "Temmuz", Sound(back: true, hard: false)),
        ("Ağu", "Ağustos", Sound(back: true, hard: true)),
        ("Eyl", "Eylül", Sound(back: false, hard: false)),
        ("Eki", "Ekim", Sound(back: false, hard: false)),
        ("Kas", "Kasım", Sound(back: true, hard: false)),
        ("Ara", "Aralık", Sound(back: true, hard: true)),
    ]
}
