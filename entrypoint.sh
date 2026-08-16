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
#
# Set in two steps rather than as ${PI_COST_JSON:-{...}}: bash ends a
# ${var:-default} at the first unescaped `}`, which in that one-liner is the
# brace closing the JSON, leaving the final `}` as a literal character after the
# expansion. Unset, that stray brace happened to re-close the truncated default
# and the value came out right -- so the bug stayed invisible. Set, it was
# appended to *your* value, jq refused the result ("invalid JSON text passed to
# --argjson"), and `set -e` took the whole startup down with it.
PI_COST_JSON="${PI_COST_JSON:-}"
if [ -z "${PI_COST_JSON}" ]; then
    PI_COST_JSON='{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}'
fi

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
#   - the provider *name* differs. omp ships a catalog of built-in providers
#     (anthropic, openai, google, ...) whose Anthropic entry is OAuth/bearer-first
#     -- selecting it makes omp prompt for interactive login, or send a raw
#     sk-ant- key as an Authorization: Bearer token (Anthropic: 401 "Invalid
#     bearer token"). So omp gets a private, collision-proof provider name; its
#     `api: anthropic-messages` + apiKey then authenticates with x-api-key, the
#     way pi already does. pi has no such catalog, so it keeps PI_PROVIDER.
PI_AGENT="${PI_AGENT:-pi}"
case "${PI_AGENT}" in
    pi)  AGENT_BIN=pi;  AGENT_CONFIG_HOME="${HOME}/.pi";  MODELS_FILE=models.json; KEY_REF='$PI_API_KEY'; AGENT_PROVIDER="${PI_PROVIDER}" ;;
    omp) AGENT_BIN=omp; AGENT_CONFIG_HOME="${HOME}/.omp"; MODELS_FILE=models.yml;  KEY_REF='PI_API_KEY';  AGENT_PROVIDER=pibot-sandbox ;;
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

# --- serialize config mutations across concurrent agent containers -----------
# Several ./pi runs can start in the same second, and every one of them
# read-modify-writes models.json and settings.json in the *shared* config
# volume. Each write is `jq > tmp && mv`, so mv's atomicity means nothing ever
# corrupts -- but without a lock the last writer silently discards the others'
# merges, and a seeded extension registration can vanish for no visible reason.
# pi locks its own settings/trust/auth writes with proper-lockfile; this covers
# ours. Held until after the provider entry is merged, then released.
CONFIG_LOCK="${AGENT_DIR}/.pibot-config.lock"
config_locked=false
if command -v flock >/dev/null 2>&1; then
    exec 9>"${CONFIG_LOCK}"
    if flock -w 30 9; then
        config_locked=true
    else
        echo "warning: timed out waiting for ${CONFIG_LOCK}; continuing without the lock" >&2
    fi
fi

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

# Register (or unregister) the status extension, mounted read-only from the
# repo's status/extension directory. It publishes this run's live state into the
# run registry that the status viewer reads; see status/extension/index.ts.
#
# Toggling PIBOT_STATUS has to remove the entry as well as add it: settings.json
# lives in a persistent volume, so a stale path would otherwise linger there
# long after the feature was turned off.
STATUS_EXT=/opt/pibot-status/index.ts
SETTINGS_JSON="${AGENT_DIR}/settings.json"
if [ "${PIBOT_STATUS:-1}" != "0" ] && [ -f "${STATUS_EXT}" ]; then
    [ -f "${SETTINGS_JSON}" ] || echo '{}' > "${SETTINGS_JSON}"
    tmp="$(mktemp)"
    jq --arg ext "${STATUS_EXT}" \
       '.extensions = (((.extensions // []) + [$ext])
                       | reduce .[] as $e ([]; if index([$e]) then . else . + [$e] end))' \
       "${SETTINGS_JSON}" > "${tmp}" && mv "${tmp}" "${SETTINGS_JSON}"
elif [ -f "${SETTINGS_JSON}" ]; then
    tmp="$(mktemp)"
    jq --arg ext "${STATUS_EXT}" \
       'if .extensions then .extensions |= map(select(. != $ext)) else . end' \
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
jq --arg p "${AGENT_PROVIDER}" --argjson entry "${provider_entry}" \
   '.providers = ((.providers // {}) + { ($p): $entry })' \
   "${MODELS_JSON}" > "${tmp}" && mv "${tmp}" "${MODELS_JSON}"

