#!/bin/bash
# =============================================================================
# AI Chief of Staff for SEO Agencies — server bootstrap (Ubuntu 24.04, run as root)
#
# One-line install from the Hostinger Web Console:
#   curl -fsSL <RAW_URL_OF_THIS_FILE> -o /root/bootstrap.sh && \
#   AGENCY_NAME="Acme SEO" COS_NAME="Rubi" OWNER_NAME="Dana" TZ_NAME="America/New_York" \
#   bash /root/bootstrap.sh 2>&1 | tee /root/bootstrap.log
#
# Safe to re-run: it skips what already exists. It never stores secrets.
# Output ends with "BOOTSTRAP DONE" and the next steps.
# =============================================================================
set -euo pipefail

AGENCY_NAME="${AGENCY_NAME:-Our Agency}"
COS_NAME="${COS_NAME:-CoS}"
OWNER_NAME="${OWNER_NAME:-Owner}"
TZ_NAME="${TZ_NAME:-UTC}"
COS_USER="cos"
COS_HOME="${COS_HOME:-/home/cos}"
AGENCY_DIR="${AGENCY_DIR:-/srv/agency}"
SKIP_SYSTEM="${SKIP_SYSTEM:-0}"   # 1 = only write files (for testing)
export DEBIAN_FRONTEND=noninteractive

say() { printf '\n==> %s\n' "$*"; }
as_cos() { sudo -u "$COS_USER" -H bash -lc "$*"; }

# -----------------------------------------------------------------------------
# 1. System packages, user, firewall, runtimes
# -----------------------------------------------------------------------------
if [ "$SKIP_SYSTEM" != "1" ]; then
  [ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }

  say "Updating system and installing base packages"
  apt-get update -y
  apt-get -o Dpkg::Options::="--force-confold" upgrade -y
  apt-get install -y git tmux curl unzip jq python3 ufw fail2ban unattended-upgrades sudo ca-certificates
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
  timedatectl set-timezone "$TZ_NAME" || echo "WARNING: unknown time zone $TZ_NAME, kept current"

  say "Creating user $COS_USER (no password, no sudo)"
  id "$COS_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$COS_USER"

  say "Installing Tailscale"
  command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh

  say "Firewall: allow SSH (until lockdown) and Tailscale, deny everything else"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow in on tailscale0
  ufw --force enable

  say "Installing Node.js 22"
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi

  say "Installing headless browser dependencies"
  npx -y playwright install-deps chromium

  say "Installing Claude Code, Bun and Chromium for $COS_USER"
  as_cos 'command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash'
  as_cos '[ -x "$HOME/.bun/bin/bun" ] || curl -fsSL https://bun.sh/install | bash'
  as_cos 'npx -y playwright install chromium'

  say "Creating SSH key for GitHub (deploy key)"
  as_cos '[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -C "cos@$(hostname)" -f ~/.ssh/id_ed25519'
  as_cos 'ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null; sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts'
fi

# -----------------------------------------------------------------------------
# 2. Project folder and files
# -----------------------------------------------------------------------------
say "Writing project files to $AGENCY_DIR"
mkdir -p "$AGENCY_DIR"/{.claude/agents,.claude/skills,scripts}
mkdir -p "$AGENCY_DIR"/clients/_template/{data,drafts,approved,reports,projects}
mkdir -p "$AGENCY_DIR"/ops/{proposals,backups,briefs}
mkdir -p "$COS_HOME/.config"
for d in .claude/agents .claude/skills clients/_template/data clients/_template/drafts \
         clients/_template/approved clients/_template/reports clients/_template/projects \
         ops/proposals ops/backups ops/briefs; do
  touch "$AGENCY_DIR/$d/.gitkeep"
done

# write_once <path>: writes stdin only if the file doesn't exist yet
write_once() { if [ -e "$1" ]; then cat >/dev/null; else cat > "$1"; fi; }

# ---------- CLAUDE.md (the rulebook) ----------
write_once "$AGENCY_DIR/CLAUDE.md" <<'EOF'
# __COS__ — AI Operations Director (Chief of Staff) for __AGENCY__

You are __COS__, the AI Operations Director for __AGENCY__, an SEO agency.
You take requests from the team in Discord. Everyone on the allowlist has
equal authority. You do not do SEO work yourself: you assign it to
subagents, track it, and keep the team informed.

@ops/team.md
@ops/roster.md

