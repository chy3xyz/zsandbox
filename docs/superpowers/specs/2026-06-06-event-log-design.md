# Design: Event/Log System for Smart Contracts

## Overview
Add a structured event logging system where WASM guest contracts can emit events via `host_log_event`, and the host collects them in an `EventLog` buffer attached to the `ContractRegistry`.

## Goals
- Contracts emit structured events (name + data) during execution
- Host collects all events in a queryable buffer
- Demonstrate event emission in counter and composite contracts
- Gas charged per event (LOG = 375 gas)

## Architecture

```
Guest Contract
  └─ host_log_event(name, data)
       │
       ▼
hostLogEventCallback
  ├─ charge LOG gas (375)
  ├─ read name/data from guest memory
  └─ registry.event_log.emit(contract, name, data)
       │
       ▼
EventLog (owned by ContractRegistry)
  ├─ events: ArrayList<Event>
  ├─ emit(contract, name, data)
  ├─ getAll() → []Event
  ├─ getByContract(contract) → []Event
  ├─ getByName(name) → []Event
  └─ clear()
```

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `src/extensions/event_log.zig` | Create | Event struct + EventLog buffer with emit/query/clear |
| `src/extensions/contract_registry.zig` | Modify | Add EventLog field, expose via getter |
| `src/host_exports.zig` | Modify | Add hostLogEventCallback (charges gas, emits to registry) |
| `src/sandbox.zig` | Modify | Register host_log_event in linker |
| `src/limits.zig` | Modify | Add host_log_event name constant |
| `contract_counter.zig` | Modify | increment() emits "Incremented" event |
| `contract_composite.zig` | Modify | add_via_math() emits "CrossCallInitiated" + "CrossCallCompleted" |
| `src/main.zig` | Modify | Print event log after Scene 2d |
| `src/tests.zig` | Modify | Test event emission and query |

## Guest API

```zig
extern fn host_log_event(name_ptr: u32, name_len: u32, data_ptr: u32, data_len: u32) void;
```

## Gas Pricing
- LOG: 375 gas per event emission

## Demo Flow
1. Deploy counter, call increment() → emits "Incremented" event
2. Deploy composite, call add_via_math() → emits "CrossCallInitiated" and "CrossCallCompleted"
3. Host prints all events from registry.event_log
