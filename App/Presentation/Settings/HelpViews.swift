import SwiftUI

enum CloudifiedSupport {
    static let companyPage = URL(string: "https://voryn-labs.github.io/")!
    static let repository = URL(string: "https://github.com/Voryn-Labs/Cloudified")!
    static let issues = repository.appendingPathComponent("issues")
    static let source = URL(string: "https://raw.githubusercontent.com/Voryn-Labs/Cloudified/main/source.json")!

    static func issueDraft(report: URL? = nil, feedback: Bool = false) -> URL {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unavailable"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unavailable"
        let revision = bundle.object(forInfoDictionaryKey: "CloudifiedRevision") as? String ?? "Unavailable"
        let body = """
        ## \(feedback ? "Suggestion" : "What happened")
        Describe \(feedback ? "the improvement and why it would help" : "the problem and which destination is affected").

        ## Expected behavior
        What should happen?

        ## Steps to reproduce
        1.
        2.

        ## App information
        - Cloudified: \(version) (\(build))
        - Revision: \(revision)
        - iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - Runtime: \(AppRuntime.description)
        - Installer / signing method:
        - Foreground / Keep Awake / background:
        - Photos / videos / Live Photos:

        ## Public diagnostics
        \(report?.absoluteString ?? "No diagnostic report attached.")

        Review before submitting. Do not include passwords, tokens, API hashes, phone numbers, account emails, private channel IDs, or personal photos.
        """
        var components = URLComponents(url: issues.appendingPathComponent("new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: feedback ? "Feedback: " : "Bug: "),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url!
    }
}

struct HelpView: View {
    @ObservedObject var environment: AppEnvironment
    var body: some View {
        List {
            Section("Get started") {
                NavigationLink { TelegramGuideView() } label: {
                    Label("Link and map Telegram", systemImage: "paperplane")
                }
                NavigationLink { BackupFAQView() } label: {
                    Label("Frequently asked questions", systemImage: "questionmark.circle")
                }
            }
            Section("Support") {
                NavigationLink { FeedbackView(environment: environment) } label: {
                    Label("Report a problem or send feedback", systemImage: "bubble.left.and.bubble.right")
                }
                Link(destination: CloudifiedSupport.issues) {
                    Label("Browse GitHub issues", systemImage: "arrow.up.right.square")
                }
            }
            Section("Install and update") {
                Text("Install the unsigned IPA with Feather, SideStore or another compatible signer. LiveContainer uses foreground backup: keep Cloudified open. Every method requires iOS 26 or later.")
                    .font(.footnote).foregroundStyle(.secondary)
                ShareLink(item: CloudifiedSupport.source) {
                    Label("Share Voryn Labs source", systemImage: "square.and.arrow.up")
                }
                Text("Add this source in Feather, then refresh it to see updates. Use your certificate and keep the same app identity when updating.")
                    .foregroundStyle(.secondary)
            }
        }
        .cloudifiedList().navigationTitle("Help & guides")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeedbackView: View {
    @ObservedObject var environment: AppEnvironment
    var body: some View {
        List {
            Section { FlowIntro(systemName: "bubble.left.and.text.bubble.right", title: "Help us find the cause", message: "Create a diagnostic link below, then review your report on GitHub. Uploading a report does not submit an issue automatically.") }
            DiagnosticUploadSection(environment: environment)
            Section("Suggestions and existing reports") {
                Link("Suggest an improvement", destination: CloudifiedSupport.issueDraft(feedback: true))
                Link("Browse existing issues", destination: CloudifiedSupport.issues)
                NavigationLink("What to include in a report") { ReportingGuideView(reportURL: nil) }
            }
        }
        .cloudifiedList().navigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReportingGuideView: View {
    let reportURL: URL?
    var body: some View {
        List {
            Section("1. Reproduce the problem") {
                Text("Note the affected destination and action. Include whether Cloudified was open, in Keep Awake, or in the background, and whether the file was a photo, video, or Live Photo.")
            }
            Section("2. Upload recent diagnostics") {
                Text("Use Upload public diagnostics in Activity → Report a problem or Settings → Report a problem, preferably soon after the issue. Reports contain selected recent events and may omit older or pruned events.")
                if let reportURL { Link("Open this report", destination: reportURL) }
            }
            Section("3. Review and submit on GitHub") {
                Link("Create GitHub issue", destination: CloudifiedSupport.issueDraft(report: reportURL))
                Text("The draft includes app information and this report link when available. Add a clear title, steps, expected behavior, and what actually happened. Sign in to GitHub if asked, review the draft, then submit it there.")
            }
            Section("Keep private information out") {
                Text("The report and issue are public. Do not add passwords, login codes, Google tokens, Telegram API hashes, phone numbers, emails, private channel IDs, or personal media. Crop account details from any screenshots you choose to attach.")
            }
        }
        .cloudifiedList().navigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TelegramGuideView: View {
    var body: some View {
        List {
            Section("1. Prepare a private channel") {
                Text("In Telegram, create a new channel and choose Private. Use a channel owned by the account you will sign in with. Turn off auto-delete so archive messages remain available for recovery.")
                Text("Cloudified requires a private channel you own. Groups, public channels, and channels where you are only an administrator are not eligible.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("2. Get your API credentials") {
                Link("Open Telegram API development tools", destination: URL(string: "https://my.telegram.org/apps")!)
                Text("Sign in to my.telegram.org and create an application under API development tools if needed. Copy its API ID and API hash. These are application credentials, not a bot token; no bot is needed.")
            }
            Section("3. Sign in to Cloudified") {
                Text("Open Settings → Destinations → Telegram → Connect Telegram. Enter the API ID and hash, then your Telegram phone number with country code. Complete the code, two-step verification password, or other verification that Telegram requests.")
                Text("Login codes may arrive in your existing Telegram app. Enter credentials only in the sign-in flow; never put them in feedback or diagnostic reports.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("4. Choose and verify the destination") {
                Text("After signing in, select your private channel. If it is missing, search by title or load more channels. Advanced users can check a known numeric channel ID; Cloudified still verifies ownership and eligibility.")
                Text("Review the account and channel, then tap Use this channel. Mapping identifies the exact archive destination. Cloudified checks existing uploads before continuing; allow this check to finish.")
            }
            Section("5. Check uploads") {
                Text("Turn on Enable uploads for Telegram. With Photos permission and automatic backup enabled, opening Cloudified starts eligible work. Open Telegram on Backup to see its own saved and remaining counts.")
            }
            Section("Changing accounts or channels") {
                Text("Change channel chooses another archive destination and checks its contents independently. Disconnect destination removes the mapping; saved messages remain. Log out of this app ends Cloudified’s Telegram session, without logging out your other Telegram apps.")
            }
            Section("Why are there JSON files?") {
                Text("Media is uploaded as original files. Small JSON manifests describe archive content and metadata for reconciliation and future viewing tools. Keep them with the media. Live Photos can have both a still image and a motion video, so one library item may create several messages.")
            }
        }
        .cloudifiedList().navigationTitle("Telegram setup")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BackupFAQView: View {
    var body: some View {
        List {
            Section("Library and quality") {
                answer("Which files are included?", "Cloudified uploads accessible photos and videos, including supported iPhone originals such as HEIC and JPEG. Allow full Photos access to include the full library; limited access includes only selected items.")
                answer("Are originals compressed?", "Cloudified sends original resource bytes. Telegram stores them as files. Google uses the original-quality upload profile. Unsupported originals appear as issues rather than being silently converted to lower quality.")
                answer("How are Live Photos counted?", "A Live Photo is one library item. Telegram keeps both original components. Google follows Settings → Live Photos; the selected fallback can save only the key image or motion when pairing is unavailable.")
                answer("Is there a 200-photo limit?", "No. There is no 200-photo library cap. Each enabled destination processes its own queue. Provider rate limits may temporarily pause that destination; adding more parallel uploads is not a guarantee of higher speed.")
            }
            Section("Live Photos: choose what Google saves") {
                answer("Both originals separately — recommended", "Google gets the original still image and original motion video as two separate items. This keeps both components without depending on Google recreating a Live Photo. Telegram keeps both original files and their association metadata with every setting.")
                answer("Paired originals (where supported)", "Requests a native paired Live Photo in Google. If pairing is not accepted or cannot be verified, the item waits or appears in Issues; Cloudified does not silently switch modes. Choose Both originals separately for a more compatible archive.")
                answer("Key image only", "Google gets only the original still image. The motion component is omitted from Google; Telegram still keeps it. Use this only if you intentionally do not want motion in Google.")
                answer("Motion video only", "Google gets only the original motion video. The still image is omitted from Google; Telegram still keeps it. Neither component is recompressed.")
                answer("Counts and changing the choice", "A Live Photo counts once in your Photos library, even when it creates several files. Saved means the resources required by that destination’s selected policy are confirmed. Change the option in Settings → Live Photos; started or uncertain jobs retain their original plan until it is safe to change coverage.")
            }
            Section("Progress and recovery") {
                answer("Do both destinations upload together?", "Yes. Google Photos and Telegram run independently in the same backup batch. A Google failure does not automatically fail Telegram, or the other way around. Photos permission, temperature and network rules can affect both.")
                answer("Why is Google slow?", "Each original needs remote checks, transfer and finalization. Network conditions, iOS scheduling, temperature and Google responses can affect completion time. Send a recent diagnostic report if progress is unusually slow; a saved count alone does not measure transfer speed.")
                answer("Will a photo already in Google be uploaded again?", "Cloudified checks for matching original content. An exact-byte match can be recognized even if another app uploaded it. Edited, transcoded or compressed copies may have different hashes and cannot be guaranteed to match.")
                answer("What does remote acceptance unknown mean?", "A transfer or finalization was interrupted and the app cannot yet prove whether the service accepted it. Cloudified reconciles remote evidence before retrying, to avoid blindly creating duplicates. Do not delete archive messages or reinstall to clear this state.")
                answer("How do I identify a problem file?", "Open Activity → Issues. All statuses are shown initially, including waiting items. Match the thumbnail, original filename, capture date and photo/video type. Select the file for its destination, reason, retry or verification action, and Copy file details. In Photos, use the date and thumbnail, then compare its filename in Info.")
                answer("Why can Telegram verification stay waiting?", "An older native send has no verifiable result. Its original stays protected and is not counted as saved; waiting does not mean the original is lost. Verify upload checks the same account/channel. If still unresolved, share diagnostics. Cloudified does not guess or automatically resend; at eight protected native uploads Telegram admission pauses until ownership is resolved.")
                answer("What happens after an upload fails?", "The affected destination records the reason and continues eligible work. Automatic sending is limited to three attempts per item and destination. Some waits need network access, account action or reconciliation rather than another immediate send. See Activity → Issues.")
                answer("Can I delete and reinstall the app?", "An update should preserve local progress when the certificate and bundle identity stay the same. Reinstalling can remove the local ledger; remote reconciliation is required before absent-content uploads. Keep Telegram media and manifests together. Do not reinstall as a routine troubleshooting step.")
            }
            Section("Background and battery") {
                answer("Will backup always continue in the background?", "iOS controls background execution and can delay or stop it. Google file transfers use an OS-managed background session, but checking and finalizing still need execution time. Telegram needs time for its native session. Force-closing the app prevents reliable continuation.")
                answer("What is Keep Awake for?", "It keeps Cloudified open on a minimal black progress screen so eligible work can continue in the foreground. It does not grant unlimited background time or bypass network, low-power or thermal protection. Use the top-right close button to return to Backup; pause/resume stays on Backup. Low battery, completion and protected-only waits permit auto-lock.")
                answer("Why did both destinations pause?", "Check Photos access, Wi-Fi only, Low Power Mode and device temperature. Thermal protection pauses work when the phone is too hot; let it cool. Background time can also expire. The destination details show the current recorded reason.")
            }
            Section("Accounts and support") {
                answer("Is Google sign-in separate from my phone’s accounts?", "Cloudified keeps its own credentials and uses an isolated web sign-in. Google may still recognize your account or register the login. App isolation cannot guarantee how Google applies account verification or restrictions.")
                answer("Are uploaded diagnostics private?", "No. The report link and a GitHub issue are public. Reports omit credentials, original media, account names and private paths, but contain technical events and app information. Review what you add before sharing.")
            }
        }
        .cloudifiedList().navigationTitle("FAQ")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func answer(_ question: String, _ answer: String) -> some View {
        DisclosureGroup(question) {
            Text(answer).foregroundStyle(.secondary).padding(.vertical, 4).textSelection(.enabled)
        }
    }
}