## First run: owner interview (before any client work)
If ops/agency-profile.md does not exist, the agency is not configured yet.
Tell anyone who writes to you, and wait for the owner (see ops/team.md)
to write "start onboarding". Then interview the owner:
- One topic at a time, 2-4 questions per message, plain language.
  Summarize each topic back and ask "correct?" before moving on.
- Topics, in order:
  1. The agency today: services, niches, markets, number of clients, pricing.
  2. Goals: 12-month and 3-year targets (revenue, clients, margin, owner hours).
  3. This quarter's objectives and how success is measured.
  4. The team: each person, role, responsibilities, hours, Discord name,
     and what they should keep doing themselves.
  5. Tools and data: rank/grid tracker, CMS, reporting, logins we can get.
  6. Bottlenecks: what takes the most time, what goes wrong most.
  7. Quality bar: brand voice, what clients must never see, examples of great work.
  8. Future plans: new services, markets, hires, partnerships, white label.
  9. Limits: what agents must never do, what always needs a human.
- Save the answers in the owner's words to ops/agency-profile.md and the
  people to ops/team.md. Commit.
- Write ops/org-plan.md: departments and agents chosen from the Agent org
  blueprint (SEO Strategy, Local SEO, Content & Design, Technical SEO &
  WordPress, Link Building, AI Visibility/AEO, Security & Maintenance,
  Quality Control & Analytics). Tie every agent to a goal or bottleneck.
  List what to skip for now. Split into Wave 1 (max 10 agents, files and
  exports only), Wave 2 and Wave 3 (live access). List data tools needed.
- Post a short summary of the plan and ask the owner to approve it.
- After approval, draft the Wave 1 agents and their starter SOP skills as
  proposals (P-0001, P-0002, ...) and use the normal approval and install flow.
- "review org": run a short version of the interview (what changed?) and
  propose roster changes. Suggest a review in the daily brief every quarter.

## How you work
1. Resolve every request to exactly one client slug using clients/index.md
   (match slug, name or alias). 0 or 2+ matches: ask. Never guess.
2. Log a task in ops/queue.md (ID, client, task, agent, requested by, status).
3. Delegate to one subagent per task, in the background, so you stay free
   for the next message. Pass: task ID, full client folder path, SOP skill,
   output file path. Workers start their final summary with the task ID.
4. Every deliverable goes to its QA agent (content-qa for content)
   before anyone sees it; client-facing work also goes to master-qa.
5. Post QA-passed work to Discord with an approval ID. Never publish.
6. Anyone on the allowlist can approve. "approve <ID>" moves the file to
   approved/ and updates ops/approvals.md (with who approved) and changelog.md.

## Status lines (post exactly these, nothing more)
- On assign:  "T-0142 -> acme-plumbing, seo-writer: water heater page"
- After QA:   "T-0142 QA passed -> approve A-0087"
              or "T-0142 QA failed: <reason>, retrying"

## Clients and projects
- "onboard new client: <name>, <city>": make a lowercase-hyphen slug, copy
  clients/_template/, add a row to clients/index.md (status: setup), commit,
  and list the files the team must fill. Setup clients get audits and scans only.
- Projects live in clients/<slug>/projects/<project>/project.md.
  "acme-plumbing / spring-campaign: ..." means read brief.md, then project.md.

## Growing the team (agents and skills)
- When asked to create or change an agent or skill: ask what you need,
  draft it in ops/proposals/P-<ID>/agents/ or /skills/<name>/, dry-run it
  on one client, then post a summary ending in "approve P-<ID>".
  Agent files list tools on one line: "tools: Read, Write, Grep".
  Write descriptions as "Use for ... Not for ...".
- When anyone on the allowlist approves, run:
  python3 scripts/install.py ops/proposals/P-<ID> --approved-by "<name>"
  then update ops/roster.md. "roll back <name>": python3 scripts/rollback.py <name>
  "retire <name>": python3 scripts/rollback.py <name> --retire
- Changes to permissions, tool connections, scripts or this file: write the
  exact change to ops/proposals/ and tag the builder. You cannot apply them.

## Rules
- Never mix clients. One task = one client folder.
- Never invent data (rankings, reviews, addresses, phone numbers). Ask.
- Keep replies short: status, task ID, next step.
- Escalate to the owner only for client complaints, anything legal,
  or a task that failed QA twice.
- Commit to git after every completed task.
EOF
sed -i "s/__COS__/${COS_NAME//\//\\/}/g; s/__AGENCY__/${AGENCY_NAME//\//\\/}/g" "$AGENCY_DIR/CLAUDE.md"

