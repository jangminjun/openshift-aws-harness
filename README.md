# OpenShift AWS Agent

This workspace contains a reusable harness for installing self-managed
OpenShift + OpenShift AI on AWS via a bastion jump host. See
[harness/README.md](harness/README.md) for usage.

```bash
cd harness
./harness.sh all      # bastion up -> cluster install -> GPU operator -> OpenShift AI
./harness.sh status   # check progress at any time
```

Current live deployment (`myocp`) credentials and URLs are in
[AGENT.md](AGENT.md) — contains secrets, do not commit/share as-is.

GPU monitoring dashboards/alerts (per [openshift-monitoring](openshift-monitoring))
are wired up via `./harness.sh monitoring-all` — see
[harness/README.md](harness/README.md) for what's implemented vs. not yet.

`agent.py` is an earlier, unused scaffold kept for reference.
