# RAM 與 build size 優化研究

研究日期：2026-10-25（香港）。範圍是 macOS app、AutoFill、Safari extension、CLI 和 Auto-Type helper；網站與 promo 不在 app bundle 內。原研究只新增文件，沒有修改產品程式或正式 release 設定；§1 的後續實作與驗證結果附於本檔末。

## 結論與執行次序

1. **Build size 最有實證的是 `-Osize`：連同 dead stripping，app 減 8.39%，ZIP 減 4.74%。** 目前有效 Release 設定為 `-O`、whole-module、雙架構，而 `DEAD_CODE_STRIPPING=NO`。單開 dead stripping 只減 0.065 MiB（0.23%），可作設定整理，不能當作主要體積優化。`-Osize` 尚未量速度，不能直接宣布適合出貨。
2. **RAM 先限制圖示快取，再減少同步資料的多種常駐表示。** 前者改動較小；後者對大 vault 更值得投入，但涉及編輯相容性，必須分階段處理。
3. **大附件峰值另外處理。** 現在的整份 Data 流程允許 500 MiB 上傳，峰值可能遠高於檔案本身；應改為檔案與分段 I/O。
4. **AutoFill 採用較輕的讀取模型。** 填密碼不需要長期保留整個可編輯 vault、所有種類的 item 和 Send。
5. **以同版本、同資料集重新建立 RAM 基準。** 已有 138 MB 數字是舊版、優化過的 Debug demo；不能拿來判定目前正式版的改善幅度。

## 已量度與限制

環境：Xcode 27.1（27A9275）。原始碼為 `25d83c2` 加上研究開始前已有的 UI 未提交修改，包含新增的 SidebarAccordion。這是工作目錄快照，並非乾淨 commit 的重現結果。所有新 archive 都停留在 `build/research-size/`，未簽署、未安裝、未發布。

### 舊產物盤點（不能互相比較優化幅度）

以下是非 symlink 一般檔案的 logical bytes 加總，MiB = 1,048,576 bytes；不是 APFS 實際佔用、下載量或執行時 RAM。

| 產物 | 版本 | 主程式架構 | App bundle MiB | 主 executable MiB |
| --- | --- | --- | ---: | ---: |
| `build/Build/Products/Debug/Triwarden.app` | 0.3.0 | arm64 | 68.095 | debug dylib 52.441 |
| `build/Build/Products/Release/Triwarden.app` | 0.2.1 | x86_64 + arm64 | 66.272 | 48.626 |
| `build/release-check/T.xcarchive/Products/Applications/Triwarden.app` | 0.1.0 | x86_64 + arm64 | 22.832 | 12.300 |
| `/Applications/Triwarden.app` | 0.5.0 | x86_64 + arm64 | 32.487 | 17.372 |

版本、功能、架構及 stripping 不一致；尤其不能宣稱把 66 MiB 降到 23 MiB。Debug 的 `Triwarden` 是啟動殼，量大小時必須包含 `.debug.dylib`。

盤點時整個 `build/` 約 4.5 GiB，主要包括編譯中間檔、SDK module、測試、影像與多套 DerivedData，這是開發磁碟成本，不能當作交付 app 大小。刪除它不會降低使用者 RAM。

### 正在執行的已安裝 app：僅作觀察

對既有 PID 59740 使用 `footprint -p`，兩次讀取為 195 MB、230 MB，process lifetime peak 為 728 MB；第一次 `Malloc Small` dirty 約 145 MB。沒有控制當時畫面、資料量或操作，且它是已安裝 0.5.0，不是這次原始碼 build。**這不是 idle benchmark，也不能將 peak 歸因於任何一個功能或宣稱 leak。** 沒有停止或重新啟動該 app，也沒有讀取 vault 內容。

`ps` 的 RSS 當時約 252 MiB，和 phys_footprint 是不同指標，不能混用。原始分類快照留在 `build/research-size/installed-footprint.txt`（第二次取樣）。

### 同一工作目錄的 Release archive 實驗

基準 archive 已成功；包含 x86_64 + arm64，所有候選使用同一份工作目錄、同一 DerivedData 與 package checkout，`CODE_SIGNING_ALLOWED=NO`。基準 log 中可見真正的 `strip -D` 命令，因此單純加「移除 debug symbols」不是尚未使用的優化。

