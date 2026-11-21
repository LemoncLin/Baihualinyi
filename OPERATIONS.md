# TestFlight 长期运营手册

本手册面向**已经跑通首次上传之后的日常运营**，回答三个问题：哪些数据必须填、新版本怎么二次提交、TestFlight 90 天到期怎么续。首次搭建流程见 [README.md](README.md)。

---

## 一、先理解 TestFlight 的 90 天规则

- TestFlight 的**每一个构建（build）有效期只有 90 天**，从上传成功那天算起，不是从有人安装算起。
- 到期后该构建对测试者失效，但**不会自动续期，也无法给旧构建续命**。唯一办法是**重新上传一个新构建**（构建号必须不同，本工具用 GitHub `run_number` 自动保证）。
- 因此"每三个月续一次"的本质 = **每隔约 90 天重新跑一次构建上传**。本工具已内置定时任务自动完成，见第三节。
- App 本身、App Store Connect 的 App 记录、证书描述文件都不会因为构建到期而消失。

---

## 二、哪些数据是"必须填"的（分两层，别混淆）

### 第 1 层：GitHub 侧配置——一次性填好，长期复用，三个月续期不用动

在仓库 **Settings → Secrets and variables → Actions**：

| 类型 | 名称 | 何时会失效 / 需更换 |
|---|---|---|
| Secret | `BUILD_CERTIFICATE_BASE64` | 发布证书到期（本项目证书 2027-06-11 到期）才换 |
| Secret | `P12_PASSWORD` | 换 .p12 时同步换 |
| Secret | `PROVISION_PROFILE_BASE64` | 描述文件到期（2027-06-11）才换 |
| Secret | `APPLE_ID` | 一般不变 |
| Secret | `APPLE_APP_SPECIFIC_PASSWORD` | **可能失效**：改 Apple ID 密码、主动吊销后需重新生成 |
| Variable | `DEVELOPMENT_TEAM` | 不变（`99289A3HF5`） |
| Variable | `ASSET_RELEASE_TAG` | 不变（`v1.0-assets`） |

> 结论：**纯三个月续期、内容不变时，这一层一个都不用改**。只有证书到期或 App 专用密码失效才需要回来更新。

### 第 2 层：App Store Connect 侧——按测试范围决定

| 数据 | 内部测试（团队成员，≤100 人） | 外部测试（外部人员/公开链接，≤1 万人） |
|---|---|---|
| 构建上传 | 必需 | 必需 |
| **Beta 应用描述**（测试说明） | 不需要 | **必填** |
| **反馈邮箱**（Feedback Email） | 不需要 | **必填** |
| 测试须知/登录演示账号 | 建议 | 常被审核要求 |
| Beta App Review 审核 | 免审，处理完即可装 | **首次必须过审**，后续多数构建免审或快审 |
| 出口合规加密声明 | 已在 Info.plist 声明，自动豁免 | 同左 |

**外部测试必填项填写位置**：App Store Connect → 你的 App → TestFlight →「测试信息（Test Information）」：
- Beta 应用描述：一句话说明这个版本测什么，例如"白桦林奕全景看房 App 测试版，验证全景漫游、沙盘、户型展示功能"
- 反馈邮箱：一个有人收的邮箱（测试者在 TestFlight 里点反馈会发到这里）
- 如有登录墙，在"审核信息"里提供演示账号密码

> 建议：自己/公司内部验证用**内部测试组**，免审核最快；要给客户/外部体验时再配外部测试组并补这两项。

---

## 三、每三个月自动续期（已配置，无需人工操作）

工作流已加入定时触发（`.github/workflows/upload-testflight.yml` 的 `schedule`）：

```
cron: "0 1 1 1,4,7,10 *"   # UTC 时间
对应北京时间：每年 1/4/7/10 月 1 日 09:00
```

- 每季度首月自动跑一次完整构建并上传新构建，间隔约 90 天，**在旧构建到期前就替换上新的**。
- 自动触发时 `skip_upload` 不生效，一定会上传；构建号自动取 `run_number`，不重复。
- 前提条件（平时保持即可）：
  1. 仓库的 Secrets 仍有效（尤其 App 专用密码没被吊销）
  2. Release `v1.0-assets` 的资产包还在
  3. GitHub Actions 定时任务在**仓库有活动记录时才稳定触发**；GitHub 对长期无活动仓库可能延迟或暂停 schedule。建议每季度初看一眼 Actions 历史确认它跑了；若没跑，手动点一次 Run workflow 即可。

