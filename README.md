# rkmpp-smi

A single-file bash terminal monitor for Rockchip SoCs, modelled on `nvidia-smi`.
It reports CPU, RAM, GPU, NPU, DMC, RGA and per-block VPU (MPP) load and
utilisation in one redrawing frame.

Aimed at the media pipeline: the MPP block section shows the per-core `load`
and `utilization` counters that the Rockchip vendor kernel exposes under
`/proc/mpp_service`.

```
Radxa ROCK 5C  rockchip,rk3588  14:03:52 up 14d 23h 31m
────────────────────────────────────────────────────────────────────────────────
  CPU          [████░░░░░░░░░░░░░░░░]  24%  L0 1.80 GHz, L4 2.30 GHz  42.5°C
  Mem          [██████████░░░░░░░░░░]  53%  used 8.36 GiB / 15.58 GiB
               cache 5.12 GiB (recl)
               swap 3.63 GiB / 7.79 GiB
────────────────────────────────────────────────────────────────────────────────
  GPU          [░░░░░░░░░░░░░░░░░░░░]   0%     200 MHz  40.6°C
  NPU          [██░░░░░░░░░░░░░░░░░░]  14%    1.00 GHz  cores 14/1/2  41.6°C
  DMC          [███░░░░░░░░░░░░░░░░░]  16%    2.11 GHz
  RGA          [█░░░░░░░░░░░░░░░░░░░]   6%
────────────────────────────────────────────────────────────────────────────────
  VPU / MPP blocks
     rkvdec-core[0] [█░░░░░░░░░░░░░░░░░░░]   7%  util 4.91%
     rkvdec-core[1] [██░░░░░░░░░░░░░░░░░░]  13%  util 12.19%
────────────────────────────────────────────────────────────────────────────────
  MPP sess     9 active
     rkvdec-core:9
```

## Requirements

- bash 4.4+ (5.0+ recommended; uses `EPOCHREALTIME` when present)
- awk, coreutils (`tr`, `head`)
- `tput` (optional; only used to read terminal width)
- A Rockchip vendor kernel exposing `/proc/mpp_service` for the MPP section.
  Without it the rest of the frame still works.

## Usage

```
rkmpp-smi [options]
```

Run with `sudo` for the root-only counters (see *Privileges*).

| Option | Description |
| --- | --- |
| `-n`, `--interval SEC` | Refresh interval in seconds, fractional allowed (default `1`) |
| `-a`, `--all` | Show every MPP block, not only the busy ones |
| `-o`, `--once` | Print one frame and exit |
| `--color` / `--no-color` | Force colours on / off (also honours `$NO_COLOR`) |
| `-V`, `--version` | Print version and exit |
| `-h`, `--help` | Help |

Keys: `q` or `Ctrl-C` to quit.

Piping output (stdout is not a tty) implies `--once`, so `rkmpp-smi > frame.txt`
does the expected thing. The layout fits the terminal width; set `COLUMNS` to
override it when the output isn't a terminal.

## Metrics and data sources

| Field | Source | Root |
| --- | --- | --- |
| CPU usage | `/proc/stat` (delta between frames) | no |
| CPU frequency | `/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq` (kHz, per cluster, labelled `L<policy>`) | no |
| Temperatures | `/sys/class/thermal/thermal_zone*/`; matched by `type` (`soc`/`cpu`, `gpu`, `npu`) | no |
| RAM / swap | `/proc/meminfo` (`MemTotal`, `MemAvailable`, `Cached`, `SwapTotal`, `SwapFree`) | no |
| GPU load / freq | devfreq node whose `name` matches `gpu`; `load` file (`<pct>@<freq>Hz`) | no |
| NPU load | `/sys/kernel/debug/rknpu/load`, per-core (bar shows the busiest core) | **yes** |
| NPU frequency | devfreq node matching `npu` | no |
| DMC load / freq | devfreq node matching `dmc` | no |
| RGA load | `/sys/kernel/debug/rkrga/load`, busiest scheduler of the units present | **yes** |
| VPU / MPP blocks | `/proc/mpp_service/load` (`load:` and `utilization:` per block) | no |
| MPP sessions | `/proc/mpp_service/sessions-summary`, grouped by device | no |
| Board / SoC | `/proc/device-tree/model`, `/proc/device-tree/compatible` | no |

`/proc/mpp_service/load_interval` is written to match `--interval` when running
as root, so the kernel sampling window lines up with the refresh rate.

## How it works

- Collectors (`collect_cpu`, `collect_mem`, `collect_accel`, `collect_mpp`,
  `collect_sessions`) set shell globals and never abort on a missing source;
  `render` reads those globals. Metric gathering and formatting are separate.
