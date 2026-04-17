# Zuar Portal On-Prem Installer

## before you begin

complete all steps in the [server preparation instructions](SERVER-PREPARATION.md)
and verify with the check script:

```bash
curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/check-requirements.sh | sudo bash -s -- --user <deploy-user>
```

all checks must pass before proceeding.

## installation

a zuar engineer will provide a single command to run on the server:

```bash
curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/install-portal.sh | sudo bash -s -- --token <install-token> --gist-url https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/install-portal.sh --user <deploy-user> --tls-cert
```

flags:
- `--token` -- one-time install token (provided by zuar, valid 14 days)
- `--gist-url` -- script source url (provided by zuar)
- `--user <deploy-user>` -- the UID 1000 user created during server preparation
- `--tls-cert` -- include only if you supplied a certificate (see server preparation step 3a)

after completion, the script outputs the portal URL and admin credentials.