# ---------- settings.json ----------
write_once "$AGENCY_DIR/.claude/settings.json" <<'EOF'
{
  "model": "claude-opus-5-5",
  "modelSettings": {
    "claude-opus-5-5": { "effortLevel": "medium" }
  },
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": [
      "Read(./**)",
      "Write(./clients/**)", "Edit(./clients/**)",
      "Write(./ops/**)", "Edit(./ops/**)",
      "WebSearch", "WebFetch",
      "Bash(git add *)", "Bash(git commit *)", "Bash(git push origin main)",
      "Bash(python3 scripts/install.py *)", "Bash(python3 scripts/rollback.py *)",
      "mcp__playwright__*"
    ],
    "deny": [
      "Read(./**/.env)", "Read(/home/cos/.config/**)",
      "Bash(rm *)", "Bash(sudo *)", "Bash(curl *)", "Bash(ssh *)",
      "Bash(git push --force*)", "Bash(git reset --hard*)",
      "Edit(./CLAUDE.md)", "Write(./CLAUDE.md)",
      "Edit(./scripts/**)", "Write(./scripts/**)"
    ]
  },
  "env": { "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1" },
  "hooks": {
    "SubagentStart": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/agent-log.sh" } ] }
    ],
    "SubagentStop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/agent-log.sh" } ] }
    ]
  }
}
EOF

write_once "$AGENCY_DIR/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless"] }
  }
}
EOF

# ---------- ops files ----------
write_once "$AGENCY_DIR/ops/team.md" <<'EOF'
# Team

| Name | Role | Discord name | Notes |
|------|------|--------------|-------|
| __OWNER__ | Owner | (fill in) | Runs the owner interview; escalations go here |
EOF
sed -i "s/__OWNER__/${OWNER_NAME//\//\\/}/g" "$AGENCY_DIR/ops/team.md"

write_once "$AGENCY_DIR/ops/roster.md" <<'EOF'
# Agent roster

No agents installed yet. Filled in after the owner interview and org plan.
EOF
write_once "$AGENCY_DIR/ops/queue.md" <<'EOF'
# Task queue

| ID | Client | Task | Agent | Requested by | Status |
|----|--------|------|-------|--------------|--------|
EOF
write_once "$AGENCY_DIR/ops/approvals.md" <<'EOF'
# Approvals

| ID | Task | Client | File | Approved by | Date |
|----|------|--------|------|-------------|------|
EOF
write_once "$AGENCY_DIR/ops/pilot-log.md" <<'EOF'
# Pilot log

| Date | Agent | What went wrong | Fix |
|------|-------|-----------------|-----|
EOF

# ---------- client registry and template ----------
write_once "$AGENCY_DIR/clients/index.md" <<'EOF'
# Client registry

| slug | name | aliases | location | owner | status |
|------|------|---------|----------|-------|--------|
EOF
write_once "$AGENCY_DIR/clients/_template/brief.md" <<'EOF'
# Client brief
- Business name, phone, address (exactly as on Google):
- Services (main first):
- Service areas:
- Years in business, licenses, guarantees (only true facts):
- Brand voice and words to avoid:
- Main conversion (call / booking form):
- Never say or do:
EOF
write_once "$AGENCY_DIR/clients/_template/targets.md" <<'EOF'
# Targets
- Main keywords per service:
- Grid scan settings (center, radius, points):
- KPIs we report on:
- Top 3 competitors:
EOF
write_once "$AGENCY_DIR/clients/_template/gbp.md" <<'EOF'
# Google Business Profile
- Primary and secondary categories:
- Services listed:
- Posting rules and offers:
- Approved photos (where they are):
- Banned claims:
EOF
write_once "$AGENCY_DIR/clients/_template/changelog.md" <<'EOF'
# Changelog (newest first)
EOF

# ---------- scripts ----------
write_once "$AGENCY_DIR/scripts/install.py" <<'EOF'
#!/usr/bin/env python3
"""Install an approved proposal into .claude/.
Usage: python3 scripts/install.py ops/proposals/P-0007 --approved-by "Sam"
Layout: agents/<name>.md and/or skills/<name>/SKILL.md (+ more .md files)
"""
import argparse, datetime, pathlib, re, shutil, subprocess, sys

