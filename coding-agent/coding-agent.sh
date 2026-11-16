#!/bin/bash
#
# Invoke a coding agent with a selected model provider/model.
#
# Default models are configured for each provider that are reasonable in
# cost/performance, but can be selected.

# Provider settings used by the selected agent.
agent_anthropic_base_url=
agent_anthropic_auth_token=
agent_anthropic_api_key=
agent_anthropic_model=

# Command-line configuration
agent="claude-code"
agent_provider="copilot-api"
agent_model=""
agent_select_model=false
agent_list_models=false
agent_context=""
agent_host=""
agent_port=""

curl_extra_args=()
agent_models=()
agent_models_default_idx=

function usage()
{
  cat >&2 <<EOF
USAGE
  $0 [--agent AGENT] [--provider PROVIDER] [--help|-h]
     [--model MODEL | --select-model | --list-models]
     [--context CONTEXT] [--host HOST] [--port PORT]
     [-- AGENT_OPTIONS]

WHERE
  AGENT
    One of 'claude-code' or 'opencode'. Defaults to 'claude-code'.
  PROVIDER
    One of 'openrouter', 'copilot-api', 'lemonade' or 'ollama'. Defaults to
    'copilot-api'.
  MODEL
    A valid model ID from the provider. Use --list-models to find them. Defaults
    to a low-cost model on the provider chosen.
  CONTEXT
    Max context for the model selected. Must be a number - SI postfixes like
    'k' and 'M' are acceptable (e.g. 262144, 256k, 1M).
  HOST
    Hostname or IP address to connect to. For 'copilot-api', 'lemonade' and
    'ollama'. Defaults to '127.0.0.1'.
  PORT
    TCP port number to connect on. For 'copilot-api', 'lemonade' and 'ollama'.
    Defaults to the default port those local services would use.

Noting that --model, --select-model and --list-models are mutually exclusive.

EOF
  
  if [ $# -gt 0 ]; then
    echo "$*" >&2
    echo
    exit 1
  else
    exit 0
  fi
}

function check_agent()
{
  case "$1" in
    "claude-code"|"opencode")
      return
      ;;
    *)
      usage "E: Invalid agent '${1:-}'"
      ;;
  esac
}

function check_provider()
{
  case "$1" in
    "openrouter"|"copilot-api"|"lemonade"|"ollama")
      return
      ;;
    *)
      usage "E: Invalid provider '${1:-}'"
      ;;
  esac
}

