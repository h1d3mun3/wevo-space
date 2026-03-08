import Vapor

/// レート制限ミドルウェア
/// クライアントIPごとにリクエスト数を制限します
actor RateLimitMiddleware: AsyncMiddleware {
    
    /// リクエスト履歴を保持する構造体
    struct RequestHistory {
        var timestamps: [Date]
        var windowStart: Date
    }
    
    /// レート制限情報
    struct RateLimitInfo {
        let allowed: Bool
        let remaining: Int
        let resetTime: Date
        let retryAfter: TimeInterval
    }
    
    /// 許可する最大リクエスト数
    private let requestLimit: Int
    
    /// 時間枠（秒）
    private let timeWindow: TimeInterval
    
    /// IPアドレスごとのリクエスト履歴
    private var histories: [String: RequestHistory] = [:]
    
    /// イニシャライザ
    /// - Parameters:
    ///   - requestLimit: 時間枠内で許可する最大リクエスト数（デフォルト: 100）
    ///   - timeWindow: 時間枠の長さ（秒）（デフォルト: 60秒）
    init(requestLimit: Int = 100, timeWindow: TimeInterval = 60) {
        self.requestLimit = requestLimit
        self.timeWindow = timeWindow
    }
    
    /// ミドルウェアのレスポンダー
    nonisolated func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // クライアントのIPアドレスを取得（取得できない場合はデフォルトIPを使用）
        let clientIP = getClientIP(from: request) ?? "127.0.0.1"
        
        // レート制限チェックと情報取得
        let info = await checkRateLimitAndGetInfo(for: clientIP)
        
        if !info.allowed {
            request.logger.warning("Rate limit exceeded for IP: \(clientIP)")
            
            // レート制限エラーのレスポンスを作成
            var response = Response(status: .tooManyRequests)
            response.headers.add(name: "X-RateLimit-Limit", value: "\(requestLimit)")
            response.headers.add(name: "X-RateLimit-Remaining", value: "0")
            response.headers.add(name: "X-RateLimit-Reset", value: "\(Int(info.resetTime.timeIntervalSince1970))")
            response.headers.add(name: "Retry-After", value: "\(Int(info.retryAfter))")
            response.headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            
            // エラーメッセージをJSONで返す
            let errorBody: [String: Any] = [
                "error": true,
                "reason": "レート制限を超えました。しばらく待ってから再試行してください。"
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: errorBody) {
                response.body = Response.Body(data: jsonData)
            }
            
            return response
        }
        
        // 次のミドルウェア/ハンドラーにリクエストを渡す
        var response = try await next.respond(to: request)
        
        // レート制限ヘッダーを追加
        response.headers.add(name: "X-RateLimit-Limit", value: "\(requestLimit)")
        response.headers.add(name: "X-RateLimit-Remaining", value: "\(info.remaining)")
        response.headers.add(name: "X-RateLimit-Reset", value: "\(Int(info.resetTime.timeIntervalSince1970))")
        
        return response
    }
    
    /// レート制限をチェックし、詳細情報を返します
    /// - Parameter clientIP: クライアントのIPアドレス
    /// - Returns: レート制限情報
    private func checkRateLimitAndGetInfo(for clientIP: String) async -> RateLimitInfo {
        let now = Date()
        
        // 既存の履歴を取得、なければ新規作成
        var history = histories[clientIP] ?? RequestHistory(timestamps: [], windowStart: now)
        
        // 時間枠外の古いタイムスタンプを削除
        history.timestamps.removeAll { now.timeIntervalSince($0) > timeWindow }
        
        // ウィンドウの開始時刻を更新
        if history.timestamps.isEmpty {
            history.windowStart = now
        } else if let oldest = history.timestamps.first {
            history.windowStart = oldest
        }
        
        // リセット時刻を計算
        let resetTime = history.windowStart.addingTimeInterval(timeWindow)
        
        // リクエスト数が制限を超えているかチェック
        if history.timestamps.count >= requestLimit {
            let retryAfter = resetTime.timeIntervalSince(now)
            return RateLimitInfo(
                allowed: false,
                remaining: 0,
                resetTime: resetTime,
                retryAfter: max(0, retryAfter)
            )
        }
        
        // 新しいタイムスタンプを追加
        history.timestamps.append(now)
        histories[clientIP] = history
        
        let remaining = requestLimit - history.timestamps.count
        
        return RateLimitInfo(
            allowed: true,
            remaining: remaining,
            resetTime: resetTime,
            retryAfter: 0
        )
    }
    
    /// クライアントのIPアドレスを取得します
    /// - Parameter request: リクエスト
    /// - Returns: IPアドレス（取得できない場合はnil）
    nonisolated private func getClientIP(from request: Request) -> String? {
        // プロキシ経由の場合、X-Forwarded-Forヘッダーから取得
        if let forwarded = request.headers.first(name: "X-Forwarded-For") {
            // 複数のIPがカンマ区切りで含まれる場合、最初のもの（クライアントIP）を使用
            let ip = forwarded.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            if let ip = ip, !ip.isEmpty {
                return ip
            }
        }
        
        // X-Real-IPヘッダーをチェック
        if let realIP = request.headers.first(name: "X-Real-IP") {
            return realIP
        }
        
        // 直接接続の場合、リモートアドレスから取得
        return request.remoteAddress?.ipAddress
    }
    
    /// 古い履歴をクリーンアップします（メモリ管理のため）
    /// 定期的に呼び出すことを推奨
    func cleanup() async {
        let now = Date()
        
        // 時間枠外のすべてのエントリを削除
        for (ip, history) in histories {
            let validTimestamps = history.timestamps.filter { now.timeIntervalSince($0) <= timeWindow }
            
            if validTimestamps.isEmpty {
                histories.removeValue(forKey: ip)
            } else {
                let windowStart = validTimestamps.first ?? now
                histories[ip] = RequestHistory(timestamps: validTimestamps, windowStart: windowStart)
            }
        }
    }
}
