# Vhisper

一款高效的语音输入法应用，按住快捷键说话，松开即可将语音转换为文字并自动输入到当前光标位置。

## 功能特性

- **快捷键触发**：按住 Alt 键（可自定义）开始录音，松开自动识别
- **多 ASR 引擎支持**：
  - 通义千问 ASR（默认，中英文混合识别效果好）
  - DashScope Paraformer
  - OpenAI Whisper
  - FunASR（本地部署）
- **LLM 文本润色**：可选启用 LLM 对识别结果进行纠错和润色
- **跨平台**：支持 macOS 和 Windows
- **系统托盘**：后台运行，随时可用

## 环境要求

- **Node.js**: >= 22.0.0
- **pnpm**: >= 8.0.0
- **Rust**: >= 1.70.0

## 安装

### 下载安装包

前往 [Releases](https://github.com/JobinJia/Vhisper/releases) 页面下载对应平台的安装包：

- **macOS**: `.dmg` 文件
- **Windows**: `.msi` 或 `.exe` 安装程序

### 从源码构建

```bash
# 克隆仓库
git clone https://github.com/JobinJia/Vhisper.git
cd Vhisper

# 安装依赖
pnpm install

# 开发模式运行
pnpm start

# 构建生产版本
pnpm tauri build
```

## 配置

首次使用需要配置 ASR 服务的 API Key。

### 获取 API Key

**通义千问 ASR（推荐）**：
1. 访问 [阿里云百炼控制台](https://bailian.console.aliyun.com/)
2. 完成实名认证
3. 前往「密钥管理」创建 API Key

### 应用设置

1. 点击系统托盘图标，打开设置界面
2. 选择 ASR 提供商（推荐「通义千问」）
3. 填入 API Key
4. 点击「测试」验证配置
5. 保存设置

## 使用方法

1. 启动应用后，会在系统托盘显示图标
2. 按住 **Alt** 键（默认快捷键）开始录音
3. 对着麦克风说话
4. 松开 Alt 键，语音将自动转换为文字并输入到当前光标位置

## 配置选项

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| 触发键 | 录音快捷键 | Alt |
| ASR 提供商 | 语音识别服务 | 通义千问 |
| LLM 润色 | 是否启用文本纠错 | 启用 |
| LLM 提供商 | 文本润色服务 | DashScope |

## 技术栈

- **前端**: Vue 3 + TypeScript
- **后端**: Rust + Tauri 2
- **音频**: cpal (跨平台音频库)

## 开发

```bash
# 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 安装 pnpm（如未安装）
npm install -g pnpm

# 安装依赖
pnpm install

# 启动开发服务器
pnpm start

# 构建
pnpm tauri build
```

> 注意：本项目仅支持 pnpm 作为包管理器，不支持 npm 或 yarn。

## 许可证

[MIT](LICENSE)
