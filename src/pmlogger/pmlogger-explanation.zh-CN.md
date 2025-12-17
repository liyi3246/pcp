# pmlogger - PCP 性能指标归档日志记录器

## pmlogger 是什么？

**pmlogger** 是 Performance Co-Pilot (PCP) 中的性能指标归档日志记录守护进程。它负责从 PMCD（性能指标收集守护进程）或本地 PMDA 收集性能指标数据，并将这些数据持久化存储为归档文件，以便后续分析和回放。

pmlogger 是 PCP "VCR 范式"的核心组件，使得回溯性能分析成为可能。

## 主要功能

### 1. 性能指标归档
- 定期从 PMCD 获取性能指标值
- 将指标数据写入 PCP 归档文件格式
- 支持本地和远程指标收集
- 支持归档版本 2 和 3（默认版本 3）

### 2. 灵活的日志控制
pmlogger 为每个性能指标的每个实例维护独立的两级日志状态：

**强制级别（Mandatory Level）**：
- **on**：必须记录（带关联的采样间隔）
- **off**：必须不记录
- **maybe**：由建议级别决定

**建议级别（Advisory Level）**（仅在强制级别为 maybe 时有效）：
- **on**：记录（带关联的采样间隔）
- **off**：不记录

默认状态：所有指标都是 "强制 maybe，建议 off"

### 3. 动态配置
- 可以通过 `pmlc` 工具在运行时查询和修改日志状态
- 支持配置文件定义初始日志规则
- 支持实例过滤（记录特定实例或所有实例）

### 4. 归档管理
- **卷切换**：基于大小、时间或样本数自动创建新卷
- **压缩**：支持归档压缩以节省磁盘空间
- **清理**：自动删除旧归档文件
- **合并**：合并多个归档文件
- **重写**：修改归档元数据

### 5. 远程推送
- 支持将归档数据推送到远程 pmproxy 服务器
- 使用 HTTP 协议传输
- 支持分布式归档存储

## 使用场景

### 场景 1：主 pmlogger（Primary Logger）
每个系统可以配置一个"主" pmlogger 实例：

```bash
# 由系统服务启动
systemctl start pmlogger

# 配置文件
/etc/pcp/pmlogger/control         # 控制配置
/var/lib/pcp/config/pmlogger/config.default  # 默认配置
```

主 pmlogger 通常记录常用的系统指标，用于日常监控和故障排查。

### 场景 2：自定义 pmlogger
为特定目的启动额外的 pmlogger 实例：

```bash
# 记录特定指标到自定义目录
pmlogger -c myconfig.conf -t 30s /var/log/pcp/archives/myapp

# 使用 strftime 格式的归档名称
pmlogger -c config.conf /archives/%Y%m%d.%H.%M
```

### 场景 3：远程日志记录
记录远程主机的指标：

```bash
# 连接到远程 PMCD
pmlogger -h remote-host.example.com -c config.conf /archives/remote

# 推送到远程 pmproxy
pmlogger -c config.conf http://archive-server.example.com:44322
```

## 配置文件格式

pmlogger 配置文件定义了要记录的指标和采样间隔：

```
# 基本语法
log mandatory on <interval> {
    metric.name
    metric.name [ instance1 instance2 ]
}

# 示例配置
log mandatory on once {
    # 系统信息（仅记录一次）
    hinv.ncpu
    hinv.physmem
}

log mandatory on 1 minute {
    # CPU 指标（每分钟）
    kernel.all.cpu.idle
    kernel.all.cpu.user
    kernel.all.cpu.sys
}

log mandatory on 30 seconds {
    # 磁盘 I/O（每 30 秒）
    disk.dev.read
    disk.dev.write
    disk.dev.total
}

log advisory on 10 seconds {
    # 网络流量（建议每 10 秒）
    network.interface.in.bytes
    network.interface.out.bytes
}
```

## 常用命令选项

### 基本选项
```bash
-c conffile     # 指定配置文件
-h host         # 连接到远程 PMCD
-l logfile      # 指定日志文件
-t interval     # 默认采样间隔（默认 60 秒）
-v volsize      # 卷大小限制
```

### 归档控制
```bash
-s endsize      # 达到指定大小后停止
-T endtime      # 在指定时间后停止
-V version      # 归档版本（2 或 3）
```

### 高级选项
```bash
-P              # 标记为主 pmlogger
-r              # 如果指标不可用则报告
-N              # 在采样时执行获取和存储
-L              # 使用本地上下文而不是 PMCD
```

## 归档文件结构

pmlogger 创建的归档由多个文件组成：

```
archivename.meta        # 元数据（指标描述、实例域等）
archivename.0           # 第一卷数据
archivename.1           # 第二卷数据（如果卷切换）
archivename.index       # 时间索引
```

## 管理工具

PCP 提供了一套管理 pmlogger 的工具：

### pmlogger_check
检查并启动配置的 pmlogger 实例：

