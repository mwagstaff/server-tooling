# Performance Analysis: ubuntu-4gb-hel1-2

- Generated: 2026-06-17T12:08:51Z
- Kernel: Linux 6.8.0-124-generic x86_64 GNU/Linux
- User: mwagstaff
- Sampling duration: 10s
- Primary sampled PID: 82962 (/usr/bin/node /home/mwagstaff/dev/kidsplorers/services/api/dist/index.js)

## Concise Summary

| Check | Status | Detail |
|---|---|---|
| CPU/load | OK | 1m load 1.61 across 4 CPU(s). |
| Memory/swap | Investigate | Memory use 71%, swap use 61%. |
| Disk capacity | OK | No non-tmpfs filesystem is >= 85% full. |
| Profiling tools | Limited | perf |

## Recommendations

- CPU load is within a normal range for the available CPU count.
- Memory pressure is high. For Node.js, capture heap snapshots from the app, check container or system memory limits, and review recent deploys for leaks or unbounded caches.
- Disk capacity is not currently the primary concern.
- Install missing tools for stronger evidence: perf. On Debian/Ubuntu this is usually sysstat, strace, and linux-tools matching the running kernel.

## Host Snapshot

### Uptime and Load

```text
 12:08:51 up 2 days,  1:17,  2 users,  load average: 1.61, 1.08, 1.04
```

### CPU and Memory Pressure (vmstat)

```text
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 3  0 1280136 1451572  32508 1088000  188  204   301  1851 4529   12 34  3 62  0  0  0
 0  0 1280136 1429108  32508 1088000    0    0     0     4 4155 4746 22  4 75  0  0  0
 2  0 1280136 1423052  32508 1088000    0    0     0   636 2476 3283 10  2 88  0  0  0
 2  0 1280136 1387388  32508 1088028    0    0     0    64 7113 8261 49  7 44  0  0  0
 1  0 1280136 1325120  32516 1088060    0    0     0   100 5553 7071 50  5 45  0  0  0
 1  0 1280136 1303172  32516 1088088    0    0     0    44 4673 5591 24  4 72  0  0  0
 2  0 1280136 1296988  32516 1088088    0    0     0     0 2032 2708  8  2 90  0  0  0
 0  0 1280136 1328912  32516 1088088    0    0     0    80 4662 5801 23  3 73  0  0  0
 2  0 1280136 1343412  32516 1088096    0    0     0   904 2811 3458 14  3 84  0  0  0
 1  0 1280136 1353844  32524 1088096    0    0     0   112 3093 4255 12  2 86  0  0  0
```

### Top CPU Processes

```text
    PID    PPID USER     STAT %CPU %MEM     ELAPSED COMMAND         COMMAND
 135595  135594 mwagsta+ R     100  0.0       00:00 ps              ps -eo pid,ppid,user,stat,%cpu,%mem,etime,comm,args --sort=-%cpu
  84425    1120 mwagsta+ Rsl  41.1  4.3    22:57:33 next-server (v1 next-server (v15.5.15)
  82962    1120 mwagsta+ Ssl  18.9  3.5    22:59:34 node            /usr/bin/node /home/mwagstaff/dev/kidsplorers/services/api/dist/index.js
 132194    1120 mwagsta+ Ssl  14.8  6.5    01:38:52 node            /usr/bin/node /home/mwagstaff/dev/top-scores/scraper.js
   2124    2024 caddy    Ssl  13.2 30.8  2-01:17:18 mongod          mongod --config /etc/mongod.conf
 132290    1120 mwagsta+ Ssl   9.1  6.6    01:38:51 node            /usr/bin/node /home/mwagstaff/dev/top-scores/monitor.js
 132275    1120 mwagsta+ Ssl   8.3  6.5    01:38:52 node            /usr/bin/node /home/mwagstaff/dev/top-scores/server.js
    924       1 root     Ssl   2.0  0.4  2-01:17:20 cloudflared     /usr/local/bin/cloudflared --no-autoupdate --protocol http2 --config /etc/cloudflared/config.yml tunnel run
   2151    2083 caddy    Ssl   1.4  3.1  2-01:17:18 redis-server    redis-server 127.0.0.1:6379
    922       1 caddy    Ssl   1.3  0.2  2-01:17:20 caddy           /usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
   1317    1120 mwagsta+ Ssl   0.8  0.9  2-01:17:19 node            /usr/bin/node /home/mwagstaff/dev/train-track-api/index.js
   1294    1120 mwagsta+ Ssl   0.6  0.9  2-01:17:19 node            /usr/bin/node /home/mwagstaff/dev/boris-bikes-api/server.js
   2142    2060 472      Ssl   0.6  1.8  2-01:17:18 grafana         grafana server --homepath=/usr/share/grafana --config=/etc/grafana/grafana.ini --packaging=docker cfg:default.log.mode=console cfg:default.paths.data=/var/lib/grafana cfg:default.paths.logs=/var/log/grafana cfg:default.paths.plugins=/var/lib/grafana/plugins cfg:default.paths.provisioning=/etc/grafana/provisioning
   2125    2013 nobody   Ssl   0.4  2.1  2-01:17:18 prometheus      /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=15d --web.enable-lifecycle
 135536  135535 mwagsta+ Ss    0.2  0.0       00:09 bash            bash -s
```