# Config is settled; let the next container in.
#
# Note the bare `exec 9>&-`: an `exec` carrying any other redirection would
# apply it to the rest of this script *and* to the agent it execs at the end, so
# a defensive-looking `2>/dev/null` here would silently discard every error pi
# ever printed. Closing an fd that was never opened is not an error, so this
# needs no guard.
if [ "${config_locked}" = true ]; then
    flock -u 9
fi
exec 9>&-

# Management subcommands take no provider/model selector, so let them through raw.
case "${1:-}" in
    install|uninstall|update|config|list|packages)
        exec "${AGENT_BIN}" "$@"
        ;;
esac

# --- per-run identity --------------------------------------------------------
# Every ./pi invocation is its own container, and they all share one config
# volume. Without a distinct session id per run, two agents in the same project
# directory can end up appending to the same session file: pi writes session
# entries with a plain appendFileSync and `-c` resolves to "most recent file for
# this cwd" with no ownership check, so two conversations interleave into one
# tree. Giving each run its own id also makes the session file self-identifying
# -- the filename is <timestamp>_<sessionId>.jsonl, which is what lets the
# status viewer attribute a transcript to a container without guessing.
#
# Session ids accept [A-Za-z0-9._-] and must start and end alphanumeric, so the
# id the ./pi wrapper mints is human-readable rather than a bare UUID.
PIBOT_RUN="${PIBOT_RUN:-run-$(date +%Y%m%d-%H%M%S)-$$}"
export PIBOT_RUN
# Always under ~/.pi even for omp: compose mounts both config volumes into every
# agent container, so one registry covers both agents and the viewer has exactly
# one place to look.
PIBOT_RUN_DIR="${PIBOT_RUN_DIR:-${HOME}/.pi/agent/.pibot/runs}"
export PIBOT_RUN_DIR

session_args=()
PIBOT_SESSION_ID_INJECTED=0
wants_own_session=false
wants_continue=false
wants_name=false
for arg in "$@"; do
    case "${arg}" in
        # Anything that selects a session explicitly wins over our id.
        -c|--continue)                        wants_own_session=true; wants_continue=true ;;
        -r|--resume|--session|--session-id|--fork|--no-session) wants_own_session=true ;;
        -n|--name)                            wants_name=true ;;
    esac
done

# omp is a fork with its own CLI surface and no guarantee of --session-id, so
# the injection is pi-only. omp runs still get a run record; the viewer pairs it
# with a transcript by working directory instead of by filename.
if [ "${PI_AGENT}" = pi ]; then
    # Its own switch, separate from PIBOT_STATUS: per-run session ids are about
    # keeping concurrent containers off each other's transcripts, which matters
    # whether or not anyone is watching the status page. Set PIBOT_SESSION_ID=0
    # for pi's stock behavior (a fresh uuidv7 per session).
    if [ "${wants_own_session}" = false ] && [ "${PIBOT_SESSION_ID:-1}" != "0" ]; then
        session_args+=(--session-id "${PIBOT_RUN}")
        PIBOT_SESSION_ID_INJECTED=1
    fi
    if [ -n "${PIBOT_LABEL:-}" ] && [ "${wants_name}" = false ]; then
        session_args+=(--name "${PIBOT_LABEL}")
    fi
fi
export PIBOT_SESSION_ID_INJECTED