function normalize_context()
{
  local raw_context="$1"

  [[ "$raw_context" =~ ^[1-9][0-9]*[kM]?$ ]] || return 1

  case "$raw_context" in
    *k) context_tokens=$((10#${raw_context%k} * 1024)) ;;
    *M) context_tokens=$((10#${raw_context%M} * 1048576)) ;;
    *)  context_tokens=$((10#$raw_context)) ;;
  esac
}

function sanitize_context()
{
  local context_tokens

  normalize_context "$agent_context" || usage "E: Bad context: '${agent_context}'"
  agent_context="$context_tokens"
}

function check_host()
{
  if [ -z "${1:-}" ]; then
    usage "E: Empty host specified."
  fi
}

function check_port()
{
  if ! [[ "${1:-}" =~ ^-?(0|[1-9][0-9]*)$ ]]; then
    usage "E: Port must be a number."
  elif [ "$1" -le 0 ] || [ "$1" -ge 65536 ]; then
    usage "E: Port number must be in [1 - 65535]."
  fi
}

function get_models()
{
  mapfile -t agent_models < <(curl "${curl_extra_args[@]}" -s "${agent_anthropic_base_url}/v1/models" | \
    jq -r '.data[].id' | sort)
} 

function get_model_context()
{
  local agent_remote_context context_tokens
  agent_remote_context=$(
    curl "${curl_extra_args[@]}" -s "${agent_anthropic_base_url}/v1/models" | \
      jq --arg model_id "$agent_anthropic_model" \
        '.data[] | select(.id == $model_id) | .capabilities.limits.max_context_window_tokens')

  # Normalize valid provider limits before comparing them or writing JSON.
  # If the provider has no usable limit, retain the user's requested context.
  if ! normalize_context "$agent_remote_context"; then
    return
  fi
  agent_remote_context="$context_tokens"

  if [ -z "$agent_context" ] || [ "$agent_context" -gt "$agent_remote_context" ]; then
    agent_context="$agent_remote_context"
  fi
}

function run_claude()
{
  [ -n "${agent_anthropic_base_url:-}" ] && export ANTHROPIC_BASE_URL="${agent_anthropic_base_url}"
  [ -n "${agent_anthropic_auth_token:-}" ] && export ANTHROPIC_AUTH_TOKEN="${agent_anthropic_auth_token}"
  [ -n "${agent_anthropic_api_key:-}" ] && export ANTHROPIC_API_KEY="${agent_anthropic_api_key}"
  [ -n "${agent_anthropic_model:-}" ] && export ANTHROPIC_MODEL="${agent_anthropic_model}"

  # Enables Claude Code's gateway model discovery.
  export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

  # If the user requested context (or the model provided it) then set the max
  # context. Otherwise just force Claude to wait for the API to tell it when
  # context has exceeded.
  if [ -n "${agent_context:-}" ]; then
    export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${agent_context}"
  else
    export CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1
  fi

  claude-code "$@"
}

# Use a subshell so the EXIT trap runs while the local config_dir is in scope.
function run_opencode() (
  local config_dir
  local config_file

  config_dir=$(mktemp -d) || return 1
  trap 'rm -rf -- "$config_dir"' EXIT
  config_file="${config_dir}/opencode.json"

  # OpenCode reads this file alongside its normal configuration. Keep the
  # credentials in the environment rather than writing them to disk.
  jq -n \
    --arg model "$agent_anthropic_model" \
    --argjson context "${agent_context:-null}" \
    '{"$schema": "https://opencode.ai/config.json",
      model: ("gateway/" + $model),
      providers: {
        gateway: {
          name: "OpenAI-compatible gateway",
          env: ["OPENAI_API_KEY"],
          package: "@opencode/ai/providers/openai-compatible",
          settings: {baseURL: "{env:OPENAI_BASE_URL}"},
          models: {($model): ({name: $model} +
            (if $context == null then {} else {limit: {context: $context}} end))}
        }
      }}' > "$config_file" || return 1

  # The configured providers expose OpenAI-compatible endpoints at /v1.
  export OPENAI_BASE_URL="${agent_anthropic_base_url}/v1"
  # OpenCode uses OPENAI_API_KEY for either credential type: prefer the
  # provider's API key, falling back to its bearer token.
  export OPENAI_API_KEY="${agent_anthropic_api_key:-$agent_anthropic_auth_token}"
  export OPENCODE_CONFIG="$config_file"

  opencode "$@"
)

function print_models()
{
  local agent_models_idx=0

  while [ ${agent_models_idx} -lt ${#agent_models[@]} ]; do
    if [ "${agent_models[${agent_models_idx}]}" = "${agent_anthropic_model}" ]; then
      printf "%4d: * %s\n" "${agent_models_idx}" "${agent_models[${agent_models_idx}]}"
      agent_models_default_idx="${agent_models_idx}"
    else
      printf "%4d:   %s\n" "${agent_models_idx}" "${agent_models[${agent_models_idx}]}"
    fi

    ((agent_models_idx++))
  done
}

##
## SCRIPT-PROPER STARTS HERE
##

parsed_args=$(getopt \
  --options "h" \
  --long "agent:,provider:,help,model:,select-model,list-models,context:,host:,port:" \
  --name "$0" \
  -- "$@"
)

if [ $? != 0 ]; then
  echo "Try '$0 --help' for more information." >&2
  exit 2
fi

# getopt produces shell-quoted output, so eval is used to restore
# the correctly separated and quoted arguments.
eval "set -- $parsed_args"

while true; do
  case "$1" in
    --agent)
      agent="${2:-}"
      check_agent "${agent}"
      shift 2
      ;;
    --provider)
      agent_provider="${2:-}"
      check_provider "${agent_provider}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --model)
      agent_model="${2:-}"
      shift 2
      ;;
    --select-model)
      agent_select_model=true
      shift
      ;;
    --list-models)
      agent_list_models=true
      shift
      ;;
    --context)
      agent_context="${2:-}"
      sanitize_context "${agent_context}"
      shift 2
      ;;
    --host)
      agent_host="${2:-}"
      check_host "${agent_host}"
      shift 2
      ;;
    --port)
      agent_port="${2:-}"
      check_port "${agent_port}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Internal error: unexpected option: $1" >&2
      exit 2
      ;;
  esac