### Top Memory Processes

```text
    PID    PPID USER     STAT %CPU %MEM   RSS    VSZ     ELAPSED COMMAND         COMMAND
   2124    2024 caddy    Ssl  13.2 30.8 2448296 4527636 2-01:17:18 mongod        mongod --config /etc/mongod.conf
 132290    1120 mwagsta+ Ssl   9.1  6.6 526556 22721940 01:38:51 node            /usr/bin/node /home/mwagstaff/dev/top-scores/monitor.js
 132275    1120 mwagsta+ Ssl   8.3  6.5 522728 22702044 01:38:52 node            /usr/bin/node /home/mwagstaff/dev/top-scores/server.js
 132194    1120 mwagsta+ Ssl  14.8  6.5 515784 12207064 01:38:52 node            /usr/bin/node /home/mwagstaff/dev/top-scores/scraper.js
  84425    1120 mwagsta+ Rsl  41.1  4.3 346436 22540712 22:57:33 next-server (v1 next-server (v15.5.15)
  82962    1120 mwagsta+ Ssl  18.9  3.5 283844 12057256 22:59:34 node            /usr/bin/node /home/mwagstaff/dev/kidsplorers/services/api/dist/index.js
   2151    2083 caddy    Ssl   1.4  3.1 247232 540104 2-01:17:18 redis-server    redis-server 127.0.0.1:6379
   2125    2013 nobody   Ssl   0.4  2.1 173560 9209964 2-01:17:18 prometheus     /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=15d --web.enable-lifecycle
   2142    2060 472      Ssl   0.6  1.8 148656 1812292 2-01:17:18 grafana        grafana server --homepath=/usr/share/grafana --config=/etc/grafana/grafana.ini --packaging=docker cfg:default.log.mode=console cfg:default.paths.data=/var/lib/grafana cfg:default.paths.logs=/var/log/grafana cfg:default.paths.plugins=/var/lib/grafana/plugins cfg:default.paths.provisioning=/etc/grafana/provisioning
   1317    1120 mwagsta+ Ssl   0.8  0.9 75672 11828932 2-01:17:19 node           /usr/bin/node /home/mwagstaff/dev/train-track-api/index.js
   1294    1120 mwagsta+ Ssl   0.6  0.9 72608 11827996 2-01:17:19 node           /usr/bin/node /home/mwagstaff/dev/boris-bikes-api/server.js
 132304    1120 mwagsta+ Ssl   0.0  0.8 64704 1000980   01:38:51 node            /usr/bin/node /home/mwagstaff/dev/top-scores/audit.js
 132180    1120 mwagsta+ Ssl   0.0  0.7 60164 11515968  01:38:52 node            /usr/bin/node /home/mwagstaff/dev/top-scores-web/server.mjs
    369       1 root     S<s   0.0  0.6 49120 124260  2-01:17:33 systemd-journal /usr/lib/systemd/systemd-journald
   1320       1 root     Ssl   0.0  0.4 37108 2646852 2-01:17:19 dockerd         /usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
```