```bash
# 手动运行检查
pmlogger_check

# 通常由定时器自动运行
systemctl status pmlogger_check.timer
```

### pmlogger_daily
日常维护任务（压缩、清理等）：

```bash
# 手动运行
pmlogger_daily

# 由定时器自动运行
systemctl status pmlogger_daily.timer
```

配置选项：
- `$PCP_CULLAFTER`：保留天数（默认 14 天）
- `$PCP_COMPRESSAFTER`：压缩前保留天数（默认立即）

### pmlogger_merge
合并多个归档文件：

```bash
# 合并归档
pmlogger_merge -o output.archive input1.archive input2.archive
```

### pmlogger_rewrite
重写归档元数据：

```bash
# 修改归档
pmlogger_rewrite -c rewrite.conf input.archive output.archive
```

### pmlc（pmlogger 控制）
实时控制运行中的 pmlogger：

```bash
# 连接到 pmlogger
pmlc

# pmlc 命令
pmlc> show loggers        # 显示运行中的 pmlogger
pmlc> connect <pid>       # 连接到特定 pmlogger
pmlc> query kernel.all.cpu  # 查询指标状态
pmlc> log mandatory on 5 sec kernel.all.cpu  # 修改日志状态
```

## 架构中的位置

```
应用程序/工具
     ↓
  pmlogger ←→ pmlc（控制）
     ↓
   PMCD（本地或远程）
     ↓
  各种 PMDA
     ↓
  系统/应用程序指标
```

## 实际示例

### 示例 1：监控 Web 服务器
```bash
# 配置文件：webserver.conf
log mandatory on 30 seconds {
    kernel.all.cpu
    mem.util
    network.interface.in.bytes["eth0"]
    network.interface.out.bytes["eth0"]
    apache.total_accesses
    apache.total_kbytes
}

# 启动 pmlogger
pmlogger -c webserver.conf -t 30s /var/log/pcp/webserver/$(date +%Y%m%d)
```

### 示例 2：数据库性能监控
```bash
# 配置文件：database.conf
log mandatory on 1 minute {
    mysql.status.queries
    mysql.status.slow_queries
    mysql.status.connections
    disk.dev.read
    disk.dev.write
}

# 启动
pmlogger -c database.conf /archives/mysql/$(hostname)
```

### 示例 3：容器监控
```bash
# 配置文件：containers.conf
log mandatory on 10 seconds {
    containers.cpu.usage
    containers.memory.usage
    containers.network.in.bytes
    containers.network.out.bytes
}

# 启动
pmlogger -c containers.conf /archives/containers/%Y%m%d.%H.%M
```

## 性能考虑

### 采样间隔
- **太频繁**（< 1 秒）：高 CPU 开销，大归档
- **太稀疏**（> 5 分钟）：可能错过重要事件
- **建议**：大多数场景 30-60 秒

### 指标选择
- 仅记录需要的指标
- 使用实例过滤减少数据量
- 考虑使用派生指标减少存储

### 归档大小
- 使用卷切换避免单个大文件
- 启用压缩节省空间
- 定期清理旧归档

## 故障排查

### 检查 pmlogger 状态
```bash
# 查看运行中的 pmlogger
pmlogger_check -V
pcp | grep pmlogger

# 查看日志
journalctl -u pmlogger
tail -f /var/log/pcp/pmlogger/pmlogger.log
```

### 常见问题

**pmlogger 无法启动**：
- 检查配置文件语法
- 验证归档目录权限
- 确认 PMCD 正在运行

**归档文件过大**：
- 减少采样频率
- 减少记录的指标数量
- 启用压缩
- 调整卷切换参数

**连接 PMCD 失败**：
- 检查网络连接
- 验证 PMCD 正在运行
- 检查防火墙规则

## 与其他 PCP 组件的关系

- **PMCD**：pmlogger 从 PMCD 获取指标数据
- **PMDA**：通过 PMCD 间接使用 PMDA 提供的指标
- **pmproxy**：可以接收 pmlogger 推送的归档数据
- **pmie**：可以读取 pmlogger 创建的归档进行推理
- **pmchart/pmrep**：回放和可视化 pmlogger 创建的归档
- **pmlogsummary**：汇总归档统计信息
- **pmlogextract**：从归档提取数据

## 安全考虑

- pmlogger 通常以 `pcp` 用户运行
- 归档文件权限应限制访问
- 远程连接应使用加密和认证
- 配置文件应保护敏感信息

## 总结

pmlogger 是 PCP 生态系统中不可或缺的组件，它：

1. **持久化性能数据**：将实时指标转换为可回放的归档
2. **灵活可配置**：精细控制记录什么、何时记录
3. **可扩展性好**：支持从单台主机到大规模部署
4. **工具完善**：配套工具覆盖整个生命周期
5. **回溯分析**：是性能问题事后分析的基础

通过 pmlogger，系统管理员可以建立完整的性能历史记录，用于趋势分析、容量规划、问题诊断和合规审计。
