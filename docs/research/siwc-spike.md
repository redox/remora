# Sign in with ChatGPT spike findings

Date: 2026-11-20. Plan: ChatGPT Pro. Harness: `spikes/siwc` (`siwc-spike`). Verdict: GO. Login, model listing, streaming inference and token refresh all work end to end.

## Sign-in
- Flow per docs (`/siwc/token-sharing-open-source/sign-in`): loopback listener 127.0.0.1:1455, `client_id=dynamic_agent_client`, `agent_name_hint=Remora`, `ext_agent_host_id=urn:uuid:<v4>` persisted in `~/.config/remora-spike/host.json`, PKCE S256, fresh state/nonce.
- Callback params received: `client_id, code, iss, scope, state`. Issued client id: `oaiapp_…` (redacted).
- Granted scopes: `chatgpt.tokens.use.direct email offline_access openid profile resource.invoke` (includes the required `chatgpt.tokens.use.direct`).
- ID token checks done: JWT decode, iss, aud contains issued client_id, nonce, exp. JWKS signature NOT verified in the spike (jwks_uri `https://auth.openai.com/.well-known/jwks.json`, RS256). Plan 2 should verify it.
- Re-login (observed, second `login` run): the authorize URL used the saved issued `client_id=oaiapp_…` with `id_token_hint` and `login_hint=<email>` (the account email; no `agent_name_hint`). The user still had to approve in the browser (an interaction occurred; the docs say no consent screen is shown, so this is either the account selector or an approval step, not distinguished). Callback params were `code, iss, scope, state`: no `client_id`, so the retained id was used. ID token claim keys: at_hash, aud, auth_time, email, email_verified, exp, https://api.openai.com/auth, iat, iss, jti, name, nonce, sid, sub. Result `LOGIN OK` with the same client id and the same six scopes.

## Facts the brief did not mention (from docs, relied on)
- Token exchange AND refresh both need `resource=https://api.openai.com/v1` (form-encoded); refresh uses the issued client_id and omits `scope`.
- Token response includes `earliest_refresh_at` (epoch seconds, string). Observed: about 54 min after issuance for a 3600 s token (roughly expiry minus 6 min).
- Docs say refresh tokens rotate (new 30-day token each refresh; the 30-day lifetime is docs-only, not verified); refresh must be serialized per session and the replacement saved immediately. Refresh errors to treat as re-login: invalid_grant, invalid_refresh_token, token_expired, refresh_token_expired/invalidated/reused. `invalid_client`: fix client config.
- Pre-stream errors (401/403/503) have body `{"detail":"..."}`, not the `error` object. Stream/Responses errors use `error.code`: subscription_sharing_user_not_eligible 403, _usage_limit_exceeded 429, _usage_unavailable 503, _unsupported_capability 400, _route_not_supported 403, _invalid_user 401, _user_unavailable 503, chatpass_v2_scope_not_authorized 403, chatpass_v2_invalid_authorization_context 403. Usage-limit errors may also arrive as `response.failed` after streaming starts.
- Docs say function/custom tools must be in namespaces or `additional_tools`; unsupported request fields (temperature, max_output_tokens, previous_response_id, metadata, user, ...) must be omitted; system-role input items are rejected (use `instructions`). Not exercised by the spike except as below.
- Docs examples use inconsistent model slugs; always read `/v1/models`.

## Token lifetimes and refresh
- Access token `expires_in: 3600` (about 2.1 KB JWT). Refresh token about 211 chars, 30-day lifetime per docs, docs say rotating. Observed by code on two consecutive `refresh` runs: `response_had_refresh_token=true rotated=true` (new value differs from the old one, compared in code, values never printed) and `response_had_id_token=true`.
- `refresh` returned HTTP 200, `expires_in=3600`, same scopes; a following `ask` with the refreshed token succeeded.
- Credentials file: `~/.config/remora-spike/credentials.json`, 0600, directory 0700, atomic write.

## Models (`GET /v1/models`, visibility == "list", server order)
| slug | display name |
|---|---|
| gpt-6.2-sol | GPT-6.2-Sol |
| gpt-6.2-astra | GPT-6.2-Astra |
| gpt-6.1-terra | GPT-6.1 Terra |
| gpt-6.1-sol | GPT-6.1-Sol |
| gpt-6-astra | GPT-6-Astra |
| gpt-6-sol | GPT-6-Sol |
| gpt-6-luna | GPT-6-Luna |
| gpt-5.6-sol | GPT-5.6-Sol |
| gpt-5.6-terra | GPT-5.6-Terra |
| gpt-5.6-luna | GPT-5.6-Luna |

Non-listed (visibility hide): gpt-reserve, codex-auto-review. The response has no tier/size/speed metadata, so "fastest/smallest" is inferred. Codename guess: luna = small/fast, terra = mid, sol/astra = large. Measured in the matrix below, `gpt-5.6-luna` had the lowest latency (about 2.0 s first token, 2.2 s total for a 6-token reply). The inference is mine; no doc states it.