基準 app 為 29,671,601 bytes（28.297 MiB），以 `ditto -c -k --keepParent` 壓縮為 12.637 MiB。主 executable 16.796 MiB（59.4%）、AutoFill executable 3.214 MiB、Assets.car 2.111 MiB。下載 ZIP 會受壓縮與簽章影響；這是 unsigned 實驗值，並非 notarized 正式 DMG。

| 設定 | App MiB | ZIP MiB | 對基準的 app 減幅 |
| --- | ---: | ---: | ---: |
| 基準 `-O`，dead stripping NO | 28.297 | 12.637 | — |
| `-O`，dead stripping YES | 28.232 | 12.621 | 0.23% |
| `-Osize`，dead stripping YES | 25.924 | 12.038 | 8.39% |

Dead stripping 後主程式由 16.796 降至 16.748 MiB、AutoFill 由 3.214 降至 3.197 MiB；assets 未變。這個結果否定了「只打開 dead stripping 就能大幅縮小」的假設。

`-Osize` + dead stripping 的 app 為 27,183,313 bytes，ZIP 為 12,622,216 bytes；相對基準分別減 2.373 MiB（8.39%）和 0.599 MiB（4.74%）。主 executable 降至 14.983 MiB，AutoFill 降至 2.761 MiB；Assets.car 仍為 2.111 MiB。這是 compiler setting 收益，沒有移除功能或語言，但尚未執行功能 smoke、runtime benchmark 或簽署／更新驗證。

三組都回報 `ARCHIVE SUCCEEDED`。同一工作目錄的設定比較已完成；RAM 節省量、速度取捨和正式發布相容性不在這次實測結論內。

重現基準（不需重新產生 Xcode project，也不覆寫正式 dist）：

```bash
xcodebuild -project Triwarden.xcodeproj -scheme Triwarden \
  -configuration Release -derivedDataPath build/research-size \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution \
  -archivePath build/research-size/baseline.xcarchive \
  CODE_SIGNING_ALLOWED=NO archive
```

候選一使用另一個 archivePath，增加 `DEAD_CODE_STRIPPING=YES`；候選二在它的基礎上增加 `SWIFT_OPTIMIZATION_LEVEL=-Osize`。編譯記錄位於 `/tmp/triwarden-research-{build,strip,size}.log`；檔案加總／ZIP 分析工具留在 `build/research-size/analyze.py`，結果留在同目錄 `size-results.json`。本地 build 和 `/tmp` 不屬長期保存的研究附件，後續重現應重新執行命令。

## RAM：具體發現

### 1. IconStore：無容量上限，適合先做

位置：`App/Sources/Icons.swift`，`images`、`request`、`clear`、`thumbnail`；`App/Sources/AppModel.swift` 的 `lock`。

`images: [String: NSImage]` 會保留曾載入的 host，沒有 LRU、decoded byte budget 或 memory pressure eviction；全 vault lock 不會清除它。已經有 ImageIO 128 px thumbnail，這部分應保留。

128 × 128 × 4 約 64 KiB，1,000 個這種 decoded bitmap 約 62.5 MiB，5,000 個約 312.5 MiB；這只是滿尺寸 RGBA 的容量推算，不是實測，且未含物件、其他 image representation 或 allocator 成本。實際圖示可以更小。

建議試驗 8–16 MiB 的 decoded cost budget（起始實驗值），以 LRU 或 cost-aware NSCache 管理，保留 observation 更新機制；記憶體 eviction 不刪除加密磁碟快取。鎖定時可清掉 memory tier。`clear()` 現在連磁碟也清，應拆開使用目的。

`request` 建立的 Task 未被保存；`clear()` 時未取消，也沒有 generation 檢查，已在飛行的請求仍可能重新寫入 `images`。實作 eviction／停用圖示時，一併加入 Task tracking、取消、generation 和寫入前 enabled 檢查。`thumbnail` 失敗會 fallback 到 `NSImage(data:)`，因此 128 px 並非所有輸入的硬上限；宜限制接收 bytes／pixel dimensions，並為 fallback 保留同樣的上限。

驗證：相同 1,000／5,000 個 host 滾動後 idle，檢查 decoded cache cost、phys_footprint、cache hit rate；再測停用圖示及 lock 時有 in-flight request 的情況。

### 2. 同步與 session：多種表示同時存在

位置：`App/Sources/AccountSession.swift:load`、`Shared/VaultDecoder.swift:decode`、`Packages/VaultCore/Sources/VaultwardenAPI/CipherEditor.swift:rawCiphers`、`Shared/EquivalentDomains.swift:init(syncData:)`、`SyncPayload.swift:replacingCiphers`。

