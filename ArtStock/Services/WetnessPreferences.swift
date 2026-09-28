//
//  WetnessPreferences.swift
//  ArtAssist — 美术生的工具箱
//
//  颜料湿润计时器的偏好设置。
//
//  用 UserDefaults 而不是 SwiftData：这些是"设备级设置"
//  （每个颜料体系标定出来的常数、喷一下能维持多久、选定城市），
//  量极小、不需要查询、也不需要迁移。界面用 @AppStorage 绑同一个 key。
//

import Foundation

enum WetnessPreferences {

    private enum Key {
        static let calibrationPrefix = "wetness.calibration."
        static let minutesPerSpray = "wetness.minutesPerSpray"
        static let notificationsEnabled = "wetness.notificationsEnabled"
        static let defaultPaintSystem = "wetness.defaultPaintSystem"
        static let defaultClosure = "wetness.defaultClosure"
        static let cityName = "wetness.cityName"
        static let cityLatitude = "wetness.cityLatitude"
        static let cityLongitude = "wetness.cityLongitude"
    }

    private static var store: UserDefaults { .standard }

    // MARK: - 实测校准常数

    /// 取某颜料体系下用户实测校准的 K。nil 表示还没校准过。
    static func calibration(for system: PaintSystem) -> Double? {
        let key = Key.calibrationPrefix + system.rawValue
        guard store.object(forKey: key) != nil else { return nil }
        let value = store.double(forKey: key)
        // 0 或负数视为未校准，避免脏数据把模型带偏。
        return value > 0 ? value : nil
    }

    /// 写入校准值。传 nil 表示清除（回到默认起点常数）。
    static func setCalibration(_ value: Double?, for system: PaintSystem) {
        let key = Key.calibrationPrefix + system.rawValue
        if let value, value > 0 {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    /// 已校准过的颜料体系。
    static var calibratedSystems: [PaintSystem] {
        PaintSystem.allCases.filter { calibration(for: $0) != nil }
    }

    // MARK: - 喷雾标定

    /// 喷一下大约能维持多少分钟。0 表示未标定。
    static var minutesPerSpray: Double {
        get { store.double(forKey: Key.minutesPerSpray) }
        set { store.set(max(0, newValue), forKey: Key.minutesPerSpray) }
    }

    static var hasSprayCalibration: Bool { minutesPerSpray > 0 }

    // MARK: - 通知

    static var notificationsEnabled: Bool {
        get {
            // 默认开启：这个功能的价值就在提醒，默认关掉等于没做。
            if store.object(forKey: Key.notificationsEnabled) == nil { return true }
            return store.bool(forKey: Key.notificationsEnabled)
        }
        set { store.set(newValue, forKey: Key.notificationsEnabled) }
    }

    // MARK: - 默认选项

    static var defaultPaintSystem: PaintSystem {
        get {
            guard let raw = store.string(forKey: Key.defaultPaintSystem),
                  let value = PaintSystem(rawValue: raw) else { return .gouache }
            return value
        }
        set { store.set(newValue.rawValue, forKey: Key.defaultPaintSystem) }
    }

    static var defaultClosure: PaletteClosure {
        get {
            guard let raw = store.string(forKey: Key.defaultClosure),
                  let value = PaletteClosure(rawValue: raw) else { return .open }
            return value
        }
        set { store.set(newValue.rawValue, forKey: Key.defaultClosure) }
    }

    // MARK: - 城市

    /// 用户指定城市。设了就优先用它，不再请求定位。
    static var city: (name: String, latitude: Double, longitude: Double)? {
        get {
            guard let name = store.string(forKey: Key.cityName), !name.isEmpty,
                  store.object(forKey: Key.cityLatitude) != nil else { return nil }
            return (name, store.double(forKey: Key.cityLatitude), store.double(forKey: Key.cityLongitude))
        }
        set {
            if let newValue {
                store.set(newValue.name, forKey: Key.cityName)
                store.set(newValue.latitude, forKey: Key.cityLatitude)
                store.set(newValue.longitude, forKey: Key.cityLongitude)
            } else {
                store.removeObject(forKey: Key.cityName)
                store.removeObject(forKey: Key.cityLatitude)
                store.removeObject(forKey: Key.cityLongitude)
            }
        }
    }
}
