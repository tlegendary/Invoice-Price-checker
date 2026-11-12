import SwiftUI
import CloudKit
import UIKit
import ChargeCheckCore

/// Settings › Staff: the owner shares the business with staff phones; staff see whose business they're in.
struct TeamView: View {
    @ObservedObject private var team = CloudTeam.shared
    @State private var share: CKShare?
    @State private var showInvite = false
    @State private var working = false
    @State private var problem: String?
    @State private var confirmStop = false
    @State private var confirmLeave = false

    var body: some View {
        List {
            switch team.role {
            case .none: offView
            case .owner: ownerView
            case .staff: staffView
            }
            if !team.status.isEmpty || problem != nil {
                Section {
                    Text(problem ?? team.status)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Staff")
        .refreshable { await team.refresh() }
        .sheet(isPresented: $showInvite) {
            if let share {
                CloudSharingView(share: share, container: team.cloudContainer)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var offView: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Share your shops with staff", systemImage: "person.2.fill")
                    .font(.headline)
                Text("Staff use ChargeCheck on their own iPhones. They scan and check invoices for their shop, and see Reports and what's owed. Only you can change prices, record payments and change settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button {
                Task {
                    working = true
                    problem = nil
                    do {
                        try await team.becomeOwner()
                    } catch {
                        problem = CloudTeam.describe(error)
                    }
                    working = false
                }
            } label: {
                HStack {
                    Label("Turn on sharing", systemImage: "icloud.and.arrow.up")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(working)
        } footer: {
            Text("Everything is kept in your own iCloud. Staff join with an invite link you send them. To join someone else's business, open the invite link they sent you.")
        }
    }

    @ViewBuilder
    private var ownerView: some View {
        Section {
            Label("Sharing is on", systemImage: "checkmark.icloud.fill")
                .foregroundStyle(.green)
            syncLine
            Button {
                Task {
                    working = true
                    problem = nil
                    do {
                        share = try await team.share()
                        showInvite = true
                    } catch {
                        problem = CloudTeam.describe(error)
                    }
                    working = false
                }
            } label: {
                HStack {
                    Label("Invite staff or see who's joined", systemImage: "person.badge.plus")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(working)
        } footer: {
            Text("Send the invite by WhatsApp, Messages or email. Staff need ChargeCheck Beta from TestFlight first (add them as testers in App Store Connect). You can remove anyone from the same screen.")
        }
        Section {
            Button("Stop sharing", role: .destructive) { confirmStop = true }
                .confirmationDialog("Stop sharing with every staff member?", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Stop sharing", role: .destructive) { Task { await team.stopSharing() } }
                } message: {
                    Text("Staff phones lose access straight away. Your own data stays on this phone.")
                }
        }
    }

    @ViewBuilder
    private var staffView: some View {
        Section {
            Label {
                Text("You're on the team of \(UserDefaults.standard.string(forKey: SettingKey.business).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "the owner"))")
            } icon: {
                Image(systemName: "person.2.fill")
            }
            syncLine
        } footer: {
            Text("Invoices you check are shared with the owner. Prices, payments and settings are managed by the owner.")
        }
        Section {
            Button("Leave the team", role: .destructive) { confirmLeave = true }
                .confirmationDialog("Leave the team?", isPresented: $confirmLeave, titleVisibility: .visible) {
                    Button("Leave", role: .destructive) { Task { await team.leave() } }
                } message: {
                    Text("The owner's prices and reports are removed from this phone.")
                }
        }
    }

    private var syncLine: some View {
        HStack {
            Text(team.lastSync.map { String(localized: "Last synced \($0.formatted(date: .omitted, time: .shortened))") }
                 ?? String(localized: "Not synced yet"))
                .foregroundStyle(.secondary)
            Spacer()
            if team.busy {
                ProgressView()
            } else {
                Button("Sync now") { Task { await team.refresh() } }
                    .buttonStyle(.borderless)
            }
        }
        .font(.subheadline)
    }
}

/// Apple's own screen for inviting people to a share and managing who's in it.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}

        func itemTitle(for csc: UICloudSharingController) -> String? {
            let business = UserDefaults.standard.string(forKey: SettingKey.business) ?? ""
            return business.isEmpty ? String(localized: "ChargeCheck team") : business
        }
    }
}

/// Opening an invite link lands here: iOS hands the share to the app's scene.
final class TeamAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = TeamSceneDelegate.self
        return configuration
    }
}

final class TeamSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in await CloudTeam.shared.accept(cloudKitShareMetadata) }
    }
}
