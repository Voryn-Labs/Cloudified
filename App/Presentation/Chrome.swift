import SwiftUI

struct SymbolTile: View {
    let systemName: String
    var color: Color = .accentColor
    var pulse: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: systemName)
            .symbolEffect(.bounce, value: pulse)
            .symbolEffectsRemoved(reduceMotion)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("BrandMark").resizable().scaledToFit().frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Cloudified").font(.headline)
                Text("VORYN LABS").font(.system(size: 8, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("BrandMark").resizable().scaledToFit().frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloudified").font(.title2.weight(.bold))
                Text("BY VORYN LABS").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct BrandSignature: View {
    var body: some View {
        Link(destination: CloudifiedSupport.companyPage) {
            HStack(spacing: 8) {
                Image("VorynMark").resizable().scaledToFit().frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).accessibilityHidden(true)
                Text("Voryn Labs").font(.caption.weight(.medium))
                Image(systemName: "arrow.up.right").font(.caption2)
            }.frame(minHeight: 44)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Visit Voryn Labs website")
        .textCase(nil)
    }
}

struct MenuRow: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var color: Color = .accentColor
    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(systemName: symbol, color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

struct StatusPill: View {
    let title: String
    let symbol: String
    var color: Color = .secondary
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.medium)).lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.09), in: Capsule())
    }
}

struct BackupMeter: View {
    let fraction: Double?
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.12))
                Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, fraction ?? 0)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct ProgressOrbit: View {
    let fraction: Double?
    let symbol: String
    var color: Color = .accentColor
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.12), lineWidth: 5)
            Circle().trim(from: 0, to: min(1, max(0, fraction ?? 0)))
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: symbol).font(.title2.weight(.medium)).foregroundStyle(color)
        }
        .accessibilityHidden(true)
    }
}

struct FlowIntro: View {
    let systemName: String
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SymbolTile(systemName: systemName)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
}

struct IssueBlock: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(message).foregroundStyle(.primary).textSelection(.enabled)
        }
        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }
}

struct WorkingBlock: View {
    let title: String
    let message: String
    var fillsScreen = false
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.accentColor)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsScreen ? .infinity : nil)
        .padding(fillsScreen ? 24 : 12)
    }
}

extension View {
    func countedBadge(_ count: Int?) -> some View { badge(max(0, count ?? 0)) }
    func cloudifiedList() -> some View {
        listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}

struct FilterCapsule: View {
    let title: String
    var body: some View {
        Text(title).font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.08), in: Capsule())
    }
}
