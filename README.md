# norns-deps

A library for norns scripts that need things installed: system packages,
pipx tools, downloaded models and samples, UGen binaries. A script describes
its dependencies in a table; the library checks them, installs what is
missing in the background, and shows progress and errors on the norns screen.

Works on norns, shields (rp3/rp4, 32- or 64-bit) and desktop norns.

## Use

Copy `lib/deps.lua` and `lib/deps/` into your script's `lib/`.

```lua
local deps = include("lib/deps")
local d = deps.new { name = "myscript", dir = _path.data .. "myscript/deps" }

d:add { id = "sox", label = "SoX", check = "sox", pkg = "sox",
        size = "1 MB", why = "resamples audio" }
d:add { id = "pipx", check = "pipx",
        pkg = { apt = "pipx", pacman = "python-pipx" } }
d:add { id = "piper", check = "piper", needs = { "pipx" },
        install = {
          { when = { arch = "armv7l" }, steps = {
            { url = "https://.../piper_linux_armv7l.tar.gz",
              extract = "~/.local/share/piper/runtime" },
            { cmd = "ln -sfn $HOME/.local/share/piper/runtime/piper/piper"
                .. " /usr/local/bin/piper", priv = true },
          } },
          { steps = { { pipx = "piper-tts" } } },
        } }

if not d:ok("sox") then
  d:ensure({ "sox" }, { on_done = function(ok, results, did_install) end })
end
```

`ensure` takes over `key`, `enc` and `redraw` while the installer screen is
open and puts the script's own back when it closes. It does nothing when
everything is already in place. Scripts usually reload themselves after an
install (`norns.script.load(norns.state.script)`), since availability is
decided at init.

### Dependency fields

| field | meaning |
|---|---|
| `id` | required, unique |
| `label`, `why`, `size` | shown in the review list |
| `check` | command(s) that must be on PATH (also looks in `~/.local/bin`, `/usr/local/bin`) |
| `check_file` | file(s) that must exist |
| `check_ugens` | plugin/class file name(s) that must exist on the SC class path |
| `check_fn` | function returning true when satisfied |
| `needs` | ids installed first |
| `optional` | a failure is skipped instead of stopping the run |
| `pkg`, `pipx`, `url`, `cmd` | shorthand for a single step |
| `install` | list of `{ when = {...}, steps = {...} }`; the first recipe whose `when` matches wins. `when` keys: `arch`, `pm`, `desktop`, `shield`, `os_id` |

Steps:

- `{ pkg = "name" }` or `{ pkg = { apt = ..., pacman = ..., dnf = ... } }`
- `{ pipx = "package" }`
- `{ url = ..., dest = ..., sha256 = ..., extract = dir }` (wget, or curl;
  `.zip` is unzipped, anything else goes through `tar -xf`)
- `{ cmd = "shell", priv = true, step_label = "...", progress = "percent" }`

A dependency counts as installed only if its check passes after the steps
ran; otherwise the run stops with "installed, but the check still fails".

### Root

Steps that need root (`pkg`, `priv = true`) use, in order: already root,
`sudo -n` (norns shields have it), or on desktop `pkexec` (graphical
password prompt). With none of these the installer screen lists the exact
`sudo ...` command to run by hand instead of failing halfway.

### UGen conflicts

`d:ugen_conflicts()` returns file names (`*.scx`, `Capitalised.sc`) that
exist in more than one place under the SuperCollider Extensions folders and
the include paths in `sclang_conf.yaml`. Duplicates make sclang or scsynth
complain, so a script can warn before installing another copy.

## How it works

Each step runs as a detached `sh` job (own session) that writes its output
to a log and its exit code to a status file; the UI polls them. This avoids
`norns.system_cmd`, which only reports once a command finishes and never
reports a failure. Progress comes from apt's `APT::Status-Fd` output or the
`NN%` lines of wget/curl; other steps show an indeterminate bar.

## Tests

```sh
lua5.3 tests/run.lua
```

Runs without norns: planning, the job runner, sessions, downloads against a
local web server, UGen scanning.
