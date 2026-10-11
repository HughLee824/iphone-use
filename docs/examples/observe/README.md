# 观察输出示例

[observe.cli.example.txt](observe.cli.example.txt) 展示 Calculator 界面的 CLI 紧凑输出，包含截图路径、观察状态、AX 来源和元素引用。它由已记录输出整理而来；会话路径、ID 和时间戳已替换为示例值，不附带原始截图，也不能直接用于当前设备操作。

## 如何阅读

- `observation=o4` 与行内 `[e24]` 组合为完整引用 `o4:e24`。
- `screenshot` 是供调用 agent 用读图工具打开的 PNG 路径；示例路径是占位值。
- `pixels` 是截图像素尺寸，`screen_points` 和元素 frame 使用屏幕点，两者不能混用。
- `refs=current` 表示宿主尚未使引用失效，不证明控件仍可点击或画面持续未变。
- `source_truncated=false` 只表示本次采集没有达到节点上限，不表示得到 App 的全部界面或 Web DOM。
- `snapshot` 指向同次观察的缓存节点。`inspect o4` 分页读取详情，`inspect o4 --query TEXT` 在已采集数据中搜索。

截图与 AX 分开采集；应实际读取图片再决定动作。派发动作后重新 `observe`，不要把示例引用或旧引用用于下一次操作。完整规则见[观察契约](../../observations.md)和[动作接口](../../actions.md)。

## 示例与测试数据的区别

公开示例用于解释当前 CLI 格式；回归测试数据位于 [Tests/IPhoneUseCoreTests/Fixtures](../../../Tests/IPhoneUseCoreTests/Fixtures)，通过 SwiftPM 资源加载。历史格式草稿、原始设备响应和 XCTest 调试转储仅留在本地，不再作为公开文档或测试运行依赖。
