// MARK: - 天气管理（Open-Meteo 免费 API，无需 Key）
// 职责：一次定位取经纬度 → 拉取 7 天预报 → 提供当前/指定日期天气描述。
// 定位失败或网络失败时返回 nil，调用方自行隐藏天气 UI（不影响其它功能）。
import Foundation
import CoreLocation

struct DayWeather {
    let date: Date
    /// 天气描述（如"小雨"）
    let description: String
    /// SF Symbol 图标名
    let symbol: String
    let tempMax: Double
    let tempMin: Double
    /// 是否有降水（提醒带伞用）
    let rainy: Bool
}

enum WeatherManager {
    /// 最近一次成功定位的经纬度缓存（避免每次都问系统要定位）
    private static var cachedLocation: (lat: Double, lon: Double)? = nil

    // MARK: - 定位
    /// 取当前位置（异步，一次定位即停；成功后缓存并回写 UserDefaults）
    static func fetchLocation(completion: @escaping (Double, Double) -> Void) {
        // 有缓存直接用（经纬度短期内不变，冷启动后第一次才真正定位）
        if let c = cachedLocation {
            completion(c.lat, c.lon)
            return
        }
        // UserDefaults 里存过上次的定位也直接用（定位权限被拒时唯一来源）
        if let lat = StorageLocation.defaults.object(forKey: "weather.lat") as? Double,
           let lon = StorageLocation.defaults.object(forKey: "weather.lon") as? Double {
            cachedLocation = (lat, lon)
            completion(lat, lon)
            return
        }

        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.requestWhenInUseAuthorization()
        // 授权是异步的，这里轮询等待授权状态（最多 3 秒）
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            waited += 0.25
            let status = manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                timer.invalidate()
                manager.requestLocation()
            } else if waited > 3.0 {
                // 用户拒绝或未响应：放弃定位
                timer.invalidate()
            }
        }
        // 定位结果回调（delegate 需要强持有，用静态属性）
        locationDelegate.onLocation = { lat, lon in
            cachedLocation = (lat, lon)
            StorageLocation.defaults.set(lat, forKey: "weather.lat")
            StorageLocation.defaults.set(lon, forKey: "weather.lon")
            completion(lat, lon)
        }
        locationDelegate.onFail = { }
        manager.delegate = locationDelegate
        activeManager = manager
    }

    /// 强持有 CLLocationManager / delegate（局部变量会被释放导致回调丢失）
    private static var activeManager: CLLocationManager?
    private static let locationDelegate = LocationDelegate()

    private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
        var onLocation: ((Double, Double) -> Void)?
        var onFail: (() -> Void)?
        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let loc = locations.first else { onFail?(); return }
            onLocation?(loc.coordinate.latitude, loc.coordinate.longitude)
        }
        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            onFail?()
        }
        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let s = manager.authorizationStatus
            if s == .denied || s == .restricted { onFail?() }
        }
    }

    // MARK: - 拉取 7 天预报
    /// 拉取未来 7 天每日天气（异步回调；失败回调空数组）
    static func fetchDailyWeather(completion: @escaping ([DayWeather]) -> Void) {
        fetchLocation { lat, lon in
            let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&daily=temperature_2m_max,temperature_2m_min,weathercode&timezone=auto&forecast_days=7"
            guard let url = URL(string: urlStr) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                var days: [DayWeather] = []
                if let data = data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let daily = obj["daily"] as? [String: Any],
                   let times = daily["time"] as? [String],
                   let tMax = daily["temperature_2m_max"] as? [Double],
                   let tMin = daily["temperature_2m_min"] as? [Double],
                   let codes = daily["weathercode"] as? [Int] {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    for (i, timeStr) in times.enumerated() where i < codes.count && i < tMax.count && i < tMin.count {
                        if let date = formatter.date(from: timeStr) {
                            let w = describe(code: codes[i])
                            days.append(DayWeather(date: date, description: w.0, symbol: w.1,
                                                   tempMax: tMax[i], tempMin: tMin[i],
                                                   rainy: isRainy(code: codes[i])))
                        }
                    }
                }
                DispatchQueue.main.async { completion(days) }
            }.resume()
        }
    }

    // MARK: - WMO 天气代码 → 中文描述 / 图标
    private static func describe(code: Int) -> (String, String) {
        switch code {
        case 0:                       return ("晴", "sun.max")
        case 1, 2:                    return ("多云", "cloud.sun")
        case 3:                       return ("阴", "cloud")
        case 45, 48:                  return ("雾", "cloud.fog")
        case 51...57:                 return ("毛毛雨", "cloud.drizzle")
        case 61...65, 80, 81, 82:     return ("雨", "cloud.rain")
        case 66, 67:                  return ("冻雨", "cloud.sleet")
        case 71...77, 85, 86:         return ("雪", "cloud.snow")
        case 95...99:                 return ("雷阵雨", "cloud.bolt.rain")
        default:                      return ("未知", "cloud")
        }
    }

    private static func isRainy(code: Int) -> Bool {
        return (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code)
    }
}
