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

### Auto-start when all agents have valid configurations
When all three agent roles have valid, assigned configurations on launch, skip the manual "Start" button and begin the orchestration runtime automatically. Currently the user must always click Start even when nothing has changed.

### Copy button for channel messages
Text selection in the channel log is limited to one line at a time because each line is a separate SwiftUI `Text` view. Add a copy button (or context menu item) to each message row that copies the full message content to the clipboard, so users can easily grab multi-line output without fighting the selection model.

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

### Task update history
Store Brown's `task_update` messages as a `updates: [(Date, String)]` array on `AgentTask`. Currently these updates are only sent as ephemeral channel messages to Smith — they're lost on restart. Persisting them on the task gives a restarted Brown useful context about where the previous Brown left off.

**Design notes:**
- Only Brown's `task_update` calls are stored (not `message_brown` content)
- Full text retained (updates are already encouraged to be brief)
- Cap at last ~20 entries or ~4K character budget to avoid unbounded growth
- On task restart, include the update history in Brown's initial instruction so it knows prior progress
- Consider adding a source tag (`.brown` / `.smith`) if Smith is later given the ability to annotate tasks

### Remove implementation instructions from user-visible task descriptions
`CreateTaskTool` appends `"\n\nReport the detailed results to the user using task_complete."` to the task description at creation time (CreateTaskTool.swift:33). This implementation detail is persisted on the task and visible in the task list UI. The instruction should either be injected into Brown's initial message separately (not stored on the task), or moved into Brown's system prompt so it doesn't pollute user-facing task descriptions.

### Add `bash` tool for better environment availability
The current `shell` tool may not provide full PATH and environment variable availability. Add a `bash` tool that executes commands via `/bin/bash -c <arguments>`, which sources the user's shell profile and provides access to the full PATH and environment values that the user would have in an interactive terminal session. This improves reliability for commands that depend on tools installed via Homebrew, nvm, pyenv, etc.
