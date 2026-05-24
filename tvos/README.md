# Duplex tvOS

## Installing to a device

```
make clean && make install \
    DEVELOPMENT_TEAM=<TEAM_ID> \
    DEVICE_ID=<DEVICE_UUID> \
    WEBVIEW_URL=http://<host>:2345
```

`DEVELOPMENT_TEAM` is optional — when omitted, the Makefile auto-detects it from
your `Apple Development` certificate. `DEVICE_ID` is required if you have more
than one Apple TV paired (otherwise the first one is used). `WEBVIEW_URL`
defaults to `http://localhost:2345`; set it to the host running the duplex
server (usually not `localhost`, since the Apple TV needs to reach it over the
network).

### Finding `DEVICE_ID`

```
make list
```

The UUID in the third column is the value to pass.

### Finding `DEVELOPMENT_TEAM`

The 10-character Team ID is the **OU** field of your signing certificate's
subject — not the parenthesized string in the certificate name (that's an
Apple-internal user identifier and `xcodebuild` will reject it with
"No Account for Team ...").

```
security find-certificate -c "Apple Development" -p \
    | openssl x509 -noout -subject
```

Look for `OU=XXXXXXXXXX` in the output.

Cross-check against the team(s) Xcode actually knows about:

```
defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier
```

And against the team(s) on your installed provisioning profiles:

```
for p in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
    security cms -D -i "$p" | sed -n '/TeamIdentifier/,/<\/array>/p'
done
```

All three should agree.

## Other targets

- `make generate` — regenerate `Duplex.xcodeproj` from `project.yml` via xcodegen
- `make build` — build for device (no install)
- `make run` — same as `make install`, but stays attached to the app's
  stdout/stderr (via `devicectl --console`). Use this for live debugging.
  Ctrl-C detaches.
- `make simulator` — build for the tvOS simulator
- `make list` — list paired Apple TVs
- `make clean` — remove generated project, build dir, and DerivedData
