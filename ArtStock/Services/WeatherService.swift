//
//  WeatherService.swift
//  ArtAssist — 美术生的工具箱
//
//  取当前温度与相对湿度，喂给 DryingModel。
//
//  ── 为什么用 API 而不是"解析天气预报网站" ──────────────────────
//  这是实测过的：现代天气站（中国天气网、中国气象局）的湿度数据是
//  **JS 在前端渲染**的，直接 HTTP 抓回来的 HTML 里根本没有那个数字
//  （实测两个站各 80 KB 左右，grep「湿度」一无所获）。
//  iOS App 里没有浏览器引擎，所以抓站这条路走不通。
//
//  Open-Meteo 免费、无需注册、无需 API Key（不需要在 App 里藏密钥，
//  这对一个要放进公开仓库的项目是硬要求），返回的是干净的 JSON。
//
//  ── 必须先说清楚的一件事 ─────────────────────────────────────
//  **室外天气的湿度不等于你画室里的湿度。**
//  空调、暖气、加湿器、门窗开关、旁边一个洗笔筒，都能让室内外差出
//  二三十个百分点。这个数据只能当**起点**，不是真值。
//  所以开始计时时允许用户手动修正 —— 那是这个功能准确性的关键一步，
//  不是可有可无的装饰。
//

import CoreLocation
import Foundation
import Observation

struct WeatherSnapshot: Equatable, Sendable {
    var temperatureC: Double
    var relativeHumidity: Double
    var fetchedAt: Date
    var placeName: String
    var sourceDescription: String

    /// 超过 90 分钟算旧。
    var isStale: Bool {
        Date.now.timeIntervalSince(fetchedAt) > 90 * 60
    }
}

enum WeatherError: LocalizedError {
    case locationDenied
    case locationUnavailable
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .locationDenied:
            return "定位权限被拒绝。可以到「设置 → 隐私与安全性 → 定位服务」里开启，或在设置里指定城市。"
        case .locationUnavailable:
            return "暂时取不到位置。稍后再试，或在设置里指定城市。"
        case .network(let message):
            return "网络请求失败：\(message)"
        case .badResponse:
            return "天气服务返回了无法解析的数据。"
        }
    }
}

@MainActor
@Observable
final class WeatherService {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)

        var isLoading: Bool { self == .loading }
    }

    private(set) var state: LoadState = .idle
    private(set) var snapshot: WeatherSnapshot?

    private let session: URLSession
    private let locationProvider = OneShotLocationProvider()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        // 天气是实时数据，不能用缓存糊弄。
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// 刷新。已有新鲜数据时直接复用。
    func refresh(force: Bool = false) async {
        if !force, let snapshot, !snapshot.isStale {
            state = .loaded
            return
        }

        state = .loading
        do {
            let coordinates = try await resolveCoordinates()
            let snapshot = try await fetch(latitude: coordinates.latitude,
                                           longitude: coordinates.longitude,
                                           placeName: coordinates.name)
            self.snapshot = snapshot
            state = .loaded
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }

    /// 取当前生效的天气；没有新鲜快照就现取。
    /// 供"开始计时"面板调用 —— 它必须拿到一组数字才能开局。
    func currentOrFetch() async throws -> WeatherSnapshot {
        if let snapshot, !snapshot.isStale { return snapshot }
        await refresh(force: true)
        if let snapshot { return snapshot }
        if case .failed(let message) = state {
            throw WeatherError.network(message)
        }
        throw WeatherError.badResponse
    }

    func invalidate() {
        snapshot = nil
        state = .idle
    }

    // MARK: - 坐标

    private struct Coordinates {
        var latitude: Double
        var longitude: Double
        var name: String
    }

    /// 用户设定了城市就优先用它 —— 尊重显式选择，也免去每次定位。
    private func resolveCoordinates() async throws -> Coordinates {
        if let city = WetnessPreferences.city {
            return Coordinates(latitude: city.latitude, longitude: city.longitude, name: city.name)
        }
        let location = try await locationProvider.currentLocation()
        return Coordinates(latitude: location.coordinate.latitude,
                           longitude: location.coordinate.longitude,
                           name: "当前位置")
    }

    // MARK: - 网络

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double
            let relative_humidity_2m: Double
        }
        let current: Current
        let timezone: String?
    }

    private func fetch(latitude: Double, longitude: Double, placeName: String) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { throw WeatherError.badResponse }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherError.network("HTTP 状态异常")
        }

        guard let decoded = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data) else {
            throw WeatherError.badResponse
        }

        return WeatherSnapshot(
            temperatureC: decoded.current.temperature_2m,
            relativeHumidity: decoded.current.relative_humidity_2m,
            fetchedAt: .now,
            placeName: placeName,
            sourceDescription: "Open-Meteo · \(decoded.timezone ?? "本地时区")"
        )
    }

    // MARK: - 城市检索（不想开定位时的替代）

    struct Place: Identifiable, Equatable, Sendable {
        var id: String { "\(name)|\(latitude)|\(longitude)" }
        var name: String
        var admin: String
        var country: String
        var latitude: Double
        var longitude: Double

        var displayName: String {
            [name, admin, country].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private struct GeocodingResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Result]?
    }

    /// 用城市名搜坐标。中文城市名可以直接搜。
    func searchPlaces(matching query: String) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: "zh")
        ]
        guard let url = components?.url else { throw WeatherError.badResponse }

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw WeatherError.network(error.localizedDescription)
        }

        guard let decoded = try? JSONDecoder().decode(GeocodingResponse.self, from: data) else {
            throw WeatherError.badResponse
        }

        return (decoded.results ?? []).map {
            Place(name: $0.name, admin: $0.admin1 ?? "", country: $0.country ?? "",
                  latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}

// MARK: - 一次性定位

/// 取一次当前位置就结束。
///
/// 独立成一个类是因为 CLLocationManager 必须由一个 NSObject 持有并实现
/// delegate 回调，混进 @Observable 类里会很难看。
@MainActor
final class OneShotLocationProvider: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var isRequesting = false

    override init() {
        super.init()
        manager.delegate = self
        // 算天气只需要城市级精度，没必要申请精确位置 —— 少要点权限更容易被同意。
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func currentLocation() async throws -> CLLocation {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            throw WeatherError.locationDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            // 上一次还没结束就再请求会直接失败，先把它收掉。
            if let existing = self.continuation {
                existing.resume(throwing: WeatherError.locationUnavailable)
            }
            self.continuation = continuation
            self.isRequesting = true

            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    private func finish(with result: Result<CLLocation, Error>) {
        guard isRequesting, let continuation else { return }
        isRequesting = false
        self.continuation = nil
        continuation.resume(with: result)
    }

    // MARK: Delegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.isRequesting else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                self.finish(with: .failure(WeatherError.locationDenied))
            case .notDetermined:
                break
            @unknown default:
                self.finish(with: .failure(WeatherError.locationUnavailable))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let location = locations.last {
                self.finish(with: .success(location))
            } else {
                self.finish(with: .failure(WeatherError.locationUnavailable))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // 定位服务被关掉时 CoreLocation 报 kCLErrorDenied，归到权限问题更好懂。
            if (error as? CLError)?.code == .denied {
                self.finish(with: .failure(WeatherError.locationDenied))
            } else {
                self.finish(with: .failure(WeatherError.locationUnavailable))
            }
        }
    }
}
