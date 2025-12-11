# derive_fetch.c 中 eval_expr() 函数深度分析

## 概述

`eval_expr()` 函数是 PCP 派生指标的**核心递归求值引擎**。它遍历表示派生指标公式的表达式树（抽象语法树），并通过以下方式计算结果值：

1. 递归求值子节点（左右操作数）
2. 执行当前节点指定的操作
3. 管理跨多个实例的实例-值对
4. 处理需要历史数据的时间操作（delta、rate）

**位置**：`src/libpcp/src/derive_fetch.c`（第 817-1973 行，约 1156 行）

## 函数签名

```c
int eval_expr(__pmContext *ctxp, node_t *np, struct timespec *stamp, 
              int numpmid, pmValueSet **vset, int level)
```

### 参数

| 参数 | 类型 | 描述 |
|------|------|------|
| `ctxp` | `__pmContext *` | 当前 PCP 上下文（实时或归档） |
| `np` | `node_t *` | 要求值的表达式树节点 |
| `stamp` | `struct timespec *` | 本次求值的当前时间戳 |
| `numpmid` | `int` | vset 数组中的 PMID 数量 |
| `vset` | `pmValueSet **` | 来自 pmFetch 的值集数组（原始指标数据） |
| `level` | `int` | 递归深度（用于调试） |

### 返回值

返回此节点的值数量（`numval`）：
- **> 0**：成功计算的实例-值对数量
- **0**：无可用值（有效状态）
- **< 0**：错误代码（PM_ERR_* 常量）

## 架构

### 表达式树结构

每个 `node_t` 代表表达式树中的一个操作或值：

```
示例：rate(disk.dev.read + disk.dev.write)
树结构：
         N_RATE
            |
         N_PLUS
         /     \
    N_NAME    N_NAME
    (read)    (write)
```

### 节点类型（主要类别）

1. **叶节点**：`N_INTEGER`、`N_DOUBLE`、`N_NAME`（实际指标）
2. **一元运算符**：`N_NEG`、`N_NOT`、`N_DELTA`、`N_RATE`
3. **二元运算符**：`N_PLUS`、`N_MINUS`、`N_MULTIPLY`、`N_DIVIDE` 等
4. **聚合**：`N_AVG`、`N_SUM`、`N_MIN`、`N_MAX`、`N_COUNT`
5. **条件**：`N_QUEST`（三元 ?:）、`N_COLON`
6. **过滤**：`N_FILTERINST`、`N_PATTERN`
7. **特殊**：`N_RESCALE`、`N_INSTANT`、`N_DEFINED`、`N_NOVALUE`

## 详细操作流程

### 阶段 1：递归求值操作数（第 828-854 行）

```c
// 先求值左操作数（如果存在且应该求值）
if (np->left != NULL && /* 条件... */) {
    sts = eval_expr(ctxp, np->left, stamp, numpmid, vset, level+1);
    if (sts < 0) return sts;  // 传播错误（count() 除外）
}

// 然后求值右操作数（如果存在且应该求值）
if (np->right != NULL && /* 条件... */) {
    sts = eval_expr(ctxp, np->right, stamp, numpmid, vset, level+1);
    if (sts < 0) return sts;
}
```

**关键点**：
- **后序遍历**：叶节点在父节点之前求值
- **count() 短路**：操作数中的错误对于 count() 映射为 0
- **条件绑定**：三元运算符 (?) 可能跳过操作数求值

### 阶段 2：节点特定处理（第 863-1970 行）

一个大型 `switch` 语句处理每种节点类型。让我们检查最重要的情况：

## 节点类型处理器

### 1. 常量：N_INTEGER、N_DOUBLE（第 865-869 行）

**目的**：表达式中的常量值（例如 `100 - cpu.idle` 中的 `100`）

```c
case N_INTEGER:
case N_DOUBLE:
    save_ivlist(np);          // 保存先前的值
    adjust_constant(ctxp, np); // 根据需要调整实例域
    return np->data.info->numval;
```

**关键操作**：
- `save_ivlist()`：保留先前的值（用于多次采样）
- `adjust_constant()`：如果需要，跨所有实例复制常量值
  - 如果指标有实例 (PM_INDOM)，常量在每个实例上复制
  - 否则，保持单个值

### 2. 时间操作：N_DELTA、N_RATE（第 871-1037 行）

**目的**：计算连续样本之间的差值或速率

