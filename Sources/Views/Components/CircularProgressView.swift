import SwiftUI

/// Стильный горизонтальный прогресс-бар с анимацией и метками
public struct StageProgressBar: View {
  let title: String
  let progress: Double
  let detailText: String
  let tintColor: Color

  public init(
    title: String,
    progress: Double,
    detailText: String = "",
    tintColor: Color = .blue
  ) {
    self.title = title
    self.progress = min(1.0, max(0.0, progress))
    self.detailText = detailText
    self.tintColor = tintColor
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.primary)

        Spacer()

        if !detailText.isEmpty {
          Text(detailText)
            .font(.system(size: 10, weight: .regular))
            .foregroundColor(.secondary)
        }

        Text("\(Int(progress * 100))%")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(tintColor)
          .frame(width: 38, alignment: .trailing)
      }

      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.08))
            .frame(height: 6)

          RoundedRectangle(cornerRadius: 3)
            .fill(tintColor)
            .frame(width: geometry.size.width * CGFloat(progress), height: 6)
            .animation(.linear(duration: 0.2), value: progress)
        }
      }
      .frame(height: 6)
    }
  }
}
