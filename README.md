# Codex 设置和聊天记录备份守护

一个 Windows 用的 Codex 本地状态备份脚本。

它可以备份和恢复 Codex 的配置文件、插件状态、聊天记录、聊天索引和侧边栏聊天列表相关状态。适合在更新、误操作、配置损坏或聊天记录异常之前，先给当前正常状态留一份本地备份。

## 特点

- 只有一个主脚本：`codex-state-guardian.cmd`
- 双击即可打开中文菜单
- 支持保存 Codex 设置和聊天记录
- 支持恢复最新健康备份
- 支持恢复指定备份
- 恢复前会自动保存一份“恢复前备份”，方便回退
- 默认最多保留 5 个备份，超过会自动删除最旧备份
- 日常检查使用轻量指纹，减少卡顿

## 使用方法

下载或复制这个文件：

```text
codex-state-guardian.cmd
```

放到任意固定文件夹里，然后双击运行。

首次使用建议选择：

```text
1. 检查并保存健康备份
```

如果以后 Codex 设置、插件、聊天记录或聊天列表出现问题，先关闭 Codex，再运行脚本，选择：

```text
4. 恢复最新健康备份
```

恢复时需要手动输入：

```text
确认
```

不输入 `确认` 不会覆盖当前文件。

## 菜单

```text
1. 检查并保存健康备份
2. 查看当前状态
3. 列出备份
4. 恢复最新健康备份
5. 恢复指定备份
6. 强制保存一份健康备份
0. 退出
```

## 备份内容

脚本默认备份当前 Windows 用户目录下的 Codex 数据：

```text
%USERPROFILE%\.codex
```

主要包括：

```text
config.toml
.codex-global-state.json
session_index.jsonl
sessions
archived_sessions
state_5.sqlite
state_5.sqlite-wal
state_5.sqlite-shm
```

## 备份保存位置

备份会保存在脚本旁边的文件夹：

```text
codex-state-backups
```

如果这个文件夹不存在，脚本会自动创建。

## 命令行用法

```cmd
codex-state-guardian.cmd 状态
codex-state-guardian.cmd 检查
codex-state-guardian.cmd 列表
codex-state-guardian.cmd 恢复
codex-state-guardian.cmd 指定恢复 健康备份-20260630-200248
codex-state-guardian.cmd 检查 -强制
```

旧英文命令也兼容：

```cmd
codex-state-guardian.cmd check
codex-state-guardian.cmd status
codex-state-guardian.cmd list
codex-state-guardian.cmd restore
```

## 文件说明

```text
codex-state-guardian.cmd  主脚本
README.md                使用说明
```

## 安全提醒

- 恢复前建议先关闭 Codex。
- 不输入 `确认` 不会覆盖当前文件。
