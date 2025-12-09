# __dmpostvalueset() 函数详细分析

## 函数签名

```c
int __dmpostvalueset(__pmContext *ctxp, struct timespec *stamp, 
                     int vnumpmid, pmValueSet **vset, 
                     int numpmid, pmValueSet **newvset)
```

## 函数目的

`__dmpostvalueset()` 是派生指标处理的核心函数之一，负责在 `pmFetch()` 操作后重写结果集。它的主要作用是：

1. **检查每个指标**是否为派生指标
2. **计算派生指标的值**（如果是派生指标）
3. **创建新的值集**（`pmValueSet`），包含原始指标值或计算出的派生指标值
4. **正确处理内存分配**和不同的数据类型

## 参数说明

- **ctxp**: 当前的 PCP 上下文指针，包含派生指标定义
- **stamp**: 时间戳（用于表达式求值）
- **vnumpmid**: 原始获取的值集数量（来自 PMCD/归档）
- **vset**: 原始值集数组（输入）
- **numpmid**: 请求的指标数量（应该与原始 `pmFetch()` 调用匹配）
- **newvset**: 新的值集数组（输出），将填充重写后的值

## 返回值

返回失败的派生指标数量（0 表示全部成功）。

## 详细工作流程

### 第一层循环：遍历所有请求的指标（j = 0 到 numpmid）

```c
for (j = 0; j < numpmid; j++) {
```

对于每个指标：

#### 步骤 1: 初始化变量

```c
numval = vset[j]->numval;    // 实例数量
valfmt = vset[j]->valfmt;    // 值格式（INSITU/DPTR/SPTR）
rewrite = 0;                 // 是否需要重写标志
```

#### 步骤 2: 检查是否为派生指标

```c
if (IS_DERIVED(vset[j]->pmid)) {
```

如果是派生指标：
- 在派生指标列表中查找此 PMID
- 如果没有表达式 → 设置 `numval = PM_ERR_PMID`（错误）
- 如果有表达式：
  - 设置 `rewrite = 1`
  - 根据结果类型设置 `valfmt`：
    - `PM_TYPE_32` 或 `PM_TYPE_U32` → `PM_VAL_INSITU`（值直接存储在结构中）
    - 其他类型 → `PM_VAL_DPTR`（值通过指针存储）
  - **调用 `eval_expr()`** 计算表达式，返回实例数量

#### 步骤 3: 为新值集分配内存

```c
if (numval <= 0) {
    // 错误情况：只需要 pmid 和 numval 字段
    need = sizeof(pmValueSet) - sizeof(pmValue);
} else {
    // 正常情况：需要存储 numval 个值
    need = sizeof(pmValueSet) + (numval - 1)*sizeof(pmValue);
}
newvset[j] = (pmValueSet *)malloc(need);
```

#### 步骤 4: 填充基本字段

```c
newvset[j]->pmid = vset[j]->pmid;
newvset[j]->numval = numval;
newvset[j]->valfmt = valfmt;
```

### 第二层循环：处理每个实例的值（i = 0 到 numval）

```c
for (i = 0; i < numval; i++) {
```

这里有两种路径：

#### 路径 A: 非派生指标（!rewrite）

这是简单的复制操作：

```c
if (!rewrite) {
    newvset[j]->vlist[i].inst = vset[j]->vlist[i].inst;
    
    if (vset[j]->valfmt == PM_VAL_DPTR || vset[j]->valfmt == PM_VAL_SPTR) {
        // 指针类型：需要深拷贝 pmValueBlock
        need = vset[j]->vlist[i].value.pval->vlen;
        vp = (pmValueBlock *)malloc(need);
        memcpy(vp, vset[j]->vlist[i].value.pval, need);
        newvset[j]->vlist[i].value.pval = vp;
        
        // 特殊处理：SPTR 改为 DPTR（避免内存泄漏）
        if (vset[j]->valfmt == PM_VAL_SPTR)
            newvset[j]->valfmt = PM_VAL_DPTR;
    } else {
        // INSITU 类型：直接复制值
        newvset[j]->vlist[i].value.lval = vset[j]->vlist[i].value.lval;
    }
}
```

**关键点**：
- `PM_VAL_DPTR` = 动态分配的指针（需要 free）
- `PM_VAL_SPTR` = 静态缓冲区指针（不应 free）
- `PM_VAL_INSITU` = 值内联存储（32 位整数）

#### 路径 B: 派生指标（rewrite == 1）

这是复杂的重写操作，根据数据类型处理：

```c
newvset[j]->vlist[i].inst = cp->mlist[m].expr->data.info->ivlist[i].inst;
```

然后根据派生指标的类型（`cp->mlist[m].expr->desc.type`）进行不同处理：

##### 1. PM_TYPE_32 / PM_TYPE_U32（32 位整数）

```c
case PM_TYPE_32:
case PM_TYPE_U32:
    // 直接复制到 lval（INSITU 格式）
    newvset[j]->vlist[i].value.lval = 
        cp->mlist[m].expr->data.info->ivlist[i].value.l;
    break;
```

##### 2. PM_TYPE_64 / PM_TYPE_U64（64 位整数）

```c
case PM_TYPE_64:
case PM_TYPE_U64:
    need = PM_VAL_HDR_SIZE + sizeof(__int64_t);  // 头部 + 8 字节
    vp = (pmValueBlock *)malloc(need);
    vp->vlen = need;
    vp->vtype = cp->mlist[m].expr->desc.type;
    memcpy(vp->vbuf, &cp->mlist[m].expr->data.info->ivlist[i].value.ll, 
           sizeof(__int64_t));
    newvset[j]->vlist[i].value.pval = vp;
    break;
```

