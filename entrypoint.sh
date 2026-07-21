#!/usr/bin/env bash
set -euo pipefail

: "${PI_BASE_URL:?PI_BASE_URL is not set (e.g. http://192.168.1.50:8080/v1)}"
: "${PI_MODEL_ID:?PI_MODEL_ID is not set (e.g. qwen3-coder-30b)}"

PI_PROVIDER="${PI_PROVIDER:-local}"
PI_MODEL_NAME="${PI_MODEL_NAME:-${PI_MODEL_ID}}"
PI_CONTEXT_WINDOW="${PI_CONTEXT_WINDOW:-131072}"
PI_MAX_TOKENS="${PI_MAX_TOKENS:-16384}"
PI_REASONING="${PI_REASONING:-false}"

# PI_REASONING is pi's `reasoning` field: a strict boolean toggling *whether* the
# model does extended thinking. It does NOT choose the thinking *style*. Reject a
# non-boolean here with a clear message instead of letting jq --argjson fail with
# an opaque "invalid JSON text" further down.
case "${PI_REASONING}" in
    true|false) ;;
    *)
        cat >&2 <<MSG
error: PI_REASONING must be 'true' or 'false' (got '${PI_REASONING}').

It only toggles whether the model thinks -- it does not select a thinking mode.
If a hosted Anthropic model rejected "thinking.type.enabled" and told you to use
"thinking.type.adaptive", that is a separate switch: keep PI_REASONING=true and
turn on adaptive thinking via the provider compat flag, e.g. in .env:

    PI_COMPAT_JSON={"forceAdaptiveThinking":true}

That makes pi send thinking.type "adaptive" + output_config.effort, which the
current Claude models require.
MSG
        exit 1
        ;;
esac

# Which wire protocol pi speaks to the endpoint. Defaults to openai-completions
# so a local OpenAI-compatible server (vLLM, llama.cpp, Ollama, ...) works with
# no extra config -- exactly as before. Set to talk to a hosted API instead:
#   anthropic-messages     the Anthropic API   (PI_BASE_URL=https://api.anthropic.com)
#   openai-completions     OpenAI-compatible   (PI_BASE_URL=https://api.openai.com/v1)
#   openai-responses       OpenAI Responses API
#   google-generative-ai   Google Generative AI
PI_API="${PI_API:-openai-completions}"

# Per-token cost, surfaced in pi's /cost. Zeros by default (a local server is
# free), so an unset value reproduces the previous models.json exactly. For a
# paid API, set e.g.
#   PI_COST_JSON='{"input":3,"output":15,"cacheRead":0.3,"cacheWrite":3.75}'
# (dollars per million tokens, matching pi's convention).
PI_COST_JSON="${PI_COST_JSON:-{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0}}"

# Which agent to launch. `pi` is the default (vanilla pi coding agent); `omp`
# runs the oh-my-pi fork (binary `omp`). They differ only in a few particulars,
# captured here so the rest of the script stays agent-agnostic:
#   - config lives under ~/.pi vs ~/.omp
#   - the provider list is models.json (pi) vs models.yml (omp). omp reads YAML,
#     and JSON is valid YAML, so the same jq-built entry serves both.
#   - pi resolves an apiKey written as `$NAME` against the env; omp treats the
#     value as a bare env-var *name* first, falling back to a literal. So the
#     stored reference is `$PI_API_KEY` for pi, `PI_API_KEY` for omp. Either way
#     the secret stays in the env and never lands in the config volume.
PI_AGENT="${PI_AGENT:-pi}"
case "${PI_AGENT}" in
    pi)  AGENT_BIN=pi;  AGENT_CONFIG_HOME="${HOME}/.pi";  MODELS_FILE=models.json; KEY_REF='$PI_API_KEY' ;;
    omp) AGENT_BIN=omp; AGENT_CONFIG_HOME="${HOME}/.omp"; MODELS_FILE=models.yml;  KEY_REF='PI_API_KEY'  ;;
    *)   echo "error: PI_AGENT must be 'pi' or 'omp', got '${PI_AGENT}'" >&2; exit 1 ;;
esac

AGENT_DIR="${AGENT_CONFIG_HOME}/agent"
MODELS_JSON="${AGENT_DIR}/${MODELS_FILE}"

