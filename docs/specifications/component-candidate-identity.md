# 外部组件候选身份与快照组合契约

## 目的

Fovea 的跨仓候选门回答两个窄问题：给定一份 Git-free 组件源码树和一份外部身份文档，Fovea 实际编译、测试的字节是否与该身份精确一致；候选 manifest、构建和测试过程是否被约束在一个无网络、不可读取宿主源码、不可修改候选快照或 Fovea 不可变源码的本地操作系统沙箱中。

该门不证明作者身份、发布真实性、Git revision、tag、签名、供应链来源、受保护 CI 或 release qualification。上述声明必须由独立发布治理提供。

## Source identity v2

组件身份文档必须包含：

- `schemaVersion` 与组件专属 `identityID`；
- 完整顶层覆盖根；
- 只允许出现在仓库顶层的构建/版本控制排除项；
- 允许在任意层级忽略的临时文件名；
- 必要时列出的精确排除子树；
- 每个被覆盖文件的 POSIX 相对路径、字节数、SHA-256 和可执行位；
- 对 schema、identity ID、覆盖契约和完整文件清单计算的总 SHA-256。

顶层未知项、未声明的嵌套 `.build/.git/.swiftpm/.artifacts`、符号链接、特殊文件、路径逃逸、重复或乱序路径、missing/extra 文件、字节数、摘要或可执行位漂移均失败关闭。

ImageCraft 仅声明两个精确排除子树：

- `Fixtures/ConsumerSmoke/.build`
- `Fixtures/ConsumerSmoke/.swiftpm`

它们是外部消费者验证缓存，不进入发布候选。相同名称出现在其他嵌套路径时仍被拒绝。Akashic 当前没有精确排除子树。

## Fovea 组合算法

`scripts/verify-component-candidate-clean-copy.py` 执行以下步骤：

1. 同时接收组件 Git-free 源码路径和外部 JSON 身份文档。
2. **不执行**候选仓库中的身份捕获工具；该工具只作为被哈希的普通文件处理。
3. Fovea 使用自己固定的组件覆盖契约重新枚举源码树，并复算每个文件的字节数、SHA-256、可执行位和总身份摘要。
4. 从再次读取并校验的内存字节物化隔离候选快照，规范化写出可执行或不可执行模式；构建不再引用原候选工作区。
5. 仅在沙箱外解析当前受支持的公开精确 pin；此时尚未把 SwiftPM 切换到候选快照，因此候选 manifest 不会在沙箱前执行。
6. 生成 `FOVEA-COMPONENT-CANDIDATE-SANDBOX-V1` Seatbelt profile。它禁止全部网络、禁止读取宿主用户主目录、默认禁止文件写入，只允许专用 State 根、SwiftPM 的 `Packages/` 与 `Package.resolved` 状态、已确认的 Swift 工具链临时路径和 Fovea 测试专属临时根。
7. 在沙箱内执行实际逃逸探针：专用 State 写入必须成功；宿主 Fovea 源码读取、隔离 Fovea `Package.swift` 写入、宿主写逃逸、每个已提供候选快照写入和 IPv4 connect 必须以 `EPERM/EACCES` 失败。单组件与双组件候选使用同一策略，探针数量随候选数变化。
8. 在同一沙箱内执行 `swift package edit`、依赖路径检查和完整 Fovea 测试。当前隔离重放使用 SwiftPM `native` build system，并显式关闭 SwiftPM 的嵌套沙箱；外层 Seatbelt 才是权威隔离边界。
9. 当前工作树要求精确 838 项测试且无 Fovea 自有 warning；测试结束后再次验证所有已提供候选身份，并比较 Fovea 不可变源码前后摘要。

因此，原候选在校验后的变化不会改变实际构建输入；候选快照和 Fovea 不可变源码在构建期间的变化也不会被静默接受。候选 manifest、编译器子进程和测试进程不能读取原始宿主仓库或用户主目录、修改已验证源码，亦不能访问网络。

## 操作系统隔离边界

schema-4 报告证明的是**宿主侧候选执行约束**，不是任意意义上的完全互不信任：

- 候选可以读取隔离临时目录中的 Fovea 源码，因为 SwiftPM 以一个源码包图共同编译；因此 `mutualConfidentialityClaim=false`。
- 当前 Seatbelt 资格绑定 SwiftPM `native` build system。该后端已被 SwiftPM 标记为 deprecated；默认 `swiftbuild` 的隔离资格仍为 `false`，不能把本结果外推为默认构建后端等价证明。
- 沙箱不证明编译器、Xcode、macOS 内核或 Seatbelt 本身不存在漏洞，也不等于虚拟机、独立用户、容器或远程受保护 CI。
- 沙箱外的 resolve 仅处理当前公开精确 pin；候选 manifest 的首次执行发生在 Seatbelt 内。

更强的双向保密、独立权限域或 hostile compiler/plugin 模型，仍需要分离构建、二进制接口边界、独立 OS 用户/虚拟机和受保护 CI。

## 负向保留门

`scripts/verify-component-candidate-identity-negatives.py` 在不启动构建的情况下保留以下反例：

1. 未绑定顶层文件；
2. 身份清单遗漏现存源码；
3. 未声明的嵌套构建子树；
4. 符号链接条目；
5. 将候选身份工具替换为有副作用的程序——必须只因字节漂移失败，且程序不得执行；
6. 文件字节不变但可执行位漂移。

报告写入：

- `.artifacts/external-components/candidate-identity-negatives.json`
- `.artifacts/external-components/candidate-sandbox-probes.json`
- `.artifacts/external-components/candidate-clean-copy.json`

schema-4 主报告还绑定候选验证器、身份负向验证器、身份规范、沙箱策略模块、运行时 profile 和逃逸探针报告的 SHA-256。

## 本地命令

先由组件自身生成身份并物化 Git-free 候选，再运行：

```sh
python3 scripts/verify-component-candidate-clean-copy.py \
  --akashic-source /path/to/Akashic \
  --akashic-identity /path/to/Akashic-identity.json \
  --imagecraft-source /path/to/ImageCraft \
  --imagecraft-identity /path/to/ImageCraft-identity.json
```

只验证身份而不解析或构建 SwiftPM：

```sh
python3 scripts/verify-component-candidate-clean-copy.py \
  --identity-only \
  --akashic-source /path/to/Akashic \
  --akashic-identity /path/to/Akashic-identity.json \
  --imagecraft-source /path/to/ImageCraft \
  --imagecraft-identity /path/to/ImageCraft-identity.json
```

重放负向门：

```sh
python3 scripts/verify-component-candidate-identity-negatives.py \
  --akashic-source ../Akashic \
  --imagecraft-source ../ImageCraft
```
