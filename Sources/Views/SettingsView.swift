import Photos
import ServiceManagement
import SwiftUI

/// ViewModel для управления состоянием экрана Настроек
@MainActor
public final class SettingsViewModel: ObservableObject {
  @Published public var passwordInput: String = ""
  @Published public var otpInput: String = ""
  @Published public var isTestingConnection: Bool = false
  @Published public var connectionTestMessage: String?
  @Published public var connectionTestSuccess: Bool = false
  @Published public var albumSearchQuery: String = ""
  @Published public var showResetAlert: Bool = false

  // Свойства для работы с вкладкой Логов
  @Published public var logSearchText: String = ""
  @Published public var selectedLogLevel: LogEntry.LogLevel? = nil
  @Published public var showCopiedAlert: Bool = false

  public init() {
    if let savedPassword = KeychainHelper.shared.getPassword() {
      self.passwordInput = savedPassword
    }
  }

  public func testConnection(config: SyncConfig, syncState: SyncState) {
    guard !isTestingConnection, !syncState.isSyncing else { return }
    let serverURL = config.serverURL
    let username = config.username
    let password = passwordInput
    let otp = otpInput
    let insecure = config.allowInsecureSSL
    isTestingConnection = true
    connectionTestMessage = nil

    Task {
      do {
        try KeychainHelper.shared.savePassword(password)
        let (server, dsm) = try await SynologyAPIClient.shared.testConnection(
          serverURL: serverURL,
          username: username,
          password: password,
          otpCode: otp.isEmpty ? nil : otp,
          allowInsecureSSL: insecure
        )
        await MainActor.run {
          self.otpInput = ""
          self.connectionTestSuccess = true
          self.connectionTestMessage = "Успешно: \(server) (\(dsm))"
          syncState.connectionStatus = .connected(serverName: server, dsmVersion: dsm)
          self.isTestingConnection = false
        }
      } catch {
        await MainActor.run {
          self.connectionTestSuccess = false
          self.connectionTestMessage = error.localizedDescription
          syncState.connectionStatus = .failed(message: error.localizedDescription)
          self.isTestingConnection = false
        }
      }
    }
  }

  public func filteredAlbums(all: [AlbumInfo]) -> [AlbumInfo] {
    if albumSearchQuery.isEmpty {
      return all
    } else {
      return all.filter { $0.title.localizedCaseInsensitiveContains(albumSearchQuery) }
    }
  }

  public func filteredLogs(all: [LogEntry]) -> [LogEntry] {
    return all.filter { entry in
      let matchesLevel = (selectedLogLevel == nil || entry.level == selectedLogLevel)
      let matchesText =
        logSearchText.isEmpty || entry.message.localizedCaseInsensitiveContains(logSearchText)
        || (entry.details?.localizedCaseInsensitiveContains(logSearchText) ?? false)
      return matchesLevel && matchesText
    }
  }

  public func copyLogs() {
    AppLogger.shared.copyAllToClipboard()
    showCopiedAlert = true
    Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      await MainActor.run {
        self.showCopiedAlert = false
      }
    }
  }

  public func setLaunchAtLogin(enabled: Bool) {
    if #available(macOS 13.0, *) {
      do {
        if enabled {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
        SyncConfig.shared.launchAtLogin = SMAppService.mainApp.status == .enabled
      } catch {
        AppLogger.error("Не удалось изменить автозапуск", details: error.localizedDescription)
      }
    }
  }
}

/// Окно Настроек приложения SynologyPhotoSync (5 вкладок)
public struct SettingsView: View {
  @ObservedObject private var config = SyncConfig.shared
  @ObservedObject private var monitor = PhotoLibraryMonitor.shared
  @ObservedObject private var syncState = SyncState.shared
  @ObservedObject private var logger = AppLogger.shared
  @StateObject private var vm = SettingsViewModel()

  public init() {}

