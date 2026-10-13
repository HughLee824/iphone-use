# 预览开孔逐机型校准（2026-10-13）

范围：当前预览支持的 32 个精确 productType、31 款机型。包括官方素材目录中的全部 23 款，以及 16e、17 / Air / 17e、18 Pro / Pro Max。未登记机型仍使用无猜测开孔的通用外框，不将“所有支持机型”扩张为所有历代 iPhone。

## 依据与方法

- 11–16 的 23 款机型：对照 `assets/preview/catalog.json` 中对应 PNG，核对透明屏幕开口。用少量圆弧参数拟合刘海主体、下圆角和两侧接入屏幕的肩部；灵动岛使用独立的 x/y、宽、高及圆角。没有把像素、纹理或整条描摹路径放入自绘组件。
- 16e、17 / Air / 17e、18 Pro / Pro Max：逐型号读取 [Apple 公开尺寸图](https://developer.apple.com/accessories/dimensional-drawings/)中的显示有效宽度、开孔宽高、距机身顶部的位置及屏幕内缩距离，再换算为屏幕坐标。对照可用 Product Bezel 正面参考检查外观，未新增受限 PNG 到源码或分发包。
- 以屏幕宽度 400 为单位，坐标原点为竖屏有效屏幕左上角。新机型胶囊 y = (开孔中心距机身顶部 − 半高 − 屏幕内缩) × 400 / 有效屏幕宽度。参考图自身的透明边距不会混入开孔坐标。
- 听筒、镜头中心和大小分别设置；11/12 的听筒在刘海内，13/14 非 Pro/e 的听筒在上边框，前镜头在左侧；灵动岛镜头在右侧。镜头高光、听筒纹理、金属反射和侧键仍为视觉近似，不作为工程尺寸或逐像素复刻承诺。

## 参数清单

下表是开孔主体，刘海上沿另有小圆弧肩部，因此最顶端宽度比主体稍大。单位均相对于宽 400 的屏幕，非手机像素或毫米。

| productType | 型号 | 形状 | 主体宽 × 高 | 距屏幕顶部 | 下圆角 / 肩部 | 参考 |
| --- | --- | --- | --- | --- | --- | --- |
| `iPhone12,5` | iPhone 11 Pro Max | 刘海 | 202.25 × 28.36 | 0.00 | 20.95 / 4.83 | `iphone-11-pro-max-portrait.png` |
| `iPhone12,3` | iPhone 11 Pro | 刘海 | 223.51 × 31.34 | 0.00 | 22.97 / 5.34 | `iphone-11-pro-portrait.png` |
| `iPhone12,1` | iPhone 11 | 刘海 | 223.64 × 31.48 | 0.00 | 25.42 / 4.60 | `iphone-11-portrait.png` |
| `iPhone13,4` | iPhone 12 Pro Max | 刘海 | 196.40 × 29.64 | 0.00 | 21.68 / 4.52 | `iphone-12-pro-max-portrait.png` |
| `iPhone13,3` | iPhone 12 Pro | 刘海 | 215.74 × 32.82 | 0.00 | 23.25 / 6.32 | `iphone-12-pro-portrait.png` |
| `iPhone13,1` | iPhone 12 mini | 刘海 | 242.25 × 36.33 | 0.00 | 26.36 / 6.23 | `iphone-12-mini-portrait.png` |
| `iPhone13,2` | iPhone 12 | 刘海 | 215.67 × 32.82 | 0.00 | 23.08 / 6.32 | `iphone-12-portrait.png` |
| `iPhone14,3` | iPhone 13 Pro Max | 刘海 | 150.96 × 31.46 | 0.00 | 21.81 / 5.30 | `iphone-13-pro-max-portrait.png` |
| `iPhone14,2` | iPhone 13 Pro | 刘海 | 165.94 × 34.53 | 0.00 | 23.93 / 5.81 | `iphone-13-pro-portrait.png` |
| `iPhone14,4` | iPhone 13 mini | 刘海 | 185.73 × 40.00 | 0.00 | 26.48 / 6.85 | `iphone-13-mini-portrait.png` |
| `iPhone14,5` | iPhone 13 | 刘海 | 165.94 × 34.53 | 0.00 | 23.93 / 5.81 | `iphone-13-portrait.png` |
| `iPhone14,8` | iPhone 14 Plus | 刘海 | 150.67 × 31.15 | 0.00 | 21.34 / 4.98 | `iphone-14-plus-portrait.png` |
| `iPhone15,3` | iPhone 14 Pro Max | 灵动岛 | 116.59 × 34.11 | 10.54 | 17.05 / 0.00 | `iphone-14-pro-max-portrait.png` |
| `iPhone15,2` | iPhone 14 Pro | 灵动岛 | 127.23 × 37.32 | 11.54 | 18.66 / 0.00 | `iphone-14-pro-portrait.png` |
| `iPhone14,7` | iPhone 14 | 刘海 | 165.73 × 34.53 | 0.00 | 23.59 / 6.50 | `iphone-14-portrait.png` |
| `iPhone15,5` | iPhone 15 Plus | 灵动岛 | 116.59 × 34.11 | 10.54 | 17.05 / 0.00 | `iphone-15-plus-portrait.png` |
| `iPhone16,2` | iPhone 15 Pro Max | 灵动岛 | 116.59 × 34.11 | 10.54 | 17.05 / 0.00 | `iphone-15-pro-max-portrait.png` |
| `iPhone16,1` | iPhone 15 Pro | 灵动岛 | 127.23 × 37.32 | 11.54 | 18.66 / 0.00 | `iphone-15-pro-portrait.png` |
| `iPhone15,4` | iPhone 15 | 灵动岛 | 127.23 × 37.32 | 11.54 | 18.66 / 0.00 | `iphone-15-portrait.png` |
| `iPhone17,4` | iPhone 16 Plus | 灵动岛 | 116.59 × 34.11 | 10.54 | 17.05 / 0.00 | `iphone-16-plus-portrait.png` |
| `iPhone17,2` | iPhone 16 Pro Max | 灵动岛 | 113.33 × 32.73 | 13.03 | 16.36 / 0.00 | `iphone-16-pro-max-portrait.png` |
| `iPhone17,1` | iPhone 16 Pro | 灵动岛 | 124.05 × 35.49 | 14.26 | 17.74 / 0.00 | `iphone-16-pro-portrait.png` |
| `iPhone17,3` | iPhone 16 | 灵动岛 | 127.23 × 37.32 | 11.54 | 18.66 / 0.00 | `iphone-16-portrait.png` |
| `iPhone17,5` | iPhone 16e | 刘海 | 165.93 × 34.56 | 0.00 | 23.04 / 5.08 | [iphone-16e.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-16e.pdf) |
| `iPhone18,5` | iPhone 17e | 刘海 | 165.93 × 34.56 | 0.00 | 23.04 / 5.08 | [iphone-17e.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-17e.pdf) |
| `iPhone18,1` | iPhone 17 Pro | 灵动岛 | 124.74 × 36.47 | 13.91 | 18.24 / 0.00 | [iphone-17-pro.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-17-pro.pdf) |
| `iPhone18,2` | iPhone 17 Pro Max | 灵动岛 | 113.97 × 33.32 | 12.71 | 16.66 / 0.00 | [iphone-17-pro-max.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-17-pro-max.pdf) |
| `iPhone18,3` | iPhone 17 | 灵动岛 | 124.62 × 36.47 | 13.91 | 18.24 / 0.00 | [iphone-17.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-17.pdf) |
| `iPhone18,4` | iPhone Air | 灵动岛 | 119.40 × 34.91 | 19.01 | 17.46 / 0.00 | [iphone-air.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-air.pdf) |
| `iPhone19,2` | iPhone 18 Pro | 灵动岛 | 94.10 × 36.47 | 13.91 | 18.24 / 0.00 | [iphone-18-pro.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-18-pro.pdf) |
| `iPhone19,3` | iPhone 18 Pro Max | 灵动岛 | 86.08 × 33.32 | 12.71 | 16.66 / 0.00 | [iphone-18-pro-max.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-18-pro-max.pdf) |
| `iPhone19,7` | iPhone 18 Pro Max | 灵动岛 | 86.08 × 33.32 | 12.71 | 16.66 / 0.00 | [iphone-18-pro-max.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-18-pro-max.pdf) |

## 校准精度与验收边界

旧版 PNG 的刘海圆弧拟合是近似：在宽 400 坐标系下，侧边拟合 RMS 最大约 0.36；紧贴圆弧顶/底端的栅格阈值误差更大，回归检查的水平边界容差为 3.2。灵动岛与刘海的上下边、主体尺寸分别检查，不能用“布局能运行”替代几何校验。新机型的物理尺寸换算保留两位小数；这不是对应真机采集的验收结果。

`scripts/tests/fixtures/preview-hardware.json` 保存旧 PNG 的 SHA 与稀疏边界验收点，以及新机型的公开尺寸图数值。更换参考素材时需重新核对，测试不从实现参数反推期望值。

验证命令：`node --test scripts/tests/test_preview_metrics.mjs`。覆盖目录完整性、逐机型边界、公开尺寸换算、模型切换后的样式更新、四个方向、三个窗口尺寸下官方/自绘画面大小与中心不变、未知机型及素材失败回退、不变帧无装饰写入。浏览器测试使用明确标注的几何测试画面，不冒充所有型号真机。

本次修改仅影响两种控制模式共用的预览 HTML/CSS，不修改解码、媒体连接或录屏链路。此前 standard 的方向同步和 runner 的 XCTest 授权限制仍以[验收记录](local-preview-validation.md)为准。
