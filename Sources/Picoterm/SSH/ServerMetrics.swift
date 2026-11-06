import Foundation
import PicotermCore

// 服务器状态采集：样本解析 + 采集脚本 + 跨采样求差。
// Ported from Berth (GPL-3) — .reference/Berth/Berth/Core/SSH/ServerMetrics.swift
// 在移植基础上扩展：/sys/block 磁盘读写累计字节（DISKREAD/DISKWRITE），速率同样由 app 求差得到。

/// 一次资源采样。CPU 占用、网络与磁盘速率必须拿原始累计计数器跨两次采样求差，
/// 所以这里存裸数值，派生值统一由 `ServerMetricsReading` 计算。
struct ServerMetricsSample: Equatable, Sendable {
    /// 本地采样时刻。速率一律按本地时钟求差——服务器时钟漂移/跳变不该算进速率里
    var takenAt = Date()

    var hostname = ""
    var os = ""
    var kernel = ""
    var cpuCount = 0
    /// 1/5/15 分钟负载
    var load: [Double] = []
    var uptimeSeconds: Double?

    /// /proc/stat 的累计 jiffies（总量与空闲量），跨两次采样求差得 CPU 占用
    var cpuTotalTicks: Double?
    var cpuIdleTicks: Double?
    /// 拿不到计数器时的直接占用率（macOS 的 top 只给百分比）
    var cpuPercentDirect: Double?

    var memTotalKB: Double?
    var memAvailableKB: Double?
    var swapTotalKB: Double?
    var swapFreeKB: Double?

    /// 逐网卡累计收发字节（排除 lo 与容器虚拟网卡），跨两次采样求差得速率；
    /// 网络列要支持「指定网卡」，所以不再只给合计
    var netIfs: [NetIfSample] = []
    /// 逐盘累计读/写字节（/sys/block 顶层盘，含 dm/md 层），求差得速率；
    /// 磁盘列要支持「指定磁盘」，合计由 app 排除 dm/md 后求和防重复计数
    var diskIOs: [DiskIOSample] = []

    var processes: Int?
    /// CPU 温度（摄氏），仅在能读到 thermal zone 时有值
    var temperatureC: Double?
    var disks: [DiskUsage] = []
    /// 进程 TOP（按 CPU 降序前 5）：名称|PID|CPU%|MEM%——状态条进程列点击展示
    var topProcesses: [TopProcess] = []

    struct TopProcess: Equatable, Sendable {
        let name: String
        let pid: Int
        let cpuPercent: Double?
        let memPercent: Double?
    }

    /// 至少解析出一项有意义的数据（否则视为采集失败，别用空数据糊弄）
    var isUsable: Bool {
        memTotalKB != nil || cpuTotalTicks != nil || cpuPercentDirect != nil
            || !load.isEmpty || !disks.isEmpty
    }

    struct NetIfSample: Equatable, Sendable {
        let name: String
        let rxBytes: Double
        let txBytes: Double
    }

    struct DiskIOSample: Equatable, Sendable {
        let name: String
        let readBytes: Double
        let writeBytes: Double
    }

    struct DiskUsage: Equatable, Sendable, Identifiable {
        let mount: String
        let usedKB: Double
        let totalKB: Double
        /// 基础块设备名（分区已剥到顶层盘；LVM 为 dm-N），对齐 DISKIO 用
        let dev: String

        var id: String { mount }
        var fraction: Double {
            guard totalKB > 0 else { return 0 }
            return min(max(usedKB / totalKB, 0), 1)
        }
    }

    init() {}

