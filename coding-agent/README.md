# Coding Agent Wrapper

This wrapper selects an OpenAI-compatible endpoint and model for Claude Code or
OpenCode. It defaults to Claude Code; use `--agent opencode` to launch OpenCode.
Arguments after `--` are forwarded to the selected agent.

For OpenCode, the wrapper generates a temporary config file and points
`OPENCODE_CONFIG` at it; the file is removed when OpenCode exits. OpenCode is
also launched with `--standalone`, so it runs against a private server that
actually reads the generated config: by default OpenCode connects to its
shared background service, which keeps the configuration it was started with
and ignores the `OPENCODE_CONFIG` of later clients - the selected model would
silently lose to whatever model that service was started with. Wrapper runs
therefore do not share session state with the background service. For
OpenRouter the file selects the requested model through OpenCode's builtin
OpenRouter provider, with `OPENROUTER_API_KEY` carrying the credential. For
other providers it selects the model through an OpenAI-compatible gateway,
while `OPENAI_BASE_URL` and `OPENAI_API_KEY` carry the endpoint and provider
credential in the child process environment. Model context is included when
reported by the provider or set with `--context`.

Supported providers are lemonade-server, Ollama, OpenRouter and Copilot (via
copilot-api). The wrapper requires `curl` and `jq`.

Models that do not support tool calling are never offered or accepted - the
coding agents cannot use them. OpenRouter models missing `tools` in
`supported_parameters` and Copilot models with `tool_calls` disabled are
filtered out unconditionally (there is no override). Lemonade and Ollama do
not report tool support, so no filtering happens for them.

## Copilot

Install any copilot-api wrapper for copilot and it will give you a local
openai-compatible port. The default is 4141 but can be overridden with the
--port option. Defaults to gpt-6-luna.

## Lemonade

Defaults to the lemonade-server port of 13305 and a Gemma4 model, since these
work quite well on 32G RAM + 8G GPU.

## Ollama

Defaults to the default Ollama port of 11434 and qwen3-coder:30b (although
that's a tight fit on most laptops).

## OpenRouter

Defaults to the usual OpenRouter endpoint and openai/gpt-6-luna. To authenticate,
set `OPENROUTER_AUTH_TOKEN` in your environment to the token you want to use.

The wrapper only ever offers and accepts models the key is permitted to run: it
reads the authenticated `/api/v1/models/user` listing, so `--list-models` and
`--select-model` show what the key may actually use, each with its context
window, ZDR-capable endpoint count and prompt/completion price per million
tokens. Models given with `--model` (and the default) are validated against
that list before the agent starts; if the catalog cannot be fetched - network
failure, rejected credentials, or a malformed response - the agent is not
started at all.

By default the wrapper assumes Zero Data Retention: it filters the listing to
models that have at least one ZDR-capable endpoint (per OpenRouter's ZDR
endpoint preview) and configures the agent to send `provider.zdr: true` on
every request (Claude Code via `CLAUDE_CODE_EXTRA_BODY`, OpenCode via the
builtin provider's `body` overlay). The ZDR column shows each model's
ZDR-capable endpoints in both modes - `N+Ms` means N ZDR endpoints plus M
safety-retention ones. Note that the ZDR preview only vouches for concrete
model IDs, so `~`-prefixed alias models are treated as non-ZDR by default.
Pass `--no-zdr` to drop both the filter and the per-request ZDR routing.
