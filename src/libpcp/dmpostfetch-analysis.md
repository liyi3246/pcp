# __dmpostfetch() Function Analysis

## Overview

`__dmpostfetch()` is the **post-processing function** for derived metrics in PCP's libpcp library. It's called after `pmFetch()` to transform a raw `pmResult` containing both base metrics and derived metric placeholders into a final `pmResult` with computed derived metric values.

**Location**: `src/libpcp/src/derive_fetch.c`

## Function Signature

```c
void __dmpostfetch(__pmContext *ctxp, __pmResult **result)
```

### Parameters

- **`ctxp`**: Pointer to the PCP context (`__pmContext`)
  - Contains the derived metrics control structure (`c_dm`)
  - Provides context for metric evaluation and debugging
  
- **`result`**: Pointer to pointer to `__pmResult`
  - **Input**: Raw pmResult from fetch containing base metrics
  - **Output**: Transformed pmResult with computed derived metrics
  - The function modifies `*result` in-place

### Return Value

- **`void`**: No return value (modifies `*result` directly)

## Purpose

The function serves as the **final step** in the derived metrics pipeline:

1. **Pre-fetch** (`__dmprefetch`): Expands pmID list to include operand metrics
2. **Fetch**: Gets base metric values from PMDAs
3. **Post-fetch** (`__dmpostfetch`): **Computes derived metrics from base values** ← This function

## Workflow

### Step 1: Early Exit Check

```c
ctl_t *cp = (ctl_t *)ctxp->c_dm;

if (cp == NULL || cp->fetch_has_dm == 0)
    return;
```

**Fast path optimization**:
- If no derived metrics context (`cp == NULL`)
- Or if fetch had no derived metrics (`fetch_has_dm == 0`)
- **Exit immediately** without processing

### Step 2: Debug Output (Optional)

```c
if (pmDebugOptions.derive && pmDebugOptions.desperate) {
    fprintf(stderr, "__dmpostfetch: from context before rewrite ...\n");
    __pmPrintResult_ctx(ctxp, stderr, rp);
}
```

**When enabled**: Prints the raw pmResult before transformation

### Step 3: Allocate New pmResult

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

**Key points**:
- Allocates new pmResult with `cp->numpmid` entries
  - `cp->numpmid`: Original fetch count (before operand expansion)
  - This restores the pmResult to the original requested metric count
- Copies timestamp from raw result
- Fatal error if allocation fails

### Step 4: Compute Derived Metrics

```c
struct timespec timestamp;
timestamp.tv_sec = rp->timestamp.sec;
timestamp.tv_nsec = rp->timestamp.nsec;

fails = __dmpostvalueset(ctxp, &timestamp, 
                         rp->numpmid, rp->vset,
                         newrp->numpmid, newrp->vset);
```

**Core computation**:
- Calls `__dmpostvalueset()` to:
  - Iterate through all metrics in the original request
  - For **base metrics**: Copy values directly
  - For **derived metrics**: Evaluate expressions using operand values
  - Populate `newrp->vset[]` with results
- Returns count of failed evaluations

### Step 5: Debug Failed Metrics (Optional)

```c
if (fails > 0 && pmDebugOptions.derive)
    __pmPrintResult_ctx(ctxp, stderr, rp);
```

**When errors occur**: Prints the raw result for debugging

### Step 6: Replace Result

```c
__pmFreeResult(rp);
*result = newrp;
```

**Final step**:
- Frees the original (raw) pmResult
- Replaces `*result` with the transformed pmResult
- Caller now has derived metrics computed

## Data Flow

### Input pmResult (from fetch)
```
pmResult (expanded with operands):
├── vset[0]: disk.dev.read (base metric)      ✓ fetched
├── vset[1]: disk.dev.write (base metric)     ✓ fetched
├── vset[2]: disk.dev.total (derived)         ✗ PM_ERR_NOAGENT
└── vset[3]: some.other.metric (base)         ✓ fetched
```

### Processing by __dmpostvalueset()
```
For each metric in original request (cp->numpmid):
  - disk.dev.total (derived):
    → Evaluate: disk.dev.read + disk.dev.write
    → Create new vset with computed values
```

### Output pmResult
```
pmResult (original size, with derived values):
├── vset[0]: disk.dev.total                   ✓ computed
└── vset[1]: some.other.metric                ✓ copied
```

## Key Data Structures

### ctl_t (Control Structure)
```c
typedef struct {
    int      numpmid;        // Original fetch pmID count
    int      fetch_has_dm;   // Flag: fetch contains derived metrics
    int      nmetric;        // Total derived metrics defined
    mlist_t  *mlist;         // Derived metric definitions
} ctl_t;
```

