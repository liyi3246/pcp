# libpcp - Performance Co-Pilot 核心库

## libpcp 是什么？

**libpcp** 是 Performance Co-Pilot (PCP) 工具集的核心库。它提供了性能指标 API (PMAPI) 的基础架构和实现，PMAPI 是访问 PCP 性能指标的主要接口。

## 用途和功能

libpcp 的主要用途包括：

1. **实现 PMAPI**：提供完整的性能指标应用程序编程接口，客户端应用程序使用该接口访问性能数据。

2. **管理连接**：处理监控工具与以下组件之间的连接：
   - PMCD（性能指标收集守护进程）进程，用于实时指标
   - PCP 归档文件，用于回溯分析

3. **上下文管理**：维护性能指标上下文，这些上下文表示与 PMCD 的实时连接或 PCP 归档的句柄。

4. **指标解析**：在人类可读的指标名称和内部性能指标标识符 (PMID) 之间进行转换。

5. **数据检索**：从各种来源获取和格式化性能指标值。

6. **线程安全**：为使用性能指标的多线程应用程序提供线程安全的操作。

## 主要特性

- **线程安全实现**：专为多线程应用程序设计
- **跨平台支持**：支持 Linux、macOS、Windows (MinGW)、AIX 和 Solaris
- **协议处理**：管理与 PMCD 和归档文件的通信协议
- **派生指标**：支持从其他指标计算得出的派生指标
- **多上下文**：可以同时管理到不同指标源的多个连接
- **错误处理**：全面的错误报告和处理机制

## 如何使用 libpcp

### 在 C/C++ 应用程序中使用

包含主头文件：

```c
#include <pcp/pmapi.h>
```

对于高级用法，您可能还需要：

```c
#include <pcp/libpcp.h>
```

### 链接

将您的应用程序与 libpcp 链接：

```bash
cc myapp.c -lpcp
```

或使用 pkg-config：

```bash
cc myapp.c $(pkg-config --cflags --libs pcp)
```

### 基本使用模式

```c
#include <pcp/pmapi.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    int ctx, sts;
    pmID pmid;
    pmResult *result;
    char *metric = "kernel.all.load";
    
    /* 创建上下文（连接） */
    ctx = pmNewContext(PM_CONTEXT_HOST, "localhost");
    if (ctx < 0) {
        fprintf(stderr, "无法连接到 PMCD: %s\n", pmErrStr(ctx));
        return 1;
    }
    
    /* 按名称查找指标 */
    sts = pmLookupName(1, &metric, &pmid);
    if (sts < 0) {
        fprintf(stderr, "无法查找指标: %s\n", pmErrStr(sts));
        pmDestroyContext(ctx);
        return 1;
    }
    
    /* 获取指标值 */
    sts = pmFetch(1, &pmid, &result);
    if (sts < 0) {
        fprintf(stderr, "无法获取指标: %s\n", pmErrStr(sts));
        pmDestroyContext(ctx);
        return 1;
    }
    
    /* 使用这些值 ... */
    
    /* 清理 */
    pmFreeResult(result);
    pmDestroyContext(ctx);
    
    return 0;
}
```

## 与其他 PCP 组件的关系

- **PMAPI**：libpcp 实现 PMAPI 规范
- **pmcd**：libpcp 连接到 pmcd 以检索实时指标
- **PMDA**：libpcp 通过 pmcd 与性能指标域代理通信
- **libpcp_pmda**：用于编写 PMDA 的独立库（基于 libpcp 概念构建）
- **PCP 归档**：libpcp 可以从历史归档文件中读取指标
- **PCP 工具**：所有标准 PCP 工具（pminfo、pmval、pmstat 等）都是使用 libpcp 构建的

## 架构

在 PCP 术语中，libpcp 位于"PMAPI 下方"，实现客户端应用程序在"PMAPI 上方"使用的服务。它抽象了以下复杂性：

- 与 PMCD 的网络通信
- 归档文件格式处理
- 指标命名空间管理
- 实例域解析
- 归档回放的时间控制
- 连接池和管理

## 文档

有关详细的 API 文档，请参阅：

- `PMAPI(3)` - 主 PMAPI 手册页
- `pmNewContext(3)`、`pmFetch(3)`、`pmLookupName(3)` - 核心 PMAPI 函数
- `docs/PG/PMAPI.rst` - 程序员指南 PMAPI 章节
- `docs/PG/ProgrammingPcp.rst` - PCP 应用程序编程

有关线程安全和锁定的信息：
- `src/libpcp/doc/libpcp-locking.odt` - 锁定和并发控制文档

## 库变体

- **libpcp.so.4**：当前版本（PMAPI_VERSION_4），用于 PCP 7.0 及更高版本
- **libpcp.so.3**：旧版本（PMAPI_VERSION_2），在 `src/libpcp3/` 中维护
- **libpcp_fault**：带有故障注入的开发/测试变体（参见 `src/libpcp_fault/`）

## 许可证

本库是自由软件；您可以根据自由软件基金会发布的 GNU 宽通用公共许可证（版本 2.1 或您选择的任何更高版本）的条款重新分发和/或修改它。
