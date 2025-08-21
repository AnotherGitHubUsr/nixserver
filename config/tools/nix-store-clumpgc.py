#!/usr/bin/env python3
# nix-store-clumpgc.py
# Automatic, non-interactive NixOS system generation retention + clumping GC.
# - Keeps all generations for 3d.
# - 3–10d: daily keep, and for "productive stretches" (mean inter-arrival <= 12h across >=36h span),
#          keep {first, +24h, last}.
# - >10d: greedy "integral" clumping using a kernel-smoothed activity score; enforce 5–10d windows.
# - >3m: one per month (last generation of month).
# - Safety: keep current booted, previous booted, and any explicitly pinned in state.
#
# Activity score per generation g_i at time t_i:
#   score_i = 0.1 * rebuild_event(=1) + 0.5 * norm(git_lines_delta) + 0.4 * norm(store_path_delta)
# (closure bytes intentionally excluded)
#
# State file (JSON): tracks known generations, keep/delete decisions, and pinned flags.
# Default state path: /var/lib/nix-retain/state.json
#
# Usage:
#   sudo ./nix-store-clumpgc.py --apply        # perform deletions
#   sudo ./nix-store-clumpgc.py --dry-run      # plan only (default)
#   sudo ./nix-store-clumpgc.py --state /path  # override state file path
#
# Requires: nix, nix-env, nix-store, git, coreutils, python3.
# Runs on host; does not need network; non-interactive.
#
# NOTE: This script avoids deleting current/previous booted generations.
#       Deletion is done via `nix-env -p /nix/var/nix/profiles/system --delete-generations`.
#
import argparse, subprocess, sys, os, re, json, math, shutil
from datetime import datetime, timedelta, timezone
from collections import defaultdict

STATE_DEFAULT = "/var/lib/nix-retain/state.json"
PROFILE = "/nix/var/nix/profiles/system"
TZ = timezone.utc  # we operate in UTC to avoid DST surprises

# ---- Helpers ----

def run(cmd):
    return subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def list_generations():
    # Output format (typical):
    # 123  2025-08-12 12:34:56
    r = run(["nix-env", "-p", PROFILE, "--list-generations"])
    gens = []
    for line in r.stdout.splitlines():
        m = re.match(r"^\s*(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})", line)
        if m:
            gen_id = int(m.group(1))
            ts = datetime.fromisoformat(f"{m.group(2)} {m.group(3)}").replace(tzinfo=TZ)
            gens.append((gen_id, ts))
    gens.sort(key=lambda x: x[1])
    return gens

def booted_generations():
    # Determine current booted and previous booted from /run/current-system symlink and journal
    current = None
    try:
        link = os.path.realpath("/run/current-system")
        m = re.search(r"system-(\d+)-link", link)
        if m: current = int(m.group(1))
    except Exception:
        pass
    # Previous booted guessed: current-1 if exists
    prev = None
    if current is not None:
        prev = max(current-1, 1)
    return current, prev

def gen_path(gen_id):
    return f"/nix/var/nix/profiles/system-{gen_id}-link"

def closure_paths(gen_id):
    p = gen_path(gen_id)
    if not os.path.exists(p):
        return set()
    r = run(["nix-store", "-qR", os.path.realpath(p)])
    return set(filter(None, r.stdout.splitlines()))

def git_lines_delta(repo_dir, older_ts, newer_ts):
    # Heuristic: diff between commits nearest to the two generation times.
    # If no git repo found, return 0.
    if not os.path.isdir(os.path.join(repo_dir, ".git")):
        return 0
    def commit_at(ts):
        r = run(["git", "-C", repo_dir, "rev-list", "-1", f'--before={ts.isoformat()}','HEAD'])
        c = r.stdout.strip()
        return c if c else None
    c_old = commit_at(older_ts)
    c_new = commit_at(newer_ts)
    if not c_old or not c_new or c_old == c_new:
        return 0
    r = run(["git", "-C", repo_dir, "diff", "--numstat", c_old, c_new])
    adds = dels = 0
    for line in r.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3 and parts[0].isdigit() and parts[1].isdigit():
            adds += int(parts[0]); dels += int(parts[1])
    return adds + dels

def normalize(values):
    # robust percentile scaling to [0,1]
    arr = list(values)
    if not arr: return {}
    v = sorted(arr)
    def pct(x):
        if len(v) == 1: return 0.0
        # 5th and 95th percentiles
        p5 = v[int(0.05*(len(v)-1))]
        p95 = v[int(0.95*(len(v)-1))]
        if p95 == p5:
            return 0.0 if x <= p5 else 1.0
        return max(0.0, min(1.0, (x - p5) / (p95 - p5)))
    return {x: pct(x) for x in values}

