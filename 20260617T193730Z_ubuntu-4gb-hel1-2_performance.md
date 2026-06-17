# Performance Analysis: ubuntu-4gb-hel1-2

- Generated: 2026-06-17T19:37:31Z
- Kernel: Linux 6.8.0-124-generic x86_64 GNU/Linux
- User: mwagstaff
- Sampling duration: 10s
- Primary sampled PID: 141679 (/usr/bin/node /home/mwagstaff/dev/top-scores/scraper.js)

## Concise Summary

| Check | Status | Detail |
|---|---|---|
| CPU/load | OK | 1m load 1.00 across 4 CPU(s). |
| Memory/swap | Investigate | Memory use 79%, swap use 37%. |
| Disk capacity | OK | No non-tmpfs filesystem is >= 85% full. |
| Profiling tools | OK | perf, strace, iostat, and pidstat are available. |

## Recommendations

- CPU load is within a normal range for the available CPU count.
- Memory pressure is high. For Node.js, capture heap snapshots from the app, check container or system memory limits, and review recent deploys for leaks or unbounded caches.
- Disk capacity is not currently the primary concern.

## Host Snapshot

### Uptime and Load

```text
 19:37:31 up 2 days,  8:46,  1 user,  load average: 1.00, 1.15, 1.46
```

### CPU and Memory Pressure (vmstat)

```text
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 2  0 768916 1239128  22384 653332  183  195   290  1804 4502   12 33  3 63  0  0  0
 1  0 768916 1235608  22384 653484    0    0     0     4 2749 3697 10  2 88  0  0  0
 0  0 768916 1256140  22384 653484    0    0     0  1028 4637 5289 27  3 70  0  0  0
 3  0 768916 1261544  22384 653492    0    0     0     0 2314 3063 10  2 88  0  0  0
 0  0 768916 1280380  22384 653492    0    0     0   228 4978 6069 26  4 70  0  0  0
 1  0 768916 1281204  22392 653496    0    0     0   176 2184 3012  8  1 91  0  0  0
 0  0 768916 1289156  22392 653496    0    0     0    20 3940 4833 23  3 74  0  0  0
 1  0 768916 1277812  22392 653524    0    0     0     4 3217 3910 17  2 81  0  0  0
 0  0 768916 1263968  22392 653532    0    0     0     0 3317 4091 18  2 80  0  0  0
 2  0 768916 1247512  22392 653560    0    0     0     0 4029 4901 23  3 74  0  0  0
```

### Top CPU Processes

```text
    PID    PPID USER     STAT %CPU %MEM     ELAPSED COMMAND         COMMAND
 144589  144588 mwagsta+ R     100  0.0       00:00 ps              ps -eo pid,ppid,user,stat,%cpu,%mem,etime,comm,args --sort=-%cpu
  84425    1120 mwagsta+ Rsl  40.7  3.5  1-06:26:14 next-server (v1 next-server (v15.5.15)
 141679    1120 mwagsta+ Ssl  29.7  6.5    04:21:57 node            /usr/bin/node /home/mwagstaff/dev/top-scores/scraper.js
 141700    1120 mwagsta+ Ssl  25.5  5.4    04:21:57 node            /usr/bin/node /home/mwagstaff/dev/top-scores/server.js
  82962    1120 mwagsta+ Rsl  18.8  3.0  1-06:28:14 node            /usr/bin/node /home/mwagstaff/dev/kidsplorers/services/api/dist/index.js
 141721    1120 mwagsta+ Ssl  14.6  4.8    04:21:57 node            /usr/bin/node /home/mwagstaff/dev/top-scores/monitor.js
   2124    2024 caddy    Ssl  13.1 41.1  2-08:45:58 mongod          mongod --config /etc/mongod.conf
    924       1 root     Ssl   2.0  0.3  2-08:46:00 cloudflared     /usr/local/bin/cloudflared --no-autoupdate --protocol http2 --config /etc/cloudflared/config.yml tunnel run
   2151    2083 caddy    Ssl   1.4  2.9  2-08:45:58 redis-server    redis-server 127.0.0.1:6379
    922       1 caddy    Ssl   1.3  0.2  2-08:46:00 caddy           /usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
   1317    1120 mwagsta+ Ssl   0.8  0.8  2-08:46:00 node            /usr/bin/node /home/mwagstaff/dev/train-track-api/index.js
   1294    1120 mwagsta+ Ssl   0.6  0.8  2-08:46:00 node            /usr/bin/node /home/mwagstaff/dev/boris-bikes-api/server.js
   2142    2060 472      Ssl   0.6  1.3  2-08:45:58 grafana         grafana server --homepath=/usr/share/grafana --config=/etc/grafana/grafana.ini --packaging=docker cfg:default.log.mode=console cfg:default.paths.data=/var/lib/grafana cfg:default.paths.logs=/var/log/grafana cfg:default.paths.plugins=/var/lib/grafana/plugins cfg:default.paths.provisioning=/etc/grafana/provisioning
   2125    2013 nobody   Ssl   0.4  1.9  2-08:45:58 prometheus      /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=15d --web.enable-lifecycle
 144530  144529 mwagsta+ Ss    0.3  0.0       00:09 bash            bash -s
```

