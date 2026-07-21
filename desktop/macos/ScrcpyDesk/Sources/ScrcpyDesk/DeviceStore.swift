import Foundation

enum APKInstallState: Equatable {
    case installing
    case succeeded
    case failed
}

@MainActor
final class DeviceStore: ObservableObject {
    private struct InternalStartupDevice {
        let host: String
        let port: String
        let remark: String

        var serial: String { "\(host):\(port)" }
    }

    private static let internalStartupDevices = [
        InternalStartupDevice(
            host: "33.230.81.195",
            port: "8080",
            remark: "详情页"
        ),
        InternalStartupDevice(
            host: "33.230.88.55",
            port: "8080",
            remark: "列表页"
        ),
    ]

    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var displayedSerials: [String] = []
    @Published private(set) var deviceRemarks: [String: String] = [:]
    @Published private(set) var deviceDeepLinks: [String: String] = [:]
    @Published private(set) var deviceCardWidths: [String: Double] = [:]
    @Published private(set) var launchingLinkSerials: Set<String> = []
    @Published private(set) var apkInstallStates: [String: APKInstallState] = [:]
    @Published private(set) var isRefreshing = false
    @Published var notice: String?
    @Published var errorMessage: String?

    let adbPath: URL?
    let serverPath: URL?

    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false
    private let displayedSerialsKey = "displayedDeviceSerials"
    private let deviceRemarksKey = "deviceRemarks"
    private let deviceDeepLinksKey = "deviceDeepLinks"
    private let deviceCardWidthsKey = "deviceCardWidths"

    init() {
        adbPath = ToolLocator.find("adb")
        serverPath = ToolLocator.findScrcpyServer()
        displayedSerials = UserDefaults.standard.stringArray(
            forKey: displayedSerialsKey
        ) ?? []
        deviceRemarks = UserDefaults.standard.dictionary(
            forKey: deviceRemarksKey
        ) as? [String: String] ?? [:]
        deviceDeepLinks = UserDefaults.standard.dictionary(
            forKey: deviceDeepLinksKey
        ) as? [String: String] ?? [:]
        deviceCardWidths = UserDefaults.standard.dictionary(
            forKey: deviceCardWidthsKey
        ) as? [String: Double] ?? [:]
    }

    var displayedDevices: [AndroidDevice] {
        displayedSerials.compactMap { serial in
            devices.first { $0.serial == serial }
        }
    }

    func isDisplayed(_ device: AndroidDevice) -> Bool {
        displayedSerials.contains(device.serial)
    }

    func toggleDisplayed(_ device: AndroidDevice) {
        if let index = displayedSerials.firstIndex(of: device.serial) {
            displayedSerials.remove(at: index)
        } else {
            displayedSerials.append(device.serial)
        }
        UserDefaults.standard.set(displayedSerials, forKey: displayedSerialsKey)
    }

    func removeFromDisplay(serial: String) {
        displayedSerials.removeAll { $0 == serial }
        UserDefaults.standard.set(displayedSerials, forKey: displayedSerialsKey)
    }

    func displayName(for device: AndroidDevice) -> String {
        deviceRemarks[device.serial] ?? device.name
    }

    func remark(for device: AndroidDevice) -> String {
        deviceRemarks[device.serial] ?? ""
    }

