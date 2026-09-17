# Host provisioning (DigitalOcean)

Hardened, Docker-ready Ubuntu host for OxyTrip. **No application deploy here** — this
directory only gets a droplet to the point where you can `git pull`, set env files, and
`./scripts/stack.sh up`.

## What you get

| Piece | Role |
|-------|------|
| `cloud-init.yaml` | User-data applied at droplet create — deploy user, SSH harden, UFW, fail2ban, unattended-upgrades (no auto-reboot), Docker Engine + Compose, 4 GB swap, DO monitoring agent, `/opt/oxytrip` clone |
| `authorized_keys` | **Public** SSH keys for `deploy` (never commit private keys) |
| `verify-host.sh` | Post-boot checklist; exits non-zero on any failure |

The droplet must come up **without any manual SSH steps** to finish hardening. Your first
login is only to run verification (or to deploy apps later).

---

## 1. Create the production droplet (BLR1)

**Recommended size:** Basic **4 vCPU / 8 GB** RAM, Ubuntu **24.04 LTS**, region **BLR1**,
**backups on**, **monitoring on**. Paste `provision/cloud-init.yaml` as **user data**.

### Control panel

1. Create → Droplets → BLR1 → Ubuntu 24.04 LTS → Basic 4 vCPU / 8 GB.
2. Enable **Monitoring** and **Backups**.
3. Authentication: you can skip adding DO SSH keys here — cloud-init installs the keys from
   `authorized_keys` onto `deploy`. (Adding your key in the UI as well does not hurt.)
4. Advanced → **User data** → paste the full contents of `provision/cloud-init.yaml`.
5. Create the droplet. Wait until it shows active, then give cloud-init several minutes
   (Docker install + package upgrades). On the host: `cloud-init status --wait`.

### Equivalent `doctl`

```bash
# Once: doctl auth init
doctl compute droplet create oxytrip-blr1 \
  --region blr1 \
  --image ubuntu-24-04-x64 \
  --size s-4vcpu-8gb \
  --enable-monitoring \
  --enable-backups \
  --user-data-file provision/cloud-init.yaml \
  --wait
```

Note the public IPv4. First login:

```bash
ssh deploy@<DROPLET_IP>
sudo /opt/oxytrip/provision/verify-host.sh
```

Every line should be `PASS`. `ssh root@<DROPLET_IP>` must be **refused**.

---

## 2. Cloud Firewall

Create a DigitalOcean **Cloud Firewall** and attach it to the droplet (or a tag).

| Direction | Protocol | Ports | Sources |
|-----------|----------|-------|---------|
| Inbound | TCP | **22** | **Admin IP(s) only** (your office / VPN / bastion) |
| Inbound | TCP | **80, 443** | Anywhere (`0.0.0.0/0` and `::/0`) **for now** |
| Outbound | — | All | Anywhere |

Host UFW already allows 22/80/443 only; the Cloud Firewall is defense in depth and is
where you pin SSH to admin IPs (UFW alone cannot easily track a changing home IP).

**Later (after Cloudflare proxies the site):** restrict inbound **80/443** to
[Cloudflare’s published IP ranges](https://www.cloudflare.com/ips/). Leaving 80/443 open
to the world while Cloudflare is in front allows attackers to bypass Cloudflare and hit
the origin directly.

---

## 3. Reserved IP

Assign a **Reserved IP** (Floating IP) to the droplet and use that address in DNS.

Rebuilding the droplet then becomes: create new droplet → attach the same Reserved IP →
update nothing in Cloudflare. The address survives the machine.

```bash
doctl compute reserved-ip create --region blr1
doctl compute reserved-ip-action <RESERVED_IP> assign <DROPLET_ID>
```

---

## 4. Disaster recovery — rebuild from zero

This is the recovery procedure. Treat a failed host as disposable.

1. **Snapshot / note** anything not in git (env files under `/opt/oxytrip/env/*.env` are
   gitignored — keep an off-box backup of those secrets).
2. **Create a new droplet** in BLR1 with the **same** `provision/cloud-init.yaml` as
   user-data (size as above; monitoring + backups on).
3. Wait for `cloud-init status --wait` (SSH as `deploy` once the IP answers).
4. Run **`sudo /opt/oxytrip/provision/verify-host.sh`** — all checks must pass.
5. **Attach the Reserved IP** to the new droplet.
6. Restore env files into `/opt/oxytrip/env/` (from backup), `docker login ghcr.io` as
   needed, then:

   ```bash
   cd /opt/oxytrip
   git pull --ff-only
   ./scripts/stack.sh pull staging   # or pin SHAs for prod
   ./scripts/stack.sh up staging     # or prod
   ./scripts/healthcheck.sh https://<SITE_DOMAIN>
   ```

7. Confirm `/api/health` (and panel health) from outside, then retire the old droplet.

No manual SSH hardening steps — cloud-init must leave the host verify-clean.

---

## 5. Disposable smoke test (cheap droplet)

Before trusting production, exercise provisioning on the **smallest** Basic droplet
(hourly billing, a few cents):

```bash
doctl compute droplet create oxytrip-provision-test \
  --region blr1 \
  --image ubuntu-24-04-x64 \
  --size s-1vcpu-1gb \
  --enable-monitoring \
  --user-data-file provision/cloud-init.yaml \
  --wait

IP=$(doctl compute droplet get oxytrip-provision-test --format PublicIPv4 --no-header)
ssh -o StrictHostKeyChecking=accept-new deploy@"$IP" 'cloud-init status --wait'
ssh deploy@"$IP" 'sudo /opt/oxytrip/provision/verify-host.sh'
# Expect: ssh root@$IP refused / Permission denied
doctl compute droplet delete oxytrip-provision-test --force
```

The 4 GB swap check still passes on the small box — this tests **provisioning**, not capacity.

### If `deploy` login is refused

`Permission denied (publickey)` a few minutes after boot means cloud-init didn't finish setting
up the user. Don't weaken SSH to get in — use the droplet's **Access → Recovery Console** in the
control panel (use **Reset root password** there if prompted; the password is emailed), then:

```bash
cloud-init status --long
id deploy
grep -iE "deploy|useradd|error|fail|traceback" /var/log/cloud-init.log | tail -30
```

Fix `cloud-init.yaml`, destroy the droplet, and retest on a **fresh** one — never patch a test
droplet by hand; the test proves the file alone produces a working host.

### Pitfalls this file already guards against

- **sshd setting precedence:** OpenSSH keeps the *first* value it reads, and `sshd_config.d/*.conf`
  is read in lexical order — so the hardening drop-in is `01-…`, ahead of the image's
  `50-cloud-init.conf`. A `99-` name would be silently overridden.
- **`set -e` leaking across `runcmd`:** cloud-init runs every `runcmd` item as one script, so each
  block runs in its own `( … )` subshell; one failing step can't skip the rest.
- **Groups that don't exist yet:** `deploy` is created with `sudo` only; `docker` membership is
  added after Docker installs.

---

## Constraints

- Commit **public keys only** in `authorized_keys` / `cloud-init.yaml`.
- Nothing application-specific in cloud-init beyond cloning this infra repo.
- `env/*.env` stays gitignored; never bake secrets into user-data.
