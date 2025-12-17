# Deep Analysis of eval_expr() Function in derive_fetch.c

## Overview

The `eval_expr()` function is the **core recursive evaluation engine** for derived metrics in PCP. It traverses an expression tree (Abstract Syntax Tree) representing a derived metric formula and computes the result values by:

1. Recursively evaluating child nodes (left and right operands)
2. Performing the operation specified by the current node
3. Managing instance-value pairs across multiple instances
4. Handling temporal operations (delta, rate) that require historical data

**Location**: `src/libpcp/src/derive_fetch.c` (lines 817-1973, ~1156 lines)

## Function Signature

```c
int eval_expr(__pmContext *ctxp, node_t *np, struct timespec *stamp, 
              int numpmid, pmValueSet **vset, int level)
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `ctxp` | `__pmContext *` | Current PCP context (live or archive) |
| `np` | `node_t *` | Expression tree node to evaluate |
| `stamp` | `struct timespec *` | Current timestamp for this evaluation |
| `numpmid` | `int` | Number of PMIDs in the vset array |
| `vset` | `pmValueSet **` | Array of value sets from pmFetch (raw metric data) |
| `level` | `int` | Recursion depth (for debugging) |

### Return Value

Returns the number of values (`numval`) for this node:
- **> 0**: Number of instance-value pairs successfully computed
- **0**: No values available (valid state)
- **< 0**: Error code (PM_ERR_* constants)

## Architecture

### Expression Tree Structure

Each `node_t` represents an operation or value in the expression tree:

```
Example: rate(disk.dev.read + disk.dev.write)
Tree Structure:
         N_RATE
            |
         N_PLUS
         /     \
    N_NAME    N_NAME
    (read)    (write)
```

### Node Types (Major Categories)

1. **Leaf Nodes**: `N_INTEGER`, `N_DOUBLE`, `N_NAME` (actual metrics)
2. **Unary Operators**: `N_NEG`, `N_NOT`, `N_DELTA`, `N_RATE`
3. **Binary Operators**: `N_PLUS`, `N_MINUS`, `N_MULTIPLY`, `N_DIVIDE`, etc.
4. **Aggregation**: `N_AVG`, `N_SUM`, `N_MIN`, `N_MAX`, `N_COUNT`
5. **Conditional**: `N_QUEST` (ternary ?:), `N_COLON`
6. **Filtering**: `N_FILTERINST`, `N_PATTERN`
7. **Special**: `N_RESCALE`, `N_INSTANT`, `N_DEFINED`, `N_NOVALUE`

## Detailed Operation Flow

### Phase 1: Recursive Evaluation of Operands (Lines 828-854)

```c
// Evaluate left operand first (if exists and should be evaluated)
if (np->left != NULL && /* conditions... */) {
    sts = eval_expr(ctxp, np->left, stamp, numpmid, vset, level+1);
    if (sts < 0) return sts;  // Propagate errors (except for count())
}

// Then evaluate right operand (if exists and should be evaluated)
if (np->right != NULL && /* conditions... */) {
    sts = eval_expr(ctxp, np->right, stamp, numpmid, vset, level+1);
    if (sts < 0) return sts;
}
```

**Key Points**:
- **Post-order traversal**: Leaves evaluated before parents
- **Short-circuit for count()**: Errors in operands map to 0 for count()
- **Conditional binding**: Ternary operator (?) may skip operand evaluation

### Phase 2: Node-Specific Processing (Lines 863-1970)

A large `switch` statement handles each node type. Let's examine the most important cases:

## Node Type Handlers

### 1. Constants: N_INTEGER, N_DOUBLE (Lines 865-869)

**Purpose**: Constant values in expressions (e.g., `100` in `100 - cpu.idle`)

```c
case N_INTEGER:
case N_DOUBLE:
    save_ivlist(np);          // Save previous values
    adjust_constant(ctxp, np); // Adjust for instance domain if needed
    return np->data.info->numval;