**Delta**：`value[now] - value[prev]`
**Rate**：`(value[now] - value[prev]) / time_delta`

```c
case N_DELTA:
case N_RATE:
    // 保存时间戳
    np->data.info->last_stamp = np->data.info->stamp;
    np->data.info->stamp = *stamp;
    
    // 分配结果数组（当前和先前 numval 的最小值）
    np->data.info->numval = min(current_numval, previous_numval);
    
    // 匹配样本之间的实例
    for (i = k = 0; i < current_numval; i++) {
        // 在先前样本中查找匹配的实例
        j = find_matching_inst(current[i].inst, previous);
        
        if (found) {
            if (N_DELTA) {
                result[k] = current[i].value - previous[j].value;
            }
            else { // N_RATE
                delta = current[i].value - previous[j].value;
                time_diff = stamp - last_stamp;
                result[k] = delta / time_diff;
                
                // 计数器语义：跳过非单调值
                if (is_counter && current[i] < previous[j])
                    continue;  // 不包括此实例
            }
            k++;
        }
    }
    np->data.info->numval = k;
```

**关键特性**：
- **实例匹配**：处理动态实例域（例如进程）
- **计数器语义**：对于 `PM_SEM_COUNTER` 指标，过滤非单调减少
- **类型处理**：支持所有数值类型（32/U32/64/U64/FLOAT/DOUBLE）
- **时间利用率**：对于时间计数器 (dimTime==1)，缩放为利用率百分比

### 3. 一元运算符：N_NOT、N_NEG（第 1039-1113 行）

**目的**：逻辑否定 (`!`) 和算术否定 (`-`)

```c
case N_NOT:  // 布尔 NOT: !expr
    for (i = 0; i < numval; i++) {
        result[i].value = (left[i].value == 0) ? 1 : 0;  // 转换为布尔值
        result[i].inst = left[i].inst;
    }
    
case N_NEG:  // 算术否定: -expr
    for (i = 0; i < numval; i++) {
        result[i].value = -left[i].value;  // 类型特定的否定
        result[i].inst = left[i].inst;
    }
```

### 4. 三元运算符：N_QUEST（第 1119-1320 行）

**目的**：条件表达式 `guard ? true_expr : false_expr`

```c
case N_QUEST:
    // 复杂的绑定逻辑确定求值哪个分支
    for (i = 0; i < numval; i++) {
        // 对实例 i 求值守卫
        if (guard[i] != 0)
            pick = true_expr;
        else
            pick = false_expr;
            
        // 从选择的表达式复制值
        result[i] = pick->ivlist[i];
        result[i].inst = indom_source->ivlist[i].inst;
    }
```

**特殊功能**：
- **惰性求值**：QUEST_BIND_LEFT/RIGHT 标志控制哪些分支执行
- **实例域处理**：结果从非单一操作数继承 indom
- **novalue() 支持**：处理特殊的 `novalue()` 伪指标

### 5. 重新缩放：N_RESCALE（第 1322-1344 行）

**目的**：转换指标单位（例如 KB 到 MB，秒到毫秒）

```c
case N_RESCALE:
    for (i = 0, j = 0; i < numval; i++) {
        sts = pmConvScale(np->desc.type,
                         &left[i].value, &left_units,
                         &result[j].value, &target_units);
        if (sts >= 0)  // 仅包括成功的转换
            j++;
    }
    np->data.info->numval = j;  // 可能少于输入
```

### 6. 聚合函数：N_AVG、N_SUM、N_MIN、N_MAX、N_COUNT（第 1359-1568 行）

**目的**：将多个实例减少为单个值

```c
case N_SUM:
    result[0].value = 0;
    for (i = 0; i < left->numval; i++) {
        result[0].value += left[i].value;
    }
    result[0].inst = PM_IN_NULL;  // 单一实例
    numval = 1;

case N_AVG:
    result[0].value = 0;
    for (i = 0; i < left->numval; i++) {
        result[0].value += left[i].value / left->numval;
    }

case N_MIN / N_MAX:
    result[0].value = left[0].value;  // 初始化
    for (i = 1; i < left->numval; i++) {
        if (left[i].value < result[0].value)  // 或 > 用于 MAX
            result[0].value = left[i].value;
    }

case N_COUNT:
    result[0].value = left->numval;  // 只计数实例
```

**输出**：总是产生恰好 1 个值，`inst = PM_IN_NULL`

### 7. 指标获取：N_NAME（第 1570-1656 行）