    func setRemark(_ remark: String, for device: AndroidDevice) {
        let value = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deviceRemarks.removeValue(forKey: device.serial)
        } else {
            deviceRemarks[device.serial] = value
        }
        UserDefaults.standard.set(deviceRemarks, forKey: deviceRemarksKey)
    }

    func deepLink(for device: AndroidDevice) -> String {
        deviceDeepLinks[device.serial] ?? ""
    }

    func setDeepLink(_ url: String, for device: AndroidDevice) {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deviceDeepLinks.removeValue(forKey: device.serial)
        } else {
            deviceDeepLinks[device.serial] = value
        }
        UserDefaults.standard.set(deviceDeepLinks, forKey: deviceDeepLinksKey)
    }

    func cardWidth(for device: AndroidDevice, default defaultWidth: CGFloat) -> CGFloat {
        deviceCardWidths[device.serial].map { CGFloat($0) } ?? defaultWidth
    }

    func setCardWidth(_ width: CGFloat, for device: AndroidDevice, persist: Bool) {
        deviceCardWidths[device.serial] = Double(width)
        if persist {
            UserDefaults.standard.set(deviceCardWidths, forKey: deviceCardWidthsKey)
        }
    }

    func resetCardWidth(for device: AndroidDevice) {
        deviceCardWidths.removeValue(forKey: device.serial)
        UserDefaults.standard.set(deviceCardWidths, forKey: deviceCardWidthsKey)
    }

    func isLaunchingLink(on device: AndroidDevice) -> Bool {
        launchingLinkSerials.contains(device.serial)
    }

    func apkInstallState(for device: AndroidDevice) -> APKInstallState? {
        apkInstallStates[device.serial]
    }

    func installAPK(_ apkURL: URL, on device: AndroidDevice) async {
        guard let adbPath else {
            errorMessage = environmentMessage
            return
        }
        guard apkURL.pathExtension.localizedCaseInsensitiveCompare("apk") == .orderedSame else {
            errorMessage = "请选择扩展名为 .apk 的 Android 安装包"
            return
        }
        guard apkInstallStates[device.serial] != .installing else { return }

        notice = nil
        errorMessage = nil
        apkInstallStates[device.serial] = .installing
        do {
            try await ADBService(executable: adbPath).installAPK(
                serial: device.serial,
                apkURL: apkURL
            )
            apkInstallStates[device.serial] = .succeeded
            errorMessage = nil
            notice = "\(apkURL.lastPathComponent) 已成功安装到 \(displayName(for: device))"
        } catch {
            apkInstallStates[device.serial] = .failed
            errorMessage = error.localizedDescription
        }
    }

    func openConfiguredLink(on device: AndroidDevice) async {
        guard let adbPath else {
            errorMessage = environmentMessage
            return
        }
        let url = deepLink(for: device)
        guard !url.isEmpty, !launchingLinkSerials.contains(device.serial) else {
            return
        }

        launchingLinkSerials.insert(device.serial)
        defer { launchingLinkSerials.remove(device.serial) }
        do {
            try await ADBService(executable: adbPath).openURL(
                serial: device.serial,
                url: url
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var environmentMessage: String? {
        guard adbPath == nil else { return nil }
        return "未找到 adb。请安装 Android Platform Tools，或通过 Homebrew 执行：brew install --cask android-platform-tools"
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await prepareInternalStartupDevices()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    private func prepareInternalStartupDevices() async {
        applyInternalStartupDefaults()
        guard let adbPath else { return }

        let service = ADBService(executable: adbPath)
        var failures: [String] = []
        for device in Self.internalStartupDevices {
            do {
                _ = try await service.connect(
                    host: device.host,
                    port: device.port
                )
            } catch {
                failures.append("\(device.remark)（\(device.serial)）：\(error.localizedDescription)")
            }
        }

        await refresh()
        if !failures.isEmpty {
            errorMessage = "内部设备预连接失败：\n" + failures.joined(separator: "\n")
        }
    }

    private func applyInternalStartupDefaults() {
        var remarksChanged = false
        var displayedDevicesChanged = false
        for device in Self.internalStartupDevices {
            if deviceRemarks[device.serial]?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ?? true {
                deviceRemarks[device.serial] = device.remark
                remarksChanged = true
            }
            if !displayedSerials.contains(device.serial) {
                displayedSerials.append(device.serial)
                displayedDevicesChanged = true
            }
        }
        if remarksChanged {
            UserDefaults.standard.set(deviceRemarks, forKey: deviceRemarksKey)
        }
        if displayedDevicesChanged {
            UserDefaults.standard.set(displayedSerials, forKey: displayedSerialsKey)
        }
    }

    func refresh() async {
        guard !isRefreshing, let adbPath else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let updated = try await ADBService(executable: adbPath).devices()
            devices = updated
            errorMessage = nil

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect(host: String, port: String) async -> Bool {
        guard let adbPath else {
            errorMessage = environmentMessage
            return false
        }

        do {
            notice = try await ADBService(executable: adbPath).connect(host: host, port: port)
            errorMessage = nil
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func pair(host: String, port: String, code: String) async -> Bool {
        guard let adbPath else {
            errorMessage = environmentMessage
            return false
        }

        do {
            notice = try await ADBService(executable: adbPath).pair(host: host, port: port, code: code)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func disconnect(_ device: AndroidDevice) async {
        guard let adbPath, device.connection == .network else { return }
        do {
            try await ADBService(executable: adbPath).disconnect(serial: device.serial)
            removeFromDisplay(serial: device.serial)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearMessages() {
        notice = nil
        errorMessage = nil
    }

}
