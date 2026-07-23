"""Daily ops digest posted to Slack at 21:00 Europe/Berlin (systemd timer).

Alerting comes first because it qualifies everything below it: alertmanager reads its
config only at start, so a bad config crash-loops it and silently swallows every page
while this report keeps arriving as if all were well (that failure mode ran for six
weeks). The section states whether delivery works and lists what Prometheus is firing.

Errors are the core: last-24h backend-origin errors by type/env, split into new vs
recurring vs quiet-since-yesterday. "Quiet" deliberately does NOT claim "resolved" -
an error that did not recur may simply not have been exercised. The log-volume line
doubles as pipeline liveness: the paging rules use noDataState=OK, so a dead logging
pipeline is otherwise indistinguishable from a healthy quiet day.

Server section reports capacity signals only (CPU avg/peak, mem peak, disk now) and
raises flags when a threshold suggests an upgrade conversation. Activity is a single
pipeline proxy (completed sensor jobs / published results), not product analytics.

Stdlib only: runs as a one-shot python:alpine container on the monitoring network.
"""

import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import date

LOKI = os.environ.get("LOKI_URL", "http://loki:3100")
PROM = os.environ.get("PROM_URL", "http://prometheus:9090")
WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]

ERRORS_24H = (
    'sum by (errorType, env) (count_over_time({env=~"staging|production", source!="flutter"}'
    ' | json level, errorType | level =~ "error|50" | errorType != "" [24h]%s))'
)
VOLUME_24H = 'sum by (env) (count_over_time({env=~"staging|production"}[24h]))'

CPU_AVG = '100 * (1 - avg by (env, instance) (rate(node_cpu_seconds_total{mode="idle"}[24h])))'
CPU_PEAK = (
    "max_over_time((100 * (1 - avg by (env, instance)"
    ' (rate(node_cpu_seconds_total{mode="idle"}[5m]))))[24h:5m])'
)
MEM_PEAK = (
    "100 * max_over_time((1 - node_memory_MemAvailable_bytes"
    " / node_memory_MemTotal_bytes)[24h:5m])"
)
DISK_NOW = (
    '100 * (1 - node_filesystem_avail_bytes{fstype!="tmpfs",mountpoint="/"}'
    ' / node_filesystem_size_bytes{fstype!="tmpfs",mountpoint="/"})'
)
DISK_IN_30D = (
    'predict_linear(node_filesystem_avail_bytes{fstype!="tmpfs",mountpoint="/"}[7d],'
    " 30 * 86400)"
)
# Alertmanager and Loki cannot page about their own death - a crash-looping alertmanager
# swallows every alert and reads exactly like a quiet week. This report is the only
# out-of-band channel (one-shot container, straight to Slack), so it carries their health.
STACK_UP = 'up{job="monitoring_stack"}'
# Alerts Prometheus is firing right now. If alerting delivery is broken these are the
# pages that were never sent; if it is healthy they are already in the channel and this
# line just restates the current state.
FIRING = 'sum by (alertname, env) (ALERTS{alertstate="firing", severity="critical"})'

JOBS_DONE = (
    'increase(redis_key_size{job="redis_bullmq",'
    'key="bull:sensor_processing_jobs:completed"}[24h])'
)
RESULTS_DONE = (
    'increase(redis_key_size{job="redis_bullmq",key="bull:trip_results:completed"}[24h])'
)


def _get(url):
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def loki_instant(query):
    url = f"{LOKI}/loki/api/v1/query?" + urllib.parse.urlencode({"query": query})
    return _get(url)["data"]["result"]


def prom_instant(query):
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    return _get(url)["data"]["result"]


def as_map(result, *label_keys):
    out = {}
    for series in result:
        key = tuple(series["metric"].get(k, "?") for k in label_keys)
        out[key] = float(series["value"][1])
    return out


