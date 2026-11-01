import SwiftUI
import KairoKit

/// Member C - OF3. The half of CF7 the user can edit, plus the app reporting on
/// its own restraint. No health app publishes its notification policy as a
/// negotiable artefact, and none reports on staying quiet.
///
/// The ceiling control is the reason this screen exists rather than a settings
/// row: committing a new value rebuilds `NudgeSchedule` and re-runs arbitration
/// on the spot, because OF3 makes the contract the user's to change and CF7 has
/// to answer to it immediately. It re-arbitrates on release, not on every
/// intermediate value, so a scrub across the dots is one decision and not
/// thirteen.
struct AttentionReceiptView: View {
    @Environment(AppModel.self) private var model

    /// Held locally while the user is still choosing; `commitCeiling()` is what
    /// makes it real.
    @State private var ceiling: Int = 6
    @State private var quietStart = 21

    private let maxCeiling = 12
    /// Fixed order, so the rows do not reshuffle as values change. Every class
    /// the vocabulary declares, because a class missing from this list is one
    /// the user cannot turn off.
    private var priorityOrder: [String] { NudgeClassVocabulary.known }

    var body: some View {
        ScrollView {
            VStack(spacing: Kairo.Space.stack) {
                VStack(spacing: 8) {
                    SectionHeader(title: "Interruptions a day", icon: "slider.horizontal.3",
                                  tint: Kairo.amber)
                    ceilingCard
                }

                VStack(spacing: 8) {
                    SectionHeader(title: "Quiet hours", icon: "moon.fill", tint: Kairo.violet)
                    quietCard
                }

                VStack(spacing: 8) {
                    SectionHeader(title: "Worth an interruption", icon: "slider.vertical.3",
                                  tint: Kairo.teal)
                    priorityCard
                }

                TrustNote(text: "Setting a priority to zero means Kairo will never spend an "
                          + "interruption on it, even when it thinks it should: that class "
                          + "stops bidding on this phone, and the agents are sent the same "
                          + "weights with every pass.")
            }
            .padding(.horizontal, Kairo.Space.stack)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .background(KairoCanvas())
        .navigationTitle("Your attention contract")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            // SCRUM-21. Both controls read the stored profile now. They used to
            // read `schedule` and a `@State` default, so the ceiling reset to 6
            // and the quiet window to 21:00 on every launch - a grant the user
            // made that the app forgot overnight.
            ceiling = model.userProfile.dailyInterruptionCeiling
            quietStart = model.userProfile.quietHoursStart
        }
    }

    // MARK: - Ceiling
    //
    // A stepper hides the shape of the decision. Thirteen dots show it: how many
    // interruptions the day is allowed to contain, how many are already gone, and
    // what is left. Warm is spent, cool is still available - the same language as
    // the dial on Today.

    private var ceilingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                stepButton("minus", enabled: ceiling > 0) { nudgeCeiling(by: -1) }