### Top Memory Processes

```text
    PID    PPID USER     STAT %CPU %MEM   RSS    VSZ     ELAPSED COMMAND         COMMAND
   2124    2024 caddy    Ssl  13.1 41.1 3262748 4534832 2-08:45:58 mongod        mongod --config /etc/mongod.conf
 141679    1120 mwagsta+ Ssl  29.7  6.5 520740 12233568 04:21:57 node            /usr/bin/node /home/mwagstaff/dev/top-scores/scraper.js
 141700    1120 mwagsta+ Ssl  25.5  5.4 430952 22724636 04:21:57 node            /usr/bin/node /home/mwagstaff/dev/top-scores/server.js
 141721    1120 mwagsta+ Ssl  14.6  4.8 388564 22619020 04:21:57 node            /usr/bin/node /home/mwagstaff/dev/top-scores/monitor.js
  84425    1120 mwagsta+ Rsl  40.7  3.6 288544 22494360 1-06:26:14 next-server (v1 next-server (v15.5.15)
  82962    1120 mwagsta+ Ssl  18.8  3.0 238808 12015664 1-06:28:14 node          /usr/bin/node /home/mwagstaff/dev/kidsplorers/services/api/dist/index.js
   2151    2083 caddy    Ssl   1.4  2.9 235592 540104 2-08:45:58 redis-server    redis-server 127.0.0.1:6379
   2125    2013 nobody   Ssl   0.4  1.9 152052 9237600 2-08:45:58 prometheus     /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=15d --web.enable-lifecycle
   2142    2060 472      Ssl   0.6  1.3 110764 1812220 2-08:45:58 grafana        grafana server --homepath=/usr/share/grafana --config=/etc/grafana/grafana.ini --packaging=docker cfg:default.log.mode=console cfg:default.paths.data=/var/lib/grafana cfg:default.paths.logs=/var/log/grafana cfg:default.paths.plugins=/var/lib/grafana/plugins cfg:default.paths.provisioning=/etc/grafana/provisioning
   1294    1120 mwagsta+ Ssl   0.6  0.8 71332 11831792 2-08:46:00 node           /usr/bin/node /home/mwagstaff/dev/boris-bikes-api/server.js
   1317    1120 mwagsta+ Ssl   0.8  0.8 65956 11826304 2-08:46:00 node           /usr/bin/node /home/mwagstaff/dev/train-track-api/index.js
 141742    1120 mwagsta+ Ssl   0.0  0.4 38536 1005332   04:21:57 node            /usr/bin/node /home/mwagstaff/dev/top-scores/audit.js
    369       1 root     S<s   0.0  0.4 32976 124392  2-08:46:13 systemd-journal /usr/lib/systemd/systemd-journald
 141952    1120 mwagsta+ Ssl   0.0  0.4 32648 11520164  04:21:55 node            /usr/bin/node /home/mwagstaff/dev/top-scores-web/server.mjs
 138823       1 root     Ssl   0.0  0.3 29444 929336    06:03:29 fail2ban-server /usr/bin/python3 /usr/bin/fail2ban-server -xf start
```

### Memory

