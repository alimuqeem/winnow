import os

/// `log stream --predicate 'subsystem == "com.alimuqeem.Winnow"'`
enum Log {
    static let app = Logger(subsystem: "com.alimuqeem.Winnow", category: "app")
    static let scan = Logger(subsystem: "com.alimuqeem.Winnow", category: "scan")
    static let photos = Logger(subsystem: "com.alimuqeem.Winnow", category: "photos")
}