##### 3. PM_TYPE_FLOAT（浮点数）

```c
case PM_TYPE_FLOAT:
    need = PM_VAL_HDR_SIZE + sizeof(float);  // 头部 + 4 字节
    vp = (pmValueBlock *)malloc(need);
    vp->vlen = need;
    vp->vtype = PM_TYPE_FLOAT;
    memcpy(vp->vbuf, &cp->mlist[m].expr->data.info->ivlist[i].value.f, 
           sizeof(float));
    newvset[j]->vlist[i].value.pval = vp;
    break;
```

##### 4. PM_TYPE_DOUBLE（双精度浮点数）

```c
case PM_TYPE_DOUBLE:
    need = PM_VAL_HDR_SIZE + sizeof(double);  // 头部 + 8 字节
    vp = (pmValueBlock *)malloc(need);
    vp->vlen = need;
    vp->vtype = PM_TYPE_DOUBLE;
    // 注意：这里有个 bug，应该是 .d 而不是 .f
    memcpy(vp->vbuf, &cp->mlist[m].expr->data.info->ivlist[i].value.f, 
           sizeof(double));
    newvset[j]->vlist[i].value.pval = vp;
    break;
```

##### 5. PM_TYPE_STRING（字符串）

```c
case PM_TYPE_STRING:
    need = PM_VAL_HDR_SIZE + cp->mlist[m].expr->data.info->ivlist[i].vlen;
    vp = (pmValueBlock *)malloc(need);
    vp->vlen = need;
    vp->vtype = cp->mlist[m].expr->desc.type;
    memcpy(vp->vbuf, cp->mlist[m].expr->data.info->ivlist[i].value.cp, 
           cp->mlist[m].expr->data.info->ivlist[i].vlen);
    newvset[j]->vlist[i].value.pval = vp;
    break;
```

##### 6. PM_TYPE_AGGREGATE / PM_TYPE_EVENT（聚合/事件类型）

```c
case PM_TYPE_AGGREGATE:
case PM_TYPE_AGGREGATE_STATIC:
case PM_TYPE_EVENT:
case PM_TYPE_HIGHRES_EVENT:
    need = cp->mlist[m].expr->data.info->ivlist[i].vlen;
    vp = (pmValueBlock *)malloc(need);
    memcpy(vp, cp->mlist[m].expr->data.info->ivlist[i].value.vbp, need);
    newvset[j]->vlist[i].value.pval = vp;
    break;
```

## 数据结构说明

### pmValueSet 结构
```c
typedef struct {
    pmID    pmid;      // 指标标识符
    int     numval;    // 值的数量（实例数）
    int     valfmt;    // 值格式（INSITU/DPTR/SPTR）
    pmValue vlist[1];  // 值数组（实际大小可变）
} pmValueSet;
```

### pmValue 结构
```c
typedef struct {
    int inst;          // 实例标识符
    union {
        int         lval;  // INSITU: 直接存储的值
        pmValueBlock *pval; // DPTR/SPTR: 指向值块的指针
    } value;
} pmValue;
```

### pmValueBlock 结构
```c
typedef struct {
    unsigned int vlen;   // 块的总长度
    int         vtype;   // 值类型
    char        vbuf[1]; // 值缓冲区（实际大小可变）
} pmValueBlock;
```

## 关键设计决策

1. **内存管理**：
   - 函数为所有 DPTR 类型分配新内存
   - 将 SPTR（静态指针）转换为 DPTR（动态指针）以便正确释放
   - 使用 `pmNoMem()` 处理内存分配失败（致命错误）

2. **类型优化**：
   - 32 位整数使用 INSITU 格式（无需额外分配）
   - 其他类型使用 DPTR 格式（需要 pmValueBlock）

3. **错误处理**：
   - 跟踪失败计数（`fails`）
   - 为缺少表达式的派生指标设置 `PM_ERR_PMID`

4. **调试支持**：
   - 使用 `pmDebugOptions.derive` 和 `pmDebugOptions.appl2` 进行详细跟踪
   - 打印每个值和实例信息

## 使用场景示例

假设有派生指标：
```
disk.util = 100 * rate(disk.dev.total)
```

当 `pmFetch()` 请求 `disk.util` 时：

1. `__dmprefetch()` 扩展请求列表，添加 `disk.dev.total`
2. PMCD 返回 `disk.dev.total` 的原始值
3. `__dmpostfetch()` 调用 `__dmpostvalueset()`
4. 对于 `disk.util`：
   - 检测到是派生指标（`rewrite = 1`）
   - 调用 `eval_expr()` 计算 `100 * rate(disk.dev.total)`
   - 为每个磁盘实例创建新值
   - 根据结果类型（可能是 DOUBLE）分配 pmValueBlock
   - 将计算值复制到新的值集

## 性能考虑

- 为每个派生指标值分配内存（可能较慢）
- 使用 memcpy 进行数据复制（高效）
- 只在需要时才重写（`rewrite` 标志）
- 非派生指标的开销最小（简单复制）

## 潜在问题

1. **内存泄漏风险**：如果调用者不正确释放结果
2. **类型错误**：PM_TYPE_DOUBLE case 中使用 `.f` 而不是 `.d`（可能是 bug）
3. **错误传播**：失败计数可能被忽略

## 总结

`__dmpostvalueset()` 是派生指标实现的关键部分，它：
- 透明地处理派生和非派生指标
- 正确管理复杂的内存分配
- 支持所有 PCP 数据类型
- 确保结果格式对调用者透明

这个函数使得派生指标对应用程序完全透明 - 它们看起来就像真实指标一样。