```text
               total        used        free      shared  buff/cache   available
Mem:           7.6Gi       6.0Gi       1.2Gi       4.0Mi       660Mi       1.6Gi
Swap:          2.0Gi       750Mi       1.3Gi
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
          33.43    0.00    3.43    0.09    0.00   63.05

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
loop0            0.02      0.75     0.00   0.00    0.34    44.82    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
loop1            0.00      0.00     0.00   0.00    0.15     4.12    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
loop2            0.00      0.01     0.00   0.00    0.13     4.50    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
loop3            0.00      0.00     0.00   0.00    0.00     1.27    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
sda             24.15    289.36    25.92  51.77    0.26    11.98   44.61   1804.77    50.95  53.32    1.68    40.46    0.00      0.00     0.00   0.00    0.00     0.00    2.42    0.26    0.08   0.58


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          13.10    0.00    1.76    0.25    0.00   84.89

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda              3.00     16.00     1.00  25.00    0.67     5.33  138.00   1976.00    54.00  28.12    0.56    14.32    0.00      0.00     0.00   0.00    0.00     0.00   31.00    0.23    0.08   2.00


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          21.16    0.00    2.27    0.25    0.00   76.32

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda              0.00      0.00     0.00   0.00    0.00     0.00    2.00      4.00     0.00   0.00    0.50     2.00    0.00      0.00     0.00   0.00    0.00     0.00    1.00    0.00    0.00   0.10


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          41.27    0.00    2.53    0.00    0.00   56.20

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          58.27    0.00    4.83    0.00    0.00   36.90

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          12.15    0.00    1.52    0.00    0.00   86.33

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda              0.00      0.00     0.00   0.00    0.00     0.00    8.00    128.00    16.00  66.67    0.50    16.00    0.00      0.00     0.00   0.00    0.00     0.00    4.00    0.25    0.01   0.30


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          24.81    0.00    3.04    0.00    0.00   72.15

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda              0.00      0.00     0.00   0.00    0.00     0.00   31.00    196.00     0.00   0.00    1.55     6.32    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.05   0.20


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          32.32    0.00    8.08    0.00    0.00   59.60

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda              0.00      0.00     0.00   0.00    0.00     0.00   92.00  81416.00    55.00  37.41    2.32   884.96    0.00      0.00     0.00   0.00    0.00     0.00    5.00    0.20    0.21   4.90


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
           6.33    0.00    1.01    0.00    0.00   92.66

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda              0.00      0.00     0.00   0.00    0.00     0.00    5.00     16.00     0.00   0.00    0.40     3.20    0.00      0.00     0.00   0.00    0.00     0.00    1.00    1.00    0.00   0.10


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          20.76    0.00    2.78    0.00    0.00   76.46

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util


```

### Per-process I/O (pidstat)

```text
Linux 6.8.0-124-generic (ubuntu-4gb-hel1-2) 	06/17/2026 	_x86_64_	(4 CPU)

07:37:49 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

07:37:50 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

07:37:51 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
07:37:52 PM  1000    141679      0.00      4.00      0.00       0  node

07:37:52 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
07:37:53 PM  1000    141700      0.00      4.00      0.00       0  node
07:37:53 PM  1000    141721      0.00      4.00      0.00       0  node

07:37:53 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

07:37:54 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

07:37:55 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

07:37:56 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

07:37:57 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
07:37:58 PM  1000    141721      0.00     16.00      0.00       0  node

07:37:58 PM   UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command

Average:      UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
Average:     1000    141679      0.00      0.40      0.00       0  node
Average:     1000    141700      0.00      0.40      0.00       0  node
Average:     1000    141721      0.00      2.00      0.00       0  node
```

## Node.js Processes

| PID | CPU % | MEM % | RSS KB | FDs | Elapsed | Command |
|---:|---:|---:|---:|---:|---|---|
| 1294 | 0.6 | 0.8 | 71188 | 26 | 2-08:46:19 | `/usr/bin/node /home/mwagstaff/dev/boris-bikes-api/server.js` |
| 1317 | 0.8 | 0.8 | 69088 | 33 | 2-08:46:19 | `/usr/bin/node /home/mwagstaff/dev/train-track-api/index.js` |
| 82962 | 18.8 | 2.9 | 235260 | 42 | 1-06:28:33 | `/usr/bin/node /home/mwagstaff/dev/kidsplorers/services/api/dist/index.js` |
| 141679 | 29.6 | 7.0 | 562592 | 42 | 04:22:16 | `/usr/bin/node /home/mwagstaff/dev/top-scores/scraper.js` |
| 141700 | 25.5 | 4.0 | 322480 | 44 | 04:22:16 | `/usr/bin/node /home/mwagstaff/dev/top-scores/server.js` |
| 141721 | 14.6 | 5.2 | 413456 | 30 | 04:22:16 | `/usr/bin/node /home/mwagstaff/dev/top-scores/monitor.js` |
| 141742 | 0.0 | 0.4 | 38596 | 19 | 04:22:16 | `/usr/bin/node /home/mwagstaff/dev/top-scores/audit.js` |
| 141952 | 0.0 | 0.4 | 32696 | 19 | 04:22:15 | `/usr/bin/node /home/mwagstaff/dev/top-scores-web/server.mjs` |

