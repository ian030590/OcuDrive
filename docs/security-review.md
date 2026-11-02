# 本機資安弱掃紀錄

執行時間（UTC）：2026-10-31T18:49:25.413683+00:00

這是本專案原始碼、自己啟動的loopback服務與實際執行檔的離線檢查。未下載CVE資料庫，不能解釋為已通過相依套件CVE評估或第三方滲透測試。

## 檢查結果

- PASS `first_party_ast_and_secret_literals`：{"files_scanned": 33, "findings": []}
- PASS `native_sdk_load_path`：Tobii loads only bundled native/tobii_stream_engine.dll via resolved absolute path; kernel32 uses Windows KnownDLL name
- PASS `missing_cookie`：{"expected": 403, "actual": 403}
- PASS `host_rebinding`：{"expected": 403, "actual": 403}
- PASS `cross_origin_post`：{"expected": 403, "actual": 403}
- PASS `missing_origin`：{"expected": 403, "actual": 403}
- PASS `missing_csrf_token`：{"expected": 403, "actual": 403}
- PASS `non_json_post`：{"expected": 415, "actual": 415}
- PASS `malformed_json`：{"expected": 400, "actual": 400}
- PASS `bounded_nested_json_does_not_crash_handler`：{"expected": 200, "actual": 200}
- PASS `json_array`：{"expected": 400, "actual": 400}
- PASS `body_size_limit`：{"expected": 413, "actual": 413}
- PASS `cross_origin_preflight`：{"expected": 403, "actual": 403}
- PASS `fixed_static_path_allowlist`：{"/../native/tobii_stream_engine.dll": 404, "/%2e%2e/native/tobii_stream_engine.dll": 404, "/webgazer.js": 404, "/.git/config": 404, "/api/scene.jpg/../../bridge_helper.py": 404, "/C:/Windows/win.ini": 404, "/..\\native\\tobii_stream_engine.dll": 404}
- PASS `bootstrap_cookie_and_relative_redirect`：303 to /; cookie HttpOnly and SameSite=Strict; token value omitted
- PASS `authenticated_ui_and_security_headers`：{"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-eval'; connect-src 'self'; img-src 'self' blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; worker-src 'self' blob:; frame-ancestors 'none'; object-src 'none'; base-uri 'none'"}
- PASS `duplicate_host_rejected`：Raw duplicate Host request rejected with 403
- PASS `connection_bound_and_recovery`：{"active_handlers": 12, "handler_limit": 12, "excess_connections_rejected": 8, "authenticated_request_after_release": true, "socket_read_timeout_seconds": 2}
- PASS `loopback_bind`：HTTP and UDP sockets bind only 127.0.0.1
- PASS `package_directory_build/bridge/OcuDriveBridge.exe`：{"member_count": 35, "unexpected_sensitive_members": []}
- PASS `embedded_helper_matches_scanned_helper`：{"embedded_sha256": "c9959e5f766cd7c2bb1b2a7e4e0b38f337f17015db8f42e51b82a38c5d6adb4e", "helper_sha256": "c9959e5f766cd7c2bb1b2a7e4e0b38f337f17015db8f42e51b82a38c5d6adb4e"}
- PASS `package_directory_dist/OcuDrive.exe`：{"member_count": 30, "unexpected_sensitive_members": []}
- PASS `defender_build/bridge/OcuDriveBridge.exe`：{"exit_code": 0, "output": "Scan starting...\nScan finished.\nScanning C:\\Users\\ian\\Projects\\OcuDrive\\build\\bridge\\OcuDriveBridge.exe found no threats.", "sha256": "c9959e5f766cd7c2bb1b2a7e4e0b38f337f17015db8f42e51b82a38c5d6adb4e", "remediation_disabled": true}
- PASS `defender_dist/OcuDrive.exe`：{"exit_code": 0, "output": "Scan starting...\nScan finished.\nScanning C:\\Users\\ian\\Projects\\OcuDrive\\dist\\OcuDrive.exe found no threats.", "sha256": "0b3e6e08597752c87b0e2a471f4981f7917f1534e0d87569bff58eba2c96fb6f", "remediation_disabled": true}

## 掃描的實際產物

- `build/bridge/OcuDriveBridge.exe`：14085604 bytes，SHA-256 `c9959e5f766cd7c2bb1b2a7e4e0b38f337f17015db8f42e51b82a38c5d6adb4e`。
- `dist/OcuDrive.exe`：193192904 bytes，SHA-256 `0b3e6e08597752c87b0e2a471f4981f7917f1534e0d87569bff58eba2c96fb6f`。

## 無法驗證與保留限制

- 未取得完整Ganzin原廠SDK，不能評估其依賴、網路實作或Sol實機安全性。套件metadata必須保持SDK未內含的標記。
- 未以真實相機、Tobii、Sol及不同螢幕DPI進行精度與完整生命週期驗收。瀏覽器推論fixture只證明控制流程。
- WebGazer及其TensorFlow/model vendor bundle保留原始碼與授權，但本次未完成線上CVE比對；CSP的unsafe-eval用於該本機vendor runtime，connect-src仍限self。
- loopback憑證防止其他網站直接呼叫；不承諾防禦已取得本機使用者權限的惡意程序。session URL含短期token，量測紀錄不得保存該URL與token。
- Defender結果只適用上述hash與當時的本機引擎/定義；不表示檔案簽章或供應鏈認證。

## 重跑

`python scripts/security_scan.py --defender`

完整逐項HTTP結果、套件目錄與人工審閱的AST sink清單位於 `.tmp/security-scan.json`。重建產物後應重跑，新的報告會以新hash取代舊結果。
