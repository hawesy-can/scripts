#!/bin/bash
#
# Invoke claude-code with a selected model provider/model.
#
# Default models are configured for each provider that are reasonable in
# cost/performance, but can be selected.

set -eu -o pipefail

# Will be exported later for claude-code to use. Only exported if the provider
# selection and command-line arguments cause the script to populate them. Not
# exported if they remain empty so that Claude doesn't try to use empty
# tokens.
ANTHROPIC_BASE_URL=
ANTHROPIC_AUTH_TOKEN=
ANTHROPIC_API_KEY=
ANTHROPIC_MODEL=

# Command-line configuation
arg_provider="copilot-api"
arg_model=""
arg_select_model=false
arg_list_models=false

curl_extra_args=()
models=()
models_default_idx=

function usage()
{
  cat >&2 <<EOF
USAGE
  $0 [--provider PROVIDER] [--help|-h]
     [--model MODEL | --select-model --list-models ]
     [--host HOST] [--port PORT] [--token TOKEN] [--] CLAUDE_CODE_OPTIONS

WHERE
  PROVIDER
    One of 'openrouter', 'copilot-api', 'lemonade' or 'ollama'. Defaults to
    'copilot-api'.
  MODEL
    A valid model ID from the provider. Use --list-models to find them. Defaults
    to a low-cost model on the provider chosen.
  HOST
    Hostname or IP address to connect to. For 'copilot-api', 'lemonade' and
    'ollama'. Defaults to '127.0.0.1'.
  PORT
    TCP port number to connect on. For 'copilot-api', 'lemonade' and 'ollama'.
    Defaults to the default port those local services would use.
  TOKEN
    Authentication key or token for the provider. Overrides any internal
    default, and the OPENROUTER_AUTH_TOKEN variable.

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

function check_host()
{
  # TODO: Check better!
  [ -z "${1:-}" ] && usage "E: Empty host specified."
}

function check_port()
{
  if ! [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || [ "$1" -gt 65535 ]; then
    usage "E: Port must be a positive number in the range 1-65536."
  fi
}

function check_token()
{
  [ -z "${1:-}" ] && usage "E: Token is empty."
}

function get_models()
{
  # TODO: For OpenRouter we'd need to do some more analysis on the endpoint
  # to work out what models are actually useable; the /models API returns
  # everything even if the auth token isn't permitted to use some models.
  local get_models_json

  if ! get_models_json=$(curl --fail "${curl_extra_args[@]}" -s "${ANTHROPIC_BASE_URL}/v1/models"); then
    echo "E: Failed to fetch model list from ${ANTHROPIC_BASE_URL}." >&2
    exit 1
  fi

  mapfile -t models < <(jq -r '.data[].id' <<<"${get_models_json}" | sort)

  # Debug code; uncomment to see the full model detail.
  #curl "${curl_extra_args[@]}" -s "${ANTHROPIC_BASE_URL}/v1/models" | jq
  #exit
} 

function print_models()
{
  local print_models_idx=0

  while [ ${print_models_idx} -lt ${#models[@]} ]; do
    if [ "${models[${print_models_idx}]}" = "${ANTHROPIC_MODEL}" ]; then
      printf "%4d: * %s\n" "${print_models_idx}" "${models[${print_models_idx}]}"
      models_default_idx="${print_models_idx}"
    else
      printf "%4d:   %s\n" "${print_models_idx}" "${models[${print_models_idx}]}"
    fi

    ((print_models_idx++)) || true
  done
}

##
## SCRIPT-PROPER STARTS HERE
##

parsed_args=$(getopt \
  --options "h" \
  --long "provider:,help,model:,select-model,list-models,host:,port:,token:" \
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
    --provider)
      arg_provider="${2:-}"
      check_provider "${arg_provider}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --model)
      arg_model="${2:-}"
      shift 2
      ;;
    --select-model)
      arg_select_model=true
      shift
      ;;
    --list-models)
      arg_list_models=true
      shift
      ;;
    --host)
      arg_host="${2:-}"
      check_host "${arg_host}"
      shift 2
      ;;
    --port)
      arg_port="${2:-}"
      check_port "${arg_port}"
      shift 2
      ;;
    --token)
      arg_token="${2:-}"
      check_token "${arg_token}"
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
if [ "${arg_select_model}" = "true" ] && [ "${arg_list_models}" = "true" ]; then
  usage "E: --select-model and --list-models are incompatible."
elif [ "${arg_select_model}" = "true" ] || [ "${arg_list_models}" = "true" ]; then
  if [ -n "${arg_model}" ]; then
    usage "E: --select-model/--list-models is incompatible with --model."
  fi