### Memory

```text
               total        used        free      shared  buff/cache   available
Mem:           7.6Gi       5.5Gi       1.3Gi       4.2Mi       1.1Gi       2.1Gi
Swap:          2.0Gi       1.2Gi       797Mi
```

### Filesystems

```text
Filesystem     Type      Size  Used Avail Use% Mounted on
efivarfs       efivarfs  256K   63K  189K  25% /sys/firmware/efi/efivars
/dev/sda1      ext4       75G   26G   47G  36% /
/dev/sda15     vfat      253M  146K  252M   1% /boot/efi
```

### Block Devices

```text
NAME    TYPE  SIZE FSTYPE   MOUNTPOINTS                   ROTA MODEL
loop0   loop 13.5M squashfs /snap/canonical-livepatch/406    0 
loop1   loop 49.3M squashfs /snap/snapd/26865                0 
loop2   loop   74M squashfs /snap/core22/2411                0 
sda     disk 76.3G                                           0 QEMU HARDDISK
├─sda1  part   76G ext4     /                                0 
├─sda14 part    1M                                           0 
└─sda15 part  256M vfat     /boot/efi                        0 
sr0     rom  1024M                                           1 QEMU DVD-ROM
```

## Disk I/O

### iostat

```text
Linux 6.8.0-124-generic (ubuntu-4gb-hel1-2) 	06/17/2026 	_x86_64_	(4 CPU)

avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          34.01    0.00    3.45    0.09    0.00   62.45

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
loop0            0.02      0.82     0.00   0.00    0.34    44.78    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
loop1            0.00      0.00     0.00   0.00    0.14     4.21    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
loop2            0.00      0.01     0.00   0.00    0.12     4.52    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
loop3            0.00      0.00     0.00   0.00    0.00     1.27    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
sda             24.94    300.98    26.57  51.58    0.26    12.07   45.99   1851.81    53.28  53.67    1.67    40.27    0.00      0.00     0.00   0.00    0.00     0.00    2.51    0.26    0.08   0.60


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          18.78    0.00    2.54    0.00    0.00   78.68

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda              0.00      0.00     0.00   0.00    0.00     0.00    1.00     72.00     1.00  50.00    1.00    72.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          13.89    0.00    2.53    0.00    0.00   83.59

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          44.81    0.00    4.30    0.00    0.00   50.89

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          34.18    0.00    4.05    0.00    0.00   61.77

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          58.69    0.00    3.53    0.00    0.00   37.78

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          15.74    0.00    2.54    0.00    0.00   81.73

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda              0.00      0.00     0.00   0.00    0.00     0.00    7.00     96.00     9.00  56.25    0.57    13.71    0.00      0.00     0.00   0.00    0.00     0.00    2.00    0.50    0.00   0.30


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          20.76    0.00    3.04    0.00    0.00   76.20

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          20.00    0.00    2.53    0.00    0.00   77.47

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          20.51    0.00    3.04    0.00    0.00   76.46

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


```

### Per-process I/O (pidstat)

```text
Linux 6.8.0-124-generic (ubuntu-4gb-hel1-2) 	06/17/2026 	_x86_64_	(4 CPU)

12:09:09 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

12:09:10 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
12:09:11 PM  1000    132275      0.00      4.00      0.00       0  node
12:09:11 PM  1000    132290      0.00      4.00      0.00       0  node

12:09:11 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

12:09:12 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

12:09:13 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

12:09:14 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

12:09:15 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

12:09:16 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

12:09:17 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

12:09:18 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

Average:      UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
Average:     1000    132275      0.00      0.40      0.00       0  node
Average:     1000    132290      0.00      0.40      0.00       0  node
```