**目的**：从 pmResult 中提取特定指标的值

```c
case N_NAME:
    // 在 vset 数组中查找此指标的 PMID
    for (j = 0; j < numpmid; j++) {
        if (np->data.info->pmid == vset[j]->pmid) {
            // 分配并复制值
            numval = vset[j]->numval;
            allocate_ivlist(numval);
            
            for (i = 0; i < numval; i++) {
                ivlist[i].inst = vset[j]->vlist[i].inst;
                
                // 类型特定的提取
                switch (type) {
                    case PM_TYPE_32/U32:
                        ivlist[i].value.l = vset[j]->vlist[i].value.lval;
                        break;
                    case PM_TYPE_64/U64:
                        memcpy(&ivlist[i].value.ll, vset[j]->vlist[i].value.pval->vbuf, 8);
                        break;
                    case PM_TYPE_STRING:
                        // 分配并复制字符串
                        allocate_and_copy_string();
                        break;
                    case PM_TYPE_AGGREGATE:
                        // 深拷贝 pmValueBlock
                        deep_copy_valueblock();
                        break;
                }
            }
            return numval;
        }
    }
    return PM_ERR_PMID;  // PMID 未找到
```

**关键操作**：
- 将表达式树中的 PMID 与获取的数据匹配
- 处理不同的值格式（INSITU、DPTR、SPTR）
- 对字符串和聚合执行深拷贝

### 8. 实例过滤：N_FILTERINST（第 1670-1807 行）

**目的**：基于模式过滤实例 `metric[instance_pattern]`

**两种模式**：

#### A. 正则表达式 (F_REGEX)
```c
// 示例：disk.dev.total["sd.*"]
for (i = 0; i < right->numval; i++) {
    // 从 indom 获取实例名称
    pmNameInDom(indom, right->ivlist[i].inst, &iname);
    
    // 检查正则表达式匹配（使用哈希缓存提高性能）
    if (regexec(&pattern->regex, iname, 0, NULL, 0) == 0) {
        // 包括此实例
        result[k++] = right->ivlist[i];
    }
}
```

**优化**：使用哈希表缓存每个实例的正则表达式匹配

#### B. 精确匹配 (F_EXACT)
```c
// 示例：disk.dev.total["sda"]
// 查找特定实例
inst_id = pmLookupInDom(indom, "sda");
for (i = 0; i < right->numval; i++) {
    if (right->ivlist[i].inst == inst_id) {
        result[0] = right->ivlist[i];
        numval = 1;
        break;
    }
}
```

### 9. 二元运算符：默认情况（第 1817-1969 行）

**目的**：算术和比较运算符（+、-、*、/、<、>、== 等）

```c
default:  // 二元运算符：+, -, *, /, <, >, ==, !=, &&, ||
    // 根据操作数 indom 确定结果 numval
    if (left->indom == PM_INDOM_NULL)
        numval = right->numval;  // 标量 <op> 向量
    else if (right->indom == PM_INDOM_NULL)
        numval = left->numval;   // 向量 <op> 标量
    else
        numval = min(left->numval, right->numval);  // 向量 <op> 向量
    
    // 对每个匹配的实例对执行操作
    for (i = j = k = 0; k < numval; ) {
        // 如果两者都有 indom，匹配实例
        if (both_have_indom && left[i].inst != right[j].inst) {
            // 搜索匹配的实例
            j = find_match(left[i].inst, right);
            if (not_found) {
                i++; 
                continue;
            }
        }
        
        // 执行操作
        if (is_relational_or_boolean_op) {
            // 提升类型，计算，将结果转换为 U32
            promoted_result = bin_op(promoted_type, op, left[i], right[j]);
            result[k].value = (U32)promoted_result;
        }
        else {
            // 算术：在结果类型中执行
            result[k].value = bin_op(result_type, op, left[i], right[j]);
        }
        
        // 设置结果实例
        result[k].inst = non_null_indom_operand[...].inst;
        
        k++;
        advance_indices(i, j);
    }
```

**关键特性**：
- **实例匹配**：对齐操作数之间的实例
- **类型提升**：关系操作使用提升的类型然后转换为 U32
- **缩放**：应用 mul_scale/div_scale 进行单位转换
- **广播**：标量在所有实例上广播

## 内存管理

### 实例-值列表 (ivlist) 管理

```c
typedef struct {
    int         inst;      // 实例标识符
    pmAtomValue value;     // 值（所有类型的联合）
    int         vlen;      // 可变长度类型的长度
} val_t;
```