# A named volume created before the image pre-created this path will be owned by
# root, and no amount of rebuilding fixes an already-populated volume.
if ! mkdir -p "${AGENT_DIR}" 2>/dev/null || [ ! -w "${AGENT_DIR}" ]; then
    config_vol="$([ "${PI_AGENT}" = omp ] && echo pi-sandbox_omp-config || echo pi-sandbox_pi-config)"
    cat >&2 <<MSG
error: cannot write to ${AGENT_CONFIG_HOME} -- the config volume is owned by root.

Docker seeds a named volume's ownership only the first time it is used, so a
volume created by an older build stays root-owned forever. Recreate it:

    docker compose down
    docker volume rm ${config_vol} pi-sandbox_pi-npm-cache pi-sandbox_pi-pip-cache
    docker compose build
MSG
    exit 1
fi

[ -f "${MODELS_JSON}" ] || echo '{}' > "${MODELS_JSON}"

# The extension seeding and skills registration below are pi-specific: they
# target pi's settings.json format and the /opt/pi-seed (`pi install`) layout.
# oh-my-pi uses a different config schema and skill-discovery model, so for omp
# we skip straight to the provider entry. (omp skills parity is a follow-up.)
if [ "${PI_AGENT}" = pi ]; then

# Merge in any extensions installed at build time (see Dockerfile,
# PI_EXTENSIONS). They land at $SEED_HOME rather than directly under ~/.pi,
# because ~/.pi is the pi-config named volume and would otherwise shadow them
# -- silently, since Docker only seeds a volume from the image once, ever.
# Running this merge on every start means it self-heals if the volume is
# recreated, deleted, or predates this image's extensions.
#
# `pi install` honors $HOME, so the seed lives at $SEED_HOME/.pi/agent. Getting
# that path wrong makes extensions vanish without a word, so mismatches are
# reported rather than skipped.
SEED_HOME=/opt/pi-seed
SEED_AGENT="${SEED_HOME}/.pi/agent"
if [ -d "${SEED_HOME}" ] && [ ! -d "${SEED_AGENT}/npm" ]; then
    echo "warning: ${SEED_HOME} exists but ${SEED_AGENT}/npm does not." >&2
    echo "warning: extensions were built but cannot be merged. Rebuild: docker compose build --no-cache agent" >&2
fi
if [ -d "${SEED_AGENT}/npm" ]; then
    mkdir -p "${AGENT_DIR}/npm"
    # -n / --no-clobber: never overwrites a package you've since modified or
    # reinstalled a different version of by hand.
    cp -rn "${SEED_AGENT}/npm/." "${AGENT_DIR}/npm/" 2>/dev/null || true
fi
if [ -f "${SEED_AGENT}/settings.json" ]; then
    SETTINGS_JSON="${AGENT_DIR}/settings.json"
    [ -f "${SETTINGS_JSON}" ] || echo '{}' > "${SETTINGS_JSON}"
    tmp="$(mktemp)"
    # Order matters: an extension that registers settings must load before the
    # extensions that use it. So dedupe by first occurrence rather than with
    # `unique`, which sorts alphabetically and would silently reorder loads.
    jq -s '.[0] * {packages: (
             ((.[0].packages // []) + (.[1].packages // []))
             | reduce .[] as $p ([]; if index([$p]) then . else . + [$p] end)
           )}' \
        "${SETTINGS_JSON}" "${SEED_AGENT}/settings.json" > "${tmp}" && mv "${tmp}" "${SETTINGS_JSON}"
fi

# Register the read-only skills mount (see docker-compose.yml). pi accepts a
# `skills` array of files or directories in settings.json and scans it for
# directories containing SKILL.md, recursively. That's a documented hook, unlike
# symlinking into ~/.pi/agent/skills -- which would also require knowing whether
# pi's scanner follows symlinks, and would leave a dangling link in the config
# volume whenever the mount is absent.
#
# Bare .md files at the root of a configured skills path are NOT treated as
# skills (that only happens in ~/.pi/agent/skills and .pi/skills), so a README
# in your skills directory is harmless.
SKILLS_MOUNT=/opt/pi-skills
SKILLS_MOUNT_D=/opt/pi-skills.d