  public var body: some View {
    TabView {
      serverTab
        .tabItem {
          Label("Сервер Synology", systemImage: "server.rack")
        }

      libraryTab
        .disabled(syncState.isSyncing || vm.isTestingConnection)
        .tabItem {
          Label("Медиатека и Качество", systemImage: "photo.on.rectangle.angled")
        }

      albumsTab
        .disabled(syncState.isSyncing || vm.isTestingConnection)
        .tabItem {
          Label("Альбомы", systemImage: "rectangle.stack")
        }

      systemTab
        .tabItem {
          Label("Система", systemImage: "gearshape")
        }

      logsTab
        .tabItem {
          Label("Логи", systemImage: "doc.text")
        }
    }
    .frame(width: 590, height: 570)
    .padding(16)
    .liquidGlassBackground(material: .underWindowBackground)
    .onAppear {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
      monitor.checkAuthorization()
      monitor.loadAvailableAlbums()
    }
    .onDisappear {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  private func reloadCredentials() {
    vm.passwordInput = KeychainHelper.shared.getPassword() ?? ""
    vm.otpInput = ""
    vm.connectionTestMessage = nil
    syncState.connectionStatus = .disconnected
  }

  // MARK: - Вкладка 1: Сервер Synology

  private var serverTab: some View {
    Form {
      Section(header: Text("Параметры подключения к DSM").font(.headline)) {
        TextField(
          "URL адрес сервера:", text: $config.serverURL,
          prompt: Text("https://nas.example.com или https://192.168.1.100:5001")
        )
        .textFieldStyle(.roundedBorder)

        TextField("Имя пользователя (Логин):", text: $config.username)
          .textFieldStyle(.roundedBorder)

        SecureField("Пароль:", text: $vm.passwordInput)
          .textFieldStyle(.roundedBorder)

        TextField(
          "2FA OTP-код (если включена двухфакторная защита):", text: $vm.otpInput,
          prompt: Text("6-значный код из Google Authenticator")
        )
        .textFieldStyle(.roundedBorder)

        Toggle("Разрешить недоверенный сертификат NAS", isOn: $config.allowInsecureSSL)
          .font(.system(size: 12))
        if config.allowInsecureSSL {
          Text("Проверка подлинности сервера отключена. Используйте только в доверенной сети.")
            .font(.caption).foregroundColor(.orange)
        }
      }
      .disabled(syncState.isSyncing || vm.isTestingConnection)
      .onChange(of: config.serverURL) { _ in reloadCredentials() }
      .onChange(of: config.username) { _ in reloadCredentials() }

      Section {
        HStack(spacing: 12) {
          Button(action: {
            vm.testConnection(config: config, syncState: syncState)
          }) {
            HStack(spacing: 6) {
              if vm.isTestingConnection {
                ProgressView()
                  .controlSize(.small)
              } else {
                Image(systemName: "network")
              }
              Text("Проверить соединение")
            }
          }
          .disabled(
            syncState.isSyncing || vm.isTestingConnection || config.serverURL.isEmpty
              || config.username.isEmpty || vm.passwordInput.isEmpty)

          if let message = vm.connectionTestMessage {
            HStack(spacing: 4) {
              Image(
                systemName: vm.connectionTestSuccess
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
              )
              .foregroundColor(vm.connectionTestSuccess ? .green : .red)
              Text(message)
                .font(.system(size: 12))
                .foregroundColor(vm.connectionTestSuccess ? .green : .red)
                .lineLimit(2)
            }
          }
        }
        .padding(.vertical, 4)
      }

      Section(header: Text("Управление синхронизацией").font(.headline)) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 12) {
            Button(action: {
              if syncState.isSyncing {
                monitor.cancelSync()
              } else {
                monitor.startSync()
              }
            }) {
              HStack(spacing: 6) {
                Image(
                  systemName: syncState.isSyncing
                    ? "xmark.circle.fill" : "arrow.triangle.2.circlepath")
                Text(syncState.isSyncing ? "Остановить синхронизацию" : "Запустить синхронизацию")
              }
            }
            .buttonStyle(.borderedProminent)
            .tint(syncState.isSyncing ? .red : .accentColor)
            .disabled(config.serverURL.isEmpty || config.username.isEmpty)

            if syncState.isSyncing {
              Button(action: {
                if syncState.isPaused {
                  monitor.resumeSync()
                } else {
                  monitor.pauseSync()
                }
              }) {
                HStack(spacing: 4) {
                  Image(systemName: syncState.isPaused ? "play.fill" : "pause.fill")
                  Text(syncState.isPaused ? "Продолжить" : "Пауза")
                }
              }
              .buttonStyle(.bordered)
            }

            Spacer()

            StatusBadgeView(stage: syncState.currentStage)
          }

          if syncState.isSyncing {
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(
                  syncState.currentFileName.isEmpty ? "Подготовка..." : syncState.currentFileName
                )
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

                Spacer()

                Text("\(syncState.syncedCount) из \(syncState.totalToSyncCount)")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundColor(.secondary)
              }

              Text(
                "Уже на NAS: \(syncState.alreadyPresentCount) из \(syncState.totalSelectedCount) · \(syncState.isReconciling ? "Идёт сверка" : "К загрузке: " + String(syncState.totalToSyncCount))"
              )
              .font(.caption).foregroundColor(.secondary)
              ProgressView(value: syncState.overallProgressFraction, total: 1.0)
                .progressViewStyle(.linear)
            }
            .padding(8)
            .liquidGlassCard(cornerRadius: 10)
          } else if monitor.isScanning {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Сканирование медиатеки Apple Photos...")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
          } else {
            Text(
              "Синхронизировано файлов: \(SyncDatabase.shared.syncedCount). При нажатии кнопки начнётся выгрузка новых и ещё не переданных файлов."
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
          }
        }
        .padding(.vertical, 4)
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Вкладка 2: Медиатека и Качество

  private var libraryTab: some View {
    Form {
      Section(header: Text("Источник (Apple Photos)").font(.headline)) {
        Picker("Синхронизировать медиатеку:", selection: $config.libraryScope) {
          ForEach(LibraryScope.allCases) { scope in
            Text(scope.localizedTitle).tag(scope)
          }
        }
        .pickerStyle(.segmented)

        Toggle("Синхронизировать всю историю снимков", isOn: $config.syncAllHistory)

        if !config.syncAllHistory {
          DatePicker(
            "Синхронизировать только начиная с даты:",
            selection: $config.syncStartDate,
            displayedComponents: [.date]
          )
        }
      }

      Section(header: Text("Назначение в Synology Photos").font(.headline)) {
        Picker("Целевое пространство:", selection: $config.targetSpace) {
          ForEach(TargetSpace.allCases) { space in
            Text(space.localizedTitle).tag(space)
          }
        }
        .pickerStyle(.radioGroup)
      }

      Section(header: Text("Форматы и копии").font(.headline)) {
        Toggle("Сохранять Live Photos (фото + видео)", isOn: $config.saveLivePhotos)
        Toggle("Сохранять отредактированные копии снимков", isOn: $config.saveEditedCopies)
      }

      Section(header: Text("Контроль целостности и качество").font(.headline)) {
        HStack {
          Image(systemName: "checkmark.seal.fill")
            .foregroundColor(.green)
          VStack(alignment: .leading, spacing: 2) {
            Text("100% Оригинальное качество без пересжатия")
              .font(.system(size: 12, weight: .semibold))
            Text(
              "Файлы извлекаются побитово через PhotoKit с сохранением всех EXIF, GPS и HDR метаданных."
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
          }
        }
        .padding(.vertical, 2)
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Вкладка 3: Альбомы

  private var albumsTab: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Синхронизация Альбомов")
        .font(.headline)
        .padding(.horizontal, 4)

      HStack {
        Toggle("Синхронизировать Личные альбомы", isOn: $config.syncPersonalAlbums)
        Spacer()
        Toggle("Синхронизировать Общие альбомы iCloud", isOn: $config.syncSharedAlbums)
      }
      .padding(.horizontal, 4)

      HStack {
        Image(systemName: "magnifyingglass")
          .foregroundColor(.secondary)
        TextField("Поиск по альбомам...", text: $vm.albumSearchQuery)
          .textFieldStyle(.roundedBorder)
      }
      .padding(.horizontal, 4)

      let displayedAlbums = vm.filteredAlbums(all: monitor.availableAlbums)
      List {
        ForEach(displayedAlbums) { album in
          HStack {
            Toggle(
              isOn: Binding(
                get: {
                  config.selectedAlbumIdentifiers.isEmpty
                    || config.selectedAlbumIdentifiers.contains(album.id)
                },
                set: { isSelected in
                  if isSelected {
                    config.selectedAlbumIdentifiers.insert(album.id)
                  } else {
                    config.selectedAlbumIdentifiers.remove(album.id)
                  }
                }
              )
            ) {
              HStack(spacing: 8) {
                Image(systemName: album.isCloudShared ? "person.2.fill" : "rectangle.stack.fill")
                  .foregroundColor(album.isCloudShared ? .blue : .secondary)
                Text(album.title)
                  .font(.system(size: 13, weight: .medium))
              }
            }

            Spacer()

            Text("\(album.assetCount) фото/видео")
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Capsule().fill(Color.primary.opacity(0.06)))
          }
          .padding(.vertical, 2)
        }
      }
      .listStyle(.bordered(alternatesRowBackgrounds: true))
    }
    .padding(6)
  }

  // MARK: - Вкладка 4: Система

  private var systemTab: some View {
    Form {
      Section(header: Text("Автозапуск").font(.headline)) {
        Toggle(
          "Запускать при входе в систему",
          isOn: Binding(
            get: { config.launchAtLogin },
            set: { newValue in
              vm.setLaunchAtLogin(enabled: newValue)
            }
          ))
      }

      Section(header: Text("База данных и кэш").font(.headline)) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Сброс локального маппинга синхронизации")
              .font(.system(size: 13, weight: .medium))
            Text("Очистит историю и маппинг идентификаторов. Файлы на Synology затронуты не будут.")
              .font(.system(size: 11))
              .foregroundColor(.secondary)
          }

          Spacer()

          Button("Сбросить кэш...") {
            vm.showResetAlert = true
          }
          .buttonStyle(.bordered)
          .tint(.red)
          .disabled(syncState.isSyncing)
        }
      }

      Section(header: Text("О медиатеке Apple Photos").font(.headline)) {
        LabeledContent("Статус доступа к медиатеке:") {
          Text(monitor.authorizationStatus == .authorized ? "Разрешён" : "Ограничен/Не разрешён")
            .foregroundColor(monitor.authorizationStatus == .authorized ? .green : .orange)
        }
        LabeledContent("Синхронизировано файлов:") {
          Text("\(syncState.syncedCount)")
            .bold()
        }
        LabeledContent("Синхронизировано альбомов:") {
          Text("\(syncState.syncedAlbumsCount)")
            .bold()
        }
      }
    }
    .formStyle(.grouped)
    .alert("Сбросить кэш синхронизации?", isPresented: $vm.showResetAlert) {
      Button("Отмена", role: .cancel) {}
      Button("Сбросить", role: .destructive) {
        SyncDatabase.shared.clearAllCache()
        syncState.reloadFromDatabase()
      }
    } message: {
      Text(
        "Приложение пересканирует медиатеку. Возможна повторная выгрузка файлов. Файлы на NAS не удаляются."
      )
    }
  }

  // MARK: - Вкладка 5: Логи (Листаемые, копируемые, подробные)

  private var logsTab: some View {
    VStack(spacing: 10) {
      // Верхняя панель: поиск, фильтр по уровню и кнопки копирования
      HStack(spacing: 8) {
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
            .foregroundColor(.secondary)
          TextField("Поиск по логам...", text: $vm.logSearchText)
            .textFieldStyle(.plain)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

        Picker("Уровень:", selection: $vm.selectedLogLevel) {
          Text("Все").tag(LogEntry.LogLevel?.none)
          Text("ℹ️ Инфо").tag(LogEntry.LogLevel?.some(.info))
          Text("✅ Успех").tag(LogEntry.LogLevel?.some(.success))
          Text("⚠️ Предупр.").tag(LogEntry.LogLevel?.some(.warning))
          Text("❌ Ошибки").tag(LogEntry.LogLevel?.some(.error))
        }
        .labelsHidden()
        .frame(width: 125)
        .help("Фильтр по уровню сообщений")

        Button(action: {
          vm.copyLogs()
        }) {
          HStack(spacing: 4) {
            Image(systemName: vm.showCopiedAlert ? "checkmark" : "doc.on.doc")
            Text(vm.showCopiedAlert ? "Скопировано!" : "Скопировать всё")
          }
        }
        .buttonStyle(.bordered)
        .tint(vm.showCopiedAlert ? .green : .accentColor)

        Button(action: {
          AppLogger.shared.clear()
        }) {
          Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .help("Очистить журнал логов")
      }
      .padding(.horizontal, 4)

      // Скроллируемый терминал подробных логов
      let entries = vm.filteredLogs(all: logger.entries)
      if entries.isEmpty {
        VStack(spacing: 8) {
          Spacer()
          Image(systemName: "doc.text.magnifyingglass")
            .font(.system(size: 32))
            .foregroundColor(.secondary)
          Text("Логи отсутствуют или не соответствуют фильтру")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
          RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
      } else {
        ScrollViewReader { _ in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
              ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 6) {
                  Text("[\(entry.timestampString)]")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                  Text(entry.level.emoji)
                    .font(.system(size: 11))

                  VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                      .font(.system(size: 11, weight: .medium, design: .monospaced))
                      .foregroundColor(colorForLevel(entry.level))

                    if let details = entry.details, !details.isEmpty {
                      Text(details)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                    }
                  }

                  Spacer()

                  Button(action: {
                    AppLogger.shared.copyEntryToClipboard(entry)
                  }) {
                    Image(systemName: "doc.on.doc")
                      .font(.system(size: 9))
                  }
                  .buttonStyle(.borderless)
                  .help("Скопировать эту строку")
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(
                  RoundedRectangle(cornerRadius: 4)
                    .fill(entry.level == .error ? Color.red.opacity(0.08) : Color.clear)
                )
                .id(entry.id)
              }
            }
            .padding(8)
          }
          .textSelection(.enabled)
          .liquidGlassCard(cornerRadius: 10, borderOpacity: 0.25)
        }
      }

      // Нижний блок: Ошибочные файлы выгрузки
      let errors = syncState.failedItems
      if !errors.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.red)
            Text("Ошибочных файлов к повторной выгрузке: \(errors.count)")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.red)

            Spacer()

            Button("Повторить ошибочные") {
              monitor.retryFailedItems()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }

          List(errors) { error in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(error.filename)
                  .font(.system(size: 11, weight: .medium))
                Text(error.errorMessage)
                  .font(.system(size: 10))
                  .foregroundColor(.secondary)
              }
              Spacer()
              Button(action: {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("\(error.filename): \(error.errorMessage)", forType: .string)
              }) {
                Image(systemName: "doc.on.doc")
                  .font(.system(size: 10))
              }
              .buttonStyle(.borderless)
              .help("Скопировать ошибку")
            }
            .padding(.vertical, 2)
          }
          .frame(height: 90)
        }
        .padding(8)
        .liquidGlassCard(cornerRadius: 10, borderOpacity: 0.3)
      }
    }
    .padding(6)
  }

  private func colorForLevel(_ level: LogEntry.LogLevel) -> Color {
    switch level {
    case .info: return .primary
    case .success: return .green
    case .warning: return .orange
    case .error: return .red
    }
  }
}
