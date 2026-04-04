# Agent Smith — Roadmap

## Planned

### Save API keys to Keychain ✅
API keys (e.g. Anthropic, OpenAI-compatible provider keys) are currently stored in plain text (UserDefaults or configuration files). Move all API key storage to the macOS Keychain using the Security framework (`SecItemAdd`/`SecItemCopyMatching`). This improves security by keeping secrets out of plist files and app defaults exports.

**Implemented:** As part of the SwiftLLMKit package rework. `KeychainService` wraps `SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching`/`SecItemDelete` with service scoped to `<keychainServicePrefix>.<appBundleID>` and account = provider ID. API keys are stored/retrieved when adding/editing providers and read at request preparation time. The old plaintext `apiKey` field in `LLMConfiguration` is still used at the provider-send level but populated from Keychain at runtime.

### Model configuration rework — SwiftLLMKit package ✅
Switching models previously required 5-6 manual steps. Created a reusable Swift package (`SwiftLLMKit`) with a three-tier architecture: Providers (connection details + Keychain API keys), Models (metadata entities enriched with LiteLLM data), and Model Configurations (provider + model + user settings). The package also prepares URLRequests with provider-appropriate auth and base parameters.

**Key components:**
- `LLMKitManager` (@Observable main class) — provider/config/model CRUD, refresh lifecycle, validation, persistence
- `KeychainService` — Keychain wrapper for API key storage
- `ModelFetchService` — queries Ollama/Anthropic/OpenAI APIs for model lists
- `ModelMetadataService` — LiteLLM metadata cache with YYYYMMDD refresh gate and conditional HTTP (ETag/Last-Modified)
- `StorageManager` — file-based persistence in Application Support
- Tab-based SettingsView (Providers, Configurations, Agent Assignments, Audio)
- `ConfigValidationView` — startup gate verifying all agent configs are valid
- `AnthropicProvider` updated to support extended thinking (`thinkingBudget`)
- `AppDefaults` schema v2 with providers, model configurations, and agent assignments

### Auto-start when all agents have valid configurations ✅
When all three agent roles have valid, assigned configurations on launch, skip the manual "Start" button and begin the orchestration runtime automatically. Currently the user must always click Start even when nothing has changed.

**Implemented:** `AppViewModel.autoStartEnabled` (defaults to `true`, persisted in UserDefaults). `MainView.onChange(of: viewModel.hasLoadedPersistedState)` checks: if nickname set, all configs valid, and autoStartEnabled → calls `viewModel.start()` automatically.

### Copy button for channel messages ✅
Text selection in the channel log is limited to one line at a time because each line is a separate SwiftUI `Text` view. Add a copy button (or context menu item) to each message row that copies the full message content to the clipboard, so users can easily grab multi-line output without fighting the selection model.

**Implemented:** Copy button exists on hover. Known low-priority UX issue: the button disappears when the cursor moves toward it, making it difficult to click.

### Completed tasks must always include a final result
When a task reaches `completed` status, its `result` field should contain a clear, meaningful summary of what was accomplished. Currently, completed tasks can end up with an empty or missing result — making it hard for the user (and Smith) to understand what was done without digging through the channel log. Enforce that `accept_work` requires a non-empty result, and ensure Brown's `task_complete` call always provides one.

### Task-scoped context and state for resumability
All context and state related to a given task needs to be tied to the task itself. Currently, when a task is interrupted (e.g. the app is stopped mid-task), the task status resets to pending but all associated context — Brown's conversation history, partial work, tool call results — is lost. When the task is later resumed, agents must start from scratch with no memory of prior progress.

**Goal:** An incomplete task should carry enough state that it can be resumed where it left off rather than restarting. This includes Brown's conversation history for the task, any intermediate results or artifacts, and the point at which work was interrupted.

### Smith fails to read task details when resuming interrupted tasks ✅
When the system restarts with tasks that were in-progress (now reset to pending), Smith notifies the user and asks how to proceed. When told to run the task, Smith asks clarifying questions that are already answered in the task's title and description — e.g. asking "what text should I append?" when the task description says `Append the text "monkies rock" to the end of the file`. Smith should use the `get_tasks` tool (or equivalent) to read the full task details before attempting to execute, rather than relying only on the summary from the startup notification.

