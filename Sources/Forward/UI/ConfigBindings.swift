import ForwardKit
import SwiftUI

/// Bindings that route every edit through `ConfigStore.update`, so the JSON file stays
/// the single source of truth and nothing can mutate config without persisting it.
@MainActor
extension ConfigStore {
    func bind<Value>(
        host hostID: UUID,
        _ keyPath: WritableKeyPath<HostGroup, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { self.config.host(id: hostID)?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                self.update { config in
                    guard let index = config.hosts.firstIndex(where: { $0.id == hostID }) else { return }
                    config.hosts[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    func bind<Value>(
        host hostID: UUID,
        forward forwardID: UUID,
        _ keyPath: WritableKeyPath<Forward, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                self.config.host(id: hostID)?
                    .forwards.first { $0.id == forwardID }?[keyPath: keyPath] ?? fallback
            },
            set: { newValue in
                self.update { config in
                    guard let hostIndex = config.hosts.firstIndex(where: { $0.id == hostID }),
                          let index = config.hosts[hostIndex].forwards.firstIndex(where: { $0.id == forwardID })
                    else { return }
                    config.hosts[hostIndex].forwards[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    func bind<Value>(settings keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.config.settings[keyPath: keyPath] },
            set: { newValue in
                self.update { config in config.settings[keyPath: keyPath] = newValue }
            }
        )
    }

    /// Text-field friendly view of an optional string: empty means "not set", which for
    /// `user` and `port` means "defer to ~/.ssh/config".
    func bindOptionalText(host hostID: UUID, _ keyPath: WritableKeyPath<HostGroup, String?>) -> Binding<String> {
        Binding(
            get: { self.config.host(id: hostID)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                self.update { config in
                    guard let index = config.hosts.firstIndex(where: { $0.id == hostID }) else { return }
                    config.hosts[index][keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
                }
            }
        )
    }

    func bindOptionalPort(host hostID: UUID) -> Binding<String> {
        Binding(
            get: { self.config.host(id: hostID)?.port.map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                self.update { config in
                    guard let index = config.hosts.firstIndex(where: { $0.id == hostID }) else { return }
                    config.hosts[index].port = trimmed.isEmpty ? nil : Int(trimmed)
                }
            }
        )
    }

    /// One option per line is far easier to edit than a JSON array.
    func bindExtraOptions(host hostID: UUID) -> Binding<String> {
        Binding(
            get: { (self.config.host(id: hostID)?.extraOptions ?? []).joined(separator: "\n") },
            set: { newValue in
                let options = newValue
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                self.update { config in
                    guard let index = config.hosts.firstIndex(where: { $0.id == hostID }) else { return }
                    config.hosts[index].extraOptions = options
                }
            }
        )
    }
}