```

**Key Operations**:
- `save_ivlist()`: Preserve previous values (for multi-sampling)
- `adjust_constant()`: Replicate constant value across all instances if needed
  - If metric has instances (PM_INDOM), constant is replicated per instance
  - Otherwise, remains a single value

### 2. Temporal Operations: N_DELTA, N_RATE (Lines 871-1037)

**Purpose**: Compute differences or rates between consecutive samples

**Delta**: `value[now] - value[prev]`
**Rate**: `(value[now] - value[prev]) / time_delta`

```c
case N_DELTA:
case N_RATE:
    // Save timestamps
    np->data.info->last_stamp = np->data.info->stamp;
    np->data.info->stamp = *stamp;
    
    // Allocate result array (minimum of current and previous numval)
    np->data.info->numval = min(current_numval, previous_numval);
    
    // Match instances between samples
    for (i = k = 0; i < current_numval; i++) {
        // Find matching instance in previous sample
        j = find_matching_inst(current[i].inst, previous);
        
        if (found) {
            if (N_DELTA) {
                result[k] = current[i].value - previous[j].value;
            }
            else { // N_RATE
                delta = current[i].value - previous[j].value;
                time_diff = stamp - last_stamp;
                result[k] = delta / time_diff;
                
                // Counter semantics: skip non-monotonic values
                if (is_counter && current[i] < previous[j])
                    continue;  // Don't include this instance
            }
            k++;
        }
    }
    np->data.info->numval = k;
```

**Critical Features**:
- **Instance matching**: Handles dynamic instance domains (e.g., processes)
- **Counter semantics**: For `PM_SEM_COUNTER` metrics, non-monotonic decreases are filtered
- **Type handling**: Supports all numeric types (32/U32/64/U64/FLOAT/DOUBLE)
- **Time utilization**: For time counters (dimTime==1), scales to utilization percentage

### 3. Unary Operators: N_NOT, N_NEG (Lines 1039-1113)

**Purpose**: Logical negation (`!`) and arithmetic negation (`-`)

```c
case N_NOT:  // Boolean NOT: !expr
    for (i = 0; i < numval; i++) {
        result[i].value = (left[i].value == 0) ? 1 : 0;  // Convert to boolean
        result[i].inst = left[i].inst;
    }
    
case N_NEG:  // Arithmetic negation: -expr
    for (i = 0; i < numval; i++) {
        result[i].value = -left[i].value;  // Type-specific negation
        result[i].inst = left[i].inst;
    }
```

### 4. Ternary Operator: N_QUEST (Lines 1119-1320)

**Purpose**: Conditional expression `guard ? true_expr : false_expr`

```c
case N_QUEST:
    // Complex binding logic determines which branch(es) to evaluate
    for (i = 0; i < numval; i++) {
        // Evaluate guard for instance i
        if (guard[i] != 0)
            pick = true_expr;
        else
            pick = false_expr;
            
        // Copy value from picked expression
        result[i] = pick->ivlist[i];
        result[i].inst = indom_source->ivlist[i].inst;
    }
```

**Special Features**:
- **Lazy evaluation**: QUEST_BIND_LEFT/RIGHT flags control which branches execute
- **Instance domain handling**: Result inherits indom from non-singular operand
- **novalue() support**: Handles special `novalue()` pseudo-metric

### 5. Rescaling: N_RESCALE (Lines 1322-1344)

**Purpose**: Convert metric units (e.g., KB to MB, seconds to milliseconds)

```c
case N_RESCALE:
    for (i = 0, j = 0; i < numval; i++) {
        sts = pmConvScale(np->desc.type,
                         &left[i].value, &left_units,
                         &result[j].value, &target_units);
        if (sts >= 0)  // Only include successful conversions
            j++;
    }
    np->data.info->numval = j;  // May be less than input
```

### 6. Aggregation Functions: N_AVG, N_SUM, N_MIN, N_MAX, N_COUNT (Lines 1359-1568)

**Purpose**: Reduce multiple instances to a single value

```c
case N_SUM:
    result[0].value = 0;
    for (i = 0; i < left->numval; i++) {
        result[0].value += left[i].value;
    }
    result[0].inst = PM_IN_NULL;  // Singular instance
    numval = 1;

case N_AVG:
    result[0].value = 0;
    for (i = 0; i < left->numval; i++) {
        result[0].value += left[i].value / left->numval;
    }

case N_MIN / N_MAX:
    result[0].value = left[0].value;  // Initialize
    for (i = 1; i < left->numval; i++) {
        if (left[i].value < result[0].value)  // or > for MAX
            result[0].value = left[i].value;
    }

case N_COUNT:
    result[0].value = left->numval;  // Just count instances