    /// 解析采集脚本输出的 key=value 行。无法识别的行忽略（服务器五花八门，宁缺毋滥）。
    init(parsing text: String, takenAt: Date = Date()) {
        self.takenAt = takenAt
        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let number = Double(value)
            switch key {
            case "HOSTNAME": hostname = value
            case "OS": os = value
            case "KERNEL": kernel = value
            case "CPUS": cpuCount = Int(value) ?? 0
            case "LOAD": load = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            case "UPTIME": uptimeSeconds = number
            case "CPUTOTAL": cpuTotalTicks = number
            case "CPUIDLE": cpuIdleTicks = number
            case "CPUPCT": cpuPercentDirect = number.map { min(max($0, 0), 100) }
            case "MEMTOTAL": memTotalKB = number
            case "MEMAVAIL": memAvailableKB = number
            case "SWAPTOTAL": swapTotalKB = number
            case "SWAPFREE": swapFreeKB = number
            case "NETIF":
                // <网卡名>|<累计收字节>|<累计发字节>
                let parts = value.components(separatedBy: "|")
                guard parts.count == 3,
                      let rx = Double(parts[1]), let tx = Double(parts[2]) else { continue }
                netIfs.append(NetIfSample(name: parts[0], rxBytes: rx, txBytes: tx))
            case "DISKIO":
                // <盘名>|<累计读字节>|<累计写字节>
                let parts = value.components(separatedBy: "|")
                guard parts.count == 3,
                      let read = Double(parts[1]), let write = Double(parts[2]) else { continue }
                diskIOs.append(DiskIOSample(name: parts[0], readBytes: read, writeBytes: write))
            case "PROCS": processes = Int(value)
            case "TEMPMC": temperatureC = number.map { $0 / 1000 }
            case "TOPPROC":
                // <名称>|<PID>|<CPU%>|<MEM%>（后两项可缺席）
                let parts = value.components(separatedBy: "|")
                guard parts.count >= 2, let pid = Int(parts[1]) else { continue }
                topProcesses.append(TopProcess(
                    name: parts[0], pid: pid,
                    cpuPercent: parts.count > 2 ? Double(parts[2]) : nil,
                    memPercent: parts.count > 3 ? Double(parts[3]) : nil))
            case "DISK":
                // <挂载点>|<已用 KB>|<总量 KB>|<基础块设备名>（末列可能缺席，兼容）
                let parts = value.components(separatedBy: "|")
                guard parts.count >= 3, let used = Double(parts[1]), let total = Double(parts[2]), total > 0 else { continue }
                let dev = parts.count >= 4 ? parts[3] : ""
                disks.append(DiskUsage(mount: parts[0], usedKB: used, totalKB: total, dev: dev))
            default: continue
            }
        }
    }
}

