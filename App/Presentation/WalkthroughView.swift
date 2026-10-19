import SwiftUI

struct WalkthroughView: View {
    let onFinish: (Bool) -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image("VorynMark").resizable().scaledToFit().frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text("Voryn Labs").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { onFinish(false) }.frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Skip walkthrough and open Cloudified")
            }
            .padding(.horizontal, 24).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    switch page {
                    case 0: introduction
                    case 1: storage
                    default: setup
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .id(page)
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: page)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 24) {
            if page == 0 {
                Image("BrandMark").resizable().scaledToFit().frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: page == 1 ? "infinity" : "checklist")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 96, height: 96, alignment: .leading)
                    .accessibilityHidden(true)
            }
            Text(page == 0 ? "Your originals.\nTwo destinations." : page == 1 ? "Free storage.\nKnow the limits." : "Ready for your\nfirst backup.")
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Cloudified backs up your iPhone photos and videos to Google Photos, Telegram, or both.")
                .font(.title3).foregroundStyle(.secondary)
            detail("Original quality", symbol: "photo.on.rectangle.angled",
                   text: "HEIC, JPEG, videos and supported Live Photo components stay in their original quality.")
            detail("Two independent backups", symbol: "arrow.triangle.branch",
                   text: "Each destination has its own queue and progress. A problem with one can leave the other running.")
            detail("Check before sending", symbol: "checkmark.shield",
                   text: "Known uploads are checked before another copy is sent. Uncertain files remain visible for verification.")
        }
    }
    private var storage: some View {
        VStack(alignment: .leading, spacing: 24) {
            detail("Telegram cloud storage", symbol: "paperplane",
                   text: "Telegram offers free unlimited cloud storage with per-file and service limits. Originals go to your private channel; oversized files use lossless parts.")
            detail("Google: unofficial unlimited-storage method", symbol: "cloud",
                   text: "An unofficial Pixel-style method requests original-quality uploads that do not count toward quota. This is not guaranteed: Google can count uploads, change the method or block access.")
            detail("Understand the Google account risk", symbol: "exclamationmark.shield",
                   text: "Google can restrict or suspend the account. Sign-in uses a broad Android credential, not Photos-only access. Use a separate backup account; isolation from other Google accounts is not guaranteed.")
            Text("Google is optional. Telegram channel files are not end-to-end encrypted. Keep an independent copy of important originals.")
                .font(.footnote).foregroundStyle(.secondary)
            Link("Read account and privacy notes", destination: CloudifiedSupport.repository.appendingPathComponent("blob/main/docs/public/PRIVACY.md"))
                .font(.subheadline).frame(minHeight: 44)
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 24) {
            detail("1. Choose Photos access", symbol: "photo.badge.checkmark",
                   text: "Backup includes accessible hidden photos and every burst frame. Limited access restricts which items iOS makes available.")
            detail("2. Link your destinations", symbol: "link",
                   text: "Open Settings to connect Google Photos, Telegram, or both. Telegram needs your API credentials and a private channel you own. Guides walk you through each step.")
            detail("3. Let backup run", symbol: "moon.stars",
                   text: "Opening Cloudified starts eligible backups automatically. For long batches, use Keep Awake while charging. iOS controls background time; LiveContainer needs the app open.")
            Text("Activity identifies files that need attention. Cloudified does not delete originals from your Photos library.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func detail(_ title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            SymbolTile(systemName: symbol)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Capsule().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 20, height: 4)
                }
                Text("\(page + 1) of 3").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.accessibilityElement(children: .ignore).accessibilityLabel("Step \(page + 1) of 3")
            HStack(spacing: 16) {
                if page > 0 { Button("Back") { page -= 1 }.frame(minWidth: 64, minHeight: 48) }
                Button {
                    if page < 2 { page += 1 } else { onFinish(true) }
                } label: {
                    Text(page == 2 ? "Set up backups" : "Continue").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
