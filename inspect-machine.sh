#!/bin/sh
set -eu

: "${SECTION:?SECTION must be set}"
: "${REPORT_PATH:?REPORT_PATH must be set}"

run() {
  printf '\n--- %s ---\n' "$*"
  if command -v "$1" >/dev/null 2>&1; then
    "$@" 2>&1 || printf 'Command failed or access denied.\n'
  else
    printf 'Command unavailable.\n'
  fi
}

terraform_runtime() {
  if command -v terraform >/dev/null 2>&1; then
    run terraform version -no-color
    return
  fi
  ancestor=$$
  attempts=0
  while [ "$ancestor" -gt 1 ] && [ "$attempts" -lt 8 ]; do
    executable=$(readlink "/proc/$ancestor/exe" 2>/dev/null || true)
    case "$executable" in
      */terraform|*/terraform-[0-9]*)
        run "/proc/$ancestor/exe" version -no-color
        return
        ;;
    esac
    if [ ! -r "/proc/$ancestor/status" ]; then
      break
    fi
    ancestor=$(awk '/^PPid:/ { print $2 }' "/proc/$ancestor/status")
    case "$ancestor" in
      ''|*[!0-9]*) break ;;
    esac
    attempts=$((attempts + 1))
  done
  printf '\nTerraform version unavailable from PATH or accessible process ancestry; consult the remote run header.\n'
}

cgroup_limits() {
  if [ ! -r /proc/self/cgroup ] || [ ! -r /proc/self/mountinfo ]; then
    printf 'Cgroup limits unavailable.\n'
    return
  fi

  memberships=$(awk '
    function decode(path) {
      gsub(/\\040/, " ", path)
      gsub(/\\011/, "\t", path)
      return path
    }
    FNR == NR {
      split($0, entry, ":")
      controllers[++count] = entry[2]
      paths[count] = entry[3]
      next
    }
    {
      split($0, sides, " - ")
      split(sides[1], mount, " ")
      split(sides[2], filesystem, " ")
      if (filesystem[1] != "cgroup" && filesystem[1] != "cgroup2") next
      root = decode(mount[4])
      point = decode(mount[5])
      for (index_entry = 1; index_entry <= count; index_entry++) {
        if (controllers[index_entry] != "" && controllers[index_entry] !~ /(^|,)(cpu|cpuset|memory|pids)(,|$)/) continue
        matches = filesystem[1] == "cgroup2" && controllers[index_entry] == ""
        split(controllers[index_entry], names, ",")
        for (name_index in names)
          if (filesystem[1] == "cgroup" && index("," filesystem[3] ",", "," names[name_index] ",")) matches = 1
        path = paths[index_entry]
        if (!matches || (root != "/" && path != root && index(path, root "/") != 1)) continue
        if (length(root) < best[index_entry]) continue
        best[index_entry] = length(root)
        suffix = root == "/" ? path : substr(path, length(root) + 1)
        resolved[index_entry] = point (suffix == "/" ? "" : suffix)
        points[index_entry] = point
        versions[index_entry] = filesystem[1] == "cgroup2" ? "v2" : "v1"
      }
    }
    END {
      for (index_entry = 1; index_entry <= count; index_entry++)
        if (resolved[index_entry] != "")
          printf "%s\t%s\t%s\t%s\n", versions[index_entry], controllers[index_entry] == "" ? "unified" : controllers[index_entry], points[index_entry], resolved[index_entry]
    }
  ' /proc/self/cgroup /proc/self/mountinfo)

  if [ -z "$memberships" ]; then
    printf 'No accessible cgroup membership could be resolved; effective limits unknown.\n'
    return
  fi

  found=0
  while IFS="$(printf '\t')" read -r version controllers mountpoint directory; do
    depth=0
    if [ ! -d "$directory" ]; then
      printf '\nCgroup %s (%s): workload directory inaccessible; limits unknown.\n' "$version" "$controllers"
      continue
    fi
    while :; do
      printf '\nCgroup %s (%s), ancestor depth %s:\n' "$version" "$controllers" "$depth"
      for metric in cpu.max cpu.cfs_quota_us cpu.cfs_period_us \
        cpuset.cpus.effective cpuset.effective_cpus cpuset.cpus \
        memory.max memory.high memory.current memory.peak memory.events \
        memory.limit_in_bytes memory.usage_in_bytes memory.max_usage_in_bytes \
        memory.failcnt memory.oom_control pids.max pids.current; do
        if [ -r "$directory/$metric" ]; then
          found=1
          printf '%s: ' "$metric"
          awk -v metric="$metric" '
            metric == "cpu.max" {
              if ($1 == "max") print "unlimited"
              else if ($2 > 0) printf "%s %s (%.3f CPU equivalents)\n", $1, $2, $1 / $2
              next
            }
            metric == "cpu.cfs_quota_us" && $1 == -1 { print "unlimited"; next }
            metric == "pids.max" && $1 == "max" { print "unlimited"; next }
            metric ~ /^memory\.(max|high|limit_in_bytes)$/ {
              if ($1 == "max" || $1 + 0 >= 9e18) print "unlimited"
              else printf "%s bytes (%.2f GiB)\n", $1, $1 / 1073741824
              next
            }
            { print }
          ' "$directory/$metric"
        fi
      done
      if [ -r "$directory/cpu.cfs_quota_us" ] && [ -r "$directory/cpu.cfs_period_us" ]; then
        quota=$(cat "$directory/cpu.cfs_quota_us")
        period=$(cat "$directory/cpu.cfs_period_us")
        awk -v quota="$quota" -v period="$period" 'BEGIN {
          if (quota >= 0 && period > 0) printf "CPU quota: %.3f CPU equivalents\n", quota / period
        }'
      fi
      [ "$directory" = "$mountpoint" ] && break
      directory=$(dirname "$directory")
      depth=$((depth + 1))
    done
  done <<EOF
$memberships
EOF
  if [ "$found" = 0 ]; then
    printf 'No readable workload/ancestor metrics; effective limits unknown.\n'
  fi
  printf '\nEffective capacity is constrained by affinity and the tightest visible ancestor limits. Hidden ancestors and scheduler limits cannot be inferred.\n'
}

