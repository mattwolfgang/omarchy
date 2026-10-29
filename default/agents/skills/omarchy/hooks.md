# Automation Hooks

Read this before setting up scripts that run on system events (theme changes,
updates, boot, low battery, etc.).

Hooks live in `~/.config/omarchy/hooks/<name>.d/` — one directory per event,
holding any number of independent scripts. Install with
`omarchy hook install <name> <script>` (copies the script in and makes it
executable). The runner also executes a flat `~/.config/omarchy/hooks/<name>`
file first, if one exists.

```
~/.config/omarchy/hooks/
├── battery-low.d/          # Low battery (percentage in $1)
├── font-set.d/             # After font change (font name in $1)
├── post-boot.d/            # After the desktop starts
├── plugin-pre-install.d/   # Before `omarchy plugin add` installs ($1 staged checkout, $2 URL, $3 id); non-zero refuses
├── plugin-pre-update.d/    # Before `omarchy plugin update` applies ($1 plugin dir, $2 id, $3 current, $4 incoming commit); non-zero refuses
├── post-update.d/          # At the end of `omarchy update`, after privileged work
├── pre-refresh-pacman.d/   # After `omarchy refresh pacman` re-syncs the package config, before it updates packages
└── theme-set.d/            # After theme change (theme slug in $1)
```

The two `plugin-pre-*` hooks are gates, run by `omarchy-hook-gate`: the first hook to exit non-zero refuses the install or update. Every other hook's exit status is ignored. A gate hook also runs for installs and background updates that other tools make with `--yes`; `OMARCHY_ASSUME_YES=1` means nobody is at a terminal to answer a question. A gate hook must only read the code it is handed: Omarchy pins the commit before running it and refuses the install or update if the checkout changed.

Example hook script:
```bash
#!/bin/bash
THEME_NAME=$1
echo "Theme changed to: $THEME_NAME"
# Add custom actions here
```

Update-related hooks run as your user with your PATH, inside the update's sudo authorization, so a hook that invokes `sudo` does not prompt again. `post-update` runs after the system packages, migrations and service restarts. `pre-refresh-pacman` runs after `omarchy refresh pacman` re-syncs the package config and before the package transaction, so custom repositories and `IgnorePkg` entries shape that transaction.
