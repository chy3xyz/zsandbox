# Design: ContractRegistry with Cross-Contract Calls

## Overview
Create a `ContractRegistry` that manages multiple WASM contract instances, each with its own `Sandbox` + `StateStore`. Support real cross-contract calls where one guest invokes another through `host_call_contract`.

## Goals
- Deploy and manage multiple named contracts
- Demonstrate real cross-contract calls (guest → host → different guest)
- Share gas budget across calls (caller accumulates callee's consumed gas)
- Maintain independent state per contract

## Architecture

```
ContractRegistry
  ├─ contracts: HashMap<name, *Sandbox>
  ├─ deploy(name, wasm_bytes) → creates Sandbox + StateStore
  └─ call(caller_name, target_name, func, args) → i32
       1. Lookup caller and target sandboxes
       2. Charge CALL gas (700) on caller
       3. Push call frame to caller's CallStack
       4. Set target.gas_meter.limit = caller.remainingGas()
       5. Execute target.call(func, args)
       6. Pop call frame
       7. Charge caller for callee's total consumed gas
       8. Return result

host_call_contract callback (extended to 6 args)
  ├─ addr_ptr, addr_len, func_ptr, func_len, arg0, arg1
  └─ Looks up ContractRegistry via global reference
      → Finds target by address
      → Calls target function with arg0, arg1
      → Returns i32 result to caller
```

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `src/extensions/contract_registry.zig` | Create | ContractRegistry with deploy/call |
| `contract_composite.zig` | Create | Guest that calls `env.call_contract` |
| `build.zig` | Modify | Add contract_composite WASM target |
| `src/host_exports.zig` | Modify | Extend hostCallContractCallback to 6 args, integrate Registry lookup |
| `src/sandbox.zig` | Modify | Add `setGasLimit()` method for cross-call budget transfer |
| `src/main.zig` | Modify | Add Scene 2d: deploy math+counter+composite, demo cross-call |
| `src/tests.zig` | Modify | Add cross-contract call test |

## Key Technical Details

### Gas Sharing Model (Simplified)
- Caller deducts CALL gas (700) before cross-call
- Callee runs with its own GasMeter, but limit is capped to caller's remaining gas
- After callee returns, caller charges itself for `callee.totalGasConsumed()`
- This approximates shared gas without deep GasMeter refactoring

### host_call_contract Signature Change
From: `(addr_ptr, addr_len, func_ptr, func_len) → i32`
To: `(addr_ptr, addr_len, func_ptr, func_len, arg0, arg1) → i32`

The callback needs access to ContractRegistry. Since callbacks receive `env: ?*anyopaque`, we can:
- Store a global `?*ContractRegistry` pointer that the callback reads
- Or pass the registry pointer through env (but env is tied to HostEnv/Sandbox)

Chosen approach: global registry pointer, set during main init.

### contract_composite.zig Guest
Imports: `env.host_log`, `env.call_contract`
Exports: `add_via_math(a: i32, b: i32) → i32`
```
add_via_math(a, b):
  result = call_contract("math", "sandbox_add", a, b)
  return result
```

## Demo Flow (Scene 2d)
1. Deploy "math" from sandbox.wasm
2. Deploy "counter" from contract_counter.wasm
3. Deploy "composite" from contract_composite.wasm
4. Direct call: registry.call("math", "sandbox_add", &.{3,4}) → 7
5. Direct call: registry.call("counter", "increment") → 1
6. Cross call: registry.call("composite", "add_via_math", &.{10,20}) → 30
   - composite guest calls host_call_contract("math", "sandbox_add", 10, 20)
   - host finds "math" sandbox, calls sandbox_add(10,20)
   - returns 30 to composite, composite returns 30
7. Show call stack depth during cross-call = 2

## Testing
```zig
test "cross-contract call: composite calls math" {
    // Deploy math and composite
    // Call composite.add_via_math(10, 20)
    // Assert result = 30
    // Assert call_stack.len >= 2 during call
}
```
