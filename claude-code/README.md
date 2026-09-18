# Claude-Code Wrapper

This wrapper lets me select between openai-compatible endpoints to connect my
agent to. It's a little hacky but it works.

I use lemonade-server, ollama, openrouter and copilot (via copilot-api).

## Copilot

Install any copilot-api wrapper for copilot and it will give you a local
openai-compatible port. The default is 4141 but can be overridden with the
--port option. Defaults to gpt-5.4-mini to save a few cents.

## Lemonade

Defaults to the lemonade-server port of 13305 and a Gemma4 model, since these
work quite well on 32G RAM + 8G GPU.

## Ollama

Defaults to the default ollama port of 11343 and qwen3-coder:30b (although
that's a tight fit on most laptops).

## OpenRouter

Defaults to the usual openrouter endpoint. To authenticate, set
OPENROUTER_AUTH_TOKEN in your environment to the token you want to use.
The model list for OpenRouter includes so many models, but many are forbidden
by the token. There are plans to improve this later.
