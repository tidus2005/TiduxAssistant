@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac remote Web dashboard")
struct MacRemoteDashboardServerTests {
    @Test("Health checks support both direct and Hub API paths")
    func healthCheckAliases() async throws {
        let router = makeRouter(token: "correct-token")

        let direct = await router.response(for: request(method: "GET", path: "/health"))
        let hub = await router.response(for: request(method: "GET", path: "/api/health"))

        #expect(direct.status == 200)
        #expect(hub.status == 200)
        #expect(direct.body == hub.body)
        let payload = try MacRemoteDashboardJSON.decoder.decode(
            [String: String].self,
            from: hub.body
        )
        #expect(payload["status"] == "ok")
        #expect(payload["service"] == "codex-watch-pet-web")
    }

    @Test("The mobile page is public but state requires the Keychain token")
    func pageAndProtectedStatusBoundary() async throws {
        let router = makeRouter(token: "correct-token")

        let page = await router.response(for: request(method: "GET", path: "/"))
        #expect(page.status == 200)
        let pageText = String(decoding: page.body, as: UTF8.self)
        #expect(pageText.contains("移动办公模式"))
        #expect(pageText.contains("随行时长"))
        #expect(pageText.contains("过去 12 小时 · 每分钟"))
        #expect(pageText.contains("renderTemperatureHistory"))
        #expect(pageText.contains("文件同步"))
        #expect(pageText.contains("照片 / 视频"))
        #expect(pageText.contains("/api/files/upload/chunk"))
        #expect(pageText.contains("自动锁屏"))
        #expect(pageText.contains("/api/screen-lock"))
        let pageHeaders = String(decoding: page.headerData, as: UTF8.self)
        #expect(pageHeaders.contains("X-Frame-Options: DENY"))
        #expect(pageHeaders.contains("frame-ancestors 'none'"))

        let embeddedDebugPage = await router.response(for: request(
            method: "GET",
            path: "/",
            queryItems: ["embeddedDebugViewport": "440x860"]
        ))
        let embeddedHeaders = String(decoding: embeddedDebugPage.headerData, as: UTF8.self)
        #expect(embeddedHeaders.contains("X-Frame-Options: SAMEORIGIN"))
        #expect(embeddedHeaders.contains("frame-ancestors 'self'"))

        let unauthorized = await router.response(
            for: request(method: "GET", path: "/api/status")
        )
        #expect(unauthorized.status == 401)

        let authorized = await router.response(
            for: request(
                method: "GET",
                path: "/api/status",
                headers: ["authorization": "Bearer correct-token"]
            )
        )
        #expect(authorized.status == 200)
        let snapshot = try MacRemoteDashboardJSON.decoder.decode(
            MacRemoteDashboardSnapshot.self,
            from: authorized.body
        )
        #expect(snapshot.deviceName == "Test Mac")
        #expect(!String(decoding: authorized.body, as: UTF8.self).contains("correct-token"))
        #expect(router.isAuthorized(request(
            method: "GET",
            path: "/ws",
            headers: ["authorization": "Bearer correct-token"]
        )))
    }

    @Test("Screen-lock routes reuse the Hub-injected bearer boundary")
    func protectedScreenLockRouting() async {
        let router = MacRemoteDashboardRouter(
            token: "correct-token",
            snapshotProvider: { Self.snapshot() },
            actionHandler: { _ in
                MacRemoteDashboardActionResponse(
                    ok: true,
                    message: "ok",
                    snapshot: Self.snapshot()
                )
            },
            screenLockHandler: { request in
                .jsonObject(["method": request.method])
            }
        )

        let unauthorized = await router.response(for: request(
            method: "GET",
            path: "/api/screen-lock"
        ))
        #expect(unauthorized.status == 401)

        let authorized = await router.response(for: request(
            method: "POST",
            path: "/api/screen-lock",
            headers: ["authorization": "Bearer correct-token"]
        ))
        #expect(authorized.status == 200)
    }

    @Test("File routes share the same Hub-injected bearer boundary")
    func protectedFileRouting() async {
        let router = MacRemoteDashboardRouter(
            token: "correct-token",
            snapshotProvider: { Self.snapshot() },
            actionHandler: { _ in
                MacRemoteDashboardActionResponse(
                    ok: true,
                    message: "ok",
                    snapshot: Self.snapshot()
                )
            },
            fileHandler: { request in
                .jsonObject(["path": request.path])
            }
        )

        let unauthorized = await router.response(for: request(
            method: "GET",
            path: "/api/files"
        ))
        #expect(unauthorized.status == 401)

        let authorized = await router.response(for: request(
            method: "GET",
            path: "/api/files",
            headers: ["authorization": "Bearer correct-token"]
        ))
        #expect(authorized.status == 200)
        let payload = try? MacRemoteDashboardJSON.decoder.decode(
            [String: String].self,
            from: authorized.body
        )
        #expect(payload?["path"] == "/api/files")
    }

    @Test("A protected action reaches the shared two-switch controller boundary")
    func protectedActionRouting() async throws {
        let recorder = DashboardActionRecorder()
        let router = makeRouter(token: "correct-token", recorder: recorder)
        let body = try MacRemoteDashboardJSON.encoder.encode(
            MacRemoteDashboardActionRequest(
                action: .setTemporaryTwoHourSession,
                enabled: true
            )
        )

        let unauthorized = await router.response(
            for: request(method: "POST", path: "/api/action", body: body)
        )
        #expect(unauthorized.status == 401)

        let authorized = await router.response(
            for: request(
                method: "POST",
                path: "/api/action",
                headers: ["authorization": "Bearer correct-token"],
                body: body
            )
        )
        #expect(authorized.status == 200)
        let requests = await recorder.requests
        #expect(requests == [
            MacRemoteDashboardActionRequest(
                action: .setTemporaryTwoHourSession,
                enabled: true
            )
        ])
    }

    @Test("HTTP parsing waits for the declared body and rejects unsupported methods")
    func requestParsingBoundary() {
        let incomplete = Data(
            "POST /api/action HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}".utf8
        )
        #expect(MacRemoteDashboardHTTPRequest.parse(incomplete) == .incomplete)

        let complete = Data(
            "POST /api/action HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8
        )
        guard case .complete(let parsed) = MacRemoteDashboardHTTPRequest.parse(complete) else {
            Issue.record("Expected a complete request")
            return
        }
        #expect(parsed.path == "/api/action")
        #expect(parsed.body == Data("{}".utf8))

        let unsupported = Data("DELETE / HTTP/1.1\r\n\r\n".utf8)
        guard case .invalid = MacRemoteDashboardHTTPRequest.parse(unsupported) else {
            Issue.record("Expected an invalid request")
            return
        }
    }

    private func makeRouter(
        token: String,
        recorder: DashboardActionRecorder = DashboardActionRecorder()
    ) -> MacRemoteDashboardRouter {
        MacRemoteDashboardRouter(
            token: token,
            snapshotProvider: { Self.snapshot() },
            actionHandler: { request in
                await recorder.append(request)
                return MacRemoteDashboardActionResponse(
                    ok: true,
                    message: "ok",
                    snapshot: Self.snapshot()
                )
            }
        )
    }

    private func request(
        method: String,
        path: String,
        queryItems: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> MacRemoteDashboardHTTPRequest {
        MacRemoteDashboardHTTPRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body
        )
    }

    nonisolated private static func snapshot() -> MacRemoteDashboardSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return MacRemoteDashboardSnapshot(
            schemaVersion: 4,
            deviceName: "Test Mac",
            observedAt: now,
            appStartedAt: now,
            appUptimeSeconds: 0,
            battery: .init(
                levelPercent: 80,
                isCharging: true,
                isOnExternalPower: true,
                estimatedMinutesRemaining: nil,
                displayName: "80% · 充电中"
            ),
            thermal: .init(
                state: "nominal",
                displayName: "正常",
                detail: "正常",
                temperatureCelsius: 72.5,
                temperatureSource: "芯片最高温",
                history: [.init(recordedAt: now, celsius: 72.5)]
            ),
            network: .init(
                kind: "wifi",
                displayName: "Wi‑Fi",
                isConnected: true,
                interfaceName: "en0",
                connectedAt: now,
                connectedDurationSeconds: 0,
                isExpensive: false,
                isConstrained: false,
                detail: "可用"
            ),
            codex: .init(
                isRunning: true,
                activeTaskCount: 1,
                lastActivityAt: now,
                detail: "1 个活跃任务"
            ),
            baselineClosedLid: .init(
                isOn: false,
                isEnabled: true,
                isBusy: false,
                status: "关闭",
                source: "macOS 普通睡眠"
            ),
            temporarySession: .init(
                phase: "off",
                isOn: false,
                isEnabled: true,
                isBusy: false,
                status: "关闭",
                expiresAt: nil,
                overridesBaseline: false
            ),
            hotspot: .init(
                targetName: "Test Hotspot",
                phase: "monitoring",
                status: "Wi‑Fi 路径正常",
                isNetworkAvailable: true,
                reconnectAttempt: 0,
                nextActionAt: nil
            ),
            remoteControl: .init(isConnected: true, status: "官方远控已连接"),
            screenLock: .init(
                batteryDisplaySleepMinutes: 30,
                powerAdapterDisplaySleepMinutes: 150,
                requiresPassword: true,
                passwordDelaySeconds: 0,
                isConfigurable: true,
                status: "电池 30 分钟 · 电源 150 分钟 · 立即需要密码"
            ),
            filesVersion: 1,
            activities: []
        )
    }
}

private actor DashboardActionRecorder {
    private(set) var requests: [MacRemoteDashboardActionRequest] = []

    func append(_ request: MacRemoteDashboardActionRequest) {
        requests.append(request)
    }
}