每個 unlocked session 保留完整 encrypted `payload`、typed `cipherIndex`、逐 cipher 的 `rawCiphers` 及解密後 `items`。decode 中還會有完整 typed SyncResponse、JSONSerialization object graph、新舊 items。equivalent domains 又重新 JSON parse 整個 payload；單 item reload 也會修改與重編碼整份 payload，再走 decode。既有 unchanged reuse 已減少重複解密，但未消除全量 parse。

分三步處理：

- 將 domains 放進 typed sync decode，避免為小欄位再建完整 Foundation JSON tree。
- 找出編輯、分享、SSH／passkey 所需的 cipher metadata，以最小索引替代不必要的長期模型；raw JSON 採有界快取或按需讀取。直接每次重新 parse 全 payload 會增加 CPU，需量度取捨。
- 有足夠量度證據才研究真正的增量儲存；網路拿一個 cipher 不等於目前程式的記憶體工作量只有一個 cipher。

不能直接用已知 typed model 重建所有 raw JSON：現有程式刻意保留未知欄位與 unsupported schema，縮減常駐資料不能破壞 round-trip 或送出遺失欄位的編輯。

`AppModel.rebuild` 會再合併與排序 `[VaultItem]`。Swift value type、String／Array 的 copy-on-write 不代表每份列表都深拷貝全部 secret；應量 item stride、array backing allocations 與實際 retained graph，不能簡化成「資料重複四次，所以 RAM 可減四倍」。

### 3. 大附件：峰值優先於 idle

位置：`AppModel.addAttachments`、`AccountSession.attachmentContents/addAttachment`、`VaultClient.downloadAttachment/uploadAttachment`、`TriCrypto/EncString.swift:EncArrayBuffer`。

上傳由 `Data(contentsOf:)` 讀整份檔案，封裝完整密文，再產生 multipart 或 HTTP body。下載由 `session.data` 收完整密文，再建立解密輸出。明文、密文、HTTP body 和 crypto 暫存的生命週期可重疊；實際倍率受 COW、Foundation 和 optimizer 影響，需要量測，不能固定宣稱 3× 或 4×。

方案：download-to-file／upload-from-file，分段 CBC 與 HMAC，multipart 寫入暫存檔；一開始可先避免重複 HTTP body buffer，逐步縮短 Data 生命週期。下載必須先驗證完整 MAC，才把已驗證的明文交給預覽／Save As；不能因 streaming 讓未驗證資料提前被消費。沿用 lock 時的暫存檔清理與錯誤路徑清理。

驗證：10／100／500 MiB synthetic 檔案，分別測上傳、下載、取消及錯誤，記錄 peak、完成後 30 秒 footprint 與 hash；先獨立操作，再評估多個附件並行。

### 4. AutoFill：保留完整 DecodedVault 的成本

位置：`AutoFill/AutoFillView.swift:AutoFillState.open`、`opened`。

Touch ID 可解鎖多個帳戶；每個 `opened` 保留 key 和完整 DecodedVault，然後才從整個 items 篩出 login。vault 內的 sync、raw ciphers、Send 和非 login item 對一般填密碼都不需要長期保留。另會再讀 cache 解析 domains。

建議將 read-only password／OTP／passkey assertion 路徑與 passkey registration 的寫入需求分開。一般填入只留所需 credential 與 matching metadata；registration 按需載入目標帳戶可編輯資料。不要假設兩個列表等於兩份深拷貝。

### 5. SwiftUI：先減少 allocation churn

位置：`VaultView.filtered`、`ItemSort.sorted`、`ItemColumn`、`AppModel.watchtowerIssueCount`。

`filtered` 多次 filter、排序，再由畫面及 `onChange(filtered.map(\.id))` 使用；列表會產生 sections／ListLine；sidebar badge 每次讀 `watchtowerIssueCount` 都建立 WatchtowerReport、issue arrays 與 duplicate grouping。這些更像 CPU／暫時配置成本，未證明是主要常駐 RAM 來源。

既有 LazyVStack 已做 virtualization。先用 Allocations 和 Time Profiler 量查詢、選取、sidebar 更新，再考慮一條 pass 篩選、預先算一次 query 正規化，以及以 vault revision + query + filter + sort + locale 作 invalidation 的 projection。Watchtower cache 需另考慮 breach 結果和日期變動。不要為每個畫面長期再存一套含 secret 的完整衍生列表。

