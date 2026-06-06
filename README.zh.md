# ZSandbox — Zig 生产级 WASM 沙箱

[![Zig](https://img.shields.io/badge/Zig-0.17%20(dev)-orange.svg)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-15%2F15%20passing-brightgreen.svg)]()
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> 一个安全、带 Gas 计量、支持多租户的 WebAssembly 沙箱内核，同时支持**插件系统**、**智能合约**和**用户上传代码执行**三大场景。

---

## 目录

- [概述](#概述)
- [功能特性](#功能特性)
- [架构](#架构)
- [安全模型](#安全模型)
- [快速开始](#快速开始)
- [使用示例](#使用示例)
- [Host Exports 参考](#host-exports-参考)
- [Gas 定价](#gas-定价)
- [项目结构](#项目结构)
- [贡献指南](#贡献指南)
- [许可证](#许可证)

---

## 概述

**ZSandbox** 是一个用 Zig 编写的生产级 WebAssembly (WASM) 沙箱。它以 [Wasmtime](https://wasmtime.dev/)（通过 C API）为执行引擎，并在之上构建了全面的安全、计量和扩展层。

三大使用场景同时在同一个内核上运行：

| 场景 | 说明 |
|------|------|
| **插件系统** | 加载/卸载/重载带沙箱隔离的插件，支持调用统计和燃料追踪。 |
| **智能合约** | 部署带持久化存储（内存或 LMDB）、跨合约调用、事件日志和 Gas 计量的合约。 |
| **用户代码执行** | 运行不受信任的用户代码，配备 I/O 管道、墙钟超时和资源限制。 |

三者共享**同一个沙箱内核**——一个 `Sandbox` 结构体，封装了引擎、存储、模块、链接器、实例、Gas 计量和内存安全。

---

## 功能特性

### 安全
- **内存边界检查** — 所有 Host 回调在读写前先验证 Guest 内存指针边界。
- **Gas 耗尽即 Trap** — Host 回调耗尽 Gas 立即通过 `wasm_trap_t` 终止 Guest 执行，绝不返回错误码让 Guest 继续。
- **运行时参数校验** — 替换 `assert()`（Release 构建中被剥离）为运行时检查，签名不匹配时返回 Trap。
- **全局重入/循环检测** — 防止 A→B→A 的循环跨合约调用。
- **调用深度限制** — 最大 16 层；跨全局调用栈检测重入。
- **WASM 模块校验** — Magic/版本检查、导入/导出白名单、必需导出验证。
- **内存增长限制** — `wasmtime_store_limiter` 将线性内存上限限制在约 1.06 MiB。

### 计量
- **指令级 Fuel** — Wasmtime 原生燃料消耗追踪。
- **Host 调用 Gas** — 参考 EVM 的 SLOAD、SSTORE、CALL、LOG、keccak256、sha256 定价。
- **跨合约 Gas 共享** — 调用者将剩余 Gas 作为被调用者的上限。

### 持久化
- **双后端状态存储** — 内存（`HashMap`）用于测试，LMDB 用于生产。
- **事务语义** — `beginTx` / `commit` / `rollback`，LMDB 事务原子性保证。

### 性能
- **模块编译缓存** — 共享单个 `wasm_engine_t`，按 SHA-256 哈希缓存编译后的 `wasmtime_module_t`。
- **并发安全注册表** — `PluginRegistry` 和 `ContractRegistry` 受 `std.atomic.Mutex` 保护。

### 加密预编译合约
- **keccak256** — 30 + 6×字 Gas（EVM 兼容）
- **sha256** — 60 + 12×字 Gas（EVM 兼容）

---

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                        Host (Zig)                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ 插件系统    │  │ 智能合约    │  │ 用户代码执行        │  │
│  │ Plugin      │  │ Contract    │  │ (I/O + 看门狗)      │  │
│  │ Registry    │  │ Registry    │  │                     │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                    │             │
│         └────────────────┴────────────────────┘             │
│                          │                                  │
│                    ┌─────┴─────┐                            │
│                    │  Sandbox  │ ← Gas 计量, Fuel 计量      │
│                    │  (内核)   │   调用栈, HostEnv          │
│                    └─────┬─────┘                            │
│                          │                                  │
│         ┌────────────────┼────────────────┐                │
│         ▼                ▼                ▼                │
│  ┌────────────┐  ┌────────────┐  ┌────────────────────┐   │
│  │ StateStore │  │ EventLog   │  │ ModuleCache        │   │
│  │ (内存 /    │  │            │  │ (共享引擎 +        │   │
│  │  LMDB)     │  │            │  │  编译缓存)         │   │
│  └────────────┘  └────────────┘  └────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Wasmtime C API (引擎)                  │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  Guest WASM 模块    │
                    │ (插件 / 合约)       │
                    └─────────────────────┘
```

---

## 安全模型

ZSandbox 将**所有 Guest 代码视为敌对代码**。以下防御措施被强制执行：

| 层级 | 防御措施 |
|------|---------|
| **模块** | 大小限制（2 MiB）、Magic/版本验证、导入/导出白名单、必需导出检查。 |
| **内存** | 所有 Host 回调在访问前验证 `ptr + len <= memory_size`。`wasmtime_store_limiter` 防止无限制的 `memory.grow`。 |
| **执行** | Fuel + Gas 双重计量。Gas 耗尽返回 `wasm_trap_t`（Guest 无法继续执行）。 |
| **重入** | 每沙箱深度限制（8）+ 全局调用栈循环检测。 |
| **Host 回调** | 运行时参数数量/类型校验（非 `assert`）。 |
| **状态** | LMDB 事务原子性；失败时 `beginTx` / `rollback`。 |

---

## 快速开始

### 环境依赖

- **Zig** 0.17.0-dev (master)
- **Wasmtime** 33.0.0+ (C 库)
- **LMDB** 0.9.33+ (持久化状态)

macOS (Homebrew):
```bash
brew install wasmtime lmdb
```

### 构建

```bash
zig build
```

这将编译：
- 5 个 Guest WASM 模块（`sandbox`、`contract_counter`、`contract_composite`、`contract_crypto`、`contract_token`）
- 1 个 Host 可执行文件（`host`）

### 运行演示

```bash
zig build run
```

### 运行测试

```bash
zig test src/tests.zig -lwasmtime -I/opt/homebrew/opt/lmdb/include \
  -L/opt/homebrew/opt/lmdb/lib -llmdb -I/opt/homebrew/include -L/opt/homebrew/lib
```

或通过构建系统：
```bash
zig build test
```

---

## 使用示例

### 1. 插件系统

```zig
const allocator = std.heap.page_allocator;

var registry = PluginRegistry.init(allocator);
defer registry.deinit();

// 从 WASM 字节加载插件
try registry.load("math", "1.0.0", wasm_bytes);

// 调用插件函数
const result = try registry.call("math", "sandbox_add", &[_]i32{ 10, 20 });
// result == 30

// 列出所有插件
const infos = try registry.list(allocator);
for (infos) |info| {
    std.log.info("{s} v{s} | 调用次数={d}", .{ info.name, info.version, info.call_count });
}
```

### 2. 智能合约

```zig
var reg = ContractRegistry.init(allocator);
defer reg.deinit();
contract_registry.g_registry = &reg; // 供 Host 回调使用

// 部署合约
try reg.deploy("math", math_wasm, &math_imports, &math_exports, &math_required);
try reg.deploy("composite", composite_wasm, &comp_imports, &comp_exports, &comp_required);

// 直接调用
const r = try reg.call("math", "math", "sandbox_add", &[_]i32{ 3, 4 });

// 跨合约调用（composite 内部调用 math）
const cross = try reg.call("composite", "composite", "add_via_math", &[_]i32{ 10, 20 });
// cross == 30
```

### 3. 用户代码执行

```zig
var sb = try Sandbox.init(allocator, wasm_bytes, &imports, &exports, &required);
defer sb.deinit();

var io_pipe = try IoPipeline.init(allocator, .{});
defer io_pipe.deinit();
sb.attachIo(&io_pipe);

var wd = Watchdog.init(5000); // 5 秒超时
sb.attachWatchdog(&wd);

// 带输入/输出执行
const output = try sb.callWithInput("process", "hello world");
```

### 4. 模块缓存

```zig
var mod_cache = try ModuleCache.init(allocator);
defer mod_cache.deinit();

// 第一个沙箱：编译并缓存
var sb1 = try Sandbox.initWithCache(allocator, wasm_bytes, &imports, &exports, &required, &mod_cache);

// 第二个沙箱：复用已编译的模块
var sb2 = try Sandbox.initWithCache(allocator, wasm_bytes, &imports, &exports, &required, &mod_cache);
```

### 5. 加密预编译合约

Guest 代码导入 `env.keccak256` 和 `env.sha256`：

```zig
extern fn keccak256(data_ptr: i32, data_len: i32, out_ptr: i32) void;
extern fn sha256(data_ptr: i32, data_len: i32, out_ptr: i32) void;

export fn hash_both(data_ptr: i32, data_len: i32, keccak_out: i32, sha_out: i32) i32 {
    keccak256(data_ptr, data_len, keccak_out);
    sha256(data_ptr, data_len, sha_out);
    return 0;
}
```

Host 端：写入数据、调用、读取 32 字节哈希：

```zig
try sb.writeToGuestMemory(1024, "hello");
_ = try sb.call("hash_both", &[_]i32{ 1024, 5, 2048, 2080 });
// keccak256("hello") 在 2048，sha256("hello") 在 2080
```

---

## Host Exports 参考

所有 Host 函数通过 `env` 模块暴露给 Guest。

| 函数 | 签名 | Gas | 说明 |
|------|------|-----|------|
| `host_log` | `(ptr: i32, len: i32) -> void` | 0 | 将 Guest 消息记录到 Host 日志。 |
| `storage_read` | `(key_ptr, key_len, val_ptr, val_max) -> i32` | 200 (SLOAD) | 从合约状态读取值。返回写入字节数或 0/−1/−2。 |
| `storage_write` | `(key_ptr, key_len, val_ptr, val_len) -> void` | 20,000/5,000 (SSTORE) | 写入值到合约状态。 |
| `call_contract` | `(addr_ptr, addr_len, func_ptr, func_len, arg0, arg1) -> i32` | 700 (CALL) | 跨合约调用。返回被调用者结果。 |
| `host_log_event` | `(name_ptr, name_len, data_ptr, data_len) -> void` | 375 (LOG) | 触发结构化事件。 |
| `keccak256` | `(data_ptr, data_len, out_ptr) -> void` | 30 + 6×字 | 计算 Keccak-256 哈希（32 字节写入 out_ptr）。 |
| `sha256` | `(data_ptr, data_len, out_ptr) -> void` | 60 + 12×字 | 计算 SHA-256 哈希（32 字节写入 out_ptr）。 |

---

## Gas 定价

参考 Ethereum EVM，适配 WASM Host 调用。

| 操作 | Gas 消耗 |
|------|----------|
| SLOAD（存储读取） | 200 |
| SSTORE（新键） | 20,000 |
| SSTORE（修改已有键） | 5,000 |
| CALL（跨合约） | 700 |
| LOG（每主题） | 375 |
| keccak256 | 30 + 6 × ⌈data_len / 32⌉ |
| sha256 | 60 + 12 × ⌈data_len / 32⌉ |
| 内存页（64 KiB） | 6,400 |

计算 Gas 与 Wasmtime Fuel 按 1:1 近似。总 Gas = fuel_consumed + host_gas_consumed。

---

## 项目结构

```
.
├── build.zig                    # 构建配置
├── sandbox.zig                  # Guest: 基础沙箱 (add, panic)
├── contract_counter.zig         # Guest: 带存储和事件的计数器
├── contract_composite.zig       # Guest: 跨合约调用演示
├── contract_crypto.zig          # Guest: keccak256/sha256 演示
├── contract_token.zig           # Guest: ERC-20 风格代币
│
├── src/
│   ├── main.zig                 # Host 入口 / 演示
│   ├── tests.zig                # 集成测试 (15 个测试)
│   │
│   ├── sandbox.zig              # 核心沙箱管理器
│   ├── sandbox_bindings.zig     # Wasmtime C API 声明
│   ├── sandbox_memory.zig       # Guest 内存读取辅助
│   ├── wasm_validator.zig       # 模块验证
│   │
│   ├── fuel_meter.zig           # 指令级 Fuel 追踪
│   ├── gas_meter.zig            # Host 调用 Gas 计量
│   ├── limits.zig               # 资源限制和配置
│   │
│   ├── host_exports.zig         # 暴露给 Guest 的 Host 回调
│   │
│   ├── extensions/
│   │   ├── plugin_registry.zig  # 插件加载/卸载/调用/重载
│   │   ├── contract_registry.zig # 合约部署 + 跨合约调度
│   │   ├── state_store.zig      # 内存 / LMDB 状态后端
│   │   ├── event_log.zig        # 结构化事件缓冲区
│   │   ├── io_pipeline.zig      # I/O 缓冲区 + 看门狗
│   │   └── module_cache.zig     # 编译模块缓存
│   │
│   └── lmdb_bindings.zig        # LMDB C API 声明
│
└── README.md                    # 本文档
```

---

## 贡献指南

欢迎贡献！请遵循以下步骤：

1. 确保 `zig build` 和所有测试通过。
2. 遵循现有 Zig 风格（函数 camelCase，类型 TitleCase）。
3. 为新功能添加测试。
4. 更新本文档以反映用户可见的变更。

安全 issue 请私下报告。

---

## 许可证

MIT License — 详见 [LICENSE](LICENSE)。

---

## 致谢

- [Wasmtime](https://wasmtime.dev/) by Bytecode Alliance — WASM 引擎
- [Zig](https://ziglang.org/) — 编程语言
- Ethereum EVM — Gas 定价灵感来源
