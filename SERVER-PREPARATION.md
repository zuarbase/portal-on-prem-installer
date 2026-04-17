# server preparation instructions

steps the customer must complete on their server before installation.
after completing these steps, run the [requirements check](#verify-with-check-script)
and contact zuar for the install command.

see [README.md](README.md) for installation instructions.

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

create a user with **UID 1000** and passwordless sudo. the username can be
anything -- below we use `<deploy-user>` as a placeholder. zuar will use the
actual name in the install command.

**why UID 1000?** portal docker containers run internal processes as UID 1000.
docker volume mounts share file ownership between host and container -- if the
host user has a different UID, portal will fail with permission errors on SSL
certs, app data, and nginx config directories.

### create user

```bash
# As root:
useradd -m -s /bin/bash -u 1000 <deploy-user>
passwd <deploy-user>
# (set a password for SSH access)
```

### configure passwordless sudo

```bash
echo "<deploy-user> ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/<deploy-user>
chmod 440 /etc/sudoers.d/<deploy-user>
```

### configure SSH access for zuar

```bash
mkdir -p /home/<deploy-user>/.ssh
# Zuar will provide the public key separately
echo "<ZUAR_PUBLIC_KEY>" >> /home/<deploy-user>/.ssh/authorized_keys
chown -R <deploy-user>:<deploy-user> /home/<deploy-user>/.ssh
chmod 700 /home/<deploy-user>/.ssh
chmod 600 /home/<deploy-user>/.ssh/authorized_keys
```

### verify

```bash
id <deploy-user>
# Expected: uid=1000(<deploy-user>) gid=1000(<deploy-user>) groups=1000(<deploy-user>),sudo

sudo -u <deploy-user> sudo whoami
# Expected: root (confirms passwordless sudo works)

ssh <deploy-user>@localhost whoami
# Expected: <deploy-user>
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

## 3a. TLS certificate (optional)

portal serves over HTTPS. by default, it uses a self-signed certificate
("snakeoil") -- HTTPS works but browsers show an "untrusted certificate"
warning. for production deployments, supply your own CA-signed certificate.

if a customer-supplied certificate is needed, the install command will include
the `--tls-cert` flag. without that flag, the server uses snakeoil and this
section can be skipped.

### required files (only if `--tls-cert` is used)

place the following files on the server **before running the install script**:

| File | Description |
|------|-------------|
| `/home/<deploy-user>/portal-cert/fullchain.pem` | full certificate chain (server cert + intermediates) |
| `/home/<deploy-user>/portal-cert/privkey.pem` | private key (PEM format, no passphrase) |

permissions:

```bash
chmod 600 /home/<deploy-user>/portal-cert/privkey.pem
chmod 644 /home/<deploy-user>/portal-cert/fullchain.pem
chown -R <deploy-user>:<deploy-user> /home/<deploy-user>/portal-cert
```

### verify

```bash
# certificate is valid
openssl x509 -in /home/<deploy-user>/portal-cert/fullchain.pem -noout -dates

# private key matches certificate
diff <(openssl x509 -in /home/<deploy-user>/portal-cert/fullchain.pem -noout -modulus) \
     <(openssl rsa -in /home/<deploy-user>/portal-cert/privkey.pem -noout -modulus)
# Expected: no output (matching modulus)
```

### notes

- self-signed certificates are accepted but browsers will show a warning
- if the certificate covers multiple domains (SAN), all of them must point to this server
- expired certificates will block portal HTTPS access -- monitor expiration

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

---

## 5. verify with check script

after completing all steps above, run the requirements check script to verify
the server is ready:

```bash
curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/check-requirements.sh | sudo bash -s -- --user <deploy-user>
```

if using a customer-supplied TLS certificate:

```bash
curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/check-requirements.sh | sudo bash -s -- --user <deploy-user> --tls-cert
```

the script checks: OS version, CPU/RAM/disk, deploy user (UID 1000, sudo),
system packages, TLS certificate (if required), and outbound connectivity.

all checks must pass before requesting an install token from zuar.

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

- [ ] Ubuntu 22.04 LTS, 2 vCPU, 4 GB RAM, 80 GB disk, x86_64
- [ ] `<deploy-user>` with UID 1000, passwordless sudo
- [ ] SSH access for zuar (public key added to `<deploy-user>`)
- [ ] inbound ports open: 22, 80, 443
- [ ] outbound access to: github.com, AWS ECR, vault.zuarbase.net, Docker/HashiCorp/Microsoft APT repos, astral.sh
- [ ] DNS A record for custom domain (if applicable)