### 6. Argon2 的必要記憶體

位置：`Packages/VaultCore/Sources/TriCrypto/KDF.swift`。

Argon2 記憶體由 account KDF 的 `memoryMiB` 決定，會轉成 KiB 傳入 reference implementation。這是安全參數，不能為了 app RAM 指標降低。應將 KDF 峰值與 vault idle 分開量，若未來增加並行解鎖，檢查同時執行的 memory-hard 工作數；目前不能將既有 728 MB peak 歸因於 Argon2。

## Build size：方案與取捨

`project.yml` 是正式來源；最終設定應寫回該檔的 Release configuration，而不是只手改生成的 pbxproj。

| 方向 | 判斷 | 驗證重點 |
| --- | --- | --- |
| `DEAD_CODE_STRIPPING=YES` | 已量度只減 0.23%；屬低收益設定整理 | App 與所有 helper／extension、runtime entry、crypto 與 passkey 行為 |
| `SWIFT_OPTIMIZATION_LEVEL=-Osize` | 連同 dead stripping 已實測減 8.39% app／4.74% ZIP；下一步驗 runtime | 大小、launch、KDF、sync、搜尋延遲；可能有速度取捨 |
| Release archive stripping | `STRIP_INSTALLED_PRODUCT=YES`，但一般 build 的 postprocessing 為 NO；要看 archive 的實際 strip command | 保存 dSYM，確認 symbolication；不要直接 strip 已簽署正式 app |
| Debug-only fixtures | Snapshot／self-test 部分已有 `#if DEBUG`；dead strip 可協助去掉不可達程式 | link map／section size，按實際殘留做處理 |
| 圖片與資源 | 舊 Release Assets.car 約 2.1 MiB，主 executable 約 48.6 MiB；先查 code 比較合理 | 使用 archive 實際檔案，不能拿 source PNG 或字串 catalog 大小當收益 |
| Sparkle | 舊 bundle 主要 updater binaries 約數 MiB，屬實際更新功能 | 不建議為數 MiB 移除自動更新；先量 bundle 分佈 |
| 拆 static library／dynamic framework | 暫不建議 | extension／CLI 是獨立程序；共享 source 不代表能消掉每個 executable 的全部程式碼 |
| 只發 arm64 | 可研究分架構 artifact，但會影響 Intel 分發 | 不適合作為無產品代價的優化；雙架構磁碟成本也不等於 runtime 載入兩個 slice |
| 本地化 | App 與 AutoFill 都需要自己的資源 | 未見證據足以支持犧牲語言支援 |