**Implemented:** Added a prominent guideline in Smith's system prompt (SmithBehavior.swift) instructing Smith to always call `list_tasks` before acting on any task. The existing belt-and-suspenders instruction in OrchestrationRuntime.swift's initial message was retained.

### Preserve agent inspector data after termination
When an agent is terminated, its conversation history and LLM turn records are lost because the `AgentActor` is deallocated. Users should be able to review what happened in a terminated agent's session — especially useful for debugging why Brown failed or what Jones flagged.

**Approach:** Before removing an agent from the `agents` dictionary in `terminateAgent` and `handleAgentSelfTerminate`, snapshot the agent's `contextSnapshot()` and `turnsSnapshot()` into a separate archive keyed by agent ID. Expose this archive via `OrchestrationRuntime` so the UI inspector can display historical sessions alongside live ones.

### Power assertion to continue running with lid closed ✅
Use `IOPMAssertion` (or `ProcessInfo.processInfo.beginActivity`) to prevent the system from sleeping while agents are actively working. The behavior should be power-source-aware:

- **On battery**: Assert for up to **15 minutes** after the user closes the lid or goes idle, then release the assertion and allow sleep.
- **On AC power**: Assert for up to **1 hour** after lid close / idle, then release.

The assertion should only be held while there are active tasks or running agents. When all tasks complete or are cancelled, release the assertion immediately. Monitor power source changes via `IOPSNotificationCreateRunLoopSource` to adjust the timeout dynamically if the user plugs in or unplugs mid-task.

**Implemented:** Created `PowerAssertionManager` actor using `IOPMAssertionCreateWithName` with `kIOPMAssertionTypePreventSystemSleep`. Uses a single 15-minute inactivity timeout (no power source differentiation — simplified from original plan). Assertion is acquired on `start()`, reset on every LLM call or user message, and released when both the 15-minute timer fires AND no active tasks exist. Released immediately on `stopAll()`. Wired into `OrchestrationRuntime` via `sendUserMessage` and `notifyProcessingStateChange`.

### Show specific error messages from LLM model-fetch failures
When the model-list refresh button in Agent LLM Configuration gets an error response, the UI only shows a generic message like "Server returned HTTP 401. Check the endpoint URL and API key." The actual error body from the server contains a more specific message (e.g. `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`) but this detail is discarded. Parse the response body and surface the server's actual error message in the UI so users can diagnose issues without needing to check the Xcode console.

**Example log output from a 401:**
```
[AgentConfig] Model fetch: GET https://api.anthropic.com/v1/models
[AgentConfig]   Headers: x-api-key: (redacted), anthropic-version: 2023-06-01
[AgentConfig]   Response: HTTP 401 body={"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CZGnZBBAcZALmp7nmj87a"}
```

### Task update history ✅
Store Brown's `task_update` messages as a `updates: [(Date, String)]` array on `AgentTask`. Currently these updates are only sent as ephemeral channel messages to Smith — they're lost on restart. Persisting them on the task gives a restarted Brown useful context about where the previous Brown left off.

**Implemented:** Brown's `task_update` calls are persisted on `AgentTask.updates` as `[(date: Date, message: String)]`. Displayed in task detail view.

### Remove implementation instructions from user-visible task descriptions
`CreateTaskTool` appends `"\n\nReport the detailed results to the user using task_complete."` to the task description at creation time (CreateTaskTool.swift:33). This implementation detail is persisted on the task and visible in the task list UI. The instruction should either be injected into Brown's initial message separately (not stored on the task), or moved into Brown's system prompt so it doesn't pollute user-facing task descriptions.

### Complete SwiftLLMKit migration — eliminate legacy LLMConfiguration ✅
The SwiftLLMKit package refactor is structurally complete but the runtime still uses the legacy `LLMConfiguration` struct in AgentSmithKit. `AppViewModel.resolvedLLMConfigs()` bridges between the two systems by converting SwiftLLMKit's `ModelConfiguration` into the old `LLMConfiguration` at startup. The actual LLM providers (`AnthropicProvider`, `OllamaProvider`, `OpenAICompatibleProvider`) consume only the legacy type.