ROOT = pathlib.Path("/srv/agency")
ALLOWED_TOOLS = {"Read", "Write", "Edit", "Glob", "Grep", "WebSearch", "WebFetch"}
ALLOWED_MCP = ("mcp__playwright__",)  # add tool servers here as the builder adds them
BANNED_KEYS = ("hooks", "mcpServers", "permissionMode", "allowed-tools", "isolation")
MODELS = {"haiku", "sonnet", "opus", "inherit"}
SLUG = re.compile(r"[a-z0-9-]+")

def fail(msg):
    sys.exit(f"REFUSED: {msg}")

def frontmatter(path):
    if not path.is_file():
        fail(f"missing {path.name}")
    m = re.match(r"---\n(.*?)\n---\n", path.read_text(), re.S)
    if not m:
        fail(f"{path.name}: missing frontmatter")
    raw = m.group(1)
    for key in BANNED_KEYS:
        if re.search(rf"^{key}\s*:", raw, re.M):
            fail(f"{path.name}: '{key}' is not allowed")
    pairs = [l.split(":", 1) for l in raw.splitlines() if re.match(r"^[A-Za-z-]+:", l)]
    return {k.strip(): v.strip() for k, v in pairs}

def check_agent(path):
    fm = frontmatter(path)
    name = fm.get("name", "")
    if not SLUG.fullmatch(name) or not fm.get("description"):
        fail(f"{path.name}: needs a lowercase name and a description")
    tools = [t.strip() for t in fm.get("tools", "").split(",") if t.strip()]
    if not tools:
        fail(f"{name}: list tools on one line, e.g. 'tools: Read, Write'")
    for t in tools:
        if t not in ALLOWED_TOOLS and not t.startswith(ALLOWED_MCP):
            fail(f"{name}: tool '{t}' is not allowed")
    if fm.get("model", "inherit") not in MODELS:
        fail(f"{name}: unknown model")
    return name

def check_skill(folder):
    for f in folder.rglob("*"):
        if f.is_file() and f.suffix != ".md":
            fail(f"skill {folder.name}: only .md files allowed ({f.name})")
    fm = frontmatter(folder / "SKILL.md")
    if not SLUG.fullmatch(fm.get("name", "")) or not fm.get("description"):
        fail(f"skill {folder.name}: needs a lowercase name and a description")
    return fm["name"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("proposal")
    ap.add_argument("--approved-by", required=True)
    a = ap.parse_args()
    prop = (ROOT / a.proposal).resolve()
    if not prop.is_dir() or not prop.is_relative_to(ROOT / "ops" / "proposals"):
        fail("proposal must be a folder in ops/proposals/")
    plan = []  # check everything before copying anything
    for f in sorted((prop / "agents").glob("*.md")):
        plan.append((f, ROOT / ".claude" / "agents" / f"{check_agent(f)}.md"))
    for d in sorted(p for p in (prop / "skills").glob("*") if p.is_dir()):
        plan.append((d, ROOT / ".claude" / "skills" / check_skill(d)))
    if not plan:
        fail("nothing to install")
    backup = ROOT / "ops" / "backups" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    for src, dst in plan:
        if dst.exists():
            (backup / dst.parent.name).mkdir(parents=True, exist_ok=True)
            shutil.move(str(dst), str(backup / dst.parent.name / dst.name))
        if src.is_dir():
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)
    names = ", ".join(dst.name for _, dst in plan)
    msg = f"Install {prop.name}: {names} (approved by {a.approved_by})"
    subprocess.run(["git", "-C", str(ROOT), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(ROOT), "commit", "--allow-empty", "-m", msg], check=True)
    print(f"INSTALLED {names}. Live within seconds, no restart needed.")

if __name__ == "__main__":
    main()
EOF

write_once "$AGENCY_DIR/scripts/rollback.py" <<'EOF'
#!/usr/bin/env python3
"""Restore the previous version of an agent or skill, or retire it.
Usage: python3 scripts/rollback.py seo-writer [--retire]
"""
import pathlib, re, shutil, subprocess, sys

ROOT = pathlib.Path("/srv/agency")
BACKUPS = ROOT / "ops" / "backups"
name = sys.argv[1] if len(sys.argv) > 1 else ""
if not re.fullmatch(r"[a-z0-9-]+", name):
    sys.exit("REFUSED: give an agent or skill name")

def commit(msg):
    subprocess.run(["git", "-C", str(ROOT), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(ROOT), "commit", "--allow-empty", "-m", msg], check=True)
    print(msg)
    sys.exit(0)