/// 采集脚本的命名空间（脚本本身与解析结果分开：脚本要跟着服务器差异演进，样本结构不必）
enum ServerMetrics {
    /// 一次采集只跑一条脚本、只取一次快照（CPU/网络/磁盘的瞬时值由 app 跨次求差得到）。
    /// 约束：保证 exit 0、不写 stderr——否则按失败处理。
    /// Linux 走 /proc 与 /sys/block；macOS/BSD 走 sysctl/vm_stat/netstat 兜底，取不到的字段
    /// 直接不输出，UI 侧按缺项降级显示，不猜、不填 0。
    static let collectionScript = #"""
    printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null)"
    printf 'KERNEL=%s\n' "$(uname -sr 2>/dev/null)"

    if [ -r /proc/stat ]; then
        printf 'OS=%s\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")"
        printf 'CPUS=%s\n' "$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
        printf 'LOAD=%s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
        printf 'UPTIME=%s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
        printf 'PROCS=%s\n' "$(ls -1 /proc 2>/dev/null | grep -c '^[0-9][0-9]*$')"

        awk '/^cpu /{t=0; for (i=2; i<=NF; i++) t+=$i; print "CPUTOTAL=" t; print "CPUIDLE=" ($5+$6); exit}' /proc/stat 2>/dev/null

        awk '
            /^MemTotal:/{mt=$2}
            /^MemAvailable:/{ma=$2; hasma=1}
            /^MemFree:/{mf=$2}
            /^Buffers:/{bu=$2}
            /^Cached:/{ca=$2}
            /^SwapTotal:/{st=$2}
            /^SwapFree:/{sf=$2}
            END{
                if (mt) print "MEMTOTAL=" mt
                if (hasma) print "MEMAVAIL=" ma; else if (mt) print "MEMAVAIL=" (mf+bu+ca)
                if (st) { print "SWAPTOTAL=" st; print "SWAPFREE=" sf+0 }
            }' /proc/meminfo 2>/dev/null

        # 逐网卡输出（UI 支持指定网卡）。只统计物理/上联网卡：
        # 回环与容器虚拟网卡会把同一份流量重复计一遍
        awk 'NR>2 {
                sub(/^ +/, "");
                split($0, p, ":");
                ifc=p[1];
                if (ifc ~ /^(lo|docker|veth|br-|virbr|cni|flannel|tun|tap)/) next;
                split(p[2], f, " ");
                if (f[1]+f[9] == 0) next;
                printf "NETIF=%s|%s|%s\n", ifc, f[1], f[9];
            }' /proc/net/dev 2>/dev/null

        # 逐盘 I/O 累计字节（分区会在父盘下重复出现，只列 /sys/block 顶层盘；
        # dm/md 是 LVM/软 RAID 层也列入——挂载点要按它对齐，合计在 app 侧排除 dm/md 防重复计数）
        for dev in /sys/block/*; do
            d=${dev##*/}
            case "$d" in loop*|ram*|zram*|fd*|sr*|nbd*) continue ;; esac
            [ -r "$dev/stat" ] || continue
            set -- $(cat "$dev/stat" 2>/dev/null)
            [ "$((${3:-0} + ${7:-0}))" -gt 0 ] || continue
            printf 'DISKIO=%s|%s|%s\n' "$d" "$((${3:-0} * 512))" "$((${7:-0} * 512))"
        done

        for zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$zone/temp" ] || continue
            case "$(cat "$zone/type" 2>/dev/null)" in
                *cpu*|*x86_pkg*|*coretemp*|*soc*|*package*)
                    printf 'TEMPMC=%s\n' "$(cat "$zone/temp" 2>/dev/null)"
                    break
                    ;;
            esac
        done

        # 进程 TOP（前 10）：procps 优先（ps -eo 按 CPU 排序）；busybox/老系统不支持 -eo
        # 时直接解析 /proc/[pid]/stat——CPU% = (utime+stime)/HZ / 进程存活时长 ×100，
        # 与 ps 的 %CPU（生命周期均值）同口径
        if [ -n "$(ps -eo comm=,pid=,pcpu=,pmem= -r 2>/dev/null | head -1)" ]; then
            ps -eo comm=,pid=,pcpu=,pmem= -r 2>/dev/null | head -10 | while IFS= read -r name pid cpu mem; do
                case "$name" in ""|" "*) continue ;; esac
                printf 'TOPPROC=%.16s|%s|%s|%s\n' "$name" "$pid" "$cpu" "$mem"
            done
        else
            memtotal=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
            pagesz=$(getconf PAGESIZE 2>/dev/null)
            [ -n "$pagesz" ] || pagesz=4096
            awk -v mt="$memtotal" -v pgsz="$pagesz" '
                BEGIN {
                    while ((getline line < "/proc/uptime") > 0) { split(line, u, " "); up = u[1] + 0; break }
                    hz = 100
                }
                {
                    line = $0
                    first = index(line, "(")
                    pos = 0; i = 0
                    while ((i = index(substr(line, pos + 1), ")")) > 0) pos += i
                    if (first == 0 || pos == 0) next
                    comm = substr(line, first + 1, pos - first - 1)
                    n = split(substr(line, pos + 2), f, " ")
                    if (n < 22) next
                    ut = f[12] + 0; st = f[13] + 0; starttick = f[20] + 0; rss = f[22] + 0
                    elapsed = up - starttick / hz
                    if (elapsed < 1) elapsed = 1
                    cpu = (ut + st) / hz / elapsed * 100
                    mem = (mt + 0 > 0) ? rss * pgsz / mt / 1024 * 100 : 0
                    printf "%.16s|%s|%.1f|%.1f\n", comm, $1, cpu, mem
                }' /proc/[0-9]*/stat 2>/dev/null | sort -t"|" -k3 -rn | head -10 | \
            while IFS="|" read -r name pid cpu mem; do
                printf 'TOPPROC=%s|%s|%s|%s\n' "$name" "$pid" "$cpu" "$mem"
            done
        fi
    else
        printf 'OS=%s\n' "$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
        printf 'CPUS=%s\n' "$(sysctl -n hw.ncpu 2>/dev/null)"
        printf 'LOAD=%s\n' "$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | sed 's/^ *//;s/ *$//')"
        printf 'PROCS=%s\n' "$(ps -A 2>/dev/null | awk 'END{print NR-1}')"

        # 注意别贪婪匹配到后面的 usec:形如 "{ sec = 1786400000, usec = 123456 } ..."
        boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9][0-9]*\).*/\1/p')
        [ -n "$boot" ] && printf 'UPTIME=%s\n' "$(( $(date +%s) - boot ))"

        top -l 1 -n 0 2>/dev/null | awk '/CPU usage/{
            for (i=1; i<=NF; i++) if ($i == "idle") {
                idle=$(i-1); sub(/%/, "", idle); printf "CPUPCT=%.1f\n", 100-idle; exit
            }
        }'

        pagesize=$(vm_stat 2>/dev/null | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p')
        [ -z "$pagesize" ] && pagesize=4096
        memsize=$(sysctl -n hw.memsize 2>/dev/null)
        [ -n "$memsize" ] && printf 'MEMTOTAL=%s\n' "$((memsize / 1024))"
        vm_stat 2>/dev/null | awk -v ps="$pagesize" '
            /Pages free/{gsub(/\./, "", $NF); f=$NF}
            /Pages inactive/{gsub(/\./, "", $NF); i=$NF}
            /Pages speculative/{gsub(/\./, "", $NF); s=$NF}
            END{ if (f+i+s > 0) printf "MEMAVAIL=%d\n", (f+i+s) * ps / 1024 }'

        netstat -ib 2>/dev/null | awk '
            $1 !~ /^(lo|Name|awdl|llw|utun|bridge|anpi|ap[0-9])/ && $3 ~ /^<Link/ {
                sub(/\*$/, "", $1);
                if ($7+$10 == 0) next;
                printf "NETIF=%s|%s|%s\n", $1, $7, $10 }'

        # 进程 TOP（macOS：top 一拍按 CPU 排序取前 10；mem 列 macOS 无百分比，留空）
        top -l 1 -o cpu -n 10 -stats pid,command,cpu 2>/dev/null | awk '
            /^ *[0-9]+ / {
                pid = $1; cpu = $NF
                name = $2
                for (i = 3; i < NF; i++) name = name " " $i
                if (pid+0 > 0) printf "TOPPROC=%.16s|%s|%s|\n", name, pid, cpu
            }' | head -10
    fi

    # 真实文件系统的容量，最多 6 个挂载点。排掉伪文件系统（tmpfs/overlay）与
    # macOS 的系统辅助卷（VM/Preboot/Update…）—— 它们和根卷共用容器，列出来只是噪声。
    # 末列附设备名；基础块设备名（分区→顶层盘、mapper→dm-N）由磁盘读写列对齐 DISKIO 用
    df -kP 2>/dev/null | awk '
        NR>1 && $1 !~ /^(tmpfs|devtmpfs|udev|none|shm|map|devfs)$/ && $2+0 > 0 &&
        ($1 != "overlay" || $6 == "/") &&
        $6 !~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)/ &&
        $6 !~ /^\/(dev|proc|sys|run|snap)/ && $6 !~ /^\/var\/lib\/docker/ {
            # 同一个文件系统被 bind-mount 多次时只留第一个挂载点，别把一块盘数三遍
            key = $1 "|" $2 "|" $3;
            if (seen[key]++) next;
            print $6 "|" $3 "|" $2 "|" $1
        }' | head -6 | while IFS='|' read -r mount used total dev; do
        base=${dev##*/}
        case "$dev" in
            /dev/mapper/*|/dev/dm-*)
                b=$(readlink -f "$dev" 2>/dev/null); b=${b##*/}
                [ -n "$b" ] && base=$b ;;
        esac
        # 分区名剥到顶层盘：nvme0n1p2→nvme0n1、sda1→sda、mmcblk0p1→mmcblk0
        if [ -d /sys/block ]; then
            b=$base
            while [ -n "$b" ] && [ ! -e "/sys/block/$b" ]; do
                case "$b" in
                    *[0-9]) b=${b%[0-9]}; case "$b" in *p) b=${b%p} ;; esac ;;
                    *) break ;;
                esac
            done
            [ -n "$b" ] && [ -e "/sys/block/$b" ] && base=$b
        fi
        printf 'DISK=%s|%s|%s|%s\n' "$mount" "$used" "$total" "$base"
    done

    exit 0
    """#
}

/// 一次采样 + 上一次采样 → 可直接上屏的展示值。
/// CPU 占用与网络/磁盘速率必须靠两次采样求差，所以首次采集这几项为 nil（UI 显示「—」）。
struct ServerMetricsReading: Equatable, Sendable {
    var takenAt: Date
    var hostname: String
    var os: String
    var kernel: String
    var cpuCount: Int
    var load: [Double]
    var uptimeSeconds: Double?
    var processes: Int?
    var temperatureC: Double?
    /// 进程 TOP（按 CPU 降序，跨采样透传——无需差分）
    var topProcesses: [ServerMetricsSample.TopProcess] = []

    /// 0...1
    var cpuFraction: Double?
    var memUsedKB: Double?
    var memTotalKB: Double?
    var swapUsedKB: Double?
    var swapTotalKB: Double?
    /// bytes/s
    var netRxRate: Double?
    var netTxRate: Double?
    /// 逐网卡速率（与采样的 netIfs 一一对应，差分得出）
    var netIfRates: [NetIfRate] = []
    /// 物理盘合计速率（排除 dm/md 层防重复计数）
    var diskReadRate: Double?
    var diskWriteRate: Double?
    /// 逐盘速率（含 dm/md）
    var diskIORates: [DiskIORate] = []
    var disks: [ServerMetricsSample.DiskUsage]

    struct NetIfRate: Equatable, Sendable {
        let name: String
        let rxRate: Double?
        let txRate: Double?
    }

    struct DiskIORate: Equatable, Sendable {
        let name: String
        let readRate: Double?
        let writeRate: Double?
    }

    /// 指定网卡的 (上行, 下行) 速率；nil 或该网卡本轮缺席时回退合计
    func netRates(selected name: String?) -> (up: Double?, down: Double?) {
        guard let name, let nic = netIfRates.first(where: { $0.name == name }) else {
            return (netTxRate, netRxRate)
        }
        return (nic.txRate, nic.rxRate)
    }

    /// 磁盘列当前展示的用量：选中挂载点优先，否则主盘
    func diskUsage(selectedMount: String?) -> ServerMetricsSample.DiskUsage? {
        guard let selectedMount,
              let disk = disks.first(where: { $0.mount == selectedMount }) else {
            return primaryDisk
        }
        return disk
    }

    /// 磁盘读写列当前展示的速率：按选中挂载点的块设备对齐；对不上时回退物理盘合计
    func diskRates(selectedMount: String?) -> (write: Double?, read: Double?) {
        let usage = diskUsage(selectedMount: selectedMount)
        if let dev = usage?.dev, !dev.isEmpty,
           let io = diskIORates.first(where: { $0.name == dev }) {
            return (io.writeRate, io.readRate)
        }
        return (diskWriteRate, diskReadRate)
    }

    var memFraction: Double? {
        guard let used = memUsedKB, let total = memTotalKB, total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    var swapFraction: Double? {
        guard let used = swapUsedKB, let total = swapTotalKB, total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    /// 主盘：优先根分区，否则容量最大的那个
    var primaryDisk: ServerMetricsSample.DiskUsage? {
        disks.first { $0.mount == "/" } ?? disks.max { $0.totalKB < $1.totalKB }
    }

    /// 负载相对核数（> 1 表示排队）
    var loadFraction: Double? {
        guard let load1 = load.first, cpuCount > 0 else { return nil }
        return load1 / Double(cpuCount)
    }

    init(sample: ServerMetricsSample, previous: ServerMetricsSample? = nil) {
        takenAt = sample.takenAt
        hostname = sample.hostname
        os = sample.os
        kernel = sample.kernel
        cpuCount = sample.cpuCount
        load = sample.load
        uptimeSeconds = sample.uptimeSeconds
        processes = sample.processes
        temperatureC = sample.temperatureC
        topProcesses = sample.topProcesses
        disks = sample.disks

        memTotalKB = sample.memTotalKB
        if let total = sample.memTotalKB, let available = sample.memAvailableKB {
            memUsedKB = max(total - available, 0)
        }
        swapTotalKB = sample.swapTotalKB
        if let total = sample.swapTotalKB, let free = sample.swapFreeKB {
            swapUsedKB = max(total - free, 0)
        }

        // 采样间隔：同一台机器两次采集的本地时刻差。<0.5s 的差分噪声太大，直接不算
        let interval = previous.map { sample.takenAt.timeIntervalSince($0.takenAt) } ?? 0

        if let direct = sample.cpuPercentDirect {
            cpuFraction = direct / 100
        } else if let previous, interval >= 0.5,
                  let total = sample.cpuTotalTicks, let idle = sample.cpuIdleTicks,
                  let prevTotal = previous.cpuTotalTicks, let prevIdle = previous.cpuIdleTicks {
            let totalDelta = total - prevTotal
            let idleDelta = idle - prevIdle
            // 计数器回绕或服务器重启 → 差值为负，这一轮不出数
            if totalDelta > 0, idleDelta >= 0 {
                cpuFraction = min(max(1 - idleDelta / totalDelta, 0), 1)
            }
        }

        if let previous, interval >= 0.5 {
            var rxSum: Double?
            var txSum: Double?
            for nic in sample.netIfs {
                let prev = previous.netIfs.first { $0.name == nic.name }
                let rx = Self.rate(nic.rxBytes, prev?.rxBytes, interval: interval)
                let tx = Self.rate(nic.txBytes, prev?.txBytes, interval: interval)
                netIfRates.append(NetIfRate(name: nic.name, rxRate: rx, txRate: tx))
                if let rx { rxSum = (rxSum ?? 0) + rx }
                if let tx { txSum = (txSum ?? 0) + tx }
            }
            netRxRate = rxSum
            netTxRate = txSum
            var readSum: Double?
            var writeSum: Double?
            for io in sample.diskIOs {
                let prev = previous.diskIOs.first { $0.name == io.name }
                let read = Self.rate(io.readBytes, prev?.readBytes, interval: interval)
                let write = Self.rate(io.writeBytes, prev?.writeBytes, interval: interval)
                diskIORates.append(DiskIORate(name: io.name, readRate: read, writeRate: write))
                // 合计只算物理盘：dm/md 的流量已含在底层 sd/nvme 里，加一遍会翻倍
                if io.name.hasPrefix("dm-") || io.name.hasPrefix("md") { continue }
                if let read { readSum = (readSum ?? 0) + read }
                if let write { writeSum = (writeSum ?? 0) + write }
            }
            diskReadRate = readSum
            diskWriteRate = writeSum
        }
    }

    private static func rate(_ current: Double?, _ previous: Double?, interval: TimeInterval) -> Double? {
        guard let current, let previous, current >= previous else { return nil }
        return (current - previous) / interval
    }
}

// MARK: - 展示格式化

enum MetricFormat {
    /// 速率：B/s → 合适量级
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "—" }
        return byteCount(value) + "/s"
    }

    static func byteCount(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(bytes, 0)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        // 大单位给一位小数，B/KB 没必要
        let precise = unit >= 2 && value < 100
        return String(format: precise ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    /// KB（1024 进制）→ 人话容量
    static func kilobytes(_ kb: Double?) -> String {
        guard let kb else { return "—" }
        return byteCount(kb * 1024)
    }

    /// 运行时长：天/小时/分钟，只取两级
    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return L("%ld 天", days) }
        if hours > 0 { return L("%ld 小时 %ld 分", hours, minutes) }
        return L("%ld 分钟", minutes)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%.1f%%", fraction * 100)
    }
}
