# Nextcloud-K3s

One Nextcloud on K3s: a private cloud for files and photos. It uses the shared PostgreSQL for its database and the shared Mailpit for email, and is reachable at `https://nextcloud.home.arpa` at home or through WireGuard.

## Overview

| Item | Value |
|---|---|
| Namespace | `nextcloud` |
| Image | `nextcloud:34.0.5-apache` (web + background jobs) |
| Address (home network / VPN) | `https://nextcloud.home.arpa` (Traefik, name from Pi-hole) |
| Address (inside the cluster) | `nextcloud.nextcloud.svc.cluster.local:80` |
| Exposure | Home network and WireGuard only, never the internet |
| Database | Own database `nextcloud` in Postgres-K3s (Secret `nextcloud-db`) |
| Email | Own login `nextcloud` in Mailpit-K3s (Secret `nextcloud-email`) |
| Storage | 20 Gi, `local-path` (program, settings and files) |
| Backup | Files nightly at 03:30 into `backup/data/<date>/`, kept 7 days (database: Postgres-K3s at 03:00) |
| Memory limit | 1 Gi web, 512 Mi background jobs |
| Admin login | Secret `nextcloud-admin` |

> `<PI_IP>` is the Pi's address on your home network (`hostname -I`, first value).

## Files

| File | Purpose |
|---|---|
| `nextcloud.yaml` | Namespace, service, HTTPS address (with HSTS), storage and Nextcloud |
| `backup/` | Nightly backup CronJob, `backup-now.sh`, `restore.sh` |
| `tests/` | Tests, run on the Pi |
| `.github/workflows/tests.yml` | Checks scripts and manifest on push to `main` and `dev` |

## Install

Needs Postgres-K3s and Mailpit-K3s running, and Pihole-K3s for the name `nextcloud.home.arpa`.

> [!WARNING]
> Files are stored on the **SD card** until the SSD is installed. Fine for trying it out; move the data to the SSD before uploading photo libraries.

```bash
export KUBECONFIG=~/.kube/config
kubectl create namespace nextcloud
../../Development/Postgres-K3s/new-app-db.sh nextcloud nextcloud      # Secret nextcloud-db
../../Development/Mailpit-K3s/new-app-email.sh nextcloud nextcloud    # Secret nextcloud-email
kubectl create secret generic nextcloud-admin -n nextcloud \
  --from-literal=username=admin --from-literal=password="$(openssl rand -hex 16)"
kubectl apply -f nextcloud.yaml
kubectl rollout status deployment/nextcloud -n nextcloud --timeout=600s   # first start installs (several minutes)
# One-time settings: heavy daily jobs at night (01:00-05:00 UTC), file type repair
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c \
  "php occ config:system:set maintenance_window_start --type=integer --value=1 && php occ maintenance:repair --include-expensive"
kubectl apply -f backup/cronjob.yaml
./tests/run-all.sh
```

## Open it

On a device that uses Pi-hole (home network or WireGuard), open https://nextcloud.home.arpa.

The certificate comes from the home CA: install it once on each device (see Pihole-K3s, "HTTPS certificate") and the browser, the Nextcloud app and the desktop client trust it. A device that does not use Pi-hole can add `<PI_IP> nextcloud.home.arpa` to its hosts file.

Admin password:
```bash
kubectl get secret -n nextcloud nextcloud-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

## Users

Log in as admin, then **Avatar → Accounts** to add or remove users. Removing a user deletes all their files.

## Backup

Daily at 03:30 into `backup/data/<date>/` (one folder per day, kept 7 days). A missed backup runs when the Pi starts again. The database is backed up by Postgres-K3s at 03:00.
- `config/`: settings, including the instance secret (needed to restore)
- `data/`: every user's files and photos
- `custom_apps/`, `themes/`

Unchanged files are hard links to the day before: every folder is complete, but only new or changed files use space. Previews and the log are skipped (Nextcloud recreates them).

```bash
./backup/backup-now.sh                                   # back up now
./backup/restore.sh backup/data/<date> <user>            # restore one user's files
kubectl get cronjob,jobs -n nextcloud                    # backup status
```

Full restore: database first, then all files.
```bash
../../Development/Postgres-K3s/backup/restore.sh nextcloud ../../Development/Postgres-K3s/backup/data/<date>/nextcloud.dump
./backup/restore.sh backup/data/<date>
```

Destination folder: `hostPath.path` in `backup/cronjob.yaml`. It is on the SD card for now, like the files themselves: move it to the SSD or a USB drive when one is connected.

## Useful commands

```bash
kubectl get pods,pvc,ingress -n nextcloud                                  # status
kubectl logs -n nextcloud deploy/nextcloud -c nextcloud --tail=50          # logs
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- \
  su -s /bin/sh www-data -c "php occ status"                               # occ (Nextcloud commands)
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- \
  su -s /bin/sh www-data -c "php occ user:list"                            # users
```

## Tests

Run on the Pi:
```bash
./tests/run-all.sh
```

| Test | Checks |
|---|---|
| `01-running.sh` | Pod, storage, service, address, secrets, installed, version, shared PostgreSQL and Mailpit, login required, HTTPS + HSTS on the home network, maintenance window, backup scheduled, cron, memory |
| `02-users.sh` | Users log in, upload/download, cannot read each other's files, wrong or deleted login rejected |
| `03-deploying.sh` | Manifests valid, no drift, users and files survive a restart |
| `04-backup.sh` | Backup, file permissions, hard links, real backups untouched, restore |
| `99-leftovers.sh` | Nothing left behind by the tests |

Test users (`nctest*`), their files and test backups (`test_*`) are removed at the end. The helper pod uses the temporary namespace `nctest`. `03` restarts Nextcloud once (about a minute).

On push, `.github/workflows/tests.yml` checks script syntax (shellcheck) and the manifest (kubeconform) on `ubuntu-latest` (it also works on `nekko-runners`). It has no access to the cluster.

## Notes

- Deleting the `nextcloud` namespace deletes all files. The database stays in Postgres-K3s (and its nightly backup).
- Upgrades: change the image tag one major version at a time (34 → 35), apply, then run the tests.
- Emails (password reset, shares) go to Mailpit, not real inboxes.
