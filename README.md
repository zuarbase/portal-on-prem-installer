# on-prem portal installation -- customer server preparation runbook

steps the customer must complete on their server before zuar runs the portal
install script. this runbook is shared with the customer directly.

---

## 1. server requirements

| Resource | Minimum |
|----------|---------|
| OS | Ubuntu 22.04 LTS (jammy) |
| CPU | 2 vCPU |
| RAM | 4 GB |
| Disk | 80 GB |
| Architecture | x86_64 (amd64) |

### Verify

```bash
lsb_release -d
# Expected: Ubuntu 22.04.x LTS

uname -m
# Expected: x86_64

nproc
# Expected: 2 or more

free -h
# Expected: 4 GB or more total

df -h /
# Expected: 80 GB or more available
```

---

## 2. user setup

create a user named `ubuntu` with **UID 1000** and passwordless sudo.

**why UID 1000?** portal docker containers run internal processes as UID 1000.
docker volume mounts share file ownership between host and container -- if the
host user has a different UID, portal will fail with permission errors on SSL
certs, app data, and nginx config directories.

### create user

```bash
# As root:
useradd -m -s /bin/bash -u 1000 ubuntu
passwd ubuntu
# (set a password for SSH access)
```

### configure passwordless sudo

```bash
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 440 /etc/sudoers.d/ubuntu
```

### configure SSH access for zuar

```bash
mkdir -p /home/ubuntu/.ssh
# Zuar will provide the public key separately
echo "<ZUAR_PUBLIC_KEY>" >> /home/ubuntu/.ssh/authorized_keys
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh
chmod 600 /home/ubuntu/.ssh/authorized_keys
```

### verify

```bash
id ubuntu
# Expected: uid=1000(ubuntu) gid=1000(ubuntu) groups=1000(ubuntu),sudo

sudo -u ubuntu sudo whoami
# Expected: root (confirms passwordless sudo works)

ssh ubuntu@localhost whoami
# Expected: ubuntu
```

---

## 3. firewall -- inbound ports

open the following ports for inbound traffic:

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP/SSH | SSH access for installation and management |
| 80 | TCP/HTTP | Portal (redirects to HTTPS) |
| 443 | TCP/HTTPS | Portal |
---

## 4. outbound network access