def kernel_smooth(points, sigma_hours=12):
    # points: list of (ts(datetime), score)
    if not points: return []
    # build hourly grid
    start = points[0][0].replace(minute=0, second=0, microsecond=0)
    end = points[-1][0].replace(minute=0, second=0, microsecond=0)
    hours = int((end - start).total_seconds() // 3600) + 1
    grid = []
    s2 = 2*(sigma_hours**2)
    for i in range(hours):
        t = start + timedelta(hours=i)
        val = 0.0
        for (pt, sc) in points:
            dh = abs((pt - t).total_seconds())/3600.0
            val += sc * math.exp(-(dh*dh)/s2)
        grid.append((t, val))
    return grid

def select_integral_windows(grid, min_days=5, max_days=10, min_area=0.0):
    # greedy non-overlapping windows maximizing integral
    selected = []
    used = [False]*len(grid)
    HMIN = int(min_days*24); HMAX = int(max_days*24)
    # precompute prefix sums
    vals = [v for (_,v) in grid]
    pref = [0.0]
    for v in vals:
        pref.append(pref[-1] + v)
    def area(i,j):  # [i, j)
        return pref[j] - pref[i]
    # masks with guard bands are handled by marking used
    def first_unused():
        for i,f in enumerate(used):
            if not f: return i
        return None
    i0 = first_unused()
    while i0 is not None:
        best = None
        for L in range(HMIN, HMAX+1):
            j = i0 + L
            if j > len(grid): break
            a = area(i0, j)
            if a >= min_area:
                if not best or a > best[2]:
                    best = (i0,j,a)
        if not best:
            used[i0] = True
            i0 = first_unused()
            continue
        (i,j,a) = best
        selected.append((i,j))
        # mask with guard +/- 12h
        for k in range(max(0,i-12), min(len(grid), j+12)):
            used[k] = True
        i0 = first_unused()
    return [(grid[i][0], grid[j-1][0]) for (i,j) in selected]

def month_key(dt):
    return dt.year*100 + dt.month

def ensure_dir(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)

def load_state(path):
    if os.path.exists(path):
        with open(path) as f: return json.load(f)
    return {"gens":{}, "kept":{}, "deleted":[], "pinned":{}, "meta":{}}

def save_state(path, data):
    ensure_dir(path)
    tmp = path + ".new"
    with open(tmp, "w") as f: json.dump(data, f, indent=2, sort_keys=True)
    os.replace(tmp, path)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="perform deletions")
    ap.add_argument("--dry-run", action="store_true", help="plan only (default)")
    ap.add_argument("--state", default=STATE_DEFAULT)
    ap.add_argument("--repo", default="/etc/nixos", help="git repo for diff stats")
    ap.add_argument("--sigma-hours", type=int, default=12)
    args = ap.parse_args()
    if not args.apply: args.dry_run = True

    gens = list_generations()
    if not gens:
        print("No generations found."); return 0

    cur, prev = booted_generations()
    state = load_state(args.state)

    # Build features
    # closure path deltas
    path_sets = {}
    for gid, _ in gens:
        try:
            path_sets[gid] = closure_paths(gid)
        except Exception:
            path_sets[gid] = set()
    lines_delta = {}
    paths_delta = {}
    score = {}
    for i in range(1, len(gens)):
        gid_p, ts_p = gens[i-1]
        gid, ts = gens[i]
        # git lines
        ld = git_lines_delta(args.repo, ts_p, ts)
        lines_delta[gid] = ld
        # store path delta
        added = len(path_sets.get(gid, set()) - path_sets.get(gid_p, set()))
        removed = len(path_sets.get(gid_p, set()) - path_sets.get(gid, set()))
        paths_delta[gid] = added + removed

    # normalize features over observed deltas (skip first gen)
    norm_lines = normalize(list(lines_delta.values()))
    norm_paths = normalize(list(paths_delta.values()))

    for i, (gid, ts) in enumerate(gens):
        base = 0.1 # rebuild event weight
        if i == 0:
            sc = base
        else:
            sc = base + 0.5*norm_lines.get(lines_delta.get(gid,0), 0.0) + 0.4*norm_paths.get(paths_delta.get(gid,0), 0.0)
        score[gid] = sc

    # Kernel smoother grid
    points = [(ts, score[gid]) for (gid, ts) in gens]
    grid = kernel_smooth(points, sigma_hours=args.sigma_hours)

    # Partition by age
    now = gens[-1][1]
    keep = set()
    reasons = {}

    # Always keep current/previous booted if present
    if cur: keep.add(cur); reasons[cur] = "booted-current"
    if prev: keep.add(prev); reasons[prev] = "booted-previous"

    # 0–3 days: keep everything
    for gid, ts in gens:
        if (now - ts) <= timedelta(days=3):
            keep.add(gid); reasons[gid] = "<=3d"

    # 3–10 days: daily keep + productive stretches
    # daily: pick last generation per calendar day
    daily = {}
    for gid, ts in gens:
        if timedelta(days=3) < (now - ts) <= timedelta(days=10):
            k = ts.date()
            if k not in daily or ts > daily[k][1]:
                daily[k] = (gid, ts)
    for gid, ts in daily.values():
        if gid not in keep:
            keep.add(gid); reasons[gid] = "daily"

    # productive stretches: mean inter-arrival <= 12h over >=36h span
    # build list in the 3–10d range
    subset = [(gid, ts) for (gid, ts) in gens if timedelta(days=3) < (now - ts) <= timedelta(days=10)]
    if len(subset) >= 2:
        i = 0
        while i < len(subset)-1:
            j = i+1
            spans = []
            while j < len(subset):
                span = (subset[j][1] - subset[i][1])
                if span >= timedelta(hours=36):
                    # compute mean inter-arrival over [i..j]
                    total = (subset[j][1] - subset[i][1]).total_seconds()
                    intervals = j - i
                    mean = total / intervals if intervals>0 else 1e9
                    if mean <= 12*3600:
                        # keep first, +24h (closest), last
                        first_gid, first_ts = subset[i]
                        last_gid, last_ts = subset[j]
                        # find +24h
                        target = first_ts + timedelta(hours=24)
                        mid_gid, mid_ts, mdiff = None, None, None
                        for k in range(i, j+1):
                            gidk, tsk = subset[k]
                            diff = abs((tsk - target).total_seconds())
                            if mdiff is None or diff < mdiff:
                                mid_gid, mid_ts, mdiff = gidk, tsk, diff
                        for gg, rr in [(first_gid, "prod-first"),
                                       (mid_gid, "prod-+24h"),
                                       (last_gid, "prod-last")]:
                            if gg not in keep:
                                keep.add(gg); reasons[gg] = rr
                        i = j  # jump
                        break
                j += 1
            else:
                i += 1

    # >10 days: integral clumping into 5–10d windows
    # Build windows from the smoothed grid beyond 10d ago
    cutoff = now - timedelta(days=10)
    grid_tail = [(t,v) for (t,v) in grid if t <= cutoff]
    if grid_tail:
        windows = select_integral_windows(grid_tail, min_days=5, max_days=10, min_area=0.0)
        # For each window, keep the last generation whose ts falls within the window
        for (ws, we) in windows:
            cand = [(gid, ts) for (gid, ts) in gens if ws <= ts <= we]
            if cand:
                gid_keep, ts_keep = cand[-1]
                if gid_keep not in keep:
                    keep.add(gid_keep); reasons[gid_keep] = "clump-longterm"

    # >3 months: monthly last
    months = {}
    for gid, ts in gens:
        if (now - ts) > timedelta(days=90):
            mk = month_key(ts)
            if mk not in months or ts > months[mk][1]:
                months[mk] = (gid, ts)
    for gid, ts in months.values():
        if gid not in keep:
            keep.add(gid); reasons[gid] = "monthly"

    # Persist state & decide deletions
    for gid, ts in gens:
        s = state["gens"].setdefault(str(gid), {})
        s["ts"] = ts.isoformat()
        s["score"] = score.get(gid, 0.0)
        if str(gid) in state.get("pinned", {}):
            keep.add(gid); reasons[gid] = "pinned"

    # Compile delete list
    all_ids = [gid for (gid, _) in gens]
    delete_ids = [gid for gid in all_ids if gid not in keep]

    # Avoid deleting current/previous
    if cur in delete_ids: delete_ids.remove(cur)
    if prev in delete_ids and prev is not None: delete_ids.remove(prev)

    # Record kept/deleted
    state["kept"] = {str(g): {"reason": reasons.get(g,"")} for g in sorted(keep)}
    # only append to deleted history; actual deletion done below
    plan_delete = [g for g in sorted(delete_ids)]
    print("Plan to delete generations:", plan_delete)
    print("Kept (id: reason):", {g: reasons.get(g,"") for g in sorted(keep)})

    # Save state before action
    state["meta"]["last_run"] = datetime.now(TZ).isoformat()
    save_state(args.state, state)

    if args.dry_run:
        print("[DRY-RUN] No deletions performed.")
        return 0

    if plan_delete:
        # nix-env deletion can accept a comma-separated list
        ids_str = ",".join(str(x) for x in plan_delete)
        r = run(["nix-env", "-p", PROFILE, "--delete-generations", ids_str])
        print(r.stdout)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
        # optional: trigger store GC
        run(["nix-collect-garbage"])
        run(["nix-store", "--gc"])
        # append to deleted list
        state = load_state(args.state)
        state["deleted"].extend(plan_delete)
        save_state(args.state, state)

    return 0

if __name__ == "__main__":
    sys.exit(main())
