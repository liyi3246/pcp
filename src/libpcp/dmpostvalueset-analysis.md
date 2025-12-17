# __dmpostvalueset() Function Detailed Analysis

## Function Signature

```c
int __dmpostvalueset(__pmContext *ctxp, struct timespec *stamp, 
                     int vnumpmid, pmValueSet **vset, 
                     int numpmid, pmValueSet **newvset)
```

## Function Purpose

`__dmpostvalueset()` is one of the core functions for derived metric processing, responsible for rewriting the result set after a `pmFetch()` operation. Its main purposes are:

1. **Check each metric** to see if it's a derived metric
2. **Compute derived metric values** (if it is derived)
3. **Create new value sets** (`pmValueSet`) containing either original metric values or computed derived metric values
4. **Properly handle memory allocation** and different data types

## Parameters

- **ctxp**: Current PCP context pointer, containing derived metric definitions
- **stamp**: Timestamp (used for expression evaluation)
- **vnumpmid**: Number of original fetched value sets (from PMCD/archive)
- **vset**: Original value set array (input)
- **numpmid**: Number of requested metrics (should match original `pmFetch()` call)
- **newvset**: New value set array (output), to be filled with rewritten values

## Return Value

Returns the number of failed derived metrics (0 means all successful).

## Detailed Workflow

### First Loop: Iterate Through All Requested Metrics (j = 0 to numpmid)

```c
for (j = 0; j < numpmid; j++) {
```

For each metric:

#### Step 1: Initialize Variables

```c
numval = vset[j]->numval;    // Number of instances
valfmt = vset[j]->valfmt;    // Value format (INSITU/DPTR/SPTR)
rewrite = 0;                 // Rewrite flag
```

#### Step 2: Check if Derived Metric

```c
if (IS_DERIVED(vset[j]->pmid)) {
```

If it's a derived metric:
- Search for this PMID in the derived metric list
- If no expression → set `numval = PM_ERR_PMID` (error)
- If expression exists:
  - Set `rewrite = 1`
  - Set `valfmt` based on result type:
    - `PM_TYPE_32` or `PM_TYPE_U32` → `PM_VAL_INSITU` (value stored directly in structure)
    - Other types → `PM_VAL_DPTR` (value stored via pointer)
  - **Call `eval_expr()`** to compute the expression, returns number of instances

#### Step 3: Allocate Memory for New Value Set

```c
if (numval <= 0) {
    // Error case: only need pmid and numval fields
    need = sizeof(pmValueSet) - sizeof(pmValue);
} else {
    // Normal case: need to store numval values
    need = sizeof(pmValueSet) + (numval - 1)*sizeof(pmValue);
}
newvset[j] = (pmValueSet *)malloc(need);
```

#### Step 4: Fill Basic Fields

```c
newvset[j]->pmid = vset[j]->pmid;
newvset[j]->numval = numval;
newvset[j]->valfmt = valfmt;
```

### Second Loop: Process Values for Each Instance (i = 0 to numval)

```c
for (i = 0; i < numval; i++) {
```

Two paths here:

#### Path A: Non-Derived Metric (!rewrite)

Simple copy operation:

```c
if (!rewrite) {
    newvset[j]->vlist[i].inst = vset[j]->vlist[i].inst;
    
    if (vset[j]->valfmt == PM_VAL_DPTR || vset[j]->valfmt == PM_VAL_SPTR) {
        // Pointer type: need deep copy of pmValueBlock
        need = vset[j]->vlist[i].value.pval->vlen;
        vp = (pmValueBlock *)malloc(need);
        memcpy(vp, vset[j]->vlist[i].value.pval, need);
        newvset[j]->vlist[i].value.pval = vp;
        
        // Special handling: convert SPTR to DPTR (avoid memory leak)
        if (vset[j]->valfmt == PM_VAL_SPTR)
            newvset[j]->valfmt = PM_VAL_DPTR;
    } else {
        // INSITU type: direct value copy
        newvset[j]->vlist[i].value.lval = vset[j]->vlist[i].value.lval;
    }
}
```

**Key Points**:
- `PM_VAL_DPTR` = Dynamically allocated pointer (needs free)
- `PM_VAL_SPTR` = Static buffer pointer (should not be freed)
- `PM_VAL_INSITU` = Value stored inline (32-bit integer)

#### Path B: Derived Metric (rewrite == 1)

Complex rewrite operation, handled by data type:

```c
newvset[j]->vlist[i].inst = cp->mlist[m].expr->data.info->ivlist[i].inst;
```

Then handle differently based on derived metric type (`cp->mlist[m].expr->desc.type`):

##### 1. PM_TYPE_32 / PM_TYPE_U32 (32-bit integer)

```c
case PM_TYPE_32:
case PM_TYPE_U32:
    // Direct copy to lval (INSITU format)
    newvset[j]->vlist[i].value.lval = 
        cp->mlist[m].expr->data.info->ivlist[i].value.l;
    break;
```

