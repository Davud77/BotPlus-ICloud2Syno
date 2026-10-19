import Foundation

/// Обертка стандартного ответа DSM WebAPI
public struct SynologyAPIResponse<T: Decodable>: Decodable {
  public let success: Bool
  public let data: T?
  public let error: SynologyAPIErrorPayload?
}

/// Информация об ошибке WebAPI
public struct SynologyAPIErrorPayload: Decodable {
  public let code: Int
  public let parameter: ParameterFailure?

  public struct ParameterFailure: Decodable {
    public let name: String?
    public let reason: String?
  }

  public init(code: Int) {
    self.code = code
    self.parameter = nil
  }

  private enum CodingKeys: String, CodingKey { case code, errors }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(Int.self, forKey: .code)
    parameter = try? container.decode(ParameterFailure.self, forKey: .errors)
  }
}

/// Данные успешной авторизации
public struct SynologyAuthData: Decodable {
  public let sid: String
  public let did: String?
  public let synotoken: String?

  private enum CodingKeys: String, CodingKey {
    case sid
    case did
    case synotoken
  }
}

/// Гибкая структура данных результата выгрузки файла
public struct SynologyUploadData: Decodable {
  public let id: Int?
  public let itemId: Int?
  public let name: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case itemId = "item_id"
    case name
  }

  public init(from decoder: Decoder) throws {
    if let singleVal = try? decoder.singleValueContainer(),
      let intVal = try? singleVal.decode(Int.self)
    {
      self.id = intVal
      self.itemId = intVal
      self.name = nil
      return
    }
    let container = try? decoder.container(keyedBy: CodingKeys.self)
    self.id = try? container?.decodeIfPresent(Int.self, forKey: .id)
    self.itemId = try? container?.decodeIfPresent(Int.self, forKey: .itemId)
    self.name = try? container?.decodeIfPresent(String.self, forKey: .name)
  }

  public var effectiveId: Int? {
    return id ?? itemId
  }
}

/// Структура элемента альбома Synology
public struct SynologyAlbumItem: Decodable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  public let itemCount: Int

  init(id: Int, name: String, itemCount: Int) {
    self.id = id
    self.name = name
    self.itemCount = itemCount
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case itemCount = "item_count"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(Int.self, forKey: .id)
    self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    self.itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
  }
}

/// Ответ на запрос списка альбомов
public struct SynologyAlbumListData: Decodable {
  public let list: [SynologyAlbumItem]
  public let total: Int?

  private enum CodingKeys: String, CodingKey {
    case list
    case total
  }
}

/// Ответ на создание альбома
public struct SynologyAlbumCreateData: Decodable {
  public let id: Int?
  public let name: String?
  public let album: SynologyAlbumSubItem?

  public struct SynologyAlbumSubItem: Decodable {
    public let id: Int
  }

  public var albumId: Int? {
    return id ?? album?.id
  }
}

/// Пользовательское описание ошибок Synology WebAPI
public enum SynologyError: LocalizedError {
  case invalidURL
  case invalidParameters(field: String?, reason: String?)
  case networkError(Error)
  case sessionExpired
  case twoFactorRequired
  case twoFactorFailed
  case invalidCredentials
  case permissionDenied
  case uploadFailed(code: Int, message: String)
  case albumOperationFailed(message: String)
  case unexpectedResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidParameters(let field, let reason):
      return
        "NAS отклонил параметры запроса (120): поле \(field ?? "неизвестно"), причина \(reason ?? "не указана")."
    case .invalidURL:
      return "Неверный адрес сервера Synology NAS."
    case .networkError(let error):
      return "Сетевая ошибка: \(error.localizedDescription)"
    case .sessionExpired:
      return "Сессия Synology истекла (код 119). Требуется повторный вход."
    case .twoFactorRequired:
      return "Требуется одноразовый код 2FA (OTP). Введите его в настройках."
    case .twoFactorFailed:
      return "Неверный код 2FA (OTP). Проверьте приложение аутентификации."
    case .invalidCredentials:
      return "Неверный логин или пароль администратора/пользователя NAS."
    case .permissionDenied:
      return "Недостаточно прав для работы с Synology Photos."
    case .uploadFailed(let code, let msg):
      return "Ошибка загрузки файла (код \(code)): \(msg)"
    case .albumOperationFailed(let msg):
      return "Ошибка операции с альбомом: \(msg)"
    case .unexpectedResponse(let detail):
      return "Непредвиденный ответ от сервера: \(detail)"
    }
  }

  public static func mapCode(_ code: Int) -> SynologyError {
    switch code {
    case 100:
      return .unexpectedResponse("Неизвестная ошибка сервера (код 100)")
    case 101:
      return .unexpectedResponse("Неверные параметры запроса или неподдерживаемый метод (код 101)")
    case 102:
      return .unexpectedResponse("Запрошенный API не существует на сервере (код 102)")
    case 103:
      return .unexpectedResponse("Запрошенный метод не существует (код 103)")
    case 104:
      return .unexpectedResponse("Версия API не поддерживается сервером (код 104)")
    case 106, 107, 119:
      return .sessionExpired
    case 120:
      return .unexpectedResponse("Ошибка параметров запроса (код 120)")
    case 400:
      return .invalidCredentials
    case 401:
      return .unexpectedResponse("Учетная запись отключена (код 401)")
    case 402, 105:
      return .permissionDenied
    case 403:
      return .twoFactorRequired
    case 404:
      return .twoFactorFailed
    default:
      return .unexpectedResponse("Код ошибки DSM: \(code)")
    }
  }
}
