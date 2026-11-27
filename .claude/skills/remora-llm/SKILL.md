---
name: remora-llm
description: Use before changing how Remora calls models — Sign in with ChatGPT auth, Responses API requests, model tiers and routing, a new job type or background job, prompts, chat tools and actions, prompt reminders, cost accounting and usage-limit handling. Also use when investigating a wrong memory answer in Remora chat or a connected MCP client. Covers SIWC request rules, adding a job end to end, untrusted prompt sections, tool trust levels and testing with FakeLLMClient.
---

# Models, prompts and chat tools

Remora has no backend. It signs in with ChatGPT (OAuth 2 + PKCE, loopback redirect) and calls the
OpenAI Responses API on the user's own plan. Before touching `LLM/Auth` or `LLM/Responses`, read
the design and its linked Sign in with ChatGPT documentation.
[Models and usage design](../../../docs/design.md#models-and-usage)

## Request rules (Sign in with ChatGPT)

- Inference is only `POST /v1/responses`, models only from `GET /v1/models` (`visibility == "list"`).
- Every request: `store: false`, `stream: true`, full history in `input`, system prompt in
  `instructions` (never a `role: "system"` item).
- Never send `temperature`, `top_p`, `max_output_tokens`, `previous_response_id`, `metadata`,
  `truncation`, `user` or `background`. Never send reasoning effort `minimal` (or `none`): nil
  means the model default. `ResponsesClient` enforces this; don't bypass it.
- Function tools work; hosted tools don't. Sign in with ChatGPT has no audio, transcription or
  embeddings endpoint. Dictation and meeting transcription share an optional project API key.
  For meetings, a saved key selects automatic language detection from verified audio segments.
  Without a key the recording uses Apple Speech with a local meeting language and model.
  [Writing and dictation design](../../../docs/design.md#writing-and-dictation)
- Success is a `response.completed` event. Usage-limit errors can arrive mid-stream as
  `response.failed` (`subscription_sharing_usage_limit_exceeded` /
  `..._usage_unavailable`); they are classified into `LLMError` and start the backoff.
- Tokens live in the Keychain only and are never logged; log request ids and error codes.

## Tiers and routing

- `Tier`: `onDevice` (Apple Foundation Models), `small` (default `gpt-6-luna`), `large` (default
  `gpt-6.1-terra`). Each `JobType` has a `defaultTier` (`LLM/Core/JobType.swift`); the user can
  override per job and per tier (`RoutingConfig`, setting `llm.routing`, pickers in Settings ›
  Account).
- Locally recorded meeting notes always use the on-device tier and have no routing picker.
  Other jobs default to a cloud tier. On-device is forced whenever privacy routing requires it.
- Reasoning effort: `low` for background work and the rewrite key; the model default for chat.

## Adding a model job

1. Add a `JobType` case with its raw value (snake_case) and `defaultTier`.
2. If it runs in the background, add a `JobKind` (`Storage/MemoryRecords.swift`) and its policy
   (`Memory/Scheduler/JobKind+Policy.swift`: when it may run, whether it may use the cloud), and register its runner in `MemoryRunners.make` or `ProactiveRunners.make`.
   `RunnerCoverageTests.everyJobKindHasExactlyOneRunner` fails otherwise: a kind without a runner
   would sit pending forever.
3. Usage-limit backoff (`MemorySettings.backoff`) is the only throttle on background work; there
   is no daily budget. Background jobs must pause on a usage-limit error and never retry in a
   loop. User-initiated work (rewrite, chat) is never held by the backoff.
4. Write the result through `DataGeneration.write(expected:)` (see the database skill).
5. Every call is recorded in `llm_calls` with tokens and an estimated cost from `PriceTable`
   (built-in prices, overridable by `model-prices.json` in the app's support folder). Keep
   Settings › Usage honest.
6. Add the job to `FeatureGuide` if the chat should be able to explain it, and tie any figure in
   the guide to the real constant with a test.

## Prompts

- Instructions say what to do; captured, clipboard, memory and tool text goes in tagged sections
  that the instructions call untrusted data. Escape every such string with
  `PromptEscaping.escape(_:tags:)` using the prompt's own tag list (`RewritePrompt.escape`,
  `ProactivePrompt.escape`).
- Never put a secret, a token or text from an excluded context into a prompt.
- Ask for structured output with a JSON schema when code parses the answer, and validate it.
  A malformed answer is a failed job, never a partial write.

## Chat tools and actions (`Assistant`)

- Each tool has a `ToolKind`: `untrustedRead` (returns captured or derived text, and taints the
  turn), `trustedRead` (Remora's own data only: usage, the built-in guide), or `action(risk)` with
  `ActionRisk.reversible` or `.confirm`.
- `ActionPolicy.needsConfirmation(risk, turnTainted:)`: a `confirm` action always asks; any action
  in a tainted turn asks. A turn is tainted from the start when it carries memory, the digest, an
  earlier summary, a replayed inbox turn or a stored tainted turn. Tool calls run one at a time.
- A new tool that returns anything a third party could have written is `untrustedRead`, full stop.
  A new action decides its risk, writes an undo token when it can be undone, reports its
  `ActionChange` so the app refreshes, and never removes an exclusion or turns privacy settings
  down without a confirmation.
- Prompt reminders run `ChatAgent.answer` with read-only tools and no confirmation UI, under the
  usage-limit backoff.

## Investigate a wrong memory answer

1. Recreate the disputed claim with fictional captures, dates and a question. Record what those
   sources establish and where the user saw the answer (Remora chat or an MCP client). Keep real
   captures, conversations and the user’s database out of fixtures and logs.
2. Follow the claim back to its source. Compare the capture with the wiki fact or summary that
   cites it. If the derived fact introduced the error, test that extraction or update path. For
   a user-stated correction to an existing wiki fact, exercise chat’s user-confirmed
   `correct_wiki` action and check that the old fact is no longer presented as current.
3. If the stored evidence is sound, replay the lookup on the affected surface. Check whether the
   decisive source is eligible under current exclusions and forget rules, where it ranks, and
   whether it survives the result limit and context assembly. For an MCP snapshot miss, add a
   question and its expected source IDs to the [recall benchmark](../../../CONTRIBUTING.md#recall-benchmark).
   A withheld source can make “I couldn’t verify that” the correct outcome.
4. If the right evidence reached the answerer, check what inference the source supports. For
   example, “Could we ship Friday?” establishes a proposal. In chat, inspect the instructions and
   tool output passed to `FakeLLMClient` and add a regression case at the first faulty step. For
   an external client, verify the MCP instructions and returned sources, and identify any answer
   behavior that still needs checking in that client. A scripted reply alone cannot demonstrate
   that a model will draw the right conclusion.

## Testing

- Use `FakeLLMClient` (`LLMTestSupport`): scripted steps, per-request scripts, `bySchema` outputs,
  and `requests` to assert exactly what was sent (instructions, escaped sections, no excluded
  text). Never call the real API from a test, and don't add a live smoke test without the user
  asking.
- For each prompt change, assert on the request: the untrusted sections are escaped, nothing
  forbidden is present, and the job type and tier are right.
