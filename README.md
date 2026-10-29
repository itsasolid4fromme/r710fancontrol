# r710-fan

Quiet, failsafe fan control for the Dell PowerEdge R710, using its iDRAC6 over IPMI.

It runs in a small Docker container on any other machine on your network. Nothing
has to be installed on the server itself, which makes it a good fit for ESXi,
where you can't easily run tools on the host.

Out of the box, Dell's automatic control holds an idle R710 at about 3600 RPM.
With the quiet profile in `env.example`, the same idle server runs at about 1560 RPM.

A web page shows the live readings and history, and lets you switch modes or set
a fixed speed.

![The r710-fan web page, showing example data](docs/dashboard.png)

## How it works

Every 30 seconds the container reads the iDRAC's sensors and picks a fan speed:

- **Inlet curve:** a fan percentage for each front inlet ("Ambient Temp") temperature.
- **Power curve (optional):** a fan percentage for each level of system power draw.
  The R710 reports no CPU temperatures, so power draw stands in for CPU load.
- The higher of the two curves wins.

It hands control back to Dell's automatic mode when any of these happen:

| Failsafe | Setting | Quiet profile |
|---|---|---|
| Inlet temperature too high | `AMBIENT_AUTO_C` | 35°C |
| Power draw too high (Dell can see CPU temps internally) | `POWER_AUTO_W` | 200 W |
| Any fan too slow or stopped | `FAN_FAIL_RPM` | 1000 RPM |
| CPU close to throttling, if your iDRAC reports it | `CPU_MARGIN_AUTO_C` | 20°C of headroom |
| No inlet temperature reading | | always |
| The iDRAC rejects a fan command | | always |
| The container stops | | always |

Manual control resumes only after the temperature or power drops back by the
hysteresis setting, so the fans don't flap between modes.

The project runs as two containers that share the `state/` folder:

- **`r710-fan`** is the controller and the only thing that talks to the iDRAC.
  After each check it writes `status.json` and adds a row to `history.csv`.
- **`r710-fan-web`** serves the web page. It reads those files and writes
  `state/override` when you pick a mode. The controller notices within a second.
  The web container never contacts the iDRAC, so it can't use up the iDRAC6's
  few IPMI sessions.

## R710 and iDRAC6 quirks it handles

- **No CPU temperatures.** The R710's CPU sensors are either disabled or report
  PECI values: negative numbers that mean degrees below the throttle point.
  Controllers that treat those as real temperatures think the CPUs are freezing.
- **Old cipher suite.** ipmitool 1.8.19 and later default to cipher suite 17,
  which the iDRAC6 rejects. This tool uses suite 3.
- **All-fans address.** Some iDRAC6 units refuse the `0xff` "all fans" address.
  The tool falls back to setting each fan on its own.
- **Few IPMI sessions.** The iDRAC6 allows only a handful of sessions. If ipmitool
  is killed mid-command, its session leaks, and after a few leaks every command
  fails, including the one that restores automatic mode. The tool never pipes
  ipmitool output, and it reads all sensors in one request per cycle.

## Measured fan speeds

Measured on one R710 with iDRAC6 firmware 2.91, five fans:

| Setting | RPM |
|---|---|
| Dell automatic, idle | 3480–3600 |
| 30% | 4440 |
| 20% | 3360 |
| 15% | 2760 |
| 10% | 2160–2280 |
| 6% | 1680–1920 |
| 4% | 1560–1680 |
| 2% | 1200 |