## ask (French reply, store:false, stream:true, `instructions: "Reply in French."`)
Reached `response.completed` with "Bonjour !". Event order: response.created, in_progress, output_item.added, content_part.added, output_text.delta, metadata, output_text.done, content_part.done, output_item.done, completed. Single runs, so noisy:
- gpt-5.6-luna (cheapest guess): ttft 2.96 s, total 3.30 s (another run 3.59 / 4.44 s)
- gpt-6.2-sol (first listed, assumed strongest): ttft 3.81 s, total 3.95 s (earlier run 3.67 s ttft)
Time to first token is about 2-4 s for every model, even for a one-word reply; plan UI around that.

## Probes (model gpt-5.6-luna)
| variant | result |
|---|---|
| baseline | ACCEPTED 200 |
| text.format json_schema strict | ACCEPTED 200, output `{"greeting":"Bonjour !"}` |
| reasoning effort=low | ACCEPTED 200 |
| reasoning effort=minimal | REJECTED 400 `unsupported_value`, param `reasoning.effort`: supported for luna are none, low, medium, high, xhigh, max |
| function tool in namespace, prompt "Say hello" | ACCEPTED 200, no tool call (not meaningful on its own) |
| plain function tool, prompt "Say hello" | ACCEPTED 200, no tool call (not meaningful on its own) |
| FORCED namespaced tool (`{"type":"namespace","name":"remora","description":...,"tools":[{"type":"function","name":"get_weather",...}]}`), "What's the weather in Paris? Use the tool." | ACCEPTED 200 with `tool_choice:"required"` and with default; `response.output_item.done` carried a `function_call` item with `namespace=remora`, `name=get_weather`, arguments `{"city":"Paris"}` |
| FORCED plain top-level function tool, same prompt | ACCEPTED 200 with `tool_choice:"required"` and with default; `function_call` item with no namespace, `name=get_weather`, arguments `{"city":"Paris"}` |
| image input (`input_image` data URL, 1x1 PNG) | ACCEPTED 200 (the model accepted and answered, "Rose" in one run and "Orange" in another; a 1x1 pixel is not a meaningful vision test, so only acceptance is established) |
| usage on `response.completed` | PRESENT: input_tokens, output_tokens, total_tokens, input_tokens_details.cached_tokens, output_tokens_details.reasoning_tokens, plus an `attribution` object with per-item and per-request-field token counts |

Reasoning omitted vs present, all 10 listed models (`matrix` subcommand, full error text captured): omitted = ACCEPTED on every model; `reasoning:{effort:"low"}` = ACCEPTED on every model; `"minimal"` = REJECTED 400 `unsupported_value` (param `reasoning.effort`) on every model. Exact supported lists from the error message:
- `low, medium, high, xhigh, max`: gpt-6.2-sol, gpt-6.2-astra, gpt-6.1-sol, gpt-6-astra
- `none, low, medium, high, xhigh, max`: gpt-6.1-terra, gpt-6-sol, gpt-6-luna, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna

Omitting `reasoning` is safe everywhere. Plan 2 must not send `minimal`. Only `low` was actually exercised as accepted; the other values are from the error text.

Latency matrix (ttft / total, seconds, single runs): luna models 1.95-2.7 / 2.15-2.9; sol, astra, terra 2.3-4.0 / 2.5-4.3. Differences are small relative to noise.

## gpt-6.1-terra (the user's chosen default model for Remora)
Chosen by the user, not by this spike. Results on `gpt-6.1-terra`, same harness:
- `ask` (French reply, completed both runs): ttft 3.63 s / total 3.84 s, and ttft 3.48 s / total 3.67 s. Slower to first token than luna (about 2-3 s) but similar to the sol models.
- json_schema strict: ACCEPTED 200, output `{"greeting":"Bonjour !"}`.
- Forced namespaced tool call (tool_choice required and default): ACCEPTED 200, `function_call` remora/get_weather, args `{"city":"Paris"}`.
- Forced plain function tool (tool_choice required and default): ACCEPTED 200, `function_call` get_weather, args `{"city":"Paris"}`.
- Image input (1x1 PNG data URL): ACCEPTED 200, answered "Noir." (acceptance only; a 1x1 pixel is not a vision test).
- Reasoning: omitted and `low` ACCEPTED; `minimal` REJECTED 400 `unsupported_value`. Supported efforts per the error text: `none, low, medium, high, xhigh, max`.

## Anything contradicting the docs
- Plain top-level function tool was accepted AND the model produced a `function_call` for it (docs: function tools must be namespaced or sent via `additional_tools`). Tool-result round-trip (sending `function_call_output` back) was not tested. Namespaced tools also work. Prefer namespaces to follow the docs.
- `minimal` reasoning effort (valid on older API models) is rejected on every model here.
- `earliest_refresh_at` is returned as an epoch value; the docs list the field without further detail. Observed offset (about 54 min after issue for a 3600 s token) is from one comparison and approximate.

## Plan 2 implications
- Treat `{"detail":...}` and `error.code` shapes separately; surface subscription_sharing_* codes.
- Refresh proactively at `earliest_refresh_at`; serialize and persist the rotated refresh token before using it.
- Verify the ID token signature against JWKS.
- Never send `minimal` reasoning; omit `reasoning` or use low/medium/high.