**关键函数**：
- `save_ivlist()`：将当前 ivlist 保存到 last_ivlist（用于 delta/rate）
- `free_ivlist()`：在重新分配前释放当前 ivlist
- `pmNoMem()`：分配失败的致命错误处理程序

**生命周期**：
1. **分配**：`malloc(numval * sizeof(val_t))`
2. **填充**：复制/计算值
3. **保留**：对于时间操作，保存到 `last_ivlist`
4. **释放**：下次求值前 `free_ivlist()`

### 字符串和聚合处理

```c
// 字符串：需要深拷贝
case PM_TYPE_STRING:
    ivlist[i].value.cp = malloc(string_len);
    memcpy(ivlist[i].value.cp, source_string, string_len);
    ivlist[i].vlen = string_len;

// 聚合：深拷贝 pmValueBlock
case PM_TYPE_AGGREGATE:
    ivlist[i].value.vbp = malloc(vblock_len);
    memcpy(ivlist[i].value.vbp, source_vblock, vblock_len);
    ivlist[i].vlen = vblock_len;
```

## 实例域处理

### 三种场景

1. **两个操作数都是单一的** (`PM_INDOM_NULL`)
   - 结果是单一的
   - 简单的标量操作

2. **一个单一，一个有实例**
   - 结果具有来自非单一操作数的实例
   - 单一值在所有实例上广播
   - 示例：`3.14 * disk.dev.read` 广播 3.14

3. **两者都有实例**
   - 实例必须跨操作数匹配
   - 搜索/匹配逻辑处理未对齐的实例
   - 结果仅包含匹配的实例

### 实例匹配算法

```c
// 对于左操作数中的每个实例
for (i = 0; i < left->numval; i++) {
    // 在右操作数中查找匹配的实例
    for (j = 0; j < right->numval; j++) {
        if (left[i].inst == right[j].inst) {
            // 找到匹配 - 执行操作
            result[k++] = op(left[i], right[j]);
            break;
        }
    }
    // 如果没有匹配，实例从结果中省略
}
```

## 类型系统

### 类型提升矩阵

二元操作使用提升表：

```c
// promote[left_type][right_type] -> result_type
// 示例：32 位 + 64 位 -> 64 位
PM_TYPE_32  + PM_TYPE_64  -> PM_TYPE_64
PM_TYPE_U64 + PM_TYPE_U64 -> PM_TYPE_DOUBLE（避免溢出）
PM_TYPE_FLOAT + PM_TYPE_64 -> PM_TYPE_DOUBLE
```

### 特殊情况

- **关系运算符**（==、<、> 等）：总是返回 `PM_TYPE_U32`（0 或 1）
- **布尔运算符**（&&、||）：返回 `PM_TYPE_U32`（0 或 1）
- **Delta**：结果类型与操作数类型相同（除了 U32 -> 64，U64 -> DOUBLE）
- **Rate**：总是返回 `PM_TYPE_DOUBLE`

## 性能优化

### 1. 正则表达式匹配的哈希表
```c
// 缓存正则表达式匹配以避免重复的正则表达式求值
__pmHashNode *hp = __pmHashSearch(inst, &pattern->hash);
if (hp == NULL) {
    // 首次 - 求值正则表达式并缓存结果
    evaluate_and_cache();
} else {
    // 使用缓存的结果
    ip = (instctl_t *)hp->data;
}
```

### 2. 实例压缩
```c
// 定期垃圾收集未使用的正则表达式匹配缓存条目
if (pattern->used >= REGEX_INST_COMPACT)
    regex_inst_gc(pattern);
```

### 3. 早期退出条件
```c
// 如果没有值，不分配
if (numval <= 0)
    return 0;

// 如果操作数没有值，跳过计算
if (left->numval <= 0 || right->numval <= 0) {
    np->data.info->numval = 0;
    return 0;
}
```

## 错误处理

### 错误传播

```c
// 递归求值错误向上冒泡
sts = eval_expr(ctxp, np->left, ...);
if (sts < 0) {
    if (np->type == N_COUNT) {
        // 特殊情况：count() 将错误视为 0
        return 0;
    }
    return sts;  // 传播错误
}
```

### 常见错误代码

