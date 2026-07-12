#!/usr/bin/env bash
set -euo pipefail

: "${PI_BASE_URL:?PI_BASE_URL is not set (e.g. http://192.168.1.50:8080/v1)}"
: "${PI_MODEL_ID:?PI_MODEL_ID is not set (e.g. qwen3-coder-30b)}"

PI_PROVIDER="${PI_PROVIDER:-local}"
PI_MODEL_NAME="${PI_MODEL_NAME:-${PI_MODEL_ID}}"
PI_CONTEXT_WINDOW="${PI_CONTEXT_WINDOW:-131072}"
PI_MAX_TOKENS="${PI_MAX_TOKENS:-16384}"
PI_REASONING="${PI_REASONING:-false}"

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

AGENT_DIR="${HOME}/.pi/agent"
MODELS_JSON="${AGENT_DIR}/models.json"

# A named volume created before the image pre-created this path will be owned by
# root, and no amount of rebuilding fixes an already-populated volume.
if ! mkdir -p "${AGENT_DIR}" 2>/dev/null || [ ! -w "${AGENT_DIR}" ]; then
    cat >&2 <<'MSG'
error: cannot write to ~/.pi -- the pi-config volume is owned by root.

Docker seeds a named volume's ownership only the first time it is used, so a
volume created by an older build stays root-owned forever. Recreate it:

    docker compose down
    docker volume rm pi-sandbox_pi-config pi-sandbox_pi-npm-cache pi-sandbox_pi-pip-cache
    docker compose build
MSG
    exit 1
fi

[ -f "${MODELS_JSON}" ] || echo '{}' > "${MODELS_JSON}"

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

# The bind-mounted project is owned by the host user; git refuses to operate
# on "dubious ownership" even when the uids match across a mount boundary.
git config --global --add safe.directory '*' 2>/dev/null || true

# Build the provider entry. Note the apiKey value: pi resolves a leading `$NAME`
# against the process environment at request time, so we store the *reference*,
# not the secret. The token stays in the container's env and never touches the
# ~/.pi volume on disk.
#
# We merge rather than overwrite, so anything you add to models.json by hand
# (extra providers, compat flags, additional models) survives a restart.
provider_entry="$(jq -n \
    --arg baseUrl   "${PI_BASE_URL}" \
    --arg api       "${PI_API}" \
    --arg keyRef    '$PI_API_KEY' \
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

# `pi update` / `pi install` and friends take no --provider flag, so let them through raw.
case "${1:-}" in
    install|uninstall|update|config|list|packages)
        exec pi "$@"
        ;;
esac

exec pi --provider "${PI_PROVIDER}" --model "${PI_MODEL_ID}" "$@"