```

**Output**: Always produces exactly 1 value with `inst = PM_IN_NULL`

### 7. Metric Fetch: N_NAME (Lines 1570-1656)

**Purpose**: Extract values from pmResult for a specific metric

```c
case N_NAME:
    // Find this metric's PMID in the vset array
    for (j = 0; j < numpmid; j++) {
        if (np->data.info->pmid == vset[j]->pmid) {
            // Allocate and copy values
            numval = vset[j]->numval;
            allocate_ivlist(numval);
            
            for (i = 0; i < numval; i++) {
                ivlist[i].inst = vset[j]->vlist[i].inst;
                
                // Type-specific extraction
                switch (type) {
                    case PM_TYPE_32/U32:
                        ivlist[i].value.l = vset[j]->vlist[i].value.lval;
                        break;
                    case PM_TYPE_64/U64:
                        memcpy(&ivlist[i].value.ll, vset[j]->vlist[i].value.pval->vbuf, 8);
                        break;
                    case PM_TYPE_STRING:
                        // Allocate and copy string
                        allocate_and_copy_string();
                        break;
                    case PM_TYPE_AGGREGATE:
                        // Deep copy pmValueBlock
                        deep_copy_valueblock();
                        break;
                }
            }
            return numval;
        }
    }
    return PM_ERR_PMID;  // PMID not found
```

**Key Operations**:
- Matches PMID from expression tree to fetched data
- Handles different value formats (INSITU, DPTR, SPTR)
- Performs deep copies for strings and aggregates

### 8. Instance Filtering: N_FILTERINST (Lines 1670-1807)

**Purpose**: Filter instances based on patterns `metric[instance_pattern]`

**Two Modes**:

#### A. Regular Expression (F_REGEX)
```c
// Example: disk.dev.total["sd.*"]
for (i = 0; i < right->numval; i++) {
    // Get instance name from indom
    pmNameInDom(indom, right->ivlist[i].inst, &iname);
    
    // Check regex match (with hash cache for performance)
    if (regexec(&pattern->regex, iname, 0, NULL, 0) == 0) {
        // Include this instance
        result[k++] = right->ivlist[i];
    }
}
```

**Optimization**: Uses hash table to cache regex matches per instance

#### B. Exact Match (F_EXACT)
```c
// Example: disk.dev.total["sda"]
// Find the specific instance
inst_id = pmLookupInDom(indom, "sda");
for (i = 0; i < right->numval; i++) {
    if (right->ivlist[i].inst == inst_id) {
        result[0] = right->ivlist[i];
        numval = 1;
        break;
    }
}
```

### 9. Binary Operators: Default Case (Lines 1817-1969)

**Purpose**: Arithmetic and comparison operators (+, -, *, /, <, >, ==, etc.)

```c
default:  // Binary operators: +, -, *, /, <, >, ==, !=, &&, ||
    // Determine result numval based on operand indoms
    if (left->indom == PM_INDOM_NULL)
        numval = right->numval;  // Scalar <op> vector
    else if (right->indom == PM_INDOM_NULL)
        numval = left->numval;   // Vector <op> scalar
    else
        numval = min(left->numval, right->numval);  // Vector <op> vector
    
    // Perform operation for each matching instance pair
    for (i = j = k = 0; k < numval; ) {
        // Match instances if both have indoms
        if (both_have_indom && left[i].inst != right[j].inst) {
            // Search for matching instance
            j = find_match(left[i].inst, right);
            if (not_found) {
                i++; 
                continue;
            }
        }
        
        // Perform the operation
        if (is_relational_or_boolean_op) {
            // Promote types, compute, cast result to U32
            promoted_result = bin_op(promoted_type, op, left[i], right[j]);
            result[k].value = (U32)promoted_result;
        }
        else {
            // Arithmetic: perform in result type
            result[k].value = bin_op(result_type, op, left[i], right[j]);
        }
        
        // Set result instance
        result[k].inst = non_null_indom_operand[...].inst;
        
        k++;
        advance_indices(i, j);
    }
