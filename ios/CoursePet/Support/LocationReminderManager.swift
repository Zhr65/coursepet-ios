// MARK: - 位置提醒（CoreLocation 地理围栏，只读定位不追踪轨迹）
// 场景：走近教学楼/宿舍等常用地点 → 自动查下一节课 → 本地通知"下节课是什么在哪"。
// 免签名无 APNs 的天花板：围栏依赖系统"始终"定位授权 + 系统后台唤醒；
// 用户手动上滑杀掉 App 后围栏失效（Apple 系统行为），重新打开 App 自动重建。
import Foundation
import CoreLocation
import UserNotifications

struct MonitoredPlace: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double = 200   // 米，教学楼/宿舍区尺度
}

enum LocationError: Error { case timeout }

final class LocationReminderManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationReminderManager()

    @Published private(set) var places: [MonitoredPlace] = []

    private let locationManager = CLLocationManager()
    private let storeKey = "location.places"
    private static let toggleKey = "settings.locationReminderEnabled"
    /// 一次性定位的挂起续体（requestLocation 是回调式，这里桥接成 async）
    private var pendingLocationContinuation: CheckedContinuation<CLLocation, Error>?

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var enabled: Bool {
        get { StorageLocation.defaults.object(forKey: Self.toggleKey) as? Bool ?? false }
        set { StorageLocation.defaults.set(newValue, forKey: Self.toggleKey) }
    }

    /// 冷启动 / 回前台调用：装载列表 + 按授权状态重建围栏（幂等，可重复调）
    func bootstrap() {
        places = loadPlaces()
        rebuildMonitoring()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            rebuildMonitoring()
        } else {
            stopAllMonitoring()
        }
    }

    func remove(at offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        persistPlaces()
        rebuildMonitoring()
    }

    /// 在当前位置添加提醒点（设置页"添加"按钮）：取一次定位 → 存列表 → 重建围栏 → 引导升级"始终"授权
    /// 返回 nil = 成功；返回字符串 = 用户能看懂的失败原因
    func addCurrentLocation(named name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "先给提醒点起个名字" }
        guard places.count < 5 else { return "提醒点最多 5 个，先删一个再加" }
        // 围栏后台唤醒需要"始终"授权：首次先要 WhenInUse（拿定位必需），随后引导升级
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            try? await Task.sleep(nanoseconds: 800_000_000)  // 等授权弹窗落定
        }
        let status = locationManager.authorizationStatus
        if status == .denied || status == .restricted {
            return "定位权限被关了：到 设置 → CoursePet 打开定位后重试"
        }
        do {
            let loc = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
                pendingLocationContinuation = cont
                locationManager.requestLocation()
                // 10 秒超时兜底：requestLocation 没回音时报错而不是永远挂起
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if let cont = pendingLocationContinuation {
                        pendingLocationContinuation = nil
                        cont.resume(throwing: LocationError.timeout)
                    }
                }
            }
            places.append(MonitoredPlace(name: String(trimmed.prefix(12)),
                                         latitude: loc.coordinate.latitude,
                                         longitude: loc.coordinate.longitude))
            persistPlaces()
            rebuildMonitoring()
            // 升级"始终"：用户拒绝也能添加成功，只是 App 被杀后围栏不再唤醒（如实降级）
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                locationManager.requestAlwaysAuthorization()
            }
            NotificationManager.requestAuthorization()
            return nil
        } catch {
            pendingLocationContinuation = nil
            return "没能拿到当前位置（室内信号差或定位服务未开）：到开阔处再试"
        }
    }

    // MARK: - 围栏管理
    private func rebuildMonitoring() {
        stopAllMonitoring()
        guard enabled, !places.isEmpty,
              locationManager.authorizationStatus == .authorizedAlways else { return }
        for place in places {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                radius: min(max(place.radius, 100), 500), identifier: place.id)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            locationManager.startMonitoring(for: region)
        }
    }

    private func stopAllMonitoring() {
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
    }

    // MARK: - 持久化
    private func loadPlaces() -> [MonitoredPlace] {
        guard let data = StorageLocation.defaults.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([MonitoredPlace].self, from: data)) ?? []
    }

    private func persistPlaces() {
        StorageLocation.defaults.set(try? JSONEncoder().encode(places), forKey: storeKey)
    }

    // MARK: - 进入围栏 → 下一节课提醒
    /// 每个提醒点每天最多提醒一次（UserDefaults 按日标记），防止反复进出围栏轰炸
    private func notifyNextClass(entering place: MonitoredPlace) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        let dayKey = f.string(from: Date())
        let doneKey = "geo.notified.\(place.id).\(dayKey)"
        guard !StorageLocation.defaults.bool(forKey: doneKey) else { return }
        let dm = DataManager.shared
        let (current, next) = ScheduleHelpers.currentAndNext(courses: dm.courses, at: Date())
        var body = ""
        if let c = current {
            body = "正在上课：《\(c.name)》到 \(c.endTime)，教室：\(c.location.isEmpty ? "未填" : c.location)"
        } else if let n = next {
            let mins = Int(n.startDate.timeIntervalSinceNow / 60)
            if mins <= 90 {  // 只提醒 90 分钟内的下一节，太远的等真走近再说
                let c = n.course
                body = "下一节：《\(c.name)》\(c.startTime) 开始（约 \(max(0, mins)) 分钟后），教室：\(c.location.isEmpty ? "未填" : c.location)"
            }
        }
        guard !body.isEmpty else { return }
        StorageLocation.defaults.set(true, forKey: doneKey)
        let content = UNMutableNotificationContent()
        content.title = "📍 已到\(place.name)附近"
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "coursepet_geo_\(place.id)_\(dayKey)", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))) { _ in }
    }

    // MARK: CLLocationManagerDelegate（放类体内：extension 访问不到 private 成员）
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        pendingLocationContinuation?.resume(returning: loc)
        pendingLocationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        pendingLocationContinuation?.resume(throwing: error)
        pendingLocationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let place = places.first(where: { $0.id == region.identifier }) else { return }
        notifyNextClass(entering: place)
    }
}
