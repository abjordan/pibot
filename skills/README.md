# Custom skills

Drop skill directories here, or point `PI_SKILLS_DIR` in `.env` at a directory
elsewhere on your host. Either way it is mounted read-only at `/opt/pi-skills`
inside the container and registered in pi's `settings.json` on every start.

A skill is a directory containing a `SKILL.md`:

    my-skill/
    ├── SKILL.md      # required: frontmatter (name, description) + instructions
    ├── scripts/      # optional helper scripts
    ├── references/   # optional docs, loaded on demand
    └── assets/

`SKILL.md` needs YAML frontmatter with `name` and `description`. A skill with no
`description` is silently not loaded -- that is the most common reason a skill
does not appear.

Discovery is recursive, so nesting skills in subdirectories is fine. This
README is not picked up as a skill: bare `.md` files at the root of a configured
skills path are ignored (that rule only applies to `~/.pi/agent/skills/`).

Verify what loaded with `/skills` inside a session, or force one with
`/skill:my-skill`.