##### 2. PM_TYPE_64 / PM_TYPE_U64 (64-bit integer)

```c
case PM_TYPE_64:
case PM_TYPE_U64:
    need = PM_VAL_HDR_SIZE + sizeof(__int64_t);  // Header + 8 bytes
    vp = (pmValueBlock *)malloc(need);
    vp->vlen = need;
    vp->vtype = cp->mlist[m].expr->desc.type;
    memcpy(vp->vbuf, &cp->mlist[m].expr->data.info->ivlist[i].value.ll, 
           sizeof(__int64_t));
    newvset[j]->vlist[i].value.pval = vp;
    break;
```

##### 3. PM_TYPE_FLOAT (float)

```c
case PM_TYPE_FLOAT:
    need = PM_VAL_HDR_SIZE + sizeof(float);  // Header + 4 bytes
    vp = (pmValueBlock *)malloc(need);
    vp->vlen = need;
    vp->vtype = PM_TYPE_FLOAT;
    memcpy(vp->vbuf, &cp->mlist[m].expr->data.info->ivlist[i].value.f, 
           sizeof(float));
    newvset[j]->vlist[i].value.pval = vp;
    break;
```

##### 4. PM_TYPE_DOUBLE (double precision float)

```c
case PM_TYPE_DOUBLE:
    need = PM_VAL_HDR_SIZE + sizeof(double);  // Header + 8 bytes
    vp = (pmValueBlock *)malloc(need);
    vp->vlen = need;
    vp->vtype = PM_TYPE_DOUBLE;
    // Note: possible bug here, should be .d instead of .f
    memcpy(vp->vbuf, &cp->mlist[m].expr->data.info->ivlist[i].value.f, 
           sizeof(double));
    newvset[j]->vlist[i].value.pval = vp;
    break;
```

##### 5. PM_TYPE_STRING (string)

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

##### 6. PM_TYPE_AGGREGATE / PM_TYPE_EVENT (aggregate/event types)

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

## Data Structure Explanation

### pmValueSet Structure
```c
typedef struct {
    pmID    pmid;      // Metric identifier
    int     numval;    // Number of values (instances)
    int     valfmt;    // Value format (INSITU/DPTR/SPTR)
    pmValue vlist[1];  // Value array (actual size variable)
} pmValueSet;
```

### pmValue Structure
```c
typedef struct {
    int inst;          // Instance identifier
    union {
        int         lval;  // INSITU: directly stored value
        pmValueBlock *pval; // DPTR/SPTR: pointer to value block
    } value;
} pmValue;
```

### pmValueBlock Structure
```c
typedef struct {
    unsigned int vlen;   // Total length of block
    int         vtype;   // Value type
    char        vbuf[1]; // Value buffer (actual size variable)
} pmValueBlock;
```

## Key Design Decisions

1. **Memory Management**:
   - Function allocates new memory for all DPTR types
   - Converts SPTR (static pointer) to DPTR (dynamic pointer) for proper freeing
   - Uses `pmNoMem()` for allocation failures (fatal error)

2. **Type Optimization**:
   - 32-bit integers use INSITU format (no extra allocation)
   - Other types use DPTR format (require pmValueBlock)

3. **Error Handling**:
   - Tracks failure count (`fails`)
   - Sets `PM_ERR_PMID` for derived metrics with missing expressions

4. **Debug Support**:
   - Uses `pmDebugOptions.derive` and `pmDebugOptions.appl2` for detailed tracing
   - Prints each value and instance information

## Usage Example Scenario

Suppose there's a derived metric:
```
disk.util = 100 * rate(disk.dev.total)
```

When `pmFetch()` requests `disk.util`:

1. `__dmprefetch()` expands request list, adds `disk.dev.total`
2. PMCD returns raw values for `disk.dev.total`
3. `__dmpostfetch()` calls `__dmpostvalueset()`
4. For `disk.util`:
   - Detects it's a derived metric (`rewrite = 1`)
   - Calls `eval_expr()` to compute `100 * rate(disk.dev.total)`
   - Creates new values for each disk instance
   - Allocates pmValueBlock based on result type (likely DOUBLE)
   - Copies computed values to new value set

## Performance Considerations

- Allocates memory for each derived metric value (potentially slow)
- Uses memcpy for data copying (efficient)
- Only rewrites when necessary (`rewrite` flag)
- Minimal overhead for non-derived metrics (simple copy)

## Potential Issues

1. **Memory Leak Risk**: If caller doesn't properly free results
2. **Type Error**: PM_TYPE_DOUBLE case uses `.f` instead of `.d` (possible bug)
3. **Error Propagation**: Failure count might be ignored

## Summary

`__dmpostvalueset()` is a key part of derived metric implementation that:
- Transparently handles both derived and non-derived metrics
- Properly manages complex memory allocation
- Supports all PCP data types
- Ensures result format is transparent to callers

This function makes derived metrics completely transparent to applications - they appear just like real metrics.
