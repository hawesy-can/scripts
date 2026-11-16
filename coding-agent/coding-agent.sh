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
agent_zdr=true

# Per-provider catalog details, set when the provider is selected below.
# The defaults describe the OpenAI-compatible providers (copilot-api,
# lemonade, ollama); openrouter overrides them.
provider_models_path="/v1/models"
provider_context_expr='(.capabilities.limits.max_context_window_tokens // null)'
provider_price_expr='null'
provider_zdr_expr='null'
provider_tools_filter=
provider_model_fields=""

curl_extra_args=()
agent_models=()
agent_model_context=()
agent_model_zdr=()
agent_model_price=()
agent_models_default_idx=
agent_catalog_json=""
agent_usable_catalog_json=""

function usage()
{
  cat >&2 <<EOF
USAGE
  $0 [--agent AGENT] [--provider PROVIDER] [--help|-h]
     [--model MODEL | --select-model | --list-models]
     [--context CONTEXT] [--host HOST] [--port PORT] [--no-zdr]
     [-- AGENT_OPTIONS]

WHERE
  AGENT
    One of 'claude-code' or 'opencode'. Defaults to 'claude-code'.
  PROVIDER
    One of 'openrouter', 'copilot-api', 'lemonade' or 'ollama'. Defaults to
    'copilot-api'.
  MODEL
    A valid model ID from the provider - one the configured credential is
    permitted to use, and one that supports tool calling (where the provider
    reports it; the coding agents need it). Use --list-models to find them.
    Defaults to a low-cost model on the provider chosen. The model is
    validated against the provider's model catalog before the agent is
    started.
  CONTEXT
    Max context for the model selected. Must be a number - SI postfixes like
    'k' and 'M' are acceptable (e.g. 262144, 256k, 1M).
  HOST
    Hostname or IP address to connect to. For 'copilot-api', 'lemonade' and
    'ollama'. Defaults to '127.0.0.1'.
  PORT
    TCP port number to connect on. For 'copilot-api', 'lemonade' and 'ollama'.
    Defaults to the default port those local services would use.
  NO-ZDR
    For 'openrouter' only. By default the wrapper assumes Zero Data Retention:
    it only lists and accepts models that have at least one ZDR-capable
    endpoint, and configures the agent to send 'provider.zdr: true' on every
    request. --no-zdr drops both the model filter and the per-request ZDR
    routing.

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

# Fetch URL (authenticated with the provider credentials where they are
# configured) and echo the response body on stdout. Any failure is fatal:
# the wrapper never launches the agent against a provider it could not
# query. Network failures, rejected credentials and unexpected HTTP
# statuses each get a distinct error message.
function fetch_json()
{
  local url="$1" what="$2"
  local response status curl_status

  response=$(curl "${curl_extra_args[@]}" -sS -w $'\n%{http_code}' "$url")
  curl_status=$?

  if [ "${curl_status}" -ne 0 ]; then
    echo "E: Could not reach ${agent_provider} to ${what} (curl exit ${curl_status}):" >&2
    echo "E:   ${url}" >&2
    echo "E: Check your network connection and try again." >&2
    exit 1
  fi

  status="${response##*$'\n'}"
  response="${response%$'\n'*}"

  if [ "${status}" != "200" ]; then
    case "${status}" in
      "401"|"403")
        echo "E: ${agent_provider} rejected the credentials (HTTP ${status}) while trying to ${what}:" >&2
        echo "E:   ${url}" >&2
        echo "E: Check that the configured token is valid and permitted to use this API." >&2
        ;;
      "000")
        echo "E: ${agent_provider} closed the connection without an HTTP response while trying to ${what}:" >&2
        echo "E:   ${url}" >&2
        ;;
      *)
        echo "E: ${agent_provider} returned HTTP ${status} while trying to ${what}:" >&2
        echo "E:   ${url}" >&2
        ;;
    esac
    exit 1
  fi

  printf '%s' "${response}"
}