                VStack(spacing: -2) {
                    Text("\(ceiling)")
                        .font(.kairoDisplay)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Kairo.ink)
                    Text("A DAY, AT MOST")
                        .font(.kairoLabel).tracking(1.2)
                        .foregroundStyle(Kairo.inkFaint)
                }
                .frame(maxWidth: .infinity)

                stepButton("plus", enabled: ceiling < maxCeiling) { nudgeCeiling(by: 1) }
            }

            dotRow

            HStack(spacing: 12) {
                legend(Kairo.amber, "\(model.schedule.spent) spent")
                legend(Kairo.teal, "\(max(0, ceiling - model.schedule.spent)) still available")
                Spacer(minLength: 0)
            }

            Text(ceilingCaption)
                .font(.caption)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard()
        .sensoryFeedback(.selection, trigger: ceiling)
    }

    private var ceilingCaption: String {
        if ceiling == 0 {
            return "At zero, Kairo may not interrupt you at all today. It will still record "
                 + "what it would have said, on Today."
        }
        return "Kairo may interrupt you at most \(ceiling) times today, and it usually "
             + "uses fewer."
    }

    private var dotRow: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(maxCeiling + 1)
            HStack(spacing: 0) {
                ForEach(0...maxCeiling, id: \.self) { i in
                    dot(i).frame(width: slot, height: 30)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // Scrubbing only moves the local value; the commit happens once,
                // on release.
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let i = Int((v.location.x / max(slot, 1)).rounded(.down))
                        let clamped = min(max(i, 0), maxCeiling)
                        if clamped != ceiling {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                ceiling = clamped
                            }
                        }
                    }
                    .onEnded { _ in commitCeiling() }
            )
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("Interruptions allowed per day")
        .accessibilityValue("\(ceiling)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudgeCeiling(by: 1)
            case .decrement: nudgeCeiling(by: -1)
            @unknown default: break
            }
        }
    }

    private func dot(_ i: Int) -> some View {
        let allowed = i > 0 && i <= ceiling
        let isSpent = allowed && i <= model.schedule.spent
        return Circle()
            .fill(dotStyle(spent: isSpent, allowed: allowed))
            .frame(width: allowed ? 13 : 8, height: allowed ? 13 : 8)
            .shadow(color: isSpent ? Kairo.amber.opacity(0.45) : .clear, radius: 5)
    }

    private func dotStyle(spent: Bool, allowed: Bool) -> AnyShapeStyle {
        if spent { return AnyShapeStyle(Kairo.warm) }
        if allowed { return AnyShapeStyle(Kairo.teal.opacity(0.55)) }
        return AnyShapeStyle(Kairo.hairline.opacity(0.10))
    }

    private func legend(_ tint: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text).font(.kairoLabel).tracking(0.4).foregroundStyle(Kairo.inkFaint)
        }
    }

    private func stepButton(_ icon: String, enabled: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(enabled ? Kairo.amber : Kairo.inkFaint)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Kairo.amber.opacity(enabled ? 0.16 : 0.05)))
                .overlay {
                    Circle().strokeBorder(Kairo.amber.opacity(enabled ? 0.28 : 0.08),
                                          lineWidth: 0.5)
                }
        }
        .buttonStyle(.kairoPress)
        .disabled(!enabled)
        .accessibilityLabel(icon == "plus" ? "Allow one more interruption"
                                           : "Allow one fewer interruption")
    }

    private func nudgeCeiling(by delta: Int) {
        let next = min(max(ceiling + delta, 0), maxCeiling)
        guard next != ceiling else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { ceiling = next }
        commitCeiling()
    }

    /// OF3: the contract the user just changed is the one the next arbitration
    /// pass runs against, so the pass is re-run here rather than at some later
    /// convenient moment.
    private func commitCeiling() {
        guard ceiling != model.userProfile.dailyInterruptionCeiling else { return }
        let chosen = ceiling
        Task {
            // AG-1's user grant. Persisted locally first so it holds with no
            // network, then written through to the server, which is the copy
            // another device would read.
            await model.updateProfile({ $0.dailyInterruptionCeiling = chosen },
                                      patch: ["dailyInterruptionCeiling": chosen])
            await model.runArbitration()
        }
    }

    private func commitQuietHours() {
        guard quietStart != model.userProfile.quietHoursStart else { return }
        let chosen = quietStart
        Task {
            await model.updateProfile({ $0.quietHoursStart = chosen },
                                      patch: ["quietHoursStart": chosen])
            // NFR8: a window that now contains the current hour has to take
            // effect on this pass, not the next one.
            await model.runArbitration()
        }
    }

    // MARK: - Quiet hours

    private var quietCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // PillWrap, not a horizontal scroller. Six hour pills at
            // accessibility XXXL are wider than an iPhone SE, and a row that
            // scrolls sideways hides the option the user is looking for behind
            // a gesture nothing on the screen advertises.
            PillWrap(spacing: 8, lineSpacing: 8) {
                ForEach(18..<24, id: \.self) { hourPill($0) }
            }

            Text(quietCaption)
                .font(.caption)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard()
    }

    private var quietCaption: String {
        let start = String(format: "%02d:00", quietStart)
        let end = String(format: "%02d:00", model.userProfile.quietHoursEnd)
        let now = model.isQuietNow ? " It is quiet hours now." : ""
        return "Quiet from \(start) until \(end). Anything Kairo wanted to say inside "
             + "those hours is listed on Today instead, marked as quiet hours.\(now)"
    }

    private func hourPill(_ h: Int) -> some View {
        let on = h == quietStart
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { quietStart = h }
            commitQuietHours()
        } label: {
            HStack(spacing: 5) {
                if on {
                    Image(systemName: "moon.fill").font(.system(size: 9, weight: .bold))
                }
                Text(String(format: "%02d:00", h))
                    .font(.kairoHeadline)
                    .monospacedDigit()
            }
            .foregroundStyle(on ? Color.white : Kairo.inkSoft)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background {
                Capsule().fill(on ? AnyShapeStyle(Kairo.violet)
                                  : AnyShapeStyle(Kairo.hairline.opacity(0.06)))
            }
            .overlay {
                Capsule().strokeBorder(on ? Kairo.violet.opacity(0.5)
                                          : Kairo.hairline.opacity(0.12), lineWidth: 0.5)
            }
        }
        .buttonStyle(.kairoPress)
        .accessibilityLabel("Quiet from \(h) o'clock")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Priorities
    //
    // Each class is drawn in its own colour so the row reads as being about
    // hydration or sleep, not about a slider. Zero is a real position with its
    // own label, because the promise in the footer only means something if the
    // user can see when they have made it.

    private var priorityCard: some View {
        VStack(spacing: 16) {
            ForEach(priorityOrder, id: \.self) { key in
                if key != priorityOrder.first {
                    Rectangle()
                        .fill(Kairo.hairline.opacity(0.08))
                        .frame(height: 0.5)
                }
                priorityRow(key)
            }
        }
        .kairoCard()
    }

    private func priorityRow(_ key: String) -> some View {
        let tint = Kairo.colour(forNudgeClass: key)
        let value = model.priorities[key] ?? 0.6
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: Kairo.icon(forNudgeClass: key))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint.opacity(0.15))
                    }

                Text(Kairo.title(forNudgeClass: key))
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)

                Spacer(minLength: 8)

                if value <= 0 {
                    Pill(text: "never", tint: Kairo.coral)
                } else {
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.kairoHeadline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(tint)
                }
            }

            // OF3: this moves a value `runArbitration()` reads. It used to move
            // a `@State` dictionary this screen owned and nothing else ever
            // looked at, under a footnote promising that zero meant never.
            Slider(value: Binding(get: { model.priorities[key] ?? 0.6 },
                                  set: { model.setPriority($0, for: key) }),
                   in: 0...1, step: 0.05,
                   onEditingChanged: { editing in
                       // Re-arbitrate on release, for the same reason the dot
                       // row does: a scrub across the slider is one decision.
                       if !editing { Task { await model.runArbitration() } }
                   })
                .tint(tint)
                .accessibilityLabel("\(Kairo.title(forNudgeClass: key)) priority")
                .accessibilityValue(value <= 0 ? "never"
                                               : "\(Int((value * 100).rounded())) percent")
        }
    }
}
