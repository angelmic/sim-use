# xd 2.0 Phase 1 — DeviceBackend 票務索引

> 計劃（SoT）：`/Users/rich/Desktop/RichMBP64/claude-skills-private/.claude/worktrees/xd-2.0-sim-use-xd-default/skills/xd/refactor-2.0-plan.md`（§5 Phase 1、§2 D6 方法論）
> P0 實測依據：同目錄 `skills/xd/refactor-phase0/P0-report.md`
> 工作區：本 worktree（branch `feat/device-backend`，基枝 feat/tvos-support @ 7d53f43）
> 紀律（D6）：每票 TDD（red→green→refactor）＋隨機 mutation spot-check（1/3 擲骰、票內至少一次，記錄在票檔）＋完成後 code-review 兩軸（Standards＋Spec=計劃對應節）→ 原子 commit。

| 票 | 主題 | blockers | 狀態 |
|---|---|---|---|
| T1 | AppiumCore 抽出（泛化 TVOSAppiumClient/Transport） | — | **done-with-deferred-e2e**（e2e Appium-path 待 Mac 修復後 T5 補跑） |
| T2 | PlatformRouter/DeviceResolver 認實機（雙 UDID 格式） | T1 | done |
| T3 | DeviceBackend verbs＋前置檢查（iOS 全套；tvOS 依版本分層） | T1,T2 | done |
| T4 | iOS device e2e suite（xcodegen playground fixture） | T3 | in_progress |
| T5 | 收尾（install 驗證、docs、sim 迴歸） | T1-T4 | blocked |

驗收指令基準：
- unit：`swift test`（worktree 根目錄）
- tvOS e2e（T1 迴歸關鍵）：`bash scripts/test-runner-tvos.sh`（需 booted Apple TV sim；UDID 用 `xcrun simctl list devices booted` 查）
- build：`swift build`

## Phase 1 開放項（收官時記錄）
1. **device paste gap**：`paste --bundle-id` 對實機欄位不生效（type 有效；欄位保持前值）——WDA pasteboard 路徑疑需 WDA-foreground 或另路。e2e 以 skip-with-reason 記錄（runner :359 附近）。後續票修。
2. T1 deferred tvOS e2e：sim Appium 已自癒，T5 補跑。
3. root RemoteXPC tunnel：非正確性前提（activate 語義已解導航持久），僅 WDA reuse 加速——要用時 sudo tunnel-creation。
