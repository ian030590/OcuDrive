# 建置與驗證

## Windows 單檔

需要 Godot 4.7.1、Python（此開發預覽使用 3.14.7）及 PyInstaller。建置腳本只使用已安裝或本機 uv cache 內的 PyInstaller，不下載套件、不更動全機環境。

```powershell
python scripts/build_windows.py --godot 'C:\Program Files\Godot\Godot_v4.7.1-stable_win64.exe'
```

輸出 `dist/OcuDrive.exe`、SHA-256 與 `build-manifest.json`。主 EXE 內嵌 PCK 與獨立的 helper EXE，執行時不需要 Python。只有連接所選眼動裝置才抽取 helper 到使用者快取並啟動。抽取前後驗證 SHA-256；使用絕對路徑啟動，無 shell 命令拼接。

建議以官方、同版本的 Windows x86_64 release template 建置：

```powershell
python scripts/build_windows.py --godot 'C:\tools\Godot.exe' --template 'C:\tools\windows_release_x86_64.exe'
```

本機沒有 export template，離線 fallback 只修改 `build/godot-offline-template.exe` 的本機複本：驗證 PE header 與預留空間後，加入 Godot exporter 所需的 `pck` section，交由 Godot 寫入嵌入資源。原安裝引擎不變。這個宿主包含編輯器程式碼，檔案較大且沒有簽章，正式發佈宜改用官方 runtime template。格式依據：[Godot Windows exporter](https://github.com/godotengine/godot/blob/4.5/platform/windows/export/export_plugin.cpp) 的 `fixup_embedded_pck`。

## 完整 Sol 建置

**本次未取得原廠 SDK，不是完整 Sol 發行包。** PDF 指示從 Chronus Remote Browser 下載 SDK；不能以同名第三方 PyPI 套件替代。請在原廠支援的 Python 3.12 環境安裝原廠 wheel 與其全部相依，再安裝含 ArUco 的 OpenCV、NumPy 與 PyInstaller。

```powershell
# 在安裝好原廠 SDK 的 Python 3.12 環境執行
python scripts/build_windows.py --godot 'C:\tools\Godot.exe' --template 'C:\tools\windows_release_x86_64.exe' --require-sol
```

`--require-sol` 在找不到 ganzin 模組時會中止，避免把缺 SDK 的檔案當作完整版本。還須檢查 wheel metadata 所需的 av、websockets 等原生套件與授權；完成後必須用實機驗證 timestamp 欄位、場景與 gaze 同步、四角標記遮擋與轉頭。

## 自動測試

Godot GUI 二進位的外層 exit code 不足以判定腳本成功，須同時檢查日誌包含 PASS 且沒有 SCRIPT ERROR。沙箱中必須把 `--log-file` 指到可寫目錄，避免預設 AppData 日誌寫入失敗。

```powershell
python scripts/verify.py
```

涵蓋 TFF、事件、紀錄、loopback 時鐘同步、frame history、介面流程及獨立 EXE smoke。各測試使用明確的測試代碼／fixture，不會製造正式受試者眼動。

```powershell
python -m unittest discover -s tests -p test_bridges.py -v
```

瀏覽器校正流程測試另設定 `PLAYWRIGHT_MODULE` 指向本機 Playwright Node 套件、`PLAYWRIGHT_BROWSER` 指向本機 Chromium。推論 fixture 只驗證校正流程，不驗證相機或量測精度。

```powershell
python scripts/check_packaged.py
python scripts/security_scan.py --defender
```

封裝測試不開相機；以本機 UDP 驗證 helper、時鐘及停止，並檢查選 WebGazer 時未載入 Tobii DLL。弱掃含可重現的來源、HTTP 邊界、封裝內容與選用 Defender 檢查；沒有離線 CVE 資料庫就不宣稱通過 CVE 掃描。

## 手動硬體驗收

必須另驗實體攝影機、Tobii、Sol、手把與不同 DPI／多螢幕環境。校正、有效率、場景可見起點與實際顯示延遲仍需量測。程式的 AOI 停留 TFF 代理值沒有臨床效度或上路能力判定。