# Collect the skills paths that actually have something in them. Registering
# /opt/pi-skills.d once is enough to cover every directory mounted beneath it,
# because discovery recurses.
skill_paths=""
[ -d "${SKILLS_MOUNT}" ] && skill_paths="${SKILLS_MOUNT}"
if [ -d "${SKILLS_MOUNT_D}" ] && [ -n "$(ls -A "${SKILLS_MOUNT_D}" 2>/dev/null)" ]; then
    skill_paths="${skill_paths}${skill_paths:+ }${SKILLS_MOUNT_D}"
fi

if [ -n "${skill_paths}" ]; then
    if [ -z "$(find ${skill_paths} -name SKILL.md -print -quit 2>/dev/null)" ]; then
        echo "note: no SKILL.md found under ${skill_paths}; no custom skills will load." >&2
    fi
    SETTINGS_JSON="${AGENT_DIR}/settings.json"
    [ -f "${SETTINGS_JSON}" ] || echo '{}' > "${SETTINGS_JSON}"
    add_json="$(printf '%s\n' ${skill_paths} | jq -R . | jq -s .)"
    tmp="$(mktemp)"
    # Dedupe by first occurrence, so re-running never duplicates entries and
    # any skills paths you added by hand keep their position.
    jq --argjson add "${add_json}" \
       '.skills = (((.skills // []) + $add)
                   | reduce .[] as $s ([]; if index([$s]) then . else . + [$s] end))' \
       "${SETTINGS_JSON}" > "${tmp}" && mv "${tmp}" "${SETTINGS_JSON}"
fi

fi  # end pi-only extension + skills setup

# The bind-mounted project is owned by the host user; git refuses to operate
# on "dubious ownership" even when the uids match across a mount boundary.
git config --global --add safe.directory '*' 2>/dev/null || true

# Build the provider entry. Note the apiKey value (${KEY_REF}): it is a
# *reference* to the env var, not the secret itself -- pi resolves a leading
# `$NAME` at request time, omp treats the value as an env-var name. Either way
# the token stays in the container's env and never touches the config volume.
#
# The same jq object serves both agents: pi reads models.json and omp reads
# models.yml, and JSON is valid YAML. We merge rather than overwrite, so
# anything you add by hand (extra providers, compat flags, models) survives.
provider_entry="$(jq -n \
    --arg baseUrl   "${PI_BASE_URL}" \
    --arg api       "${PI_API}" \
    --arg keyRef    "${KEY_REF}" \
    --arg id        "${PI_MODEL_ID}" \
    --arg name      "${PI_MODEL_NAME}" \
    --argjson ctx   "${PI_CONTEXT_WINDOW}" \
    --argjson maxT  "${PI_MAX_TOKENS}" \
    --argjson think "${PI_REASONING}" \
    --argjson cost  "${PI_COST_JSON}" \
    '{
      baseUrl: $baseUrl,
      api: $api,
      apiKey: $keyRef,
      models: [{
        id: $id,
        name: $name,
        reasoning: $think,
        input: ["text"],
        contextWindow: $ctx,
        maxTokens: $maxT,
        cost: $cost
      }]
    }')"

# Optional escape hatch for partially-compatible servers, e.g.
#   PI_COMPAT_JSON='{"supportsDeveloperRole":false,"supportsUsageInStreaming":false}'
if [ -n "${PI_COMPAT_JSON:-}" ]; then
    provider_entry="$(jq --argjson c "${PI_COMPAT_JSON}" '. + {compat: $c}' <<<"${provider_entry}")"
fi

tmp="$(mktemp)"
jq --arg p "${PI_PROVIDER}" --argjson entry "${provider_entry}" \
   '.providers = ((.providers // {}) + { ($p): $entry })' \
   "${MODELS_JSON}" > "${tmp}" && mv "${tmp}" "${MODELS_JSON}"

# Management subcommands take no provider/model selector, so let them through raw.
case "${1:-}" in
    install|uninstall|update|config|list|packages)
        exec "${AGENT_BIN}" "$@"
        ;;
esac

# pi selects with --provider + --model; omp's --provider is legacy and it
# prefers a canonical `provider/modelId` selector passed to --model.
if [ "${PI_AGENT}" = omp ]; then
    exec omp --model "${PI_PROVIDER}/${PI_MODEL_ID}" "$@"
else
    exec pi --provider "${PI_PROVIDER}" --model "${PI_MODEL_ID}" "$@"
fi
