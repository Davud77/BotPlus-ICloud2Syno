import SwiftUI

/// Всплывающее окно приложения в Menu Bar (~360pt)
public struct MenuBarPopupView: View {
  @ObservedObject private var syncState = SyncState.shared
  @ObservedObject private var monitor = PhotoLibraryMonitor.shared
  @ObservedObject private var config = SyncConfig.shared

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      headerView
      Divider()

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 14) {
          sessionProgressBlock
          currentFileBlock
          recentActivityBlock
        }
        .padding(14)
      }

      Divider()
      footerView
    }
    .frame(width: 390, height: 560)
    .background(
      VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
        .ignoresSafeArea()
    )
    .onAppear {
      syncState.reloadFromDatabase()
    }
  }

  // MARK: - 1. Шапка (Header)

  private var headerView: some View {
    HStack(spacing: 10) {
      Image(systemName: "photo.stack.fill")
        .font(.system(size: 16, weight: .bold))
        .foregroundColor(.accentColor)

      VStack(alignment: .leading, spacing: 2) {
        Text("Synology Photos Sync")
          .font(.system(size: 13, weight: .semibold))

        HStack(spacing: 6) {
          ConnectionIndicatorView(status: syncState.connectionStatus)

          if !config.username.isEmpty {
            Text("•  \(config.username)")
              .font(.system(size: 11))
              .foregroundColor(.secondary)
          }
        }
      }

      Spacer()

      if syncState.isSyncing {
        Button(action: {
          if syncState.isPaused {
            monitor.resumeSync()
          } else {
            monitor.pauseSync()
          }
        }) {
          Image(systemName: syncState.isPaused ? "play.circle.fill" : "pause.circle.fill")
            .font(.system(size: 18))
            .foregroundColor(syncState.isPaused ? .green : .orange)
        }
        .buttonStyle(.plain)
        .help(syncState.isPaused ? "Возобновить синхронизацию" : "Поставить на паузу")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  // MARK: - 2. Блок общего прогресса сессии

  private var sessionProgressBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("СЕССИЯ СИНХРОНИЗАЦИИ")
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(.secondary)

        Spacer()

        StatusBadgeView(stage: syncState.currentStage)
      }

      if syncState.isSyncing || syncState.totalSelectedCount > 0 {
        VStack(alignment: .leading, spacing: 4) {
          Text("Уже на NAS: \(syncState.alreadyPresentCount) из \(syncState.totalSelectedCount)")
            .font(.system(size: 13, weight: .semibold))
          if syncState.isReconciling {
            Text(
              "Просмотрено на NAS: \(syncState.nasScannedFileCount) файлов, \(syncState.nasScannedFolderCount) папок"
            )
            .font(.caption).foregroundColor(.secondary)
            Text(
              "Сопоставлено снимков: \(syncState.comparedAssetCount) из \(syncState.totalSelectedCount)"
            )
            .font(.caption).foregroundColor(.secondary)
          } else {
            Text(
              "Нужно догрузить: \(syncState.totalToSyncCount) · Объектов в каталоге NAS: \(syncState.nasScannedFileCount)"
            )
            .font(.caption).foregroundColor(.secondary)
          }
        }
      }

      if syncState.totalToSyncCount > 0 && !syncState.isReconciling {
        // Крупная сводка
        HStack(alignment: .firstTextBaseline) {
          Text("Догружено:")
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(.primary)

          Text("\(syncState.syncedCount) из \(syncState.totalToSyncCount)")
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.primary)

          Spacer()

          Text("(Осталось: \(syncState.remainingCount))")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
        }

        // Общий прогресс-бар
        VStack(spacing: 4) {
          ProgressView(value: syncState.overallProgressFraction, total: 1.0)
            .progressViewStyle(.linear)
            .tint(.accentColor)

          HStack {
            Text("\(Int(syncState.overallProgressFraction * 100))% обработано")
              .font(.system(size: 10, weight: .regular))
              .foregroundColor(.secondary)

            Spacer()

            if syncState.totalAlbumsCount > 0 {
              Text("Альбомы: \(syncState.processedAlbumsCount) из \(syncState.totalAlbumsCount)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.purple)
            }
          }
        }
      } else {
        HStack {
          Image(
            systemName: syncState.currentStage == .completed
              ? "checkmark.circle.fill" : "info.circle"
          )
          .foregroundColor(syncState.currentStage == .completed ? .green : .secondary)
          Text(
            syncState.currentStage.localizedDescription
          )
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
      }
    }
    .padding(12)
    .liquidGlassCard(cornerRadius: 12)
  }

  // MARK: - 3. Блок текущего файла (Детальный двухэтапный прогресс)

  private var currentFileBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("ТЕКУЩАЯ ЗАДАЧА")
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(.secondary)

        Spacer()

        if !syncState.uploadSpeedText.isEmpty {
          Text(syncState.uploadSpeedText)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.blue.opacity(0.1)))
        }
      }

      if !syncState.currentFileName.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text(syncState.currentFileName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        VStack(spacing: 8) {
          // Прогресс 1: Скачивание из iCloud
          StageProgressBar(
            title: "Скачивание из iCloud",
            progress: syncState.iCloudDownloadProgress,
            detailText: syncState.iCloudDownloadProgress >= 1.0 ? "Готово" : "",
            tintColor: .cyan
          )

          // Прогресс 2: Выгрузка на Synology
          StageProgressBar(
            title: "Выгрузка на Synology NAS",
            progress: syncState.synologyUploadProgress,
            detailText: syncState.uploadProgressBytesText,
            tintColor: .blue
          )
        }
      } else {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 12))
            .foregroundColor(.secondary)

          Text(syncState.isSyncing ? "Подготовка следующего файла..." : "Нет активной передачи")
            .font(.system(size: 11, weight: .regular))
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
      }
    }
    .padding(12)
    .liquidGlassCard(cornerRadius: 12)
  }

  // MARK: - 4. Список последних событий (Activity Feed)

  private var recentActivityBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("ПОСЛЕДНИЕ СОБЫТИЯ")
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(.secondary)

        Spacer()

        Text("Всего: \(SyncDatabase.shared.syncedCount)")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.secondary)
      }

      let items = Array(syncState.recentHistory.prefix(5))
      if items.isEmpty {
        Text("История синхронизации пуста")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .padding(.vertical, 6)
      } else {
        VStack(spacing: 6) {
          ForEach(items) { item in
            HStack(spacing: 8) {
              Image(systemName: item.type.sfSymbol)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
                .frame(width: 16)

              Text(item.filename)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

              Spacer()

              Text(formatTime(item.timestamp))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
          }
        }
      }
    }
    .padding(12)
    .liquidGlassCard(cornerRadius: 12)
  }

  // MARK: - 5. Нижняя панель кнопок (Footer)

  private var footerView: some View {
    HStack(spacing: 8) {
      Button(action: {
        if syncState.isSyncing {
          monitor.cancelSync()
        } else {
          monitor.startSync()
        }
      }) {
        HStack(spacing: 4) {
          Image(systemName: syncState.isSyncing ? "xmark.circle.fill" : "arrow.clockwise")
          Text(
            syncState.currentStage == .cancelling
              ? "Останавливается…"
              : (syncState.isSyncing ? "Остановить" : "Синхронизировать сейчас"))
        }
        .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.borderedProminent)
      .tint(syncState.isSyncing ? .red : .accentColor)
      .disabled(syncState.currentStage == .cancelling)

      Spacer()

      Button(action: {
        SettingsWindowManager.shared.showSettings()
      }) {
        Image(systemName: "gearshape")
          .font(.system(size: 12))
      }
      .buttonStyle(.bordered)
      .help("Настройки...")

      Button(action: {
        NSApplication.shared.terminate(nil)
      }) {
        Image(systemName: "power")
          .font(.system(size: 12))
      }
      .buttonStyle(.bordered)
      .help("Выход из SynologyPhotoSync")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - Вспомогательные методы

  private func formatTime(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute().second())
  }
}
