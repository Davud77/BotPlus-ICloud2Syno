import AppKit
import SwiftUI

/// Нативная подложка с эффектом размытия жидкого стекла (Liquid Frosted Glass)
public struct VisualEffectBackground: NSViewRepresentable {
  public var material: NSVisualEffectView.Material
  public var blendingMode: NSVisualEffectView.BlendingMode
  public var state: NSVisualEffectView.State

  public init(
    material: NSVisualEffectView.Material = .hudWindow,
    blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
    state: NSVisualEffectView.State = .active
  ) {
    self.material = material
    self.blendingMode = blendingMode
    self.state = state
  }

  public func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = state
    view.isEmphasized = true
    return view
  }

  public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    nsView.material = material
    nsView.blendingMode = blendingMode
    nsView.state = state
  }
}

/// Модификатор стеклянной карточки с бликом и размытием фона (Liquid Glass Card)
public struct LiquidGlassCardModifier: ViewModifier {
  public var cornerRadius: CGFloat
  public var borderOpacity: Double

  public init(cornerRadius: CGFloat = 12, borderOpacity: Double = 0.3) {
    self.cornerRadius = cornerRadius
    self.borderOpacity = borderOpacity
  }

  public func body(content: Content) -> some View {
    content
      .background(
        ZStack {
          // 1. Ультратонкое стекло с размытием рабочего стола под окном
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)

          // 2. Полупрозрачная тонировка с легким свечением
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        }
      )
      .overlay(
        // 3. Стеклянная грань с диагональным световым бликом (Specular Glass Sheen)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(
            LinearGradient(
              stops: [
                .init(color: Color.white.opacity(borderOpacity), location: 0.0),
                .init(color: Color.white.opacity(borderOpacity * 0.3), location: 0.4),
                .init(color: Color.clear, location: 0.7),
                .init(color: Color.white.opacity(borderOpacity * 0.15), location: 1.0),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
      )
      .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 3)
  }
}

extension View {
  /// Применяет стиль «Жидкое стекло» (Liquid Glass) к элементу интерфейса
  public func liquidGlassCard(cornerRadius: CGFloat = 12, borderOpacity: Double = 0.3) -> some View
  {
    self.modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, borderOpacity: borderOpacity))
  }

  /// Добавляет фоновое размытие стекла под окном
  public func liquidGlassBackground(material: NSVisualEffectView.Material = .hudWindow) -> some View
  {
    self.background(
      VisualEffectBackground(material: material, blendingMode: .behindWindow)
        .ignoresSafeArea()
    )
  }
}
