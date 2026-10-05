# TODO

State: library, UI and tests work (`lua5.3 tests/run.lua`, 27 tests). Verified
on desktop norns (Manjaro) with fake deps and a real download. First consumer
is the `SPEECH` script.

## Not yet tested

- ~~Shield (armv7, Debian): apt progress parsing (`APT::Status-Fd=1`),
  `sudo -n` as `we`, the Piper ARMv7 recipe (download, extract, link into
  `/usr/local/bin`), behaviour over flaky wifi.~~
- Desktop root path with `pkexec` (graphical prompt) and `sudo -n`; only
  command planning is tested.
- ~~Speech's auto-open at init and the "install dependencies" params trigger.~~
- ~~The script reload after a successful install (`norns.script.load`).~~
- ~~The `ugens` step on a device, with a real plugin (nb_pp's PlaitsPalette)
  and the restart after it.~~ (shield, armv7l, served over the LAN)
- rp4 variants (XL, fates, rp4 shields): only assumed to match shield.

## Next

- Show the "skipped X: already at ..." lines of a `ugens` step on the done
  screen; they are only in the job log now.
- A 64-bit kernel under a 32-bit system reports `aarch64`; `{arch}` then
  picks the wrong plugin. Detect the userland (`dpkg --print-architecture`).
- Show a summary of optional deps that failed and were skipped.
- Cancel while a `pkexec` prompt is open (the job may outlive the cancel).
- UI: scroll the failed-step log fully; show the manual command on failure
  of a privileged step.

## Notes

- norns' `require` does not resolve script-relative paths; the library loads
  its submodules by file path so `include("lib/deps")` works under any
  directory name.
- `norns.system_cmd` reports only at the end and never on failure, hence the
  detached-job runner.
