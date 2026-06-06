# Design: Guest-side Counter Contract with Per-Op Gas Logging

## Overview
Implement a new WASM guest contract (`contract_counter.zig`) that imports `env.storage_read`, `env.storage_write`, and `env.host_log`. The contract demonstrates real gas consumption for storage operations by reading a "counter" key, incrementing it, and writing it back. The host logs gas remaining before and after each storage operation.

## Goals
- Prove the gas metering system works end-to-end with actual host callbacks
- Show per-operation gas pricing (SLOAD = 200, SSTORE = 20,000 new / 5,000 modify)
- Keep existing `sandbox.zig` guest untouched for plugin/user-code scenes

## Non-Goals
- Multiple contract types (only counter for this iteration)
- Cross-contract calls between counter and other contracts
- LMDB persistence for the counter (memory-backed state only in demo)

## Architecture

```
contract_counter.zig (WASM guest)
  ├─ import env.storage_read(key_ptr, key_len, val_ptr, val_max) → i32
  ├─ import env.storage_write(key_ptr, key_len, val_ptr, val_len)
  ├─ import env.host_log(msg_ptr, msg_len)
  └─ export increment() → i32
       1. read "counter" → old_value (calls host storage_read)
       2. new_value = old_value + 1
       3. write "counter" = new_value (calls host storage_write)
       4. log "counter incremented to N" (calls host host_log)
       5. return new_value

Host (host_exports.zig)
  hostStorageReadCallback:
    - log gas before SLOAD
    - chargeSload()
    - read from StateStore
    - log gas after SLOAD

  hostStorageWriteCallback:
    - log gas before SSTORE
    - check if key exists → chargeSstore(is_new)
    - write to StateStore
    - log gas after SSTORE
```

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `contract_counter.zig` | Create | New guest contract with increment() export |
| `build.zig` | Modify | Add second WASM target for contract_counter |
| `host_exports.zig` | Modify | Add gas before/after logging in storage callbacks |
| `main.zig` | Modify | Replace Scene 2a with counter demo |
| `src/tests.zig` | Modify | Add counter gas consumption test |

## Scene 2 Demo Flow (main.zig)

1. Load `contract_counter.wasm` bytes
2. Initialize Sandbox with it
3. Attach memory-backed StateStore
4. Call `increment()` first time:
   - SLOAD (200 gas) → key "counter" does not exist → returns 0
   - SSTORE (20,000 gas) → writes "counter" = 1
5. Call `increment()` second time:
   - SLOAD (200 gas) → reads "counter" = 1
   - SSTORE_MODIFY (5,000 gas) → writes "counter" = 2
6. Call `get()` (if implemented):
   - SLOAD (200 gas) → reads "counter" = 2
7. Print final gas consumed vs initial

## Gas Pricing Reference

| Operation | Cost | Trigger |
|-----------|------|---------|
| SLOAD | 200 | Every storage_read call |
| SSTORE (new key) | 20,000 | First write to a key |
| SSTORE (modify) | 5,000 | Subsequent writes to existing key |

## Error Handling
- Out of gas: callback returns error code to guest (-2), guest may handle or trap
- Missing state: storage_read returns 0 bytes (guest interprets as 0)
- Invalid key/length: callback returns -1

## Testing

```zig
test "counter increments and charges gas" {
    // Load contract_counter.wasm
    // Initialize Sandbox + StateStore
    // Call increment() twice
    // Assert total gas consumed = 200 + 20000 + 200 + 5000 = 25,400
    // Assert first SSTORE (20,000) > second SSTORE (5,000)
}
```

## Open Questions
- None at this time.
