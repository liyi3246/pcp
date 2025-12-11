# __dmpostfetch() 函数分析

## 概述

`__dmpostfetch()` 是 PCP libpcp 库中派生指标的**后处理函数**。它在 `pmFetch()` 之后调用，将包含基础指标和派生指标占位符的原始 `pmResult` 转换为包含计算出的派生指标值的最终 `pmResult`。

**位置**: `src/libpcp/src/derive_fetch.c`

## 函数签名

```c
void __dmpostfetch(__pmContext *ctxp, __pmResult **result)
```

### 参数

- **`ctxp`**: 指向 PCP 上下文的指针 (`__pmContext`)
  - 包含派生指标控制结构 (`c_dm`)
  - 为指标评估和调试提供上下文
  
- **`result`**: 指向 `__pmResult` 指针的指针
  - **输入**: 包含基础指标的原始 fetch 结果
  - **输出**: 包含计算出的派生指标的转换后结果
  - 函数原地修改 `*result`

### 返回值

- **`void`**: 无返回值（直接修改 `*result`）

## 目的

该函数是派生指标流水线的**最后一步**：

1. **预获取** (`__dmprefetch`): 扩展 pmID 列表以包含操作数指标
2. **获取**: 从 PMDA 获取基础指标值
3. **后处理** (`__dmpostfetch`): **从基础值计算派生指标** ← 本函数

## 工作流程

### 步骤 1: 提前退出检查

```c
ctl_t *cp = (ctl_t *)ctxp->c_dm;

if (cp == NULL || cp->fetch_has_dm == 0)
    return;
```

**快速路径优化**:
- 如果没有派生指标上下文 (`cp == NULL`)
- 或者 fetch 不包含派生指标 (`fetch_has_dm == 0`)
- **立即退出**，不进行处理

### 步骤 2: 调试输出（可选）

```c
if (pmDebugOptions.derive && pmDebugOptions.desperate) {
    fprintf(stderr, "__dmpostfetch: from context before rewrite ...\n");
    __pmPrintResult_ctx(ctxp, stderr, rp);
}
```

**启用时**: 在转换前打印原始 pmResult

### 步骤 3: 分配新的 pmResult

```c
__pmResult *rp = *result;
__pmResult *newrp;

if ((newrp = __pmAllocResult(cp->numpmid)) == NULL) {
    pmNoMem("__dmpostfetch: newrp", 
            sizeof(__pmResult) + (cp->numpmid - 1) * sizeof(pmValueSet *), 
            PM_FATAL_ERR);
}
newrp->numpmid = cp->numpmid;
newrp->timestamp = rp->timestamp;
```

**关键点**:
- 分配包含 `cp->numpmid` 个条目的新 pmResult
  - `cp->numpmid`: 原始 fetch 数量（操作数扩展前）
  - 这将 pmResult 恢复到原始请求的指标数量
- 从原始结果复制时间戳
- 分配失败则致命错误

### 步骤 4: 计算派生指标

```c
struct timespec timestamp;
timestamp.tv_sec = rp->timestamp.sec;
timestamp.tv_nsec = rp->timestamp.nsec;

fails = __dmpostvalueset(ctxp, &timestamp, 
                         rp->numpmid, rp->vset,
                         newrp->numpmid, newrp->vset);
```

**核心计算**:
- 调用 `__dmpostvalueset()` 来:
  - 遍历原始请求中的所有指标
  - 对于**基础指标**: 直接复制值
  - 对于**派生指标**: 使用操作数值评估表达式
  - 用结果填充 `newrp->vset[]`
- 返回失败评估的计数

### 步骤 5: 调试失败指标（可选）

```c
if (fails > 0 && pmDebugOptions.derive)
    __pmPrintResult_ctx(ctxp, stderr, rp);
```

**发生错误时**: 打印原始结果用于调试

### 步骤 6: 替换结果

```c
__pmFreeResult(rp);
*result = newrp;
```

**最后一步**:
- 释放原始（原始）pmResult
- 用转换后的 pmResult 替换 `*result`
- 调用者现在拥有计算好的派生指标

## 数据流

### 输入 pmResult（来自 fetch）
```
pmResult (包含操作数的扩展版本):
├── vset[0]: disk.dev.read (基础指标)      ✓ 已获取
├── vset[1]: disk.dev.write (基础指标)     ✓ 已获取
├── vset[2]: disk.dev.total (派生)         ✗ PM_ERR_NOAGENT
└── vset[3]: some.other.metric (基础)      ✓ 已获取
```

### __dmpostvalueset() 处理
```
对原始请求中的每个指标 (cp->numpmid):
  - disk.dev.total (派生):
    → 评估: disk.dev.read + disk.dev.write
    → 创建包含计算值的新 vset
```

### 输出 pmResult
```
pmResult (原始大小，包含派生值):
├── vset[0]: disk.dev.total                   ✓ 已计算
└── vset[1]: some.other.metric                ✓ 已复制
```

## 关键数据结构

