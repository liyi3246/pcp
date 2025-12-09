# fetch.c and derive_fetch.c Explanation

## fetch.c - Performance Metrics Fetch Implementation

### Purpose

`fetch.c` implements the core functionality for fetching performance metric values in PCP. This is one of the most important operations in PMAPI - retrieving metric data from PMCD or archive files.

### Main Functions

1. **pmFetch()** - Public API function
   - Fetches current performance metric values for a list of PMIDs
   - One of the most commonly used PMAPI functions by applications
   - Returns a `pmResult` structure containing values for all requested metrics

2. **pmFetch_ctx()** - Internal context-aware version
   - Supports fetch operations with a specified context
   - Called by `pmFetch()` and `pmFetch_v2()`

3. **__pmFetch()** - Internal implementation function
   - Handles the actual fetch logic
   - Supports both live connections (PMCD) and archive contexts
   - Handles preprocessing and postprocessing for derived metrics
   - Manages IPC communication and PDU (Protocol Data Unit) handling

4. **pmFetchArchive()** - Fetch from archives
   - Retrieves the next set of metric values in chronological order from a PCP archive
   - Used for historical data analysis

5. **pmSetMode()** - Set archive processing mode
   - Controls how to traverse archive files
   - Sets time window and direction (forward/backward)

6. **__pmUpdateProfile()** - Update instance profile
   - Sends current instance filtering profile to PMCD
   - Optimizes data transfer to fetch only needed instances

7. **__pmRecvFetchPDU()** - Receive fetch response
   - Receives and decodes PDU responses from PMCD
   - Handles both high-resolution and standard result formats
   - Processes errors and state changes

### Workflow

1. Application calls `pmFetch(numpmid, pmidlist, &result)`
2. Check and handle derived metrics (calls `__pmPrepareFetch()`)
3. If needed, send instance profile to PMCD
4. Send FETCH request PDU to PMCD
5. Receive and decode response PDU
6. Process derived metric calculations (calls `__pmFinishResult()`)
7. Return result containing all metric values

---

## derive_fetch.c - Derived Metrics Fetch Processing

### Purpose

`derive_fetch.c` implements fetch and calculation functionality for PCP derived metrics. Derived metrics are virtual metrics computed from other metrics using expressions. For example, you can define a derived metric to calculate CPU utilization percentage or disk I/O rates.

### Main Functions

1. **__dmprefetch()** - Derived metric pre-fetch processing
   - Called before the main fetch
   - Scans the requested PMID list for derived metrics
   - For each derived metric, extracts all operand metrics used in the expression
   - Builds an expanded PMID list containing both original metrics and all operand metrics
   - Returns the size of expanded list (0 if no derived metrics)

2. **__dmpostfetch()** - Derived metric post-fetch processing
   - Called after the main fetch
   - Receives `pmResult` containing all original and operand metric values
   - Evaluates expression trees for each derived metric
   - Computes derived metric values
   - Rewrites `pmResult` to include computed derived metric values
   - Removes temporary operand metrics used only for calculation

3. **eval_expr()** - Expression evaluation
   - Recursively traverses expression tree
   - Fills leaf nodes (operands) with values from `pmResult`
   - Performs arithmetic operations (+, -, *, /, etc.)
   - Handles type conversion and promotion
   - Handles instance domain matching
   - Propagates computed values toward root node

4. **get_pmids()** - Extract metric identifiers
   - Recursively traverses expression tree
   - Collects PMIDs of all valid metrics used in the expression
   - Used to build expanded PMID list in `__dmprefetch()`

5. **bin_op()** - Binary operations
   - Performs binary operations between two operands
   - Handles different data types (integer, float, string)
   - Performs type conversion and scaling
   - Supports arithmetic, comparison, and logical operators

6. **__dmpostvalueset()** - Value set post-processing
   - Creates new value sets for each derived metric
   - Copies computed values from expression tree
   - Handles different value types (32/64-bit int, float, string, etc.)
   - Properly allocates and copies memory

7. **adjust_constant()** - Adjust constants
   - Handles constant values in expressions
   - Ensures constants have correct instance domains
   - Adjusts constants for singleton or multi-instance contexts

### Derived Metrics Workflow

1. User defines a derived metric, for example:
   ```
   disk.dev.util = 100 * delta(disk.dev.total) / delta(hinv.map.percpu)
   ```

2. Application calls `pmFetch()` requesting `disk.dev.util`

3. `__dmprefetch()` detects it's a derived metric:
   - Extracts operands: `disk.dev.total` and `hinv.map.percpu`
   - Adds them to fetch list

4. Main fetch executes to get operand values

5. `__dmpostfetch()` processes results:
   - Calls `eval_expr()` to compute expression
   - Performs calculation for each disk instance
   - Creates new `pmResult` with computed values

6. Result returned to application contains computed values for derived metric

### Supported Expression Features

- **Arithmetic operations**: +, -, *, /, %
- **Comparison operations**: <, <=, >, >=, ==, !=
- **Logical operations**: &&, ||, !
- **Functions**: delta(), rate(), instant(), sum(), avg(), min(), max(), count()
- **Conditionals**: ? : (ternary operator)
- **Constants**: numeric and string literals
- **Type conversion**: automatic type promotion and conversion

---

## Relationship Between the Two Files

These files work together to support derived metrics:

1. **fetch.c** provides the core fetch mechanism
   - Handles communication with PMCD/archives
   - Manages contexts and connections
   - Calls derived metric handlers at appropriate times

2. **derive_fetch.c** extends fetch functionality
   - Intercepts and expands PMID list before fetch
   - Computes derived metric values after fetch
   - Transparent to applications - derived metrics appear just like real metrics

This design allows PCP to support powerful derived metric capabilities while maintaining PMAPI simplicity. Applications don't need to know whether a metric is real or derived - they're used the same way.
