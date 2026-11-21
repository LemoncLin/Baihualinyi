# iOS 工程 GitHub Actions 自动上传 TestFlight 工具

把 **Capacitor 混合开发的 iOS 工程**通过 GitHub Actions 自动完成「签名 → 归档 → 导出 IPA → 上传 TestFlight」的整套工具链。支持手动触发、构建号自动递增，大文件资源通过 GitHub Release 托管，规避 GitHub 100MB 单文件推送限制。

---

## 一、整体架构与工作原理

```
本地 ios.rar
   │  (scripts/setup_project.sh 解压整理)
   ▼
ios/ 工程 + public Web 资源
   │  (scripts/cleanup_deadcode.sh 清理死代码)
   │  (scripts/pack_large_assets.sh 剥离 >45MB 大文件)
   ├──► 小文件 ──► Git 仓库（GitHub）
   │
   └──► 大文件 ──► large-assets.tar.gz ──► GitHub Release 资产
                                              │
GitHub Actions（手动触发）                     │
   1. 检出代码                                  │
   2. 从 Release 下载 tar.gz 并按 manifest 还原 ◄┘
   3. 安装 .p12 证书 + .mobileprovision 描述文件（来自 Secrets）
   4. 构建号自动 +1
   5. xcodebuild archive → 导出 IPA
   6. xcrun altool 上传 App Store Connect（TestFlight）
```

### 工程关键参数（已自动识别）

| 项 | 值 |
|---|---|
| 工程路径 | `ios/App/App.xcodeproj` |
| Scheme / Target | `App` |
| Bundle ID | `com.megmt.baihualinyi` |
| 应用名称 | 白桦林奕 |
| 依赖管理 | 本地 SPM 包 `CapApp-SPM`（远程拉取 capacitor-swift-pm 8.6.2），无 CocoaPods |
| 部署目标 | iOS 15.0 |

---

## 二、你需要准备的材料清单

### 1. Apple 开发者侧（付费 $99 账号）

| 材料 | 用途 | 获取位置 |
|---|---|---|
| 发布证书 `.p12` + 导出密码 | CI 代码签名 | 钥匙串导出，见下方步骤 A |
| App Store 描述文件 `.mobileprovision` | 关联 Bundle ID 的发布授权 | Apple Developer 网站，见步骤 B |
| **Team ID**（10 位） | 标识开发团队 | 本项目团队 ID 为 `99289A3HF5`（深圳 Megmt） |
| App Store Connect API 密钥 `.p8` + Key ID + Issuer ID | 上传 IPA 的鉴权 | App Store Connect → 用户和访问 → 密钥，见步骤 C |

### 2. GitHub 侧

- 一个 GitHub 仓库（私有仓库即可）
- 在仓库中配置 Secrets 和 Variables（见第四节）

---

## 三、签名材料制作详细步骤

### 步骤 A：生成发布证书并导出 .p12

