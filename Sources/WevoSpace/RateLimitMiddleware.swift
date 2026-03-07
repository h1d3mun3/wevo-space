//
//  RateLimitMiddleware.swift
//  WevoSpace
//
//  Created on 3/7/26.
//

import Vapor
import Foundation

/// Rate Limitingミドルウェア
/// IPアドレスごとにリクエスト数を制限します
final class RateLimitMiddleware: AsyncMiddleware {
    /// リクエスト履歴を保持する構造体
    private struct RequestHistory {
        var timestamps: [Date]
        var lastCleanup: Date
        
        init() {
            self.timestamps = []
            self.lastCleanup = Date()
        }
        
        /// 期限切れのタイムスタンプを削除
        mutating func cleanup(window: TimeInterval) {
            let now = Date()
            let cutoff = now.addingTimeInterval(-window)
            timestamps.removeAll { $0 < cutoff }
            lastCleanup = now
        }
        
        /// 現在のウィンドウ内のリクエスト数を取得
        func count(within window: TimeInterval) -> Int {
            let now = Date()
            let cutoff = now.addingTimeInterval(-window)
            return timestamps.filter { $0 >= cutoff }.count
        }
        
        /// 新しいリクエストを記録
        mutating func add() {
            timestamps.append(Date())
        }
    }
    
    /// IPアドレスごとのリクエスト履歴
    private var histories: [String: RequestHistory] = [:]
    
    /// アクセス制御用のロック
    private let lock = NSLock()
    
    /// 許可するリクエスト数
    private let maxRequests: Int
    
    /// 時間窓（秒）
    private let windowSeconds: TimeInterval
    
    /// クリーンアップ間隔（秒）
    private let cleanupInterval: TimeInterval
    
    /// 最後のグローバルクリーンアップ時刻
    private var lastGlobalCleanup: Date
    
    /// イニシャライザ
    /// - Parameters:
    ///   - maxRequests: 許可する最大リクエスト数（デフォルト: 60）
    ///   - windowSeconds: 時間窓（秒）（デフォルト: 60秒 = 1分）
    ///   - cleanupInterval: クリーンアップ間隔（秒）（デフォルト: 300秒 = 5分）
    init(maxRequests: Int = 60, windowSeconds: TimeInterval = 60, cleanupInterval: TimeInterval = 300) {
        self.maxRequests = maxRequests
        self.windowSeconds = windowSeconds
        self.cleanupInterval = cleanupInterval
        self.lastGlobalCleanup = Date()
    }
    
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // クライアントのIPアドレスを取得（取得できない場合はデフォルトIPを使用）
        let clientIP = getClientIP(from: request) ?? "127.0.0.1"
        
        // Rate Limitチェック
        let (allowed, remaining, resetTime) = checkRateLimit(for: clientIP)
        
        if !allowed {
            request.logger.info("Rate limit exceeded", metadata: [
                "ip": .string(clientIP),
                "endpoint": .string(request.url.path)
            ])
            
            let response = Response(status: .tooManyRequests)
            response.headers.add(name: "X-RateLimit-Limit", value: "\(maxRequests)")
            response.headers.add(name: "X-RateLimit-Remaining", value: "0")
            response.headers.add(name: "X-RateLimit-Reset", value: "\(Int(resetTime.timeIntervalSince1970))")
            response.headers.add(name: "Retry-After", value: "\(Int(resetTime.timeIntervalSinceNow))")
            
            let errorResponse = ErrorResponse(
                error: true,
                reason: "レート制限を超えました。しばらく待ってから再試行してください。"
            )
            try response.content.encode(errorResponse)
            
            return response
        }
        
        // リクエストを通過させる
        let response = try await next.respond(to: request)
        
        // Rate Limitヘッダーを追加
        response.headers.add(name: "X-RateLimit-Limit", value: "\(maxRequests)")
        response.headers.add(name: "X-RateLimit-Remaining", value: "\(remaining)")
        response.headers.add(name: "X-RateLimit-Reset", value: "\(Int(resetTime.timeIntervalSince1970))")
        
        return response
    }
    
    /// クライアントのIPアドレスを取得
    private func getClientIP(from request: Request) -> String? {
        // プロキシ経由の場合は X-Forwarded-For ヘッダーをチェック
        if let forwardedFor = request.headers.first(name: "X-Forwarded-For") {
            // 複数のIPがある場合は最初のもの（クライアント）を使用
            let ips = forwardedFor.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let firstIP = ips.first, !firstIP.isEmpty {
                return firstIP
            }
        }
        
        // X-Real-IP ヘッダーをチェック
        if let realIP = request.headers.first(name: "X-Real-IP") {
            return realIP
        }
        
        // 直接接続の場合
        return request.remoteAddress?.ipAddress
    }
    
    /// Rate Limitをチェックして記録
    /// - Parameter clientIP: クライアントのIPアドレス
    /// - Returns: (許可するか, 残りリクエスト数, リセット時刻)
    private func checkRateLimit(for clientIP: String) -> (allowed: Bool, remaining: Int, resetTime: Date) {
        lock.lock()
        defer { lock.unlock() }
        
        // グローバルクリーンアップ
        performGlobalCleanupIfNeeded()
        
        // 履歴を取得または作成
        var history = histories[clientIP] ?? RequestHistory()
        
        // 古いエントリをクリーンアップ
        history.cleanup(window: windowSeconds)
        
        // 現在のリクエスト数をカウント
        let currentCount = history.count(within: windowSeconds)
        
        // リセット時刻を計算（最も古いリクエストから windowSeconds 後）
        let resetTime: Date
        if let oldestTimestamp = history.timestamps.first {
            resetTime = oldestTimestamp.addingTimeInterval(windowSeconds)
        } else {
            resetTime = Date().addingTimeInterval(windowSeconds)
        }
        
        // 制限を超えているかチェック
        if currentCount >= maxRequests {
            histories[clientIP] = history
            return (false, 0, resetTime)
        }
        
        // リクエストを記録
        history.add()
        histories[clientIP] = history
        
        let remaining = maxRequests - (currentCount + 1)
        return (true, remaining, resetTime)
    }
    
    /// 定期的なグローバルクリーンアップ
    private func performGlobalCleanupIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastGlobalCleanup) > cleanupInterval else {
            return
        }
        
        // 古いエントリを削除
        let cutoff = now.addingTimeInterval(-windowSeconds * 2)
        histories = histories.filter { _, history in
            history.timestamps.contains { $0 >= cutoff }
        }
        
        lastGlobalCleanup = now
    }
}

/// エラーレスポンス用の構造体
private struct ErrorResponse: Content {
    let error: Bool
    let reason: String
}