**Goal:** Have the runtime providers consume SwiftLLMKit types directly (either `ModelConfiguration` + API key, or `PreparedRequest`), eliminating:
- The bridge code in `AppViewModel.resolvedLLMConfigs()`
- The legacy `LLMConfiguration` struct and its hardcoded defaults (`ollamaDefault`, `smithDefault`, `brownDefault`, `jonesDefault`)
- The redundant request-building logic in each provider (since `PreparedRequest` already handles auth headers and base body construction)

**Implemented:** All LLM provider implementations (`AnthropicProvider`, `GeminiProvider`, `OllamaProvider`, `OpenAICompatibleProvider`), conversation types (`LLMMessage`, `LLMResponse`, `LLMToolCall`, `LLMToolDefinition`), the `LLMProvider` protocol, and `LLMRequestLogger` moved into SwiftLLMKit. `LLMConfiguration` deleted entirely — providers now take `ModelConfiguration` + `ModelProvider` + a `@Sendable () -> String` closure that reads the API key from Keychain at point of use (no API key in any Codable struct). `ProviderType` renamed to `ProviderAPIType`. `LLMKitManager.makeProvider(for:)` factory resolves configuration → provider with keychain-based API key closure. `OrchestrationRuntime` takes pre-built providers at init. Default endpoint URLs moved to `ProviderAPIType.endpointPresets`. Remaining SwiftLLMKit improvements tracked in that package's own ROADMAP.

### Add `bash` tool for better environment availability ✅
The current `shell` tool may not provide full PATH and environment variable availability. Add a `bash` tool that executes commands via `/bin/bash -c <arguments>`, which sources the user's shell profile and provides access to the full PATH and environment values that the user would have in an interactive terminal session. This improves reliability for commands that depend on tools installed via Homebrew, nvm, pyenv, etc.

**Implemented:** `ShellTool` renamed to `BashTool` (`/bin/bash -c`). The old `shell` tool name removed. `BashTool` is now the sole command execution tool for Agent Brown.

### `get_task_details` tool ✅
Add a tool for both Smith and Brown to fetch full task details by ID, including title, description, commentary, progress updates, and summary.

**Implemented:** `GetTaskDetailsTool` available to both Smith and Brown via their respective behavior tool lists.

### Web Search tool
Given a query and optional `allowed_domains` and `blocked_domains` arrays, perform a web search. Only return results from `allowed_domains` (if non-empty) and exclude results from `blocked_domains` (if non-empty).

### Web Fetch tool
Given a URL and a prompt, fetch the URL content, convert to markdown, then run the prompt against the content to extract useful details. Useful for reading documentation, articles, and other web content.

### Grep tool ✅
Ripgrep-based content search tool for Agent Brown. Parameters: `pattern` (required, regex), `path` (required), `output_mode` (enum: files_with_matches / content), `glob` (file filter).

**Implemented:** Native Swift implementation using `NSRegularExpression` for content search and `GlobTool.globToRegex` for file filtering. Supports `files_with_matches` (default) and `content` output modes. Skips hidden files, binary files, files >1MB. Limits: 500 matching files, 1000 content lines. Glob patterns without `/` match filename only (ripgrep convention).

### Multimodal file_read — image support
`file_read` currently returns metadata only for image files (filename, dimensions, size). To support actual image reading, the tool result format needs to carry multimodal content (base64 image data as a content part) instead of plain text strings. This requires changes to how `AgentActor` passes tool results to the LLM — currently all tool results are `String`, but multimodal results need structured content blocks. Once supported, the 250K character cap should be raised or replaced with a byte-based limit appropriate for images (2-5MB).

### Task-scoped working directory for relative paths
Currently all tools (except `file_read`) require absolute paths. Relative paths would save significant tokens — paths like `/Users/andrew/Documents/ncc_source/cursor/agent-smith/AgentSmithPackage/Sources/AgentSmithKit/Tools/GrepTool.swift` are 100+ characters each, repeated across many tool calls per task. The approach: `CreateTaskTool` accepts an optional `working_directory` parameter. When set, all tools resolve relative paths against it. The working directory is immutable for the task's lifetime (no races). Tool output (glob/grep results) returns relative paths when a working directory is set, further reducing token usage. Full design documented in project memory.

