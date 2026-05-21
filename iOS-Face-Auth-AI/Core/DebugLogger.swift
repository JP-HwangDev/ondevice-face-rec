//
//  DebugLogger.swift
//  iOS-Face-Auth-AI
//
//  디버그 로그 관리 싱글턴
//

import Foundation
import Combine
import SwiftUI

// MARK: - Log Level

enum LogLevel: String, CaseIterable, Sendable {
    case info    = "INFO"
    case warning = "WARNING"
    case error   = "ERROR"

    var color: Color {
        switch self {
        case .info:    return .blue
        case .warning: return .yellow
        case .error:   return .red
        }
    }

    var icon: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }
}

// MARK: - Log Category

enum LogCategory: String, CaseIterable, Sendable {
    case general  = "General"
    case network  = "Network"
    case database = "Database"
    case faceAuth = "FaceAuth"

    var icon: String {
        switch self {
        case .general:  return "text.alignleft"
        case .network:  return "wifi"
        case .database: return "cylinder.split.1x2"
        case .faceAuth: return "faceid"
        }
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let details: String?

    var formattedTimestamp: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Debug Logger

@MainActor
final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    @Published private(set) var logs: [LogEntry] = []

    private init() {}

    /// 로그 추가
    func log(
        level: LogLevel = .info,
        category: LogCategory = .general,
        message: String,
        details: String? = nil
    ) {
        let truncatedDetails = details.map { Self.truncateLargeArrays(in: $0) }
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            details: truncatedDetails
        )
        logs.append(entry)

        #if DEBUG
        print("[\(level.rawValue)][\(category.rawValue)] \(message)")
        if let d = truncatedDetails { print("  ↳ \(d)") }
        #endif
    }

    /// 로그 전체 삭제
    func clear() {
        logs.removeAll()
    }

    // MARK: - Large Array Truncation

    /// 큰 Float 배열을 포함한 문자열을 축약 표시
    /// e.g. "[0.12, -0.55, 0.33, ...]" with 512 elements → "[0.12, -0.55, 0.33, ... 509 more]"
    private static func truncateLargeArrays(in text: String) -> String {
        let maxDisplayElements = 3
        let threshold = 10

        // Match patterns like [0.12, -0.55, 0.33, 0.44, ...]
        let pattern = #"\[(-?\d+\.?\d*(?:,\s*-?\d+\.?\d*){2,})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        // Process in reverse order to preserve ranges
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let arrayContent = String(text[range])
            let elements = arrayContent.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            if elements.count > threshold {
                let preview = elements.prefix(maxDisplayElements).joined(separator: ", ")
                let remaining = elements.count - maxDisplayElements
                let truncated = "[\(preview), ... \(remaining) more]"
                if let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: truncated)
                }
            }
        }

        return result
    }
}