1. 打开 Mac「钥匙串访问」→ 菜单「证书助理」→「从证书颁发机构请求证书」
2. 填写邮箱，选择「存储到磁盘」，得到 `CertificateSigningRequest.certSigningRequest`
3. 登录 [Apple Developer 网站](https://developer.apple.com/account) → Certificates → 「+」
4. 选择 **Apple Distribution**（注意不是 Apple Development），上传刚才的 CSR，生成证书
5. 下载证书（`.cer`），双击导入钥匙串
6. 在钥匙串中找到该证书（含其下的私钥），右键「导出」，选择 **.p12** 格式
7. 设置一个**导出密码**（此密码即后面的 `P12_PASSWORD`），得到 `distribution.p12`

### 步骤 B：创建 App Store 描述文件

1. Apple Developer 网站 → Identifiers，确认存在 App ID：`com.megmt.baihualinyi`（没有就新建）
2. Profiles → 「+」→ 选择 **App Store**（在 Distribution 分组下）
3. 选择上一步的 App ID → 选择步骤 A 的证书 → 命名（例如 `Baihualin_AppStore`）
4. 下载得到 `.mobileprovision` 文件
5. **记下描述文件的名称**，后面要填进 `ExportOptions.plist`

### 步骤 C：创建 App Store Connect API 密钥

1. 登录 [App Store Connect](https://appstoreconnect.apple.com) →「用户和访问」→「集成」→「App Store Connect API」→「团队密钥」
2. 点击「生成 API 密钥」，名称随意，访问权限选 **管理员（Admin）** 或「App 管理」
3. 生成后记录：
   - **Key ID**（如 `ABC1234DE5`）
   - **Issuer ID**（页面顶部的 UUID）
4. 下载 API 私钥（`.p8` 文件，**只能下载一次，务必妥善保存**）

---

## 四、GitHub 仓库配置

### 4.1 配置 Secrets（仓库 Settings → Secrets and variables → Actions → New secret）

| Secret 名称 | 填入内容 |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | .p12 文件的 Base64 字符串 |
| `P12_PASSWORD` | 导出 .p12 时设置的密码 |
| `PROVISION_PROFILE_BASE64` | .mobileprovision 文件的 Base64 字符串 |
| `APP_STORE_CONNECT_API_KEY` | .p8 文件的**完整文本内容** |
| `APP_STORE_CONNECT_KEY_ID` | 步骤 C 的 Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | 步骤 C 的 Issuer ID |

> Base64 字符串可用本仓库脚本生成：
> `./scripts/make_secrets.sh distribution.p12 profile.mobileprovision`
> （脚本同时会打印描述文件名称、UUID、Team ID，方便填写后续配置）

### 4.2 配置 Variables（同页面切到 Variables 标签）

| Variable 名称 | 填入内容 |
|---|---|
| `DEVELOPMENT_TEAM` | 固定填 `99289A3HF5` |
| `ASSET_RELEASE_TAG` | 大文件资产包所在 Release 的 tag，默认 `v1.0-assets` |

### 4.3 修改 ExportOptions.plist

编辑 `scripts/ExportOptions.plist`，Team ID 已填好（`99289A3HF5`），只需替换一处占位：

- `YOUR_PROVISIONING_PROFILE_NAME` → 步骤 B 记下的描述文件名称

---

## 五、大文件资产包上传（仅首次 / 资源更新时）

工程中超过 45MB 的视频/大图已被打包为 `release-assets/large-assets.tar.gz`（不进 Git）。

**方式一：网页上传**
1. GitHub 仓库 → Releases → Draft a new release
2. Tag 填 `v1.0-assets`（与 Variable `ASSET_RELEASE_TAG` 一致）
3. 把 `release-assets/large-assets.tar.gz` 拖入附件区
4. 发布

**方式二：命令行（需安装 gh）**
```bash
gh release create v1.0-assets \
  release-assets/large-assets.tar.gz \
  --title "大文件资产包" \
  --notes "CI 构建依赖的视频/大图资源"
```

> 清单文件 `release-assets/large-assets.manifest.txt` 已提交进 Git，CI 下载后会用它做 SHA256 完整性校验。

---

## 六、触发构建与上传

1. 推送代码到 GitHub
2. 仓库 → **Actions** 标签 → 左侧选择「构建并上传 TestFlight」
3. 右侧「Run workflow」：
   - `skip_upload`：默认不勾（正式上传）；勾上则只导出 IPA 不上传，用于验证
   - `marketing_version`：留空沿用工程版本；填如 `1.1.0` 可临时覆盖
4. 运行后可在页面实时查看日志，构建号每次自动 +1
5. 上传成功后，IPA 会出现在 App Store Connect 的 TestFlight 中（Apple 处理通常需几分钟到半小时，首次可能收到合规邮件）

---

## 七、脚本说明（scripts/ 目录）

| 脚本 | 作用 | 运行环境 |
|---|---|---|
| `setup_project.sh` | 从 rar/zip 解压并整理出 ios 工程、初始化 Git | 本地 |
| `cleanup_deadcode.sh` | 清理零引用旧版全景目录与工具残留（先预览 `--apply` 执行） | 本地 |
| `pack_large_assets.sh` | 剥离 >45MB 大文件，生成 tar.gz 与校验清单 | 本地 |
| `restore_large_assets.sh` | 把大文件还原回工程，供本地 Xcode 调试 | 本地 |
| `make_secrets.sh` | 证书/描述文件转 Base64 并解析描述文件信息 | 本地（macOS 解析更完整） |
| `import_certificate.sh` | CI 中安装证书与描述文件（工作流自动调用） | CI |
| `ExportOptions.plist` | IPA 导出配置（需替换 Team ID 与描述文件名） | CI |

---

## 八、常见问题与排查

**Q: 构建报 `No profiles for com.megmt.baihualinyi`？**
A: 描述文件的 Bundle ID 与工程不一致，或 `ExportOptions.plist` 中的描述文件名称填错。用 `make_secrets.sh` 查看正确名称。

**Q: 报 `Code Signing Failed` / 钥匙串相关错误？**
A: 确认 `.p12` 是 **Apple Distribution** 证书（不是 Development），且 `P12_PASSWORD` 与导出密码一致。

**Q: TestFlight 提示构建号重复？**
A: 本工具每次运行构建号自动 +1，正常不会重复。若手动改过工程号，可在触发时调整。

**Q: 大文件下载步骤失败？**
A: 确认 Release 的 tag 与 Variable `ASSET_RELEASE_TAG` 完全一致，且资产名严格为 `large-assets.tar.gz`。私有仓库工作流内置 token 已具备下载权限。

**Q: SHA256 校验失败？**
A: 资产包与 manifest 不匹配。资源更新后需重新运行 `pack_large_assets.sh` 并重新上传 Release，同时提交新的 manifest。

**Q: 以后网页资源（public）更新了怎么办？**
A: 替换 `ios/App/App/public/` 内对应文件；若新增了 >45MB 的文件，重新跑 `pack_large_assets.sh` 并更新 Release；小文件直接提交 Git 即可。

---

## 九、目录结构速览

```
.
├── .github/workflows/upload-testflight.yml   # CI 主工作流
├── scripts/
│   ├── import_certificate.sh                 # CI 装证书
│   ├── ExportOptions.plist                   # 导出配置（需改 TeamID）
│   ├── setup_project.sh                      # 一键解压整理
│   ├── cleanup_deadcode.sh                  # 死代码清理
│   ├── pack_large_assets.sh                 # 大文件剥离打包
│   ├── restore_large_assets.sh              # 大文件本地还原
│   └── make_secrets.sh                      # Secret 生成助手
├── release-assets/
│   ├── large-assets.manifest.txt            # 校验清单（进 Git）
│   └── large-assets.tar.gz                  # 资产包（进 Release，不进 Git）
├── ios/                                      # Xcode 工程 + Web 资源
└── .large-assets-stash/                      # 本地暂存的大文件（不进 Git）
```
