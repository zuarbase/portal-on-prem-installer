# Zuar Portal On-Prem Installer

One-command deployment of Zuar Portal on a customer's server.

## Server Requirements

| Resource | Minimum |
|----------|---------|
| OS | Ubuntu 22.04 LTS (jammy) |
| CPU | 2 vCPU |
| RAM | 4 GB |
| Disk | 80 GB |
| Architecture | x86_64 (amd64) |

### User

A user with **UID 1000** and passwordless sudo. Default username is `ubuntu`.
If your server has a different user with UID 1000, provide it with the `--user` flag.

Portal Docker containers run internal processes as UID 1000. If the host user
has a different UID, portal will fail with permission errors.

### Network

The server needs outbound access to:

| Destination | Port | Purpose |
|-------------|------|---------|
| vault.zuarbase.net | 8200 | Credential retrieval |
| github.com | 22, 443 | Clone portal repository |
| 575296055612.dkr.ecr.us-east-1.amazonaws.com | 443 | Pull Docker images |
| licensing3.zuarbase.net | 443 | License validation |
| download.docker.com | 443 | Docker APT repository |
| apt.releases.hashicorp.com | 443 | Vault APT repository |
| awscli.amazonaws.com | 443 | AWS CLI installer |
| packages.microsoft.com | 443 | MSSQL tools APT repo |
| astral.sh | 443 | uv installer |

### Verify connectivity

```bash
for host in github.com 575296055612.dkr.ecr.us-east-1.amazonaws.com vault.zuarbase.net:8200 download.docker.com apt.releases.hashicorp.com awscli.amazonaws.com packages.microsoft.com astral.sh; do
  code=$(curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://$host")
  printf "  %-55s %s\n" "$host" "$code"
done
```

Any 2xx/3xx/4xx means reachable. 000 means blocked.

## Installation

Once your server meets the requirements above, run the command provided by Zuar:

```bash
curl -sL <script-url> | sudo bash -s -- --token <install-token>
```

Zuar will provide the complete command with the token. The token is:
- one-time use (destroyed after first use)
- valid for 14 days
- contains no permanent credentials

The script will automatically:
- install all required packages (Docker, Git, Vault, AWS CLI, etc.)
- fetch credentials from Zuar's vault
- create license user and instance
- clone and configure portal
- restore default database content
- create admin user

### Custom deploy user

If your UID 1000 user is not named `ubuntu`:

```bash
curl -sL <script-url> | sudo bash -s -- --token <install-token> --user <username>
```

## After Installation

Portal will be accessible at the URL shown at the end of the install output.

### Verify

```bash
docker ps                    # should show portal, zwaf, auth, db containers
curl -sk https://localhost   # should return 200 or 302
```

### Upgrade

```bash
cd ~/portal-docker-setup/setup
./make.sh upgrade
```

## Firewall

Open the following inbound ports:

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH access |
| 80 | TCP | HTTP (redirects to HTTPS) |
| 443 | TCP | HTTPS (Portal) |

## Support

Contact Zuar for assistance with installation or troubleshooting.