### Streamline model configuration UI
The current Settings flow requires managing configurations as separate objects, then assigning them to agent roles across two different tabs. Redesign the UI to feel agent-centric — each agent/role has its own settings panel showing provider, model, temperature, max tokens, etc. directly. The underlying `ModelConfiguration` concept stays in the data model for reuse and persistence, but the UI abstracts it away so it feels like "adjusting Smith's settings" rather than "creating a configuration and assigning it."

### list_tasks search and semantic search
Add search capabilities to the `list_tasks` tool so Brown can find relevant tasks without retrieving the entire list. Support a `query` parameter for keyword matching against task titles and descriptions, and optionally a semantic search mode that uses the embedding service to find tasks by meaning rather than exact text. This would reduce token usage (no need to dump all tasks) and improve Brown's ability to find related prior work.

### Improve prior-task relevance in new task context
The current system injects prior task summaries into new tasks via semantic search against the task description. In practice this produces a fair number of irrelevant additions — the embedding similarity threshold is too loose, or the search query (the new task description) is too broad. Investigate: tighten the similarity threshold, limit to tasks from the same session or recent time window, weight completed tasks higher than abandoned ones, or let Smith curate which prior tasks to attach rather than auto-injecting. Goal: every prior task included in a new task's context should be genuinely useful, not noise.

### Auto-run next pending task ✅
Add a setting (persisted in UserDefaults) that controls whether the system automatically picks up the next pending task when the current one completes. When enabled, Smith or the orchestration runtime should detect task completion and immediately assign the next queued task to Brown without requiring user interaction. When disabled, the system idles after task completion and waits for the user. The setting should be exposed in the UI alongside the existing auto-start toggle.

**Implemented:** `AppViewModel.autoRunNextTask` (defaults to `true`, persisted in UserDefaults). Passed to `OrchestrationRuntime` at init, which forwards it to `SmithBehavior.systemPrompt(autoAdvanceEnabled:)` — the auto-advance instructions in Steps 6, the Key Constraints table, and the `create_task` docs are all conditional on the setting. `ReviewWorkTool` also includes advance guidance in its tool result when enabled. UI toggle added in Settings → Account tab under a "Behavior" section. Takes effect on next start (system prompt is generated at agent creation time).

### Skills — reusable prompt templates with arguments and embedded tool calls

Skills are saved, reusable prompt templates that generate fully-formed user messages to send to Smith. A skill encapsulates a repeatable workflow — instead of typing out a detailed prompt every time, the user defines the skill once (with variables for the parts that change) and invokes it with arguments.

#### Data model

A skill has the following fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | UUID | auto | Unique identifier |
| `name` | String | yes | Short name used for `/skill` invocation (no spaces; e.g. `code-review`, `summarize`) |
| `displayName` | String | yes | Human-readable name shown in the sidebar and detail view |
| `description` | String | yes | What the skill does, shown in the sidebar and detail view |
| `prompt` | String | yes | The prompt template. Supports variable substitutions (`{{var}}`) and embedded tool calls (`{{file_read:path}}`, `{{bash:command}}`). See "Prompt template syntax" below. |
| `arguments` | [SkillArgument] | no | Ordered list of arguments (required and optional). See "Arguments" below. |
| `createdAt` | Date | auto | Creation timestamp |
| `updatedAt` | Date | auto | Last modification timestamp |

**Arguments** (`SkillArgument`):

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | String | yes | Argument name, used in `{{name}}` substitutions and as the keyword in CLI invocation |
| `description` | String | yes | Shown in the run dialog and help text |
| `required` | Bool | yes | Whether the argument must be provided before the skill can run |
| `defaultValue` | String? | no | Default value if not provided. Only meaningful for optional arguments. |

#### Prompt template syntax

The prompt template is the core of a skill. It's a string that gets processed through two stages before being sent to Smith as a user message:

**Stage 1 — Variable substitution.** All occurrences of `{{variable_name}}` are replaced with the corresponding argument value. Substitution happens everywhere in the template, including inside `file_read` paths and `bash` commands (so `{{file_read:{{project_root}}/README.md}}` works — the inner `{{project_root}}` is substituted first, then the `file_read` is executed).

**Stage 2 — Embedded tool calls.** After variable substitution, the template is scanned for embedded tool calls:

