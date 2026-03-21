# davafons-infra

Infrastructure configs and provisioning scripts.

## Structure

- `machines/` — Docker Compose stacks organized per server
  - `qtower/` — Main home server
  - `monitoring/` — Monitoring server (Prometheus, Grafana, Loki, Tempo)
- `hetzner/` — Hetzner server provisioning (Docker + Tailscale + hardening)
- `tailscale/` — Tailscale ACL policy (synced via GitHub Actions)
- `deploy.sh` — Kamal-style deployment tool (rsync + docker context over SSH)

## Deploying

`deploy.sh` syncs local stack directories to remote servers via rsync, then runs `docker compose up` through a remote docker context over SSH.

Configuration lives in `deploy.conf` (INI format):

```ini
[qtower]
host = qtower          # SSH host (from ~/.ssh/config)
dir = /home/docker     # Remote base directory
stacks = db photos books ...
```

### Usage

```bash
./deploy.sh <server> <command> [stack] [args...]
```

### Commands

| Command | Description |
|---------|-------------|
| `setup` | Create docker context for a server (first time) |
| `deploy [stack]` | Sync files and `docker compose up -d` (all stacks if omitted) |
| `restart [stack]` | Restart stack(s) |
| `stop [stack]` | Stop stack(s) |
| `pull [stack]` | Pull latest images |
| `logs <stack>` | Tail logs (extra args passed through) |
| `ps [stack]` | Show running containers |
| `exec <stack> ...` | Run command in a stack container |
| `shell` | SSH into the server |
| `info` | Show server configuration |

### Examples

```bash
./deploy.sh qtower setup              # first time setup
./deploy.sh qtower deploy db          # deploy a single stack
./deploy.sh qtower deploy             # deploy all stacks
./deploy.sh monitoring deploy
./deploy.sh qtower logs db --since 5m
./deploy.sh qtower shell
```

### Environment variables

Each stack has a `.env.yaml` that defines both plain config and secrets, same structure as Kamal's `deploy.yml`:

```yaml
# machines/monitoring/monitoring/.env.yaml
env:
  clear:
    GF_ADMIN_USER: admin
    GF_ROOT_URL: http://localhost:3000
  secret:
    - GF_ADMIN_PASSWORD
```

- **`clear`** — non-secret config, committed to git
- **`secret`** — names of secrets fetched from AWS SSM Parameter Store at `/davafons-infra/<server>/<stack>/<SECRET_NAME>`
- **Runtime vars** — `TAILSCALE_IP` etc. are read from `/etc/environment` on the server automatically

To add a secret to SSM:

```bash
aws ssm put-parameter \
  --name "/davafons-infra/monitoring/monitoring/GF_ADMIN_PASSWORD" \
  --value "supersecret" \
  --type SecureString
```

During deploy, all three sources are merged into a single `.env` written to the server via SSH. The `.env` is never synced via rsync.