```

**Key Features**:
- **Instance matching**: Aligns instances across operands
- **Type promotion**: Relational ops use promoted types then cast to U32
- **Scaling**: Applies mul_scale/div_scale for unit conversions
- **Broadcasting**: Scalars are broadcast across all instances

## Memory Management

### Instance-Value List (ivlist) Management

```c
typedef struct {
    int         inst;      // Instance identifier
    pmAtomValue value;     // Value (union of all types)
    int         vlen;      // Length for variable-length types
} val_t;
```

**Key Functions**:
- `save_ivlist()`: Saves current ivlist to last_ivlist (for delta/rate)
- `free_ivlist()`: Frees current ivlist before reallocating
- `pmNoMem()`: Fatal error handler for allocation failures

**Lifecycle**:
1. **Allocation**: `malloc(numval * sizeof(val_t))`
2. **Population**: Copy/compute values
3. **Preservation**: For temporal ops, save to `last_ivlist`
4. **Deallocation**: `free_ivlist()` before next evaluation

### String and Aggregate Handling

```c
// Strings: Deep copy required
case PM_TYPE_STRING:
    ivlist[i].value.cp = malloc(string_len);
    memcpy(ivlist[i].value.cp, source_string, string_len);
    ivlist[i].vlen = string_len;

// Aggregates: Deep copy pmValueBlock
case PM_TYPE_AGGREGATE:
    ivlist[i].value.vbp = malloc(vblock_len);
    memcpy(ivlist[i].value.vbp, source_vblock, vblock_len);
    ivlist[i].vlen = vblock_len;
```

## Instance Domain Handling

### Three Scenarios

1. **Both Operands Singular** (`PM_INDOM_NULL`)
   - Result is singular
   - Simple scalar operation

2. **One Singular, One with Instances**
   - Result has instances from non-singular operand
   - Singular value broadcasts across all instances
   - Example: `3.14 * disk.dev.read` broadcasts 3.14

3. **Both with Instances**
   - Instances must match across operands
   - Search/matching logic handles misaligned instances
   - Result contains only matching instances

### Instance Matching Algorithm

```c
// For each instance in left operand
for (i = 0; i < left->numval; i++) {
    // Find matching instance in right operand
    for (j = 0; j < right->numval; j++) {
        if (left[i].inst == right[j].inst) {
            // Match found - perform operation
            result[k++] = op(left[i], right[j]);
            break;
        }
    }
    // If no match, instance is omitted from result
}
```

## Type System

### Type Promotion Matrix

Binary operations use a promotion table:

```c
// promote[left_type][right_type] -> result_type
// Example: 32-bit + 64-bit -> 64-bit
PM_TYPE_32  + PM_TYPE_64  -> PM_TYPE_64
PM_TYPE_U64 + PM_TYPE_U64 -> PM_TYPE_DOUBLE (to avoid overflow)
PM_TYPE_FLOAT + PM_TYPE_64 -> PM_TYPE_DOUBLE
```

### Special Cases

- **Relational operators** (==, <, >, etc.): Always return `PM_TYPE_U32` (0 or 1)
- **Boolean operators** (&&, ||): Return `PM_TYPE_U32` (0 or 1)
- **Delta**: Result type same as operand type (except U32 -> 64, U64 -> DOUBLE)
- **Rate**: Always returns `PM_TYPE_DOUBLE`

## Performance Optimizations

### 1. Hash Table for Regex Matching
```c
// Cache regex matches to avoid repeated regex evaluations
__pmHashNode *hp = __pmHashSearch(inst, &pattern->hash);
if (hp == NULL) {
    // First time - evaluate regex and cache result
    evaluate_and_cache();
} else {
    // Use cached result
    ip = (instctl_t *)hp->data;
}
```

### 2. Instance Compaction
```c
// Periodically garbage collect unused regex match cache entries
if (pattern->used >= REGEX_INST_COMPACT)
    regex_inst_gc(pattern);
```

### 3. Early Exit Conditions
```c
// Don't allocate if no values
if (numval <= 0)
    return 0;

// Skip computation if operand has no values
if (left->numval <= 0 || right->numval <= 0) {
    np->data.info->numval = 0;
    return 0;
}
```

## Error Handling

### Error Propagation

```c
// Recursive evaluation errors bubble up
sts = eval_expr(ctxp, np->left, ...);
if (sts < 0) {
    if (np->type == N_COUNT) {
        // Special case: count() treats errors as 0
        return 0;
    }
    return sts;  // Propagate error
}
```

### Common Error Codes

| Error Code | Meaning | Context |
|------------|---------|---------|
| `PM_ERR_PMID` | Metric PMID not found | N_NAME when PMID not in vset |
| `PM_ERR_TYPE` | Invalid data type | Type conversion errors |
| `PM_ERR_CONV` | Conversion error | Unit scaling failures |
| `PM_ERR_LOGREC` | Log record format error | Wrong valfmt for type |

## Debugging Support

### Debug Output Levels

```c
if (pmDebugOptions.derive && pmDebugOptions.appl2) {
    fprintf(stderr, "eval_expr: %s: inst[%d] mismatch ...\n",
            __dmnode_type_str(np->type), k, ...);
}

