#!/usr/bin/env python3
"""What the machine was doing over one window, from the samples the session sampler wrote.

    sysstat.py START END [--docker-root PATH]   one window's summary as JSON, epoch seconds
    sysstat.py --selftest                       prove the parsing and the arithmetic and stop

Imported by host/monitor/session-records.py, which stores the summary on every run, and by
host/session/status.py. It reads the daily `saDD` files host/lib/sampler.sh has `sadc` write
under $RUNNER_CACHE_DIR/sysstat, through `sadf`, and writes nothing.

A window with no sample in it is None, never a summary of zeros: the sampler runs only when
RUNNER_SAMPLE_SECONDS is set, and a quiet machine must not read like an unwatched one.

see docs/monitor.md#the-machine-a-run-ran-on
"""

import argparse
import datetime
import functools
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time

# One call per file for every block. A block the file does not hold is left out and the
# call still succeeds (measured, sysstat 12.7.7), so a file older than XDISK still reads.
ACTIVITIES = ("-u", "-q", "ALL", "-r", "-W", "-d", "-p", "-F", "MOUNT")

# Not disks of their own: a loop device is a file on one, and sr0 is the provider's ISO drive.
NOT_DISKS = re.compile(r"(loop|sr|ram|zram)\d+")

# The columns summary() reads; the two names stay text, the rest are numbers.
KEPT = frozenset(
    {
        "%idle", "%steal", "%iowait", "ldavg-1", "%scpu", "%fio", "%fmem",
        "kbavail", "kbmemused", "%memused", "pswpin/s", "pswpout/s",
        "DEV", "tps", "%util", "await", "MOUNTPOINT", "MBfsfree", "MBfsused",
    }
)  # fmt: skip
NAMES = frozenset({"DEV", "MOUNTPOINT"})


def directory():
    cache = os.environ.get("RUNNER_CACHE_DIR") or ""
    return os.path.join(cache, "sysstat") if cache else None