## Node.js Processes

| PID | CPU % | MEM % | RSS KB | FDs | Elapsed | Command |
|---:|---:|---:|---:|---:|---|---|
| 1294 | 0.6 | 0.9 | 72544 | 26 | 2-01:17:38 | `/usr/bin/node /home/mwagstaff/dev/boris-bikes-api/server.js` |
| 1317 | 0.8 | 0.9 | 76388 | 32 | 2-01:17:38 | `/usr/bin/node /home/mwagstaff/dev/train-track-api/index.js` |
| 82962 | 18.9 | 3.2 | 255684 | 42 | 22:59:53 | `/usr/bin/node /home/mwagstaff/dev/kidsplorers/services/api/dist/index.js` |
| 132180 | 0.0 | 0.7 | 60212 | 19 | 01:39:12 | `/usr/bin/node /home/mwagstaff/dev/top-scores-web/server.mjs` |
| 132194 | 14.8 | 6.4 | 510540 | 40 | 01:39:11 | `/usr/bin/node /home/mwagstaff/dev/top-scores/scraper.js` |
| 132275 | 8.3 | 5.1 | 408112 | 38 | 01:39:11 | `/usr/bin/node /home/mwagstaff/dev/top-scores/server.js` |
| 132290 | 9.0 | 7.7 | 616740 | 28 | 01:39:11 | `/usr/bin/node /home/mwagstaff/dev/top-scores/monitor.js` |
| 132304 | 0.0 | 0.8 | 64768 | 19 | 01:39:11 | `/usr/bin/node /home/mwagstaff/dev/top-scores/audit.js` |

## Process Detail: 82962

### Process Status

```text
Name:	node
Umask:	0002
State:	S (sleeping)
Tgid:	82962
Ngid:	0
Pid:	82962
PPid:	1120
TracerPid:	0
Uid:	1000	1000	1000	1000
Gid:	1000	1000	1000	1000
FDSize:	256
Groups:	27 100 110 1000 
NStgid:	82962
NSpid:	82962
NSpgid:	82962
NSsid:	82962
Kthread:	0
VmPeak:	12187828 kB
VmSize:	12028952 kB
VmLck:	       0 kB
VmPin:	       0 kB
VmHWM:	  444176 kB
VmRSS:	  255684 kB
RssAnon:	  237052 kB
RssFile:	   18632 kB
RssShmem:	       0 kB
VmData:	  370912 kB
VmStk:	     132 kB
VmExe:	   27208 kB
VmLib:	   16380 kB
VmPTE:	    6060 kB
VmSwap:	   11368 kB
HugetlbPages:	       0 kB
CoreDumping:	0
THP_enabled:	1
untag_mask:	0xffffffffffffffff
Threads:	11
SigQ:	0/30830
SigPnd:	0000000000000000
ShdPnd:	0000000000000000
SigBlk:	0000000000000000
SigIgn:	0000000001001000
SigCgt:	0000000100004602
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	000001ffffffffff
CapAmb:	0000000000000000
NoNewPrivs:	0
Seccomp:	0
Seccomp_filters:	0
Speculation_Store_Bypass:	thread vulnerable
SpeculationIndirectBranch:	conditional enabled
Cpus_allowed:	f
Cpus_allowed_list:	0-3
Mems_allowed:	00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000000,00000001
Mems_allowed_list:	0
voluntary_ctxt_switches:	12425289
nonvoluntary_ctxt_switches:	2808010
x86_Thread_features:	
x86_Thread_features_locked:	
```

### Process Limits

```text
Limit                     Soft Limit           Hard Limit           Units     
Max cpu time              unlimited            unlimited            seconds   
Max file size             unlimited            unlimited            bytes     
Max data size             unlimited            unlimited            bytes     
Max stack size            8388608              unlimited            bytes     
Max core file size        0                    unlimited            bytes     
Max resident set          unlimited            unlimited            bytes     
Max processes             30830                30830                processes 
Max open files            1048576              1048576              files     
Max locked memory         1015242752           1015242752           bytes     
Max address space         unlimited            unlimited            bytes     
Max file locks            unlimited            unlimited            locks     
Max pending signals       30830                30830                signals   
Max msgqueue size         819200               819200               bytes     
Max nice priority         0                    0                    
Max realtime priority     0                    0                    
Max realtime timeout      unlimited            unlimited            us        
```