def place(src, dst):
    if dst.is_dir():
        shutil.rmtree(dst)
    elif dst.exists():
        dst.unlink()
    if src.is_dir():
        shutil.copytree(src, dst)
    else:
        shutil.copy2(src, dst)

if "--retire" in sys.argv:
    for kind, item in (("agents", f"{name}.md"), ("skills", name)):
        live = ROOT / ".claude" / kind / item
        if live.exists():
            (BACKUPS / "retired" / kind).mkdir(parents=True, exist_ok=True)
            shutil.move(str(live), str(BACKUPS / "retired" / kind / item))
            commit(f"Retired {name}")
    sys.exit(f"{name} is not installed")

for stamp in sorted(BACKUPS.glob("[0-9]*"), reverse=True):
    for kind, item in (("agents", f"{name}.md"), ("skills", name)):
        if (stamp / kind / item).exists():
            place(stamp / kind / item, ROOT / ".claude" / kind / item)
            commit(f"Rolled back {name} to the version saved {stamp.name}")
sys.exit(f"No earlier version of {name} found")
EOF

write_once "$AGENCY_DIR/scripts/run-job.sh" <<'EOF'
#!/usr/bin/env bash
# usage: scripts/run-job.sh "<job name>" "<webhook var>" "<prompt>"
# Scheduled jobs run on Sonnet to stretch the monthly Agent SDK credit.
set -uo pipefail
[ -f /home/cos/.config/cos-live ] || exit 0
source /home/cos/.config/cos.env 2>/dev/null || true
cd /srv/agency
OUT=$(timeout 30m claude -p "$3" --model sonnet --max-turns 60 2>&1 | tail -c 1800) || OUT="FAILED: $1"
HOOK="${!2:-}"
[ -n "$HOOK" ] || exit 0
jq -n --arg c "**$1**"$'\n'"$OUT" '{content:$c}' \
  | curl -s -m 20 -H 'Content-Type: application/json' -d @- "$HOOK" >/dev/null
EOF

write_once "$AGENCY_DIR/scripts/agent-log.sh" <<'EOF'
#!/usr/bin/env bash
# Posts subagent start/finish lines to #agent-log (called by Claude Code hooks)
source /home/cos/.config/cos.env 2>/dev/null || true
in=$(cat)
[ -n "${DISCORD_WEBHOOK_AGENTLOG:-}" ] || exit 0
event=$(jq -r '.hook_event_name' <<<"$in")
agent=$(jq -r '.agent_type // "agent"' <<<"$in")
if [ "$event" = "SubagentStart" ]; then
  msg="START $agent"
else
  summary=$(jq -r '.last_assistant_message // ""' <<<"$in" | tr '\n' ' ' | head -c 300)
  msg="DONE  $agent · $summary"
fi
jq -n --arg c "$msg" '{content:$c}' \
  | curl -s -m 10 -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_AGENTLOG" >/dev/null
exit 0
EOF

write_once "$AGENCY_DIR/scripts/set-secret.sh" <<'EOF'
#!/usr/bin/env bash
# usage: scripts/set-secret.sh KEY   (asks for the value without showing it)
set -euo pipefail
KEY="${1:-}"
ENVF=/home/cos/.config/cos.env
[[ "$KEY" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "usage: set-secret.sh KEY_NAME"; exit 1; }
read -rsp "Paste value for $KEY and press Enter: " VAL; echo
touch "$ENVF"; chmod 600 "$ENVF"
{ grep -v "^$KEY=" "$ENVF" || true; printf '%s=%q\n' "$KEY" "$VAL"; } > "$ENVF.tmp"
mv "$ENVF.tmp" "$ENVF"; chmod 600 "$ENVF"
echo "Saved $KEY"
EOF

write_once "$AGENCY_DIR/scripts/start-cos.sh" <<'EOF'
#!/usr/bin/env bash
# Starts the CoS in tmux once go-live is done, if it isn't already running.
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"
[ -f /home/cos/.config/cos-live ] || exit 0
tmux has-session -t cos 2>/dev/null && exit 0
tmux new-session -d -s cos -c /srv/agency \
  "claude --model claude-opus-5-5 --effort medium --channels plugin:discord@claude-plugins-official"
EOF

write_once "$AGENCY_DIR/scripts/go-live.sh" <<'EOF'
#!/usr/bin/env bash
# Turns on the always-on CoS session, scheduled jobs and the watchdog.
touch /home/cos/.config/cos-live
/srv/agency/scripts/start-cos.sh
sleep 3
tmux has-session -t cos 2>/dev/null && echo "CoS is running. Watch it with: tmux attach -t cos" \
  || echo "CoS did not start. Run it by hand to see the error: cd /srv/agency && claude"
EOF

write_once "$AGENCY_DIR/scripts/lockdown.sh" <<'EOF'
#!/usr/bin/env bash
# Run as root AFTER Tailscale works: closes public SSH and hardens sshd.
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }
TSIP=$(tailscale ip -4 2>/dev/null || true)
[ -n "$TSIP" ] || { echo "Tailscale is not up. Run: tailscale up --ssh"; exit 1; }
cat > /etc/ssh/sshd_config.d/99-cos.conf <<'CONF'
PermitRootLogin no
PasswordAuthentication no
CONF
systemctl restart ssh 2>/dev/null || systemctl restart sshd
ufw delete allow OpenSSH || true
ufw status verbose
echo "LOCKDOWN DONE. Reach the server over Tailscale: ssh cos@$TSIP (or the Hostinger Web Console)."
EOF

