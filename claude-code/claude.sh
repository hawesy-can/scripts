#!/bin/bash
#
# Invoke a coding agent with a selected model provider/model.
#
# Default models are configured for each provider that are reasonable in
# cost/performance, but can be selected.

# Provider settings used by the selected agent.
claude_anthropic_base_url=
claude_anthropic_auth_token=
claude_anthropic_api_key=
claude_anthropic_model=

# Command-line configuration
claude_agent="claude-code"
claude_provider="copilot-api"
claude_model=""
claude_select_model=false
claude_list_models=false
claude_context=""
claude_host=""
claude_port=""

curl_extra_args=()
claude_models=()
claude_models_default_idx=

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

  normalize_context "$claude_context" || usage "E: Bad context: '${claude_context}'"
  claude_context="$context_tokens"
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
  mapfile -t claude_models < <(curl "${curl_extra_args[@]}" -s "${claude_anthropic_base_url}/v1/models" | \
    jq -r '.data[].id' | sort)
} 

function get_model_context()
{
  local claude_remote_context context_tokens
  claude_remote_context=$(
    curl "${curl_extra_args[@]}" -s "${claude_anthropic_base_url}/v1/models" | \
      jq --arg model_id "$claude_anthropic_model" \
        '.data[] | select(.id == $model_id) | .capabilities.limits.max_context_window_tokens')

  # Normalize valid provider limits before comparing them or writing JSON.
  # If the provider has no usable limit, retain the user's requested context.
  if ! normalize_context "$claude_remote_context"; then
    return
  fi
  claude_remote_context="$context_tokens"

  if [ -z "$claude_context" ] || [ "$claude_context" -gt "$claude_remote_context" ]; then
    claude_context="$claude_remote_context"
  fi
}

function run_claude()
{
  [ -n "${claude_anthropic_base_url:-}" ] && export ANTHROPIC_BASE_URL="${claude_anthropic_base_url}"
  [ -n "${claude_anthropic_auth_token:-}" ] && export ANTHROPIC_AUTH_TOKEN="${claude_anthropic_auth_token}"
  [ -n "${claude_anthropic_api_key:-}" ] && export ANTHROPIC_API_KEY="${claude_anthropic_api_key}"
  [ -n "${claude_anthropic_model:-}" ] && export ANTHROPIC_MODEL="${claude_anthropic_model}"

  # Enables Claude Code's gateway model discovery.
  export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

  # If the user requested context (or the model provided it) then set the max
  # context. Otherwise just force Claude to wait for the API to tell it when
  # context has exceeded.
  if [ -n "${claude_context:-}" ]; then
    export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${claude_context}"
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
    --arg model "$claude_anthropic_model" \
    --argjson context "${claude_context:-null}" \
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
  export OPENAI_BASE_URL="${claude_anthropic_base_url}/v1"
  # OpenCode uses OPENAI_API_KEY for either credential type: prefer the
  # provider's API key, falling back to its bearer token.
  export OPENAI_API_KEY="${claude_anthropic_api_key:-$claude_anthropic_auth_token}"
  export OPENCODE_CONFIG="$config_file"

  opencode "$@"
)

function print_models()
{
  local claude_models_idx=0

  while [ ${claude_models_idx} -lt ${#claude_models[@]} ]; do
    if [ "${claude_models[${claude_models_idx}]}" = "${claude_anthropic_model}" ]; then
      printf "%4d: * %s\n" "${claude_models_idx}" "${claude_models[${claude_models_idx}]}"
      claude_models_default_idx="${claude_models_idx}"
    else
      printf "%4d:   %s\n" "${claude_models_idx}" "${claude_models[${claude_models_idx}]}"
    fi

    ((claude_models_idx++))
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
      claude_agent="${2:-}"
      check_agent "${claude_agent}"
      shift 2
      ;;
    --provider)
      claude_provider="${2:-}"
      check_provider "${claude_provider}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --model)
      claude_model="${2:-}"
      shift 2
      ;;
    --select-model)
      claude_select_model=true
      shift
      ;;
    --list-models)
      claude_list_models=true
      shift
      ;;
    --context)
      claude_context="${2:-}"
      sanitize_context "${claude_context}"
      shift 2
      ;;
    --host)
      claude_host="${2:-}"
      check_host "${claude_host}"
      shift 2
      ;;
    --port)
      claude_port="${2:-}"
      check_port "${claude_port}"
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
if [ "${claude_select_model}" = "true" ] && [ "${claude_list_models}" = "true" ]; then
  usage "E: --select-model and --list-models are incompatible."
