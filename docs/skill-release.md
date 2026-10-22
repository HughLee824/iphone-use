# 通用 skill 的 npm 发布

`iphone-use-skill` 由 `.github/workflows/publish-skill.yml` 发布。维护者本机只做打包、安装及真机验收，不执行 `npm publish`。现有 CLI/Homebrew 草稿流程和 `dsh-iphone-use` 是独立渠道，本工作流不发布它们。

## 发布顺序

1. 在功能分支修改唯一 skill 源及安装器，通过 PR 审阅合入 main。版本需与 `packages/iphone-use-skill/package.json` 一致；用 `scripts/sync-plugin.py` 同步插件副本。
2. 等待该 main 提交的 CI 成功。完成并记录相应的本地真机验收；云端安装测试不能替代真机证据。
3. 在 GitHub Actions 选择 **Publish portable skill**，选择 main，输入源文件中已有的新版本。不允许从 PR/其他分支发布，也不在每次普通合并时自动发布。
4. 工作流校验相同 SHA 的 main CI、版本、registry 未占用、生成文件同步和安装器测试；生成完整 tgz，测试该 tgz，然后通过 OIDC 发布，并等待 registry 提供相同 integrity 的包。
5. 工作流以全新缓存按公开版本安装 Cursor/OpenCode，检查重复安装、托管状态、卸载与残留。成功结果关联 GitHub Actions 源提交及 npm provenance。真机范围独立记录。

失败后先判断是否已经被 npm 接受。包处理或安装核验失败不意味着发布失败；禁止直接重发或改写已发布版本。可下载该运行的 `portable-skill-package` artifact 核对归档与 integrity，并用其中的 `npm pack --json` 输出运行发布核验脚本：`python3 scripts/verify-skill-publication.py /path/to/skill-pack.json`。本脚本会临时安装并卸载 skill，但不会发布、改 dist-tag 或操作手机。

若包已发布但 CI 验证失败，可在同一个工作流勾选 **verify_only**，输入已发布版本。它仍要求当前 main 的 CI 成功及版本匹配，重新构建归档并核对公开包的完整性，但跳过发布步骤。只有打包内容与已发布包完全相同才会通过；这次验证的源码提交不会替换原发布的 provenance。普通发布模式仍拒绝已存在的版本。

npm 的版本详情、安装索引及 tarball 可能分批可见。验证脚本输出 npm 原始错误，仅对 `ETARGET`/`E404` 做最多 16 次、间隔 20 秒的安装重试，并强制重新检查在线索引；冲突或其他安装错误立即失败。

## 一次性 Trusted Publisher 配置

本仓库未存储 npm 写入 token。发布前需要以下配置；仅提交工作流不代表 OIDC 已经生效：

- GitHub environment 名称 `npm`，部署分支只允许 `main`；需要时在该环境设置发布审批。
- npm 的 `iphone-use-skill` 包设置中添加 GitHub Actions Trusted Publisher：owner `hughlee824`、repository `iphone-use`、workflow filename `publish-skill.yml`、environment `npm`，允许 `npm publish`。
- 使用 GitHub-hosted runner 与 Node 24，npm 至少 11.5.1；发布 job 只有必要的 `contents: read`、`actions: read` 和 `id-token: write` 权限。无需复制本机登录凭据，也不设置 `NODE_AUTH_TOKEN`。

新 trusted publisher 必须在 npm 要求的期限内完成首次发布，因此在 PR 合并、准备正式运行时配置。具体规则以 [npm 官方 Trusted Publishing 文档](https://docs.npmjs.com/trusted-publishers/)为准。

## 0.1.12 的历史例外

2026-10-17，`iphone-use-skill@0.1.12` 在 PR #25 尚未合并时由本机直接提交 npm。这是一次发布流程错误，不是上述 CI 工作流产物；不能补称它具有 GitHub Actions 发布来源，也不能重新发布同版本来补造历史。

该 tgz 的 SHA-1 为 `36d6c4d4b7e88314f83f5f65430162e4ac3ce829`，内容与功能分支 `b24654c` 中的打包源逐文件一致。该提交的 CI 与 Cursor Runner 真机导航验收通过；这些检查不能替代 CI 发布身份。后续新版本按本页流程发布，已有版本的撤回或废弃需单独决定。
