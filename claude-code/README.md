# Coding Agent Wrapper

This wrapper selects an OpenAI-compatible endpoint and model for Claude Code or
OpenCode. It defaults to Claude Code; use `--agent opencode` to launch OpenCode.
Arguments after `--` are forwarded to the selected agent.

For OpenCode, the wrapper generates a temporary config file and points
`OPENCODE_CONFIG` at it. The file selects the requested model through an
OpenAI-compatible gateway, while `OPENAI_BASE_URL` and `OPENAI_API_KEY` carry
the endpoint and provider credential in the child process environment. The
file is removed when OpenCode exits. Model context is included when reported
by the provider or set with `--context`.

Supported providers are lemonade-server, Ollama, OpenRouter and Copilot (via
copilot-api). The wrapper requires `curl` and `jq`.

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
The model list for OpenRouter includes so many models, but many are forbidden
by the token. There are plans to improve this later.