### ctl_t（控制结构）
```c
typedef struct {
    int      numpmid;        // 原始 fetch 的 pmID 数量
    int      fetch_has_dm;   // 标志: fetch 包含派生指标
    int      nmetric;        // 定义的派生指标总数
    mlist_t  *mlist;         // 派生指标定义
} ctl_t;
```

### mlist_t（指标列表条目）
```c
typedef struct {
    pmID     pmid;           // 指标 ID
    int      flags;          // 绑定标志 (DM_BIND 等)
    node_t   *expr;          // 用于评估的表达式树
} mlist_t;
```

## 与其他函数的关系

### 调用链
```
pmFetch()
  ↓
__dmprefetch()              // 前: 扩展 pmID 列表
  ↓
[PMDA fetch 操作]           // 获取基础指标
  ↓
__dmpostfetch()             // 后: 计算派生指标 ← 本函数
  ↓
  └→ __dmpostvalueset()     // 实际计算
```

### 协作

**__dmprefetch()**:
- 保存 `cp->numpmid`（原始计数）
- 设置 `cp->fetch_has_dm` 标志
- 用操作数扩展 pmID 列表

**__dmpostfetch()**:
- 使用 `cp->numpmid` 恢复结果大小
- 检查 `cp->fetch_has_dm` 进行快速路径
- 将计算委托给 `__dmpostvalueset()`

**__dmpostvalueset()**:
- 遍历指标
- 评估派生指标表达式
- 处理实例匹配和类型转换

## 性能考虑

### 优化

1. **快速路径退出**
   - 检查 `fetch_has_dm` 标志
   - 如果没有派生指标则避免分配

2. **原地转换**
   - 修改 `*result` 指针
   - 避免额外的复制操作

3. **内存效率**
   - 立即释放旧结果
   - 精确分配 `cp->numpmid` 个条目

### 开销

- **内存**: 一次额外的 pmResult 分配（临时）
- **CPU**: `__dmpostvalueset()` 中的表达式评估
- 当没有派生指标时开销**最小**

## 错误处理

### 致命错误
```c
if ((newrp = __pmAllocResult(cp->numpmid)) == NULL) {
    pmNoMem(..., PM_FATAL_ERR);
    /* NOTREACHED */
}
```

**内存分配失败**: 终止程序

### 非致命错误

- `__dmpostvalueset()` 中的评估失败会被计数
- 失败的指标具有 `numval < 0`（错误码）
- 启用调试时打印到 stderr

## 调试

### 启用调试
```bash
export PCP_DEBUG=derive,desperate
pminfo -f my.derived.metric
```

### 调试输出

**转换前**:
```
__dmpostfetch: from context before rewrite ...
pmResult dump from 0x... timestamp: ...
  2 metrics:
    disk.dev.read[sda] = 1000
    disk.dev.write[sda] = 500
```

**失败后**（如果有）:
```
[打印显示基础指标值的原始结果]
```

## 使用示例

### 客户端代码
```c
pmID pmids[1] = {derived_metric_pmid};
pmResult *result;

// 使用派生指标进行 fetch
pmFetch(1, pmids, &result);

// 此时:
// 1. __dmprefetch() 已扩展 pmID 列表
// 2. 已获取基础指标
// 3. __dmpostfetch() 计算了派生值
// 4. result->vset[0] 包含计算出的值

// 使用结果
for (int i = 0; i < result->vset[0]->numval; i++) {
    printf("值: %d\n", result->vset[0]->vlist[i].value.lval);
}

pmFreeResult(result);
```

### 内部流程
```c
// 在 pmFetch() 实现内部:

// 预获取: 扩展 pmID 列表
int n = __dmprefetch(ctxp, numpmid, pmidlist, &newlist);

// 从 PMDA 获取
__pmResult *rp = fetch_from_pmdas(ctxp, n, newlist);

// 后处理: 计算派生指标
__dmpostfetch(ctxp, &rp);  // ← 原地转换 rp

return rp;  // 现在包含派生值
```

## 常见问题

### 问题: 派生指标返回 PM_ERR_NOAGENT

**原因**: `__dmpostfetch()` 未被调用或失败

**调试**:
```bash
export PCP_DEBUG=derive
pminfo -f metric.name
```

### 问题: 内存泄漏

**原因**: 旧 pmResult 未释放

**解决方案**: `__dmpostfetch()` 自动调用 `__pmFreeResult(rp)`

### 问题: 结果中的指标计数错误

**原因**: `__dmprefetch()` 中 `cp->numpmid` 设置不正确

**检查**: 确保在后处理前调用预处理

## 总结

`__dmpostfetch()` 是一个**简单的协调器**，它:

1. ✅ 验证上下文和快速路径
2. ✅ 分配新的 pmResult（原始大小）
3. ✅ 将计算委托给 `__dmpostvalueset()`
4. ✅ 用计算结果替换原始结果
5. ✅ 处理清理和调试

实际的复杂性在于 `__dmpostvalueset()`，它:
- 评估表达式树
- 跨指标匹配实例
- 处理类型转换
- 管理计算值的内存

**关键洞察**: 此函数是原始 PMDA 数据和用户可见的派生指标之间的**桥梁**，确保将计算的指标透明地集成到 PCP 的 fetch 流水线中。