done

# Sanity check.
if [ "${agent_select_model}" = "true" ] && [ "${agent_list_models}" = "true" ]; then
  usage "E: --select-model and --list-models are incompatible."
elif [ "${agent_select_model}" = "true" ] || [ "${agent_list_models}" = "true" ]; then
  if [ -n "${agent_model}" ]; then
    usage "E: --select-model/--list-models is incompatible with --model."
  fi
fi

# Check that openrouter did not supply --host or --port.
if [ "${agent_provider}" = "openrouter" ]; then
  if [ -n "${agent_host}" ] || [ -n "${agent_port}" ]; then
    usage "E: Selected provider '${agent_provider}' does not accept --host or --port."
  fi
fi

# Set the --host and --port defaults
case "${agent_provider}" in
  "copilot-api")
    [ -z "${agent_host}" ] && agent_host="127.0.0.1"
    [ -z "${agent_port}" ] && agent_port="4141"

    agent_anthropic_base_url="http://${agent_host}:${agent_port}"
    agent_anthropic_auth_token="copilot"
    agent_anthropic_model="${agent_model:-gpt-6-luna}"
    ;;
  "lemonade")
    [ -z "${agent_host}" ] && agent_host="127.0.0.1"
    [ -z "${agent_port}" ] && agent_port="13305"

    agent_anthropic_base_url="http://${agent_host}:${agent_port}"
    agent_anthropic_api_key="lemonade"
    agent_anthropic_model="${agent_model:-Gemma-4-12B-it-MTP-GGUF}"
    ;;
  "ollama")
    [ -z "${agent_host}" ] && agent_host="127.0.0.1"
    [ -z "${agent_port}" ] && agent_port="11434"

    agent_anthropic_base_url="http://${agent_host}:${agent_port}"
    agent_anthropic_auth_token="ollama"
    agent_anthropic_model="${agent_model:-qwen3-coder:30b}"
    ;;
  "openrouter")
    agent_host="openrouter.ai"
    agent_port="443"

    if [ -z "${OPENROUTER_AUTH_TOKEN:-}" ]; then
      echo "E: OPENROUTER_AUTH_TOKEN must be set before calling this script."
      exit 1
    fi

    # "Claude Code Key" on openrouter.ai - silicon-alliances workspace $50/month
    agent_anthropic_base_url="https://openrouter.ai/api"
    agent_anthropic_auth_token="${OPENROUTER_AUTH_TOKEN}"
    agent_anthropic_model="${agent_model:-openai/gpt-6-luna}"
    ;;
esac

# Add auth headers to CURL if they are needed.
if [ -n "${agent_anthropic_api_key}" ]; then
  curl_extra_args+=( "-H" "X-API-Key: ${agent_anthropic_api_key}" )
fi

if [ -n "${agent_anthropic_auth_token}" ]; then
  curl_extra_args+=( "-H" "Authorization: Bearer ${agent_anthropic_auth_token}" )
fi

# Assume everyone's openai compatible:
if [ "${agent_list_models}" = "true" ] || [ "${agent_select_model}" = "true" ]; then
  echo "Models available for ${agent_provider}:"
  echo
  get_models
  print_models

  if [ "${agent_list_models}" = "true" ]; then
    exit
  fi

  echo
  read -p "Select model index, ENTER for default, CTRL-C to cancel: " agent_models_idx

  if [ -z "${agent_models_idx}" ]; then
    agent_models_idx="${agent_models_default_idx}"
  fi

  ## Sanity check even the default model index (not else-if with above).
  if ! [[ "${agent_models_idx}" =~ ^[0-9][0-9]*$ ]]; then
    echo "Invalid input; please enter a number (>=0)." >&2
    exit 1
  elif [ ${agent_models_idx} -ge ${#agent_models[@]} ]; then
    echo "Input out of range." >&2
    exit 1
  fi

  agent_anthropic_model="${agent_models[${agent_models_idx}]}"
  echo "Selected '${agent_anthropic_model}'."
fi

get_model_context

case "$agent" in
  "claude-code")
    run_claude "$@"
    ;;
  "opencode")
    run_opencode "$@"
    ;;
  *)
    # Defensive: validation should reject unknown agents, but catch a new
    # accepted agent whose runner has not been added here.
    echo "E: No runner for agent '$agent'." >&2
    exit 1
    ;;
esac

