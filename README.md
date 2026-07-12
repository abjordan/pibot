# pi-sandbox

Run the [pi coding agent](https://pi.dev) against your current directory, inside a container that can only reach your LAN inference server and an allowlist of package registries.

## Layout

```
pi-sandbox/
├── .env                     ← your copy of .env.example
├── Dockerfile               ← agent image: node + python + pi
├── docker-compose.yml
├── entrypoint.sh            ← renders models.json, execs pi
├── pi                       ← launcher (chmod +x)
├── pi-allow                 ← allowlist helper (chmod +x)
├── skills/                  ← default custom-skills dir (or set PI_SKILLS_DIR)
├── proxy/
│   ├── Dockerfile           ← squid image (a different file!)
│   ├── entrypoint.sh        ← parses PI_BASE_URL into ACLs (a different file!)
│   ├── squid.conf
│   ├── allowlist.txt
│   └── allowlist.local.txt
└── tunnel/
    └── Dockerfile           ← optional autossh sidecar
```

pi deliberately ships no permission system — it runs with the permissions of whoever launched it, and upstream's own advice for stronger boundaries is "run it in a container." This is that container.

## How it's put together

```
┌─────────────┐   HTTP_PROXY   ┌───────────┐
│   agent     │───────────────▶│   proxy   │──▶ 192.168.1.50:8080   (inference)
│             │                │  (squid)  │──▶ registry.npmjs.org  (allowlisted)
│  pi + node  │                │           │──▶ pypi.org            (allowlisted)
│  + python   │                │ allowlist │──✗ everything else
└─────────────┘                └───────────┘
   pi-egress                   pi-egress +
  (internal:true)               pi-outbound
```

Two walls, independent of each other:

1. **No route.** `pi-egress` is an `internal` Docker network. No default route, no NAT. The agent cannot open a socket to your LAN or the internet even if it wanted to. The only reachable host is `proxy`.
2. **No permission.** Squid enforces a destination allowlist. Your inference server is pinned by address (or name); everything else must be an explicit allowlist entry.

The agent talks to the proxy because pi installs undici's `EnvHttpProxyAgent` globally, so it honors `HTTP_PROXY`/`HTTPS_PROXY` for its own model calls — as do npm, pip, curl, and git-over-https, which is what the model reaches for when it runs `bash`.

## Setup

```bash
chmod +x pi pi-allow
cp .env.example .env
$EDITOR .env          # set PI_BASE_URL, PI_API_KEY, PI_MODEL_ID
docker compose build
```

Then, from any project directory:

```bash
/path/to/pi-sandbox/pi
```

Symlink it onto your `PATH` if you like: `ln -s "$PWD/pi" ~/.local/bin/pi-safe`.

The wrapper mounts `$PWD` at the same path inside the container, passes your uid/gid so new files come out owned by you, and forwards every argument to pi. The matching path matters: pi keys saved sessions by working directory, so each project gets its own session history and `pi -c` resumes the right one.

```bash
pi                        # interactive
pi "port this to asyncio" # interactive with an opening prompt
pi -c                     # continue the last session for this directory
pi -p "explain build.rs"  # one-shot
```

## Where your credentials live

`PI_BASE_URL` and `PI_API_KEY` come out of `.env` into the container's environment. The entrypoint renders `~/.pi/agent/models.json` at startup and writes the token as the literal string `$PI_API_KEY` — pi resolves a leading `$NAME` against the process environment when it makes a request. **The secret is never written to the config volume.** Rotate it by editing `.env` and restarting; nothing on disk needs cleaning up.

The generated provider entry is merged, not overwritten, so anything you add to `models.json` by hand survives a restart.

## Using a hosted API (Anthropic / OpenAI)

The sandbox works against a web endpoint just as well as a LAN server — no proxy or network changes. The egress allowlist for inference is generated from the host in `PI_BASE_URL`, so `api.anthropic.com` or `api.openai.com` is permitted automatically, and Squid tunnels the HTTPS `CONNECT` straight through (end-to-end TLS with the container's CA bundle — Squid never sees the plaintext).

Two extra knobs make it work:

- **`PI_API`** — the wire protocol pi speaks. Unset it defaults to `openai-completions`, so nothing changes for a local OpenAI-compatible server. Set it for a hosted API: `anthropic-messages`, `openai-completions`, `openai-responses`, or `google-generative-ai`.
- **`PI_API_KEY`** — a real key now. It is still stored only as the `$PI_API_KEY` reference described above, so it never lands on the config volume.

```ini
# Anthropic API (note: no /v1 on the base URL)
PI_BASE_URL=https://api.anthropic.com
PI_API=anthropic-messages
PI_API_KEY=sk-ant-...
PI_MODEL_ID=claude-sonnet-4-5
PI_CONTEXT_WINDOW=200000
PI_MAX_TOKENS=64000
PI_REASONING=true
```

```ini
# OpenAI API (keep the /v1)
PI_BASE_URL=https://api.openai.com/v1
PI_API=openai-completions
PI_API_KEY=sk-...
PI_MODEL_ID=gpt-4o
```

For paid endpoints, set `PI_COST_JSON` (dollars per million tokens) so pi's `/cost` reports real spend; unset, costs stay at `0` as they do for a free local server. See `.env.example` for the full set of options.

## Reaching a tunnel on the host

If your API server is only reachable through an SSH tunnel you run on the host, `localhost:11666` will not work from `.env`. Inside a container, `localhost` is the container's own loopback interface. Your tunnel is bound to the *host's* loopback, and nothing bridges the two.

Only the proxy needs to solve this. The agent hands every request to Squid, and Squid makes the outbound connection — so the agent stays sealed on the internal network either way.

**Recommended: run the tunnel inside compose.** This depends on no host-networking behavior, is identical on macOS and Linux, and binds the forwarded port inside a container rather than on your host — so nothing is exposed to your LAN.

```ini
SSH_TARGET=me@gpu-box            # what you'd type after `ssh`
SSH_REMOTE=127.0.0.1:11434       # the endpoint as seen from the remote box
PI_BASE_URL=http://tunnel:11666/v1
```
```bash
docker compose --profile tunnel up -d tunnel
./pi
```

Your `~/.ssh` is mounted read-only, `autossh` reconnects if the link drops, and the `tunnel` container sits on `pi-outbound` only — the agent cannot reach it directly, so inference traffic still passes the proxy's allowlist.

**Or keep the tunnel on the host, Docker Desktop.** Use Desktop's own `host.docker.internal`. Do **not** add `extra_hosts: host.docker.internal:host-gateway` — Desktop already provides the name, and the override replaces it with the bridge gateway *inside the VM*, which is not your host. Whether Desktop forwards to a tunnel bound on the host's `127.0.0.1` varies across Desktop, Colima, Rancher, and OrbStack. If you see `503 TCP_TUNNEL` in the proxy log, yours doesn't.

**Or keep the tunnel on the host, Linux.** `host.docker.internal` does not exist there. A tunnel bound to `127.0.0.1` is unreachable — the host's loopback is not on any bridge. `pi-outbound` pins its subnet, so the host is always `172.28.166.1` on it:

```bash
docker compose up -d proxy    # creates the bridge, so the address exists
ssh -N -L 172.28.166.1:11666:127.0.0.1:11434 gpu-box
```
```ini
PI_BASE_URL=http://172.28.166.1:11666/v1
```

An explicit `bind_address` in `-L` overrides ssh's `GatewayPorts` setting, so this needs no ssh config changes. The bridge must exist before ssh can bind to it, and `docker compose down` removes the bridge and kills the tunnel with it.

Resist `-L 0.0.0.0:11666:...`. That exposes your inference server, and its token, to everyone on your LAN.

**Why an IP beats a name.** With an IP literal the proxy entrypoint pins your server with a Squid `dst` ACL and no DNS is involved. A hostname becomes a `dstdomain` ACL, which Squid must resolve — and name resolution inside Docker has sharp edges. `squid.conf` deliberately does *not* set `hosts_file`: that would preload `/etc/hosts` into Squid's IP cache and shadow DNS, which on Docker Desktop means pinning `host.docker.internal` to an IPv6 address the IPv4-only bridges can't route to. `dns_v4_first on` then makes Squid prefer the A record it gets from Docker's embedded DNS.

## Growing the allowlist

The baseline covers npm, PyPI, GitHub, and Debian. When the agent gets blocked, you'll see it — either in pi's tool output or in the proxy log.

```bash
./pi-allow --tail        # watch decisions in a second terminal; TCP_DENIED = blocked
./pi-allow .crates.io    # add + apply live, no restart, session survives
./pi-allow               # show the effective list
./pi-allow --reload      # after hand-editing proxy/allowlist.local.txt
```

`proxy/allowlist.txt` is the reviewable baseline; `proxy/allowlist.local.txt` is yours. A leading dot matches subdomains (`.npmjs.org` covers `registry.npmjs.org`); no dot is an exact match.

## What this protects you from, and what it doesn't

**Does:** an agent that `rm -rf`s outside the project, writes to `~/.ssh`, reads your host credentials, curls a pastebin, pip-installs from a typosquatted index you never approved, or wanders onto your LAN. It runs unprivileged, with all capabilities dropped, `no-new-privileges`, and a pid cap.

**Doesn't:**

- **Your working directory is bind-mounted read-write.** That's the point — the agent has to edit your code. It can also mangle it. Use git and keep the tree clean before a long autonomous run; pi has no built-in undo. This is the one "oopsie" a container structurally cannot prevent.
- **Allowlisted domains are trusted completely.** `.github.com` is on the list, and a determined agent could POST data somewhere under it. Squid resolves CONNECT targets itself, so a client can't smuggle traffic to an arbitrary IP under an allowed name — but an allowed name is an allowed name.
- **No TLS interception**, by design. That means no cert-pinning headaches, but also that the proxy sees only the hostname of an HTTPS request, not the path.
- **Plain HTTP to your inference box puts the token on the wire in the clear.** Fine on a trusted LAN; worth knowing.
- **git over SSH won't work.** No proxy for it. Use HTTPS remotes, or add an entry and a token.

## Adding skills

Point `.env` at one directory, or several:

```ini
PI_SKILLS_DIR=/home/user/my-custom-skills                       # one
PI_SKILLS_DIRS=/home/user/my-skills:~/team-skills:/opt/shared   # many, colon-separated
```

```bash
./pi    # no rebuild needed
```

Both are mounted read-only and registered in pi's `settings.json` `skills` array on every start. Unlike extensions, skills need no build step — edit a `SKILL.md` on the host and the next `./pi` picks it up. If you set neither, the bundled `./skills` directory is used, so you can just drop skills in there.

The two knobs exist because compose can't expand a variable into a variable *number* of mounts. `PI_SKILLS_DIR` is a plain compose bind at `/opt/pi-skills`. `PI_SKILLS_DIRS` is split by the `pi` wrapper into one `run -v` per entry, landing at `/opt/pi-skills.d/NN-<basename>` — they can't nest under `/opt/pi-skills`, since you can't create mountpoints inside a read-only bind. Only `/opt/pi-skills.d` is registered, not each child: discovery recurses, so one entry covers them all.

Consequences worth knowing:

- **Order matters.** On duplicate skill *names*, pi warns and keeps the first found. Entries are mounted in the order listed and prefixed `01-`, `02-`, … so that order is deterministic rather than left to filesystem iteration.
- Two directories with the same basename are fine — the numeric prefix keeps them apart.
- `~` is expanded in `PI_SKILLS_DIRS` (by the wrapper) but **not** in `PI_SKILLS_DIR` (compose doesn't).
- A directory that doesn't exist is skipped with a warning rather than failing the run.
- Paths containing `:` can't go in `PI_SKILLS_DIRS`. Use `PI_SKILLS_DIR` for those.

A skill is a directory with a `SKILL.md` (YAML frontmatter: `name`, `description`). Discovery recurses into subdirectories. Bare `.md` files at the root of a configured skills path are *not* skills — that rule applies only to `~/.pi/agent/skills/` — so a `README.md` alongside them is harmless.

**Read-only is deliberate.** pi only ever reads a configured skills path, so nothing is lost, and the agent can't rewrite the instructions it's about to follow. The one thing it blocks is a skill whose setup says "run `npm install` in the skill directory." For those, either install the dependency in the `Dockerfile`, or copy that skill into the writable `~/.pi/agent/skills/` inside the container.

**A skill with no `description` in its frontmatter is silently not loaded.** That's the usual reason one doesn't show up. Check what actually loaded with `/skills` in a session, or force one with `/skill:my-skill`. The entrypoint also prints a note if the mounted directory contains no `SKILL.md` at all.

## Extra system packages

```ini
PI_APT_PACKAGES=ripgrep fd-find postgresql-client libpq-dev
```
```bash
docker compose build agent
```

This is the *only* way to add system packages. The agent runs unprivileged with all capabilities dropped, so it cannot `apt-get` at runtime — and image builds bypass the proxy, so nothing needs allowlisting.

The layer runs as root, immediately before the image drops to the `pi` user. That position is deliberate: below the npm/extension layers, so changing the list doesn't rebuild them; above the pip layer, so `libpq-dev` is installed by the time `psycopg2` compiles against it. Put build dependencies in `PI_APT_PACKAGES` and the Python packages that need them in `PI_PIP_PACKAGES`.

Version pins survive word-splitting (`curl=7.88.1-10+deb12u5`, epochs included). An unknown package exits 100 and fails the build rather than silently producing an image without the tool. An empty list is skipped — a bare `apt-get install` is an error.

## Extra Python packages

```ini
PI_PIP_PACKAGES=pandas>=2.0 requests httpx[http2] ruff
```
```bash
docker compose build agent
```

Installed into the container's venv as the last image layer, so changing the list doesn't rebuild the npm/extension layers above it. It runs as the `pi` user, not root, which keeps `/opt/venv` writable — the agent can still `pip install` more mid-session (those vanish when the container exits, and must pass the proxy allowlist; `.pypi.org` and `.pythonhosted.org` are already on it).

Two syntax rules, both load-bearing:

- **No spaces inside a spec.** Write `pandas>=2.0`, not `pandas >= 2.0`. The list is word-split, so spaces turn one requirement into three packages named `pandas`, `>=`, and `2.0`.
- **`>` is safe.** It looks like a shell redirection but isn't: redirection operators are recognized before variable expansion, so a `>` arriving from `${PI_PIP_PACKAGES}` stays part of the requirement. (A `>` written literally in the Dockerfile *would* redirect. That's why the list is interpolated, never inlined.)

An empty `PI_PIP_PACKAGES` is skipped rather than running a bare `pip install`, which errors. A package that fails to install fails the build. `pip check` runs afterward and warns about dependency conflicts without failing.

Build-time installs pull from PyPI directly, not through the Squid allowlist — image builds don't go through the proxy. For *system* packages, use `PI_APT_PACKAGES` above.

## Installing extensions

Set in `.env`, then rebuild:

```ini
PI_EXTENSIONS=npm:@juanibiapina/pi-extension-settings npm:@juanibiapina/pi-powerbar
```
```bash
docker compose build agent
./pi
```

`pi install` writes to `~/.pi/agent/npm/` and `~/.pi/agent/settings.json` — both inside the `pi-config` volume. A plain `RUN pi install ...` in the Dockerfile would build fine and then have zero effect at runtime, silently: Docker seeds a named volume's contents from the image only the very first time that volume is used, never again, so anything the image adds later just sits under a volume that already has its own copy of `~/.pi`.

Extensions are installed at build time into a seed path outside `~/.pi` instead. The entrypoint merges the seed into `~/.pi/agent` on every start — new packages copied in, `settings.json`'s `packages` array unioned, nothing you've changed by hand overwritten. That merge is what makes it survive a `pi-config` volume that predates the extensions, or one you delete later per the troubleshooting section below.

`pi list` inside a session shows what's active. Anything not on the npm/git allowlist will fail to install — see "Growing the allowlist" above; `.npmjs.org` and `.github.com` are already there for most packages.

**Load order matters.** `pi-extension-settings` hands out settings registration via an event emitted at load time, so anything registering settings with it must come *after* it in the list. The merge dedupes by first occurrence rather than sorting, so the order in `PI_EXTENSIONS` is the order in `settings.json`. One exception: packages you installed at runtime with `pi install` keep their existing position, and seeded ones get appended after them. If that produces a bad order, edit `~/.pi/agent/settings.json` directly, or wipe and re-seed as below.

**Bumping an extension's version doesn't update it.** The merge never overwrites an existing copy — on purpose, so it doesn't clobber changes you made by hand. That cuts both ways: if you change `PI_EXTENSIONS` to pin a newer version and rebuild, the volume still has the old one. Force a clean re-seed:

```bash
docker compose run --rm --entrypoint sh agent -c 'rm -rf ~/.pi/agent/npm'
./pi    # entrypoint re-merges from the freshly built seed
```

That discards runtime-installed extensions too; re-run `pi install` for those.

**Extensions built but never appear.** The entrypoint prints a warning if the build-time seed exists but can't be found at the path it expects. `pi install` writes to `$HOME/.pi/agent`, so the seed is at `/opt/pi-seed/.pi/agent` — note the `.pi`. Check it survived the build:

```bash
docker compose run --rm --entrypoint sh agent -c 'ls /opt/pi-seed/.pi/agent/npm && cat /opt/pi-seed/.pi/agent/settings.json'
docker compose run --rm --entrypoint sh agent -c 'cat ~/.pi/agent/settings.json'
```

The first shows what the image baked; the second shows what the running container merged. If the first is populated and the second isn't, the merge is broken. If both are populated, `pi` is loading them and the problem is elsewhere — check `pi list` in a session.

## Troubleshooting

**`mkdir: cannot create directory '/home/pi/.pi/agent': Permission denied`**

A named volume created before the image pre-created that path is owned by root. Docker seeds volume ownership only on first use, so rebuilding alone won't fix an existing volume — you have to remove it:

```bash
docker compose down
docker volume rm pi-sandbox_pi-config pi-sandbox_pi-npm-cache pi-sandbox_pi-pip-cache
docker compose build
```

This discards saved sessions. Nothing else lives there that isn't regenerated at startup.

**`unable to prepare context: path ".../proxy" not found`**

The `proxy/` subdirectory is missing. See the layout at the top of this file — the two `Dockerfile`s and two `entrypoint.sh`es are different files, not duplicates.

**`FATAL: Cannot open '/dev/stdout' for writing` (proxy crash-loops)**

Squid reopens its log files by path after dropping privileges, and Linux blocks a process from reaching its own `/proc/self/fd` once it has changed uid. `chmod` on `/dev/stdout` does not fix it — the proxy image therefore runs as `squid` from PID 1 and never setuids. If you see this, you're on an older build; rebuild the proxy:

```bash
docker compose build --no-cache proxy
```

**`503 TCP_TUNNEL:HIER_DIRECT` in the proxy log.** Squid resolved the destination, then failed to open a TCP connection to it — the name resolves to the wrong address, or nothing is listening there. Ask the proxy what it sees:

```bash
docker compose exec proxy getent hosts host.docker.internal
docker compose exec proxy sh -c 'nc -w2 host.docker.internal 11666 </dev/null && echo OPEN || echo CLOSED'
```

Three ways this goes wrong:

- **An IPv6 answer** (e.g. `fdc4:...::254`). Both bridges are IPv4-only, so there is no route to it. Compare `getent hosts` (reads `/etc/hosts` first) with `getent ahostsv4` (falls through to DNS): if the first is v6 and the second is v4, Squid must not preload the hosts file — hence no `hosts_file` directive, plus `dns_v4_first on`. If `getent ahostsv4` is empty, there is no A record at all; use the `tunnel` profile.
- **A `172.17.x.x` answer.** Something is overriding `host.docker.internal` with `host-gateway`.
- **Resolves fine but `CLOSED`.** Your tunnel is bound to the host's loopback and your Docker runtime won't forward there — use the `tunnel` profile.

`403 TCP_DENIED` is a different thing entirely: that's the allowlist working as intended.

**Everything the agent fetches times out.** Check the proxy is up and look for `TCP_DENIED` with `./pi-allow --tail`. If the proxy itself is down, the agent has no route anywhere and every connection hangs rather than failing fast.

**`WARNING: HTTP requires the use of Via` in the proxy log.** Expected. It's Squid objecting to `via off`, which is there so the proxy doesn't announce itself upstream. Harmless.

**`network pi-sandbox_pi-egress ... needs to be recreated`** — the egress subnet is pinned in newer builds. `docker compose down` (removes the old network; volumes survive), then start again.

## Notes

- `PI_MODEL_ID` must match what your server reports at `GET /v1/models`.
- If the model behaves strangely — missing token counts, rejected `developer` role, ignored reasoning effort — set `PI_COMPAT_JSON` in `.env`. llama.cpp and older vLLM builds usually want `{"supportsDeveloperRole":false,"supportsReasoningEffort":false}`.
- Sessions persist in the `pi-config` volume, keyed by working directory, so `pi -c` works across container restarts. (Sessions saved by builds before the mount path matched the host path were keyed to `/work` and won't be found by `pi -c`; they're still in the volume, just orphaned.)
- `pi install`, `pi update`, and `pi config` are passed through unmodified — the entrypoint only injects `--provider`/`--model` for agent runs.
- Pin the agent version with `PI_VERSION` in `.env` if you'd rather not track `latest`.