## Process Detail: 141679

### Process Status

```text
Name:	node
Umask:	0002
State:	S (sleeping)
Tgid:	141679
Ngid:	0
Pid:	141679
PPid:	1120
TracerPid:	0
Uid:	1000	1000	1000	1000
Gid:	1000	1000	1000	1000
FDSize:	256
Groups:	27 100 110 1000 
NStgid:	141679
NSpid:	141679
NSpgid:	141679
NSsid:	141679
Kthread:	0
VmPeak:	13595436 kB
VmSize:	12275904 kB
VmLck:	       0 kB
VmPin:	       0 kB
VmHWM:	 1764868 kB
VmRSS:	  562592 kB
RssAnon:	  541188 kB
RssFile:	   21404 kB
RssShmem:	       0 kB
VmData:	  628944 kB
VmStk:	     132 kB
VmExe:	   27208 kB
VmLib:	    5316 kB
VmPTE:	   10952 kB
VmSwap:	   10812 kB
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
voluntary_ctxt_switches:	1247571
nonvoluntary_ctxt_switches:	481396
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
COMMAND    PID      USER   FD      TYPE  DEVICE SIZE/OFF    NODE NAME
node    141679 mwagstaff  cwd       DIR     8,1     4096  265158 /home/mwagstaff/dev/top-scores
node    141679 mwagstaff  rtd       DIR     8,1     4096       2 /
node    141679 mwagstaff  txt       REG     8,1 98932688  167635 /usr/bin/node
node    141679 mwagstaff  mem       REG     8,1  2125328  169197 /usr/lib/x86_64-linux-gnu/libc.so.6
node    141679 mwagstaff  mem       REG     8,1  2592224  143859 /usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.33
node    141679 mwagstaff  mem       REG     8,1    14408  169209 /usr/lib/x86_64-linux-gnu/libpthread.so.0
node    141679 mwagstaff  mem       REG     8,1   183024  143857 /usr/lib/x86_64-linux-gnu/libgcc_s.so.1
node    141679 mwagstaff  mem       REG     8,1   952616  169200 /usr/lib/x86_64-linux-gnu/libm.so.6
node    141679 mwagstaff  mem       REG     8,1    14408  169199 /usr/lib/x86_64-linux-gnu/libdl.so.2
node    141679 mwagstaff  mem       REG     8,1   236616  169194 /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
node    141679 mwagstaff    0r      CHR     1,3      0t0       5 /dev/null
node    141679 mwagstaff    1w      REG     8,1  1436113  266980 /home/mwagstaff/dev/top-scores/top-scores-scraper.log
node    141679 mwagstaff    2w      REG     8,1     1690  267882 /home/mwagstaff/dev/top-scores/top-scores-scraper.error.log
node    141679 mwagstaff    3u  a_inode    0,15        0    1062 [eventpoll]
node    141679 mwagstaff    4r     FIFO    0,14      0t0 1436028 pipe
node    141679 mwagstaff    5w     FIFO    0,14      0t0 1436028 pipe
node    141679 mwagstaff    6r     FIFO    0,14      0t0 1436029 pipe
node    141679 mwagstaff    7w     FIFO    0,14      0t0 1436029 pipe
node    141679 mwagstaff    8u  a_inode    0,15        0    1062 [eventfd:17]
node    141679 mwagstaff    9u  a_inode    0,15        0    1062 [eventpoll:10,12]
node    141679 mwagstaff   10r     FIFO    0,14      0t0 1435307 pipe
node    141679 mwagstaff   11w     FIFO    0,14      0t0 1435307 pipe
node    141679 mwagstaff   12u  a_inode    0,15        0    1062 [eventfd:20]
node    141679 mwagstaff   13u  a_inode    0,15        0    1062 [eventpoll:14,16,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,38,40,41,42,43]
node    141679 mwagstaff   14r     FIFO    0,14      0t0 1435308 pipe
node    141679 mwagstaff   15w     FIFO    0,14      0t0 1435308 pipe
node    141679 mwagstaff   16u  a_inode    0,15        0    1062 [eventfd:25]
node    141679 mwagstaff   17r      CHR     1,3      0t0       5 /dev/null
node    141679 mwagstaff   18u     IPv6 1436101      0t0     TCP *:3013 (LISTEN)
node    141679 mwagstaff   19u     IPv4 1436109      0t0     TCP localhost:36860->localhost:27017 (ESTABLISHED)
node    141679 mwagstaff   20u     IPv6 1536506      0t0     TCP ubuntu-4gb-hel1-2:54262->[2606:4700:20::681a:bc9]:https (ESTABLISHED)
node    141679 mwagstaff   21u     IPv4 1436112      0t0     TCP localhost:36876->localhost:27017 (ESTABLISHED)
node    141679 mwagstaff   22u     IPv4 1436115      0t0     TCP localhost:36884->localhost:27017 (ESTABLISHED)
node    141679 mwagstaff   23u     IPv4 1436118      0t0     TCP localhost:36892->localhost:27017 (ESTABLISHED)
node    141679 mwagstaff   24u     IPv4 1436121      0t0     TCP localhost:36898->localhost:27017 (ESTABLISHED)
node    141679 mwagstaff   25u     IPv4 1436124      0t0     TCP localhost:36914->localhost:27017 (ESTABLISHED)
node    141679 mwagstaff   26u     IPv4 1436127      0t0     TCP localhost:36916->localhost:27017 (ESTABLISHED)
node    141679 mwagstaff   27u     IPv4 1436138      0t0     TCP localhost:36926->localhost:27017 (ESTABLISHED)
node    141679 mwagstaff   28u     IPv4 1434557      0t0     TCP localhost:41572->localhost:redis (ESTABLISHED)
```

