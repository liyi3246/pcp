# libpcp - Performance Co-Pilot Core Library

## What is libpcp?

**libpcp** is the core library of the Performance Co-Pilot (PCP) toolkit. It provides the fundamental infrastructure and implementation of the Performance Metrics API (PMAPI), which is the primary interface for accessing performance metrics in PCP.

## Purpose and Function

The main purposes of libpcp are:

1. **Implement the PMAPI**: Provides the complete Performance Metrics Application Programming Interface that client applications use to access performance data.

2. **Manage Connections**: Handles connections between monitoring tools and:
   - PMCD (Performance Metrics Collection Daemon) processes for live metrics
   - PCP archive files for retrospective analysis

3. **Context Management**: Maintains performance metric contexts, which represent either a live connection to a PMCD or a handle to a PCP archive.

4. **Metric Resolution**: Translates between human-readable metric names and internal Performance Metric Identifiers (PMIDs).

5. **Data Retrieval**: Fetches and formats performance metric values from various sources.

6. **Thread Safety**: Provides thread-safe operations for multi-threaded applications using performance metrics.

## Key Features

- **Thread-safe implementation**: Designed for use in multi-threaded applications
- **Cross-platform support**: Works on Linux, macOS, Windows (MinGW), AIX, and Solaris
- **Protocol handling**: Manages communication protocols with PMCDs and archive files
- **Derived metrics**: Supports computed metrics derived from other metrics
- **Multiple contexts**: Can manage multiple simultaneous connections to different metric sources
- **Error handling**: Comprehensive error reporting and handling mechanisms

## How to Use libpcp

### In C/C++ Applications

Include the main header file:

```c
#include <pcp/pmapi.h>
```

For advanced usage, you may also need:

```c
#include <pcp/libpcp.h>
```

### Linking

Link your application with libpcp:

```bash
cc myapp.c -lpcp
```

Or using pkg-config:

```bash
cc myapp.c $(pkg-config --cflags --libs pcp)
```

### Basic Usage Pattern

```c
#include <pcp/pmapi.h>

int main(int argc, char **argv)
{
    int ctx;
    pmID pmid;
    pmResult *result;
    
    /* Create a context (connection) */
    ctx = pmNewContext(PM_CONTEXT_HOST, "localhost");
    
    /* Look up a metric by name */
    pmLookupName(1, &"kernel.all.load", &pmid);
    
    /* Fetch metric values */
    pmFetch(1, &pmid, &result);
    
    /* Use the values ... */
    
    /* Clean up */
    pmFreeResult(result);
    pmDestroyContext(ctx);
    
    return 0;
}
```

## Relationship to Other PCP Components

- **PMAPI**: libpcp implements the PMAPI specification
- **pmcd**: libpcp connects to pmcd to retrieve live metrics
- **PMDAs**: libpcp communicates with Performance Metrics Domain Agents through pmcd
- **libpcp_pmda**: Separate library for writing PMDAs (built on top of libpcp concepts)
- **PCP Archives**: libpcp can read metrics from historical archive files
- **PCP Tools**: All standard PCP tools (pminfo, pmval, pmstat, etc.) are built using libpcp

## Architecture

libpcp sits "below the PMAPI" in PCP terminology, implementing the services that client applications use "above the PMAPI". It abstracts away the complexities of:

- Network communication with PMCDs
- Archive file format handling
- Metric namespace management
- Instance domain resolution
- Time control for archive playback
- Connection pooling and management

## Documentation

For detailed API documentation, see:

- `PMAPI(3)` - Main PMAPI man page
- `pmNewContext(3)`, `pmFetch(3)`, `pmLookupName(3)` - Core PMAPI functions
- `docs/PG/PMAPI.rst` - Programmer's Guide PMAPI chapter
- `docs/PG/ProgrammingPcp.rst` - Programming PCP applications

For information on thread safety and locking:
- `src/libpcp/doc/libpcp-locking.odt` - Locking and concurrency control documentation

## Library Variants

- **libpcp.so.4**: Current version (PMAPI_VERSION_4) used in PCP 7.0 and later
- **libpcp.so.3**: Legacy version (PMAPI_VERSION_2) maintained in `src/libpcp3/`
- **libpcp_fault**: Development/testing variant with fault injection (see `src/libpcp_fault/`)

## License

This library is free software; you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License as published by the Free Software Foundation; either version 2.1 of the License, or (at your option) any later version.
