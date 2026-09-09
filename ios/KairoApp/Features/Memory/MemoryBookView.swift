import SwiftUI
import KairoKit

/// Member D — CF10. Every remembered fact in plain language, with the controls
/// that make the memory an artefact the user owns rather than a hidden profile.
///
/// A profile you cannot read is a profile you cannot argue with, so each fact
/// carries where it came from, how sure Kairo is, and a delete that really
/// deletes. Facts Kairo is no longer sure about are drawn differently from the
/// ones it is acting on, because adjudicating them is the user's job.
struct MemoryBookView: View {
    @Environment(AppModel.self) private var model
    @State private var openRecordID: String?

    var body: some View {
        NavigationStack {
            List {
                header
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    .kairoListRow()

                SectionHeader(title: "Facts", icon: "sparkles",
                              trailing: "\(model.memories.count)", tint: Kairo.teal)
                    .kairoListRow()

                if model.memories.isEmpty {
                    emptyFacts.kairoListRow()
                } else {
                    ForEach(model.memories, id: \.id) { m in
                        MemoryRow(memory: m) { forget(m) }
                            .kairoListRow()
                    }
                }

                decisions.kairoListRow()

                TrustNote(text: "Facts marked on-device never leave this phone. "
                          + "Anything you delete is gone from every agent's next answer.",
                          icon: "iphone.and.arrow.forward")
                    .padding(.top, 4)
                    .kairoListRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(KairoCanvas())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openRecordID) { id in
                if let record = model.records.first(where: { $0.id == id }) {
                    WhyView(record: record)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        KairoHeader(eyebrow: "what kairo remembers", title: "Memory") {
            Pill(text: factCount, icon: "book.closed.fill", tint: Kairo.teal)
        }
    }

    private var factCount: String {
        model.memories.count == 1 ? "1 fact" : "\(model.memories.count) facts"
    }

    private var emptyFacts: some View {
        HStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Kairo.teal)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Kairo.teal.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Kairo remembers nothing about you")
                    .font(.kairoHeadline).foregroundStyle(Kairo.ink)
                Text("Facts appear here as they are learned, and only after they "
                     + "have been corroborated.")
                    .font(.caption).foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .kairoCard(tint: Kairo.teal)
    }

    // MARK: - Recent decisions
    //
    // These sit inside a single list row rather than being rows themselves, so
    // the cards keep their own chrome instead of collecting a system chevron.
    //
    // Which record the reader has opened. Held here rather than pushed straight
    // from the row, for the reason spelled out on the Button below.

    @ViewBuilder private var decisions: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Recent decisions", icon: "clock.arrow.circlepath",
                          trailing: "\(model.records.count)", tint: Kairo.violet)
                .padding(.top, 10)

            if model.records.isEmpty {
                Text("Nothing has been decided yet this session.")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kairoCard(padding: 14, radius: Kairo.Radius.inner)
            } else {
                ForEach(model.records.reversed(), id: \.id) { r in
                    // A Button plus `navigationDestination(item:)` rather than a
                    // NavigationLink: nested or not, a link inside a List still
                    // earns the row a system chevron, and the card draws its own.
                    Button { openRecordID = r.id } label: {
                        DecisionRecordCard(record: r)
                    }
                    .buttonStyle(.kairoPress)
                }
            }
        }
    }

    // MARK: - Actions

    /// CF10: the delete is real. It leaves the store, so it is gone from the
    /// next answer every agent gives — there is no shadow copy behind it.
    private func forget(_ memory: MemoryItem) {
        try? model.env.memoryStore.delete(id: memory.id)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            model.reloadMemories()
        }
    }
}

// MARK: - One fact