elif [ "${claude_select_model}" = "true" ] || [ "${claude_list_models}" = "true" ]; then
  if [ -n "${claude_model}" ]; then
    usage "E: --select-model/--list-models is incompatible with --model."
  fi
fi

# Check that openrouter did not supply --host or --port.
if [ "${claude_provider}" = "openrouter" ]; then
  if [ -n "${claude_host}" ] || [ -n "${claude_port}" ]; then
    usage "E: Selected provider '${claude_provider}' does not accept --host or --port."
  fi
fi

# Set the --host and --port defaults
case "${claude_provider}" in
  "copilot-api")
    [ -z "${claude_host}" ] && claude_host="127.0.0.1"
    [ -z "${claude_port}" ] && claude_port="4141"

    claude_anthropic_base_url="http://${claude_host}:${claude_port}"
    claude_anthropic_auth_token="copilot"
    claude_anthropic_model="${claude_model:-gpt-6-luna}"
    ;;
  "lemonade")
    [ -z "${claude_host}" ] && claude_host="127.0.0.1"
    [ -z "${claude_port}" ] && claude_port="13305"

    claude_anthropic_base_url="http://${claude_host}:${claude_port}"
    claude_anthropic_api_key="lemonade"
    claude_anthropic_model="${claude_model:-Gemma-4-12B-it-MTP-GGUF}"
    ;;
  "ollama")
    [ -z "${claude_host}" ] && claude_host="127.0.0.1"
    [ -z "${claude_port}" ] && claude_port="11434"

    claude_anthropic_base_url="http://${claude_host}:${claude_port}"
    claude_anthropic_auth_token="ollama"
    claude_anthropic_model="${claude_model:-qwen3-coder:30b}"
    ;;
  "openrouter")
    claude_host="openrouter.ai"
    claude_port="443"

    if [ -z "${OPENROUTER_AUTH_TOKEN:-}" ]; then
      echo "E: OPENROUTER_AUTH_TOKEN must be set before calling this script."
      exit 1
    fi

    # "Claude Code Key" on openrouter.ai - silicon-alliances workspace $50/month
    claude_anthropic_base_url="https://openrouter.ai/api"
    claude_anthropic_auth_token="${OPENROUTER_AUTH_TOKEN}"
    claude_anthropic_model="${claude_model:-openai/gpt-6-luna}"
    ;;
esac

# Add auth headers to CURL if they are needed.
if [ -n "${claude_anthropic_api_key}" ]; then
  curl_extra_args+=( "-H" "X-API-Key: ${claude_anthropic_api_key}" )
fi

if [ -n "${claude_anthropic_auth_token}" ]; then
  curl_extra_args+=( "-H" "Authorization: Bearer ${claude_anthropic_auth_token}" )
fi

# Assume everyone's openai compatible:
if [ "${claude_list_models}" = "true" ] || [ "${claude_select_model}" = "true" ]; then
  echo "Models available for ${claude_provider}:"
  echo
  get_models
  print_models

  if [ "${claude_list_models}" = "true" ]; then
    exit
  fi

  echo
  read -p "Select model index, ENTER for default, CTRL-C to cancel: " claude_models_idx

  if [ -z "${claude_models_idx}" ]; then
    claude_models_idx="${claude_models_default_idx}"
  fi

  ## Sanity check even the default model index (not else-if with above).
  if ! [[ "${claude_models_idx}" =~ ^[0-9][0-9]*$ ]]; then
    echo "Invalid input; please enter a number (>=0)." >&2
    exit 1
  elif [ ${claude_models_idx} -ge ${#claude_models[@]} ]; then
    echo "Input out of range." >&2
    exit 1
  fi

  claude_anthropic_model="${claude_models[${claude_models_idx}]}"
  echo "Selected '${claude_anthropic_model}'."
fi

get_model_context

case "$claude_agent" in
  "claude-code")
    run_claude "$@"
    ;;
  "opencode")
    run_opencode "$@"
    ;;
  *)
    # Defensive: validation should reject unknown agents, but catch a new
    # accepted agent whose runner has not been added here.
    echo "E: No runner for agent '$claude_agent'." >&2
    exit 1
    ;;
esac