Apple 的 [build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference) 說明 dead stripping 與 `-Osize`；[app size 指引](https://developer.apple.com/documentation/xcode/doing-basic-optimization-to-reduce-your-app-s-size) 可作 release 檢查依據。這些設定的實際收益以本專案比較為準。

## 後續 RAM 實驗與驗收

先擴充 `scripts/bench.sh`：目前以 optimized Debug 的 200+ item demo 測試，idle memory 只取第一輪一次；即使 `RUNS=5` 也不是五次 memory median。demo 未經真實 encrypted sync decode，不能驗證 AccountSession 優化。圖示從遠端載入也會增加不確定性。結果用獨立 `--out`，避免覆蓋舊基準。

建議固定 synthetic encrypted vault（200、1,000、10,000 items；含長 notes、history、custom fields、org 與 passkey），使用本機固定圖示或分別關閉／開啟 icons。release-equivalent benchmark 可使用獨立 fixture target／受控 flag，不把 demo 入口加入出貨 binary。

每個候選做至少五輪相同操作：fresh process → unlock → idle 10/30 秒 → 全 sync → one-item reload → 全列表滾動 → 查詢／切頁 → lock → 再 idle 30 秒；另測 1／3 帳戶和 AutoFill。記錄每階段 phys_footprint、過程 peak、P50/P95 操作時間與 retained allocation。peak 是 process lifetime high-water mark，不可用前後 peak 相減作階段峰值。Leaks／Memory Graph 與 Allocations 用來區分 leak、cache、暫存和 allocator 留用頁面。

每項單獨比較，不混入新 UI 或改變資料集。RAM 收益未有受控量測前只列假設；cache budget 對圖示 own cost 應有可驗證上限，而不是承諾總 app RAM 固定下降多少。大小候選仍需 VaultCore tests、主程式／AutoFill／Safari／CLI／Auto-Type smoke，以及 Developer ID 簽署、notarization、Sparkle 更新驗證後才適合正式發布。unsigned archive 成功只證明可建置。

Apple 的 [memory use 指引](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use) 建議按具體功能定位增長；本研究的 RAM 排序是基於程式生命週期與資料結構推論，尚未有逐 allocation 的歸因證據。

## §1 實作：IconStore memory budget（2026-10-25）

本節只落實 RAM 第一項，沒有修改 `-Osize`、Release stripping 或其他優化。實作以最新 `origin/main`（`fb43a43`）為底；原研究的大小表仍是當時工作目錄的歷史數字。

- `App/Sources/IconStore.swift`：預設 **12 MiB** decoded bitmap budget，按實際 CGImage `bytesPerRow × height` 計 cost，超額先淘汰 LRU。讀圖命中會更新 recency；比整個 budget 大的單張圖片不會被保留。ImageIO 仍限制 128 px，解碼失敗不再 fallback 到可能保留原尺寸資料的 NSImage。
- `Icons.swift`：production wiring 沿用同一 Keychain service、加密 key、cache directory 和 keyed filename。cache 本體獨立，測試不讀寫使用者 Keychain、偏好設定或真實 vault。可見 row 的 cache presence 變動會重新觸發回填；鎖定／關門期間不開始新圖示載入。
- `clearMemory()`：換世代、取消 host／placeholder Tasks、清除圖片與記帳、負快取，**不刪 encrypted disk cache**。單帳戶 lock、全 vault lock 和 `clearVaultContents()` 都接入。Settings 停用圖示仍使用既有 `clear()`，明確清除兩層快取。
- 每個請求另有獨立 ID；每個 suspension 後驗證 cancellation、世代、ID 與 enabled。舊請求不能寫回圖片、disk 或 missing set；舊 defer 也不能移除同 host 的新請求。有效結果驗證與兩層寫入之間沒有 await。

### 驗證結果

`IconStoreTests` 是直接編譯 production cache 的 macOS logic-test scheme；CI 已加入同一組測試。

| 驗證 | 結果 |
| --- | --- |
| 1,000 個不同 host、128×128 RGBA 圖示，逐次檢查 budget | 最多保留 192 張，12,582,912 bytes = 12 MiB |
| 同樣圖示全數保留的 bitmap 容量對照 | 65,536,000 bytes = 62.5 MiB；比該對照少 50.5 MiB（80.8%） |
| LRU 命中更新、eviction 後 disk 回填 | 通過；沒有額外網路下載 |
| memory clear 後 disk 保留及離線回填 | 通過；disk entry 仍可用原 key 解密，檔名不包含 host |
| 舊 host Task 遲到、同 host 新請求仍在途 | 通過；舊結果不能寫回，不能移除新請求 |
| 等待 placeholder 時 clear、停用時 response 遲到 | 通過 |
| 超 budget 單圖、512→128 px 縮圖、無法 decode 的資料 | 通過 |
| 故意關閉 eviction 與 stale-result guards 的對照 | 兩個回歸測試出現四個 assertion failure；還原後 8 tests／0 failures |

上表是 cache 自己保留的 bitmap bytes；全數保留對照是相同 RGBA fixture 的容量計算，**不是舊 app 的完整 phys_footprint 實測**。12 MiB 不包含 NSImage／dictionary overhead、SwiftUI 正在持有的圖片、在途 response／decode 暫存，也不保證整個 app RAM 固定下降 50.5 MiB。未用真實 vault 作 UI／Activity Monitor 前後比較。

重跑（DerivedData 宜放在內置磁碟；本機外置磁碟上的 XCTest bundle 載入曾停滯）：

```bash
xcodegen generate -q
xcodebuild -project Triwarden.xcodeproj -scheme IconStoreTests \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/icon-tests CODE_SIGNING_ALLOWED=NO test
```

手動 UI 驗證要點（本次未操作使用者正在執行的 app）：用 synthetic／demo vault 滾動超過 192 個不同 host，再回捲確認從 disk 顯示；單帳戶及全帳戶 lock 後檢查 cache bytes 歸零、disk 檔案仍在；動畫鎖定時留意 pending request 不會重填；解鎖後可重新載入；Settings 停用圖示仍清除兩層。