### Open File Descriptor Count

```text
42
```

### Top Open Files

```text
COMMAND   PID      USER   FD      TYPE  DEVICE SIZE/OFF   NODE NAME
node    82962 mwagstaff  cwd       DIR     8,1     4096 258185 /home/mwagstaff/dev/kidsplorers
node    82962 mwagstaff  rtd       DIR     8,1     4096      2 /
node    82962 mwagstaff  txt       REG     8,1 98932688 167635 /usr/bin/node
node    82962 mwagstaff  mem       REG     8,1 16645008 417827 /home/mwagstaff/dev/kidsplorers/node_modules/.pnpm/@img+sharp-libvips-linux-x64@1.2.4/node_modules/@img/sharp-libvips-linux-x64/lib/libvips-cpp.so.8.17.3
node    82962 mwagstaff  mem       REG     8,1  2125328 169197 /usr/lib/x86_64-linux-gnu/libc.so.6
node    82962 mwagstaff  mem       REG     8,1   410952 410823 /home/mwagstaff/dev/kidsplorers/node_modules/.pnpm/@img+sharp-linux-x64@0.34.5/node_modules/@img/sharp-linux-x64/lib/sharp-linux-x64.node
node    82962 mwagstaff  mem       REG     8,1  2592224 143859 /usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.33
node    82962 mwagstaff  mem       REG     8,1    60208 427928 /home/mwagstaff/dev/kidsplorers/node_modules/.pnpm/argon2@0.44.0/node_modules/argon2/prebuilds/linux-x64/argon2.glibc.node
node    82962 mwagstaff  mem       REG     8,1    68104 169210 /usr/lib/x86_64-linux-gnu/libresolv.so.2
node    82962 mwagstaff  mem       REG     8,1    14408 169209 /usr/lib/x86_64-linux-gnu/libpthread.so.0
node    82962 mwagstaff  mem       REG     8,1   183024 143857 /usr/lib/x86_64-linux-gnu/libgcc_s.so.1
node    82962 mwagstaff  mem       REG     8,1   952616 169200 /usr/lib/x86_64-linux-gnu/libm.so.6
node    82962 mwagstaff  mem       REG     8,1    14408 169199 /usr/lib/x86_64-linux-gnu/libdl.so.2
node    82962 mwagstaff  mem       REG     8,1   236616 169194 /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
node    82962 mwagstaff    0r      CHR     1,3      0t0      5 /dev/null
node    82962 mwagstaff    1w      REG     8,1      271 266693 /home/mwagstaff/dev/kidsplorers/kidsplorers-api.log
node    82962 mwagstaff    2w      REG     8,1        0 296745 /home/mwagstaff/dev/kidsplorers/kidsplorers-api.error.log
node    82962 mwagstaff    3u  a_inode    0,15        0   1062 [eventpoll]
node    82962 mwagstaff    4r     FIFO    0,14      0t0 723488 pipe
node    82962 mwagstaff    5w     FIFO    0,14      0t0 723488 pipe
node    82962 mwagstaff    6r     FIFO    0,14      0t0 723489 pipe
node    82962 mwagstaff    7w     FIFO    0,14      0t0 723489 pipe
node    82962 mwagstaff    8u  a_inode    0,15        0   1062 [eventfd:94]
node    82962 mwagstaff    9u  a_inode    0,15        0   1062 [eventpoll:10,12]
node    82962 mwagstaff   10r     FIFO    0,14      0t0 725328 pipe
node    82962 mwagstaff   11w     FIFO    0,14      0t0 725328 pipe
node    82962 mwagstaff   12u  a_inode    0,15        0   1062 [eventfd:95]
node    82962 mwagstaff   13u  a_inode    0,15        0   1062 [eventpoll:14,16,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,38,41,42,44,46]
node    82962 mwagstaff   14r     FIFO    0,14      0t0 725329 pipe
node    82962 mwagstaff   15w     FIFO    0,14      0t0 725329 pipe
node    82962 mwagstaff   16u  a_inode    0,15        0   1062 [eventfd:109]
node    82962 mwagstaff   17r      CHR     1,3      0t0      5 /dev/null
node    82962 mwagstaff   18u     IPv4  723580      0t0    TCP localhost:39936->localhost:27017 (ESTABLISHED)
node    82962 mwagstaff   19u     IPv4  723583      0t0    TCP *:3100 (LISTEN)
node    82962 mwagstaff   20u     IPv4  726080      0t0    TCP localhost:39946->localhost:27017 (ESTABLISHED)
node    82962 mwagstaff   21u     IPv4  726081      0t0    TCP localhost:39954->localhost:27017 (ESTABLISHED)
node    82962 mwagstaff   22u     IPv4  723590      0t0    TCP localhost:39962->localhost:27017 (ESTABLISHED)
node    82962 mwagstaff   23u     IPv4  723593      0t0    TCP localhost:39974->localhost:27017 (ESTABLISHED)
node    82962 mwagstaff   24u     IPv4  723596      0t0    TCP localhost:39988->localhost:27017 (ESTABLISHED)
```