chmod +x "$AGENCY_DIR"/scripts/*.sh "$AGENCY_DIR"/scripts/*.py

# ---------- secrets file (empty) and crontab ----------
write_once "$COS_HOME/.config/cos.env" <<'EOF'
# Filled with scripts/set-secret.sh — never commit or share this file
EOF
chmod 600 "$COS_HOME/.config/cos.env"

cat > "$COS_HOME/.config/cos.crontab" <<'EOF'
PATH=/home/cos/.local/bin:/home/cos/.bun/bin:/usr/local/bin:/usr/bin:/bin
# Always-on CoS (starts only after scripts/go-live.sh)
*/5 * * * * /srv/agency/scripts/start-cos.sh
@reboot     sleep 30 && /srv/agency/scripts/start-cos.sh
10 3 * * *  tmux kill-session -t cos 2>/dev/null
# Scheduled jobs (skip themselves until go-live). Edit days to match your work week.
40 8 * * 1-5 /srv/agency/scripts/run-job.sh "Daily brief" DISCORD_WEBHOOK_BRIEF "Read ops/queue.md, ops/approvals.md, git log since yesterday and each clients/*/changelog.md. Write today's brief to ops/briefs/ in a file named with today's date: done yesterday, waiting for approval (with IDs), blocked, ranking alerts, agents or skills installed. Reply with the brief in under 1500 characters."
10 7 * * 1   /srv/agency/scripts/run-job.sh "Weekly grid check" DISCORD_WEBHOOK_ALERTS "For every active client in clients/index.md, use the grid ranking agent if installed to compare the newest grid scan in data/ with the previous one. Reply with drops and wins only, under 1500 characters."
45 2 * * *   cd /srv/agency && git add -A && git commit -qm "nightly backup"; git -C /srv/agency push -q origin main 2>/dev/null
EOF

# ---------- git ----------
if [ "$SKIP_SYSTEM" != "1" ]; then
  chown -R "$COS_USER:$COS_USER" "$AGENCY_DIR" "$COS_HOME/.config"
  as_cos "crontab $COS_HOME/.config/cos.crontab"
  as_cos "cd $AGENCY_DIR && { [ -d .git ] || git init -q -b main; } && \
          git config user.name '$COS_NAME (AI Operations Director)' && \
          git config user.email 'cos@localhost' && \
          git add -A && { git diff --cached --quiet || git commit -qm 'Initial setup by bootstrap'; }"
fi

# -----------------------------------------------------------------------------
say "BOOTSTRAP DONE"
cat <<EOF

Next steps (the setup runbook covers each one):
  1. Tailscale:     tailscale up --ssh            (open the link it prints, approve)
  2. Claude login:  su - $COS_USER  then  cd $AGENCY_DIR && claude   (choose the subscription login)
  3. GitHub key:    cat $COS_HOME/.ssh/id_ed25519.pub   (add as a deploy key with write access)
  4. Secrets:       $AGENCY_DIR/scripts/set-secret.sh DISCORD_WEBHOOK_BRIEF   (and _ALERTS, _AGENTLOG)
  5. Discord:       inside claude: /plugin install discord@claude-plugins-official, /discord:configure <token>
  6. Go live:       $AGENCY_DIR/scripts/go-live.sh   (as $COS_USER)
  7. Lock down:     $AGENCY_DIR/scripts/lockdown.sh  (as root, after Tailscale works)
  8. Owner:         DM $COS_NAME in Discord: start onboarding
EOF