The iDRAC6 flags a fan as critical below 720 RPM. To measure your own server,
see [Calibrating](#calibrating).

## Setup

### 1. Put the iDRAC6 on the network

Reboot the R710 and press **Ctrl+E** when the iDRAC6 prompt appears during POST.

- **LAN Parameters:** choose the NIC. Use Dedicated with the iDRAC6 Enterprise
  card, or Shared (LOM1) without it. Then turn on DHCP or set a static address.
- **IPMI Over LAN:** On.
- **LAN User Configuration:** change the root password from the default `calvin`.

If the web interface already works, the same switch is under iDRAC Settings >
Network/Security > Network > IPMI Settings. Set the channel privilege limit to
Administrator. Dell's fan commands are refused for lower privilege levels.

### 2. Configure

```sh
git clone <this repo> r710-fan && cd r710-fan
cp env.example .env && chmod 600 .env
nano .env        # set IDRAC_HOST and IDRAC_PASSWORD
```

### 3. Test the connection

```sh
docker compose run --rm r710-fan test
```

This checks the login and the sensors, and confirms the iDRAC accepts fan commands.
It leaves the fans in Dell automatic mode.

### 4. Watch, then go live

`env.example` starts in monitor mode, which logs decisions without changing anything.

```sh
docker compose up -d
docker logs -f r710-fan
```

When the readings and chosen speeds look right, set `MONITOR_ONLY=false` in `.env`
and run `docker compose up -d` again.

## Everyday use

Open `http://<docker host>:8710` in a browser. The page shows:

- the current fan speed, inlet temperature and power draw, refreshed every few seconds
- each fan's RPM
- history charts for the last hour, 6 hours, 24 hours or 7 days, with a table view
- a mode switch: **Quiet curve**, **Fixed speed** with a slider, or **Dell automatic**

A banner explains whenever a failsafe has handed control to Dell or the
controller has stopped reporting.

The same controls work from the command line:

```sh
docker exec r710-fan fanctl status     # sensors, current override, last decision
docker exec r710-fan fanctl set 20     # hold 20%; the failsafes stay active
docker exec r710-fan fanctl curve      # back to the curves
docker exec r710-fan fanctl auto       # Dell automatic control
docker compose down                    # stop; fans go back to Dell automatic
```

Changes apply within a second. `set` and `auto` are saved in `state/override`,
so they survive a restart.

A log line looks like this:

```
2026-10-29 07:19:21 ambient=24C cpu=[n/a] power=140W fans=[FAN 1:1560, FAN 2:1680, ...] -> 4% (curve)
```

## Configuration

All settings live in `.env`. The table shows the built-in default, which applies
when a setting is missing. `env.example` overrides several of these with the quiet profile.

| Setting | Default | Meaning |
|---|---|---|
| `IDRAC_HOST` | | iDRAC address. Required. |
| `IDRAC_USER` | `root` | iDRAC login with Administrator privilege |
| `IDRAC_PASSWORD` | | Required. Single-quote it in `.env`. |
| `MONITOR_ONLY` | `false` | `true` logs decisions without changing the fans |
| `FAN_CURVE` | `20:12 24:15 27:20 30:30 33:45` | `inletC:percent` points, linear in between |
| `POWER_CURVE` | off | `watts:percent` points, linear in between |
| `MIN_FAN` / `MAX_FAN` | `10` / `100` | Limits for any manual speed |
| `AMBIENT_AUTO_C` | `35` | Inlet temperature that hands control to Dell |
| `POWER_AUTO_W` | `0` (off) | Power draw that hands control to Dell |
| `POWER_HYSTERESIS_W` | `20` | Watts the draw must fall before manual control resumes |
| `HYSTERESIS_C` | `3` | Degrees the temperature must fall before manual control resumes |
| `FAN_FAIL_RPM` | `1000` | Any fan below this hands control to Dell |
| `CPU_MARGIN_AUTO_C` | `20` | CPU headroom limit, used only if the iDRAC reports PECI values |
| `CPU_TEMP_AUTO_C` | `80` | CPU limit, used only if the iDRAC reports real CPU temperatures |
| `CHECK_INTERVAL` | `30` | Seconds between checks. After a speed change the next check comes within 10 s. |
| `IPMI_CIPHER` | `3` | IPMI cipher suite |
| `TZ` | UTC | Time zone for log timestamps |
| `WEB_PORT` | `8710` | Host port for the web page |
| `WEB_USER` / `WEB_PASSWORD` | none | Optional login for the web page. Empty password means no login. |
| `HISTORY_DAYS` | `7` | Days of readings kept for the charts |

Set `POWER_CURVE` and `POWER_AUTO_W` around your own idle draw. `fanctl status`
shows it as "System Level". With the curves in `env.example`, an idle draw near
140 W keeps the floor speed, and the fans climb as the draw passes 160 W.

## Calibrating

Stop the daemon first so it doesn't fight the measurement:

```sh
docker compose stop
docker compose run --rm --entrypoint r710-calibrate r710-fan
docker compose run --rm -e STEPS="8 6 4 2" -e SETTLE=15 --entrypoint r710-calibrate r710-fan
docker compose up -d
```

It steps through each percentage, prints every fan's RPM, and always finishes in
Dell automatic mode.

## Limitations

- **No CPU temperatures.** The curves follow inlet temperature and power draw.
  A CPU can get hot under a load that draws less than `POWER_AUTO_W`. The CPUs
  protect themselves by throttling, but set the power limits with that in mind.
- **The tool has to be running.** If the container, its host or the iDRAC goes
  down while the fans are on manual, they stay at their last speed. A normal
  stop hands them back to Dell first. Avoid running the container in a VM on the
  same R710, because a host crash would then leave the fans on manual.
- **Manual mode survives a host reboot.** The iDRAC keeps it until it is told
  otherwise or loses power.
- **The web page is plain HTTP.** Keep it on your LAN, or put it behind a
  reverse proxy with HTTPS. Set `WEB_PASSWORD` if others share your network.
  The page refuses cross-site requests, so another website can't change your fans.
- **Other servers are untested.** The same raw commands work on iDRAC7 and
  iDRAC8, and on iDRAC9 before firmware 3.34.34.34, but only the R710 has been tested.

Use at your own risk. Running server fans below Dell's defaults is unsupported by Dell.

## Tests

The controller tests run it against a fake ipmitool. They cover the curves,
every failsafe, hysteresis, overrides, the status and history files, the per-fan
fallback, iDRAC outages and shutdown. The web tests cover the API, input
checking, cross-site refusal and the optional login.

```sh
docker build -t r710-fan:local .
docker run --rm -v "$PWD/tests:/tests:ro" --entrypoint bash r710-fan:local \
  /tests/tests.sh /usr/local/bin/r710-fan
docker run --rm -v "$PWD:/src:ro" --entrypoint python3 r710-fan:local \
  -m unittest discover -s /src/tests -p "test_*.py"
```

GitHub Actions runs the same tests on every push.

## Raw commands

For reference, these are Dell's IPMI commands that the tool sends:

```sh
ipmitool -I lanplus -C 3 -H <idrac> -U root -P <password> raw 0x30 0x30 0x01 0x00       # manual mode
ipmitool -I lanplus -C 3 -H <idrac> -U root -P <password> raw 0x30 0x30 0x02 0xff 0x04  # all fans 4%
ipmitool -I lanplus -C 3 -H <idrac> -U root -P <password> raw 0x30 0x30 0x01 0x01       # Dell automatic
```

## References

- [R710 IPMI fan commands (millerjs wiki)](https://wiki.millerjs.org/r710/ipmi)
- [Dell iDRAC fan controller for Docker (tigerblue77)](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker), including iDRAC6 notes
- [ipmitool cipher suite 17 incompatibility (Red Hat)](https://access.redhat.com/solutions/5931381)
