# pmlogger - PCP Performance Metrics Archive Logger

## What is pmlogger?

**pmlogger** is the performance metrics archive logging daemon in Performance Co-Pilot (PCP). It collects performance metric data from PMCD (Performance Metrics Collection Daemon) or local PMDAs and persistently stores this data as archive files for later analysis and playback.

pmlogger is the core component of PCP's "VCR paradigm", enabling retrospective performance analysis.

## Main Functions

### 1. Performance Metrics Archiving
- Periodically fetches performance metric values from PMCD
- Writes metric data in PCP archive file format
- Supports local and remote metric collection
- Supports archive versions 2 and 3 (default version 3)

### 2. Flexible Logging Control
pmlogger maintains an independent two-level logging state for each instance of each performance metric:

**Mandatory Level**:
- **on**: Must be logged (with associated sampling interval)
- **off**: Must not be logged
- **maybe**: Determined by advisory level

**Advisory Level** (only effective when mandatory level is maybe):
- **on**: Log (with associated sampling interval)
- **off**: Don't log

Default state: All metrics are "mandatory maybe, advisory off"

### 3. Dynamic Configuration
- Query and modify logging state at runtime using `pmlc` tool
- Configuration files define initial logging rules
- Supports instance filtering (log specific instances or all instances)

### 4. Archive Management
- **Volume switching**: Automatically create new volumes based on size, time, or sample count
- **Compression**: Support archive compression to save disk space
- **Culling**: Automatically delete old archive files
- **Merging**: Merge multiple archive files
- **Rewriting**: Modify archive metadata

### 5. Remote Push
- Support pushing archive data to remote pmproxy servers
- Uses HTTP protocol for transmission
- Supports distributed archive storage

## Use Cases

### Use Case 1: Primary pmlogger
Each system can configure one "primary" pmlogger instance:

```bash
# Started by system service
systemctl start pmlogger

# Configuration files
/etc/pcp/pmlogger/control         # Control configuration
/var/lib/pcp/config/pmlogger/config.default  # Default config
```

The primary pmlogger typically logs common system metrics for daily monitoring and troubleshooting.

### Use Case 2: Custom pmlogger
Start additional pmlogger instances for specific purposes:

```bash
# Log specific metrics to custom directory
pmlogger -c myconfig.conf -t 30s /var/log/pcp/archives/myapp

# Use strftime-formatted archive names
pmlogger -c config.conf /archives/%Y%m%d.%H.%M
```

### Use Case 3: Remote Logging
Log metrics from remote hosts:

```bash
# Connect to remote PMCD
pmlogger -h remote-host.example.com -c config.conf /archives/remote

# Push to remote pmproxy
pmlogger -c config.conf http://archive-server.example.com:44322
```

## Configuration File Format

pmlogger configuration files define which metrics to log and sampling intervals:

```
# Basic syntax
log mandatory on <interval> {
    metric.name
    metric.name [ instance1 instance2 ]
}

# Example configuration
log mandatory on once {
    # System information (logged once)
    hinv.ncpu
    hinv.physmem
}

log mandatory on 1 minute {
    # CPU metrics (every minute)
    kernel.all.cpu.idle
    kernel.all.cpu.user
    kernel.all.cpu.sys
}

log mandatory on 30 seconds {
    # Disk I/O (every 30 seconds)
    disk.dev.read
    disk.dev.write
    disk.dev.total
}

log advisory on 10 seconds {
    # Network traffic (advisory every 10 seconds)
    network.interface.in.bytes
    network.interface.out.bytes
}
```

## Common Command Options

### Basic Options
```bash
-c conffile     # Specify configuration file
-h host         # Connect to remote PMCD
-l logfile      # Specify log file
-t interval     # Default sampling interval (default 60 seconds)
-v volsize      # Volume size limit
```

### Archive Control
```bash
-s endsize      # Stop after reaching specified size
-T endtime      # Stop after specified time
-V version      # Archive version (2 or 3)
```

### Advanced Options
```bash
-P              # Mark as primary pmlogger
-r              # Report if metrics unavailable
-N              # Perform fetch and store at sample time
-L              # Use local context instead of PMCD
```

## Archive File Structure

Archives created by pmlogger consist of multiple files:

```
archivename.meta        # Metadata (metric descriptions, instance domains, etc.)
archivename.0           # First volume data
archivename.1           # Second volume data (if volume switched)
archivename.index       # Time index
```

## Management Tools

PCP provides a suite of tools for managing pmlogger:

### pmlogger_check
Check and start configured pmlogger instances:

```bash
# Manually run check
pmlogger_check

# Usually run automatically by timer
systemctl status pmlogger_check.timer
```