def docker_root():
    """Where Docker keeps its images and volumes, or None when docker does not answer."""
    try:
        done = subprocess.run(
            ["docker", "info", "-f", "{{.DockerRootDir}}"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    root = done.stdout.strip()
    return root if done.returncode == 0 and root.startswith("/") else None


def page_kb():
    try:
        return os.sysconf("SC_PAGE_SIZE") // 1024
    except (OSError, ValueError):
        return 4


# --------------------------------------------------------------------------
# Reading
# --------------------------------------------------------------------------


def files_for(where, start, end):
    """The daily files a window can have samples in.

    `saDD` is a day of the month and is replaced a month on, so a name is not a date: the
    samples are kept by their own timestamps, and a file of the same name from last month
    contributes nothing. Both clocks, so a window across midnight finds its second file
    whichever one sadc names files by.
    """
    names = set()
    for zone in (None, datetime.UTC):
        day = datetime.datetime.fromtimestamp(start, zone).date()
        last = datetime.datetime.fromtimestamp(end, zone).date()
        while day <= last:
            names.add("sa%02d" % day.day)
            day += datetime.timedelta(days=1)
    return [
        os.path.join(where, name)
        for name in sorted(names)
        if os.path.isfile(os.path.join(where, name))
    ]


def parse(text):
    """Every data line as (timestamp, interval, {column: value}), named by its block's header.

    Only the columns summary() reads, as numbers: a day at 5 s is tens of thousands of lines.
    """
    rows, columns = [], None
    for line in text.splitlines():
        if line.startswith("# "):
            columns = line[2:].split(";")
            continue
        values = line.split(";")
        if not columns or len(values) != len(columns):
            continue
        fields = dict(zip(columns, values, strict=True))
        try:
            when, interval = int(fields["timestamp"]), int(fields["interval"])
        except (KeyError, ValueError):
            continue
        row = {k: v if k in NAMES else number(v) for k, v in fields.items() if k in KEPT}
        rows.append((when, interval, row))
    return rows


# A few days at a time: session-records.py seals in date order, so the files a run reads
# are the ones the run before it read, and a month of them held at once does not fit.
@functools.lru_cache(maxsize=4)
def read_file(path, mtime):
    """(cpus, rows) for one daily file. Cached on its mtime, so a file still being written
    is read again."""
    try:
        data = subprocess.run(
            ["sadf", "-d", "-U", path, "--", *ACTIVITIES],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=120,
        )
        head = subprocess.run(
            ["sadf", "-H", path], capture_output=True, text=True, errors="replace", timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None, ()
    # Whatever the exit status: a file sadc is still appending to can end in a record it has
    # not finished writing, and every whole record before that one is still good.
    found = re.search(r"\((\d+) CPU\)", head.stdout)
    return (int(found.group(1)) if found else None), tuple(parse(data.stdout))


def summarise(where, start, end, root=None):
    """The window's summary, or None. Nothing here raises: a record seals without it."""
    if not where or start is None or end is None or not os.path.isdir(where):
        return None
    rows, cpus = [], None
    for path in files_for(where, start, end):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        found, parsed = read_file(path, mtime)
        cpus = found or cpus
        rows.extend(parsed)
    return summary(rows, start, end, cpus, root, page_kb())


# --------------------------------------------------------------------------
# The arithmetic
# --------------------------------------------------------------------------


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def column(rows, name):
    return [v for v in (number(row.get(name)) for row in rows) if v is not None]


def mean_p95(values):
    """Mean and 95th percentile by nearest rank. Not the max: at 5 s a max is one sample,
    and %util read 11.7 at p95 against 95.7 at max.  see docs/monitor.md#the-machine-a-run-ran-on"""
    if not values:
        return None, None
    ordered = sorted(values)
    return (
        round(sum(values) / len(values), 2),
        round(ordered[math.ceil(0.95 * len(ordered)) - 1], 2),
    )


def summary(rows, start, end, cpus=None, root=None, page=4):
    inside = sorted((r for r in rows if start <= r[0] <= end), key=lambda r: r[0])
    of = [row for _when, _interval, row in inside]
    cpu = [row for row in of if "%idle" in row]
    if not cpu:
        return None

    out = {
        "interval": inside[0][1],
        "samples": len(cpu),
        "cpus": cpus,
        "mem_mb": None,
    }

    def pair(name, values):
        out[name + "_mean"], out[name + "_p95"] = mean_p95(values)

    pair("cpu_busy", [100 - v for v in column(cpu, "%idle")])
    pair("load1", column(of, "ldavg-1"))
    pair("steal", column(cpu, "%steal"))
    pair("iowait", column(cpu, "%iowait"))
    pair("psi_cpu", column(of, "%scpu"))
    pair("psi_io", column(of, "%fio"))
    pair("psi_mem", column(of, "%fmem"))

    memory = [row for row in of if "kbavail" in row]
    avail = column(memory, "kbavail")
    out["avail_min_mb"] = round(min(avail) / 1024) if avail else None
    if memory:
        used, share = number(memory[-1].get("kbmemused")), number(memory[-1].get("%memused"))
        if used and share:
            out["mem_mb"] = round(used * 100 / share / 1024)

    # The pages moved and not kbswpused end minus start: a burst swapped back in leaves no delta.
    paging = [(interval, row) for _when, interval, row in inside if "pswpout/s" in row]
    for name, field in (("swap_in_mb", "pswpin/s"), ("swap_out_mb", "pswpout/s")):
        moved = sum((number(row.get(field)) or 0) * interval for interval, row in paging)
        out[name] = round(moved * page / 1024, 1) if paging else None

    out["disks"] = disks([row for row in of if "DEV" in row and "%util" in row])
    out["filesystem"] = filesystem([row for row in of if "MOUNTPOINT" in row], root)
    return out


def disks(rows):
    """Whole devices that did I/O in the window. XDISK reports partitions beside their disk,
    and `sda1` summed with `sda` counts the same I/O twice."""
    devices = {}
    for row in rows:
        devices.setdefault(row["DEV"], []).append(row)
    out = {}
    for name in sorted(devices):
        partition = any(
            other != name and re.fullmatch(re.escape(other) + r"p?\d+", name) for other in devices
        )
        if partition or NOT_DISKS.fullmatch(name):
            continue
        busy = [row for row in devices[name] if (number(row.get("tps")) or 0) > 0]
        if not busy:
            continue
        util = mean_p95(column(devices[name], "%util"))
        # Only while it had I/O: an idle interval reports an await of 0 ms.
        wait = mean_p95(column(busy, "await"))
        out[name] = {
            "util_mean": util[0],
            "util_p95": util[1],
            "await_mean": wait[0],
            "await_p95": wait[1],
        }
    return out


def filesystem(rows, root):
    """The filesystem holding Docker's root dir — the images and the agent's volume."""
    if not rows or not root:
        return None
    holding = {
        row["MOUNTPOINT"]
        for row in rows
        if root == row["MOUNTPOINT"] or root.startswith(row["MOUNTPOINT"].rstrip("/") + "/")
    }
    if not holding:
        return None
    mount = max(holding, key=len)
    mine = [row for row in rows if row["MOUNTPOINT"] == mount]
    free, used = column(mine, "MBfsfree"), column(mine, "MBfsused")
    if not free or not used:
        return None
    return {
        "mount": mount,
        "size_mb": round(free[0] + used[0]),
        "free_start_mb": round(free[0]),
        "free_min_mb": round(min(free)),
    }


# --------------------------------------------------------------------------
# --selftest
# --------------------------------------------------------------------------

# Real lines from the VPS on 2026-09-10, three 5 s samples, with pswpout and the third
# sample's disk and filesystem edited so each rule below has something to catch.
T0 = 1789035923
FIXTURE = """\
# hostname;interval;timestamp;CPU;%user;%nice;%system;%iowait;%steal;%idle
h;5;{0};-1;29.01;0.00;21.30;38.13;0.20;11.36
h;5;{1};-1;13.21;0.00;3.25;0.41;0.00;83.13
h;5;{2};-1;8.70;0.00;4.05;0.61;0.00;86.64
# hostname;interval;timestamp;pswpin/s;pswpout/s
h;5;{0};1.40;0.00
h;5;{1};0.00;256.00
h;5;{2};0.00;0.00
# hostname;interval;timestamp;kbmemfree;kbavail;kbmemused;%memused;kbbuffers;kbcached;kbcommit;%commit;kbactive;kbinact;kbdirty
h;5;{0};275920;1431252;342948;17.07;14592;1252856;1920872;46.78;614372;931704;656
h;5;{1};256488;1413512;360688;17.95;15080;1254060;1794856;43.71;621420;933232;720
h;5;{2};243292;1407080;367120;18.27;15112;1260792;1794856;43.71;626836;939616;944
# hostname;interval;timestamp;runq-sz;plist-sz;ldavg-1;ldavg-5;ldavg-15;blocked
h;5;{0};2;242;1.02;0.38;0.44;1
h;5;{1};0;241;0.94;0.37;0.44;0
h;5;{2};0;241;0.86;0.37;0.44;0
# hostname;interval;timestamp;DEV;tps;rkB/s;wkB/s;dkB/s;areq-sz;aqu-sz;await;%util
h;5;{0};loop0;0.00;0.00;0.00;0.00;0.00;0.00;0.00;0.00
h;5;{0};sda;417.80;44576.00;523.20;1131060.00;2815.12;21.85;52.28;54.68
h;5;{0};sda1;417.80;44576.00;523.20;1131060.00;2815.12;21.85;52.28;54.68
h;5;{0};sr0;0.00;0.00;0.00;0.00;0.00;0.00;0.00;0.00
h;5;{1};loop0;0.00;0.00;0.00;0.00;0.00;0.00;0.00;0.00
h;5;{1};sda;12.60;323.20;0.00;0.00;25.65;0.03;2.62;1.60
h;5;{1};sda1;12.60;323.20;0.00;0.00;25.65;0.03;2.62;1.60
h;5;{1};sr0;0.00;0.00;0.00;0.00;0.00;0.00;0.00;0.00
h;5;{2};loop0;0.00;0.00;0.00;0.00;0.00;0.00;0.00;0.00
h;5;{2};sda;0.00;0.00;0.00;0.00;0.00;0.00;0.00;0.00
h;5;{2};sda1;0.00;0.00;0.00;0.00;0.00;0.00;0.00;0.00
h;5;{2};sr0;0.00;0.00;0.00;0.00;0.00;0.00;0.00;0.00
# hostname;interval;timestamp;MOUNTPOINT;MBfsfree;MBfsused;%fsused;%ufsused;Ifree;Iused;%Iused
h;5;{0};/;7014;11673;62.47;62.55;2159571;223789;9.39
h;5;{0};/boot;839;150;15.16;21.96;64886;650;0.99
h;5;{1};/;7000;11687;62.54;62.62;2159571;223789;9.39
h;5;{1};/boot;839;150;15.16;21.96;64886;650;0.99
h;5;{2};/;7010;11677;62.49;62.57;2159571;223789;9.39
h;5;{2};/boot;839;150;15.16;21.96;64886;650;0.99
# hostname;interval;timestamp;%scpu-10;%scpu-60;%scpu-300;%scpu
h;5;{0};15.25;5.85;1.92;25.81
h;5;{1};14.55;6.75;2.20;8.85
h;5;{2};11.91;6.73;2.25;6.30
# hostname;interval;timestamp;%sio-10;%sio-60;%sio-300;%sio;%fio-10;%fio-60;%fio-300;%fio
h;5;{0};33.69;12.39;3.02;54.85;26.44;9.78;2.37;38.63
h;5;{1};22.81;12.28;3.20;1.66;16.09;9.25;2.41;0.47
h;5;{2};15.44;11.52;3.16;0.80;10.94;8.69;2.38;0.57
# hostname;interval;timestamp;%smem-10;%smem-60;%smem-300;%smem;%fmem-10;%fmem-60;%fmem-300;%fmem
h;5;{0};2.91;1.05;0.25;4.56;2.30;0.80;0.19;4.08
h;5;{1};1.60;0.95;0.24;0.00;1.26;0.73;0.18;0.00
h;5;{2};1.07;0.89;0.24;0.00;0.84;0.68;0.18;0.00
"""


def selftest():
    failures, ran = [], []

    def check(name, got, want):
        ran.append(name)
        if got != want:
            failures.append("%s: got %r, wanted %r" % (name, got, want))

    def at(t0):
        return parse(FIXTURE.format(t0, t0 + 5, t0 + 10))

    rows = at(T0)
    whole = summary(rows, T0, T0 + 10, cpus=1, root="/var/lib/docker", page=4)
    assert whole is not None
    check("every sample in the window", whole["samples"], 3)
    check("the interval is the sampler's", whole["interval"], 5)
    check(
        "busy is what idle is not", (whole["cpu_busy_mean"], whole["cpu_busy_p95"]), (39.62, 88.64)
    )
    check("iowait", (whole["iowait_mean"], whole["iowait_p95"]), (13.05, 38.13))
    check("steal", (whole["steal_mean"], whole["steal_p95"]), (0.07, 0.2))
    check("load", (whole["load1_mean"], whole["load1_p95"]), (0.94, 1.02))
    check("psi cpu is some", (whole["psi_cpu_mean"], whole["psi_cpu_p95"]), (13.65, 25.81))
    check("psi io is full", (whole["psi_io_mean"], whole["psi_io_p95"]), (13.22, 38.63))
    check("psi mem is full", (whole["psi_mem_mean"], whole["psi_mem_p95"]), (1.36, 4.08))
    check("memory free is the lowest", whole["avail_min_mb"], 1374)
    check("memory total is derived from used and its share", whole["mem_mb"], 1962)
    check("pages moved are counted in MB", (whole["swap_in_mb"], whole["swap_out_mb"]), (0.0, 5.0))
    check("the cpu count is passed through", whole["cpus"], 1)

    check("a partition, a loop and the ISO drive are not disks", sorted(whole["disks"]), ["sda"])
    check(
        "await is taken only while the disk had I/O",
        (whole["disks"]["sda"]["await_mean"], whole["disks"]["sda"]["await_p95"]),
        (27.45, 52.28),
    )
    check(
        "util is taken over every sample",
        (whole["disks"]["sda"]["util_mean"], whole["disks"]["sda"]["util_p95"]),
        (18.76, 54.68),
    )
    check(
        "the filesystem holding docker, from its first sample and its lowest",
        whole["filesystem"],
        {"mount": "/", "size_mb": 18687, "free_start_mb": 7014, "free_min_mb": 7000},
    )

    check("the window's edges are inclusive", summary(rows, T0 + 5, T0 + 10)["samples"], 2)
    check("no sample in the window is None", summary(rows, T0 + 11, T0 + 99), None)
    month_ago = at(T0 - 30 * 86400)
    check(
        "a file of the same name a month old contributes nothing",
        summary(month_ago, T0, T0 + 10),
        None,
    )
    check(
        "rows from two days are one window",
        summary(month_ago + rows, T0 - 30 * 86400, T0 + 10)["samples"],
        6,
    )

    bare = parse("\n".join(line for line in FIXTURE.format(T0, T0 + 5, T0 + 10).splitlines()[:24]))
    older = summary(bare, T0, T0 + 10, root="/var/lib/docker")
    assert older is not None
    check("a file without XDISK has no filesystem", older["filesystem"], None)
    check(
        "nor PSI when it was not collected",
        (older["psi_io_mean"], older["psi_io_p95"]),
        (None, None),
    )
    check("no docker answer is no filesystem", summary(rows, T0, T0 + 10)["filesystem"], None)

    mounts = [
        {"MOUNTPOINT": "/", "MBfsfree": "10", "MBfsused": "90"},
        {"MOUNTPOINT": "/boot", "MBfsfree": "1", "MBfsused": "1"},
        {"MOUNTPOINT": "/var", "MBfsfree": "5", "MBfsused": "5"},
    ]
    check("the longest mount point wins", filesystem(mounts, "/var/lib/docker")["mount"], "/var")
    check("a prefix is a path, not a string", filesystem(mounts, "/bootstrap/docker")["mount"], "/")
    check("a device named like a partition of nothing stays", sorted(disks([
        {"DEV": "nvme0n1", "tps": "1", "%util": "1", "await": "1"},
        {"DEV": "nvme0n1p1", "tps": "1", "%util": "1", "await": "1"},
    ])), ["nvme0n1"])  # fmt: skip

    check("p95 by nearest rank", mean_p95([float(n) for n in range(1, 21)]), (10.5, 19.0))
    check("an empty column is no figure", mean_p95([]), (None, None))

    os.environ["TZ"] = "Europe/Zurich"
    time.tzset()
    with tempfile.TemporaryDirectory() as where:
        for name in ("sa09", "sa10", "sa11"):
            open(os.path.join(where, name), "w").close()
        before = datetime.datetime(2026, 9, 9, 23, 50).timestamp()
        after = datetime.datetime(2026, 9, 10, 0, 10).timestamp()
        check(
            "a window across midnight reads both days",
            [os.path.basename(p) for p in files_for(where, before, after)],
            ["sa09", "sa10"],
        )
        check(
            "a missing directory is None", summarise(os.path.join(where, "no"), before, after), None
        )

    if failures:
        print("sysstat --selftest FAILED (%d of %d)" % (len(failures), len(ran)))
        for line in failures:
            print("  " + line)
        return 1
    print("sysstat --selftest ok (%d cases)" % len(ran))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("start", nargs="?", type=int, help="epoch seconds")
    parser.add_argument("end", nargs="?", type=int, help="epoch seconds")
    parser.add_argument("--directory", default=directory(), help="where the saDD files are")
    parser.add_argument("--docker-root", help="the path whose filesystem is reported")
    parser.add_argument("--selftest", action="store_true", help="prove the arithmetic and stop")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if args.start is None or args.end is None:
        parser.error("START and END, or --selftest")
    root = args.docker_root or docker_root()
    print(json.dumps(summarise(args.directory, args.start, args.end, root), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
