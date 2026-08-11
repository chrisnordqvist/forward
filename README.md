# Forward

A small macOS menu bar app for managing SSH port forwards. It is `ssh -L 4000:localhost:4000 host`, but named, persistent, and supervised.

```
┌────────────────────────────────┐
│  Forward            2 active   │
├────────────────────────────────┤
│  ● Staging              ▣      │
│    ● API      4000 → 4000   ◉  │
│    ○ Postgres 5432 → 5432   ○  │
│  ○ Prod                 ▶      │
│    ○ Redis    6379 → 6379   ○  │
├────────────────────────────────┤
│  Start All   Stop All          │
│  Settings…               ⌘,    │
│  Quit Forward            ⌘Q    │
└────────────────────────────────┘
```

## What it does

- **Named forwards, grouped by host.** A host owns one or more local (`-L`) forwards. Toggle one, or bring the whole host up at once.
- **One connection per host.** All of a host's forwards ride a single ssh ControlMaster connection, so you authenticate once and toggling a forward never disturbs its siblings.
- **Health checks and auto-reconnect.** A dropped tunnel is noticed within seconds and retried with exponential backoff. Failures a retry cannot fix — bad credentials, unknown hosts — stop immediately with the real error instead of retrying six times.
- **Port conflict detection.** If something already holds the local port, you get *"Local port 4000 is already in use by node (pid 12345)"* rather than an opaque ssh failure.
- **A config file you can edit.** Everything lives in `~/.config/forward/config.json`. Edit it in your editor and the app picks the change up immediately, adjusting live tunnels without dropping the ones that didn't change.

## Requirements

macOS 14+, Xcode command line tools. No dependencies.

## Build and run

```sh
make                    # build build/Forward.app
make run                # build and launch it
make install            # copy to /Applications
make install DEST=$HOME # ...or anywhere else
make dist               # zip for carrying to another Mac
make test               # run the test suite
```

The menu bar UI only works from an `.app` bundle, so use `make run` rather than `swift run`.

The app is ad-hoc signed and **not sandboxed** — it has to spawn `/usr/bin/ssh`.

## Moving it to another Mac

```sh
make dist   # → dist/Forward-<version>-arm64.zip
```

The zip is built with `ditto` rather than `zip`, which preserves the code signature and
extended attributes; a plain `zip` mangles the bundle and the copy is rejected as damaged
on arrival. The build is arm64 only — Apple silicon, macOS 14+.

Because the app is ad-hoc signed rather than notarized, macOS will block it on first
launch on the receiving machine. Clear the quarantine flag there:

```sh
xattr -dr com.apple.quarantine /Applications/Forward.app
open /Applications/Forward.app
```

Whether the flag is set at all depends on transport — AirDrop and downloads set it, `scp`
and `rsync` do not — but running the command is harmless either way. `dist/INSTALL.txt`
is a copy of these instructions to send along with the zip.

Distributing it more widely, or avoiding that step, would need a Developer ID and Apple
notarization.

## How it works

Forward never implements SSH. It shells out to the system `ssh`, so `~/.ssh/config`, `ProxyJump`, `Include`, ssh-agent, key types and `known_hosts` all work exactly as they do in your terminal. A host's **SSH host** field is passed verbatim, so an alias from your ssh config works as-is.

Each host gets one master connection, started with no forwards at all:

```sh
ssh -N -M -S ~/.local/state/forward/cm-<id>.sock \
    -o ControlPersist=no -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10 -o BatchMode=yes <host>
```

Forwards are then added and removed over that socket while it stays up:

```sh
ssh -S <socket> -O forward -L 127.0.0.1:4000:localhost:4000 <host>   # add
ssh -S <socket> -O cancel  -L 127.0.0.1:4000:localhost:4000 <host>   # remove
ssh -S <socket> -O check <host>                                      # liveness probe
```

Keeping the master free of `-L` flags is deliberate: each forward then succeeds or fails on its own, so one port clash cannot take down a host's other tunnels, and `-O check` gives a real liveness answer rather than merely "is the process still there".

Forwards bind to `127.0.0.1` explicitly, so they are never exposed on your local network regardless of your `GatewayPorts` setting.

## Authentication

Forward runs without a terminal, so an interactive passphrase or host-key prompt would hang forever. It therefore passes `-o BatchMode=yes` by default, which turns that hang into an immediate, readable error.

In practice this means **key-based auth** — either keys with no passphrase, or keys loaded into ssh-agent. When something needs a human:

- **Open in Terminal** (host right-click menu, or the Advanced section in Settings) runs the equivalent `ssh` command in Terminal.app so you can accept a host key or enter a passphrase once.
- Turn **BatchMode** off for a host in Settings › Tunnels › Advanced if you use an askpass helper.

## Configuration

`~/.config/forward/config.json`:

```jsonc
{
  "version": 1,
  "hosts": [
    {
      "id": "6C1F6E3A-0000-0000-0000-000000000001",
      "name": "Staging",              // display name for the group
      "sshHost": "staging-api",       // passed to ssh; a ~/.ssh/config alias is fine
      "user": null,                   // optional -l; null defers to ssh config
      "port": null,                   // optional -p; null defers to ssh config
      "batchMode": true,              // fail fast instead of hanging on a prompt
      "autoStart": false,             // connect when Forward launches
      "extraOptions": ["Compression=yes"],   // each becomes -o <value>
      "forwards": [
        {
          "id": "6C1F6E3A-0000-0000-0000-000000000002",
          "name": "API",
          "localPort": 4000,
          "remoteHost": "localhost",  // resolved on the far side
          "remotePort": 4000,
          "enabled": true
        }
      ]
    }
  ],
  "settings": {
    "launchAtLogin": false,
    "healthIntervalSeconds": 10,
    "maxReconnectAttempts": 6
  }
}
```

Comments and trailing commas are accepted when reading. Note that saving from the app rewrites the file as strict JSON, so comments do not survive an in-app edit.

Missing keys fall back to sensible defaults rather than failing the whole file, and a file that fails to parse leaves running tunnels alone — the error surfaces in the menu and in Settings › General.

## Tests

```sh
make test
```

The unit tests are hermetic. The live integration tests exercise a real tunnel end to end — connect, forward traffic, reconnect after a killed master, detect a port conflict — and are skipped unless a test server is running:

```sh
eval "$(./Scripts/test-sshd.sh start)"
swift test
./Scripts/test-sshd.sh stop
```

`Scripts/test-sshd.sh` runs a throwaway unprivileged `sshd` on a high port with its own host key and `authorized_keys` under a temp directory. It needs no admin rights, does not enable Remote Login, and never touches `~/.ssh`.

## Limitations

- Local (`-L`) forwards only. No reverse (`-R`) forwards and no SOCKS (`-D`) proxies. The config schema leaves room to add a `kind` field later without a migration.
- Unknown host keys fail rather than prompt, since there is no terminal to prompt on. Use **Open in Terminal** once to accept them.

## License

MIT — see [LICENSE](LICENSE).