def section_errors(lines):
    try:
        today = as_map(loki_instant(ERRORS_24H % ""), "env", "errorType")
        yesterday = as_map(loki_instant(ERRORS_24H % " offset 24h"), "env", "errorType")
    except Exception as exc:
        lines.append(f":warning: error queries failed: {exc}")
        return
    if not today:
        lines.append(":white_check_mark: no backend-origin errors in the last 24h")
    for (env, etype), count in sorted(today.items(), key=lambda kv: -kv[1]):
        tag = "recurring" if (env, etype) in yesterday else "NEW"
        lines.append(f":red_circle: {env} `{etype}`: {count:.0f} ({tag})")
    quiet = {k: v for k, v in yesterday.items() if k not in today}
    for (env, etype), count in sorted(quiet.items(), key=lambda kv: -kv[1]):
        lines.append(f":large_yellow_circle: {env} `{etype}`: quiet for 24h (was {count:.0f})")

    try:
        volume = as_map(loki_instant(VOLUME_24H), "env")
    except Exception as exc:
        lines.append(f":warning: volume query failed: {exc}")
        return
    vol_text = ", ".join(f"{env} {v:,.0f} lines" for (env,), v in sorted(volume.items()))
    lines.append(f"log pipeline: {vol_text or 'NO DATA'}")
    for (env,), v in volume.items():
        if v == 0:
            lines.append(f":warning: {env} ingested 0 log lines - the pipeline may be dead")
    if not volume:
        lines.append(":warning: no env ingested any logs - the pipeline may be dead")


def section_servers(lines):
    try:
        cpu_avg = as_map(prom_instant(CPU_AVG), "env", "instance")
        cpu_peak = as_map(prom_instant(CPU_PEAK), "env", "instance")
        mem_peak = as_map(prom_instant(MEM_PEAK), "env", "instance")
        disk_now = as_map(prom_instant(DISK_NOW), "env", "instance")
        disk_30d = as_map(prom_instant(DISK_IN_30D), "env", "instance")
    except Exception as exc:
        lines.append(f":warning: server queries failed: {exc}")
        return
    flags = []
    for key in sorted(cpu_avg):
        env, instance = key
        host = f"{env} ({instance.split(':')[0]})"
        avg, peak = cpu_avg.get(key, 0), cpu_peak.get(key, 0)
        mem, disk = mem_peak.get(key, 0), disk_now.get(key, 0)
        lines.append(
            f"{host}: cpu avg {avg:.0f}% peak {peak:.0f}% | mem peak {mem:.0f}%"
            f" | disk {disk:.0f}%"
        )
        if avg > 60:
            flags.append(f"{host}: sustained CPU {avg:.0f}% - consider more cores")
        if mem > 85:
            flags.append(f"{host}: memory peaked at {mem:.0f}% - consider more RAM")
        if disk > 80:
            flags.append(f"{host}: disk at {disk:.0f}%")
        if disk_30d.get(key, 1) < 0:
            flags.append(f"{host}: disk trending FULL within 30 days")
    for flag in flags:
        lines.append(f":warning: {flag}")
    if cpu_avg and not flags:
        lines.append(":white_check_mark: no capacity flags")


def section_alerting(lines):
    try:
        stack = prom_instant(STACK_UP)
        firing = as_map(prom_instant(FIRING), "env", "alertname")
    except Exception as exc:
        lines.append(f":warning: alerting queries failed: {exc}")
        return
    down = [s["metric"].get("instance", "?") for s in stack if float(s["value"][1]) == 0]
    if down:
        lines.append(
            f":rotating_light: DELIVERY BROKEN - {', '.join(sorted(down))} down."
            " Alerts below were never sent to Slack."
        )
    elif not stack:
        lines.append(":warning: monitoring stack health unknown - no `up` series")
    else:
        lines.append(":white_check_mark: alertmanager and loki up")
    for (env, alertname), _ in sorted(firing.items()):
        lines.append(f":rotating_light: firing now: {env} `{alertname}`")
    if not firing:
        lines.append("no alerts firing")


def section_activity(lines):
    try:
        jobs = as_map(prom_instant(JOBS_DONE), "env")
        results = as_map(prom_instant(RESULTS_DONE), "env")
    except Exception as exc:
        lines.append(f":warning: activity queries failed: {exc}")
        return
    for (env,) in sorted(set(jobs) | set(results)):
        lines.append(
            f"{env}: {jobs.get((env,), 0):.0f} sensor batches processed,"
            f" {results.get((env,), 0):.0f} trip results published"
        )
    if not jobs and not results:
        lines.append("no pipeline activity recorded")


def main():
    lines = [f"*Hero2 daily report - {date.today().isoformat()}* (last 24h)", "", "*Alerting*"]
    section_alerting(lines)
    lines += ["", "*Errors*"]
    section_errors(lines)
    lines += ["", "*Servers*"]
    section_servers(lines)
    lines += ["", "*Pipeline activity*"]
    section_activity(lines)

    payload = json.dumps({"text": "\n".join(lines)}).encode()
    req = urllib.request.Request(
        WEBHOOK, data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode()
    if body != "ok":
        print(f"slack webhook answered: {body}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