### pmlogger_daily
Daily maintenance tasks (compression, culling, etc.):

```bash
# Manual run
pmlogger_daily

# Run automatically by timer
systemctl status pmlogger_daily.timer
```

Configuration options:
- `$PCP_CULLAFTER`: Days to keep (default 14 days)
- `$PCP_COMPRESSAFTER`: Days before compression (default immediate)

### pmlogger_merge
Merge multiple archive files:

```bash
# Merge archives
pmlogger_merge -o output.archive input1.archive input2.archive
```

### pmlogger_rewrite
Rewrite archive metadata:

```bash
# Modify archive
pmlogger_rewrite -c rewrite.conf input.archive output.archive
```

### pmlc (pmlogger control)
Control running pmlogger in real-time:

```bash
# Connect to pmlogger
pmlc

# pmlc commands
pmlc> show loggers        # Show running pmloggers
pmlc> connect <pid>       # Connect to specific pmlogger
pmlc> query kernel.all.cpu  # Query metric status
pmlc> log mandatory on 5 sec kernel.all.cpu  # Modify logging state
```

## Position in Architecture

```
Applications/Tools
     ↓
  pmlogger ←→ pmlc (control)
     ↓
   PMCD (local or remote)
     ↓
  Various PMDAs
     ↓
  System/Application Metrics
```

## Practical Examples

### Example 1: Web Server Monitoring
```bash
# Configuration file: webserver.conf
log mandatory on 30 seconds {
    kernel.all.cpu
    mem.util
    network.interface.in.bytes["eth0"]
    network.interface.out.bytes["eth0"]
    apache.total_accesses
    apache.total_kbytes
}

# Start pmlogger
pmlogger -c webserver.conf -t 30s /var/log/pcp/webserver/$(date +%Y%m%d)
```

### Example 2: Database Performance Monitoring
```bash
# Configuration file: database.conf
log mandatory on 1 minute {
    mysql.status.queries
    mysql.status.slow_queries
    mysql.status.connections
    disk.dev.read
    disk.dev.write
}

# Start
pmlogger -c database.conf /archives/mysql/$(hostname)
```

### Example 3: Container Monitoring
```bash
# Configuration file: containers.conf
log mandatory on 10 seconds {
    containers.cpu.usage
    containers.memory.usage
    containers.network.in.bytes
    containers.network.out.bytes
}

# Start
pmlogger -c containers.conf /archives/containers/%Y%m%d.%H.%M
```

## Performance Considerations

### Sampling Interval
- **Too frequent** (< 1 second): High CPU overhead, large archives
- **Too sparse** (> 5 minutes): May miss important events
- **Recommended**: 30-60 seconds for most scenarios

### Metric Selection
- Only log needed metrics
- Use instance filtering to reduce data volume
- Consider using derived metrics to reduce storage

### Archive Size
- Use volume switching to avoid single large files
- Enable compression to save space
- Regularly cull old archives

## Troubleshooting

### Check pmlogger Status
```bash
# View running pmloggers
pmlogger_check -V
pcp | grep pmlogger

# View logs
journalctl -u pmlogger
tail -f /var/log/pcp/pmlogger/pmlogger.log
```

### Common Issues

**pmlogger won't start**:
- Check configuration file syntax
- Verify archive directory permissions
- Confirm PMCD is running

**Archive files too large**:
- Reduce sampling frequency
- Reduce number of logged metrics
- Enable compression
- Adjust volume switching parameters

**Cannot connect to PMCD**:
- Check network connection
- Verify PMCD is running
- Check firewall rules

## Relationship to Other PCP Components

- **PMCD**: pmlogger fetches metric data from PMCD
- **PMDAs**: Indirectly uses metrics provided by PMDAs through PMCD
- **pmproxy**: Can receive archive data pushed by pmlogger
- **pmie**: Can read archives created by pmlogger for inference
- **pmchart/pmrep**: Playback and visualize archives created by pmlogger
- **pmlogsummary**: Summarize archive statistics
- **pmlogextract**: Extract data from archives

## Security Considerations

- pmlogger typically runs as `pcp` user
- Archive file permissions should restrict access
- Remote connections should use encryption and authentication
- Configuration files should protect sensitive information

## Summary

pmlogger is an indispensable component in the PCP ecosystem that:

1. **Persists performance data**: Converts real-time metrics to playable archives
2. **Flexible configuration**: Fine-grained control over what to log and when
3. **Good scalability**: Supports from single host to large-scale deployment
4. **Complete tooling**: Supporting tools cover the entire lifecycle
5. **Retrospective analysis**: Foundation for post-mortem performance analysis

Through pmlogger, system administrators can establish complete performance history records for trend analysis, capacity planning, problem diagnosis, and compliance auditing.