### 想调整续期节奏

改工作流里的 cron。例如希望每两个月续一次（更保险)：
```yaml
schedule:
  - cron: "0 1 1 1,3,5,7,9,11 *"
```
> cron 五段含义：分 时 日 月 星期，均为 UTC。北京时间 = UTC+8。

---

## 四、二次及以后版本更新（拿到新 ios.rar 的标准操作）

### 方式 A：一键脚本（推荐）

把新的 `ios.rar` 放到仓库根目录（覆盖旧的），然后执行：

```bash
cd /mnt/c/Users/LQH/Desktop/githubactionsTotestflight
./scripts/update_from_rar.sh            # 默认读 ./ios.rar
# 或指定路径：./scripts/update_from_rar.sh /path/to/new.rar
```

脚本会自动完成：备份当前版本 → 解压新工程 → 纠正 Bundle ID（防止新包带回旧 ID）→ 清理死代码 → 重新剥离大文件生成资产包和校验清单。**它不会自动提交或发布**，结束后按它打印的提示，手动做 4 步：

1. `git status` 检查改动
2. 提交推送：
   ```bash
   git add -A
   git commit -m "release: 版本更新"
   git push
   ```
3. **更新 Release 资产**（仅当大文件有变化时必须做；小文件改动可跳过）：
   - Releases → `v1.0-assets` → Edit → 删掉旧 `large-assets.tar.gz` → 拖入新生成的同名文件 → Update release
4. Actions → Run workflow（不勾 skip_upload 即正式上传新构建）

### 方式 B：分步手动（脚本出问题时的兜底）

```bash
# 1. 解压整理（会备份已有 ios 目录）
./scripts/setup_project.sh ios.rar
# 2. 清理死代码
./scripts/cleanup_deadcode.sh --apply
# 3. 剥离大文件、生成资产包与清单
./scripts/pack_large_assets.sh
# 4. 之后同方式 A 的提交、更新 Release、触发工作流
```

### 二次更新判断清单

- 只改了网页小资源（图片/JS/HTML 等 <45MB 文件）：正常 commit/push 即可，**不用动 Release**，CI 直接从 Git 拿。
- 新增/替换了 ≥45MB 的大视频或大图：必须重跑资产打包并**覆盖 Release 资产**，否则 CI 还原的还是旧资源（SHA256 校验也会失败提醒你）。
- 改了版本号：可在触发工作流时用 `marketing_version` 临时指定，无需改工程。
- 换新 Mac/重装系统导致 .p12 私钥丢失：重新走 README 的证书制作流程并更新对应 Secret。

---

## 五、常见运营场景速查

| 场景 | 怎么做 |
|---|---|
| 只想验证能不能打包，不上传 | 触发时勾选 `skip_upload`，产物在 Artifacts 下载 IPA |
| 临时发一个新版本号 | Run workflow 时填 `marketing_version`（如 1.2.0） |
| 定时任务好像没跑 | Actions 页看历史；没有就手动 Run workflow，再检查 cron 时区 |
| App 专用密码失效导致上传报 -26000 | appleid.apple.com 重新生成，更新 Secret `APPLE_APP_SPECIFIC_PASSWORD` |
| 证书 2027 年快到期 | 提前在开发者后台续期，重导 .p12/描述文件，更新两个 Base64 Secret |
| 测试者反馈入口收不到邮件 | 检查 TestFlight「测试信息」里的反馈邮箱是否正确、有人监控 |
| 外部测试卡在审核 | 补全测试信息、演示账号，必要时在审核备注里说明 App 用途 |
| 想回滚到上一版工程 | 用 `.update-backup/<时间戳>/ios` 目录恢复 |

---

## 六、关键时间点备忘（本项目）

| 项目 | 日期 / 值 |
|---|---|
| 发布证书到期 | 2027-06-11 |
| 描述文件到期 | 2027-06-11 |
| Bundle ID | com.megmt.baihualinyi |
| Team ID | 99289A3HF5 |
| 大文件 Release Tag | v1.0-assets |
| SDK 升级提醒（警告 90725） | **2027 年 4 月起**须用 iOS 27 SDK / Xcode 27 构建；工作流动态选最高 Xcode，届时自动满足，无需手动改 |
| 自动续期时间 | 每季度首月（1/4/7/10 月）1 日 北京时间 09:00 |
