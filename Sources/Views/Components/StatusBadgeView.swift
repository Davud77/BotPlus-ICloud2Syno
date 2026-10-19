import SwiftUI

/// Бейдж отображения текущей стадии синхронизации
public struct StatusBadgeView: View {
  let stage: SyncStage

  public init(stage: SyncStage) {
    self.stage = stage
  }

  public var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(indicatorColor)
        .frame(width: 7, height: 7)
        .shadow(color: indicatorColor.opacity(0.8), radius: 4, x: 0, y: 0)

      Text(stage.localizedDescription)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.primary.opacity(0.85))
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 4)
    .background(
      Capsule()
        .fill(indicatorColor.opacity(0.14))
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(
          Capsule()
            .stroke(
              LinearGradient(
                colors: [
                  indicatorColor.opacity(0.5),
                  Color.white.opacity(0.2),
                  indicatorColor.opacity(0.2),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: 0.8
            )
        )
        .shadow(color: indicatorColor.opacity(0.15), radius: 4, x: 0, y: 1)
    )
  }

  private var indicatorColor: Color {
    switch stage {
    case .idle:
      return .gray
    case .scanning, .checkingSynology:
      return .orange
    case .downloadingFromICloud:
      return .cyan
    case .uploadingToSynology:
      return .blue
    case .syncingAlbums:
      return .purple
    case .paused, .attention:
      return .yellow
    case .completed:
      return .green
    case .cancelling, .cancelled:
      return .gray
    case .error:
      return .red
    }
  }
}

/// Индикатор подключения к Synology NAS
public struct ConnectionIndicatorView: View {
  let status: ConnectionStatus

  public init(status: ConnectionStatus) {
    self.status = status
  }

  public var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)
        .shadow(color: statusColor.opacity(0.8), radius: 4, x: 0, y: 0)

      Text(displayText)
        .font(.system(size: 11, weight: .regular))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  private var statusColor: Color {
    switch status {
    case .disconnected:
      return .gray
    case .connecting:
      return .orange
    case .connected:
      return .green
    case .failed:
      return .red
    }
  }

  private var displayText: String {
    switch status {
    case .disconnected:
      return "Отключено"
    case .connecting:
      return "Подключение..."
    case .connected(let server, _):
      return server
    case .failed:
      return "Ошибка связи"
    }
  }
}
