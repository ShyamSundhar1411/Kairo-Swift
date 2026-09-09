import SwiftUI
import KairoKit

/// The app shell. One canvas behind everything, four resident screens, and a
/// floating bar instead of the system tab bar — the screens keep their state
/// while switching, which matters because a half-logged meal must survive a
/// glance at Today.
enum KairoTab: String, CaseIterable, Identifiable {
    case today, meals, sleep, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:  "Today"
        case .meals:  "Meals"
        case .sleep:  "Sleep"
        case .memory: "Memory"
        }
    }

    var icon: String {
        switch self {
        case .today:  "sun.max"
        case .meals:  "fork.knife"
        case .sleep:  "moon.zzz"
        case .memory: "book.closed"
        }
    }

    var selectedIcon: String {
        switch self {
        case .today:  "sun.max.fill"
        case .meals:  "fork.knife"
        case .sleep:  "moon.zzz.fill"
        case .memory: "book.closed.fill"
        }
    }

    var tint: Color {
        switch self {
        case .today:  Kairo.amber
        case .meals:  Kairo.leaf
        case .sleep:  Kairo.violet
        case .memory: Kairo.teal
        }
    }
}

struct RootView: View {
    @State private var tab: KairoTab = .today

    var body: some View {
        ZStack(alignment: .bottom) {
            KairoCanvas()

            ZStack {
                page(.today)  { TodayView() }
                page(.meals)  { MealCaptureView() }
                page(.sleep)  { SleepView() }
                page(.memory) { MemoryBookView() }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 62) }

            KairoTabBar(selection: $tab)
                .padding(.horizontal, 20)
        }
        .tint(tab.tint)
    }

    @ViewBuilder
    private func page<V: View>(_ t: KairoTab, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .opacity(tab == t ? 1 : 0)
            .allowsHitTesting(tab == t)
            .accessibilityHidden(tab != t)
            .zIndex(tab == t ? 1 : 0)
    }
}

struct KairoTabBar: View {
    @Binding var selection: KairoTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(KairoTab.allCases) { t in
                Button {
                    guard t != selection else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { selection = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: selection == t ? t.selectedIcon : t.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .symbolEffect(.bounce, value: selection == t)
                        Text(t.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(selection == t ? t.tint : Kairo.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if selection == t {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(t.tint.opacity(0.16))
                                .matchedGeometryEffect(id: "selectedTab", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(selection == t ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(5)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay { Capsule(style: .continuous).fill(Kairo.cardTint.opacity(0.45)) }
                .overlay { Capsule(style: .continuous).strokeBorder(Kairo.hairline.opacity(0.12), lineWidth: 1) }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        }
    }
}
