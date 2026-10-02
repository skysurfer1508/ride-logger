import CoreLocation
import SwiftUI

/// Settings > Auto-start: how to connect the helmet, the optional "start by itself" mode, and the diary that shows what really happened.
struct AutoStartPanel: View {
    @ObservedObject var coordinator: AutoStartCoordinator
    @ObservedObject var recorder: RideRecorder
    @State private var found: [String] = []
    @State private var searched = false

    var body: some View {
        Panel(title: "Auto-start") {
            Text("Start recording by itself, with the phone locked in your bag.")
                .font(.footnote).foregroundStyle(Theme.muted)

            // 1. the Shortcuts automation
            Text("FROM THE HELMET").font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
            Text("iOS cannot open an app because a Bluetooth device connected, but Shortcuts can: Shortcuts > Automation > + > Bluetooth > choose your helmet > Is Connected > Run Immediately > Next > Add Action > RideLog > Start ride. Do the same with Is Disconnected and Stop ride if you want it to stop too.")
                .font(.footnote).foregroundStyle(Theme.text)
            Button("Open Shortcuts") {
                if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
            HStack {
                Image(systemName: coordinator.notificationsAllowed ? "checkmark.circle.fill" : "bell.slash")
                    .foregroundStyle(coordinator.notificationsAllowed ? Theme.success : Theme.muted)
                Text(coordinator.notificationsAllowed ? "Notifications are on: if the start does not work by itself, a notification asks you to tap."
                                                      : "Notifications are off: without them there is no safety net if the start does not work with a locked phone.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            if !coordinator.notificationsAllowed {
                Button("Allow notifications") { coordinator.requestNotificationPermission() }.buttonStyle(.bordered)
            }

            Divider().overlay(Theme.border)

            // 2. motion fallback
            Text("START BY ITSELF").font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
            Toggle("Notice when I start riding", isOn: $coordinator.motionEnabled).tint(Theme.accent).foregroundStyle(Theme.text)
            Text("Needs location access set to Always. The phone is woken by a movement, checks the GPS for up to two minutes, and starts when you ride at 15 km/h or more for 20 seconds.")
                .font(.footnote).foregroundStyle(Theme.muted)
            if coordinator.motionEnabled && !recorder.isAlways {
                Label("Location is not set to Always yet.", systemImage: "location.slash").font(.footnote).foregroundStyle(Theme.danger)
                if recorder.authorization == .notDetermined {
                    Button("Allow location") { recorder.requestPermission() }.buttonStyle(.bordered)
                } else if recorder.authorization == .authorizedWhenInUse {
                    Button("Allow \"Always\" location") { recorder.requestAlwaysPermission() }.buttonStyle(.bordered)
                    Text("If iOS does not ask again: iPhone Settings > RideLog > Location > Always.").font(.caption).foregroundStyle(Theme.muted)
                } else {
                    Text("Open iPhone Settings > RideLog > Location and choose Always.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Picker("When it looks like a ride", selection: $coordinator.mode) {
                ForEach(AutoStartMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Only when my helmet is connected", isOn: $coordinator.requireHelmet).tint(Theme.accent).foregroundStyle(Theme.text)
            TextField("Helmet name, for example Cardo", text: $coordinator.helmetName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Look for connected audio devices") {
                found = coordinator.detectAudioDevices()
                searched = true
            }
            .buttonStyle(.bordered)
            if searched && found.isEmpty {
                Text("No device is reported right now. A Bluetooth helmet often only shows up while audio plays to it: switch the helmet on, play something, and try again. If it never shows, switch \"Only when my helmet is connected\" off.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(found, id: \.self) { name in
                Button { coordinator.helmetName = name } label: {
                    Label(name, systemImage: "headphones").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }

            Toggle("Stop after 10 minutes standing still", isOn: $coordinator.autoStopEnabled).tint(Theme.accent).foregroundStyle(Theme.text)
            Text("Only for rides that started by themselves.").font(.caption).foregroundStyle(Theme.muted)

            Divider().overlay(Theme.border)

            // 3. the diary
            HStack {
                Text("WHAT HAPPENED").font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
                Spacer()
                if !coordinator.entries.isEmpty { Button("Clear") { coordinator.clearLog() }.font(.footnote) }
            }
            if coordinator.entries.isEmpty {
                Text("Nothing yet. Every automatic start, and every time one was tried and did not work, is written here.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            ForEach(coordinator.entries.prefix(15)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.date.formatted(date: .abbreviated, time: .standard))  ·  \(entry.trigger)  ·  \(entry.outcome)")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                    if !entry.detail.isEmpty { Text(entry.detail).font(.caption).foregroundStyle(Theme.muted) }
                }
            }
        }
        .onAppear { coordinator.refreshEntries() }
    }
}