- `{{file_read:/path/to/file}}` — Reads the file at the given path and replaces the token with the file's contents. Uses the same `FileReadTool` logic (respects blocked paths, size limits, etc.).
- `{{bash:command here}}` — Executes the command via `/bin/bash -c` and replaces the token with stdout. Uses the same `BashTool` logic (timeout, environment, etc.).

**Tool call failure semantics:** If any embedded tool call fails (file not found, command exits non-zero, blocked path, timeout, etc.), the entire skill invocation fails. The user sees an error message explaining which tool call failed and why. The prompt is NOT sent to Smith. This is intentional — a skill whose context-gathering steps fail should not produce a half-baked prompt.

**Escaping:** The double-brace `{{` / `}}` delimiters are chosen because single braces are common in code, JSON, and natural language. If the user needs literal `{{` in the output, they can use `\{{` to escape it. A trailing `\}}` escape is also supported. The backslash is consumed during processing.

**Processing order summary:**
1. Replace `\{{` → placeholder, `\}}` → placeholder
2. Substitute all `{{variable_name}}` with argument values
3. Execute all `{{file_read:...}}` and `{{bash:...}}`, replace with output
4. Restore escaped-brace placeholders to literal `{{` / `}}`
5. Result is the final prompt string sent to Smith as a user message

#### Invocation

Skills can be invoked three ways:

**1. `/skill` command in the message input field:**

- `/skill code-review` — If the skill has no required arguments (or all have defaults), runs immediately. If it has unfilled required arguments, opens the run dialog.
- `/skill code-review repo_url=https://github.com/foo/bar issue_number=42` — Provides arguments as keyword=value pairs. Positional arguments (without `=`) are assigned to required arguments in order. If all required arguments are satisfied, runs immediately; otherwise opens the run dialog with the provided values pre-filled.
- `/skill` with no name — Opens the skill sidebar/panel if not already visible.

**2. Run button on the skill sidebar:** Each skill in the sidebar has a small play button. Clicking it either runs immediately (no required args) or opens the run dialog.

**3. Run button on the skill detail view:** Same behavior as the sidebar run button.

**When a skill runs:** The generated prompt is sent to Smith as a user message (exactly as if the user typed it). Smith then creates a task, assigns Brown, etc. through the normal workflow. The skill system is purely a prompt-generation convenience — it does not bypass Smith or create tasks directly.

#### UI — Skill sidebar

The left panel currently has a task list. Add a segmented control or tab bar at the top to switch between "Tasks" and "Skills" views.

**Skill sidebar contents:**
- List of all skills, sorted by name
- Each row shows: skill `displayName`, a brief description (1 line, truncated), and a play (▶) button on the right
- Clicking a skill row opens the **skill detail view** (not the run dialog — the user can review before running)
- Clicking the play button opens the **run dialog** directly (or runs immediately if no required args)
- A "+" button at the top to create a new skill

#### UI — Skill detail view

Shown when the user clicks a skill in the sidebar. Could be a sheet, a panel, or an inline expansion — design to match the existing task detail view style.

**Contents:**
- Skill `displayName` and `name` (the `/skill` invocable name)
- Description (full text)
- Arguments list: for each argument, show name, description, required/optional badge, default value if any
- Prompt template preview: the raw template with `{{variable}}` markers visible, syntax-highlighted or at least in a monospaced font
- **Run** button — opens the run dialog (or runs immediately if no args needed)
- **Edit** button — opens the skill editor (see below)
- **Delete** button — with confirmation

#### UI — Run dialog (also serves as the "fill arguments" dialog)

A modal sheet that appears when a skill is invoked with unfilled required arguments. Also appears when the user clicks Run from the detail view (if there are arguments to fill).

