//
// Copyright 2022 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

// TODO: sendable (remove preconcurrency)
#if SWIFT_PACKAGE
  @preconcurrency internal import GoogleUtilities_UserDefaults
#else
  @preconcurrency internal import GoogleUtilities
#endif // SWIFT_PACKAGE

/// CacheKey is like a "key" to a "safe". It provides necessary metadata about the current cache to
/// know if it should be expired.
struct CacheKey: Codable {
  var createdAt: Date
  var googleAppID: String
  var appVersion: String
}

/// SettingsCacheClient is responsible for accessing the cache that Settings are stored in.
protocol SettingsCacheClient: Sendable {
  /// Returns in-memory cache content in O(1) time. Returns empty dictionary if it does not exist in
  /// cache.
  var cacheContent: [String: Any] { get set }
  /// Returns in-memory cache-key, no performance guarantee because type-casting depends on size of
  /// CacheKey
  var cacheKey: CacheKey? { get set }
  /// Removes all cache content and cache-key
  func removeCache()
  /// Returns whether the cache is expired for the given app info structure and time.
  func isExpired(for appInfo: ApplicationInfoProtocol, time: Date) -> Bool
}

/// SettingsCache uses UserDefaults to store Settings on-disk, but also directly query UserDefaults
/// when accessing Settings values during run-time. This is because UserDefaults encapsulates both
/// in-memory and persisted-on-disk storage, allowing fast synchronous access in-app while hiding
/// away the complexity of managing persistence asynchronously.
final class SettingsCache: SettingsCacheClient {
  private static let cacheDurationSecondsDefault: TimeInterval = 60 * 60
  private static let flagCacheDuration = "cache_duration"
  private static let settingsVersion: Int = 1
  private enum UserDefaultsKeys {
    static let forContent = "firebase-sessions-settings"
    static let forCacheKey = "firebase-sessions-cache-key"
  }

  /// UserDefaults holds values in memory, making access O(1) and synchronous within the app, while
  /// abstracting away async disk IO.
  private let cache: GULUserDefaults = .standard()

  /// Converting to dictionary is O(1) because object conversion is O(1)
  var cacheContent: [String: Any] {
    get {
      return (cache.object(forKey: UserDefaultsKeys.forContent) as? [String: Any]) ?? [:]
    }
    set {
      cache.setObject(newValue, forKey: UserDefaultsKeys.forContent)
    }
  }

  /// Casting to Codable from Data is O(n)
  var cacheKey: CacheKey? {
    get {
      if let data = cache.object(forKey: UserDefaultsKeys.forCacheKey) as? Data {
        do {
          return try JSONDecoder().decode(CacheKey.self, from: data)
        } catch {
          Logger.logError("[Settings] Decoding CacheKey failed with error: \(error)")
        }
      }
      return nil
    }
    set {
      do {
        try cache.setObject(JSONEncoder().encode(newValue), forKey: UserDefaultsKeys.forCacheKey)
      } catch {
        Logger.logError("[Settings] Encoding CacheKey failed with error: \(error)")
      }
    }
  }

  /// Removes stored cache
  func removeCache() {
    cache.setObject(nil, forKey: UserDefaultsKeys.forContent)
    cache.setObject(nil, forKey: UserDefaultsKeys.forCacheKey)
  }

  func isExpired(for appInfo: ApplicationInfoProtocol, time: Date) -> Bool {
    guard !cacheContent.isEmpty else {
      removeCache()
      return true
    }
    guard let cacheKey = cacheKey else {
      Logger.logError("[Settings] Could not load settings cache key")
      removeCache()
      return true
    }
    guard cacheKey.googleAppID == appInfo.appID else {
      Logger
        .logDebug("[Settings] Cache expired because Google App ID changed")
      removeCache()
      return true
    }
    if time.timeIntervalSince(cacheKey.createdAt) > cacheDuration() {
      Logger.logDebug("[Settings] Cache TTL expired")
      return true
    }
    if appInfo.synthesizedVersion != cacheKey.appVersion {
      Logger.logDebug("[Settings] Cache expired because app version changed")
      return true
    }
    return false
  }

  private func cacheDuration() -> TimeInterval {
    guard let duration = cacheContent[Self.flagCacheDuration] as? Double else {
      return Self.cacheDurationSecondsDefault
    }
    Logger.logDebug("[Settings] Cache duration: \(duration)")
    return duration
  }
}