## Hotspot Sampling

### perf

```text
perf is not installed.
```

### strace syscall summary

```text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 82.45    0.732841         225      3247       624 futex
  4.73    0.042077         117       359           munmap
  3.65    0.032440         175       185           mmap
  3.30    0.029350          13      2103           epoll_pwait
  2.09    0.018608         100       185           mprotect
  1.65    0.014645          12      1155         1 read
  0.72    0.006417          20       310           write
  0.72    0.006366          34       185           madvise
  0.53    0.004701          85        55           writev
  0.11    0.000990          26        38           getpid
  0.01    0.000131          21         6           epoll_ctl
  0.01    0.000076          12         6           close
  0.01    0.000065          32         2           getdents64
  0.01    0.000048          16         3           openat
  0.00    0.000044          14         3           accept4
  0.00    0.000037          12         3           setsockopt
  0.00    0.000019           9         2           shutdown
  0.00    0.000009           9         1           fstat
  0.00    0.000001           1         1           getrusage
------ ----------- ----------- --------- --------- ----------------
100.00    0.888865         113      7849       625 total
```

## Service and Container Context

### Failed systemd Units

```text
  UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
● cloud-init-hotplugd.service loaded failed failed Cloud-init: Hotplug Hook

Legend: LOAD   → Reflects whether the unit definition was properly loaded.
        ACTIVE → The high-level unit activation state, i.e. generalization of SUB.
        SUB    → The low-level unit activation state, values depend on unit type.

1 loaded units listed.
```

### Docker Containers

```text
NAME                CPU %     MEM USAGE / LIMIT     PIDS
mongo-kidsplorers   10.32%    2.38GiB / 7.564GiB    149
grafana             0.52%     154.6MiB / 7.564GiB   15
redis-server        0.63%     248.9MiB / 7.564GiB   6
prometheus          0.11%     181.7MiB / 7.564GiB   10
```

## Recent Kernel and OOM Signals

### Kernel warnings/errors

```text
```

## Interpretation Notes

- High load with low CPU usage often points to disk I/O wait, blocked network filesystems, or process contention.
- High Node.js CPU in perf without useful JavaScript frames still confirms where time is spent at the native/runtime level; use a Node.js CPU profile or inspector snapshot for source-level attribution.
- Heavy strace time in epoll_wait with low CPU is usually idle waiting, not a bottleneck. Heavy read/write/fsync/connect/futex time is more actionable.
- If the process runs inside a container, host-level perf/strace may need root or container PID namespace access.
