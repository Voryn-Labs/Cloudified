import SwiftUI

struct WalkthroughView: View {
    let onFinish: (Bool) -> Void
    @State private var page = 0
    @State private var showsStorageDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 28) {
                    illustration
                    VStack(spacing: 12) {
                        Text(title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(.isHeader)
                        if page == 0 {
                            Text("Photos, videos and Live Photos.\nGoogle Photos, Telegram, or both.")
                                .font(.body).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    switch page {
                    case 0: introduction
                    case 1: storage
                    default: setup
                    }
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .id(page)
            .scrollIndicators(.hidden)
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .sheet(isPresented: $showsStorageDetails) { storageDetails }
    }

    private var header: some View {
        HStack {
            Button {
                changePage(to: page - 1)
            } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Previous step")
            .disabled(page == 0).opacity(page == 0 ? 0 : 1)
            Spacer(minLength: 0)
            Text("Cloudified").font(.headline).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button("Skip") { onFinish(false) }
                .font(.subheadline).frame(minWidth: 48, minHeight: 48)
                .accessibilityLabel("Skip walkthrough and open Cloudified")
        }
        .padding(.horizontal, 16)
    }

    private var title: String {
        switch page {
        case 0: "Your originals.\nBacked up."
        case 1: "More space.\nKnow the trade-offs."
        default: "A few steps.\nThen it runs."
        }
    }

    private var illustration: some View {
        Group {
            if page == 0 {
                HStack(spacing: 20) {
                    Image("BrandMark").resizable().scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    Image(systemName: "arrow.right").font(.title3).foregroundStyle(.tertiary)
                    VStack(spacing: 12) {
                        destinationSymbol("photo.on.rectangle", name: "Google Photos")
                        destinationSymbol("paperplane", name: "Telegram")
                    }
                }
            } else {
                Image(systemName: page == 1 ? "infinity" : "checkmark.shield")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 128, height: 128)
                    .background(Color.accentColor.opacity(0.08), in: Circle())
            }
        }
        .frame(height: 144)
        .dynamicTypeSize(.large)
        .accessibilityHidden(true)
    }

    private func destinationSymbol(_ symbol: String, name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(name).font(.caption.weight(.medium)).foregroundStyle(.primary)
        }
        .frame(maxWidth: 144, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var introduction: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                benefit("Original\nquality", symbol: "photo")
                benefit("Separate\nqueues", symbol: "arrow.triangle.branch")
                benefit("Duplicate\nchecks", symbol: "checkmark.shield")
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("Your library stays on your iPhone.\nCloudified never deletes your originals.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func benefit(_ title: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor)
            Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                fact("Telegram", symbol: "paperplane", text: "Free unlimited cloud storage, with file and service limits.")
                Divider()
                fact("Google Photos", symbol: "photo.on.rectangle", text: "Unlimited-storage workaround. Unofficial and not guaranteed.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Use a separate Google account", systemImage: "exclamationmark.shield")
                    .font(.subheadline.weight(.semibold))
                Text("Google may restrict or suspend the account. Linking is optional.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Button("Storage & account details") { showsStorageDetails = true }
                .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func fact(_ title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 24) {
            fact("Choose Photos access", symbol: "photo.badge.checkmark", text: "Allow full or selected-library access.")
            fact("Connect a destination", symbol: "link", text: "Google Photos, your private Telegram channel, or both. Guides are included.")
            fact("Open the app. Backups start.", symbol: "arrow.up.circle", text: "Use Keep Awake for long batches. Your originals stay on your iPhone.")
            Text("Background time depends on iOS.\nIn LiveContainer, keep Cloudified open.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private var controls: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Capsule().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: index == page ? 24 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Step \(page + 1) of 3")
            Button {
                if page < 2 { changePage(to: page + 1) } else { onFinish(true) }
            } label: {
                Text(page == 2 ? "Open setup" : "Continue")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func changePage(to next: Int) {
        guard (0..<3).contains(next) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { page = next }
    }

    private var storageDetails: some View {
        NavigationStack {
            List {
                Section("Telegram") {
                    Text("Original files go to your private channel. Oversized files use lossless parts. Telegram can impose file, rate and service limits; permanent availability is not guaranteed.")
                    Text("Channel files are not end-to-end encrypted. Keep an independent copy of important originals.")
                }
                Section("Google Photos") {
                    Text("An unofficial Pixel-style method requests original-quality uploads that do not count toward quota. Google can count uploads, change the method or block access.")
                    Text("Sign-in uses a broad Android credential, not Photos-only access. The whole account may be restricted or suspended. A separate backup account is recommended; isolation from other Google accounts is not guaranteed.")
                    Link("Read account and privacy notes", destination: CloudifiedSupport.repository.appendingPathComponent("blob/main/docs/public/PRIVACY.md"))
                }
            }
            .navigationTitle("Storage & accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsStorageDetails = false }
                }
            }
        }
    }
}