**Contents:**
- Skill `displayName` at the top
- For each argument: a labeled text field, pre-filled with any provided value or the default value. Required arguments are visually marked (e.g., asterisk or red border if empty).
- A **prompt preview** section at the bottom showing the generated prompt after substitution (updated live as the user types). Embedded tool calls show as `[file_read: /path/...]` or `[bash: command...]` placeholders in the preview (they don't execute until the user confirms).
- **Cancel** button — dismisses without running
- **Run** button — enabled only when all required arguments are filled. Executes the template processing pipeline (substitution → tool calls → send to Smith). Shows a spinner during tool call execution. On failure, shows the error inline without dismissing.

#### UI — Skill editor

For creating and editing skills. A sheet or panel with fields for:

- `name` (the `/skill` invocable name) — validated: no spaces, no duplicates
- `displayName`
- `description` — multi-line text field
- `prompt` — large multi-line text editor (similar to the expanded editor for the message input). Should be tall enough to comfortably edit multi-paragraph prompts.
- **Arguments section:** a list of arguments with add/remove/reorder. Each argument has fields for `name`, `description`, `required` toggle, and `defaultValue` text field (shown only when not required, or always shown).
- **Save** and **Cancel** buttons

#### Persistence

Skills are stored as a JSON array in a file managed by `PersistenceManager`, similar to tasks and memories. File location: Application Support directory alongside existing persistence files. The `Skill` struct conforms to `Codable`.

A `SkillStore` (similar to `TaskStore`) manages in-memory state and persistence:
- CRUD operations
- `findByName(_ name: String) -> Skill?` for `/skill` command lookup
- `onChange` callback for UI refresh (same pattern as `TaskStore`)
- Owned by `AppViewModel` (not `OrchestrationRuntime` — skills are a UI/input concern, not an orchestration concern)

#### Implementation phases

**Phase 1 — Core data model and persistence:**
- `Skill` and `SkillArgument` structs (Codable)
- `SkillStore` with CRUD, persistence, and onChange callback
- Wire into `PersistenceManager` (load/save)
- Wire into `AppViewModel` (store ownership, published skill list)

**Phase 2 — Template processing engine:**
- `SkillRunner` or similar: takes a `Skill` + argument values, produces a final prompt string or an error
- Stage 1: variable substitution with `\{{` / `\}}` escape handling
- Stage 2: embedded `file_read` and `bash` execution (reuse existing tool logic or call the underlying functions directly)
- Clear error reporting: which variable is missing, which tool call failed and why

**Phase 3 — UI — Sidebar and detail view:**
- Segmented control on left panel (Tasks / Skills)
- Skill list view with play buttons
- Skill detail view with Run / Edit / Delete
- Skill editor (create + edit)

**Phase 4 — UI — Run dialog and `/skill` command:**
- Run dialog with argument fields, live prompt preview, Run/Cancel
- `/skill` command parsing in `UserInputView` or `AppViewModel.sendMessage()`
- Argument parsing: positional + keyword=value
- Integration: on successful run, send generated prompt via `runtime.sendUserMessage()`

#### Future additions (not part of initial implementation)

**1. Turn completed task into a skill.** After a task completes, offer a "Save as Skill" action. Use an LLM call (via the summarizer or a dedicated model config) to:
- Take the original task description and the completed result
- Generate a reusable prompt template
- Identify variable parts and suggest arguments (e.g., file paths, repo URLs, names that would change between invocations)
- Present the generated skill in the editor for the user to review and save

**2. Skill execution as agent tools.** Expose skills as tools available to Smith or Brown, so agents can invoke skills programmatically. This would allow meta-workflows where one skill's output feeds into another, or where Smith can decide which skill to run based on the user's request. Design TBD — needs careful thought about recursion depth, argument resolution, and whether tool-invoked skills skip the run dialog.

### Harden `isRetryableError` in TaskSummarizer
`TaskSummarizer.isRetryableError` currently matches on `error.localizedDescription` strings (e.g. `hasPrefix("HTTP 429")`, regex for `^HTTP 5\d\d`). This works because `LLMProviderError.httpError` formats its description as `"HTTP \(code): \(body)"`, but it's fragile — if error wrapping or formatting changes, retries silently stop working. Replace with direct pattern matching on `LLMProviderError.httpError(statusCode:body:url:)` to check the status code as an integer.

### Decouple SecurityEvaluator iteration counters
`SecurityEvaluator.evaluate` uses a combined `totalIterations` counter (capped at 25) that conflates file-read rounds with parse-failure retries. If Jones reads many files (the prompt now says "up to 20 at a time"), it can exhaust the iteration budget before getting a chance to retry a parse failure. Fix: track `fileReadRounds` and `retryCount` independently, each with its own cap (e.g., 20 file reads, 5 retries). The combined counter was introduced to prevent unbounded loops, but separate caps achieve the same goal without the coupling.

### Search: Cmd-F and Cmd-Shift-F
Two levels of search:

**Cmd-F — Find in current transcript.** Opens a search bar (similar to browser/IDE find-in-page) that highlights and jumps between matches in the visible channel log. Should support case-insensitive text matching at minimum; regex would be a bonus. The search bar should appear at the top of the channel log area with next/previous navigation and a match count indicator.

**Cmd-Shift-F — Global search across tasks, transcript, and prior transcripts.** A more powerful search that covers:
- Current transcript messages
- All tasks (titles, descriptions, updates, results)
- Prior session transcripts that are not currently loaded/visible

Results should be grouped by source (current transcript, task, prior session) with enough context to understand each match. Clicking a result navigates to it or opens it in context.

> **Note:** This implies we need a way to view prior transcripts. Currently, transcripts from previous sessions are persisted but only partially restorable. Consider adding a "Session History" or "Prior Transcripts" view (perhaps accessible from the sidebar or a dedicated tab) that lets the user browse, search, and read past session transcripts. This would also support the Cmd-Shift-F global search by providing the underlying data source and navigation target for prior-session matches.

### Tool post-call behavior flags system
`AgentActor.updatePostCallFlags` currently uses stringly-typed matching on tool names and exact return value strings to determine post-call behavior (should the agent idle? did it send a message? did it complete a task?). This is fragile — adding a new tool or changing a return string requires manual sync with the agent loop, and mistakes cause bugs like the task_update spam loop.

Replace with a structured system where tools declare their post-call semantics via a protocol property or return type:
- `PostCallBehavior.idle` — agent should wait for new input after this call (e.g., `message_user`, `reply_to_user`)
- `PostCallBehavior.continue` — agent should keep working (e.g., `file_read`, `bash`, `task_update`)
- `PostCallBehavior.awaitReview` — agent enters review-wait state (e.g., `task_complete`)
- `PostCallBehavior.restart` — agent loop should exit for a system restart (e.g., `run_task`)

The tool's `execute` method could return a `ToolResult` struct containing both the result string and the behavior flag, eliminating the need for string matching entirely. This also makes the agent loop's control flow self-documenting — each tool explicitly declares what should happen after it runs.

### Enhanced model stats popover in inspector
The model stats popover (shown when clicking the model name on an agent card) currently shows session-level stats computed from `LLMTurnRecord` data: LLM call count, tool call count, average latency, context resets, and token breakdowns. Future enhancements:
- **Per-task breakdown**: Show stats grouped by task, so the user can see which tasks consumed the most tokens.
- **Historical stats from UsageStore**: Aggregate across sessions using persisted `UsageRecord` data (not just the current session's `LLMTurnRecord` array). Show all-time totals, daily averages, and trends.
- **Cost estimation**: Use pricing data from `ModelMetadataService` to show estimated dollar costs alongside token counts. See "Token usage cost estimation" below.
- **Jones-specific stats**: For the security agent, show approval/denial/warning/abort counts from `EvaluationRecord` data (already available in `jonesEvaluationRecords`).
- **Latency histogram or percentiles**: Show p50/p95/p99 latency instead of just the average.

### Token usage cost estimation
Add estimated cost columns to the Token Usage analytics window. Use LiteLLM pricing data (already available via `ModelMetadataService`) to calculate per-turn and per-task cost estimates based on model ID and token counts. Display in the Overview, By Task, and By Model/Provider tabs. Handle cache pricing correctly (Anthropic cached reads are cheaper than uncached input).

## Blockers

### ~~SSH key not configured on this device~~ ✅ Resolved
Was misdiagnosed as an SSH key issue. The actual problem was corrupted SwiftPM caches. Fix: delete `~/.swiftpm`, `~/Library/org.swift.swiftpm`, and `~/Library/Caches/org.swift.swiftpm`, then quit and restart Xcode. May also need to verify the build succeeds — there may be pre-existing errors in `ProviderManagementView.swift` and `ModelConfigurationEditorView.swift` referencing `ProviderAPIType` that need investigation.