- Accelerator devfreq nodes are found by reading each `name` and matching a
  regex on `.`/`-` boundaries, not by directory glob. Node names are
  driver-defined — on the ROCK 5C the GPU is `fb000000.gpu-panthor`, which a
  `*.gpu` glob would miss, while a boundary match still rejects `mygpu`.
- The per-frame path avoids forks: bar, Hz/KiB/temperature and uptime
  formatting write a global (`BAR`, `FMT_*`, `REP`) instead of forking a
  command substitution, and the clock comes from bash's `printf '%()T'` rather
  than `date`. `awk` is used only for one-shot startup conversions.
- Frame scheduling uses `EPOCHREALTIME` and sleeps only the remaining time, so
  the interval does not drift with render cost. The `q` key is polled every
  frame (capped at `KEY_POLL_US`), so quitting stays responsive even when a
  frame takes longer than `--interval` to draw.
- Interactive mode hides the cursor, homes with `ESC[H` and erases with
  `ESC[J` per frame. An `EXIT` trap restores the cursor and the saved
  `load_interval`.
- MPP core names are normalised by stripping the `fddddddd.` prefix and
  numbering duplicates (`rkvdec-core[0]`, `rkvdec-core[1]`).
- The layout follows the terminal width: the rule is exactly `TERM_COLS`, and
  each row's optional tail (frequency list, temperature, utilisation) is fitted
  to it — full units when there is room, then compact (`L0 1.8G`), then a
  truncated `..` form. Narrow terminals also shrink the bars down to
  `BAR_MIN`. `$COLUMNS` overrides the detected width (useful when piping).
  The width is floored at `MIN_WIDTH` (48) and capped at `MAX_WIDTH` (120).

## Privileges

The script runs unprivileged. Root is needed only for:

- `/sys/kernel/debug/rknpu/load` — per-core NPU load
- `/sys/kernel/debug/rkrga/load` — RGA load (shown as `n/a (needs root)`
  otherwise; as root without the file it reads `n/a (no rkrga)`)
- writing `/proc/mpp_service/load_interval`

Without root, NPU falls back to the devfreq `load` value, tagged `devfreq` in
the row. GPU, DMC and NPU frequency come from devfreq and need no privilege.

## Limitations

- RGA is debugfs-only, and the value shown is the busiest scheduler
  (`rkrga/load` lists one entry per unit, e.g. 2x rga3 + 1x rga2). Per-unit
  breakdown is not shown.
- NPU load requires root. It is read from `/sys/kernel/debug/rknpu/load`
  (bar = busiest core, per-core values in the row). Unprivileged runs fall back
  to the devfreq `load` value, tagged `devfreq`; on this kernel that value is
  the `rknpu_ondemand` governor's request and pins near 100, so it is not real
  utilisation.
- DMC `load` is the devfreq governor's utilisation estimate, not a memory
  bandwidth measurement.
- `/proc/mpp_service/load_interval` is a single global; restoring it on exit
  can race with a second running instance.
- The MPP block list is whatever the kernel exposes at runtime.
- Some kernels (e.g. the RK3566 build tested) return
  `please set load_interval first!!!` from `/proc/mpp_service/load` until the
  sampling window is set. That needs root, so the MPP section only works with
  `sudo` there and otherwise says so.
- Rows are drawn only when the SoC exposes the source. A board whose kernel has
  no NPU node (some RK3566 builds) shows no NPU row rather than a fake reading.

## Install

```
install -m 755 rkmpp-smi /usr/local/bin/rkmpp-smi
```

## Testing

The pure logic is covered by a dependency-free bash suite that runs anywhere
(including this non-Rockchip dev box, where the accelerator/MPP rows degrade
as designed):

```
bash -n rkmpp-smi        # syntax
bash tests/run.sh        # formatters, collectors, CLI, frame layout, q-quit
```

The suite sources the script (its main block is guarded by a `BASH_SOURCE`
check), so collectors and formatters can be exercised without hardware. The
`q`-quit path is driven through a real pty when `python3` is available, and
skipped otherwise.

Full verification of the live frame still happens on the ROCK hosts:

```
ssh rockchip-host-a /usr/local/bin/rkmpp-smi --once --all
ssh rockchip-host-b /usr/local/bin/rkmpp-smi --once
```

## Tested on

- Radxa ROCK 5C (RK3588S), kernel `6.1.115-vendor-rk35xx`
- Radxa ROCK 3C (RK3566), kernel `6.1.84-18-rk2410-nocsf`
- x86-64 (degraded: no devfreq/NPU/MPP nodes — used for the unit-test baseline)
