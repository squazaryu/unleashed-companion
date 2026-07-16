# Module One routing drift check

Automation for [issue #11](https://github.com/squazaryu/TumoCompanion/issues/11):
keep the app's hand-maintained Module One routing map honest against upstream
[xMasterX/all-the-plugins](https://github.com/xMasterX/all-the-plugins).

## Files

| File | What |
|------|------|
| `module_one_routes.json` | The routing map (`stem → /ext/apps/Module One/…`), **generated** from `PluginInstallRouting.targetPaths` in the app source. |
| `upstream_snapshot.json` | Last-seen set of upstream `.fap` stems + categories. Lets the check report only *new* apps, not the whole pack. Committed by CI. |
| `../scripts/export_routing_map.py` | Regenerates `module_one_routes.json` from the Swift source (run locally when you edit the map). |
| `../scripts/check_routing_drift.py` | CI: downloads the latest release, enumerates `.fap` stems, diffs against the map + snapshot. |
| `../.github/workflows/routing-drift.yml` | Runs the check daily (and on demand), opening/updating a single **“Module One routing drift”** tracking issue. |

## When you change the routing map

After editing `PluginInstallRouting.targetPaths` in `Sources/Features/Updates/PluginUpdater.swift`,
regenerate the JSON and commit it here:

```sh
python3 scripts/export_routing_map.py
git add routing/module_one_routes.json && git commit -m "routing: sync map"
```

## What the check flags

- **Stale** — a mapped stem that no longer exists upstream (renamed/removed, or a core/custom
  app the pack doesn't ship — that map entry never fires).
- **New candidates** — a newly-appeared upstream app in the same upstream category as apps we
  already route to Module One; review whether it belongs in the map.

No drift → the tracking issue is closed; drift → it's (re)opened and its body updated in place.
