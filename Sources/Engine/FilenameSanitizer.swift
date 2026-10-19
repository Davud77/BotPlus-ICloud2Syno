import CryptoKit
import Foundation

/// Санитайзер имен файлов для Synology Photos API
/// Обеспечивает 100% совместимость с HTTP-заголовками multipart/form-data и C-парсером Synology DSM WebAPI
public enum FilenameSanitizer {

  /// Stable suffix prevents different Photos assets with the same name overwriting/skipping one another.
  public static func assetBase(_ base: String, identifier: String) -> String {
    let digest = SHA256.hash(data: Data(identifier.utf8)).prefix(10).map {
      String(format: "%02x", $0)
    }.joined()
    return "\(String(sanitizeBase(base).prefix(120)))_\(digest)"
  }

  public static func assetFilename(_ filename: String, identifier: String) -> String {
    let safe = sanitize(filename) as NSString
    let base = assetBase(safe.deletingPathExtension, identifier: identifier)
    return safe.pathExtension.isEmpty ? base : "\(base).\(safe.pathExtension)"
  }

  private static let cyrillicToLatinMap: [Character: String] = [
    "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Е": "E", "Ё": "Yo",
    "Ж": "Zh", "З": "Z", "И": "I", "Й": "Y", "К": "K", "Л": "L", "М": "M",
    "Н": "N", "О": "O", "П": "P", "Р": "R", "С": "S", "Т": "T", "У": "U",
    "Ф": "F", "Х": "Kh", "Ц": "Ts", "Ч": "Ch", "Ш": "Sh", "Щ": "Shch",
    "Ъ": "", "Ы": "Y", "Ь": "", "Э": "E", "Ю": "Yu", "Я": "Ya",
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
  ]

  /// Преобразует базовое имя файла (без расширения) в безопасный ASCII-вид
  public static func sanitizeBase(_ originalBase: String) -> String {
    var base = originalBase

    // 1. Преобразование стандартных шаблонов Apple Photos
    base = base.replacingOccurrences(of: "Без даты", with: "Bez_daty")
    base = base.replacingOccurrences(of: "без даты", with: "bez_daty")
    base = base.replacingOccurrences(of: "БЕЗ ДАТЫ", with: "BEZ_DATY")
    base = base.replacingOccurrences(of: "Снимок экрана", with: "Screenshot")
    base = base.replacingOccurrences(of: "снимок экрана", with: "screenshot")

    // 2. Транслитерация через CoreFoundation (ICU Transform to Latin & strip combining marks)
    let mutable = NSMutableString(string: base) as CFMutableString
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
    let icuResult = mutable as String

    // 3. Дополнительная замена оставшихся не-ASCII символов через словарь и фильтрация
    var safeChars: [Character] = []
    for ch in icuResult {
      if let mapped = cyrillicToLatinMap[ch] {
        safeChars.append(contentsOf: mapped)
      } else if ch.isASCII
        && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." || ch == "("
          || ch == ")" || ch == " ")
      {
        safeChars.append(ch)
      } else if ch == "/" || ch == "\\" || ch == ":" || ch == "*" || ch == "?" || ch == "\""
        || ch == "<" || ch == ">" || ch == "|"
      {
        safeChars.append("_")
      } else if !ch.isASCII {
        // Если остался не-ASCII символ (например, эмодзи), заменяем на безопасный разделитель
        safeChars.append("_")
      } else {
        safeChars.append("_")
      }
    }

    var result = String(safeChars)

    // 4. Сжатие подряд идущих подчеркиваний и пробелов
    while result.contains("__") {
      result = result.replacingOccurrences(of: "__", with: "_")
    }
    while result.contains("  ") {
      result = result.replacingOccurrences(of: "  ", with: " ")
    }

    result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ._"))

    // Если базовое имя оказалось пустым, даем дефолтное
    if result.isEmpty {
      result = "photo"
    }

    return String(result.prefix(160))
  }

  /// Преобразует полное имя файла (с расширением) в безопасную ASCII-совместимую строку
  public static func sanitize(_ filename: String) -> String {
    let nsFilename = filename as NSString
    let ext = nsFilename.pathExtension
    let base = nsFilename.deletingPathExtension

    let safeBase = sanitizeBase(base)

    if ext.isEmpty {
      return safeBase
    } else {
      // Очищаем и расширение на случай спецсимволов
      let safeExt = ext.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(16)
        .lowercased()
      return "\(safeBase).\(safeExt.isEmpty ? "jpg" : safeExt)"
    }
  }
}