# --- run registry ------------------------------------------------------------
# One small JSON record plus a heartbeat file per run. The record is refined by
# the status extension once pi is up (it knows the exact session file); this is
# the bootstrap version, and for omp it is the only version.
if [ "${PIBOT_STATUS:-1}" != "0" ] && mkdir -p "${PIBOT_RUN_DIR}" 2>/dev/null; then
    # Self-cleaning: records outlive their containers, so drop stale ones.
    find "${PIBOT_RUN_DIR}" -maxdepth 1 -type f \( -name '*.json' -o -name '*.beat' \) \
        -mtime +7 -delete 2>/dev/null || true

    if [ "${wants_continue}" = true ]; then
        # `-c` deliberately reuses an existing session file, which is the one
        # case where two live containers can collide on the same transcript.
        for beat in $(find "${PIBOT_RUN_DIR}" -maxdepth 1 -name '*.beat' -mmin -1 2>/dev/null); do
            other="${beat%.beat}.json"
            [ -f "${other}" ] || continue
            [ "$(jq -r '.cwd // ""' "${other}" 2>/dev/null)" = "${PWD}" ] || continue
            [ "$(jq -r '.runId // ""' "${other}" 2>/dev/null)" != "${PIBOT_RUN}" ] || continue
            echo "warning: another live agent is running in ${PWD} ($(jq -r '.runId' "${other}" 2>/dev/null))." >&2
            echo "warning: with -c you may both append to the same session file and interleave two conversations." >&2
        done
    fi

    # Note `--arg runLabel`, not `--arg label`. `label` is a reserved word in jq
    # (`label $out | ... break $out`), and a reserved word cannot be a *variable*
    # name: jq 1.6 -- the version Debian bookworm ships, so the one in this
    # image -- fails to parse `$label` with "unexpected label, expecting IDENT".
    # jq 1.7 parses it happily, which is exactly what makes this worth a comment:
    # the program is only broken on the jq the container actually has. The bare
    # `label:` object key is fine on both; the variable is what bites.
    run_record="${PIBOT_RUN_DIR}/${PIBOT_RUN}.json"
    tmp="$(mktemp)"
    if jq -n \
        --arg runId     "${PIBOT_RUN}" \
        --arg agent     "${PI_AGENT}" \
        --arg runLabel  "${PIBOT_LABEL:-}" \
        --arg cwd       "${PWD}" \
        --arg model     "${PI_MODEL_ID}" \
        --arg provider  "${AGENT_PROVIDER}" \
        --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson injected "${PIBOT_SESSION_ID_INJECTED}" \
        '{
          "runId": $runId, "source": "entrypoint", "agent": $agent,
          "label": (if $runLabel == "" then null else $runLabel end),
          "cwd": $cwd, "model": $model, "provider": $provider,
          "startedAt": $startedAt, "state": "starting",
          "sessionIdInjected": ($injected == 1)
        }' > "${tmp}"
    then
        mv "${tmp}" "${run_record}"
    else
        # Loud, because the failure mode is otherwise invisible: the heartbeat
        # below would still tick, and the viewer skips a heartbeat with no
        # record, so the run would just quietly never appear as live.
        rm -f "${tmp}"
        echo "warning: could not write the run record for ${PIBOT_RUN}; this run will not show as live in the status view." >&2
    fi

    # Liveness. The extension cannot provide this on its own -- a killed
    # container never gets to write "ended", and for omp there is no extension
    # at all -- so an mtime-only heartbeat is what distinguishes "thinking hard"
    # from "gone". The loop is backgrounded before the exec below, gets
    # reparented to the container's init when pi replaces this shell, and dies
    # with the container.
    #
    # Its stdio is closed deliberately: a background child that keeps the
    # container's stdout open would stop `./pi -p ... | something` from seeing
    # EOF, and anything it printed would land in the middle of pi's TUI.
    beat_file="${PIBOT_RUN_DIR}/${PIBOT_RUN}.beat"
    (
        while :; do
            touch "${beat_file}" 2>/dev/null || exit 0
            sleep 5
        done
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
fi

# pi selects with --provider + --model; omp's --provider is legacy and it
# prefers a canonical `provider/modelId` selector passed to --model. The exact
# `provider/modelId` form also bypasses omp's coalescing, pinning our private
# provider instead of a built-in catalog entry with the same model id.
#
# ${arr[@]+"${arr[@]}"} so an empty array doesn't trip `set -u`.
if [ "${PI_AGENT}" = omp ]; then
    exec omp --model "${AGENT_PROVIDER}/${PI_MODEL_ID}" "$@"
else
    exec pi --provider "${AGENT_PROVIDER}" --model "${PI_MODEL_ID}" \
        ${session_args[@]+"${session_args[@]}"} "$@"
fi