# Annotate every model in the openrouter catalog with the number of
# ZDR-capable endpoints that serve it (safety-retention endpoints count
# too; the account level setting governs them). The ZDR endpoint list is
# fetched authenticated, and any failure is fatal like any other catalog
# problem. Each model ends up with a .zdr object: {in: N, sr: M} - N true
# ZDR endpoints and M safety-retention endpoints.
function annotate_catalog_zdr()
{
  local url="${agent_anthropic_base_url}/v1/endpoints/zdr"
  local zdr_endpoints zdr_summary

  zdr_endpoints=$(fetch_json "${url}" "fetch the ZDR-capable endpoints") || exit 1

  if ! jq -e '.data | type == "array"' <<<"${zdr_endpoints}" >/dev/null 2>&1; then
    echo "E: OpenRouter returned a malformed ZDR endpoint list (expected a JSON object with a 'data' array):" >&2
    echo "E:   ${url}" >&2
    exit 1
  fi

  # Each ZDR-capable endpoint carries the OpenRouter model ID it serves in
  # model_id. Reduce the endpoint list to per-model counts first: the full
  # endpoint list is far too large to pass to jq as a command line
  # argument.
  if ! zdr_summary=$(jq -c '
      [.data[] | {id: (.model_id // ""), sr: (.safety_retention == true)}]
      | group_by(.id)
      | map({key: .[0].id,
             value: {in: ([.[] | select(.sr == false)] | length),
                     sr: ([.[] | select(.sr == true)] | length)}})
      | from_entries' <<<"${zdr_endpoints}"); then
    echo "E: Could not summarize the ZDR-capable endpoints." >&2
    exit 1
  fi

  if ! agent_catalog_json=$(jq --argjson zs "${zdr_summary}" \
      '.data |= map(. + {zdr: ($zs[.id] // {in: 0, sr: 0})})' \
      <<<"${agent_catalog_json}"); then
    echo "E: Could not annotate the model catalog with ZDR endpoint counts." >&2
    exit 1
  fi
}

# Fetch the catalog of models the configured credential is permitted to
# use, into agent_catalog_json. For openrouter this is the authenticated
# /v1/models/user listing, so models the key may not run never appear.
# Runs for every invocation: the model choice is validated against the
# catalog before the agent is launched.
#
# From it, agent_usable_catalog_json is derived: the models the wrapper
# will actually offer or accept - tool-calling models only (where the
# provider reports tool support), and for openrouter with ZDR on, only
# models with at least one ZDR-capable endpoint.
function get_catalog()
{
  local url="${agent_anthropic_base_url}${provider_models_path}"

  agent_catalog_json=$(fetch_json "${url}" "fetch the model catalog") || exit 1

  if ! jq -e '.data | type == "array"' <<<"${agent_catalog_json}" >/dev/null 2>&1; then
    echo "E: ${agent_provider} returned a malformed model catalog (expected a JSON object with a 'data' array):" >&2
    echo "E:   ${url}" >&2
    exit 1
  fi

  # OpenRouter: annotate every model with its ZDR-capable endpoint counts
  # (the ZDR column needs them even when the ZDR filter is off).
  if [ "${agent_provider}" = "openrouter" ]; then
    annotate_catalog_zdr
  fi

  agent_usable_catalog_json="${agent_catalog_json}"

  # The coding agents need tool calling: drop models without it wherever
  # the provider reports tool support. There is no escape hatch - a
  # model that cannot call tools cannot drive the agent.
  if [ -n "${provider_tools_filter}" ]; then
    if ! agent_usable_catalog_json=$(jq '.data |= map('"${provider_tools_filter}"')' \
        <<<"${agent_usable_catalog_json}"); then
      echo "E: Could not filter the model catalog for tool-calling support." >&2
      exit 1
    fi
  fi

  # Zero Data Retention (openrouter only, by default): keep only the
  # models that have at least one ZDR-capable endpoint.
  if [ "${agent_provider}" = "openrouter" ] && [ "${agent_zdr}" = "true" ]; then
    if ! agent_usable_catalog_json=$(jq \
        '.data |= map(select((.zdr.in // 0) + (.zdr.sr // 0) > 0))' \
        <<<"${agent_usable_catalog_json}"); then
      echo "E: Could not filter the model catalog for ZDR-capable models." >&2
      exit 1
    fi
  fi
}

# Parse the usable catalog into the columns used for listing and picking:
#   agent_models[i]        - model ID (sorted)
#   agent_model_context[i] - context window in tokens ("-" when unknown)
#   agent_model_zdr[i]     - ZDR-capable endpoints: "N", "N+Ms" when the
#                            count includes safety-retention endpoints,
#                            "-" when none or not applicable
#   agent_model_price[i]   - prompt/completion price per million tokens,
#                            as a "$in/$out" string ("-" when unknown)
function parse_catalog()
{
  local id context zdr_col price_in price_out

  agent_models=()
  agent_model_context=()
  agent_model_zdr=()
  agent_model_price=()

  while IFS=$'\t' read -r id context zdr_col price_in price_out; do
    [ -n "${id}" ] || continue
    agent_models+=("${id}")
    agent_model_context+=("${context}")
    agent_model_zdr+=("${zdr_col}")
    if [ "${price_in}" = "-" ] || [ "${price_out}" = "-" ]; then
      agent_model_price+=("-")
    else
      agent_model_price+=("${price_in}/${price_out}")
    fi
  done < <(jq -r \
    '[.data[] | '"${provider_model_fields}"'] | sort_by(.id) | .[] |
     [.id, (.context // "-"), (.zdr // "-"), (.price.in // "-"), (.price.out // "-")] | @tsv' \
    <<<"${agent_usable_catalog_json}")
}

# Hard pre-launch check: the model (from --model or the provider default)
# must appear in the usable catalog. Diagnose against the permitted
# catalog so the error states the actual reason.
function validate_model()
{
  local model="$1"

  if jq -e --arg model_id "${model}" '.data[] | select(.id == $model_id)' \
      <<<"${agent_usable_catalog_json}" >/dev/null 2>&1; then
    return
  fi

  if ! jq -e --arg model_id "${model}" '.data[] | select(.id == $model_id)' \
      <<<"${agent_catalog_json}" >/dev/null 2>&1; then
    echo "E: Model '${model}' is not available to this ${agent_provider} credential." >&2
    echo "E: Use --list-models to see the models that are available." >&2
    exit 1
  fi

  # The model is permitted but not usable: tool calling, then ZDR.
  if [ -n "${provider_tools_filter}" ] && \
     ! jq -e --arg model_id "${model}" \
        ".data[] | select(.id == \$model_id) | ${provider_tools_filter}" \
        <<<"${agent_catalog_json}" >/dev/null 2>&1; then
    echo "E: Model '${model}' does not support tool calling, which the coding agents require." >&2
    echo "E: Use --list-models to see the models that are available." >&2
    exit 1
  fi

  echo "E: Model '${model}' has no ZDR-capable endpoint." >&2
  echo "E: Retry with --no-zdr if it should be permitted without ZDR." >&2
  exit 1
}

# Clamp the requested context to the limit the provider reports for the
# selected model, if it reports one at all. If the provider has no usable
# limit, the user's requested context is retained.
function clamp_model_context()
{
  local agent_remote_context context_tokens

  agent_remote_context=$(jq -r --arg model_id "${agent_anthropic_model}" \
    '.data[] | select(.id == $model_id) | ('"${provider_context_expr}"' // empty)' \
    <<<"${agent_usable_catalog_json}")

  # Normalize valid provider limits before comparing them or writing JSON.
  if ! normalize_context "${agent_remote_context}"; then
    return
  fi
  agent_remote_context="${context_tokens}"

  if [ -z "${agent_context}" ] || [ "${agent_context}" -gt "${agent_remote_context}" ]; then
    agent_context="${agent_remote_context}"
  fi
}

# The per-request body that asks OpenRouter to route only to ZDR-capable
# endpoints; "null" when ZDR is disabled (or not applicable to the
# provider).
function zdr_request_body()
{
  if [ "${agent_provider}" = "openrouter" ] && [ "${agent_zdr}" = "true" ]; then
    echo '{"provider":{"zdr":true}}'
  else
    echo "null"
  fi
}

function run_claude()
{
  [ -n "${agent_anthropic_base_url:-}" ] && export ANTHROPIC_BASE_URL="${agent_anthropic_base_url}"
  [ -n "${agent_anthropic_auth_token:-}" ] && export ANTHROPIC_AUTH_TOKEN="${agent_anthropic_auth_token}"
  [ -n "${agent_anthropic_api_key:-}" ] && export ANTHROPIC_API_KEY="${agent_anthropic_api_key}"
  [ -n "${agent_anthropic_model:-}" ] && export ANTHROPIC_MODEL="${agent_anthropic_model}"

  # OpenRouter only: ask the provider to route every request to a
  # ZDR-capable endpoint (unless --no-zdr was given). Claude Code merges
  # this environment variable into the top level of its conversation
  # request bodies.
  if [ "${agent_provider}" = "openrouter" ] && [ "${agent_zdr}" = "true" ]; then
    export CLAUDE_CODE_EXTRA_BODY='{"provider":{"zdr":true}}'
  fi

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
  if [ "${agent_provider}" = "openrouter" ]; then
    # OpenCode ships a native OpenRouter provider: use it rather than a
    # generic OpenAI-compatible gateway. It reads OPENROUTER_API_KEY for
    # the credential and talks to the OpenAI-compatible /v1 API on
    # openrouter.ai by default. The body overlay is deep-merged into every
    # request body and asks OpenRouter to route only to ZDR-capable
    # endpoints (unless --no-zdr was given).
    jq -n \
      --arg model "$agent_anthropic_model" \
      --argjson context "${agent_context:-null}" \
      --argjson zdr_body "$(zdr_request_body)" \
      '{"$schema": "https://opencode.ai/config.json",
        model: ("openrouter/" + $model),
        providers: {
          openrouter: (
            (if $zdr_body == null then {} else {body: $zdr_body} end) +
            {models: {($model): ({name: $model} +
              (if $context == null then {} else {limit: {context: $context}} end))}}
          )
        }}' > "$config_file" || return 1

    export OPENROUTER_API_KEY="${agent_anthropic_auth_token}"
  else
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
  fi

  export OPENCODE_CONFIG="$config_file"

  opencode "$@"
)

# Print the model catalog as a table with context, ZDR and price columns,
# and remember the index of the default model (marked with a '*') for the
# --select-model prompt.
function print_models()
{
  local agent_models_idx=0
  local context zdr price marker

  agent_models_default_idx=

  printf "%4s: %s %-48s %9s %6s  %s\n" "IDX" "  " "MODEL" "CONTEXT" "ZDR" "PRICE IN/OUT PER M"

  while [ ${agent_models_idx} -lt ${#agent_models[@]} ]; do
    context="${agent_model_context[${agent_models_idx}]:--}"
    zdr="${agent_model_zdr[${agent_models_idx}]:--}"
    price="${agent_model_price[${agent_models_idx}]:--}"
    if [ "${agent_models[${agent_models_idx}]}" = "${agent_anthropic_model}" ]; then
      marker="*"
      agent_models_default_idx="${agent_models_idx}"
    else
      marker=" "
    fi
    printf "%4d: %s %-48s %9s %6s  %s\n" \
      "${agent_models_idx}" "${marker}" "${agent_models[${agent_models_idx}]}" \
      "${context}" "${zdr}" "${price}"

    ((agent_models_idx++))
  done
}

##
## SCRIPT-PROPER STARTS HERE
##

parsed_args=$(getopt \
  --options "h" \
  --long "agent:,provider:,help,model:,select-model,list-models,context:,host:,port:,no-zdr" \
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
    --no-zdr)
      agent_zdr=false
      shift
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

# Check that --no-zdr is only used with openrouter.
if [ "${agent_provider}" != "openrouter" ] && [ "${agent_zdr}" = "false" ]; then
  usage "E: Selected provider '${agent_provider}' does not accept --no-zdr."
fi

# Set the --host and --port defaults
case "${agent_provider}" in
  "copilot-api")
    [ -z "${agent_host}" ] && agent_host="127.0.0.1"
    [ -z "${agent_port}" ] && agent_port="4141"

    agent_anthropic_base_url="http://${agent_host}:${agent_port}"
    agent_anthropic_auth_token="copilot"
    agent_anthropic_model="${agent_model:-gpt-6-luna}"
    provider_tools_filter='select(.capabilities.supports.tool_calls == true)'
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

    # The authenticated /v1/models/user listing only contains the models
    # this key is permitted to use. Context comes straight from the model
    # entry; prices are per-token strings that get scaled and formatted
    # per million tokens for display. The ZDR column is derived from the
    # .zdr annotation added by annotate_catalog_zdr.
    provider_models_path="/v1/models/user"
    provider_context_expr='(.context_length // .top_provider.context_length // null)'
    provider_tools_filter='select((.supported_parameters // []) | index("tools") != null)'
    provider_zdr_expr='(if ((.zdr.in // 0) + (.zdr.sr // 0)) == 0 then null
      elif (.zdr.sr // 0) > 0 then "\(.zdr.in)+\(.zdr.sr)s"
      else "\(.zdr.in)" end)'
    provider_price_expr='(def money($c):
        (if $c < 0 then "-" else "" end) as $s |
        ($c | if . < 0 then -. else . end) as $a |
        ($a / 100 | floor) as $d |
        ($a % 100) as $r |
        "\($s)$\($d).\(if $r < 10 then "0\($r)" else "\($r)" end)";
      if .pricing.prompt == null or .pricing.completion == null then null
      else {in: money((.pricing.prompt | tonumber) * 100000000 | round),
            out: money((.pricing.completion | tonumber) * 100000000 | round)}
      end)'
    ;;
esac

# jq expression mapping each catalog entry to the columns shown by
# --list-models: {id, context, zdr, price:{in,out}}. Price strings come
# pre-formatted per million tokens ("$1.50"); null means "unknown".
provider_model_fields="{id: .id, context: ${provider_context_expr}, zdr: ${provider_zdr_expr}, price: ${provider_price_expr}}"

# Add auth headers to CURL if they are needed.
if [ -n "${agent_anthropic_api_key}" ]; then
  curl_extra_args+=( "-H" "X-API-Key: ${agent_anthropic_api_key}" )
fi

if [ -n "${agent_anthropic_auth_token}" ]; then
  curl_extra_args+=( "-H" "Authorization: Bearer ${agent_anthropic_auth_token}" )
fi

# Fetch the catalog of models the credential is permitted to use. This
# always runs: every model choice (--list-models, --select-model, --model
# and the default) is validated against it, and a fetch failure is fatal.
get_catalog

if [ "${agent_list_models}" = "true" ] || [ "${agent_select_model}" = "true" ]; then
  if [ "${agent_provider}" = "openrouter" ]; then
    if [ "${agent_zdr}" = "true" ]; then
      echo "Models permitted for this OpenRouter key with at least one ZDR-capable"
      echo "endpoint (* marks the default; --no-zdr shows all permitted models):"
    else
      echo "All models permitted for this OpenRouter key, ZDR filtering disabled"
      echo "by --no-zdr (* marks the default):"
    fi
    echo "ZDR column: ZDR-capable endpoints; 'N+Ms' includes M safety-retention ones."
    echo "Models without tool calling are never shown."
  elif [ -n "${provider_tools_filter}" ]; then
    echo "Models available for ${agent_provider} (* marks the default; models"
    echo "without tool calling are hidden):"
  else
    echo "Models available for ${agent_provider} (* marks the default):"
  fi
  echo

  parse_catalog
  if [ "${#agent_models[@]}" -eq 0 ]; then
    echo "E: No models are available to this ${agent_provider} credential." >&2
    if [ "${agent_provider}" = "openrouter" ] && [ "${agent_zdr}" = "true" ]; then
      echo "E: Retry with --no-zdr if the credential should also have models without" >&2
      echo "E: a ZDR-capable endpoint." >&2
    fi
    exit 1
  fi
  print_models

  if [ "${agent_list_models}" = "true" ]; then
    exit
  fi

  echo
  read -p "Select model index, ENTER for default, CTRL-C to cancel: " agent_models_idx

  if [ -z "${agent_models_idx}" ]; then
    if [ -z "${agent_models_default_idx:-}" ]; then
      echo "E: The default model is not in the list; enter a model index (or run with --model)." >&2
      exit 1
    fi
    agent_models_idx="${agent_models_default_idx}"
  fi

  ## Sanity check even the default model index (not else-if with above).
  if ! [[ "${agent_models_idx}" =~ ^[0-9][0-9]*$ ]]; then
    echo "E: Invalid input '${agent_models_idx}'; enter a model index from the list." >&2
    exit 1
  elif [ "${agent_models_idx}" -ge "${#agent_models[@]}" ]; then
    echo "E: Input out of range." >&2
    exit 1
  fi

  agent_anthropic_model="${agent_models[${agent_models_idx}]}"
  echo "Selected '${agent_anthropic_model}'."
else
  # Hard pre-launch validation of --model and the provider default.
  validate_model "${agent_anthropic_model}"
fi

clamp_model_context

# Zero Data Retention (openrouter only, on by default): the selected agent
# must be able to attach the per-request provider routing settings, or the
# wrapper refuses to run. Both supported agents can (see run_claude and
# run_opencode); this guard catches a new agent that cannot.
if [ "${agent_provider}" = "openrouter" ] && [ "${agent_zdr}" = "true" ]; then
  case "${agent}" in
    "claude-code"|"opencode")
      ;;
    *)
      echo "E: ZDR enforcement is on, but agent '${agent}' cannot attach per-request provider settings." >&2
      exit 1
      ;;
  esac
fi

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