if (pmDebugOptions.derive && pmDebugOptions.desperate) {
    fprintf(stderr, "eval_expr: ? bind %d values: ...\n", ...);
}
```

**Flags**:
- `derive`: Enable derived metrics debugging
- `appl2`: Application-level detail (instance matching, etc.)
- `desperate`: Maximum verbosity (ternary operator logic, etc.)

## Examples

### Example 1: Simple Arithmetic

**Expression**: `disk.dev.read + disk.dev.write`

```
Execution Flow:
1. eval_expr(N_PLUS node)
2.   eval_expr(N_NAME "disk.dev.read")  -> Extract from vset
3.   eval_expr(N_NAME "disk.dev.write") -> Extract from vset
4. Perform binary + operation on matching instances
5. Return result with combined values
```

### Example 2: Rate Calculation

**Expression**: `rate(network.interface.in.bytes)`

```
Execution Flow (2nd sample onwards):
1. eval_expr(N_RATE node)
2.   eval_expr(N_NAME "network.interface.in.bytes") -> current values
3. Match instances between current and saved previous values
4. For each matched instance:
     delta = current - previous
     time_diff = current_stamp - last_stamp
     result = delta / time_diff
5. Handle counter semantics (skip non-monotonic)
6. Save current as previous for next sample
```

### Example 3: Aggregation

**Expression**: `sum(disk.dev.total["sd.*"])`

```
Execution Flow:
1. eval_expr(N_SUM node)
2.   eval_expr(N_FILTERINST node)
3.     eval_expr(N_NAME "disk.dev.total") -> All instances
4.     eval_expr(N_PATTERN "sd.*")        -> Regex pattern
5.   Filter: Keep only instances matching "sd.*"
6. Aggregate: Sum all matching instance values
7. Return singular value (inst = PM_IN_NULL)
```

### Example 4: Conditional Expression

**Expression**: `kernel.all.cpu.user > 80 ? 1 : 0`

```
Execution Flow:
1. eval_expr(N_QUEST node)
2.   eval_expr(N_GT node) [guard]
3.     eval_expr(N_NAME "kernel.all.cpu.user")
4.     eval_expr(N_INTEGER 80)
5.   Compare: user > 80 ? (returns 0 or 1)
6.   eval_expr(N_INTEGER 1) [true branch]
7.   eval_expr(N_INTEGER 0) [false branch]
8. For each instance: pick true_branch if guard!=0, else false_branch
9. Return selected values
```

## Best Practices for Expression Authors

1. **Understand Instance Domains**: Mixing metrics with different indoms requires care
2. **Counter Semantics**: Use `rate()` for counters, aware it filters non-monotonic values
3. **Type Awareness**: Know that U64 delta/rate promotes to avoid overflow
4. **Performance**: Avoid complex regex patterns in high-frequency expressions
5. **Null Checking**: Expressions may return 0 values (not an error)

## Relationship to Other Functions

- **Called by**: `__dmpostfetch()` - The main post-fetch processing function
- **Calls**: `bin_op()` - Performs binary operations with type handling
- **Uses**: `pmConvScale()` - Unit conversion
- **Uses**: `pmNameInDom_ctx()`, `pmLookupInDom_ctx()` - Instance name resolution

## Summary

`eval_expr()` is a sophisticated recursive evaluator that:

✅ **Handles** 20+ node types covering constants, metrics, operators, and functions  
✅ **Manages** instance-value pairs across dynamic instance domains  
✅ **Supports** temporal operations requiring historical state  
✅ **Implements** type promotion and unit conversion  
✅ **Optimizes** regex matching and memory allocation  
✅ **Provides** comprehensive error handling and debugging  

It's the **heart of PCP's derived metrics system**, enabling powerful metric transformations and computations entirely at the client side without PMDA modifications.