## Hotspot Sampling

### perf stat

```text

 Performance counter stats for process id '141679':

            314.78 msec task-clock                       #    0.031 CPUs utilized             
               689      context-switches                 #    2.189 K/sec                     
                85      cpu-migrations                   #  270.032 /sec                      
               466      page-faults                      #    1.480 K/sec                     
       187,409,913      cycles                           #    0.595 GHz                       
        77,538,078      stalled-cycles-frontend          #   41.37% frontend cycles idle      
       269,566,895      instructions                     #    1.44  insn per cycle            
                                                  #    0.29  stalled cycles per insn   
        54,830,423      branches                         #  174.188 M/sec                     
         1,477,043      branch-misses                    #    2.69% of all branches           

      10.004883793 seconds time elapsed

```

### perf top symbols

```text
perf record failed; check perf_event_paranoid, kernel symbols, or permissions.
```

### strace syscall summary

```text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 91.80    0.684060         186      3675       767 futex
  3.26    0.024264          20      1158           epoll_pwait
  2.32    0.017287          19       900           read
  0.65    0.004867          45       106           munmap
  0.64    0.004759          48        99           mprotect
  0.44    0.003267          33        99           mmap
  0.38    0.002798          28        99           madvise
  0.17    0.001238          15        80           getpid
  0.08    0.000597          24        24         2 connect
  0.07    0.000525           9        58           write
  0.06    0.000414          31        13           close
  0.04    0.000277          19        14           getsockname
  0.03    0.000237          23        10           socket
  0.02    0.000175          19         9         2 epoll_ctl
  0.01    0.000090          22         4           ioctl
  0.01    0.000085          14         6           poll
  0.01    0.000084          42         2           sendmmsg
  0.01    0.000077          19         4           recvfrom
  0.00    0.000019           1        10           setsockopt
  0.00    0.000014           7         2           getsockopt
  0.00    0.000003           1         2           lseek
  0.00    0.000003           1         2           writev
  0.00    0.000003           0         4           newfstatat
  0.00    0.000002           1         2           openat
  0.00    0.000001           0         2           fstat
  0.00    0.000000           0         2           sendto
  0.00    0.000000           0         6           recvmsg
  0.00    0.000000           0         2           bind
------ ----------- ----------- --------- --------- ----------------
100.00    0.745146         116      6394       771 total
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
mongo-kidsplorers   6.29%     3.292GiB / 7.564GiB   156
grafana             0.59%     98.98MiB / 7.564GiB   15
redis-server        0.62%     235.9MiB / 7.564GiB   6
prometheus          0.00%     164.6MiB / 7.564GiB   10
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