### mlist_t (Metric List Entry)
```c
typedef struct {
    pmID     pmid;           // Metric ID
    int      flags;          // Binding flags (DM_BIND, etc.)
    node_t   *expr;          // Expression tree for evaluation
} mlist_t;
```

## Relationship to Other Functions

### Call Chain
```
pmFetch()
  ↓
__dmprefetch()              // Pre: Expand pmID list
  ↓
[PMDA fetch operations]     // Fetch base metrics
  ↓
__dmpostfetch()             // Post: Compute derived ← THIS FUNCTION
  ↓
  └→ __dmpostvalueset()     // Actual computation
```

### Collaboration

**__dmprefetch()**:
- Saves `cp->numpmid` (original count)
- Sets `cp->fetch_has_dm` flag
- Expands pmID list with operands

**__dmpostfetch()**:
- Uses `cp->numpmid` to restore result size
- Checks `cp->fetch_has_dm` for fast path
- Delegates computation to `__dmpostvalueset()`

**__dmpostvalueset()**:
- Iterates through metrics
- Evaluates derived metric expressions
- Handles instance matching and type conversion

## Performance Considerations

### Optimizations

1. **Fast Path Exit**
   - Checks `fetch_has_dm` flag
   - Avoids allocation if no derived metrics

2. **In-Place Transformation**
   - Modifies `*result` pointer
   - Avoids extra copy operations

3. **Memory Efficiency**
   - Frees old result immediately
   - Allocates exactly `cp->numpmid` entries

### Overhead

- **Memory**: One extra pmResult allocation (temporary)
- **CPU**: Expression evaluation in `__dmpostvalueset()`
- **Minimal** when no derived metrics present

## Error Handling

### Fatal Errors
```c
if ((newrp = __pmAllocResult(cp->numpmid)) == NULL) {
    pmNoMem(..., PM_FATAL_ERR);
    /* NOTREACHED */
}
```

**Memory allocation failure**: Terminates program

### Non-Fatal Errors

- Evaluation failures in `__dmpostvalueset()` are counted
- Failed metrics have `numval < 0` (error code)
- Printed to stderr when debugging enabled

## Debugging

### Enable Debugging
```bash
export PCP_DEBUG=derive,desperate
pminfo -f my.derived.metric
```

### Debug Output

**Before transformation**:
```
__dmpostfetch: from context before rewrite ...
pmResult dump from 0x... timestamp: ...
  2 metrics:
    disk.dev.read[sda] = 1000
    disk.dev.write[sda] = 500
```

**After failures** (if any):
```
[Raw result printed showing base metric values]
```

## Example Usage Pattern

### Client Code
```c
pmID pmids[1] = {derived_metric_pmid};
pmResult *result;

// Fetch with derived metric
pmFetch(1, pmids, &result);

// At this point:
// 1. __dmprefetch() already expanded pmID list
// 2. Base metrics were fetched
// 3. __dmpostfetch() computed derived values
// 4. result->vset[0] contains computed values

// Use result
for (int i = 0; i < result->vset[0]->numval; i++) {
    printf("Value: %d\n", result->vset[0]->vlist[i].value.lval);
}

pmFreeResult(result);
```

### Internal Flow
```c
// Inside pmFetch() implementation:

// Pre-fetch: expand pmID list
int n = __dmprefetch(ctxp, numpmid, pmidlist, &newlist);

// Fetch from PMDAs
__pmResult *rp = fetch_from_pmdas(ctxp, n, newlist);

// Post-fetch: compute derived metrics
__dmpostfetch(ctxp, &rp);  // ← Transforms rp in-place

return rp;  // Now contains derived values
```

## Common Issues

### Problem: Derived metric returns PM_ERR_NOAGENT

**Cause**: `__dmpostfetch()` not called or failed

**Debug**:
```bash
export PCP_DEBUG=derive
pminfo -f metric.name
```

### Problem: Memory leak

**Cause**: Old pmResult not freed

**Solution**: `__dmpostfetch()` calls `__pmFreeResult(rp)` automatically

### Problem: Wrong metric count in result

**Cause**: `cp->numpmid` not set correctly in `__dmprefetch()`

**Check**: Ensure pre-fetch called before post-fetch

## Summary

`__dmpostfetch()` is a **simple coordinator** that:

1. ✅ Validates context and fast-path
2. ✅ Allocates new pmResult (original size)
3. ✅ Delegates computation to `__dmpostvalueset()`
4. ✅ Replaces raw result with computed result
5. ✅ Handles cleanup and debugging

The actual complexity lies in `__dmpostvalueset()` which:
- Evaluates expression trees
- Matches instances across metrics
- Handles type conversions
- Manages memory for computed values

**Key insight**: This function is the **bridge** between raw PMDA data and user-visible derived metrics, ensuring transparent integration of computed metrics into PCP's fetch pipeline.