struct MemoryRow: View {
    let memory: MemoryItem
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                MetricRing(progress: memory.confidence,
                           tint: confidenceTint,
                           centreText: percent,
                           size: 52, lineWidth: 6)
                Text("sure")
                    .font(.kairoLabel).tracking(0.8)
                    .foregroundStyle(Kairo.inkFaint)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(memory.text)
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)

                PillWrap {
                    Pill(text: spacedStateName(memory.state.name),
                         icon: stateIcon, tint: stateTint ?? Kairo.leaf)
                    if memory.sensitivity.mustStayOnDevice {
                        Pill(text: "on device", icon: "iphone", tint: Kairo.teal)
                    }
                    if memory.decayExempt {
                        Pill(text: "never expires", icon: "lock.fill", tint: Kairo.violet)
                    }
                    if let decayAt = memory.decayAt {
                        Pill(text: "fades \(decayAt.formatted(.dateTime.day().month()))",
                             icon: "hourglass", tint: Kairo.amber)
                    }
                    if !memory.isRetrievable {
                        Pill(text: "not used in answers", icon: "eye.slash",
                             tint: Kairo.inkFaint)
                    }
                }

                if let note = stateNote {
                    HStack(spacing: 5) {
                        Image(systemName: stateIcon).font(.system(size: 9, weight: .bold))
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2)
                    .foregroundStyle(stateTint ?? Kairo.inkSoft)
                }

                HStack(spacing: 5) {
                    Image(systemName: originIcon).font(.system(size: 9, weight: .bold))
                    Text(origin)
                    Text("·").foregroundStyle(Kairo.inkFaint)
                    Text(memory.id).font(.kairoMono)
                }
                .font(.caption2)
                .foregroundStyle(Kairo.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: cardTint)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onForget) {
                Label("Forget", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(memory.text). \(percent) per cent confident, "
                            + "\(spacedStateName(memory.state.name)). \(origin).")
    }

    // MARK: Presentation

    private var percent: String { "\(Int((memory.confidence * 100).rounded()))" }

    /// The card is tinted by state first: a fact waiting to be adjudicated must
    /// not look like one Kairo is acting on. Sensitivity only speaks up when the
    /// state has nothing to say.
    private var cardTint: Color? {
        stateTint ?? (memory.sensitivity.mustStayOnDevice ? Kairo.teal : nil)
    }

    private var stateTint: Color? {
        switch memory.state {
        case .contradicted:
            return Kairo.coral
        case .candidate, .unconfirmed, .decaying:
            return Kairo.amber
        case .superseded, .expired, .deleted:
            return Kairo.inkFaint
        case .active, .verified:
            return nil
        }
    }

    private var confidenceTint: Color {
        if let stateTint { return stateTint }
        return memory.confidence >= 0.75 ? Kairo.leaf : Kairo.amber
    }

    private var stateIcon: String {
        switch memory.state {
        case .active:       "checkmark.circle.fill"
        case .verified:     "checkmark.seal.fill"
        case .candidate:    "questionmark.circle"
        case .contradicted: "exclamationmark.triangle.fill"
        case .unconfirmed:  "eye.trianglebadge.exclamationmark"
        case .decaying:     "hourglass"
        case .superseded:   "arrow.triangle.branch"
        case .expired:      "clock.badge.xmark"
        case .deleted:      "trash"
        }
    }

    /// Plain English for anything the user might want to act on.
    private var stateNote: String? {
        switch memory.state {
        case .active, .verified:
            return nil
        case .candidate:
            return "Not confirmed yet — no agent is using this."
        case .contradicted:
            return "This clashes with something newer. Forget it if it is wrong."
        case .unconfirmed:
            return "Kairo has not seen this happen lately."
        case .decaying:
            return "Fading out on its own unless it happens again."
        case .superseded:
            return "Replaced by a newer fact, kept because a decision cited it."
        case .expired:
            return "Timed out. Kept only for records that cited it."
        case .deleted:
            return "Deleted."
        }
    }

    private var origin: String {
        switch memory.sourceRef {
        case "user":                        "you told me this"
        case "chat":                        "you told me this in conversation"
        case "extraction":                  "picked out of something you said"
        case "motion-pattern":              "learned from your motion pattern"
        case "nudge-outcomes", "outcomes":  "learned from how you answered nudges"
        case "seed":                        "set up with the app"
        default:                            "learned from \(memory.sourceRef)"
        }
    }

    private var originIcon: String {
        switch memory.sourceRef {
        case "user", "chat", "extraction": "text.bubble"
        default:                           "waveform.path.ecg"
        }
    }
}

// MARK: - One decision

/// A decision record as something you would want to open, rather than an id.
struct DecisionRecordCard: View {
    let record: DecisionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(record.id)
                    .font(.kairoMono)
                    .foregroundStyle(Kairo.ink)
                Spacer(minLength: 0)
                Pill(text: spacedStateName(record.state.name),
                     icon: record.isSealed ? "lock.fill" : "pencil",
                     tint: record.isSealed ? Kairo.violet : Kairo.amber)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Kairo.inkFaint)
            }

            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(Kairo.inkSoft)

            if !roles.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(roles.enumerated()), id: \.offset) { _, agent in
                        AgentChip(agent: agent, compact: true)
                    }
                    Spacer(minLength: 0)
                }
            }

            Text(counts)
                .font(.kairoMono)
                .foregroundStyle(Kairo.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(padding: 14, radius: Kairo.Radius.inner)
    }

    /// One chip per role, in the order they contributed, without repeats.
    private var roles: [String] {
        var seen: Set<String> = []
        return record.contributingAgents.filter { seen.insert($0).inserted }
    }

    private var counts: String {
        [count(roles.count, "role"),
         count(record.citations.count, "citation"),
         count(record.rejectedAlternatives.count, "rejected", plural: "rejected")]
            .joined(separator: " · ")
    }

    private func count(_ n: Int, _ singular: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}

// MARK: - Shared bits

/// State machine names are camelCase in the domain; the user reads words.
func spacedStateName(_ name: String) -> String {
    var out = ""
    for c in name {
        if c.isUppercase, !out.isEmpty { out.append(" ") }
        out += String(c).lowercased()
    }
    return out
}

/// A row of pills that wraps onto the next line instead of squashing. Facts can
/// carry four or five badges at once and the labels grow with Dynamic Type.
struct PillWrap: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0
        var lineHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > limit {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            if x > 0 { x += spacing }
            x += size.width
            widest = max(widest, x)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            if x > bounds.minX { x += spacing }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
