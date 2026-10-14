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

### The installer screen

1. **Review**: "install 3 items", one line per missing dependency with its
   `size`. It is one decision: K3 installs all of them, K2 cancels. E2
   moves the highlight to show each item's `why` (or why it is blocked).
2. **Running**: the current dependency and step, with a progress bar. K2
   cancels.
3. **Done**: one line per dependency, installed, skipped (optional and
   blocked) or failed (optional, and its step failed), so steps that went
   past too fast to read can be checked afterwards. E2 scrolls, K3 closes.
   When a dependency needs a restart, K3 restarts instead and K2 is "later".

A required step that fails stops the run on a **failed** screen with the
end of its log (E2 scrolls, K3 retries, K2 closes). A required dependency
with no recipe for the platform, or root steps without a way to get root,
show a **blocked** screen with the command to run by hand instead.
`remove` uses the same screens ("remove 2 items", K3 remove all).

### Dependency fields

| field | meaning |
|---|---|
| `id` | required, unique |
| `label`, `why`, `size` | shown in the review list |
| `check` | command(s) that must be on PATH (also looks in `~/.local/bin`, `/usr/local/bin`) |
| `check_file` | file(s) that must exist |
| `check_ugens` | plugin or class file name(s) SuperCollider must find: `"MiPlaits"` (a plugin, `.so` or `.scx`) or `"MiPlaits.sc"` |
| `check_fn` | function returning true when satisfied |
| `needs` | ids installed first |
| `restart` | installing it needs an sclang restart (UGens, classes; set automatically by a `ugens` step); the screen ends with K3 restart / K2 later, and `on_done` gets `needs_restart` |
| `manual` | shown instead of "no recipe" when nothing matches the platform |
| `optional` | a failure is skipped instead of stopping the run |
| `pkg`, `pipx`, `url`, `ugens`, `cmd` | shorthand for a single step |
| `recommends` | `false` installs a `pkg` without its recommended packages (apt `--no-install-recommends`) |
| `uninstall` | list of steps that undo the install, see [Uninstall](#uninstall) |
| `install` | list of `{ when = {...}, steps = {...} }`; the first recipe whose `when` matches wins. `when` keys: `arch`, `pm`, `desktop`, `shield`, `os_id` |

Steps:

- `{ pkg = "name" }` or `{ pkg = { apt = ..., pacman = ..., dnf = ... } }`,
  optionally with `recommends = false`
- `{ pipx = "package" }`
- `{ url = ..., dest = ..., sha256 = ..., extract = dir }` (wget, or curl;
  `.zip` is unzipped, anything else goes through `tar -xf`)
- `{ ugens = url, into = "folder", sha256 = ... }`, see [UGens](#ugens)
- `{ cmd = "shell", priv = true, step_label = "...", progress = "percent" }`

In `url` and `ugens`, `{arch}` in the URL is replaced by the machine name
(`armv7l`, `aarch64`, `x86_64`), and `sha256` can be a table of checksums by
machine name. A machine that is not in the table has no download: the
dependency is blocked and shows its `manual` text.

A dependency counts as installed only if its check passes after the steps
ran; otherwise the run stops with "installed, but the check still fails".

### Root

Steps that need root (`pkg`, `priv = true`) use, in order: already root,
`sudo -n` (norns shields have it), or on desktop `pkexec` (graphical
password prompt). With none of these the installer screen lists the exact
`sudo ...` command to run by hand instead of failing halfway.

### Restart required

A dependency with `restart = true` is only usable once sclang has been
restarted. After installing it, the library writes a marker file and shows
"restart needed"; K3 calls `_norns.reset()` (restarts sclang and matron, what
SYSTEM > RESTART ends with). `d:restart_pending()` compares the marker with
sclang's start time, so the prompt comes back after a script reload until the
restart has really happened. `d:ensure` shows only that screen when nothing is
missing but a restart is still pending.

Mods have no `include()`: load the library with
`dofile(_path.code .. "mymod/lib/deps.lua")` (`mod.this_name` only holds
the name while the mod file loads). Open `ensure` once a script is running,
e.g. from a `script_post_init` hook or a `clock.run` with a short sleep,
since loading a script resets the key, enc and redraw handlers.

### UGens

```lua
d:add { id = "nb_pp", label = "PlaitsPalette UGen", size = "2 MB",
        check_ugens = "PlaitsPalette",
        ugens = "https://github.com/me/nb_pp/releases/download/v1/"
          .. "PlaitsPalette-{arch}.tar.gz",
        sha256 = { armv7l = "...", aarch64 = "..." },
        manual = "build it: ugen/build.sh install" }
```

A `ugens` step downloads an archive (or a single `.so` / `.scx` / `.sc`) and
copies its contents to
`~/.local/share/SuperCollider/Extensions/<into>`; `into` defaults to the
dependency's id. `restart` is switched on, so the screen ends with the
restart prompt.

A plugin or class file that SuperCollider already finds somewhere else is
left out of the copy and named in the log, because a second copy of a class
stops sclang from compiling at all. So a pack that overlaps with something
installed by hand or by another script installs only what is new.

To make an archive, on each kind of device:

```sh
tar -czf PlaitsPalette-$(uname -m).tar.gz PlaitsPalette.so   # plus any .sc
sha256sum PlaitsPalette-$(uname -m).tar.gz
```

A plugin has to be built for the machine and for the SuperCollider version
that runs it. Building on the device is an ordinary `cmd` step instead.

`d:ugen_conflicts()` returns the file names that exist in more than one
place, as `{ name = { paths } }`: plugins (`*.so`, `*.scx`) under the
Extensions and plugin folders scsynth loads from, class files
(`Capitalised.sc`) under the Extensions folders and the include paths in
`sclang_conf.yaml` (on norns, all of `dust`).

## Uninstall

Every dependency that an install session puts in place is written to
`<dir>/manifest.lua`, together with the steps that remove it again.
Dependencies that were already there before (their check passed) are not
listed, so uninstalling never takes away a package the user installed
themselves.

The removal steps are the dependency's `uninstall` list, or else derived
from the install recipe: a `pkg` step is removed with the package manager,
`pipx` with `pipx uninstall`, a `ugens` step by deleting its Extensions
folder, and a `url` step with `dest` (no `extract`) by deleting the file.
Commands and extracted archives can't be undone automatically; give those
an `uninstall` list:

```lua
d:add { id = "link", check_file = "~/bin/tool",
        cmd = "ln -s /opt/tool/bin/tool ~/bin/tool",
        uninstall = { { cmd = "rm -f ~/bin/tool" } } }
```

`uninstall` steps use the same format as install steps (`priv = true` for
root, `{ pkg = ..., remove = true }` to remove a package). They are stored
as data in the manifest, so uninstalling needs only the `dir`:

```lua
local d = deps.new { name = "myscript", dir = _path.data .. "myscript/deps" }
d:remove(nil, { on_done = function(ok, results, did_remove, needs_restart) end })
```

`remove(ids, opts)` opens the same screen as `ensure`: the list of what
will be removed, K3 to go, progress, retry on failure. Dependencies are
removed newest first. `ok` is false when the user cancelled or a step
failed; whatever was removed is gone from the manifest either way, so
running it again continues where it stopped. `d:installed()` lists the
ids in the manifest, and `d:uninstall_session(ids)` is the headless
version.

### Uninstalling a mod

Nothing in norns runs a mod's code when it is removed: maiden and
modhousekeeper delete its directory. A mod that installs things can ship
`lib/uninstall.lua`, which returns a function taking an `on_done(ok)`
callback:

```lua
-- lib/uninstall.lua
return function(on_done)
  local deps = dofile(_path.code .. "mymod/lib/deps.lua")
  local d = deps.new { name = "mymod", dir = _path.data .. "mymod/deps" }
  d:remove(nil, { on_done = function(ok) on_done(ok) end })
end
```

[modhousekeeper](https://github.com/vehka/modhousekeeper) calls it before
deleting the mod, and keeps the mod when `ok` is false. Remove the mod's
own leftovers (data files) there too, but leave the mod's directory and
`system.mods` to the caller.

The mod itself stays loaded in matron until norns restarts, and its hooks
keep running: a menu's `deinit`, a script's params, `system_pre_shutdown`.
Make them check that the mod is still installed before they write data or
start anything, or they put back what the uninstall removed:

```lua
local function uninstalled()
  return not util.file_exists(_path.code .. "mymod/lib/mod.lua")
end
```

## How it works

Each step runs as a detached `sh` job (own session) that writes its output
to a log and its exit code to a status file; the UI polls them. This avoids
`norns.system_cmd`, which only reports once a command finishes and never
reports a failure. Progress comes from apt's `APT::Status-Fd` output or the
`NN%` lines of wget/curl; other steps show an indeterminate bar.

The library only uses `os.execute` and read-mode `io.popen`, so it also
works on the norns 3 beta, where shell commands go through a sidecar
process and `io.popen(cmd, "w")` is refused.

## Tests

```sh
lua5.3 tests/run.lua
```

Runs without norns: planning, the job runner, sessions, downloads against a
local web server, UGen scanning and install.