mkdir -p "$(dirname "$REPORT_PATH")"
os=$(uname -s)

{
  printf 'Collected at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'Runner-visible observations, not guaranteed allocations or equivalent performance.\n'
  case "$SECTION" in
    cpu)
      run getconf _NPROCESSORS_ONLN
      if [ "$os" = Darwin ]; then
        run sysctl machdep.cpu.brand_string hw.ncpu hw.physicalcpu hw.logicalcpu
      else
        if command -v lscpu >/dev/null 2>&1; then
          lscpu 2>&1 | awk '/^(Architecture|CPU\(s\)|On-line CPU|Vendor ID|Model name|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|Hypervisor vendor|Virtualization type):/'
        else
          printf 'CPU model/topology summary unavailable.\n'
        fi
        if [ -r "/proc/$$/status" ]; then
          printf '\n--- Collector CPU affinity ---\n'
          awk '/^Cpus_allowed_list:/ { print; found = 1 } END {
            if (!found) print "Affinity unavailable: process status omits Cpus_allowed_list."
          }' "/proc/$$/status"
        else
          printf 'Process CPU affinity unavailable.\n'
        fi
      fi
      ;;
    memory)
      if [ "$os" = Darwin ]; then
        run sysctl hw.memsize vm.swapusage
        run vm_stat
      else
        run free -h
        if [ -r /proc/meminfo ]; then
          awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ { print }' /proc/meminfo
        fi
      fi
      ;;
    disk)
      for storage_path in "$PWD" "${TMPDIR:-/tmp}"; do
        printf '\n--- Storage at %s ---\n' "$storage_path"
        run df -Pk "$storage_path"
        run df -Pi "$storage_path"
        if df -Pi "$storage_path" 2>/dev/null | awk 'NR > 1 && $2 == 0 { unavailable = 1 } END { exit !unavailable }'; then
          printf 'Inode capacity unavailable: filesystem reports zero total inodes.\n'
        fi
        if df -Pk "$storage_path" 2>/dev/null | awk 'NR > 1 && $2 + 0 >= 1e15 { synthetic = 1 } END { exit !synthetic }'; then
          printf 'Synthetic/unbounded capacity reported; actual storage capacity unknown.\n'
        fi
      done
      ;;
    system)
      run uname -srm
      run id
      terraform_runtime
      if [ "$os" = Darwin ]; then
        run sw_vers
      else
        if [ -r /etc/os-release ]; then
          awk '/^(PRETTY_NAME|ID|VERSION_ID)=/' /etc/os-release
        fi
        run getconf GNU_LIBC_VERSION
      fi
      printf '\n--- Provisioner tool availability (not requirements) ---\n'
      for tool in sh bash git curl unzip python3 node aws az gcloud; do
        if command -v "$tool" >/dev/null 2>&1; then
          printf '%s: available\n' "$tool"
        else
          printf '%s: unavailable\n' "$tool"
        fi
      done
      ;;
    limits)
      printf '\n--- ulimit -a ---\n'
      ulimit -a
      cgroup_limits
      ;;
    *)
      printf 'Unknown section: %s\n' "$SECTION" >&2
      exit 1
      ;;
  esac
} >"$REPORT_PATH"