fi

# Check that openrouter did not supply --host or --port.
if [ "${arg_provider}" = "openrouter" ]; then
  if [ -n "${arg_host:-}" ] || [ -n "${arg_port:-}" ]; then
    usage "E: Selected provider '${arg_provider}' does not accept --host or --port."
  fi
fi

# Set the --host and --port defaults
case "${arg_provider}" in
  "copilot-api")
    ANTHROPIC_BASE_URL="http://${arg_host:=127.0.0.1}:${arg_port:-4141}"
    ANTHROPIC_AUTH_TOKEN="${arg_token:-copilot-api}"
    ANTHROPIC_MODEL="${arg_model:-gpt-5.4-mini}"
    ;;
  "lemonade")
    ANTHROPIC_BASE_URL="http://${arg_host:-127.0.0.1}:${arg_port:-13305}"
    ANTHROPIC_API_KEY="${arg_token:-lemonade}"
    ANTHROPIC_MODEL="${arg_model:-Gemma-4-12B-it-MTP-GGUF}"
    ;;
  "ollama")
    ANTHROPIC_BASE_URL="http://${arg_host:-127.0.0.1}:${arg_port:-11434}"
    ANTHROPIC_AUTH_TOKEN="${arg_token:-ollama}"
    ANTHROPIC_MODEL="${arg_model:-gemma4:12b}"
    ;;
  "openrouter")
    arg_host="openrouter.ai"
    arg_port="443"

    # Prefer --token if it was supplied. Default to the env token if not.
    if [ -n "${arg_token:-}" ]; then
      ANTHROPIC_AUTH_TOKEN="${arg_token}"
    else
      ANTHROPIC_AUTH_TOKEN="${OPENROUTER_AUTH_TOKEN:-}"
    fi

    if [ -z "${ANTHROPIC_AUTH_TOKEN}" ]; then
      echo "E: OPENROUTER_AUTH_TOKEN is not set and --token was not provided."
      exit 1
    fi

    ANTHROPIC_BASE_URL="https://openrouter.ai/api"
    ANTHROPIC_MODEL="${arg_model:-openai/gpt-5.4-mini}"
    ;;
esac

# Add auth headers to CURL if they are needed. This is two if statements
# rather then else-if just in case both are needed/provided.
if [ -n "${ANTHROPIC_API_KEY}" ]; then
  curl_extra_args+=( "-H" "X-API-Key: ${ANTHROPIC_API_KEY}" )
fi

if [ -n "${ANTHROPIC_AUTH_TOKEN}" ]; then
  curl_extra_args+=( "-H" "Authorization: Bearer ${ANTHROPIC_AUTH_TOKEN}" )
fi

# Assume everyone's openai compatible:
if [ "${arg_list_models}" = "true" ] || [ "${arg_select_model}" = "true" ]; then
  echo "Models available for ${arg_provider}:"
  echo
  get_models
  print_models

  if [ "${arg_list_models}" = "true" ]; then
    exit
  fi

  echo

  if [ -n "${models_default_idx}" ]; then
    read -p "Select model index, ENTER for default, CTRL-C to cancel: " models_idx

    if [ -z "${models_idx}" ]; then
      models_idx="${models_default_idx}"
    fi
  else
    read -p "Select model index, CTRL-C to cancel: " models_idx

    if [ -z "${models_idx}" ]; then
      echo "W: Default '${ANTHROPIC_MODEL}' not found in models list. Exiting." >&2
      exit
    fi
  fi

  ## Sanity check even the default model index (not else-if with above).
  if ! [[ "${models_idx}" =~ ^[0-9][0-9]*$ ]]; then
    echo "Invalid input; please enter a number (>=0)." >&2
    exit 1
  elif [ ${models_idx} -ge ${#models[@]} ]; then
    echo "Input out of range." >&2
    exit 1
  fi

  ANTHROPIC_MODEL="${models[${models_idx}]}"
  echo "Selected '${ANTHROPIC_MODEL}'."
fi

[ -n "${ANTHROPIC_BASE_URL:-}" ] && export ANTHROPIC_BASE_URL
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && export ANTHROPIC_AUTH_TOKEN
[ -n "${ANTHROPIC_API_KEY:-}" ] && export ANTHROPIC_API_KEY
[ -n "${ANTHROPIC_MODEL:-}" ] && export ANTHROPIC_MODEL

# Enables claude's gateway model discovery.
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

claude-code "${@}"