the server must reach these destinations during installation and at runtime:

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| github.com | 22 | TCP/SSH | Clone portal-docker-setup repository |
| github.com | 443 | TCP/HTTPS | SSH keyscan fallback |
| 575296055612.dkr.ecr.us-east-1.amazonaws.com | 443 | TCP/HTTPS | Pull Docker images (AWS ECR) |
| licensing3.zuarbase.net | 443 | TCP/HTTPS | License validation |
| vault.zuarbase.net | 8200 | TCP/HTTPS | AppRole auth, AWS STS credentials |
| devpi.zuarbase.net | 443 | TCP/HTTPS | Python packages (plugins) |
| download.docker.com | 443 | TCP/HTTPS | Docker APT repository |
| apt.releases.hashicorp.com | 443 | TCP/HTTPS | Vault APT repository |
| awscli.amazonaws.com | 443 | TCP/HTTPS | AWS CLI installer |
| packages.microsoft.com | 443 | TCP/HTTPS | MSSQL tools + ODBC APT repo |
| astral.sh | 443 | TCP/HTTPS | uv installer |
| *.amazonaws.com | 443 | TCP/HTTPS | Download DB backup from S3 |
| acme-v02.api.letsencrypt.org | 443 | TCP/HTTPS | SSL cert (if using Let's Encrypt) |

### verify

```bash
# test all endpoints at once:
for host in github.com 575296055612.dkr.ecr.us-east-1.amazonaws.com vault.zuarbase.net:8200 download.docker.com apt.releases.hashicorp.com awscli.amazonaws.com packages.microsoft.com astral.sh; do
  code=$(curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://$host")
  printf "  %-55s %s\n" "$host" "$code"
done

# Expected output (any 2xx/3xx/4xx means reachable, 000 means blocked):
#   github.com                                              301
#   575296055612.dkr.ecr.us-east-1.amazonaws.com            403
#   vault.zuarbase.net:8200                                 400
#   download.docker.com                                     200
#   apt.releases.hashicorp.com                              200
#   awscli.amazonaws.com                                    403
#   packages.microsoft.com                                  200
#   astral.sh                                               301

# Test SSH to GitHub (port 22):
ssh -T git@github.com 2>&1 | head -1
# Expected: "Hi ...! You've successfully authenticated" or "Permission denied"
# (both mean github.com:22 is reachable)
```

if outbound access is restricted, zuar can provide a VPN tunnel (sshuttle)
through a zuar-hosted VM.

---

## 5. installation

once the server meets requirements above, a zuar engineer will provide a
single command to run on the server. the command looks like:

```bash
curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/install-portal.sh | sudo bash -s -- --token <install-token> --gist-url https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/install-portal.sh
```

the `<install-token>` is unique to your deployment:
- one-time use (destroyed after first use)
- valid for 14 days
- contains no permanent credentials

if your UID 1000 user is not named `ubuntu`, add `--user <username>`:

```bash
curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/install-portal.sh | sudo bash -s -- --token <install-token> --gist-url https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/install-portal.sh --user deploy
```

the script will automatically:
1. install all required packages (Docker, Git, Vault, AWS CLI, etc.)
2. fetch credentials from zuar vault
3. create license user and instance
4. clone and configure portal
5. restore default database content
6. create admin user

after completion, the script outputs the portal URL and admin credentials.

### upgrade

```bash
cd ~/portal-docker-setup/setup
./make.sh upgrade
```

---

## 6. software reference (auto-installed by the install script)

the install script automatically installs all required packages.
no manual installation is needed. this section is for reference only.

**auto-installed by the script (if missing):**

| Package | Version | Source |
|---------|---------|--------|
| Docker CE | 27.5.1 | Docker APT repo |
| Docker Compose | 2.32.4 | Docker APT repo (plugin) |
| containerd.io | 1.7.25 | Docker APT repo |
| Git | 2.34.1 | Ubuntu APT |
| HashiCorp Vault | 1.18.4 | HashiCorp APT repo |
| AWS CLI | 2.24.4 | Official AWS installer |
| uv | latest | astral.sh installer |
| jq | 1.6 | Ubuntu APT |
| ripgrep | (any) | Ubuntu APT |
| gron | (any) | Ubuntu APT |
| ncdu | (any) | Ubuntu APT |
| icdiff | (any) | Ubuntu APT |
| nmap | (any) | Ubuntu APT |
| emacs-nox | (any) | Ubuntu APT |
| net-tools | (any) | Ubuntu APT |
| pv | (any) | Ubuntu APT |
| postgresql-client | (any) | Ubuntu APT |
| mssql-tools18 | (any) | Microsoft APT repo |
| unixodbc-dev | (any) | Microsoft APT repo |
| pass | (any) | Ubuntu APT |
| gnupg2 | (any) | Ubuntu APT |
| haveged | (any) | Ubuntu APT |
| zip / unzip | (any) | Ubuntu APT |

**must be pre-installed (standard on Ubuntu Server, used before any install step):**

| Package | Used for |
|---------|----------|
| curl | Connectivity checks, APT key downloads, license service |
| wget | Download database backup from S3 |
| openssl | Generate auth secrets (make.sh) |
| gpg | Import Docker and Vault APT signing keys |
| ssh / ssh-keyscan | GitHub access (clone repository) |
| sudo | Package installation, make.sh restore |
| tar / gzip | Extract install package and database backup |
| lsb_release | OS version detection |

### verify (after portal installation)

```bash
echo "--- Core packages ---"
printf "  %-20s %s\n" "docker" "$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo 'NOT FOUND')"
printf "  %-20s %s\n" "docker compose" "$(docker compose version --short 2>/dev/null || echo 'NOT FOUND')"
printf "  %-20s %s\n" "git" "$(git --version 2>/dev/null | awk '{print $3}' || echo 'NOT FOUND')"
printf "  %-20s %s\n" "vault" "$(vault --version 2>/dev/null | awk '{print $2}' || echo 'NOT FOUND')"
printf "  %-20s %s\n" "aws" "$(aws --version 2>/dev/null | awk '{print $1}' || echo 'NOT FOUND')"
printf "  %-20s %s\n" "uv" "$(uv --version 2>/dev/null || echo 'NOT FOUND')"

echo ""
echo "--- Tools ---"
for cmd in jq rg gron ncdu icdiff nmap emacs pv psql /opt/mssql-tools18/bin/sqlcmd pass; do
  if command -v $cmd > /dev/null 2>&1; then
    printf "  %-20s OK\n" "$cmd"
  else
    printf "  %-20s MISSING\n" "$cmd"
  fi
done

echo ""
echo "--- System packages ---"
for cmd in curl wget openssl gpg ssh ssh-keyscan sudo tar gzip lsb_release unzip zip; do
  if command -v $cmd > /dev/null 2>&1; then
    printf "  %-20s OK\n" "$cmd"
  else
    printf "  %-20s MISSING\n" "$cmd"
  fi
done

# Expected output:
#   --- Core packages ---
#     docker               27.5.1
#     docker compose       2.32.4
#     git                  2.34.1
#     vault                v1.18.4
#     aws                  aws-cli/2.24.4
#     uv                   uv 0.x.x
#
#   --- Tools ---
#     jq                   OK
#     rg                   OK
#     gron                 OK
#     ncdu                 OK
#     icdiff               OK
#     nmap                 OK
#     emacs                OK
#     pv                   OK
#     psql                 OK
#     /opt/mssql-tools18/bin/sqlcmd OK
#     pass                 OK
#
#   --- System packages ---
#     curl                 OK
#     wget                 OK
#     openssl              OK
#     gpg                  OK
#     ssh                  OK
#     ssh-keyscan          OK
#     sudo                 OK
#     tar                  OK
#     gzip                 OK
#     lsb_release          OK
#     unzip                OK
#     zip                  OK
```

---

## 7. DNS (if using custom domain)

if the portal should be accessible at a custom domain (e.g. portal.customer.com):

1. create a DNS A record pointing to the server's public IP
2. wait for propagation

### verify

```bash
dig +short portal.customer.com
# Expected: server's public IP address
```

---

## summary checklist

- [ ] ubuntu 22.04 LTS, 2 vCPU, 4 GB RAM, 80 GB disk, x86_64
- [ ] user `ubuntu` with UID 1000, passwordless sudo
- [ ] SSH access for zuar (public key added to `ubuntu`)
- [ ] inbound ports open: 22, 80, 443
- [ ] outbound access to: github.com, AWS ECR, vault.zuarbase.net, Docker/HashiCorp/Microsoft APT repos, astral.sh
- [ ] DNS A record for custom domain (if applicable)