| 错误代码 | 含义 | 上下文 |
|----------|------|--------|
| `PM_ERR_PMID` | 未找到指标 PMID | N_NAME 当 PMID 不在 vset 中 |
| `PM_ERR_TYPE` | 无效的数据类型 | 类型转换错误 |
| `PM_ERR_CONV` | 转换错误 | 单位缩放失败 |
| `PM_ERR_LOGREC` | 日志记录格式错误 | 类型的 valfmt 错误 |

## 调试支持

### 调试输出级别

```c
if (pmDebugOptions.derive && pmDebugOptions.appl2) {
    fprintf(stderr, "eval_expr: %s: inst[%d] mismatch ...\n",
            __dmnode_type_str(np->type), k, ...);
}

if (pmDebugOptions.derive && pmDebugOptions.desperate) {
    fprintf(stderr, "eval_expr: ? bind %d values: ...\n", ...);
}
```

**标志**：
- `derive`：启用派生指标调试
- `appl2`：应用程序级详细信息（实例匹配等）
- `desperate`：最大详细程度（三元运算符逻辑等）

## 示例

### 示例 1：简单算术

**表达式**：`disk.dev.read + disk.dev.write`

```
执行流程：
1. eval_expr(N_PLUS 节点)
2.   eval_expr(N_NAME "disk.dev.read")  -> 从 vset 提取
3.   eval_expr(N_NAME "disk.dev.write") -> 从 vset 提取
4. 对匹配的实例执行二元 + 操作
5. 返回组合值的结果
```

### 示例 2：速率计算

**表达式**：`rate(network.interface.in.bytes)`

```
执行流程（第 2 次采样起）：
1. eval_expr(N_RATE 节点)
2.   eval_expr(N_NAME "network.interface.in.bytes") -> 当前值
3. 匹配当前和保存的先前值之间的实例
4. 对于每个匹配的实例：
     delta = current - previous
     time_diff = current_stamp - last_stamp
     result = delta / time_diff
5. 处理计数器语义（跳过非单调）
6. 保存当前值作为下次采样的先前值
```

### 示例 3：聚合

**表达式**：`sum(disk.dev.total["sd.*"])`

```
执行流程：
1. eval_expr(N_SUM 节点)
2.   eval_expr(N_FILTERINST 节点)
3.     eval_expr(N_NAME "disk.dev.total") -> 所有实例
4.     eval_expr(N_PATTERN "sd.*")        -> 正则表达式模式
5.   过滤：仅保留匹配 "sd.*" 的实例
6. 聚合：对所有匹配的实例值求和
7. 返回单一值（inst = PM_IN_NULL）
```

### 示例 4：条件表达式

**表达式**：`kernel.all.cpu.user > 80 ? 1 : 0`

```
执行流程：
1. eval_expr(N_QUEST 节点)
2.   eval_expr(N_GT 节点) [守卫]
3.     eval_expr(N_NAME "kernel.all.cpu.user")
4.     eval_expr(N_INTEGER 80)
5.   比较：user > 80 ?（返回 0 或 1）
6.   eval_expr(N_INTEGER 1) [真分支]
7.   eval_expr(N_INTEGER 0) [假分支]
8. 对于每个实例：如果守卫!=0 选择 true_branch，否则 false_branch
9. 返回选择的值
```

## 表达式作者的最佳实践

1. **理解实例域**：混合具有不同 indom 的指标需要小心
2. **计数器语义**：对计数器使用 `rate()`，了解它过滤非单调值
3. **类型意识**：知道 U64 delta/rate 提升以避免溢出
4. **性能**：避免在高频表达式中使用复杂的正则表达式模式
5. **空值检查**：表达式可能返回 0 个值（不是错误）

## 与其他函数的关系

- **被调用于**：`__dmpostfetch()` - 主要的后获取处理函数
- **调用**：`bin_op()` - 使用类型处理执行二元操作
- **使用**：`pmConvScale()` - 单位转换
- **使用**：`pmNameInDom_ctx()`、`pmLookupInDom_ctx()` - 实例名称解析

## 总结

`eval_expr()` 是一个复杂的递归求值器，它：

✅ **处理** 20 多种节点类型，涵盖常量、指标、运算符和函数  
✅ **管理** 跨动态实例域的实例-值对  
✅ **支持** 需要历史状态的时间操作  
✅ **实现** 类型提升和单位转换  
✅ **优化** 正则表达式匹配和内存分配  
✅ **提供** 全面的错误处理和调试  

它是 **PCP 派生指标系统的核心**，使强大的指标转换和计算完全在客户端进行，而无需修改 PMDA。
